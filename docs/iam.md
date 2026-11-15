# IAM layer: least privilege for kops

Everything here is created by `scripts/01-bootstrap-iam.sh` from the templates in `iam/` (rendered with `envsubst` using an explicit variable list; `CLUSTER_NAME_DASHED` is derived in the script, e.g. `lp-demo-k8s-local`). Preview with `scripts/01-bootstrap-iam.sh --dry-run`; remove with `scripts/99-teardown-iam.sh`.

## What kops recommends vs what this repo does

The kops AWS getting-started guide has you create a `kops` IAM user and attach these managed policies: `AmazonEC2FullAccess`, `AmazonRoute53FullAccess`, `AmazonS3FullAccess`, `IAMFullAccess`, `AmazonVPCFullAccess`, `AmazonSQSFullAccess`, `AmazonEventBridgeFullAccess`, plus a long-lived access key. That is effectively account administrator: `IAMFullAccess` alone lets the holder grant themselves anything, `AmazonS3FullAccess` exposes every bucket in the account, and `AmazonEC2FullAccess` covers every instance, not just the cluster's.

This repo replaces that with an assumable role, `lp-demo-kops-admin`, that has no long-lived keys, requires MFA, and can only touch resources that belong to one cluster (by name pattern, tag, or ARN). Route53 is omitted entirely because the cluster uses gossip DNS (`*.k8s.local`).

## Personas

All three roles trust `arn:aws:iam::<account>:root` with `Bool aws:MultiFactorAuthPresent = true` (`iam/trust/assume-with-mfa.json`). Trusting the account root means "any principal in this account that is itself allowed to call `sts:AssumeRole` on the role". So **users need an identity policy** such as:

```json
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sts:AssumeRole",
 "Resource":"arn:aws:iam::<account>:role/lp-demo-kops-admin"}]}
```

and must have an MFA device and call `aws sts assume-role --serial-number <mfa-arn> --token-code <code>` (or an AWS CLI profile with `mfa_serial`). Both sides (trust and identity policy) must allow it; this is the recommended pattern over listing individual users in the trust policy.

| Role | Purpose | Gets |
|---|---|---|
| `lp-demo-kops-admin` | Runs `kops create/update/delete cluster`, `kops export kubeconfig --admin` | Scoped policy in `kops-admin.json` |
| `lp-demo-kops-viewer` | `kops get cluster/ig`, inspect infra | Read of spec files + EC2/ASG/ELB `Describe*`; explicit deny on key material |
| `lp-demo-developer` | Authenticates to Kubernetes (aws-iam-authenticator maps it to group `team-a-developers`) | `sts:GetCallerIdentity` only; everything else explicitly denied |

Role policies are **inline** (`put-role-policy`) because the admin policy is ~8.7k characters, above the 6,144 limit for managed policies but below the 10,240 inline limit. If you add statements you will hit that limit; split into two inline policies.

## `kops-admin.json`, statement by statement

| Statement | Scoping | Why |
|---|---|---|
| `StateStoreBucketLevel` | the state bucket only | kops lists the bucket and reads its location/encryption config |
| `StateStoreObjectsThisClusterOnly` | `<state-bucket>/<cluster>/*` | kops stores everything under a per-cluster prefix; cannot touch other clusters' state |
| `OidcDiscovery*` | OIDC bucket; objects under `<cluster>/discovery/*` | kops publishes the OIDC discovery document + JWKS (IRSA). `GetBucketPolicyStatus`/`GetObjectAcl` are used by kops to check the store is public (from kops `s3fs.go`) |
| `ReadOnlyDescribe...` | `*` | `Describe*`, `List*` APIs do not support resource-level permissions |
| `Ec2CreateInRegion` | `aws:RequestedRegion` | Create calls cannot be tag-conditioned unless kops tags in the same call, so they are limited by region only |
| `Ec2TagOnCreate` | `ec2:CreateAction` present | Allows tagging only as part of a create call |
| `Ec2MutateTaggedResourcesOnly` | `ec2:ResourceTag/KubernetesCluster = <cluster>` | modify/attach/authorize only on resources kops tagged for this cluster |
| `Ec2DestroyTaggedResourcesOnly` | same tag | `TerminateInstances`, `DeleteVolume`, `DeleteVpc`, `DeleteNatGateway`, ... only for this cluster's resources |
| `AutoScalingGroupsNamedForThisCluster` | ARN `autoScalingGroupName/*.<cluster>` | kops names ASGs `<ig>.<cluster>` |
| `LoadBalancers*` | `aws:RequestTag/` on create, `aws:ResourceTag/KubernetesCluster` on change/delete | API NLB (elbv2) |
| `ServiceLinkedRolesForAsgAndElb` | `iam:AWSServiceName` | first-use service-linked roles for Auto Scaling / ELB |
| `IamRolesAndInstanceProfilesNamedForThisCluster` | `role/*.<cluster>`, `instance-profile/*.<cluster>` | kops roles: `masters.<cluster>`, `nodes.<cluster>`, `bastions.<cluster>`, IRSA `<sa>.<ns>.sa.<cluster>`. The pattern deliberately does **not** match `lp-demo-kops-admin` etc., so the admin cannot edit itself or other personas |
| `AttachOnlyRepoManagedPoliciesToClusterRoles` | `iam:PolicyARN` = `policy/lp-demo-*` | prevents attaching `AdministratorAccess` |
| `PassClusterRolesOnlyToEc2` | `iam:PassedToService = ec2.amazonaws.com` | creating launch templates/ASGs requires PassRole on the node/control-plane roles |
| `OidcProviderForThisClusterIssuer` | provider ARN `<oidc-bucket>.s3.<region>.amazonaws.com/<cluster>*` | `enableAWSOIDCProvider: true` makes kops create/delete/tag an IAM OIDC provider |
| `NodeTerminationHandler*` | queue `<cluster-dashed>-nth`, rules `<cluster-dashed>-*` | SQS + EventBridge for NTH queue mode |
| `Deny...` | explicit | no IAM users/keys/groups/policies, no organizations/account APIs, no changes to `lp-demo-*` roles, cannot weaken the state bucket policy, no plaintext S3 |

