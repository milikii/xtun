#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TEST_WARP_PRIVATE_KEY="eHR1bi10ZXN0LXdhcnAtcHJpdmF0ZS1rZXktMzJieXQ="
TEST_WARP_PEER_PUBLIC_KEY="eHR1bi10ZXN0LXdhcnAtcGVlci1wdWJsaWMta2V5LTM="

TEST_SANDBOX_ROOT="${TEST_SANDBOX_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/xtun-test-sandbox.XXXXXX")}"

prepare_test_sandbox_root() {
  # ------------------------------
  # 真实 xray 二进制以软链接进沙箱
  # 用例照旧能跑 xray vlessenc / -test，
  # 而卸载、回滚类用例删掉的只是这条软链
  # ------------------------------
  install -d -m 0755 "${TEST_SANDBOX_ROOT}/usr/local/bin"
  if [[ -x /usr/local/bin/xray && ! -e "${TEST_SANDBOX_ROOT}/usr/local/bin/xray" ]]; then
    ln -s /usr/local/bin/xray "${TEST_SANDBOX_ROOT}/usr/local/bin/xray"
  fi
}

prepare_test_sandbox_root

# 下列路径变量由 source 进来的 xtun.sh 各层使用
# shellcheck disable=SC2034
sandbox_managed_paths() {
  # ------------------------------
  # 把全部托管路径改写到临时沙箱
  # 测试若以 root 运行，回滚/卸载类用例会真的删文件，
  # 这里保证它们永远删不到真实部署
  # ------------------------------
  local root="${TEST_SANDBOX_ROOT}"

  [[ -n "${root}" ]] || return 0

  SELF_INSTALL_DIR="${root}/usr/local/lib/xtun"
  SELF_COMMAND_PATH="${root}/usr/local/sbin/xtun"
  XRAY_BIN="${root}/usr/local/bin/xray"
  XRAY_CONFIG_DIR="${root}/usr/local/etc/xray"
  XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
  XRAY_ASSET_DIR="${root}/usr/local/share/xray"
  XRAY_SERVICE_FILE="${root}/etc/systemd/system/xray.service"
  XRAY_LOGROTATE_FILE="${root}/etc/logrotate.d/xtun"
  STATE_FILE="${XRAY_CONFIG_DIR}/node-meta.env"
  HEALTH_STATE_FILE="${XRAY_CONFIG_DIR}/health-state.env"
  HEALTH_HISTORY_FILE="${XRAY_CONFIG_DIR}/health-history.log"
  WARP_RULES_FILE="${XRAY_CONFIG_DIR}/warp-domains.list"
  HAPROXY_CONFIG="${root}/etc/haproxy/haproxy.cfg"
  NGINX_CONF_DIR="${root}/etc/nginx/conf.d"
  NGINX_CONFIG_FILE="${NGINX_CONF_DIR}/xtun.conf"
  NGINX_SERVICE_FILE="${root}/lib/systemd/system/nginx.service"
  FALLBACK_SITE_DIR="${root}/var/www/xtun-fallback"
  SSL_DIR="${root}/etc/ssl/xtun"
  TLS_CERT_FILE="${SSL_DIR}/cert.pem"
  TLS_KEY_FILE="${SSL_DIR}/key.pem"
  CORE_HEALTH_HELPER="${root}/usr/local/sbin/xtun-core-health.sh"
  CORE_HEALTH_SERVICE_FILE="${root}/etc/systemd/system/${CORE_HEALTH_SERVICE_NAME}"
  CORE_HEALTH_TIMER_FILE="${root}/etc/systemd/system/${CORE_HEALTH_TIMER_NAME}"
  NET_SYSCTL_CONF="${root}/etc/sysctl.d/98-xtun-net.conf"
  NET_HELPER_PATH="${root}/usr/local/sbin/xtun-net-optimize.sh"
  NET_SERVICE_FILE="${root}/etc/systemd/system/${NET_SERVICE_NAME}"
  ACME_HOME="${root}/root/.acme.sh"
  ACME_SH_BIN="${ACME_HOME}/acme.sh"
  ACME_RELOAD_HELPER="${root}/usr/local/sbin/xtun-cert-reload.sh"
  OP_LOG_DIR="${root}/var/log/xtun"
  OP_LOG_FILE="${OP_LOG_DIR}/operations.log"
  OUTPUT_FILE="${root}/root/xtun-output.md"
  SUBSCRIPTION_DIR="${root}/root/xtun-subscriptions"
  SUBSCRIPTION_RAW_FILE="${SUBSCRIPTION_DIR}/vless-raw.txt"
  SUBSCRIPTION_BASE64_FILE="${SUBSCRIPTION_DIR}/vless-base64.txt"
  SUBSCRIPTION_MANIFEST_FILE="${SUBSCRIPTION_DIR}/manifest.txt"
  SUBSCRIPTION_QR_DIR="${SUBSCRIPTION_DIR}/qr"
  SUBSCRIPTION_RAW_QR_FILE="${SUBSCRIPTION_QR_DIR}/vless-raw.png"
  SUBSCRIPTION_BASE64_QR_FILE="${SUBSCRIPTION_QR_DIR}/vless-base64.png"
  BACKUP_ROOT="${root}/root/xtun-backups"
  INSTALL_DRAFT_FILE="${root}/root/.xtun-install-draft.env"
  SCRIPT_LOCK_FILE="${root}/run/xtun.lock"
}

