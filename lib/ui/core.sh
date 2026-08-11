# shellcheck shell=bash

# ------------------------------
# 展示基础层
# 负责通用样式、状态探测与配置自检
# ------------------------------

style_text() {
  local style="${1}"
  local text="${2}"
  printf '%b%s%b' "${style}" "${text}" "${C_RESET}"
}

divider() {
  printf '%s\n' '--------------------------------------------------------------------'
}

panel_row() {
  printf '  %-18s %s\n' "${1}" "${2}"
}

short_value() {
  local value="${1}"
  local head="${2:-8}"
  local tail="${3:-6}"
  local len=0

  len="${#value}"
  if [[ "${len}" -le $((head + tail + 3)) ]]; then
    printf '%s' "${value}"
  else
    printf '%s...%s' "${value:0:head}" "${value: -tail}"
  fi
}

service_active_state() {
  local unit_name="${1}"
  local state=""

  if ! service_exists "${unit_name}"; then
    printf 'not-installed'
    return
  fi

  state="$(systemctl show "${unit_name}" -p ActiveState --value 2>/dev/null || true)"
  if [[ -n "${state}" ]]; then
    printf '%s' "${state}"
  else
    printf 'installed'
  fi
}

service_enable_state() {
  local unit_name="${1}"

  if ! service_exists "${unit_name}"; then
    printf 'not-installed'
    return
  fi

  case "$(systemctl show "${unit_name}" -p UnitFileState --value 2>/dev/null || true)" in
    enabled)
      printf 'enabled'
      ;;
    disabled|masked|static|indirect|generated|transient)
      printf 'installed'
      ;;
    *)
      printf 'installed'
      ;;
  esac
}

service_badge() {
  local state="${1}"

  case "${state}" in
    active)
      style_text "${C_GREEN}" "运行中"
      ;;
    inactive|failed|activating|deactivating)
      case "${state}" in
        inactive) style_text "${C_RED}" "未运行" ;;
        failed) style_text "${C_RED}" "失败" ;;
        activating) style_text "${C_YELLOW}" "启动中" ;;
        deactivating) style_text "${C_YELLOW}" "停止中" ;;
      esac
      ;;
    not-installed)
      style_text "${C_YELLOW}" "未安装"
      ;;
    *)
      style_text "${C_YELLOW}" "${state}"
      ;;
  esac
}

bool_badge() {
  case "${1}" in
    yes|enabled|true)
      style_text "${C_GREEN}" "已启用"
      ;;
    skipped)
      style_text "${C_YELLOW}" "已跳过"
      ;;
    no|disabled|false)
      style_text "${C_YELLOW}" "已禁用"
      ;;
    *)
      style_text "${C_YELLOW}" "${1:-未知}"
      ;;
  esac
}

service_install_state_label() {
  case "${1}" in
    enabled)
      printf '已启用'
      ;;
    installed)
      printf '已安装'
      ;;
    not-installed)
      printf '未安装'
      ;;
    *)
      printf '%s' "${1}"
      ;;
  esac
}

pretty_cert_mode() {
  case "${CERT_MODE:-unknown}" in
    self-signed)
      printf '自签名'
      ;;
    existing)
      printf '现有证书'
      ;;
    cf-origin-ca)
      printf 'Cloudflare Origin CA'
      ;;
    acme-dns-cf)
      printf 'ACME DNS CF'
      ;;
    *)
      printf '%s' "${CERT_MODE:-未知}"
      ;;
  esac
}

xray_version_line() {
  if [[ -x "${XRAY_BIN}" ]]; then
    "${XRAY_BIN}" version 2>/dev/null | head -n 1 || true
  fi
}

listening_port_text() {
  local port="${1}"
  local listeners=""

  if ! command -v ss >/dev/null 2>&1; then
    printf '未探测'
    return
  fi

  listeners="$(ss -ltnH "( sport = :${port} )" 2>/dev/null | awk '{print $4}' | sort -u | paste -sd, -)"
  if [[ -n "${listeners}" ]]; then
    printf '运行中 (%s)' "${listeners}"
  else
    printf '未监听'
  fi
}