### Action -> why kops needs it

| Action family | Why |
|---|---|
| `s3:Get/Put/DeleteObject`, `ListBucket` | read/write cluster spec, instance groups, keystores, addons |
| `ec2:CreateVpc/Subnet/InternetGateway/RouteTable/SecurityGroup/DhcpOptions/NatGateway`, `AllocateAddress` | private topology with NAT gateway + EIP |
| `ec2:RunInstances`, `CreateLaunchTemplate(Version)` | ASG launch templates (caller needs RunInstances for the template check) |
| `ec2:CreateVolume`, `AttachVolume` | etcd volumes |
| `ec2:CreateTags/DeleteTags` | kops tags everything `KubernetesCluster` / `kubernetes.io/cluster/<name>` |
| `autoscaling:*AutoScalingGroup`, `PutLifecycleHook`, `CreateOrUpdateTags`, `Attach/DetachLoadBalancerTargetGroups` | node/control-plane groups, NTH lifecycle hooks, NLB registration |
| `elasticloadbalancing:Create*/Modify*/Delete*/RegisterTargets/...` | public API NLB |
| `iam:CreateRole`, `PutRolePolicy`, `CreateInstanceProfile`, `AddRoleToInstanceProfile`, ... | kops creates one role + instance profile per instance-group role, and IRSA roles |
| `iam:CreateOpenIDConnectProvider` etc. | IRSA trust anchor |
| `sqs:*Queue*`, `events:PutRule/PutTargets` | node-termination-handler |

## Privilege escalation: PassRole and CreateRole

`iam:CreateRole` + `iam:PutRolePolicy` + `iam:PassRole` is the classic escalation path: create a role, give it `*:*`, launch an instance with it, read its credentials. Mitigations here:

1. **Name-pattern scoping** (`*.<cluster>`): the admin can only create/modify roles ending in the cluster name, never roles such as `lp-demo-kops-admin`, existing human roles, or AWS service roles.
2. **`iam:PassedToService = ec2.amazonaws.com`**: those roles cannot be passed to Lambda, CloudFormation, ECS, etc.
3. **`AttachRolePolicy` limited by `iam:PolicyARN`** to `lp-demo-*` managed policies.
4. **Explicit denies** on user/key/group/policy-version APIs and on touching the persona roles.

**Honest limitation:** IAM has no condition key that inspects the *contents* of an inline policy. So a holder of `lp-demo-kops-admin` can still write an over-broad inline policy onto a `*.lp-demo.k8s.local` role and launch an instance with it. The blast radius is "things an instance in this cluster could be given", but that includes anything. The real fix is a **permissions boundary**: set `spec.iam.permissionsBoundary` in the kops cluster spec to a boundary policy, and add `iam:PermissionsBoundary` conditions to `CreateRole`/`PutRolePolicy` and a deny on removing it. This repo does not ship that (it needs a boundary broad enough for control-plane needs and coordination with the cluster spec); treat the admin role as a trusted operator, protected by MFA and short sessions (1h `max-session-duration`).

## Viewer and the state store

