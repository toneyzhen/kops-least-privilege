#!/usr/bin/env bash
# 01-bootstrap-iam.sh - create the buckets and IAM personas for the least-privilege kops demo.
# Idempotent: safe to re-run. Usage: scripts/01-bootstrap-iam.sh [--dry-run]
#   --dry-run  render templates, print them and the aws commands; call no AWS API.
# Env knob: OIDC_ACCESS_MODE=policy (default) | acl
#   policy: bucket policy grants public GetObject on <cluster>/discovery/* only.
#   acl:    the setup from kops docs (public-read bucket ACL) - fallback if kops insists on ACLs.
set -euo pipefail

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$(dirname "$0")/../config.env"
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config.env not found. Run: cp config.env.example config.env  and edit it." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"

for v in AWS_REGION AWS_ACCOUNT_ID CLUSTER_NAME KOPS_STATE_BUCKET KOPS_OIDC_BUCKET DEMO_DATA_BUCKET NAME_PREFIX; do
  if [[ -z "${!v:-}" ]]; then echo "ERROR: $v is not set in config.env" >&2; exit 1; fi
done
for tool in envsubst jq; do
  command -v "$tool" >/dev/null || { echo "ERROR: '$tool' is required" >&2; exit 1; }
done
if ! $DRY_RUN; then
  command -v aws >/dev/null || { echo "ERROR: 'aws' CLI is required" >&2; exit 1; }
  actual="$(aws sts get-caller-identity --query Account --output text)"
  if [[ "$actual" != "$AWS_ACCOUNT_ID" ]]; then
    echo "ERROR: credentials are for account $actual but config.env says $AWS_ACCOUNT_ID" >&2; exit 1
  fi
fi

OIDC_ACCESS_MODE="${OIDC_ACCESS_MODE:-policy}"
# kops/AWS names derived from the cluster name (NTH queue/rules use the dashed form; see docs/iam.md)
CLUSTER_NAME_DASHED="${CLUSTER_NAME//./-}"
export CLUSTER_NAME_DASHED

# Explicit variable list: never let envsubst touch anything else (e.g. IAM policy variables).
# shellcheck disable=SC2016  # literal ${...} names are intended: envsubst expands them, not bash
VARS='${AWS_REGION} ${AWS_ACCOUNT_ID} ${CLUSTER_NAME} ${CLUSTER_NAME_DASHED} ${KOPS_STATE_BUCKET} ${KOPS_OIDC_BUCKET} ${DEMO_DATA_BUCKET} ${NAME_PREFIX}'

# run: print the command; execute unless --dry-run
run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if ! $DRY_RUN; then "$@"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

render() { # render <template> <outfile>
  envsubst "$VARS" < "$1" > "$2"
  jq -e . "$2" >/dev/null || { echo "ERROR: rendered $1 is not valid JSON" >&2; exit 1; }
  if $DRY_RUN; then echo "--- rendered $(basename "$1") ---"; jq . "$2"; fi
}

P="$ROOT/iam/policies"
render "$P/kops-admin.json"                "$WORK/kops-admin.json"
render "$P/kops-viewer.json"               "$WORK/kops-viewer.json"
render "$P/developer.json"                 "$WORK/developer.json"
render "$P/state-store-bucket-policy.json" "$WORK/state-store-bucket-policy.json"
render "$P/oidc-bucket-policy.json"        "$WORK/oidc-bucket-policy.json"
render "$ROOT/iam/trust/assume-with-mfa.json" "$WORK/trust.json"
# irsa-s3-reader.json is reference only (kops applies it via serviceAccountExternalPermissions); validate it anyway.
render "$P/irsa-s3-reader.json"            "$WORK/irsa-s3-reader.json"

bucket_exists() { ! $DRY_RUN && aws s3api head-bucket --bucket "$1" >/dev/null 2>&1; }

create_bucket() { # create_bucket <name> <ownership>
  local name="$1" ownership="$2"
  if bucket_exists "$name"; then echo "bucket $name exists, skipping create"; return; fi
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    run aws s3api create-bucket --bucket "$name" --region "$AWS_REGION" --object-ownership "$ownership"
  else
    run aws s3api create-bucket --bucket "$name" --region "$AWS_REGION" --object-ownership "$ownership" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION"
  fi
}

sse_s3() { # default encryption SSE-S3 (kops default). SSE-KMS would break anonymous reads on the OIDC bucket.
  run aws s3api put-bucket-encryption --bucket "$1" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
}

bpa_all_on() {
  run aws s3api put-public-access-block --bucket "$1" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
}

