# shellcheck shell=bash

# ------------------------------
# 状态面板层
# 负责菜单简报与完整体检面板
# ------------------------------

# 菜单每转一圈都要重画一次面板，所以这里只保留决策必需的行：
# 不跑 xray/nginx/haproxy -t、不做本地 TLS 握手、不读证书。
# 需要完整体检时走 xtun status 或「查看状态与诊断」。
show_dashboard_brief() {
  local xray_state=""
  local haproxy_state=""
  local nginx_state=""

  load_dashboard_context || return 1

  xray_state="$(service_active_state 'xray.service')"
  haproxy_state="$(service_active_state 'haproxy.service')"
  nginx_state="$(service_active_state 'nginx.service')"
  divider
  printf '%b%s%b\n' "${C_BOLD}${C_CYAN}" "Xray 管理面板" "${C_RESET}"
  divider
  if [[ -f "${XRAY_CONFIG_FILE}" ]]; then
    panel_row "安装状态" "$(style_text "${C_GREEN}" "已托管")  脚本 v${SCRIPT_VERSION}"
    panel_row "REALITY" "$(short_value "${SERVER_IP:-未知}" 24 12):443"
    panel_row "XHTTP CDN" "$(short_value "${XHTTP_DOMAIN:-未知}" 24 12):443"
    panel_row "IPv6 直连" "$(if [[ -n "${SERVER_IP6:-}" ]]; then printf '已配置'; else printf '未启用'; fi)"
    panel_row "XHTTP H3" "$(h3_intent_text)"
  else
    panel_row "安装状态" "$(style_text "${C_YELLOW}" "未安装")  脚本 v${SCRIPT_VERSION}"
  fi
  panel_row "服务" "xray $(service_badge "${xray_state}")   haproxy $(service_badge "${haproxy_state}")   nginx $(service_badge "${nginx_state}")"
  panel_row "监听 :443 (TCP)" "$(short_value "$(listening_port_text 443)" 20 8)"
  panel_row "WARP 分流" "$(bool_badge "${ENABLE_WARP:-no}")  规则=$(warp_rule_count_text)"
  if pending_operation_present; then
    panel_row "上次动作" "$(style_text "${C_YELLOW}" "未完成：$(short_value "$(pending_operation_text)" 14 8)")"
  fi
  panel_row "完整体检" "查看状态与诊断 / xtun status"
  divider
}