`kops-viewer.json` allows only `ListBucket` (with `s3:prefix` limited to `""`, `<cluster>`, `<cluster>/*`) and `GetObject` on `<cluster>/config`, `cluster.spec`, `cluster.completed.spec`, `instancegroup/*`, plus `Describe*`. It also has explicit denies on `*/pki/private/*`, `*/pki/ssh/*`, `*/secrets/*`, `*/backups/*` (etcd backups contain Secrets) and all writes. A deny beats any allow, so even if someone later attaches a broader S3 policy the keys stay protected. Note that listing key *names* under `pki/private/` is permitted by `ListBucket`; reading them is not. Because the viewer cannot read the CA key it cannot mint an admin kubeconfig.

`state-store-bucket-policy.json` is the second line of defence (resource side):
- Deny all non-TLS (`aws:SecureTransport=false`).
- Deny `PutObject` that carries an encryption header other than `AES256`/`aws:kms`. Objects with no header are still encrypted via the bucket default (SSE-S3). A stricter "header required" rule would break clients that rely on default encryption, such as etcd-manager backups; I could not verify that they send the header.
- Deny Get/Put/Delete on `*/pki/private/*` and `*/secrets/*` for everyone except `role/lp-demo-kops-admin` and `role/masters.<cluster>` (`ArnNotLike` on `aws:PrincipalArn`, which for assumed roles is the role ARN). The admin needs it because `kops export kubeconfig --admin` reads the CA keyset. This also applies to the account root user; to administer the bucket, remove the policy (the teardown script does so) because `DeleteBucketPolicy` is not denied.
- Public Access Block fully on, ACLs disabled (BucketOwnerEnforced), versioning on, SSE-S3.

## OIDC bucket (IRSA discovery)

AWS STS must fetch the discovery document and JWKS without credentials, so that content has to be public. The default mode makes the bucket **policy**-public for `<cluster>/discovery/*` only (`GetObject`), keeps `BlockPublicAcls`/`IgnorePublicAcls` on and ACLs disabled. This is narrower than the kops docs, which turn off all four Block Public Access settings and set a `public-read` ACL on the whole bucket (available via `OIDC_ACCESS_MODE=acl`). Nothing else is readable or listable. Default encryption must be SSE-S3 (SSE-KMS would break anonymous reads).

Unverified: the kops docs only say the store must be publicly readable; my reading of the kops source is that it does not set object ACLs unless `KOPS_STATE_S3_ACL` is set, and that it checks public-ness via `GetBucketPolicyStatus`/`GetObjectAcl`. I have not run kops end-to-end against the policy-based mode; if kops reports the discovery store is not public, re-run bootstrap with `OIDC_ACCESS_MODE=acl`. Also unverified: the exact key layout kops writes under `discovery/` (the kops layer states `.well-known/openid-configuration` and `openid/v1/jwks`).

## IRSA demo

Namespace `demo-app`, service account `s3-reader` -> role `s3-reader.demo-app.sa.lp-demo.k8s.local`. The kops cluster spec (`serviceAccountExternalPermissions`) carries the policy; `iam/policies/irsa-s3-reader.json` is the same document for reference:
- `s3:GetObject` on `arn:aws:s3:::<data-bucket>/allowed/*`
- `s3:ListBucket` on the bucket with `s3:prefix` like `allowed/*`

`forbidden/secret.txt` therefore fails with AccessDenied for the pod. Role names are max **64 characters**; `<sa>.<ns>.sa.<cluster>` can exceed that with long names (kops truncates and hashes, per its `truncate` helper; I did not verify the exact rule), which would then no longer match the `*.<cluster>` pattern, so keep names short.

## Limitations and unverified items

- EC2 create actions (`CreateVpc`, `RunInstances`, ...) have no useful resource/tag condition, so they are limited by region only. Tag-conditioned mutate/destroy only works if kops tags resources `KubernetesCluster=<cluster>` at creation; kops sets this tag on its resources, but I did not run it. If `kops update cluster` fails with `UnauthorizedOperation`, check CloudTrail for the denied action (likely a separately-issued `CreateTags` or a modify on an untagged shared resource) and widen deliberately.
- Control-plane role name `masters.<cluster>`: from my knowledge of kops `IAMName`; the web sources I could fetch did not state it. NTH queue name (`<cluster-dashed>-nth`) and EventBridge rule prefix are also from memory; both dotted and dashed forms are allowed to hedge.
- Nodes are assumed not to read `pki/private/*` or `secrets/*` (kops-controller bootstraps them); if a node-bootstrap fails with AccessDenied on those prefixes, add `role/nodes.<cluster>` to the `ArnNotLike` list.
- IAM role names are limited to 64 characters; S3 bucket names are global.
- Classic ELB, KMS customer-managed keys, Route53, bastions and SSH key pairs are intentionally not covered (the demo uses NLB, default EBS key, gossip DNS, no bastion, no SSH key).
- No real AWS calls were made while authoring; JSON is validated with `envsubst | jq` only. IAM Policy Simulator / Access Analyzer validation is recommended before use.