is_port_listening() {
  local port="${1}"

  if ! command -v ss >/dev/null 2>&1; then
    return 1
  fi

  ss -ltnH "( sport = :${port} )" 2>/dev/null | grep -q .
}

cert_expiry_text() {
  if [[ ! -f "${TLS_CERT_FILE}" ]]; then
    printf '未找到证书'
    return
  fi

  openssl x509 -in "${TLS_CERT_FILE}" -noout -enddate 2>/dev/null \
    | sed 's/^notAfter=//' \
    | head -n 1
}

latest_backup_label() {
  local latest_path=""

  latest_path="$(ls -1dt "${BACKUP_ROOT}"/* 2>/dev/null | head -n 1 || true)"
  if [[ -n "${latest_path}" ]]; then
    basename "${latest_path}"
  else
    printf '无'
  fi
}

warp_outbound_text() {
  local summary=""

  if [[ "${ENABLE_WARP:-no}" != "yes" ]]; then
    printf '未启用'
    return
  fi

  summary="wireguard"
  [[ -z "${WARP_ADDRESS_V4:-}" ]] || summary+=" · ${WARP_ADDRESS_V4}"
  [[ -z "${WARP_ADDRESS_V6:-}" ]] || summary+=" · ${WARP_ADDRESS_V6}"
  summary+=" · ${WARP_ENDPOINT:-${DEFAULT_WARP_ENDPOINT}}"
  [[ -z "${WARP_RESERVED:-}" ]] || summary+=" · reserved=${WARP_RESERVED}"
  printf '%s' "${summary}"
}

warp_output_addresses_text() {
  local addresses=""

  [[ -z "${WARP_ADDRESS_V4:-}" ]] || addresses="${WARP_ADDRESS_V4}/32"
  if [[ -n "${WARP_ADDRESS_V6:-}" ]]; then
    [[ -z "${addresses}" ]] || addresses+=", "
    addresses+="${WARP_ADDRESS_V6}/128"
  fi

  printf '%s' "${addresses:-未设置}"
}

warp_endpoint_host() {
  local endpoint="${WARP_ENDPOINT:-${DEFAULT_WARP_ENDPOINT}}"

  if [[ "${endpoint}" == *:* ]]; then
    printf '%s' "${endpoint%:*}"
  else
    printf '%s' "${endpoint}"
  fi
}

warp_endpoint_resolve_state() {
  local host=""

  if [[ "${ENABLE_WARP:-no}" != "yes" ]]; then
    printf 'unknown'
    return
  fi

  host="$(warp_endpoint_host)"
  if [[ -z "${host}" ]]; then
    printf 'fail'
    return
  fi
  if is_ipv4 "${host}"; then
    printf 'ok'
    return
  fi
  if ! command -v getent >/dev/null 2>&1; then
    printf 'unknown'
    return
  fi

  if getent ahosts "${host}" 2>/dev/null | grep -q .; then
    printf 'ok'
  else
    printf 'fail'
  fi
}

warp_endpoint_resolve_text() {
  check_badge "$(warp_endpoint_resolve_state)"
}

