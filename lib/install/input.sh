# shellcheck shell=bash

# ------------------------------
# 安装输入与预检层
# 负责交互输入、参数规范化与安装前校验
# ------------------------------

prepare_install_inputs() {
  local guessed_ip=""

  guessed_ip="$(guess_server_ip)"

  prompt_with_default SERVER_IP "REALITY 直连节点地址或 IP" "${guessed_ip}"
  prompt_with_default NODE_LABEL_PREFIX "导出链接使用的节点名前缀" "$(default_node_label_prefix)"
  prompt_with_default REALITY_UUID "REALITY UUID" "$(random_uuid)"
  prompt_with_default REALITY_SNI "REALITY 可见 SNI" "${DEFAULT_REALITY_SNI}"
  prompt_with_default REALITY_TARGET "REALITY 目标地址 host:port" "$(default_reality_target_for_sni "${REALITY_SNI}")"
  prompt_with_default REALITY_SHORT_ID "REALITY 短 ID" "$(random_hex 8)"
  prompt_with_default XHTTP_UUID "XHTTP UUID" "$(random_uuid)"
  prompt_with_default XHTTP_DOMAIN "XHTTP CDN 域名" ""
  prompt_with_default XHTTP_PATH "XHTTP 路径" "$(random_path)"
  prompt_yes_no XHTTP_VLESS_ENCRYPTION_ENABLED "是否启用 XHTTP CDN 的 VLESS Encryption？ [y/n]" "y"
  XHTTP_VLESS_ENCRYPTION_ENABLED="$(normalize_yes_no_value "XHTTP_VLESS_ENCRYPTION_ENABLED" "${XHTTP_VLESS_ENCRYPTION_ENABLED}")"
  XHTTP_ECH_ENABLED="${XHTTP_ECH_ENABLED:-$(if [[ -n "${XHTTP_ECH_CONFIG_LIST:-}" ]]; then printf 'yes'; else printf 'no'; fi)}"
  prompt_yes_no XHTTP_ECH_ENABLED "是否启用 XHTTP CDN 的 ECH？ [y/n]" "n"
  configure_xhttp_ech_from_toggle
  prompt_yes_no XHTTP_XPADDING_ENABLED "是否启用 XHTTP xpadding？ [y/n]" "n"
  XHTTP_XPADDING_ENABLED="$(normalize_yes_no_value "XHTTP_XPADDING_ENABLED" "${XHTTP_XPADDING_ENABLED}")"
  if [[ "${XHTTP_XPADDING_ENABLED}" == "yes" ]]; then
    prompt_xhttp_xpadding_settings
  fi
  prompt_cert_mode_selection "TLS 证书模式序号" "self-signed"
  prompt_cert_mode_inputs

  prompt_yes_no ENABLE_NET_OPT "是否启用网络优化？ [y/n]" "y"
  ENABLE_NET_OPT="$(normalize_yes_no_value "ENABLE_NET_OPT" "${ENABLE_NET_OPT}")"

  NODE_LABEL_PREFIX="$(normalize_node_label_prefix "${NODE_LABEL_PREFIX}")"

  prompt_yes_no ENABLE_WARP "是否启用选择性 WARP 出站？ [y/n]" "y"
  ENABLE_WARP="$(normalize_yes_no_value "ENABLE_WARP" "${ENABLE_WARP}")"
  if [[ "${ENABLE_WARP}" == "yes" ]]; then
    prompt_warp_settings
  fi
}

configure_xhttp_ech_from_toggle() {
  local enabled=""

  enabled="$(normalize_yes_no_value "XHTTP_ECH_ENABLED" "${XHTTP_ECH_ENABLED:-$(if [[ -n "${XHTTP_ECH_CONFIG_LIST:-}" ]]; then printf 'yes'; else printf 'no'; fi)}")"
  if [[ "${enabled}" == "yes" ]]; then
    XHTTP_ECH_CONFIG_LIST="${XHTTP_ECH_CONFIG_LIST:-cloudflare-ech.com+https://223.5.5.5/dns-query}"
    XHTTP_ECH_FORCE_QUERY="${XHTTP_ECH_FORCE_QUERY:-none}"
    return
  fi

  XHTTP_ECH_CONFIG_LIST=""
  XHTTP_ECH_FORCE_QUERY=""
}

