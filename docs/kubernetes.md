# In-cluster least privilege

Manifests live in `k8s/`; `scripts/03-apply-k8s.sh` renders them with `envsubst` and applies them;
`scripts/04-verify-least-privilege.sh` proves the result.

## Identity: who is calling?

The kops spec maps AWS IAM roles to Kubernetes identities through aws-iam-authenticator:

| AWS role | Kubernetes username | Group |
|---|---|---|
| `lp-demo-developer` | `developer:{{SessionName}}` | `team-a-developers` |
| `lp-demo-kops-viewer` | (session) | `cluster-viewers` |

Permissions attach to groups only, never to individual users, and nobody except the kops admin
holds `cluster-admin`.

## RBAC design and the escalation paths it closes

`k8s/10-rbac-team-a.yaml` gives `team-a-developers` a namespaced Role (not a ClusterRole), so nothing
leaks outside `team-a`. RBAC is additive, so each exclusion below is simply the absence of a rule:

| Not granted | Escalation path closed |
|---|---|
| `secrets` get/list/watch | Secrets hold credentials, including ServiceAccount tokens, which could then be replayed. `list` returns full contents. |
| `pods/exec`, `attach`, `portforward` | Running code inside a pod means acting with that pod's SA token, mounted secrets and IRSA AWS role. |
| `roles`, `rolebindings` | Editing RBAC lets a user grant themselves anything (self-escalation). |
| `serviceaccounts/token` | TokenRequest mints a token for any SA in the namespace. |

**Residual path: `create pods`.** Anyone who can create pods (or Deployments) can set
`serviceAccountName` to any SA in that namespace and borrow its permissions. RBAC cannot prevent
this, so the design removes the prize instead: `team-a` has only the `default` SA, which is bound to
no Role and has `automountServiceAccountToken: false`. The IRSA SA lives in `demo-app`, which team-a
developers cannot write to.

`k8s/11-rbac-cluster-viewers.yaml` defines `cluster-viewer` (pods, services, endpoints, nodes,
namespaces, events, workload controllers; read-only). Secrets, configmaps and pod logs are excluded
because they commonly leak credentials. The built-in `view` ClusterRole is a reasonable alternative;
we enumerate rules so the grant is explicit and does not grow when aggregated roles change.

## Pod Security Admission

Both namespaces enforce the `restricted` profile (non-root, no privilege escalation, all capabilities
dropped, seccomp `RuntimeDefault`, no host namespaces/volumes). `enforce-version` is pinned (v1.30) so
upgrades do not change what is blocked unexpectedly; `audit`/`warn` track `latest` to preview the
next tightening. PSA also backs the `create pods` argument above: developers cannot create privileged
or hostPath pods to break out.

## IRSA flow (no node credentials needed by pods)

1. kops provisions an IAM role `s3-reader.demo-app.sa.<cluster>` whose trust policy only accepts the
   cluster's OIDC provider for subject `system:serviceaccount:demo-app:s3-reader`, and whose policy
   allows `s3:GetObject` on `<bucket>/allowed/*` and `ListBucket` with prefix `allowed/`.
2. The pod-identity-webhook addon mutates pods using that SA: adds a projected, audience-bound,
   short-lived token and sets `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE`. (kops configures the
   webhook with the SA-to-role mapping; the `eks.amazonaws.com/role-arn` annotation is an optional override.)
3. The AWS CLI/SDK calls STS `AssumeRoleWithWebIdentity` with that token and receives temporary,
   scoped credentials.

The demo (`k8s/20-demo-app.yaml`) shows `get-caller-identity` returning the assumed role, the
`allowed/` object readable, and the `forbidden/` object denied.

## Why block the instance metadata service (IMDS)?

Node instance roles are broad (the kubelet, CNI and other components need them). If a pod can reach
`169.254.169.254` it can fetch the node's credentials and bypass IRSA entirely. Two layers:

* kops sets the IMDS hop limit to 1 so traffic from pod network namespaces (an extra hop) is dropped.
* NetworkPolicy `allow-https-egress-no-imds` allows only TCP/443 to `0.0.0.0/0` except `169.254.169.254/32`.

The demo probes `169.254.169.254:80` with bash `/dev/tcp` (the aws-cli image has no curl). Note that
port 80 is also blocked simply by the policy allowing only 443, so this probe exercises both layers
together; to test the hop limit alone, run a pod without the policy.

## NetworkPolicies

`30-networkpolicies.yaml` applies default-deny ingress and egress in `team-a` and `demo-app`, then
in `demo-app` allows DNS to kube-dns and HTTPS egress. This needs a CNI that enforces policy: set
`networking: cilium: {}` (or calico) in the kops spec. Without one the objects are silently ignored.

## Reproducing the checks manually

```bash
# RBAC (as admin, with impersonation)
kubectl auth can-i create deployments.apps -n team-a --as=developer:alice --as-group=team-a-developers   # yes
kubectl auth can-i get secrets -n team-a            --as=developer:alice --as-group=team-a-developers   # no
kubectl auth can-i create pods/exec -n team-a       --as=developer:alice --as-group=team-a-developers   # no
kubectl auth can-i create rolebindings.rbac.authorization.k8s.io -n team-a --as=developer:alice --as-group=team-a-developers  # no
kubectl auth can-i list pods -A --as=viewer:bob --as-group=cluster-viewers                              # yes
kubectl auth can-i get secrets -A --as=viewer:bob --as-group=cluster-viewers                            # no

# IRSA
kubectl -n demo-app logs deploy/s3-reader-demo --tail=20
kubectl -n demo-app exec deploy/s3-reader-demo -- env | grep AWS_    # AWS_ROLE_ARN, AWS_WEB_IDENTITY_TOKEN_FILE

# PSA: a privileged pod must be rejected
kubectl -n team-a run bad --image=busybox:1.36 --dry-run=server   # warns/rejects: no securityContext, runs as root

# AWS side (viewer role)
aws sts assume-role --role-arn arn:aws:iam::$AWS_ACCOUNT_ID:role/lp-demo-kops-viewer --role-session-name t
# export the returned credentials, then:
aws s3 ls $KOPS_STATE_STORE/$CLUSTER_NAME/                                   # allowed
aws s3 cp $KOPS_STATE_STORE/$CLUSTER_NAME/pki/private/kubernetes-ca/keyset.yaml -   # AccessDenied
aws iam list-users                                                            # AccessDenied
```

Or simply run `scripts/04-verify-least-privilege.sh` (`--skip-aws`, `--skip-irsa`,
`--mfa-serial ARN --mfa-code 123456` are available).
