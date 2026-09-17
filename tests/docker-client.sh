#!/usr/bin/env bash
# Verify the documented NAS launch with the published, digest-pinned image.
# This is container startup/JSON evidence, not a real NAS/CDN/GUI path test.
set -Eeuo pipefail
umask 077

workdir="$(mktemp -d -t xtun-docker-client.XXXXXX)"
container_name="xtun-client-test-${workdir##*.}"
image_ref=ghcr.io/xtls/xray-core@sha256:45338c4df61fda061c47ce62aafda6c5d7d59cbdefc33f2e335d8b0c748b748a
cleanup() {
  docker rm -f "${container_name}" >/dev/null 2>&1 || true
  rm -rf "${workdir}"
}
trap cleanup EXIT
[[ "${EUID}" -eq 0 ]] || { printf 'Run with sudo; the fixture is sandboxed.\n' >&2; exit 2; }
command -v docker >/dev/null
export TEST_SANDBOX_ROOT="${workdir}/sandbox"
# shellcheck source=tests/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=tests/cases_generation.sh
. "${ROOT_DIR}/tests/cases_generation.sh"
# shellcheck source=tests/cases_nodes.sh
. "${ROOT_DIR}/tests/cases_nodes.sh"
load_functions
nodes_fixture "${workdir}/fixture"
run_cli_command export-client --node 3 --variant plain --format json --output "${workdir}/client.json"
[[ "$(stat -c %a "${workdir}/client.json")" == 600 ]]
python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1',10808))
PY
docker pull "${image_ref}" >/dev/null
docker run --rm "${image_ref}" version
declare -a options=(--read-only --cap-drop=ALL --security-opt=no-new-privileges
  --user "$(stat -c '%u:%g' "${workdir}/client.json")"
  --mount "type=bind,src=${workdir}/client.json,dst=/config/client.json,readonly")
docker run --rm "${options[@]}" "${image_ref}" run -test -config /config/client.json
docker run --rm -d --name "${container_name}" --network host "${options[@]}" \
  "${image_ref}" run -config /config/client.json >/dev/null
python3 - <<'PY'
import socket,time
deadline=time.monotonic()+10
while True:
    try:
        with socket.create_connection(('127.0.0.1',10808),1) as s:
            s.sendall(b'\x05\x01\x00')
            assert s.recv(2)==b'\x05\x00'
        break
    except OSError:
        if time.monotonic()>deadline: raise
        time.sleep(.1)
PY
[[ "$(docker inspect -f '{{.State.Running}}' "${container_name}")" == true ]]
printf 'PASS Docker: digest-pinned official image accepted the exported JSON and served local SOCKS; real NAS transport pending.\n'