warp_probe_port() {
  local port=0
  local attempt=0

  while [[ "${attempt}" -lt 20 ]]; do
    port=$((41000 + RANDOM % 4000))
    if ! is_port_listening "${port}"; then
      printf '%s' "${port}"
      return 0
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

warp_egress_probe_text() {
  local port=""
  local config_file=""
  local probe_pid=""
  local ip=""
  local waited=0

  if [[ "${ENABLE_WARP:-no}" != "yes" ]]; then
    printf '未启用'
    return
  fi
  if [[ ! -x "${XRAY_BIN}" ]] || ! command -v curl >/dev/null 2>&1; then
    printf '未探测 (缺少 xray 或 curl)'
    return
  fi
  if [[ -z "${WARP_PRIVATE_KEY:-}" ]]; then
    printf '未探测 (缺少 WireGuard 私钥)'
    return
  fi
  if ! port="$(warp_probe_port)"; then
    printf '未探测 (找不到空闲端口)'
    return
  fi
  if ! config_file="$(mktemp "${TMPDIR:-/tmp}/xtun-warp-probe.XXXXXX.json")"; then
    printf '未探测 (无法创建临时配置)'
    return
  fi

  chmod 0600 "${config_file}"
  if ! jq -cn \
    --argjson outbound "$(xray_warp_outbound_json)" \
    --arg port "${port}" \
    '{
       log: { loglevel: "none" },
       inbounds: [
         {
           listen: "127.0.0.1",
           port: ($port | tonumber),
           protocol: "socks",
           settings: { udp: false }
         }
       ],
       outbounds: [$outbound]
     }' > "${config_file}" 2>/dev/null; then
    rm -f "${config_file}"
    printf '未探测 (生成临时配置失败)'
    return
  fi

  "${XRAY_BIN}" run -c "${config_file}" >/dev/null 2>&1 &
  probe_pid="$!"
  while [[ "${waited}" -lt 40 ]]; do
    is_port_listening "${port}" && break
    sleep 0.1
    waited=$((waited + 1))
  done

  if is_port_listening "${port}"; then
    ip="$(curl --socks5-hostname "127.0.0.1:${port}" \
      -fsSL --max-time 8 https://api.ipify.org 2>/dev/null | tr -d '\r\n')"
  fi

  kill "${probe_pid}" >/dev/null 2>&1 || true
  wait "${probe_pid}" 2>/dev/null || true
  rm -f "${config_file}"

  if [[ -n "${ip}" ]]; then
    printf '%s' "${ip}"
  else
    printf '未探测'
  fi
}

warp_rule_count_text() {
  local count=0

  if [[ -z "${WARP_RULES_TEXT:-}" && ! -f "${WARP_RULES_FILE}" ]]; then
    printf '0'
    return
  fi

  while IFS= read -r _; do
    count=$((count + 1))
  done < <(current_warp_rules_text)

  printf '%s' "${count}"
}

check_badge() {
  case "${1}" in
    ok)
      style_text "${C_GREEN}" "通过"
      ;;
    fail)
      style_text "${C_RED}" "失败"
      ;;
    *)
      style_text "${C_YELLOW}" "${1:-未探测}"
      ;;
  esac
}

xray_config_check_state() {
  if [[ ! -x "${XRAY_BIN}" || ! -f "${XRAY_CONFIG_FILE}" ]]; then
    printf 'unknown'
    return
  fi

  if "${XRAY_BIN}" run -test -config "${XRAY_CONFIG_FILE}" >/dev/null 2>&1; then
    printf 'ok'
  else
    printf 'fail'
  fi
}

xray_config_check_text() {
  check_badge "$(xray_config_check_state)"
}

nginx_config_check_state() {
  if ! command -v nginx >/dev/null 2>&1 || [[ ! -f "${NGINX_CONFIG_FILE}" ]]; then
    printf 'unknown'
    return
  fi

  if nginx -t >/dev/null 2>&1; then
    printf 'ok'
  else
    printf 'fail'
  fi
}

nginx_config_check_text() {
  check_badge "$(nginx_config_check_state)"
}

haproxy_config_check_state() {
  if ! command -v haproxy >/dev/null 2>&1 || [[ ! -f "${HAPROXY_CONFIG}" ]]; then
    printf 'unknown'
    return
  fi

  if haproxy -c -f "${HAPROXY_CONFIG}" >/dev/null 2>&1; then
    printf 'ok'
  else
    printf 'fail'
  fi
}

haproxy_config_check_text() {
  check_badge "$(haproxy_config_check_state)"
}

local_tls_probe_state() {
  if ! command -v openssl >/dev/null 2>&1; then
    printf 'unknown'
    return
  fi

  if [[ -z "${XHTTP_DOMAIN:-}" ]]; then
    printf 'unknown'
    return
  fi

  if echo | openssl s_client -connect 127.0.0.1:443 -servername "${XHTTP_DOMAIN}" >/dev/null 2>&1; then
    printf 'ok'
  else
    printf 'fail'
  fi
}

local_tls_probe_text() {
  check_badge "$(local_tls_probe_state)"
}
