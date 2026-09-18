#!/bin/sh
set -eu

image=${1:?usage: smoke-image.sh IMAGE}
container="bb-k8s-smoke-$$"
cleanup() {
  docker rm --force "${container}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

uid=$(docker run --rm --entrypoint id "${image}" -u)
test "${uid}" = 10001

docker run --rm --entrypoint bb "${image}" --version | grep -q '0.43.1'
docker run --rm --entrypoint codex "${image}" --version | grep -q '0.155.0'

docker run --detach \
  --name "${container}" \
  --read-only \
  --tmpfs /tmp:uid=10001,gid=10001 \
  --tmpfs /home/bb:uid=10001,gid=10001 \
  --tmpfs /var/lib/bb:uid=10001,gid=10001 \
  --publish 127.0.0.1::38886 \
  "${image}" \
  bb-server --data-dir /var/lib/bb --server-bind-host 0.0.0.0 --server-port 38886 \
  >/dev/null

host_port=$(docker port "${container}" 38886/tcp | sed 's/.*://')
attempt=0
until curl --fail --silent --show-error "http://127.0.0.1:${host_port}/health" >/dev/null; do
  attempt=$((attempt + 1))
  if [ "${attempt}" -ge 30 ]; then
    docker logs "${container}" >&2
    exit 1
  fi
  sleep 1
done

echo 'Image smoke test passed.'
