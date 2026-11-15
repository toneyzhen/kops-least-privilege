# kops cluster layer

Files: `kops/cluster.yaml`, `kops/encryption-config.yaml`, `scripts/02-create-cluster.sh`,
`scripts/98-delete-cluster.sh`. Run the scripts while assumed into `lp-demo-kops-admin`
(the scripts warn if you are not).

```bash
scripts/02-create-cluster.sh --dry-run   # print rendered manifests + commands, touch nothing
scripts/02-create-cluster.sh             # create (~15-20 min)
scripts/98-delete-cluster.sh             # destroy (prompts; --yes to skip)
```

Tested-against assumption: kOps 1.34/1.35 with Kubernetes 1.33.5 (the
`config.env.example` / script default). Field names were checked against the
kops `v1alpha2` API source and kops.sigs.k8s.io docs, but **no cluster was created
during authoring** (no AWS credentials), so expect to fix small things on a first run.
kops supports its own Kubernetes minor and the two before it; keep binary and version aligned.

## Hardening walk-through

| Setting | kops default | This repo | What it removes |
|---|---|---|---|
| `topology: private` + NAT, no bastion | public: instances get public IPs | private subnets for control plane and nodes | Direct internet reachability of instances; no bastion host to attack |
| `kubernetesApiAccess: [ADMIN_CIDR]` | `0.0.0.0/0` via CLI | operator `/32` only; script refuses `0.0.0.0/0` unless `ALLOW_OPEN_API=true` | Internet-wide exposure of the API endpoint to scans and brute force |
| `sshAccess: []`, `sshKeyName: ""` | SSH rule open to the CLI-provided CIDR (commonly `0.0.0.0/0`), key pair attached | no SSH rule, no EC2 key pair | Port 22 exposure and a long-lived SSH key that can be stolen |
| `instanceMetadata: httpTokens: required, httpPutResponseHopLimit: 1` | IMDSv2 required, hop limit 1 in recent kops; older versions differ | set explicitly on both IGs | SSRF or a compromised pod reading node IAM credentials from 169.254.169.254 (the extra container hop drops the response) |
| `iam.useServiceAccountExternalPermissions: true` | off (addon permissions live on the node role) | on, with IRSA discovery in S3 | Node role carrying CCM/EBS-CSI/autoscaler permissions that any pod could inherit |
| `serviceAccountExternalPermissions` for `demo-app/s3-reader` | none | `GetObject` on `allowed/*` + `ListBucket` with `s3:prefix` = `allowed/*` | Workload getting a broad S3 policy; the role is assumable only by that service account |
| `iam.allowContainerRegistry: false` | false | explicit | ECR pull rights on every node |
| `authentication.aws` (aws-iam-authenticator) | client certs / none | IAM roles mapped to k8s users/groups; `{{SessionName}}` kept in the username | Shared kubeconfigs and static credentials; audit logs show a real session name |
| `authorization.rbac` | RBAC | explicit | Accidental AlwaysAllow |
| `kubeAPIServer.anonymousAuth: false` / `kubelet.anonymousAuth: false` | recent kops already false; explicit here | explicit | Unauthenticated calls to the API server or kubelet |
| audit log + `auditPolicyFile` (via `fileAssets`) | no audit policy, so nothing logged | Metadata-level policy, Secret/ConfigMap bodies never logged | Lack of accountability; logs stay on the control-plane node at `/var/log/kube-apiserver-audit.log` (ship them elsewhere in real use) |
| `encryptionConfig: true` + `encryption-config.yaml` | Secrets base64 in etcd | aescbc key generated per cluster, stored in the private kops state bucket | etcd/volume snapshot disclosure revealing Secrets |
| `etcdClusters[].etcdMembers[].encryptedVolume: true`, `rootVolumeEncryption: true` | not guaranteed on all versions | explicit | Plaintext data on EBS volumes and snapshots |
| `networking: cilium` | kops-version dependent | Cilium | Provides NetworkPolicy enforcement for the k8s layer |

Tags: kops tags everything it creates with `kubernetes.io/cluster/<name>=owned` and
`KubernetesCluster=<name>`. The IAM layer's tag conditions depend on these; nothing extra is set.

## Node role before vs after `useServiceAccountExternalPermissions`

