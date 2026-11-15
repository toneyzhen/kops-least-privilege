#!/usr/bin/env bash
# 99-teardown-iam.sh - remove what 01-bootstrap-iam.sh created (roles + the three buckets).
# Usage: scripts/99-teardown-iam.sh [--yes]
# Run `kops delete cluster` FIRST: kops-created roles/instance profiles/OIDC provider are removed by kops.
set -euo pipefail

ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=true ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

CONFIG="$(dirname "$0")/../config.env"
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config.env not found. Run: cp config.env.example config.env  and edit it." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"
for v in AWS_REGION AWS_ACCOUNT_ID KOPS_STATE_BUCKET KOPS_OIDC_BUCKET DEMO_DATA_BUCKET NAME_PREFIX; do
  if [[ -z "${!v:-}" ]]; then echo "ERROR: $v is not set in config.env" >&2; exit 1; fi
done
for tool in aws jq; do command -v "$tool" >/dev/null || { echo "ERROR: '$tool' is required" >&2; exit 1; }; done

cat <<MSG
This will PERMANENTLY delete (account ${AWS_ACCOUNT_ID}):
  IAM roles : ${NAME_PREFIX}-kops-admin ${NAME_PREFIX}-kops-viewer ${NAME_PREFIX}-developer
  S3 buckets: ${KOPS_STATE_BUCKET} ${KOPS_OIDC_BUCKET} ${DEMO_DATA_BUCKET} (including all object versions)
MSG
if ! $ASSUME_YES; then
  read -r -p "Type 'delete' to continue: " answer
  [[ "$answer" == "delete" ]] || { echo "aborted"; exit 1; }
fi

delete_role() {
  local name="$1" p
  if ! aws iam get-role --role-name "$name" >/dev/null 2>&1; then echo "role $name not found, skipping"; return; fi
  for p in $(aws iam list-role-policies --role-name "$name" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "$name" --policy-name "$p"
  done
  for p in $(aws iam list-attached-role-policies --role-name "$name" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$name" --policy-arn "$p"
  done
  aws iam delete-role --role-name "$name"
  echo "deleted role $name"
}

empty_and_delete_bucket() {
  local b="$1" objs
  if ! aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then echo "bucket $b not found, skipping"; return; fi
  # Remove the bucket policy first: the state store policy denies access to pki/private and secrets.
  aws s3api delete-bucket-policy --bucket "$b" 2>/dev/null || true
  # Delete every version and delete marker, 1000 per delete-objects call.
  objs="$(aws s3api list-object-versions --bucket "$b" --output json \
    --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}' || echo '{"Objects":null}')"
  echo "$objs" | jq -c '(.Objects // []) | map(select(. != null)) | [_nwise(1000)]  | .[] | {Objects: ., Quiet: true}' |
  while read -r batch; do
    aws s3api delete-objects --bucket "$b" --delete "$batch" >/dev/null
  done
  aws s3api delete-bucket --bucket "$b"
  echo "deleted bucket $b"
}

for r in kops-admin kops-viewer developer; do delete_role "${NAME_PREFIX}-${r}"; done
for b in "$KOPS_STATE_BUCKET" "$KOPS_OIDC_BUCKET" "$DEMO_DATA_BUCKET"; do empty_and_delete_bucket "$b"; done
echo "Teardown complete."