prompt_xhttp_xpadding_settings() {
  prompt_with_default XHTTP_XPADDING_KEY "XHTTP xpadding 参数名" "${XHTTP_XPADDING_KEY:-${DEFAULT_XHTTP_XPADDING_KEY}}"
  prompt_with_default XHTTP_XPADDING_HEADER "XHTTP xpadding Header 名" "${XHTTP_XPADDING_HEADER:-${DEFAULT_XHTTP_XPADDING_HEADER}}"
  prompt_with_default XHTTP_XPADDING_PLACEMENT "XHTTP xpadding placement" "${XHTTP_XPADDING_PLACEMENT:-${DEFAULT_XHTTP_XPADDING_PLACEMENT}}"
  prompt_with_default XHTTP_XPADDING_METHOD "XHTTP xpadding method" "${XHTTP_XPADDING_METHOD:-${DEFAULT_XHTTP_XPADDING_METHOD}}"
}

default_reality_target_for_sni() {
  local sni="${1}"
  [[ -n "${sni}" ]] || return 0
  printf '%s:443' "${sni}"
}

normalize_yes_no_value() {
  local field_name="${1}"
  local raw_value="${2}"
  local value=""

  value="$(printf '%s' "${raw_value}" | tr 'A-Z' 'a-z')"
  case "${value}" in
    y|yes|enable|enabled)
      printf 'yes'
      ;;
    n|no|disable|disabled)
      printf 'no'
      ;;
    *)
      die "${field_name} 只能是 yes 或 no。"
      ;;
  esac
}

normalize_warp_target_mode() {
  local value=""

  value="$(printf '%s' "${1}" | tr 'A-Z' 'a-z')"
  case "${value}" in
    yes|enable|enabled)
      printf 'enable'
      ;;
    no|disable|disabled)
      printf 'disable'
      ;;
    *)
      die "WARP 操作只能是 enable 或 disable。"
      ;;
  esac
}

validate_cert_mode_value() {
  local value=""

  value="$(normalize_cert_mode "${1}")"
  case "${value}" in
    self-signed|existing|cf-origin-ca|acme-dns-cf)
      printf '%s' "${value}"
      ;;
    *)
      die "不支持的证书模式：${1}"
      ;;
  esac
}

show_cert_mode_menu() {
  cat <<'EOF'
证书模式:
  1. 自签名
  2. 现有证书
  3. Cloudflare Origin CA
  4. ACME DNS (Cloudflare)
EOF
}

prompt_cert_mode_selection() {
  local prompt_text="${1}"
  local default_mode="${2}"
  local default_choice=""

  default_choice="$(cert_mode_choice_value "${default_mode}")"
  [[ -n "${CERT_MODE:-}" ]] || show_cert_mode_menu
  prompt_with_default CERT_MODE "${prompt_text}" "${default_choice}"
  CERT_MODE="$(validate_cert_mode_value "${CERT_MODE}")"
}

prompt_warp_settings() {
  resolve_value_source WARP_TEAM_NAME
  resolve_value_source WARP_CLIENT_ID
  resolve_value_source WARP_CLIENT_SECRET
  resolve_value_source WARP_PROXY_PORT
  prompt_with_default WARP_TEAM_NAME "Cloudflare Zero Trust 团队名" "${WARP_TEAM_NAME:-}"
  prompt_with_default WARP_CLIENT_ID "Cloudflare 服务令牌 Client ID" "${WARP_CLIENT_ID:-}"
  prompt_secret WARP_CLIENT_SECRET "Cloudflare 服务令牌 Client Secret"
  prompt_with_default WARP_PROXY_PORT "本地 WARP SOCKS5 端口" "${WARP_PROXY_PORT:-${DEFAULT_WARP_PROXY_PORT}}"
}

