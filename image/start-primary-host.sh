#!/bin/sh
set -eu

bb_data_dir="${BB_DATA_DIR:-/var/lib/bb}"
codex_home="${CODEX_HOME:-/var/lib/codex}"
server_url="${BB_SERVER_URL:-http://127.0.0.1:38886}"
daemon_port="${BB_HOST_DAEMON_PORT:-38887}"

mkdir -p "${bb_data_dir}" "${codex_home}"

# Containers generally have no usable keyring. File storage also lets Codex
# refresh a ChatGPT login on the persistent CODEX_HOME volume.
if [ ! -e "${codex_home}/config.toml" ]; then
  umask 077
  printf '%s\n' 'cli_auth_credentials_store = "file"' > "${codex_home}/config.toml"
fi

echo "Waiting for bb server at ${server_url}"
# The template expression below is JavaScript, not a shell expansion.
# shellcheck disable=SC2016
until node -e '
  const url = `${process.argv[1]}/health`;
  fetch(url, { signal: AbortSignal.timeout(2000) })
    .then((response) => process.exit(response.ok ? 0 : 1))
    .catch(() => process.exit(1));
' "${server_url}"; do
  sleep 2
done

if [ -s "${bb_data_dir}/auth.json" ]; then
  exec bb-host-daemon \
    --server-url "${server_url}" \
    --host-daemon-port "${daemon_port}"
fi

exec bb-host-daemon join \
  --server-url "${server_url}" \
  --host-daemon-port "${daemon_port}"
