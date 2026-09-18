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

For releases, update the npm package/lock files, chart `appVersion` and `version`,
default image tag, and Git tag together. Do not loosen the Ingress acknowledgement
or singleton replica constraint.
