#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TEST_WARP_PRIVATE_KEY="eHR1bi10ZXN0LXdhcnAtcHJpdmF0ZS1rZXktMzJieXQ="
TEST_WARP_PEER_PUBLIC_KEY="eHR1bi10ZXN0LXdhcnAtcGVlci1wdWJsaWMta2V5LTM="

TEST_SANDBOX_ROOT="${TEST_SANDBOX_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/xtun-test-sandbox.XXXXXX")}"

# ------------------------------
# 宿主机依赖
# 沙箱里的 xray 是宿主机真实二进制的软链，用例会真的去跑
# xray vlessenc / x25519 / run -test，所以宿主机必须先装了 xray。
# 以前宿主机没有 xray 时，下面那个软链只是静默地不建，然后一路跑到第 4 条用例，
# 才在 lib/install.sh 里炸出一句 "No such file or directory"——
# CI 正是这样连红了六个提交，而本机因为是生产节点、装着 xray，85 条全绿。
# 缺什么现在开跑前一次说清楚。
# ------------------------------
TEST_HOST_XRAY_BIN="${TEST_HOST_XRAY_BIN:-/usr/local/bin/xray}"

require_test_host_tools() {
  local missing=""
  local tool=""

  [[ -x "${TEST_HOST_XRAY_BIN}" ]] \
    || missing+="  ${TEST_HOST_XRAY_BIN}（xray 可执行文件，用例要真的跑 vlessenc / x25519 / run -test）"$'\n'

  for tool in jq openssl; do
    command -v "${tool}" >/dev/null 2>&1 || missing+="  ${tool}"$'\n'
  done

  [[ -n "${missing}" ]] || return 0

  printf '[fail] 这套测试对宿主机有硬依赖，下面这些没找到：\n%s' "${missing}" >&2
  printf '[fail] 装上再跑。CI 里由 .github/workflows/ci.yml 的 Install Xray-core 步骤负责。\n' >&2
  exit 1
}

prepare_test_sandbox_root() {
  # ------------------------------
  # 真实 xray 二进制以软链接进沙箱
  # 用例照旧能跑 xray vlessenc / -test，
  # 而卸载、回滚类用例删掉的只是这条软链
  # ------------------------------
  install -d -m 0755 "${TEST_SANDBOX_ROOT}/usr/local/bin"
  if [[ ! -e "${TEST_SANDBOX_ROOT}/usr/local/bin/xray" ]]; then
    ln -s "${TEST_HOST_XRAY_BIN}" "${TEST_SANDBOX_ROOT}/usr/local/bin/xray"
  fi
}

require_test_host_tools
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
  NGINX_MAIN_CONFIG="${root}/etc/nginx/nginx.conf"
  NGINX_CONFIG_FILE="${NGINX_CONF_DIR}/xtun.conf"
  NGINX_LIMITS_DROPIN_FILE="${root}/etc/systemd/system/nginx.service.d/xtun-limits.conf"
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

# 写成 `! grep -q ...` 的反向断言不会触发 errexit（shellcheck SC2251），
# 断言失败时用例会若无其事地跑下去。这里显式返回失败。
assert_absent() {
  local pattern="${1}"
  local path="${2}"

  if grep -q -- "${pattern}" "${path}"; then
    printf '[fail] %s 里不该出现 %s\n' "${path}" "${pattern}" >&2
    return 1
  fi
}

# 同一个坑的另一半：写成 `! some_fn arg` 的反向断言也不触发 errexit
# （`!` 的操作数被 set -e 豁免），断言失败时用例照样往下跑到结尾并返回 0。
assert_false() {
  if "$@"; then
    printf '[fail] 期望失败但返回了成功：%s\n' "$*" >&2
    return 1
  fi
}

# 有些「返回假」是被调用的命令自己报错报出来的：退出码一样非 0，
# 但会往 stderr 吐一行（`[ -gt ]` 收到非数字就是这样）。
# 只看退出码的断言分辨不出「判为假」和「炸了」，这里连 stderr 一起看。
assert_false_silently() {
  local stderr=""

  if stderr="$("$@" 2>&1 >/dev/null)"; then
    printf '[fail] 期望失败但返回了成功：%s\n' "$*" >&2
    return 1
  fi
  if [[ -n "${stderr}" ]]; then
    printf '[fail] %s 期望静默返回假，却输出了：%s\n' "$*" "${stderr}" >&2
    return 1
  fi
}