default_warp_rules_text() {
  cat <<'EOF'
geosite:google
geosite:youtube
geosite:openai
geosite:netflix
geosite:disney
domain:gemini.google.com
domain:claude.ai
domain:anthropic.com
domain:api.anthropic.com
domain:console.anthropic.com
domain:statsig.anthropic.com
domain:sentry.io
domain:x.com
domain:twitter.com
domain:t.co
domain:twimg.com
domain:github.com
domain:api.github.com
domain:githubcopilot.com
domain:copilot-proxy.githubusercontent.com
domain:origin-tracker.githubusercontent.com
domain:copilot-telemetry.githubusercontent.com
domain:collector.github.com
domain:default.exp-tas.com
EOF
}

normalize_warp_rule_value() {
  local raw_value="${1:-}"
  local trimmed=""

  trimmed="$(printf '%s' "${raw_value}" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -n "${trimmed}" ]] || die "WARP 分流规则不能为空。"
  [[ "${trimmed}" != *[[:space:]]* ]] || die "WARP 分流规则不能包含空白字符：${trimmed}"

  case "${trimmed}" in
    domain:*)
      validate_hostname_value "WARP 域名规则" "${trimmed#domain:}"
      printf '%s' "${trimmed}"
      ;;
    geosite:*)
      [[ "${trimmed#geosite:}" =~ ^[A-Za-z0-9._-]+$ ]] || die "WARP geosite 规则不合法：${trimmed}"
      printf '%s' "${trimmed}"
      ;;
    *)
      validate_hostname_value "WARP 域名规则" "${trimmed}"
      printf 'domain:%s' "${trimmed}"
      ;;
  esac
}

normalize_warp_rules_text() {
  local input_text="${1:-}"
  local line=""
  local normalized_line=""
  local seen=""

  while IFS= read -r line; do
    line="$(printf '%s' "${line}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "${line}" ]] || continue
    [[ "${line}" != \#* ]] || continue
    normalized_line="$(normalize_warp_rule_value "${line}")"

    case $'\n'"${seen}" in
      *$'\n'"${normalized_line}"$'\n'*)
        continue
        ;;
    esac

    seen+="${normalized_line}"$'\n'
    printf '%s\n' "${normalized_line}"
  done <<< "${input_text}"
}

current_warp_rules_text() {
  if [[ -n "${WARP_RULES_TEXT:-}" ]]; then
    printf '%s\n' "${WARP_RULES_TEXT}" | sed '/^$/d'
    return
  fi

  if [[ -f "${WARP_RULES_FILE}" ]]; then
    normalize_warp_rules_text "$(<"${WARP_RULES_FILE}")"
    return
  fi

  default_warp_rules_text
}

write_warp_rules_file() {
  local tmp_file=""
  local rules_text=""

  rules_text="$(normalize_warp_rules_text "$(current_warp_rules_text)")"
  mkdir -p "${XRAY_CONFIG_DIR}"
  backup_path "${WARP_RULES_FILE}"
  tmp_file="$(mktemp "${XRAY_CONFIG_DIR}/.warp-domains.list.tmp.XXXXXX")"
  printf '%s\n' "${rules_text}" > "${tmp_file}"
  mv -f "${tmp_file}" "${WARP_RULES_FILE}"
  chmod 0640 "${WARP_RULES_FILE}"
}

resolve_install_input_sources() {
  resolve_value_source CERT_SOURCE_PEM
  resolve_value_source KEY_SOURCE_PEM
  resolve_value_source WARP_TEAM_NAME
  resolve_value_source WARP_CLIENT_ID
  resolve_value_source WARP_CLIENT_SECRET
  resolve_value_source WARP_PROXY_PORT
  resolve_value_source CF_API_TOKEN
  resolve_value_source CF_DNS_TOKEN
}

preflight_check_port_443() {
  local listeners=""

  if ! command -v ss >/dev/null 2>&1; then
    warn "系统中未找到 ss，已跳过 443 端口占用预检。"
    return 0
  fi

  listeners="$(ss -ltnH '( sport = :443 )' 2>/dev/null || true)"
  [[ -z "${listeners}" ]] && return 0

  if [[ -f "${XRAY_CONFIG_FILE}" || -f "${HAPROXY_CONFIG}" ]]; then
    warn "检测到 443 端口已被当前机器上的现有服务占用，继续执行重装流程。"
    return 0
  fi

  die "预检失败：443 端口已被占用，请先释放端口或确认是否为当前脚本托管服务。"
}