echo "== 1/4 kops state store bucket: $KOPS_STATE_BUCKET"
create_bucket "$KOPS_STATE_BUCKET" BucketOwnerEnforced
run aws s3api put-bucket-versioning --bucket "$KOPS_STATE_BUCKET" --versioning-configuration Status=Enabled
sse_s3 "$KOPS_STATE_BUCKET"
bpa_all_on "$KOPS_STATE_BUCKET"
run aws s3api put-bucket-policy --bucket "$KOPS_STATE_BUCKET" --policy "file://$WORK/state-store-bucket-policy.json"

echo "== 2/4 OIDC discovery bucket: $KOPS_OIDC_BUCKET (mode: $OIDC_ACCESS_MODE)"
# Why this bucket is public: AWS STS fetches <issuer>/.well-known/openid-configuration and the JWKS
# anonymously to validate service-account tokens (IRSA). Only those documents are public.
case "$OIDC_ACCESS_MODE" in
  policy)
    # ACLs disabled; only a *bucket policy* can make objects public, and only for the <cluster>/discovery/* prefix.
    # BlockPublicAcls/IgnorePublicAcls stay ON; only the two policy-related blocks are off.
    create_bucket "$KOPS_OIDC_BUCKET" BucketOwnerEnforced
    run aws s3api put-public-access-block --bucket "$KOPS_OIDC_BUCKET" --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
    run aws s3api put-bucket-policy --bucket "$KOPS_OIDC_BUCKET" --policy "file://$WORK/oidc-bucket-policy.json"
    ;;
  acl)
    # Setup from the kops docs: ACL-based public read of the whole bucket. Broader; use only if needed.
    create_bucket "$KOPS_OIDC_BUCKET" BucketOwnerPreferred
    run aws s3api put-public-access-block --bucket "$KOPS_OIDC_BUCKET" --public-access-block-configuration \
      BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false
    run aws s3api put-bucket-acl --bucket "$KOPS_OIDC_BUCKET" --acl public-read
    ;;
  *) echo "ERROR: OIDC_ACCESS_MODE must be policy or acl" >&2; exit 1 ;;
esac
sse_s3 "$KOPS_OIDC_BUCKET"

echo "== 3/4 demo data bucket: $DEMO_DATA_BUCKET"
create_bucket "$DEMO_DATA_BUCKET" BucketOwnerEnforced
sse_s3 "$DEMO_DATA_BUCKET"
bpa_all_on "$DEMO_DATA_BUCKET"
printf 'hello from the allowed/ prefix\n' > "$WORK/hello.txt"
printf 'this object must NOT be readable by the s3-reader workload\n' > "$WORK/secret.txt"
run aws s3api put-object --bucket "$DEMO_DATA_BUCKET" --key allowed/hello.txt --body "$WORK/hello.txt"
run aws s3api put-object --bucket "$DEMO_DATA_BUCKET" --key forbidden/secret.txt --body "$WORK/secret.txt"

echo "== 4/4 IAM roles (trust: account root + MFA)"
ensure_role() { # ensure_role <name> <description> <policy-file>
  local name="$1" desc="$2" pol="$3"
  if ! $DRY_RUN && aws iam get-role --role-name "$name" >/dev/null 2>&1; then
    echo "role $name exists, updating trust policy"
    run aws iam update-assume-role-policy --role-name "$name" --policy-document "file://$WORK/trust.json"
  else
    run aws iam create-role --role-name "$name" --description "$desc" --max-session-duration 3600 \
      --assume-role-policy-document "file://$WORK/trust.json" \
      --tags Key=project,Value=kops-least-privilege Key=cluster,Value="$CLUSTER_NAME"
  fi
  # Inline policy (put-role-policy overwrites => idempotent). kops-admin exceeds the 6144-char
  # managed-policy limit, so inline (10240 aggregate limit) is used for all personas.
  run aws iam put-role-policy --role-name "$name" --policy-name "${name}-policy" --policy-document "file://$pol"
}
ensure_role "${NAME_PREFIX}-kops-admin"  "kops operator: scoped create/update/delete of cluster ${CLUSTER_NAME}" "$WORK/kops-admin.json"
ensure_role "${NAME_PREFIX}-kops-viewer" "read-only view of kops cluster spec; no key material" "$WORK/kops-viewer.json"
ensure_role "${NAME_PREFIX}-developer"   "Kubernetes developer persona (mapped to team-a-developers); no AWS access" "$WORK/developer.json"

cat <<MSG

Done$($DRY_RUN && echo ' (dry run: nothing was created)').
Users still need an identity policy allowing sts:AssumeRole on these roles, and an MFA device:
  arn:aws:iam::${AWS_ACCOUNT_ID}:role/${NAME_PREFIX}-kops-admin
  arn:aws:iam::${AWS_ACCOUNT_ID}:role/${NAME_PREFIX}-kops-viewer
  arn:aws:iam::${AWS_ACCOUNT_ID}:role/${NAME_PREFIX}-developer
See docs/iam.md.
MSG
