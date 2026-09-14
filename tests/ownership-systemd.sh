#!/usr/bin/env bash
# 真实 HAProxy 共享服务卸载验收；文件均在沙箱，服务名映射到唯一测试 unit。
set -Eeuo pipefail

[[ "${XTUN_TEST_ISOLATED_VPS:-no}" == yes && "${EUID}" -eq 0 && -d /run/systemd/system ]] || exit 2
TEST_OWNER_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
TEST_OWNER_ROOT="${2:-$(mktemp -d /var/tmp/xtun-ownership.XXXXXX)}"
[[ "${TEST_OWNER_ROOT}" == /var/tmp/xtun-ownership.* ]] || exit 2
TEST_SANDBOX_ROOT="${TEST_OWNER_ROOT}/sandbox"
# shellcheck disable=SC1090
source "$(dirname "${TEST_OWNER_SCRIPT}")/common.sh"
load_functions

ownership_config() {
  cat > "${HAPROXY_CONFIG}" <<CONFIG
global
  maxconn 32
defaults
  mode http
  timeout connect 1s
  timeout client 2s
  timeout server 2s
frontend foreign-site
  bind 127.0.0.1:${TEST_OWNER_PORT}
  http-request return status 200 content-type text/plain string ${1}
CONFIG
}

ownership_systemctl() {
  local arg=""
  local -a args=()

  for arg in "$@"; do
    case "${arg}" in
      haproxy|haproxy.service) arg="${TEST_OWNER_UNIT}" ;;
      xray|xray.service|nginx|nginx.service|xtun-net-optimize.service)
        arg="${TEST_OWNER_UNIT%.service}-${arg%.service}.service" ;;
    esac
    args+=("${arg}")
  done
  command systemctl "${args[@]}"
}

ownership_case() {
  local scenario="${1}"
  local status=0
  local expected_body="shared"
  local reload_command=""

  TEST_OWNER_UNIT="${2}"
  TEST_OWNER_PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)"
  mkdir -p "$(dirname "${HAPROXY_CONFIG}")" "${SYSTEMD_UNIT_DIRS[0]}" "${ACME_HOME}/foreign.example_ecc" "$(dirname "${NGINX_MAIN_CONFIG}")"
  printf foreign-certificate > "${ACME_HOME}/foreign.example_ecc/cert.pem"
  printf foreign-nginx > "${NGINX_MAIN_CONFIG}"
  NGINX_MAIN_MANAGED=no
  CERT_MODE=self-signed
  record_package_origin haproxy
  if [[ "${scenario}" != missing ]]; then
    if [[ "${scenario}" != absent ]]; then ownership_config original; fi
    record_takeover_original "${HAPROXY_CONFIG}"
  fi
  ownership_config shared
  if [[ "${scenario}" == corrupted ]]; then
    printf corrupted > "$(takeover_original_path "${HAPROXY_CONFIG}")"
  fi
  reload_command='/bin/kill -USR2 $MAINPID'
  [[ "${scenario}" != reload-failure ]] || reload_command=/bin/false
  cat > "/etc/systemd/system/${TEST_OWNER_UNIT}" <<UNIT
[Unit]
Description=xtun shared HAProxy ownership test
[Service]
Type=notify
ExecStart=$(command -v haproxy) -Ws -f ${HAPROXY_CONFIG} -p ${TEST_OWNER_ROOT}/haproxy.pid
ExecReload=${reload_command}
[Install]
WantedBy=multi-user.target
UNIT
  ln -s "/etc/systemd/system/${TEST_OWNER_UNIT}" "${SYSTEMD_UNIT_DIRS[0]}/haproxy.service"
  command systemctl daemon-reload
  command systemctl start "${TEST_OWNER_UNIT}"
  [[ "$(curl -fsS --max-time 5 "http://127.0.0.1:${TEST_OWNER_PORT}/")" == shared ]]
  sha256sum "${HAPROXY_CONFIG}" > "${TEST_OWNER_ROOT}/config-before.sha256"
  systemctl() { ownership_systemctl "$@"; }
  # 网络优化不是本用例范围，禁止 uninstall 的 sysctl --system 影响宿主。
  sysctl() { printf 'sysctl excluded from ownership fixture\n' >> "${TEST_OWNER_ROOT}/excluded-actions.log"; }
  run_cli_command uninstall --yes > "${TEST_OWNER_ROOT}/operation.log" 2>&1 || status=$?
  [[ -f "${HAPROXY_CONFIG}" ]]
  [[ "$(command systemctl show "${TEST_OWNER_UNIT}" -p ActiveState --value)" == active ]]
  [[ "$(cat "${NGINX_MAIN_CONFIG}")" == foreign-nginx ]]
  [[ "$(cat "${ACME_HOME}/foreign.example_ecc/cert.pem")" == foreign-certificate ]]
  if [[ "${scenario}" == original ]]; then
    [[ "${status}" -eq 0 && ! -e "${ORIGINALS_ROOT}" ]]
    expected_body=original
  else
    [[ "${status}" -eq 1 && -f "${ORIGINALS_ROOT}/manifest.tsv" ]]
    grep -q '未能确认' "${TEST_OWNER_ROOT}/operation.log"
  fi
  if [[ "${scenario}" != original && "${scenario}" != reload-failure ]]; then
    sha256sum -c "${TEST_OWNER_ROOT}/config-before.sha256" >/dev/null
  fi
  [[ "$(curl -fsS --retry 3 --retry-delay 1 --max-time 5 "http://127.0.0.1:${TEST_OWNER_PORT}/")" == "${expected_body}" ]]
  printf 'exit=%s\nservice=active\nhttp=%s\nforeign_files=preserved\n' "${status}" "${expected_body}" > "${TEST_OWNER_ROOT}/result.txt"
}

ownership_cleanup() {
  local unit=""

  for unit in "${TEST_OWNER_UNITS[@]}"; do
    command systemctl stop "${unit}" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${unit}"
  done
  command systemctl daemon-reload
}

if [[ "${1:-}" == --case ]]; then
  ownership_case "${3}" "${4}"
else
  TEST_OWNER_UNITS=()
  failures=0
  trap ownership_cleanup EXIT
  for scenario in original absent missing reload-failure corrupted; do
    unit="xtun-ownership-${TEST_OWNER_ROOT##*.}-${scenario}.service"
    TEST_OWNER_UNITS+=("${unit}")
    mkdir "${TEST_OWNER_ROOT}/${scenario}"
    status=0
    # 单独进程保留 errexit；不能把整个 case 函数放在 if/|| 下导致断言失效。
    bash "${TEST_OWNER_SCRIPT}" --case "${TEST_OWNER_ROOT}/${scenario}" "${scenario}" "${unit}" \
      > "${TEST_OWNER_ROOT}/${scenario}/fixture.log" 2>&1 || status=$?
    printf '%s\t%s\n' "${scenario}" "${status}" | tee -a "${TEST_OWNER_ROOT}/results.tsv"
    [[ "${status}" -eq 0 ]] || failures=$((failures + 1))
  done
  printf 'ownership evidence: %s\n' "${TEST_OWNER_ROOT}"
  [[ "${failures}" -eq 0 ]]
fi
