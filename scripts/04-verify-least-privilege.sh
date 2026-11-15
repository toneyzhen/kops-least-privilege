#!/usr/bin/env bash
# Verify the least-privilege design end to end. Run as a cluster admin (the
# admin kubeconfig from kops), because the RBAC checks use impersonation.
#
# Usage: scripts/04-verify-least-privilege.sh [--skip-aws] [--skip-irsa]
#          [--mfa-serial ARN --mfa-code 123456]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/config.env"
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: $CONFIG not found. Run: cp config.env.example config.env && edit it." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"

SKIP_AWS=0; SKIP_IRSA=0; MFA_SERIAL=""; MFA_CODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-aws) SKIP_AWS=1 ;;
    --skip-irsa) SKIP_IRSA=1 ;;
    --mfa-serial) MFA_SERIAL="${2:?--mfa-serial needs a value}"; shift ;;
    --mfa-code) MFA_CODE="${2:?--mfa-code needs a value}"; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -t 1 ]]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'; else G=""; R=""; Y=""; B=""; N=""; fi
PASS=0; FAIL=0

report() { # ok(0/1) description expected actual
  if [[ "$1" -eq 0 ]]; then
    PASS=$((PASS+1)); printf '%s[PASS]%s %-62s expected: %-8s got: %s\n' "$G" "$N" "$2" "$3" "$4"
  else
    FAIL=$((FAIL+1)); printf '%s[FAIL]%s %-62s expected: %-8s got: %s\n' "$R" "$N" "$2" "$3" "$4"
  fi
}

# can_i EXPECTED USER GROUP DESCRIPTION -- kubectl-can-i-args...
can_i() {
  local expected="$1" user="$2" group="$3" desc="$4"; shift 5
  local got
  got="$(kubectl auth can-i "$@" --as="$user" --as-group="$group" 2>/dev/null)" || true
  got="${got%%$'\n'*}"; [[ "$got" == yes* ]] && got=yes || got=no
  [[ "$got" == "$expected" ]] && ok=0 || ok=1; report "$ok" "$desc" "$expected" "$got"
}

command -v kubectl >/dev/null || { echo "ERROR: kubectl is required" >&2; exit 1; }
echo "${B}Kubernetes context:${N} $(kubectl config current-context 2>/dev/null)"

echo; echo "${B}== RBAC: group team-a-developers (as developer:alice) ==${N}"
D=developer:alice; DG=team-a-developers
can_i yes $D $DG "create deployments in team-a"          -- create deployments.apps -n team-a
can_i yes $D $DG "get pod logs in team-a"                -- get pods/log -n team-a
can_i no  $D $DG "get secrets in team-a"                 -- get secrets -n team-a
can_i no  $D $DG "create pods/exec in team-a"            -- create pods/exec -n team-a
can_i no  $D $DG "create rolebindings in team-a"         -- create rolebindings.rbac.authorization.k8s.io -n team-a
can_i no  $D $DG "create serviceaccounts/token in team-a" -- create serviceaccounts/token -n team-a
can_i no  $D $DG "list pods in kube-system"              -- list pods -n kube-system
can_i no  $D $DG "get secrets in demo-app (IRSA ns)"     -- get secrets -n demo-app
can_i no  $D $DG "delete nodes"                          -- delete nodes

echo; echo "${B}== RBAC: group cluster-viewers (as viewer:bob) ==${N}"
V=viewer:bob; VG=cluster-viewers
can_i yes $V $VG "list pods in all namespaces"           -- list pods --all-namespaces
can_i yes $V $VG "list nodes"                            -- list nodes
can_i no  $V $VG "get secrets in kube-system"            -- get secrets -n kube-system
can_i no  $V $VG "delete pods in team-a"                 -- delete pods -n team-a
can_i no  $V $VG "create pods/exec in team-a"            -- create pods/exec -n team-a

