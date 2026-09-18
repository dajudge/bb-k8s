#!/bin/sh
set -eu

image=${1:?usage: integration-kind.sh IMAGE}
cluster=${KIND_CLUSTER_NAME:-bb-k8s-ci}
namespace=bb-integration
release=bb
port_forward_pid=

cleanup() {
  if [ -n "${port_forward_pid}" ]; then
    kill "${port_forward_pid}" >/dev/null 2>&1 || true
  fi
  if [ "${KEEP_KIND_CLUSTER:-false}" != true ]; then
    kind delete cluster --name "${cluster}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

kind create cluster --name "${cluster}" --wait 120s
kind load docker-image --name "${cluster}" "${image}"

repository=${image%:*}
tag=${image##*:}
helm upgrade --install "${release}" ./charts/bb-k8s \
  --namespace "${namespace}" \
  --create-namespace \
  --set "image.repository=${repository}" \
  --set "image.tag=${tag}" \
  --set image.pullPolicy=Never \
  --set podDisruptionBudget.enabled=false \
  --wait \
  --timeout 5m

kubectl --namespace "${namespace}" rollout status statefulset/bb-bb-k8s --timeout=2m
kubectl --namespace "${namespace}" get pods
kubectl --namespace "${namespace}" exec bb-bb-k8s-0 -c primary-host -- codex --version \
  | grep -q '0.155.0'

kubectl --namespace "${namespace}" port-forward service/bb-bb-k8s 38886:80 \
  > "${TMPDIR:-/tmp}/bb-k8s-port-forward.log" 2>&1 &
port_forward_pid=$!

attempt=0
until curl --fail --silent --show-error http://127.0.0.1:38886/health >/dev/null; do
  attempt=$((attempt + 1))
  if [ "${attempt}" -ge 30 ]; then
    kubectl --namespace "${namespace}" describe pod bb-bb-k8s-0 >&2
    kubectl --namespace "${namespace}" logs bb-bb-k8s-0 --all-containers >&2
    exit 1
  fi
  sleep 1
done

echo 'kind integration test passed.'
