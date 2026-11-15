#!/usr/bin/env bash
# Delete the kops cluster and everything kops created for it.
# Usage: scripts/98-delete-cluster.sh [--yes]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=true ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

CONFIG="$REPO_ROOT/config.env"
[[ -f "$CONFIG" ]] || { echo "ERROR: config.env not found. Run: cp config.env.example config.env" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"
: "${AWS_REGION:=us-east-1}"
: "${NAME_PREFIX:=lp-demo}"
for v in CLUSTER_NAME KOPS_STATE_BUCKET; do
  [[ -n "${!v:-}" ]] || { echo "ERROR: $v is not set in config.env" >&2; exit 1; }
done
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
export KOPS_STATE_STORE="${KOPS_STATE_STORE:-s3://${KOPS_STATE_BUCKET}}"

command -v kops >/dev/null 2>&1 || { echo "ERROR: kops not found in PATH" >&2; exit 1; }
if ARN="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"; then
  [[ "$ARN" == *"assumed-role/${NAME_PREFIX}-kops-admin/"* ]] \
    || echo "WARNING: not running as assumed-role/${NAME_PREFIX}-kops-admin (current: $ARN)" >&2
fi

if ! $ASSUME_YES; then
  echo "This will PERMANENTLY delete cluster $CLUSTER_NAME (VPC, instances, NLB, IAM roles) from $KOPS_STATE_STORE."
  read -r -p "Type the cluster name to confirm: " reply
  [[ "$reply" == "$CLUSTER_NAME" ]] || { echo "Aborted."; exit 1; }
fi

kops delete cluster --name "$CLUSTER_NAME" --yes

cat <<MSG

Cluster deleted. Not removed by this script (owned by other layers):
 - the kops state bucket and the OIDC discovery bucket objects under
   ${CLUSTER_NAME}/discovery/ (kops may leave these behind), and
 - IAM roles/policies from the IAM layer and the demo data bucket.
MSG
