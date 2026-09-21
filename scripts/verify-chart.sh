#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
chart="${repo_root}/charts/bb-k8s"
work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT INT TERM

helm lint "${chart}" --strict
helm template bb "${chart}" > "${work_dir}/default.yaml"

grep -q 'kind: StatefulSet' "${work_dir}/default.yaml"
grep -q 'replicas: 1' "${work_dir}/default.yaml"
grep -q 'name: primary-host' "${work_dir}/default.yaml"
claim_templates=$(sed -n '/^  volumeClaimTemplates:/,$p' "${work_dir}/default.yaml")
if printf '%s\n' "${claim_templates}" | grep -Eq 'helm.sh/chart|app.kubernetes.io/version|app.kubernetes.io/managed-by'; then
  echo 'volumeClaimTemplates contain release-varying labels that break StatefulSet upgrades' >&2
  exit 1
fi
printf '%s\n' "${claim_templates}" | grep -q 'app.kubernetes.io/name: bb-k8s'
printf '%s\n' "${claim_templates}" | grep -q 'app.kubernetes.io/instance: bb'

grep -q 'name: log-forwarder' "${work_dir}/default.yaml"
if grep -q 'kind: Ingress' "${work_dir}/default.yaml"; then
  echo 'default render unexpectedly contains an Ingress' >&2
  exit 1
fi

helm template bb "${chart}" --set logging.sidecar.enabled=false \
  > "${work_dir}/logging-disabled.yaml"
if grep -q 'name: log-forwarder' "${work_dir}/logging-disabled.yaml"; then
  echo 'log-forwarder rendered while disabled' >&2
  exit 1
fi

if helm template bb "${chart}" \
  --set ingress.enabled=true \
  --set 'ingress.hosts[0].host=bb.example.test' \
  --set 'ingress.hosts[0].paths[0].path=/' \
  --set 'ingress.hosts[0].paths[0].pathType=Prefix' \
  > "${work_dir}/unsafe-ingress.yaml" 2> "${work_dir}/unsafe-ingress.err"; then
  echo 'Ingress rendered without the required security acknowledgement' >&2
  exit 1
fi
grep -q 'acknowledgeUnauthenticatedApiExposure' "${work_dir}/unsafe-ingress.err"

helm template bb "${chart}" \
  --set ingress.enabled=true \
  --set ingress.acknowledgeUnauthenticatedApiExposure=true \
  --set 'ingress.hosts[0].host=bb.example.test' \
  --set 'ingress.hosts[0].paths[0].path=/' \
  --set 'ingress.hosts[0].paths[0].pathType=Prefix' \
  > "${work_dir}/ingress.yaml"
grep -q 'kind: Ingress' "${work_dir}/ingress.yaml"

digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
helm template bb "${chart}" --set "image.digest=${digest}" > "${work_dir}/digest.yaml"
grep -q "dajudge/bb-k8s@${digest}" "${work_dir}/digest.yaml"

echo 'Helm chart verification passed.'
