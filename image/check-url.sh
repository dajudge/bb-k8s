#!/bin/sh
set -eu

url="${1:?usage: check-url URL}"

exec node -e '
  fetch(process.argv[1], { signal: AbortSignal.timeout(2000) })
    .then((response) => process.exit(response.ok ? 0 : 1))
    .catch(() => process.exit(1));
' "${url}"
