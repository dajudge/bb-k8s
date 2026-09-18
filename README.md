# bb-k8s

An opinionated Kubernetes deployment of [bb](https://getbb.app/) with a
Codex-enabled primary host. The image and Helm chart are designed for GitOps,
reproducible builds, and a single-replica k3s installation.

## Architecture

The chart runs two containers in one StatefulSet pod:

- `server` runs `bb-server` and owns bb's persistent SQLite-backed state.
- `primary-host` runs `bb-host-daemon` with the Codex CLI installed. It shares
  bb state with the server and has separate persistent `CODEX_HOME` and
  workspace volumes.

External machines can join the same bb server as independent hosts. Their
Codex installations, API endpoints, and logins remain local to those machines;
there is no account pooler or shared Codex credential store.

## Security boundary

bb's direct HTTP API is unauthenticated and includes command execution and file
access. Do not expose it directly to the public internet. The chart therefore
ships with Ingress disabled and requires an explicit acknowledgement before an
Ingress can be rendered. Prefer `bb connect`, a VPN, or an authenticated reverse
proxy on a private network.

The workload runs as UID/GID 10001, drops all Linux capabilities, uses a
read-only root filesystem, disables service-account token mounting, and stores
only the required mutable state in volumes.

## Install

Until the first release image is published, build and push the image yourself.
For a released version:

```sh
helm upgrade --install bb ./charts/bb-k8s \
  --namespace bb \
  --create-namespace \
  --set image.tag=0.1.0
```

For a GitOps controller, point it at `charts/bb-k8s` and keep the default of one
replica. Pin `image.digest` in production; when set, it takes precedence over
`image.tag`.

Access the UI without exposing the API:

```sh
kubectl --namespace bb port-forward service/bb-bb-k8s 38886:80
```

Then open <http://127.0.0.1:38886>.

## Log in to Codex on the primary host

Open a terminal on the primary host in the bb UI and run:

```sh
codex login --device-auth
```

The image configures file-based Codex credential storage in the primary host's
persistent `CODEX_HOME`. This login belongs only to the in-cluster primary host.
Each external host performs its own Codex login and can use a different endpoint
or account.

You can also start the login through Kubernetes:

```sh
kubectl --namespace bb exec -it bb-bb-k8s-0 -c primary-host -- \
  codex login --device-auth
```

## External hosts

Install bb and Codex on the external machine, use the join command shown by the
bb UI, and authenticate Codex on that machine. The chart does not copy or pool
credentials between hosts.

## Verification and releases

Pull requests and pushes run Helm/render checks, shell linting, an image runtime
smoke test, a real installation in a disposable kind cluster, a critical
vulnerability scan, and independent amd64/arm64 builds.

Tags matching `v*` build a multi-architecture image with provenance and an SBOM,
scan and keylessly sign it, package the chart, and create a GitHub release.
Publishing needs repository secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`.
The expected image repository is `dajudge/bb-k8s`.

Runtime versions are pinned in `image/package.json`; the base image is pinned by
digest. Dependabot and Renovate configuration make updates reviewable.

This project is an independent deployment wrapper and is not affiliated with bb
or OpenAI.
