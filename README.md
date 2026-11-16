# Permission Blast Radius

An interactive webpage that shows the **principle of least privilege** as a
blast radius. An attacker has broken into one app in a Kubernetes cluster on
AWS. Switch the app's permissions on and off and watch how far the damage can
spread.

**[▶ Open the simulator](https://htmlpreview.github.io/?https://github.com/toneyzhen/kops-least-privilege/blob/main/index.html)**

You don't need to know AWS, Kubernetes or [kOps](https://kops.sigs.k8s.io/)
to follow along. The page explains each term as it comes up.

## What you can do on the page

- **Flip permissions on and off.** Each one is marked "Needed for the job" or
  "Not needed".
- **Watch the blast radius** grow or shrink across four rings: the app, the
  cluster, the servers, and the whole AWS account.
- **See how permissions chain together.** Select anything at risk to see the
  path an attacker takes to reach it. For example, reading every storage
  bucket exposes the cluster's master keys, which give full control of the
  cluster.
- **Try the presets:** Least privilege, Typical setup and Full access.
- **Open "Technical details"** under any permission to see the real AWS IAM
  or Kubernetes rule behind it.

Nothing on the page connects to AWS. It is a simplified model of a kOps
cluster.

## Running it

Open the link above, or download [`index.html`](index.html) and open it in any
browser. It is a single file with no build step and no dependencies.

## License

[MIT](LICENSE)
