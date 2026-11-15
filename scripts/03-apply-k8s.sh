#!/usr/bin/env bash
# Render and apply the in-cluster manifests (namespaces, RBAC, demo app, policies).
# Usage: scripts/03-apply-k8s.sh [--dry-run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/config.env"
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: $CONFIG not found. Run: cp config.env.example config.env && edit it." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

for v in AWS_REGION AWS_ACCOUNT_ID CLUSTER_NAME DEMO_DATA_BUCKET; do
  if [[ -z "${!v:-}" ]]; then echo "ERROR: $v is not set in config.env" >&2; exit 1; fi
done
command -v envsubst >/dev/null || { echo "ERROR: envsubst (gettext) is required" >&2; exit 1; }

export AWS_REGION AWS_ACCOUNT_ID CLUSTER_NAME DEMO_DATA_BUCKET
# Only substitute our variables so any other $ in the manifests is left alone.
# shellcheck disable=SC2016
VARS='${AWS_REGION} ${AWS_ACCOUNT_ID} ${CLUSTER_NAME} ${DEMO_DATA_BUCKET}'

RENDERED="$(mktemp -d)"
trap 'rm -rf "$RENDERED"' EXIT
for f in "$ROOT"/k8s/*.yaml; do
  out="$RENDERED/$(basename "$f")"
  envsubst "$VARS" < "$f" > "$out"
done

if [[ $DRY_RUN -eq 1 ]]; then
  if command -v kubectl >/dev/null; then
    echo "==> kubectl apply --dry-run=client"
    kubectl apply --dry-run=client -f "$RENDERED"
  else
    echo "==> kubectl not found; printing rendered manifests instead"
    for f in "$RENDERED"/*.yaml; do echo "# ---- $(basename "$f")"; cat "$f"; done
  fi
  exit 0
fi

command -v kubectl >/dev/null || { echo "ERROR: kubectl is required" >&2; exit 1; }
echo "==> Applying manifests (context: $(kubectl config current-context))"
# Files are numbered so namespaces exist before namespaced objects.
kubectl apply -f "$RENDERED"

echo "==> Waiting for demo workload rollout"
kubectl -n demo-app rollout status deployment/s3-reader-demo --timeout=180s
echo "Done. Next: scripts/04-verify-least-privilege.sh"
