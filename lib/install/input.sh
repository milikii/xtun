# shellcheck shell=bash

# ------------------------------
# 安装输入与预检层
# 负责交互输入、参数规范化与安装前校验
# ------------------------------

# 下面每处 `X="$(normalize_... )"` 后面的 `|| exit 1` 都是必须的，别当成噪音删掉：
# 这些 normalize_/validate_ 函数在参数不合法时走的是 die，而 die 是 exit——
# 它跑在 $( ) 的子 shell 里，只能把那个子 shell 打死。错误信息照样印在 stderr 上，
# 但命令替换的结果是空串，赋值把变量留成空，然后函数一路跑完返回 0。
# 于是 `是否启用 WARP？ [y/n]` 那里手一抖打成 "maybe"，屏幕上闪一行错误，
# 安装照常做完、报成功，只是 WARP 静默没装。ENABLE_NET_OPT / xpadding / ECH /
# VLESS Encryption 全是同一个形状。
# errexit 兜不住：dispatch_cli_command 那里是 `... || status=$?`，
# 整棵动态调用树里的 errexit 都被豁免了。
# 纯赋值语句（含数组追加、拼接赋值）的退出码就是最后那个命令替换的退出码，
# 所以 `|| exit 1` 接得住；写成 `local X="$(...)"` 就接不住了（shellcheck SC2155）。
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
  XHTTP_VLESS_ENCRYPTION_ENABLED="$(normalize_yes_no_value "XHTTP_VLESS_ENCRYPTION_ENABLED" "${XHTTP_VLESS_ENCRYPTION_ENABLED}")" || exit 1
  XHTTP_ECH_ENABLED="${XHTTP_ECH_ENABLED:-$(if [[ -n "${XHTTP_ECH_CONFIG_LIST:-}" ]]; then printf 'yes'; else printf 'no'; fi)}"
  prompt_yes_no XHTTP_ECH_ENABLED "是否启用 XHTTP CDN 的 ECH？ [y/n]" "n"
  configure_xhttp_ech_from_toggle
  prompt_yes_no XHTTP_XPADDING_ENABLED "是否启用 XHTTP xpadding？ [y/n]" "n"
  XHTTP_XPADDING_ENABLED="$(normalize_yes_no_value "XHTTP_XPADDING_ENABLED" "${XHTTP_XPADDING_ENABLED}")" || exit 1
  if [[ "${XHTTP_XPADDING_ENABLED}" == "yes" ]]; then
    prompt_xhttp_xpadding_settings
  fi
  prompt_cert_mode_selection "TLS 证书模式序号" "self-signed"
  prompt_cert_mode_inputs

  prompt_yes_no ENABLE_NET_OPT "是否启用网络优化？ [y/n]" "y"
  ENABLE_NET_OPT="$(normalize_yes_no_value "ENABLE_NET_OPT" "${ENABLE_NET_OPT}")" || exit 1

  NODE_LABEL_PREFIX="$(normalize_node_label_prefix "${NODE_LABEL_PREFIX}")"

  prompt_yes_no ENABLE_WARP "是否启用选择性 WARP 出站？ [y/n]" "y"
  ENABLE_WARP="$(normalize_yes_no_value "ENABLE_WARP" "${ENABLE_WARP}")" || exit 1
  if [[ "${ENABLE_WARP}" == "yes" ]]; then
    prompt_warp_settings
  fi
}

configure_xhttp_ech_from_toggle() {
  local enabled=""

  enabled="$(normalize_yes_no_value "XHTTP_ECH_ENABLED" "${XHTTP_ECH_ENABLED:-$(if [[ -n "${XHTTP_ECH_CONFIG_LIST:-}" ]]; then printf 'yes'; else printf 'no'; fi)}")" || exit 1
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

  value="$(printf '%s' "${raw_value}" | tr '[:upper:]' '[:lower:]')"
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

  value="$(printf '%s' "${1}" | tr '[:upper:]' '[:lower:]')"
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
  CERT_MODE="$(validate_cert_mode_value "${CERT_MODE}")" || exit 1
}

