#!/bin/sh
set -eu

image=${1:?usage: integration-kind.sh IMAGE}
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cluster=${KIND_CLUSTER_NAME:-bb-k8s-ci}
namespace=bb-integration
release=bb
port_forward_pid=
kind_config=$(mktemp)


cleanup() {
  exit_status=$?
  if [ "${exit_status}" -ne 0 ]; then
    kubectl --namespace "${namespace}" describe pod bb-bb-k8s-0 >&2 || true
    kubectl --namespace "${namespace}" logs bb-bb-k8s-0 --all-containers >&2 || true
    for kind_node in $(kind get nodes --name "${cluster}" 2>/dev/null); do
      docker exec "${kind_node}" dmesg 2>/dev/null \
        | grep -E 'apparmor.*(bwrap|bubblewrap)' | tail -20 >&2 || true
    done
  fi
  if [ -n "${port_forward_pid}" ]; then
    kill "${port_forward_pid}" >/dev/null 2>&1 || true
  fi
  rm -f "${kind_config}"
  if [ "${KEEP_KIND_CLUSTER:-false}" != true ]; then
    kind delete cluster --name "${cluster}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

cat > "${kind_config}" <<'YAML'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /sys/kernel/security
        containerPath: /sys/kernel/security
        readOnly: true
YAML

if [ "${BUBBLEWRAP_TEST_APPARMOR:-false}" = true ]; then
  sudo apparmor_parser --replace "${repo_root}/security/apparmor/bb-k8s-bubblewrap"
fi

kind create cluster --name "${cluster}" --config "${kind_config}" --wait 120s
kind load docker-image --name "${cluster}" "${image}"

# Localhost seccomp profiles live on the node, rather than in the pod image.
for kind_node in $(kind get nodes --name "${cluster}"); do
  docker exec "${kind_node}" mkdir -p /var/lib/kubelet/seccomp/bb-k8s
  docker cp "${repo_root}/security/seccomp/bubblewrap.json" \
    "${kind_node}:/var/lib/kubelet/seccomp/bb-k8s/bubblewrap.json"
done

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

log_marker="bb-log-forwarder-ci-$$"
printf '%s\n' "${log_marker}" | kubectl --namespace "${namespace}" \
  exec -i bb-bb-k8s-0 -c primary-host -- tee -a /var/lib/bb/logs/server-stdio.log >/dev/null
attempt=0
until kubectl --namespace "${namespace}" logs bb-bb-k8s-0 -c log-forwarder | grep -q "${log_marker}"; do
  attempt=$((attempt + 1))
  if [ "${attempt}" -ge 30 ]; then
    echo 'log-forwarder did not stream the bb log file' >&2
    exit 1
  fi
  sleep 1
done

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

curl \
  --fail \
  --silent \
  --show-error \
  --max-time 300 \
  http://127.0.0.1:38886/install/bb-app.tgz \
  | tar --gzip --list --file - \
  | grep -q '^package/package.json$'

app_armor_profile=
if [ "${BUBBLEWRAP_TEST_APPARMOR:-false}" = true ]; then
  app_armor_profile=bb-k8s-bubblewrap
fi

helm upgrade "${release}" "${repo_root}/charts/bb-k8s" \
  --namespace "${namespace}" \
  --reuse-values \
  --set primaryHost.bubblewrap.enabled=true \
  --set "primaryHost.bubblewrap.appArmorProfile=${app_armor_profile}" \
  --wait \
  --timeout 5m

kubectl --namespace "${namespace}" rollout status statefulset/bb-bb-k8s --timeout=2m
kubectl --namespace "${namespace}" exec bb-bb-k8s-0 -c primary-host \
  -- /usr/local/bin/check-bubblewrap.sh

echo 'kind integration test passed.'
