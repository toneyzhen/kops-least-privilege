#!/usr/bin/env bash
# Create the least-privilege kops cluster.
# Run while assumed into the lp-demo-kops-admin IAM role.
# Usage: scripts/02-create-cluster.sh [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---- config -----------------------------------------------------------------
CONFIG="$REPO_ROOT/config.env"
[[ -f "$CONFIG" ]] || die "config.env not found. Run: cp config.env.example config.env  and edit it."
# shellcheck disable=SC1090
source "$CONFIG"

: "${AWS_REGION:=us-east-1}"
: "${ZONES:=${AWS_REGION}a}"
# config.env.example pins 1.33.5 (kOps 1.34/1.35 support it); bump together with your kops binary
# (kops supports its own minor version and the two before it).
: "${KUBERNETES_VERSION:=1.33.5}"
: "${NAME_PREFIX:=lp-demo}"
: "${ALLOW_OPEN_API:=false}"
for v in AWS_ACCOUNT_ID CLUSTER_NAME KOPS_STATE_BUCKET KOPS_OIDC_BUCKET DEMO_DATA_BUCKET ADMIN_CIDR; do
  [[ -n "${!v:-}" ]] || die "$v is not set in config.env"
done
KOPS_STATE_STORE="${KOPS_STATE_STORE:-s3://${KOPS_STATE_BUCKET}}"
# Single-zone demo: use the first zone. Add zones/subnets/IGs for HA.
ZONE="${ZONES%%,*}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION" AWS_ACCOUNT_ID CLUSTER_NAME KOPS_STATE_STORE \
       KOPS_OIDC_BUCKET DEMO_DATA_BUCKET NAME_PREFIX ZONE KUBERNETES_VERSION ADMIN_CIDR

# ---- preflight --------------------------------------------------------------
for tool in kops kubectl aws envsubst; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    if $DRY_RUN && [[ "$tool" != envsubst ]]; then warn "'$tool' not found (needed for a real run)"; else die "'$tool' not found in PATH (envsubst is in gettext)."; fi
  fi
done

# Least privilege: never expose the API to the world by accident.
if [[ "$ADMIN_CIDR" == "0.0.0.0/0" || "$ADMIN_CIDR" == "::/0" ]]; then
  [[ "$ALLOW_OPEN_API" == "true" ]] \
    || die "ADMIN_CIDR=$ADMIN_CIDR opens the Kubernetes API to the internet. Use your IP/32 (e.g. \$(curl -s https://checkip.amazonaws.com)/32) or set ALLOW_OPEN_API=true to override."
  warn "ALLOW_OPEN_API=true: Kubernetes API will be open to the internet."
fi
[[ "$ADMIN_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ || "$ALLOW_OPEN_API" == "true" ]] \
  || die "ADMIN_CIDR must look like 203.0.113.7/32 (got: $ADMIN_CIDR)."

if $DRY_RUN; then
  log "DRY RUN: skipping AWS identity check, nothing will be created" >&2
else
  ARN="$(aws sts get-caller-identity --query Arn --output text)" \
    || die "aws sts get-caller-identity failed - are you logged in / have you assumed the role?"
  log "Caller identity: $ARN"
  if [[ "$ARN" != *"assumed-role/${NAME_PREFIX}-kops-admin/"* ]]; then
    warn "Not running as assumed-role/${NAME_PREFIX}-kops-admin. kops needs that role's (scoped) permissions; other identities are probably too broad or too narrow."
  fi
fi

# ---- render -----------------------------------------------------------------
# Explicit variable list so envsubst never touches other $ or {{...}} text.
# shellcheck disable=SC2016  # literal ${VAR} names are intended
SUBST_VARS='${CLUSTER_NAME} ${KOPS_STATE_STORE} ${KOPS_OIDC_BUCKET} ${DEMO_DATA_BUCKET} ${AWS_ACCOUNT_ID} ${AWS_REGION} ${ZONE} ${KUBERNETES_VERSION} ${ADMIN_CIDR} ${NAME_PREFIX}'
CLUSTER_MANIFEST="$(envsubst "$SUBST_VARS" < "$REPO_ROOT/kops/cluster.yaml")"

if $DRY_RUN; then
  ENCRYPTION_KEY="REDACTED-32-byte-base64-key-generated-at-run-time"
else
  ENCRYPTION_KEY="$(head -c 32 /dev/urandom | base64)"
fi
export ENCRYPTION_KEY
# shellcheck disable=SC2016
ENCRYPTION_MANIFEST="$(envsubst '${ENCRYPTION_KEY}' < "$REPO_ROOT/kops/encryption-config.yaml")"

export KOPS_STATE_STORE
if $DRY_RUN; then
  printf '%s\n' "----- rendered kops/cluster.yaml -----" "$CLUSTER_MANIFEST" \
    "----- rendered kops/encryption-config.yaml (key redacted) -----" "$ENCRYPTION_MANIFEST" \
    "----- commands that would run -----" \
    "kops create -f <rendered cluster.yaml>" \
    "kops create secret encryptionconfig -f - --name $CLUSTER_NAME   # key never written to disk" \
    "kops update cluster --name $CLUSTER_NAME --yes" \
    "kops validate cluster --name $CLUSTER_NAME --wait 15m" \
    "kops export kubeconfig --name $CLUSTER_NAME --admin=1h"
  exit 0
fi

# ---- create -----------------------------------------------------------------
if kops get cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  die "Cluster $CLUSTER_NAME already exists in $KOPS_STATE_STORE. Run scripts/98-delete-cluster.sh first, or manage it with kops directly."
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$CLUSTER_MANIFEST" > "$TMP/cluster.yaml"

log "Registering cluster spec in $KOPS_STATE_STORE"
kops create -f "$TMP/cluster.yaml"

log "Storing the etcd encryption config (key goes to the private state bucket only)"
printf '%s\n' "$ENCRYPTION_MANIFEST" | kops create secret encryptionconfig -f - --name "$CLUSTER_NAME"

log "Creating AWS resources (VPC, NAT, NLB, IAM roles, instances) - takes several minutes"
kops update cluster --name "$CLUSTER_NAME" --yes

log "Waiting for the cluster to become healthy (up to 15m)"
kops validate cluster --name "$CLUSTER_NAME" --wait 15m

# Least privilege: the kops admin kubeconfig is a client certificate with
# system:masters. Make it expire in 1 hour instead of the default 18h. Day-to-day
# access is via the IAM-mapped identities (developer / viewer roles), not this.
log "Exporting a 1-hour cluster-admin kubeconfig"
kops export kubeconfig --name "$CLUSTER_NAME" --admin=1h

cat <<MSG

Cluster $CLUSTER_NAME is ready.
 - The admin credential expires in 1h; re-run: kops export kubeconfig --name $CLUSTER_NAME --admin=1h
 - Next: apply the Kubernetes layer (RBAC, namespaces, IRSA demo), then use
   the developer / viewer roles with aws-iam-authenticator for normal access.
MSG