load_functions() {
  # ------------------------------
  # 只加载函数定义，不执行 main
  # 这样 smoke test 可以直接调用内部生成器
  # ------------------------------
  # shellcheck disable=SC1090
  source <(sed '$d' "${ROOT_DIR}/xtun.sh")
  sandbox_managed_paths
}

prepare_workspace() {
  local workdir="${1}"

  XRAY_CONFIG_DIR="${workdir}/xray"
  XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
  STATE_FILE="${XRAY_CONFIG_DIR}/node-meta.env"
  OUTPUT_FILE="${workdir}/output.md"
  SUBSCRIPTION_DIR="${workdir}/subscriptions"
  SUBSCRIPTION_RAW_FILE="${SUBSCRIPTION_DIR}/vless-raw.txt"
  SUBSCRIPTION_BASE64_FILE="${SUBSCRIPTION_DIR}/vless-base64.txt"
  SUBSCRIPTION_MANIFEST_FILE="${SUBSCRIPTION_DIR}/manifest.txt"
  SUBSCRIPTION_QR_DIR="${SUBSCRIPTION_DIR}/qr"
  SUBSCRIPTION_RAW_QR_FILE="${SUBSCRIPTION_QR_DIR}/vless-raw.png"
  SUBSCRIPTION_BASE64_QR_FILE="${SUBSCRIPTION_QR_DIR}/vless-base64.png"
  mkdir -p "${XRAY_CONFIG_DIR}"
}

reset_feature_defaults() {
  XHTTP_ECH_CONFIG_LIST="${DEFAULT_XHTTP_ECH_CONFIG_LIST}"
  XHTTP_ECH_FORCE_QUERY="${DEFAULT_XHTTP_ECH_FORCE_QUERY}"
  XHTTP_ECH_ENABLED=""
  XHTTP_XPADDING_ENABLED="${DEFAULT_XHTTP_XPADDING_ENABLED}"
  XHTTP_XPADDING_KEY="${DEFAULT_XHTTP_XPADDING_KEY}"
  XHTTP_XPADDING_HEADER="${DEFAULT_XHTTP_XPADDING_HEADER}"
  XHTTP_XPADDING_PLACEMENT="${DEFAULT_XHTTP_XPADDING_PLACEMENT}"
  XHTTP_XPADDING_METHOD="${DEFAULT_XHTTP_XPADDING_METHOD}"
  REALITY_URI=""
  XHTTP_URI=""
  XHTTP_SPLIT_URI=""
  XHTTP_REALITY_URI=""
  XHTTP_REVERSE_SPLIT_URI=""
  NODE_CLIENTS_TEXT=""
  OUTPUT_CLIENT_NAME=""
  LINK_CLIENT_NAME=""
  LINK_REALITY_UUID=""
  LINK_XHTTP_UUID=""
}

stub_side_effects() {
  ensure_managed_permissions() { :; }
  backup_path() { :; }
}

set_test_warp_credentials() {
  WARP_PRIVATE_KEY="${TEST_WARP_PRIVATE_KEY}"
  WARP_ADDRESS_V4="172.16.0.2"
  WARP_ADDRESS_V6="2606:4700:110:8a1b:cafe:1:2:3"
  WARP_PEER_PUBLIC_KEY="${TEST_WARP_PEER_PUBLIC_KEY}"
  WARP_ENDPOINT="${DEFAULT_WARP_ENDPOINT}"
  WARP_RESERVED="3,4,5"
  WARP_MTU="${DEFAULT_WARP_MTU}"
  WARP_PROFILE_SOURCE=""
}

clear_test_warp_credentials() {
  WARP_PRIVATE_KEY=""
  WARP_ADDRESS_V4=""
  WARP_ADDRESS_V6=""
  WARP_PEER_PUBLIC_KEY="${DEFAULT_WARP_PEER_PUBLIC_KEY}"
  WARP_ENDPOINT="${DEFAULT_WARP_ENDPOINT}"
  WARP_RESERVED=""
  WARP_MTU="${DEFAULT_WARP_MTU}"
  WARP_PROFILE_SOURCE=""
}

capture_function_definition() {
  local fn_name="${1}"

  declare -f "${fn_name}" 2>/dev/null || true
}

restore_function_definition() {
  local definition="${1:-}"

  [[ -n "${definition}" ]] || return 0
  eval "${definition}"
}

assert_contains() {
  local pattern="${1}"
  local path="${2}"

  grep -q -- "${pattern}" "${path}"
}
