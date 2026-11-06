#!/bin/sh
set -eu

image=${1:?usage: smoke-image.sh IMAGE}
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
codex_version=$(node -p 'require(process.argv[1]).dependencies["@openai/codex"]' "${repo_root}/image/package.json")
bb_version=$(node -p 'require(process.argv[1]).dependencies["bb-app"]' "${repo_root}/image/package.json")

container="bb-k8s-smoke-$$"
cleanup() {
  docker rm --force "${container}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

uid=$(docker run --rm --entrypoint id "${image}" -u)
test "${uid}" = 10001

docker run --rm --entrypoint bb "${image}" --version | grep -Fq "${bb_version}"
docker run --rm --entrypoint codex "${image}" --version | grep -Fq "${codex_version}"

# Exercise the native addon against the image's actual Node runtime. The strict
# install above checks declared engine ranges; this catches ABI/runtime failures.
docker run --rm --entrypoint node "${image}" -e '
const { createRequire } = require("node:module");
const requireFromBb = createRequire("/opt/bb-k8s/node_modules/bb-app/package.json");
const Database = requireFromBb("better-sqlite3");
const db = new Database(":memory:");
db.exec("CREATE TABLE compatibility (value TEXT NOT NULL)");
db.prepare("INSERT INTO compatibility (value) VALUES (?)").run("node-compatible");
const row = db.prepare("SELECT value FROM compatibility").get();
db.close();
if (row.value !== "node-compatible") {
  throw new Error("better-sqlite3 compatibility check failed");
}
'

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