preflight_check_domain_resolution() {
  local domain="${1}"
  local label="${2}"
  local resolved_ip=""

  [[ -n "${domain}" ]] || return 0
  resolved_ip="$(getent ahostsv4 "${domain}" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  if [[ -z "${resolved_ip}" ]]; then
    warn "预检提示：${label} 当前无法解析，后续请确认 DNS 配置。"
    return 0
  fi

  if [[ -n "${SERVER_IP:-}" && "${resolved_ip}" == "${SERVER_IP}" ]]; then
    log_success "${label} 已解析到当前服务器地址：${resolved_ip}"
    return 0
  fi

  warn "预检提示：${label} 当前解析为 ${resolved_ip}，如果使用了 Cloudflare 橙云，这可能是正常现象。"
}

verify_cloudflare_token() {
  local token="${1}"
  local label="${2}"
  local response=""

  [[ -n "${token}" ]] || return 0
  response="$(curl -fsSL https://api.cloudflare.com/client/v4/user/tokens/verify \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' 2>/dev/null || true)"
  if [[ -z "${response}" ]]; then
    warn "预检提示：无法在线校验 ${label}，已跳过权限验证。"
    return 0
  fi

  printf '%s' "${response}" | grep -Eq '"success"[[:space:]]*:[[:space:]]*true' \
    || die "预检失败：${label} 校验未通过。"
  log_success "${label} 校验通过。"
}

run_install_preflight_checks() {
  log_step "执行安装前预检。"
  preflight_check_port_443
  preflight_check_domain_resolution "${XHTTP_DOMAIN}" "XHTTP CDN 域名"

  case "${CERT_MODE}" in
    acme-dns-cf)
      verify_cloudflare_token "${CF_DNS_TOKEN}" "Cloudflare DNS Token"
      ;;
  esac
}

