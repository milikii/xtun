# shellcheck shell=bash

# ------------------------------
# 健康统计层
# 负责恢复记录读取、窗口统计与面板汇总
# ------------------------------

health_event_text() {
  local prefix="${1}"
  local last_action_var="${prefix}_LAST_ACTION"
  local last_reason_var="${prefix}_LAST_REASON"
  local last_check_var="${prefix}_LAST_CHECK_AT"
  local action="${!last_action_var:-}"
  local reason="${!last_reason_var:-}"
  local checked_at="${!last_check_var:-}"

  if [[ -z "${action}" ]]; then
    printf '无'
    return
  fi

  if [[ -n "${checked_at}" ]]; then
    printf '%s @ %s (%s)' "${action}" "${checked_at}" "${reason:-无说明}"
  else
    printf '%s (%s)' "${action}" "${reason:-无说明}"
  fi
}

latest_health_history_text() {
  local line=""

  if [[ ! -f "${HEALTH_HISTORY_FILE}" ]]; then
    printf '无'
    return
  fi

  line="$(tail -n 1 "${HEALTH_HISTORY_FILE}" 2>/dev/null || true)"
  printf '%s' "${line:-无}"
}

# 就地去掉字段首尾空白。
# 面板每刷新一次要处理上百个字段，写成 x="$(trim "$x")" 就是上百次 fork，
# 所以这里接变量名、用 printf -v 回写。
health_history_trim_var() {
  local name="${1}"
  local value="${!name-}"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf -v "${name}" '%s' "${value}"
}

health_history_epoch() {
  local stamp="${1}"

  [[ -n "${stamp}" ]] || return 1
  date -d "${stamp}" '+%s' 2>/dev/null
}

health_history_now_epoch() {
  local now_raw="${HEALTH_HISTORY_NOW:-}"

  if [[ -n "${now_raw}" ]]; then
    health_history_epoch "${now_raw}"
    return
  fi

  date '+%s'
}

