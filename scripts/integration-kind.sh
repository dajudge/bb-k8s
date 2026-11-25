#!/bin/sh
set -eu

image=${1:?usage: integration-kind.sh IMAGE}
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
codex_version=$(node -p 'require(process.argv[1]).dependencies["@openai/codex"]' "${repo_root}/image/package.json")

cluster=${KIND_CLUSTER_NAME:-bb-k8s-ci}
namespace=bb-integration
release=bb
port_forward_pid=
work_dir=$(mktemp -d)

cleanup() {
  rm -rf "${work_dir}"
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
# Start with the exact published chart/image currently deployed in production.
curl --fail --silent --show-error --location \
  https://github.com/dajudge/bb-k8s/releases/download/v0.2.4/bb-k8s-0.2.4.tgz \
  --output "${work_dir}/previous.tgz"
printf '%s  %s\n' \
  9b8df1253cf58523c3982124d8d39d3112a2e45820e47c24f6958ea1184ce958 \
  "${work_dir}/previous.tgz" | sha256sum --check
helm install "${release}" "${work_dir}/previous.tgz" \
  --namespace "${namespace}" \
  --create-namespace \
  --set image.digest=sha256:d2d43355900c584d9ed800a4f1e951cdd84fb200f0ddc8ccb744e048a2633c5a \
  --set podDisruptionBudget.enabled=false \
  --wait \
  --timeout 5m

# Seed application state through the old CLI and files on both host volumes.
kubectl --namespace "${namespace}" exec bb-bb-k8s-0 -c server -- \
  env BB_SERVER_URL=http://127.0.0.1:38886 \
  bb settings general showDiagnosticEvents true --json
kubectl --namespace "${namespace}" exec bb-bb-k8s-0 -c primary-host -- \
  sh -c 'printf "%s\n" upgrade-fixture > /workspace/bb-upgrade-fixture.txt
         printf "%s\n" upgrade-fixture > /var/lib/codex/bb-upgrade-fixture.txt'

verify_persisted_state() {
  kubectl --namespace "${namespace}" exec bb-bb-k8s-0 -c server -- \
    env BB_SERVER_URL=http://127.0.0.1:38886 bb settings show --json \
    | node -e '
let input = "";
process.stdin.on("data", chunk => { input += chunk; });
process.stdin.on("end", () => {
  if (JSON.parse(input).generalSettings.showDiagnosticEvents !== true) {
    throw new Error("Saved bb setting did not survive the upgrade");
  }
});'
  kubectl --namespace "${namespace}" exec bb-bb-k8s-0 -c primary-host -- \
    sh -c 'grep -qx upgrade-fixture /workspace/bb-upgrade-fixture.txt &&
           grep -qx upgrade-fixture /var/lib/codex/bb-upgrade-fixture.txt'
}
verify_persisted_state

helm upgrade "${release}" ./charts/bb-k8s \
  --reset-values \
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
verify_persisted_state
kubectl --namespace "${namespace}" exec bb-bb-k8s-0 -c primary-host -- codex --version \
  | grep -Fq "${codex_version}"

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

# Numbered files can first appear after the sidecar starts. Renaming one must
# neither replay its contents nor prevent discovery of its replacement.
# shellcheck disable=SC2016 # Positional parameters expand inside the container.
kubectl --namespace "${namespace}" exec bb-bb-k8s-0 -c primary-host -- \
  sh -c 'printf "%s\n" "$1-structured" > /var/lib/bb/logs/server.999998.log' sh "${log_marker}"
attempt=0
until kubectl --namespace "${namespace}" logs bb-bb-k8s-0 -c log-forwarder | grep -q "${log_marker}-structured"; do
  attempt=$((attempt + 1))
  [ "${attempt}" -lt 30 ] || { echo 'structured log file was not discovered' >&2; exit 1; }
  sleep 1
done
# shellcheck disable=SC2016 # Positional parameters expand inside the container.
kubectl --namespace "${namespace}" exec bb-bb-k8s-0 -c primary-host -- \
  sh -c 'mv /var/lib/bb/logs/server.999998.log /var/lib/bb/logs/server.999999.log
         printf "%s\n" "$1-renamed" >> /var/lib/bb/logs/server.999999.log
         printf "%s\n" "$1-replacement" > /var/lib/bb/logs/server.999998.log' sh "${log_marker}"
attempt=0
until kubectl --namespace "${namespace}" logs bb-bb-k8s-0 -c log-forwarder | grep -q "${log_marker}-replacement" &&
      kubectl --namespace "${namespace}" logs bb-bb-k8s-0 -c log-forwarder | grep -q "${log_marker}-renamed"; do
  attempt=$((attempt + 1))
  [ "${attempt}" -lt 30 ] || { echo 'rotated log files were not followed' >&2; exit 1; }
  sleep 1
done
count=$(kubectl --namespace "${namespace}" logs bb-bb-k8s-0 -c log-forwarder | grep -c "${log_marker}-structured")
[ "${count}" -eq 1 ] || { echo 'rotation replayed a structured log entry' >&2; exit 1; }

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

# A second boot checks startup against the newly migrated state as well.
kubectl --namespace "${namespace}" rollout restart statefulset/bb-bb-k8s
kubectl --namespace "${namespace}" rollout status statefulset/bb-bb-k8s --timeout=2m
verify_persisted_state

echo 'kind integration and persisted-state upgrade tests passed.'