prompt_warp_settings() {
  local use_profile="no"

  resolve_value_source WARP_PRIVATE_KEY
  resolve_value_source WARP_PROFILE_SOURCE
  resolve_value_source WARP_RESERVED
  resolve_value_source WARP_ENDPOINT

  if warp_credentials_ready || [[ -n "${WARP_PROFILE_SOURCE}" ]]; then
    return
  fi

  log "WARP 出站由 Xray 内置 wireguard 承载，默认自动注册一台免费 WARP 设备。"
  prompt_yes_no use_profile "是否改为导入已有的 wgcf profile.conf？ [y/n]" "n"
  use_profile="$(normalize_yes_no_value "use_profile" "${use_profile}")" || exit 1
  [[ "${use_profile}" == "yes" ]] || return

  prompt_multiline_value WARP_PROFILE_SOURCE "粘贴 wgcf profile.conf 内容"
  [[ -n "${WARP_PROFILE_SOURCE}" ]] || die "未提供 WARP profile 内容。"
}

default_warp_rules_text() {
  cat <<'EOF'
geosite:openai
domain:chatgpt.com
domain:claude.ai
domain:anthropic.com
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
    normalized_line="$(normalize_warp_rule_value "${line}")" || exit 1

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

# 规则清单打到 stderr，因为编辑器的最终结果要从 stdout 取。
show_warp_rules_list() {
  local index=1
  local rule=""

  if [[ "$#" -eq 0 ]]; then
    printf '%s\n' "  （当前没有任何规则）" >&2
    return
  fi

  for rule in "$@"; do
    printf '  %2s. %s\n' "${index}" "${rule}" >&2
    index=$((index + 1))
  done
}

# 交互输入的规则不能直接丢给 normalize_warp_rule_value：
# 那个函数校验失败就 die，会把整个菜单进程带走。这里先自己挡一道。
warp_rules_editor_normalize() {
  local raw_value="${1:-}"

  [[ -n "${raw_value}" ]] || {
    warn "规则不能为空。"
    return 1
  }
  if [[ "${raw_value}" == *[[:space:]]* ]]; then
    warn "规则不能包含空白字符：${raw_value}"
    return 1
  fi
  case "${raw_value}" in
    geosite:*)
      [[ "${raw_value#geosite:}" =~ ^[A-Za-z0-9._-]+$ ]] || {
        warn "geosite 规则不合法：${raw_value}"
        return 1
      }
      ;;
    *)
      if ! is_valid_hostname "${raw_value#domain:}"; then
        warn "域名规则不合法：${raw_value}"
        return 1
      fi
      ;;
  esac

  normalize_warp_rule_value "${raw_value}"
}

warp_rules_editor_delete() {
  local target="${1}"
  local -n rules_ref="${2}"
  local -a kept=()
  local index=0
  local removed=0
  local rule=""

  if [[ "${target}" =~ ^[0-9]+$ ]]; then
    index=$((target - 1))
    if [[ "${index}" -lt 0 || "${index}" -ge "${#rules_ref[@]}" ]]; then
      warn "序号超出范围：${target}"
      return 1
    fi
    unset "rules_ref[${index}]"
    rules_ref=("${rules_ref[@]+"${rules_ref[@]}"}")
    return 0
  fi

  for rule in "${rules_ref[@]+"${rules_ref[@]}"}"; do
    if [[ "${rule}" == "${target}" || "${rule}" == "domain:${target}" ]]; then
      removed=1
      continue
    fi
    kept+=("${rule}")
  done

  if [[ "${removed}" -eq 0 ]]; then
    warn "找不到规则：${target}"
    return 1
  fi
  rules_ref=("${kept[@]+"${kept[@]}"}")
}

