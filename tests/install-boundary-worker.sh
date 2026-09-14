#!/usr/bin/env bash
# install-boundary.py 的隔离进程；问答、任务派发、确认、草稿与锁使用真实实现。
set -Eeuo pipefail

: "${TEST_BOUNDARY_ROOT:?由 install-boundary.py 设置测试目录}"
: "${TEST_BOUNDARY_TASK:?}"
# shellcheck disable=SC1090
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_functions

if [[ "${1:-}" == seed ]]; then
  if [[ "${TEST_BOUNDARY_TASK}" != fresh ]]; then
    mkdir -p "${XRAY_CONFIG_DIR}"
    SERVER_IP=198.51.100.10
    NODE_LABEL_PREFIX=TEST
    REALITY_UUID=11111111-1111-4111-8111-111111111111
    XHTTP_UUID=22222222-2222-4222-8222-222222222222
    REALITY_SNI=reality.example.com
    REALITY_TARGET=reality.example.com:443
    REALITY_SHORT_ID=abcd1234
    REALITY_PRIVATE_KEY=wAheTQX7Smg0ISm7KVrsW_cAssW_3kDeQmmsxUOAtXI
    REALITY_PUBLIC_KEY=LTJN8tMabPnOjVqx9oUoqDljaaABtPFoeMP0SJW_bCU
    XHTTP_DOMAIN=cdn.example.test
    XHTTP_PATH=/original-path
    CERT_MODE=self-signed
    ENABLE_NET_OPT=no
    NET_BBR_KERNEL=none
    ENABLE_WARP=no
    ROUTE_BLOCK_CN=no
    NGINX_MAIN_MANAGED=no
    state_file_text > "${STATE_FILE}"
    chmod 0600 "${STATE_FILE}"
    if [[ "${TEST_BOUNDARY_TASK}" == resume ]]; then
      INSTALL_TASK=fresh
      write_install_draft_file
      rm "${STATE_FILE}"
    fi
  fi
  exit 0
fi

# 只隔离外部环境和确认后的执行；不替换任何输入、确认或备份函数。
guess_server_ip() { printf '198.51.100.10'; }
systemctl() {
  case "${1:-}" in
    show) printf 'LoadState=not-found\nActiveState=inactive\nUnitFileState=\n' ;;
    is-active|is-enabled) return 1 ;;
    daemon-reload) printf 'daemon-reload\n' >> "${TEST_BOUNDARY_ROOT}/recovery-actions.log" ;;
    *) printf 'systemctl %s\n' "$*" >> "${TEST_BOUNDARY_ROOT}/side-effects.log"; return 99 ;;
  esac
}
ss() { :; }
apt-get() { printf 'apt-get %s\n' "$*" >> "${TEST_BOUNDARY_ROOT}/side-effects.log"; return 99; }
useradd() { printf 'useradd\n' >> "${TEST_BOUNDARY_ROOT}/side-effects.log"; return 99; }

# 观察每次预览的身份，仍调用真实摘要与确认页面。
eval "$(declare -f install_summary_text | sed '1s/install_summary_text/boundary_real_install_summary/')"
BOUNDARY_PREVIEW_COUNT=0
install_summary_text() {
  BOUNDARY_PREVIEW_COUNT=$((BOUNDARY_PREVIEW_COUNT + 1))
  install_draft_file_text > "${TEST_BOUNDARY_ROOT}/preview-${BOUNDARY_PREVIEW_COUNT}.env"
  boundary_real_install_summary
}
install_prepare_and_preflight() {
  printf 'confirmed\n' >> "${TEST_BOUNDARY_ROOT}/execution.log"
  install_record_stage "测试在确认后的依赖准备入口停止"
  [[ "${TEST_BOUNDARY_OUTCOME:-}" != execute-* ]] || return 0
  return 1
}
install_xray_runtime() {
  mkdir -p "${XRAY_CONFIG_DIR}"
  printf 'new-uncommitted-config\n' > "${XRAY_CONFIG_FILE}"
  if [[ "${TEST_BOUNDARY_OUTCOME}" == execute-exit ]]; then exit 7; fi
  read_line_or_cancel BOUNDARY_INTERRUPT "执行中断测试: "
  return 99
}

case "${1:-cli}" in
  cli) run_cli_command install --task "${TEST_BOUNDARY_TASK}" ;;
  menu) menu_install_task ;;
  *) exit 2 ;;
esac
