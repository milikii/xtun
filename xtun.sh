#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_ROOT="${ROOT_DIR:-}"
if [[ -z "${SCRIPT_ROOT}" ]]; then
  SCRIPT_SELF="${BASH_SOURCE[0]}"
  case "${SCRIPT_SELF}" in
    /dev/fd/* | /proc/*/fd/*)
      SCRIPT_ROOT="$(pwd)"
      ;;
    *)
      SCRIPT_SELF="$(readlink -f "${SCRIPT_SELF}" 2>/dev/null || printf '%s' "${SCRIPT_SELF}")"
      SCRIPT_ROOT="$(cd "$(dirname "${SCRIPT_SELF}")" && pwd)"
      ;;
  esac
fi

SCRIPT_VERSION="1.1.0"
SELF_INSTALL_DIR_DEFAULT="/usr/local/lib/xtun"
SELF_COMMAND_PATH_DEFAULT="/usr/local/sbin/xtun"
BOOTSTRAP_SELF_INSTALL_DIR="${XTUN_SELF_INSTALL_DIR:-${SELF_INSTALL_DIR_DEFAULT}}"
BOOTSTRAP_REPO_OWNER="${XTUN_BOOTSTRAP_REPO_OWNER:-milikii}"
BOOTSTRAP_REPO_NAME="${XTUN_BOOTSTRAP_REPO_NAME:-xtun}"
BOOTSTRAP_BRANCH_REF="${XTUN_BOOTSTRAP_BRANCH_REF:-main}"
BOOTSTRAP_ARCHIVE_URL="${XTUN_BOOTSTRAP_ARCHIVE_URL:-}"

bootstrap_die() {
  printf '[错误] %s\n' "$*" >&2
  exit 1
}

bundle_root_ready() {
  local root_path="${1}"
  [[ -n "${root_path}" \
    && -f "${root_path}/xtun.sh" \
    && -f "${root_path}/lib/base/helpers.sh" \
    && -f "${root_path}/static/fallback/index.html" ]]
}

bootstrap_default_archive_url() {
  printf 'https://codeload.github.com/%s/%s/tar.gz/%s' \
    "${BOOTSTRAP_REPO_OWNER}" \
    "${BOOTSTRAP_REPO_NAME}" \
    "${BOOTSTRAP_BRANCH_REF}"
}

bootstrap_commit_api_url() {
  printf 'https://api.github.com/repos/%s/%s/commits/%s' \
    "${BOOTSTRAP_REPO_OWNER}" \
    "${BOOTSTRAP_REPO_NAME}" \
    "${BOOTSTRAP_BRANCH_REF}"
}

bootstrap_extract_commit_sha() {
  local metadata_json="${1:-}"
  local commit_sha=""

  commit_sha="$(printf '%s' "${metadata_json}" | grep -Eo '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' | head -n 1 | grep -Eo '[0-9a-f]{40}' || true)"
  printf '%s' "${commit_sha}"
}

bootstrap_resolve_archive_url() {
  local metadata_json=""
  local commit_sha=""

  if [[ -n "${BOOTSTRAP_ARCHIVE_URL}" ]]; then
    printf '%s' "${BOOTSTRAP_ARCHIVE_URL}"
    return
  fi

  metadata_json="$(curl -fsSL -H "Accept: application/vnd.github+json" "$(bootstrap_commit_api_url)" 2>/dev/null || true)"
  commit_sha="$(bootstrap_extract_commit_sha "${metadata_json}")"
  if [[ "${commit_sha}" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'https://codeload.github.com/%s/%s/tar.gz/%s' \
      "${BOOTSTRAP_REPO_OWNER}" \
      "${BOOTSTRAP_REPO_NAME}" \
      "${commit_sha}"
    return
  fi

  bootstrap_default_archive_url
}

exec_bundle_root() {
  local bundle_root="${1}"
  shift

  exec env \
    ROOT_DIR="${bundle_root}" \
    XTUN_COMMAND_NAME="${XTUN_COMMAND_NAME:-$(basename "$0")}" \
    bash "${bundle_root}/xtun.sh" "$@"
}

bootstrap_known_command() {
  case "${1:-menu}" in
    menu|install|update-script|upgrade|recover|check-sni|change-uuid|change-sni|change-path|change-h3|change-warp|change-warp-rules|change-cert-mode|renew-cert|uninstall|show-links|diagnose|status|restart|repair-perms|apply-config|apply-net-opt|version|--version|-v|help|--help|-h)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bootstrap_local_usage() {
  local command_name="${XTUN_COMMAND_NAME:-$(basename "${0}")}"

  printf 'xtun.sh v%s\n\n' "${SCRIPT_VERSION}"
  printf '用法:\n'
  printf '  %s [command]\n\n' "${command_name}"
  printf '常用命令:\n'
  printf '  install             安装或重装\n'
  printf '  status              查看状态\n'
  printf '  diagnose            运行诊断\n'
  printf '  show-links          查看节点链接\n'
  printf '  check-sni           检查 SNI 目标\n'
  printf '  help                显示帮助\n'
  printf '  version             显示版本\n'
}

bootstrap_dispatch_local_entry() {
  local command="${1:-menu}"

  case "${command}" in
    help|--help|-h)
      bootstrap_local_usage
      exit 0
      ;;
    version|--version|-v)
      printf 'xtun.sh v%s\n' "${SCRIPT_VERSION}"
      exit 0
      ;;
    *)
      if ! bootstrap_known_command "${command}"; then
        printf '[错误] 未知命令：%s\n' "${command}" >&2
        exit 1
      fi
      ;;
  esac
}

bootstrap_run_temp_bundle() {
  local bundle_root="${1}"
  local tmp_dir="${2}"
  local status=0

  shift 2
  env \
    ROOT_DIR="${bundle_root}" \
    XTUN_COMMAND_NAME="${XTUN_COMMAND_NAME:-$(basename "${0}")}" \
    bash "${bundle_root}/xtun.sh" "$@" || status=$?
  if ! rm -rf "${tmp_dir}" 2>/dev/null; then
    printf '[错误] 清理临时目录失败：%s\n' "${tmp_dir}" >&2
    [[ "${status}" -ne 0 ]] || status=1
  fi
  exit "${status}"
}

bootstrap_script_root_if_needed() {
  local bundle_root=""
  local tmp_dir=""
  local archive_path=""
  local archive_url=""

  bundle_root_ready "${SCRIPT_ROOT}" && return 0

  if bundle_root_ready "${XTUN_BOOTSTRAP_ROOT:-}"; then
    exec_bundle_root "${XTUN_BOOTSTRAP_ROOT}" "$@"
  fi

  bootstrap_dispatch_local_entry "$@"

  command -v curl >/dev/null 2>&1 || bootstrap_die "当前目录缺少 lib/，且系统中未找到 curl，无法自动拉取脚本 bundle。"
  command -v tar >/dev/null 2>&1 || bootstrap_die "当前目录缺少 lib/，且系统中未找到 tar，无法自动拉取脚本 bundle。"

  tmp_dir="$(mktemp -d)"
  archive_path="${tmp_dir}/xtun.tar.gz"
  archive_url="$(bootstrap_resolve_archive_url)"
  if curl -fsSL "${archive_url}" -o "${archive_path}" && tar -xzf "${archive_path}" -C "${tmp_dir}"; then
    bundle_root="$(find "${tmp_dir}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    if bundle_root_ready "${bundle_root}"; then
      bootstrap_run_temp_bundle "${bundle_root}" "${tmp_dir}" "$@"
    fi
  fi

  rm -rf "${tmp_dir}"

  if bundle_root_ready "${BOOTSTRAP_SELF_INSTALL_DIR}"; then
    exec_bundle_root "${BOOTSTRAP_SELF_INSTALL_DIR}" "$@"
  fi

  bootstrap_die "自动下载脚本 bundle 失败，且本机也没有可用的已安装 bundle。"
}

bootstrap_script_root_if_needed "$@"
# 操作日志默认关闭：只有 begin_mutation 之后的写操作才允许追加记录。
OPERATION_LOG_ENABLED=0
STATE_VERSION_CURRENT="2"
DEFAULT_WARP_PEER_PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
DEFAULT_WARP_ENDPOINT="engage.cloudflareclient.com:2408"
DEFAULT_WARP_MTU="1420"
DEFAULT_WARP_DOMAIN_STRATEGY="ForceIPv4v6"
DEFAULT_WARP_REGISTER_API="https://api.cloudflareclient.com/v0a2158/reg"
DEFAULT_TLS_ALPN="h2"
DEFAULT_FINGERPRINT="chrome"
DEFAULT_XHTTP_VLESS_ENCRYPTION_ENABLED="yes"
DEFAULT_ACME_CA="letsencrypt"
DEFAULT_XHTTP_ECH_CONFIG_LIST=""
DEFAULT_XHTTP_ECH_FORCE_QUERY=""
DEFAULT_XHTTP_XPADDING_ENABLED="no"
DEFAULT_XHTTP_XPADDING_KEY="x_padding"
DEFAULT_XHTTP_XPADDING_HEADER="Referer"
DEFAULT_XHTTP_XPADDING_PLACEMENT="queryInHeader"
DEFAULT_XHTTP_XPADDING_METHOD="tokenish"
DEFAULT_XHTTP_XMUX_MAX_CONCURRENCY="16-32"
DEFAULT_XHTTP_XMUX_C_MAX_REUSE_TIMES="0"
DEFAULT_XHTTP_XMUX_H_MAX_REUSABLE_SECS="1800-3000"
DEFAULT_XHTTP_XMUX_H_KEEP_ALIVE_PERIOD="0"
DEFAULT_XHTTP_SC_MIN_POSTS_INTERVAL_MS="30"
DEFAULT_REALITY_SNI=""
JOEY_BBR_REPO="byJoey/Actions-bbr-v3"
JOEY_BBR_RELEASES_PER_PAGE="100"
XRAY_VERSION_REQUEST="latest-published"
XRAY_SELECTED_TAG=""
XRAY_SELECTED_COMMIT=""
XRAY_SELECTED_ARCHIVE_NAME=""
XRAY_SELECTED_ARCHIVE_URL=""
XRAY_SELECTED_DGST_URL=""
XRAY_SELECTED_EXPECTED_SHA256=""
XRAY_SELECTED_CHECKSUM_SOURCE=""
XRAY_CONTEXT_REQUEST=""
XRAY_CONTEXT_ARCH=""
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
XRAY_ASSET_DIR="/usr/local/share/xray"
XRAY_SERVICE_FILE="/etc/systemd/system/xray.service"
SELF_COMMAND_PATH="${XTUN_SELF_COMMAND_PATH:-${SELF_COMMAND_PATH_DEFAULT}}"
SELF_INSTALL_DIR="${BOOTSTRAP_SELF_INSTALL_DIR}"
HAPROXY_CONFIG="/etc/haproxy/haproxy.cfg"
NGINX_MAIN_CONFIG="/etc/nginx/nginx.conf"
NGINX_CONF_DIR="/etc/nginx/conf.d"
NGINX_CONFIG_FILE="${NGINX_CONF_DIR}/xtun.conf"
NGINX_LIMITS_DROPIN_FILE="/etc/systemd/system/nginx.service.d/xtun-limits.conf"
NGINX_TLS_PORT="8443"
XHTTP_LOCAL_PORT="8001"
REALITY_FALLBACK_PORT="2444"
ROUTE_BLOCK_CN="no"
NGINX_MAIN_MANAGED=""
NET_BBR_KERNEL=""
FALLBACK_SITE_DIR="/var/www/xtun-fallback"
FALLBACK_SITE_SOURCE_DIR="${SCRIPT_ROOT}/static/fallback"
XRAY_LOG_DIR="${XTUN_XRAY_LOG_DIR:-/var/log/xray}"
XRAY_STATE_DIR="${XTUN_XRAY_STATE_DIR:-/var/lib/xray}"
# service_exists 只看这几个目录。做成变量，测试才能把「服务是否存在」
# 沙箱化——在生产机上跑用例时，真实单元文件一直存在，用例会把宿主机当沙箱用。
SYSTEMD_UNIT_DIRS=("/etc/systemd/system" "/lib/systemd/system" "/usr/lib/systemd/system")
STATE_FILE="${XRAY_CONFIG_DIR}/node-meta.env"
OUTPUT_FILE="/root/xtun-output.md"
QR_OUTPUT_DIR="/root/xtun-qr"
SSL_DIR="/etc/ssl/xtun"
TLS_CERT_FILE="${SSL_DIR}/cert.pem"
TLS_KEY_FILE="${SSL_DIR}/key.pem"
WARP_RULES_FILE="${XRAY_CONFIG_DIR}/warp-domains.list"
BACKUP_ROOT="/root/xtun-backups"
# 首次接管原件（例如别人的 nginx 主配置）和可轮转的事务备份分开放，
# 保留规则永远不许动这里。
XTUN_VAR_DIR="${XTUN_VAR_DIR:-/var/lib/xtun}"
ORIGINALS_ROOT="${XTUN_ORIGINALS_ROOT:-${XTUN_VAR_DIR}/originals}"
# 变更中途掉电/被杀留下的未完成操作清单。查看入口只报告它，不自行恢复。
PENDING_OP_FILE="${XTUN_PENDING_OP_FILE:-${XTUN_VAR_DIR}/pending-op.tsv}"
BACKUP_KEEP_COUNT="${XTUN_BACKUP_KEEP_COUNT:-5}"
OP_LOG_DIR="/var/log/xtun"
OP_LOG_FILE="${OP_LOG_DIR}/operations.log"
NET_SYSCTL_CONF="/etc/sysctl.d/98-xtun-net.conf"
NET_HELPER_PATH="/usr/local/sbin/xtun-net-optimize.sh"
NET_SERVICE_NAME="xtun-net-optimize.service"
NET_SERVICE_FILE="/etc/systemd/system/${NET_SERVICE_NAME}"
XRAY_LOGROTATE_FILE="/etc/logrotate.d/xtun"
ACME_HOME="/root/.acme.sh"
ACME_SH_BIN="${ACME_HOME}/acme.sh"
ACME_RELOAD_HELPER="/usr/local/sbin/xtun-cert-reload.sh"
INSTALL_DRAFT_FILE="/root/.xtun-install-draft.env"
SCRIPT_LOCK_FILE="${XTUN_LOCK_FILE:-/run/xtun.lock}"
SCRIPT_LOCK_HELD=0
SCRIPT_LOCK_DIR=""
SESSION_LOG_FILE=""

NON_INTERACTIVE=0
NGINX_RESTART_REQUIRED="no"
ENABLE_WARP=""
ENABLE_NET_OPT=""
H3_INTENT=""
H3_DECISION="off"
NET_BBRV3_REBOOT_REQUIRED="no"
CERT_MODE=""
SERVER_IP=""
SERVER_IP6=""
# 存在性：absent / provided / disabled。空字符串不再兼任「没给」和「明确禁用」。
SERVER_IP_PRESENCE="absent"
SERVER_IP6_PRESENCE="absent"
# 安装任务与本次动作的显式输入登记（D06）。菜单和 CLI 都只往这里填值。
INSTALL_TASK_REQUEST=""
INSTALL_TASK=""
INSTALL_TASK_SOURCE=""
INSTALL_PROVIDED_VARS=" "
INSTALL_CONFIRMED=0
INSTALL_DRAFT_SAVED=0
INSTALL_IDENTITY_ROTATED=0
INSTALL_ROTATE_PREVIOUS_PATH=""
# SNI 预检的「本次动作」事实（D09）：跳过/忽略只对这一次安装有效，
# 既不写 state，也不把失败改写成通过；装完还要再报一次。
SNI_PREFLIGHT_SKIPPED=0
SNI_PREFLIGHT_IGNORED=0
NODE_LABEL_PREFIX=""
REALITY_UUID=""
REALITY_SNI=""
REALITY_TARGET=""
REALITY_SHORT_ID=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
XHTTP_UUID=""
XHTTP_DOMAIN=""
XHTTP_PATH=""
XHTTP_VLESS_ENCRYPTION_ENABLED="${DEFAULT_XHTTP_VLESS_ENCRYPTION_ENABLED}"
XHTTP_VLESS_DECRYPTION=""
XHTTP_VLESS_ENCRYPTION=""
TLS_ALPN="${DEFAULT_TLS_ALPN}"
FINGERPRINT="${DEFAULT_FINGERPRINT}"
WARP_PRIVATE_KEY=""
WARP_ADDRESS_V4=""
WARP_ADDRESS_V6=""
WARP_PEER_PUBLIC_KEY="${DEFAULT_WARP_PEER_PUBLIC_KEY}"
WARP_ENDPOINT="${DEFAULT_WARP_ENDPOINT}"
WARP_RESERVED=""
WARP_MTU="${DEFAULT_WARP_MTU}"
WARP_PROFILE_SOURCE=""
WARP_RULES_TEXT=""
XRAY_UID=""
XRAY_GID=""
CERT_SOURCE_FILE=""
KEY_SOURCE_FILE=""
CERT_SOURCE_PEM=""
KEY_SOURCE_PEM=""
ACME_EMAIL=""
ACME_CA="${DEFAULT_ACME_CA}"
CF_DNS_TOKEN=""
CF_DNS_ACCOUNT_ID=""
CF_DNS_ZONE_ID=""
XHTTP_ECH_CONFIG_LIST="${DEFAULT_XHTTP_ECH_CONFIG_LIST}"
XHTTP_ECH_FORCE_QUERY="${DEFAULT_XHTTP_ECH_FORCE_QUERY}"
XHTTP_ECH_ENABLED=""
XHTTP_XPADDING_ENABLED="${DEFAULT_XHTTP_XPADDING_ENABLED}"
XHTTP_XPADDING_KEY="${DEFAULT_XHTTP_XPADDING_KEY}"
XHTTP_XPADDING_HEADER="${DEFAULT_XHTTP_XPADDING_HEADER}"
XHTTP_XPADDING_PLACEMENT="${DEFAULT_XHTTP_XPADDING_PLACEMENT}"
XHTTP_XPADDING_METHOD="${DEFAULT_XHTTP_XPADDING_METHOD}"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_CYAN=""
fi

. "${SCRIPT_ROOT}/lib/base/helpers.sh"
. "${SCRIPT_ROOT}/lib/base/versions.sh"

. "${SCRIPT_ROOT}/lib/install.sh"
. "${SCRIPT_ROOT}/lib/generators.sh"
. "${SCRIPT_ROOT}/lib/state.sh"
. "${SCRIPT_ROOT}/lib/base/runtime.sh"
. "${SCRIPT_ROOT}/lib/base/generation.sh"

. "${SCRIPT_ROOT}/lib/ui.sh"
. "${SCRIPT_ROOT}/lib/commands.sh"

main() {
  run_cli_command "$@"
}

main "$@"