# 菜单 13 的交互界面。放弃退出返回 1，保存时把最终规则打到 stdout。
prompt_warp_rules_editor() {
  local -a rules=()
  local line=""
  local answer=""
  local value=""
  local normalized=""
  local exists=0

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    rules+=("${line}")
  done < <(current_warp_rules_text)

  while true; do
    printf '\n%s\n' "当前 WARP 分流规则（命中的域名走 WARP，其它流量直连）:" >&2
    show_warp_rules_list "${rules[@]+"${rules[@]}"}"
    printf '%s\n' "操作: a=添加  d=删除  r=恢复默认  s=保存并应用  q=放弃退出" >&2
    read -r -p "请选择 [s]: " answer
    answer="$(printf '%s' "${answer:-s}" | tr '[:upper:]' '[:lower:]')"

    case "${answer}" in
      a|add)
        read -r -p "要添加的规则（domain:example.com / geosite:openai / example.com）: " value
        normalized="$(warp_rules_editor_normalize "${value}")" || continue
        exists=0
        for line in "${rules[@]+"${rules[@]}"}"; do
          [[ "${line}" == "${normalized}" ]] || continue
          exists=1
          break
        done
        if [[ "${exists}" -eq 1 ]]; then
          warn "规则已存在：${normalized}"
          continue
        fi
        rules+=("${normalized}")
        ;;
      d|del|delete)
        read -r -p "要删除的序号或规则: " value
        warp_rules_editor_delete "${value}" rules || continue
        ;;
      r|reset)
        rules=()
        while IFS= read -r line; do
          [[ -n "${line}" ]] || continue
          rules+=("${line}")
        done < <(default_warp_rules_text)
        ;;
      s|save|'')
        if [[ "${#rules[@]}" -eq 0 ]]; then
          warn "规则不能为空；要彻底关掉分流请用菜单 12 禁用 WARP。"
          continue
        fi
        break
        ;;
      q|quit)
        return 1
        ;;
      *)
        warn "无法识别的操作：${answer}"
        ;;
    esac
  done

  printf '%s\n' "${rules[@]}"
}

write_warp_rules_file() {
  local tmp_file=""
  local rules_text=""
  local current_text=""

  # 两层命令替换要拆开写。内层放在参数位置上时退出码会被外层整个吞掉：
  # current_warp_rules_text 读到一条非法规则会 die，而 die 是 exit，
  # 只打死了内层子 shell，外层就拿着一个空串当「当前规则」，
  # 接着把 WARP_RULES_FILE 原地清空——现有规则无声消失。
  current_text="$(current_warp_rules_text)" || return 1
  rules_text="$(normalize_warp_rules_text "${current_text}")" || return 1
  mkdir -p "${XRAY_CONFIG_DIR}" || return 1
  backup_path "${WARP_RULES_FILE}" || return 1
  tmp_file="$(mktemp "${XRAY_CONFIG_DIR}/.warp-domains.list.tmp.XXXXXX")"
  printf '%s\n' "${rules_text}" > "${tmp_file}" || { rm -f "${tmp_file}"; return 1; }
  mv -f "${tmp_file}" "${WARP_RULES_FILE}" || { rm -f "${tmp_file}"; return 1; }
  chmod 0640 "${WARP_RULES_FILE}"
}