if [[ $SKIP_IRSA -eq 0 ]]; then
  echo; echo "${B}== IRSA: workload demo-app/s3-reader-demo ==${N}"
  LOGS="$(kubectl -n demo-app logs deploy/s3-reader-demo --tail=60 2>&1)" || LOGS=""
  if [[ -z "$LOGS" ]] || ! grep -q '^\[identity\]' <<<"$LOGS"; then
    echo "${Y}No demo output yet; is the deployment running? (kubectl -n demo-app get pods)${N}"
  fi
  last() { grep "^\\[$1\\]" <<<"$LOGS" | tail -1; }
  l="$(last identity)"
  [[ "$l" =~ assumed-role/s3-reader\.demo-app\.sa\. ]] && ok=0 || ok=1; report "$ok" "pod identity is the s3-reader IRSA role" "match" "${l:-<none>}"
  l="$(last allowed)"
  [[ "$l" == "[allowed] OK"* ]] && ok=0 || ok=1; report "$ok" "read allowed/hello.txt succeeds" "OK" "${l:-<none>}"
  l="$(last forbidden)"
  [[ "$l" == "[forbidden] DENIED"* ]] && ok=0 || ok=1; report "$ok" "read forbidden/secret.txt is AccessDenied" "DENIED" "${l:-<none>}"
  l="$(last imds)"
  [[ "$l" == "[imds] BLOCKED"* ]] && ok=0 || ok=1; report "$ok" "node metadata service (IMDS) unreachable from pod" "BLOCKED" "${l:-<none>}"
else
  echo; echo "${Y}Skipping IRSA checks (--skip-irsa)${N}"
fi

if [[ $SKIP_AWS -eq 0 ]]; then
  echo; echo "${B}== AWS: assume lp-demo-kops-viewer ==${N}"
  for v in AWS_ACCOUNT_ID KOPS_STATE_STORE CLUSTER_NAME; do
    [[ -n "${!v:-}" ]] || { echo "ERROR: $v not set in config.env" >&2; exit 1; }
  done
  command -v aws >/dev/null || { echo "ERROR: aws CLI required (or use --skip-aws)" >&2; exit 1; }
  ARGS=(sts assume-role --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${NAME_PREFIX:-lp-demo}-kops-viewer"
        --role-session-name lp-verify --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
  [[ -n "$MFA_SERIAL" ]] && ARGS+=(--serial-number "$MFA_SERIAL" --token-code "$MFA_CODE")
  if CREDS="$(aws "${ARGS[@]}" 2>&1)"; then
    read -r AK SK ST <<<"$CREDS"
    viewer() { AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SESSION_TOKEN="$ST" aws "$@"; }
    STORE="${KOPS_STATE_STORE%/}/${CLUSTER_NAME}"
    # A successful ls of a prefix with objects exits 0.
    out="$(viewer s3 ls "$STORE/" 2>&1)"; rc=$?
    report "$rc" "viewer can list the kops state prefix" "allowed" "$([[ $rc -eq 0 ]] && echo allowed || echo "${out:0:60}")"
    # Key material written by kops: pki/private/<ca-name>/keyset.yaml
    out="$(viewer s3 cp "$STORE/pki/private/kubernetes-ca/keyset.yaml" - 2>&1 >/dev/null)"; rc=$?
    [[ $rc -ne 0 && "$out" =~ (403|Forbidden|AccessDenied) ]] && ok=0 || ok=1; report "$ok" "viewer cannot read CA private key (pki/private/...)" "denied" "$([[ $rc -ne 0 ]] && echo denied || echo "READ SUCCEEDED")"
    out="$(viewer iam list-users 2>&1)"; rc=$?
    [[ $rc -ne 0 && "$out" =~ (AccessDenied|not authorized) ]] && ok=0 || ok=1; report "$ok" "viewer cannot iam:ListUsers" "denied" "$([[ $rc -ne 0 ]] && echo denied || echo "ALLOWED")"
  else
    report 1 "assume-role into lp-demo-kops-viewer" "success" "${CREDS:0:80}"
  fi
else
  echo; echo "${Y}Skipping AWS-side checks (--skip-aws)${N}"
fi

echo; echo "${B}Summary:${N} ${G}${PASS} passed${N}, ${R}${FAIL} failed${N}"
[[ $FAIL -eq 0 ]]