show_dashboard() {
  local xray_state=""
  local haproxy_state=""
  local nginx_state=""
  local net_state=""
  local xray_enabled=""
  local haproxy_enabled=""
  local nginx_enabled=""
  local net_enabled=""
  local version_line=""

  load_dashboard_context || return 1
  h3_refresh_decision

  xray_state="$(service_active_state 'xray.service')"
  haproxy_state="$(service_active_state 'haproxy.service')"
  nginx_state="$(service_active_state 'nginx.service')"
  net_state="$(service_active_state "${NET_SERVICE_NAME}")"
  xray_enabled="$(service_enable_state 'xray.service')"
  haproxy_enabled="$(service_enable_state 'haproxy.service')"
  nginx_enabled="$(service_enable_state 'nginx.service')"
  net_enabled="$(service_enable_state "${NET_SERVICE_NAME}")"
  version_line="$(xray_version_line)"

  divider
  printf '%b%s%b\n' "${C_BOLD}${C_CYAN}" "Xray 管理面板" "${C_RESET}"
  divider
  panel_row "脚本版本" "${SCRIPT_VERSION}"
  if bundle_identity_valid "${SELF_INSTALL_DIR}"; then
    panel_row "脚本身份" "$(jq -r '.source + " / " + .content_sha256[0:12]' "${SELF_INSTALL_DIR}/.xtun-bundle.json")"
  else
    panel_row "脚本身份" "未核验（缺少或不匹配安装记录）"
  fi
  panel_row "更新时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

  if [[ -f "${XRAY_CONFIG_FILE}" ]]; then
    panel_row "安装状态" "$(style_text "${C_GREEN}" "已托管")"
    [[ -n "${version_line}" ]] && panel_row "Xray 核心" "${version_line}"
    if xray_installed_identity_valid; then
      panel_row "核心身份" "$(jq -r '.tag + " / " + .binary_sha256[0:12]' "$(xray_identity_file)")"
    else
      panel_row "核心身份" "未核验（可显式 upgrade --reinstall）"
    fi
    panel_row "证书模式" "$(pretty_cert_mode)"
    panel_row "REALITY" "${SERVER_IP:-未知}:443  sni=${REALITY_SNI:-未知}"
    panel_row "XHTTP CDN" "${XHTTP_DOMAIN:-未知}:443  path=${XHTTP_PATH:-未知}"
    panel_row "IPv6 直连" "$(if [[ -n "${SERVER_IP6:-}" ]]; then style_text "${C_GREEN}" "[${SERVER_IP6}]"; else printf '未启用'; fi)"
    panel_row "XHTTP H3 选择" "$(h3_intent_text)"
    panel_row "H3 本地条件" "${H3_REASON}"
    panel_row "节点前缀" "${NODE_LABEL_PREFIX:-未知}"
    panel_row "REALITY UUID" "$(short_value "${REALITY_UUID:-未知}")"
    panel_row "XHTTP UUID" "$(short_value "${XHTTP_UUID:-未知}")"
    panel_row "REALITY 公钥" "$(short_value "${REALITY_PUBLIC_KEY:-未知}" 10 8)"
    panel_row "链接文件" "${OUTPUT_FILE}"
    panel_row "二维码目录" "${QR_OUTPUT_DIR}"
  else
    panel_row "安装状态" "$(style_text "${C_YELLOW}" "未安装")"
  fi

  # 未完成操作清单只报告、不自行恢复：查看入口不写系统（D12），
  # 处理它的是下一次明确的维护动作（apply-config / 重装）。
  if pending_operation_present; then
    panel_row "上次动作" "$(style_text "${C_YELLOW}" "未完成：$(pending_operation_text)")"
    panel_row "处理方式" "检查现场后运行 xtun recover"
  fi

  divider
  printf '%b%s%b\n' "${C_BOLD}" "服务状态" "${C_RESET}"
  panel_row "xray" "$(service_badge "${xray_state}") ($(service_install_state_label "${xray_enabled}"))"
  panel_row "haproxy" "$(service_badge "${haproxy_state}") ($(service_install_state_label "${haproxy_enabled}"))"
  panel_row "nginx" "$(service_badge "${nginx_state}") ($(service_install_state_label "${nginx_enabled}"))"
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
  panel_row "监听 :443 (TCP)" "$(listening_port_text 443)"
  panel_row "监听 :2443 (TCP)" "$(listening_port_text 2443)"
  panel_row "监听 :${REALITY_FALLBACK_PORT} (TCP)" "$(listening_port_text "${REALITY_FALLBACK_PORT}")"
  panel_row "监听 :8001 (TCP)" "$(listening_port_text 8001)"
  panel_row "监听 :8443 (TCP)" "$(listening_port_text 8443)"
  panel_row "QUIC :443 (UDP)" "$(quic_port_text)"
  panel_row "拥塞控制 / qdisc" "$(net_current_cc) / $(net_default_qdisc)"
  panel_row "Xray 自检" "$(xray_config_check_text)"
  panel_row "Nginx 自检" "$(nginx_config_check_text)"
  panel_row "HAProxy 自检" "$(haproxy_config_check_text)"
  panel_row "本地 TLS 探测" "$(local_tls_probe_text)"
  panel_row "证书到期" "$(cert_expiry_text)"
  panel_row "证书操作" "$(certificate_last_event_text)"
  panel_row "WARP 出站" "$(warp_outbound_text)"
  panel_row "最近备份" "$(latest_backup_label)"
  divider
}