resolve_install_input_sources() {
  resolve_value_source CERT_SOURCE_PEM
  resolve_value_source KEY_SOURCE_PEM
  resolve_value_source WARP_PRIVATE_KEY
  resolve_value_source WARP_PROFILE_SOURCE
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
  local label=""

  [[ -n "${host}" ]] || return 1
  [[ "${#host}" -le 253 ]] || return 1
  [[ "${host}" != .* && "${host}" != *..* && "${host}" != *. ]] || return 1
  [[ "${host}" =~ ^[A-Za-z0-9.-]+$ ]] || return 1

  # 必须是 local IFS。手工存一份再在末尾还原是不够的：下面三条 return 1
  # 全都从还原语句上面跳走，调用方的 IFS 就被永久留成 "."，
  # 之后所有不加引号的展开、$*、read 全按 "." 分词。
  # local 让 bash 在函数返回时自己还原，无论从哪条路径返回。
  local IFS='.'
  for label in ${host}; do
    [[ -n "${label}" ]] || return 1
    [[ "${#label}" -le 63 ]] || return 1
    [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done

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
  # 单引号里的 `\\` 是两个字面反斜杠，只挡得住连着写两个的路径；
  # 挡一个反斜杠要写 '\'。原来的写法让 /a\b 这种路径直接通过，
  # 然后原样进 nginx 的 location 前缀。
  # shellcheck disable=SC1003
  [[ "${XHTTP_PATH}" != *'\'* ]] || die "XHTTP 路径不能包含反斜杠。"
  [[ "${XHTTP_PATH}" != *[[:space:]]* ]] || die "XHTTP 路径不能包含空白字符。"
}

ensure_xhttp_ech_format() {
  [[ "${XHTTP_ECH_CONFIG_LIST}" != *$'\n'* && "${XHTTP_ECH_CONFIG_LIST}" != *$'\r'* ]] || die "XHTTP ECH 配置不能包含换行。"
  [[ "${XHTTP_ECH_FORCE_QUERY}" != *$'\n'* && "${XHTTP_ECH_FORCE_QUERY}" != *$'\r'* ]] || die "XHTTP ECH 强制查询模式不能包含换行。"
}

ensure_xhttp_xpadding_format() {
  XHTTP_XPADDING_ENABLED="$(normalize_yes_no_value "XHTTP_XPADDING_ENABLED" "${XHTTP_XPADDING_ENABLED:-${DEFAULT_XHTTP_XPADDING_ENABLED}}")" || exit 1
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

normalize_warp_reserved_value() {
  local raw_value="${1:-}"
  local byte=""
  local normalized=""

  raw_value="$(printf '%s' "${raw_value}" | tr -d '\r' | tr -d '[]' | tr -d ' ')"
  [[ -n "${raw_value}" ]] || return 0

  while IFS= read -r byte; do
    [[ -n "${byte}" ]] || continue
    [[ "${byte}" =~ ^[0-9]+$ ]] || die "WARP reserved 只能是逗号分隔的 0-255 整数：${1}"
    (( byte >= 0 && byte <= 255 )) || die "WARP reserved 只能是逗号分隔的 0-255 整数：${1}"
    normalized+="${byte},"
  done < <(printf '%s\n' "${raw_value}" | tr ',' '\n')

  printf '%s' "${normalized%,}"
}

is_valid_wireguard_key() {
  local key="${1:-}"

  [[ "${key}" =~ ^[A-Za-z0-9+/]{42}[A-Za-z0-9+/=]{2}$ ]]
}

ensure_warp_outbound_format() {
  is_valid_wireguard_key "${WARP_PRIVATE_KEY}" \
    || die "WARP WireGuard 私钥必须是 44 位 base64 字符串。"
  is_valid_wireguard_key "${WARP_PEER_PUBLIC_KEY:-${DEFAULT_WARP_PEER_PUBLIC_KEY}}" \
    || die "WARP 对端公钥必须是 44 位 base64 字符串。"
  [[ -n "${WARP_ADDRESS_V4}" || -n "${WARP_ADDRESS_V6}" ]] \
    || die "启用 WARP 时必须提供至少一个 WireGuard 内网地址。"
  if [[ -n "${WARP_ADDRESS_V4}" ]]; then
    is_ipv4 "${WARP_ADDRESS_V4}" || die "WARP IPv4 内网地址不合法：${WARP_ADDRESS_V4}"
  fi
  if [[ -n "${WARP_ADDRESS_V6}" ]]; then
    [[ "${WARP_ADDRESS_V6}" =~ ^[0-9A-Fa-f:]+$ ]] || die "WARP IPv6 内网地址不合法：${WARP_ADDRESS_V6}"
  fi
  validate_hostport_value "WARP Endpoint" "${WARP_ENDPOINT:-${DEFAULT_WARP_ENDPOINT}}"
  validate_port_value "WARP MTU" "${WARP_MTU:-${DEFAULT_WARP_MTU}}"
  WARP_RESERVED="$(normalize_warp_reserved_value "${WARP_RESERVED}")" || exit 1
}

validate_install_inputs() {
  ensure_reality_sni_format
  ensure_reality_target_format
  ensure_xhttp_domain_format
  ensure_xhttp_path_format
  ensure_xhttp_ech_format
  ensure_xhttp_xpadding_format

  if [[ "${ENABLE_WARP:-no}" == "yes" && -n "${WARP_PRIVATE_KEY}" ]]; then
    ensure_warp_outbound_format
  fi
}
