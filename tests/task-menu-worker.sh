#!/usr/bin/env bash
# 真正的任务菜单/输入/确认/锁/持久恢复；服务应用在隔离目录内注入结果。
set -Eeuo pipefail
: "${TEST_MENU_ROOT:?由 task-menu-boundary.py 提供}"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_functions

if [[ "${1:-}" == seed ]]; then
  mkdir -p "${XRAY_CONFIG_DIR}" "$(dirname "${OUTPUT_FILE}")"
  SERVER_IP=198.51.100.10
  NODE_LABEL_PREFIX=TEST
  REALITY_UUID=11111111-1111-4111-8111-111111111111
  XHTTP_UUID=22222222-2222-4222-8222-222222222222
  REALITY_SNI=reality.example.com
  REALITY_TARGET=reality.example.com:443
  REALITY_SHORT_ID=0123456789abcdef
  REALITY_PRIVATE_KEY=fixture-private
  REALITY_PUBLIC_KEY=fixture-public
  XHTTP_DOMAIN=cdn.example.com
  XHTTP_PATH=/old
  H3_INTENT=off
  CERT_MODE=self-signed
  ENABLE_WARP=no
  ENABLE_NET_OPT=no
  NET_BBR_KERNEL=none
  set_test_warp_credentials
  state_file_text > "${STATE_FILE}"
  printf '{"inbounds":[],"outbounds":[]}\n' > "${XRAY_CONFIG_FILE}"
  printf '## 节点 1\nvless://fixture@example.test:443#FIRST\n' > "${OUTPUT_FILE}"
  exit 0
fi

systemctl() {
  if [[ "${1:-}" == show ]]; then printf 'LoadState=not-found\nActiveState=inactive\nUnitFileState=\n'; fi
}
show_dashboard_brief() { printf 'XTUN-TEST-MENU\n'; }
change_environment_fingerprint() { sha256sum "${STATE_FILE}" | awk '{print $1}'; }
status_cmd() { printf 'STATUS-OK\n'; }
apply_managed_runtime_update() {
  begin_generation_paths '菜单测试变更' -- "${STATE_FILE}" || return 1
  if [[ "${TEST_MENU_OUTCOME:-}" == execute-* ]]; then
    printf 'incomplete-candidate\n' > "${STATE_FILE}"
    if [[ "${TEST_MENU_OUTCOME}" == execute-fail ]]; then return 1; fi
    read_line_or_cancel MENU_TEST_WAIT 'EXECUTION-WAIT: ' || return $?
    return 9
  fi
  write_state_file || return 1
  generation_commit || return 1
  printf '%s\t%s\n' "${XHTTP_PATH}" "${ENABLE_WARP}" >> "${TEST_MENU_ROOT}/applied.tsv"
}
main_menu