is_valid_hostname() {
  local host="${1:-}"
  local old_ifs=""
  local label=""

  [[ -n "${host}" ]] || return 1
  [[ "${#host}" -le 253 ]] || return 1
  [[ "${host}" != .* && "${host}" != *..* && "${host}" != *. ]] || return 1
  [[ "${host}" =~ ^[A-Za-z0-9.-]+$ ]] || return 1

  old_ifs="${IFS}"
  IFS='.'
  for label in ${host}; do
    [[ -n "${label}" ]] || return 1
    [[ "${#label}" -le 63 ]] || return 1
    [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
  IFS="${old_ifs}"

  return 0
}

validate_hostname_value() {
  local field_name="${1}"
  local host="${2:-}"

  is_valid_hostname "${host}" || die "${field_name} 不是合法域名：${host}"
}

validate_port_value() {
  local field_name="${1}"
  local port="${2:-}"

  [[ "${port}" =~ ^[0-9]+$ ]] || die "${field_name} 必须是 1-65535 之间的端口：${port}"
  (( port >= 1 && port <= 65535 )) || die "${field_name} 必须是 1-65535 之间的端口：${port}"
}

validate_hostport_value() {
  local field_name="${1}"
  local hostport="${2:-}"
  local host=""
  local port=""

  [[ -n "${hostport}" ]] || die "${field_name} 不能为空。"
  [[ "${hostport}" == *:* ]] || die "${field_name} 必须是 host:port 格式：${hostport}"
  host="${hostport%:*}"
  port="${hostport##*:}"
  [[ -n "${host}" && -n "${port}" ]] || die "${field_name} 必须是 host:port 格式：${hostport}"

  if ! is_ipv4 "${host}"; then
    validate_hostname_value "${field_name}" "${host}"
  fi
  validate_port_value "${field_name}" "${port}"
}

ensure_reality_sni_format() {
  validate_hostname_value "REALITY SNI" "${REALITY_SNI}"
}

ensure_xhttp_domain_format() {
  validate_hostname_value "XHTTP CDN 域名" "${XHTTP_DOMAIN}"
}

ensure_reality_target_format() {
  validate_hostport_value "REALITY 目标地址" "${REALITY_TARGET}"
}

ensure_xhttp_path_format() {
  [[ -n "${XHTTP_PATH}" ]] || die "XHTTP 路径不能为空。"
  [[ "${XHTTP_PATH}" == /* ]] || die "XHTTP 路径必须以 / 开头。"
  [[ "${XHTTP_PATH}" != *$'\n'* && "${XHTTP_PATH}" != *$'\r'* ]] || die "XHTTP 路径不能包含换行。"
  [[ "${XHTTP_PATH}" != *'"'* ]] || die "XHTTP 路径不能包含双引号。"
  [[ "${XHTTP_PATH}" != *'\\'* ]] || die "XHTTP 路径不能包含反斜杠。"
  [[ "${XHTTP_PATH}" != *[[:space:]]* ]] || die "XHTTP 路径不能包含空白字符。"
}

ensure_xhttp_ech_format() {
  [[ "${XHTTP_ECH_CONFIG_LIST}" != *$'\n'* && "${XHTTP_ECH_CONFIG_LIST}" != *$'\r'* ]] || die "XHTTP ECH 配置不能包含换行。"
  [[ "${XHTTP_ECH_FORCE_QUERY}" != *$'\n'* && "${XHTTP_ECH_FORCE_QUERY}" != *$'\r'* ]] || die "XHTTP ECH 强制查询模式不能包含换行。"
}

ensure_xhttp_xpadding_format() {
  XHTTP_XPADDING_ENABLED="$(normalize_yes_no_value "XHTTP_XPADDING_ENABLED" "${XHTTP_XPADDING_ENABLED:-${DEFAULT_XHTTP_XPADDING_ENABLED}}")"
  if [[ "${XHTTP_XPADDING_ENABLED}" != "yes" ]]; then
    return
  fi

  [[ -n "${XHTTP_XPADDING_KEY}" ]] || die "XHTTP xpadding 参数名不能为空。"
  [[ -n "${XHTTP_XPADDING_HEADER}" ]] || die "XHTTP xpadding Header 名不能为空。"
  [[ "${XHTTP_XPADDING_KEY}" =~ ^[A-Za-z0-9._-]+$ ]] || die "XHTTP xpadding 参数名只能包含字母、数字、点、下划线或横线。"
  [[ "${XHTTP_XPADDING_HEADER}" =~ ^[A-Za-z0-9._-]+$ ]] || die "XHTTP xpadding Header 名只能包含字母、数字、点、下划线或横线。"
  case "${XHTTP_XPADDING_PLACEMENT}" in
    cookie|header|query|queryInHeader) ;;
    *) die "XHTTP xpadding placement 只能是 cookie、header、query 或 queryInHeader。" ;;
  esac
  case "${XHTTP_XPADDING_METHOD}" in
    repeat-x|tokenish) ;;
    *) die "XHTTP xpadding method 只能是 repeat-x 或 tokenish。" ;;
  esac
}

ensure_warp_proxy_port_format() {
  validate_port_value "WARP 本地 SOCKS5 端口" "${WARP_PROXY_PORT}"
}

validate_install_inputs() {
  ensure_reality_sni_format
  ensure_reality_target_format
  ensure_xhttp_domain_format
  ensure_xhttp_path_format
  ensure_xhttp_ech_format
  ensure_xhttp_xpadding_format

  if [[ "${ENABLE_WARP:-no}" == "yes" ]]; then
    [[ -n "${WARP_TEAM_NAME}" ]] || die "启用 WARP 时必须提供团队名。"
    [[ -n "${WARP_CLIENT_ID}" ]] || die "启用 WARP 时必须提供 Client ID。"
    [[ -n "${WARP_CLIENT_SECRET}" ]] || die "启用 WARP 时必须提供 Client Secret。"
    ensure_warp_proxy_port_format
  fi
}
