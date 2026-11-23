# Contributing

## Local verification

Install Docker with BuildKit, Helm 3, kubectl, kind, and shellcheck, then run:

```sh
./scripts/verify-chart.sh
shellcheck image/*.sh scripts/*.sh
docker build -t bb-k8s:dev .
./scripts/smoke-image.sh bb-k8s:dev
./scripts/integration-kind.sh bb-k8s:dev
```

The kind test creates and deletes `bb-k8s-ci` unless `KIND_CLUSTER_NAME` is set.
It installs the digest-pinned v0.2.4 release, seeds a saved bb setting and files
on the Codex/workspace volumes, then upgrades to the candidate chart/image and
checks persistence again after a restart. It also checks the native host, log
forwarding, HTTP health, and enrolled-machine package downloads.

For releases, update the npm package/lock files, chart `appVersion` and `version`,
default image tag, and Git tag together. Do not loosen the Ingress acknowledgement
or singleton replica constraint.
