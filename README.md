# Least Privilege Simulator

An interactive webpage that explains the **principle of least privilege**:
every person and program gets only the access it needs to do its job, and
nothing more.

**[▶ Open the simulator](https://htmlpreview.github.io/?https://github.com/toneyzhen/kops-least-privilege/blob/main/index.html)**

The example is a Kubernetes cluster running on AWS, built with
[kOps](https://kops.sigs.k8s.io/). You don't need to know any of those tools
to follow along. The page explains each term as it comes up.

## What you can do on the page

- **Flip one switch** between "Everyone gets full access" and "Least
  privilege" and watch the results change.
- **Try actions as four characters:** the cluster operator, a developer, an
  app, and an attacker who broke into the app. Each action shows whether it
  was allowed or blocked, and why.
- **Follow an attack** step by step and see where least privilege stops it.
- **Open "Show the technical details"** under any result to see the real
  command and the AWS or Kubernetes rule behind it.

Nothing on the page connects to AWS. The results are simulated from a
hardened kOps setup.

## Running it

Open the link above, or download [`index.html`](index.html) and open it in any
browser. It is a single file with no build step and no dependencies.

## License

[MIT](LICENSE)