health_history_count() {
  local hours="${1}"
  local scope="${2:-}"
  local now_epoch=""
  local cutoff=0
  local cutoff_stamp=""
  local cutoff_key=""
  local count=0
  local stamp=""
  local stamp_key=""
  local item_scope=""
  local action=""
  local _reason=""
  local stamp_epoch=""

  if [[ ! -f "${HEALTH_HISTORY_FILE}" ]]; then
    printf '0'
    return
  fi

  now_epoch="$(health_history_now_epoch)" || {
    printf '0'
    return
  }
  cutoff=$((now_epoch - hours * 3600))

  # 巡检写入的时间戳固定是 date -u '+%Y-%m-%dT%H:%M:%SZ'，宽度固定，
  # 抽掉分隔符后就是可直接比大小的 14 位数字。
  # 先把窗口下界折算成同样的形式，整个统计就只剩两次 date 调用，
  # 而不是每条历史记录都 fork 一次。
  cutoff_stamp="$(date -u -d "@${cutoff}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
  cutoff_key="${cutoff_stamp//[^0-9]/}"

  while IFS='|' read -r stamp item_scope action _reason; do
    health_history_trim_var stamp
    health_history_trim_var item_scope
    health_history_trim_var action

    [[ -n "${stamp}" && -n "${action}" ]] || continue

    if [[ -n "${cutoff_key}" && "${stamp}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      stamp_key="${stamp//[^0-9]/}"
      (( 10#${stamp_key} >= 10#${cutoff_key} )) || continue
    else
      # 手工编辑过、或换过格式的历史文件才退回逐行解析
      stamp_epoch="$(health_history_epoch "${stamp}")" || continue
      (( stamp_epoch >= cutoff )) || continue
    fi

    [[ -z "${scope}" || "${item_scope}" == "${scope}" ]] || continue
    [[ "${action}" == "restarted" ]] || continue
    count=$((count + 1))
  done < "${HEALTH_HISTORY_FILE}"

  printf '%s' "${count}"
}

health_history_count_text() {
  local hours="${1}"
  local scope="${2:-}"
  printf '%s' "$(health_history_count "${hours}" "${scope}")"
}

stability_signal_text() {
  local core_1h="${1:-}"
  local core_24h="${2:-}"

  [[ -n "${core_1h}" ]] || core_1h="$(health_history_count 1 core)"
  [[ -n "${core_24h}" ]] || core_24h="$(health_history_count 24 core)"

  if (( core_1h >= 2 )); then
    style_text "${C_RED}" "高风险"
    return
  fi

  if (( core_24h >= 3 )); then
    style_text "${C_YELLOW}" "观察中"
    return
  fi

  style_text "${C_GREEN}" "稳定"
}

# 菜单每转一圈都要重画一次面板，所以这里只保留决策必需的行：
# 不跑 xray/nginx/haproxy -t、不做本地 TLS 握手、不读证书。
# 需要完整体检时走 xtun status 或菜单 4。
show_dashboard_brief() {
  local xray_state=""
  local haproxy_state=""
  local nginx_state=""
  local core_1h=""
  local core_24h=""

  load_dashboard_context

  xray_state="$(service_active_state 'xray.service')"
  haproxy_state="$(service_active_state 'haproxy.service')"
  nginx_state="$(service_active_state 'nginx.service')"
  core_1h="$(health_history_count 1 core)"
  core_24h="$(health_history_count 24 core)"

  divider
  printf '%b%s%b\n' "${C_BOLD}${C_CYAN}" "Xray 管理面板" "${C_RESET}"
  divider
  if [[ -f "${XRAY_CONFIG_FILE}" ]]; then
    panel_row "安装状态" "$(style_text "${C_GREEN}" "已托管")  脚本 v${SCRIPT_VERSION}"
    panel_row "REALITY" "${SERVER_IP:-未知}:443  sni=${REALITY_SNI:-未知}"
    panel_row "XHTTP CDN" "${XHTTP_DOMAIN:-未知}:443  path=${XHTTP_PATH:-未知}"
  else
    panel_row "安装状态" "$(style_text "${C_YELLOW}" "未安装")  脚本 v${SCRIPT_VERSION}"
  fi
  panel_row "服务" "xray $(service_badge "${xray_state}")   haproxy $(service_badge "${haproxy_state}")   nginx $(service_badge "${nginx_state}")"
  panel_row "监听 :443" "$(listening_port_text 443)"
  panel_row "WARP 分流" "$(bool_badge "${ENABLE_WARP:-no}")  规则=$(warp_rule_count_text)"
  panel_row "网络优化" "$(bool_badge "${ENABLE_NET_OPT:-no}")"
  panel_row "稳定性信号" "$(stability_signal_text "${core_1h}" "${core_24h}")  近1h=${core_1h}  近24h=${core_24h}"
  panel_row "完整体检" "菜单 4 / xtun status / xtun diagnose"
  divider
}

show_dashboard() {
  local xray_state=""
  local haproxy_state=""
  local nginx_state=""
  local core_health_state=""
  local net_state=""
  local xray_enabled=""
  local haproxy_enabled=""
  local nginx_enabled=""
  local core_health_enabled=""
  local net_enabled=""
  local version_line=""
  local core_1h=""
  local core_24h=""

  load_dashboard_context

  xray_state="$(service_active_state 'xray.service')"
  haproxy_state="$(service_active_state 'haproxy.service')"
  nginx_state="$(service_active_state 'nginx.service')"
  core_health_state="$(service_active_state "${CORE_HEALTH_TIMER_NAME}")"
  net_state="$(service_active_state "${NET_SERVICE_NAME}")"
  xray_enabled="$(service_enable_state 'xray.service')"
  haproxy_enabled="$(service_enable_state 'haproxy.service')"
  nginx_enabled="$(service_enable_state 'nginx.service')"
  core_health_enabled="$(service_enable_state "${CORE_HEALTH_TIMER_NAME}")"
  net_enabled="$(service_enable_state "${NET_SERVICE_NAME}")"
  version_line="$(xray_version_line)"
  core_1h="$(health_history_count 1 core)"
  core_24h="$(health_history_count 24 core)"

  divider
  printf '%b%s%b\n' "${C_BOLD}${C_CYAN}" "Xray 管理面板" "${C_RESET}"
  divider
  panel_row "脚本版本" "${SCRIPT_VERSION}"
  panel_row "更新时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

  if [[ -f "${XRAY_CONFIG_FILE}" ]]; then
    panel_row "安装状态" "$(style_text "${C_GREEN}" "已托管")"
    [[ -n "${version_line}" ]] && panel_row "Xray 核心" "${version_line}"
    panel_row "证书模式" "$(pretty_cert_mode)"
    panel_row "REALITY" "${SERVER_IP:-未知}:443  sni=${REALITY_SNI:-未知}"
    panel_row "XHTTP CDN" "${XHTTP_DOMAIN:-未知}:443  path=${XHTTP_PATH:-未知}"
    panel_row "节点前缀" "${NODE_LABEL_PREFIX:-未知}"
    panel_row "REALITY UUID" "$(short_value "${REALITY_UUID:-未知}")"
    panel_row "XHTTP UUID" "$(short_value "${XHTTP_UUID:-未知}")"
    panel_row "REALITY 公钥" "$(short_value "${REALITY_PUBLIC_KEY:-未知}" 10 8)"
    panel_row "链接文件" "${OUTPUT_FILE}"
    panel_row "订阅目录" "${SUBSCRIPTION_DIR}"
  else
    panel_row "安装状态" "$(style_text "${C_YELLOW}" "未安装")"
  fi

  divider
  printf '%b%s%b\n' "${C_BOLD}" "服务状态" "${C_RESET}"
  panel_row "xray" "$(service_badge "${xray_state}") ($(service_install_state_label "${xray_enabled}"))"
  panel_row "haproxy" "$(service_badge "${haproxy_state}") ($(service_install_state_label "${haproxy_enabled}"))"
  panel_row "nginx" "$(service_badge "${nginx_state}") ($(service_install_state_label "${nginx_enabled}"))"
  panel_row "核心巡检" "$(service_badge "${core_health_state}") ($(service_install_state_label "${core_health_enabled}"))"
  panel_row "网络优化" "$(service_badge "${net_state}") ($(service_install_state_label "${net_enabled}"))"

  divider
  printf '%b%s%b\n' "${C_BOLD}" "功能开关" "${C_RESET}"
  panel_row "WARP 分流" "$(bool_badge "${ENABLE_WARP:-no}")  模式=wireguard"
  panel_row "WARP 规则数" "$(warp_rule_count_text)"
  panel_row "网络优化" "$(bool_badge "${ENABLE_NET_OPT:-no}")"
  panel_row "VLESS Encryption" "$(bool_badge "${XHTTP_VLESS_ENCRYPTION_ENABLED:-${DEFAULT_XHTTP_VLESS_ENCRYPTION_ENABLED}}")"
  panel_row "XHTTP ECH" "$(if [[ -n "${XHTTP_ECH_CONFIG_LIST:-${DEFAULT_XHTTP_ECH_CONFIG_LIST}}" ]]; then bool_badge "yes"; else bool_badge "no"; fi)  doh=${XHTTP_ECH_CONFIG_LIST:-未设置}"
  panel_row "XHTTP xpadding" "$(bool_badge "${XHTTP_XPADDING_ENABLED:-${DEFAULT_XHTTP_XPADDING_ENABLED}}")  header=${XHTTP_XPADDING_HEADER:-${DEFAULT_XHTTP_XPADDING_HEADER}}"
  if [[ "${CERT_MODE:-}" == "acme-dns-cf" ]]; then
    panel_row "ACME CA" "${ACME_CA:-${DEFAULT_ACME_CA}}"
  fi

  divider
  printf '%b%s%b\n' "${C_BOLD}" "运行探测" "${C_RESET}"
  panel_row "监听 :443" "$(listening_port_text 443)"
  panel_row "监听 :2443" "$(listening_port_text 2443)"
  panel_row "监听 :8001" "$(listening_port_text 8001)"
  panel_row "监听 :8443" "$(listening_port_text 8443)"
  panel_row "Xray 自检" "$(xray_config_check_text)"
  panel_row "Nginx 自检" "$(nginx_config_check_text)"
  panel_row "HAProxy 自检" "$(haproxy_config_check_text)"
  panel_row "本地 TLS 探测" "$(local_tls_probe_text)"
  panel_row "证书到期" "$(cert_expiry_text)"
  panel_row "WARP 出站" "$(warp_outbound_text)"
  panel_row "最近备份" "$(latest_backup_label)"
  panel_row "核心自恢复" "$(health_event_text CORE_HEALTH)"
  panel_row "最近恢复记录" "$(latest_health_history_text)"
  panel_row "近1小时恢复" "core=${core_1h}"
  panel_row "近24小时恢复" "core=${core_24h}"
  panel_row "稳定性信号" "$(stability_signal_text "${core_1h}" "${core_24h}")"
  divider
}