**Before (default):** all instances in a role share one instance profile. Node role
includes whatever the addons need: EC2 volume create/attach/delete (EBS CSI), ELB and
EC2 security group management (cloud-controller-manager), autoscaling actions, and so on. Any
pod that can reach IMDS or escape to the node inherits all of it. The control-plane role is
broader still (it runs the CCM and etcd-manager).

**After:** kops creates a separate IAM role per addon service account (CCM, EBS CSI,
dns-controller, etc.) trusted via the cluster's OIDC provider, each limited to its
ServiceAccount. The instance profiles shrink to what the instance itself needs
(register to the cluster, read its bootstrap/state-store files, S3 reads for kops
assets, etc.). Combined with IMDS hop limit 1, a compromised application pod has no ambient AWS
authority; it only gets what its own annotated service account is granted (here:
read `allowed/*` in one bucket). Verify the actual before/after policies with
`kops update cluster` output or `aws iam list-role-policies` on the created roles.

## Caveats

- **Gossip + IRSA:** the `.k8s.local` name means no Route53, but the OIDC issuer is an S3 URL,
  so it works. The `KOPS_OIDC_BUCKET` must allow public read of the discovery prefix (the IAM/bootstrap
  layer owns that bucket; `lp-demo-kops-admin` needs write access to
  `s3://KOPS_OIDC_BUCKET/CLUSTER_NAME/discovery/*` and IAM OIDC-provider create rights).
- **Pod identity webhook:** `podIdentityWebhook.enabled` and `certManager.enabled` are both on. Per kops
  addons docs, the webhook is configured with every ServiceAccount to role mapping in the cluster spec, so
  workloads do not need the `eks.amazonaws.com/role-arn` annotation (an annotation would override). The
  kops-created role is named `s3-reader.demo-app.sa.<cluster-name>`, so the assumed-role ARN matches
  `assumed-role/s3-reader\.demo-app\.sa\.`.
- **API access via public NLB:** gossip clusters need a public API load balancer to be reachable
  from a laptop, so the control is the `/32`, not privacy. If your IP changes, update the SG
  (`kops edit cluster` then update) or re-create.
- **aws-iam-authenticator:** uses `backendMode: CRD` so mappings are inline in this spec
  (kops docs: inline mappings are CRD-only; authenticator image >= 0.5.0, shipped with current kops).
  It runs as a DaemonSet on control-plane nodes. Users need the `aws-iam-authenticator`
  binary and a kubeconfig exec entry with `-i lp-demo.k8s.local` (the `clusterID`) and
  `-r arn:aws:iam::<acct>:role/lp-demo-developer` (or `-viewer`). The k8s layer must create
  RoleBindings for groups `team-a-developers` and `cluster-viewers`; until it does, those
  identities authenticate but are authorized for nothing. `lp-demo-kops-admin` is intentionally not mapped.
  Enabling the authenticator on an existing cluster has extra steps (kops docs); here it is on from creation.
- **Admin access:** `kops export kubeconfig --admin=1h` issues a cluster-admin client certificate
  that expires in one hour. Re-run when needed. Day-to-day use goes through IAM-mapped identities.
- **Encryption key lifecycle:** the aescbc key is generated at create time and only stored in the
  state bucket (private, versioned recommended). Rotating means adding a new key first in the list via
  `kops create secret encryptionconfig --force`, rolling the control plane, then re-writing secrets.
  For production use a KMS provider instead.
- **SSH/bastion:** none. SSM Session Manager would work but needs extra instance-role
  permissions (kops does not attach them), so the demo does not enable it.
- **Single AZ, single control plane:** demo cost trade-off, not an HA setup.
- **Cost (rough, us-east-1, on-demand):** 3 x t3.medium (~$0.042/h each) ~ $0.13/h, NAT gateway ~ $0.045/h + data,
  NLB ~ $0.025/h, EBS (~ 3 x 50 GB root + etcd volumes) ~ $0.04/h => about $0.25-0.30/h, ~$6-7/day. Delete when done.
- **Unverified before first run:** empty `sshAccess` acceptance for private topology; whether
  `kubelet.authorizationMode: Webhook` is a no-op with your kops version (it is the kops default); audit
  policy path mounting (`/etc/kubernetes/audit/policy-config.yaml` follows current kops docs).
