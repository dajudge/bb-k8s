# bb-k8s

An opinionated Kubernetes deployment of [bb](https://getbb.app/) with a
Codex-enabled primary host. The image and Helm chart are designed for GitOps,
reproducible builds, and a single-replica k3s installation.

## Architecture

The chart runs three containers in one StatefulSet pod:

- `server` runs `bb-server` and owns bb's persistent SQLite-backed state.
- `primary-host` runs `bb-host-daemon` with the Codex CLI installed. It shares
  bb state with the server and has separate persistent `CODEX_HOME` and
  workspace volumes.
- `log-forwarder` follows bb's file-based server and host-daemon logs so they
  are available through Kubernetes' container log API.

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

## Logs

bb writes its detailed server and host-daemon output to files instead of the
main processes' stdout. The enabled-by-default `log-forwarder` sidecar streams
both files to its stdout:

```sh
kubectl --namespace bb logs --follow bb-bb-k8s-0 -c log-forwarder
```

Set `logging.sidecar.enabled=false` if another collector already tails the
files under `/var/lib/bb/logs`.

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

Create that Docker Hub repository as public before tagging a release. Use a
Docker Hub personal access token with Read & Write permission; do not use or
commit an account password.

Runtime versions are pinned in `image/package.json`; the base image is pinned by
digest. Dependabot and Renovate configuration make updates reviewable.

This project is an independent deployment wrapper and is not affiliated with bb
or OpenAI.

## Licensing

The wrapper is MIT-licensed. bb 0.43.1 is MIT-licensed and Codex CLI 0.155.0
is Apache-2.0 licensed. Their exact upstream license/NOTICE files are committed
under `licenses/` and copied into every image under `/licenses`. Production npm
licenses are allowlisted and checked by CI; package-level notices remain in the
installed dependency tree. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
