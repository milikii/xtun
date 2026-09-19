# shellcheck shell=bash

# ------------------------------
# CLI 核心层
# 负责状态、菜单、分发与通用维护命令
# ------------------------------

# 查看只消费已经提交的文档；不重算凭据，也不生成/清理 PNG。
output_node_link_entries() {
  awk '
    /^## 节点 [1-9]$/ { node=$3; next }
    /^vless:\/\// {
      sequence++
      label=$0
      sub(/^.*#/, "", label)
      print (node == "" ? sequence : node) "\t" label "\t" $0
    }
  ' "${OUTPUT_FILE}"
}

output_node_png_path() {
  local number="${1}" label="${2}"
  [[ "${number}" =~ ^[1-9]$ && "${label}" != */* ]] || return 1
  printf '%s/%02d-%s.png' "${QR_OUTPUT_DIR}" "${number}" "${label}"
}

show_node_png_location() {
  local path=""
  path="$(output_node_png_path "${1}" "${2}")" || return 1
  if [[ -f "${path}" ]]; then
    printf '  PNG: %s\n' "${path}"
  else
    printf '  PNG: 尚未生成（目录 %s）\n' "${QR_OUTPUT_DIR}"
  fi
}

render_node_qr() {
  local number="${1}" label="${2}" uri="${3}"
  local rendered="" line="" rows=0 width=0
  local columns="${COLUMNS:-80}" lines="${LINES:-24}" path=""
  [[ "${columns}" =~ ^[0-9]+$ ]] || columns=80
  [[ "${lines}" =~ ^[0-9]+$ ]] || lines=24
  printf '节点 %s: %s\n' "${number}" "${label}"
  path="$(output_node_png_path "${number}" "${label}")" || return 1
  show_node_png_location "${number}" "${label}" || return $?
  if ! have_qrencode; then
    warn "未找到 qrencode，终端二维码不可用；可取用已有 PNG。"
    [[ -f "${path}" ]]
    return
  fi
  # UTF8 不带 ANSI；先计算实际尺寸，避免一张长 extra 链接刷满几屏。
  if ! rendered="$(printf '%s' "${uri}" | qrencode -t UTF8 -l L -m 1 2>/dev/null)"; then
    warn "节点 ${number} 的终端二维码编码失败；可取用已有 PNG。"
    return 1
  fi
  while IFS= read -r line; do
    rows=$((rows + 1))
    (( ${#line} <= width )) || width=${#line}
  done <<< "${rendered}"
  if (( rows > lines - 4 || width > columns )); then
    printf '  二维码超出当前终端，请取用 PNG；复制链接: xtun show-links --node %s\n' "${number}"
    [[ -f "${path}" ]]
    return
  fi
  printf '%s\n\n' "${rendered}"
}

render_output_file_qr() {
  local selected="${1:-}" number="" label="" uri="" failed=0
  while IFS=$'\t' read -r number label uri; do
    [[ -z "${selected}" || "${selected}" == "${number}" ]] || continue
    render_node_qr "${number}" "${label}" "${uri}" || failed=1
  done < <(output_node_link_entries)
  return "${failed}"
}

show_links_summary() {
  local selected="${1:-}" node_number="" label="" uri="" link_count=0
  printf '\n%s\n' "节点链接摘要"
  printf '链接文件: %s\n' "${OUTPUT_FILE}"
  printf '完整内容: xtun show-links\n'
  printf '单节点: xtun show-links --node N；二维码: xtun show-links --qr --node N\n'
  while IFS=$'\t' read -r node_number label uri; do
    [[ -z "${selected}" || "${selected}" == "${node_number}" ]] || continue
    link_count=$((link_count + 1))
    printf '节点 %s: %s\n' "${node_number}" "${label}"
    show_node_png_location "${node_number}" "${label}" || return $?
  done < <(output_node_link_entries)
  [[ "${link_count}" -gt 0 ]] || warn "输出文件中没有找到节点链接。"
}

show_links() {
  local show_qr=0
  local summary=0
  local selected="" number="" label="" uri="" entry=""

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --qr)
        show_qr=1
        ;;
      --summary)
        summary=1
        ;;
      --node|--node=*)
        option_take_value --node "${1}" "${@:2}"
        [[ "${OPTION_VALUE}" =~ ^[1-9]$ ]] || die "--node 需要节点编号 1–9。"
        [[ -z "${selected}" || "${selected}" == "${OPTION_VALUE}" ]] || die "--node 不能指定多个节点。"
        selected="${OPTION_VALUE}"
        shift "${OPTION_ARGS_CONSUMED}"
        continue
        ;;
      --help|-h|help)
        usage
        exit 0
        ;;
      *)
        die "未知的 show-links 参数：${1}"
        ;;
    esac
    shift
  done

  if [[ "${show_qr}" -eq 1 && "${summary}" -eq 1 ]]; then
    die "--summary 不能与 --qr 同时使用。"
  fi

  # show-links 是纯查看：不重写任何文件，输出文件丢了就明说。
  [[ -f "${OUTPUT_FILE}" ]] || die "找不到输出文件：${OUTPUT_FILE}"
  if [[ -n "${selected}" ]]; then
    entry="$(output_node_link_entries | awk -F '\t' -v n="${selected}" '$1 == n {print; exit}')"
    [[ -n "${entry}" ]] || die "节点 ${selected} 不存在或未启用；请用 xtun show-links --summary 查看当前节点。"
  fi

  if [[ "${summary}" -eq 1 ]]; then
    show_links_summary "${selected}"
    return
  fi
  if [[ "${show_qr}" -eq 1 ]]; then
    render_output_file_qr "${selected}"
  elif [[ -n "${selected}" ]]; then
    IFS=$'\t' read -r number label uri <<< "${entry}"
    printf '节点 %s: %s\n%s\n' "${number}" "${label}" "${uri}"
    show_node_png_location "${number}" "${label}" || return $?
  else
    cat "${OUTPUT_FILE}"
  fi
}

xray_managed_service_units() {
  printf '%s\n' \
    "xray.service" \
    "haproxy.service" \
    "nginx.service" \
    "${NET_SERVICE_NAME}"
}

restart_service_units() {
  printf '%s\n' \
    "xray.service" \
    "haproxy.service" \
    "nginx.service"

  if [[ "${ENABLE_NET_OPT:-no}" == "yes" ]]; then
    printf '%s\n' "${NET_SERVICE_NAME}"
  fi
}

restart_service_if_present() {
  local unit_name="${1}"

  service_exists "${unit_name}" || return 0
  # 重启成功与否以服务实际状态为准：systemctl 返回 0 而服务立刻又倒下，
  # 或者根本没起来，都不能被当成「已重启」（H11）。
  restart_service_verified "${unit_name}"
}

status_raw_cmd() {
  local units=()

  mapfile -t units < <(xray_managed_service_units)
  systemctl --no-pager --full status "${units[@]}" 2>/dev/null || true
}

status_cmd() {
  local raw=0

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --raw)
        raw=1
        ;;
      --help|-h|help)
        usage
        exit 0
        ;;
      *)
        die "未知的 status 参数：${1}"
        ;;
    esac
    shift
  done

  if [[ "${raw}" -eq 1 ]]; then
    status_raw_cmd
    return
  fi

  show_dashboard
}

diagnose_cmd() {
  local failures=0
  local run_warp_probe=0
  local run_net_check=0
  local xray_state=""
  local haproxy_state=""
  local nginx_state=""
  local xray_config_state=""
  local nginx_config_state=""
  local haproxy_config_state=""
  local tls_state=""
  local quic_state=""
  local net_stack_probe_state=""
  local warp_probe_result=""
  local port=""
  local snapshot=""
  local -a listen_ports=(443 2443 "${REALITY_FALLBACK_PORT}" 8001 8443)
  local -a judge_ports=(443 2443 8001 8443)
  local -a service_failures=()
  local -a port_failures=()
  local -a config_failures=()
  local -a tls_failures=()
  local -a warp_failures=()
  local -A listen_state=()
  local -A listen_text=()

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --warp-probe)
        run_warp_probe=1
        ;;
      --net)
        run_net_check=1
        ;;
      --help|-h|help)
        usage
        exit 0
        ;;
      *)
        die "未知的 diagnose 参数：${1}"
        ;;
    esac
    shift
  done

  # 只读上下文：诊断不写 state、不执行 repair / apply-config，也不改托管文件（D09）。
  load_dashboard_context || return 1
  h3_refresh_decision

  # 一次采集：下面所有展示与判定复用同一份结果。慢探测（xray -test、nginx -t、
  # TLS 握手、端口扫描）都只跑一次，不再「显示查一遍、判定再查一遍」（H21）。
  xray_state="$(service_active_state 'xray.service')"
  haproxy_state="$(service_active_state 'haproxy.service')"
  nginx_state="$(service_active_state 'nginx.service')"
  xray_config_state="$(xray_config_check_state)"
  nginx_config_state="$(nginx_config_check_state)"
  haproxy_config_state="$(haproxy_config_check_state)"
  tls_state="$(local_tls_probe_state)"
  quic_state="$(quic_port_state)"
  for port in "${listen_ports[@]}"; do
    [[ -n "${port}" ]] || continue
    snapshot="$(port_listening_snapshot "${port}")"
    listen_state["${port}"]="${snapshot%%|*}"
    listen_text["${port}"]="${snapshot#*|}"
  done
  if [[ "${run_net_check}" -eq 1 ]]; then
    net_stack_probe_state="$(net_stack_state)"
  fi
  if [[ "${run_warp_probe}" -eq 1 ]]; then
    warp_probe_result="$(warp_egress_probe_text)"
  fi

  printf '%s\n' "Xray 诊断"
  printf '%s\n' "脚本版本: ${SCRIPT_VERSION}"
  printf '%s\n' "xray: ${xray_state}"
  printf '%s\n' "haproxy: ${haproxy_state}"
  printf '%s\n' "nginx: ${nginx_state}"
  for port in "${listen_ports[@]}"; do
    [[ -n "${port}" ]] || continue
    printf '%s\n' "监听 ${port}: ${listen_text[${port}]}"
  done
  printf '%s\n' "XHTTP H3 选择: $(h3_intent_text)"
  printf '%s\n' "H3 本地条件: ${H3_REASON}"
  printf '%s\n' "H3 组件/证书/UDP: ${H3_MODULE_STATE} / ${H3_CERT_STATE} / ${H3_UDP_STATE}"
  printf '%s\n' "QUIC 443: $(quic_port_text_for_state "${quic_state}")"
  printf '%s\n' "监听 [::]:443: $(ipv6_listen_text "${listen_state[443]}" "${listen_text[443]}")"
  printf '%s\n' "Xray 配置: $(check_badge "${xray_config_state}")"
  printf '%s\n' "Nginx 配置: $(check_badge "${nginx_config_state}")"
  printf '%s\n' "Nginx worker_connections: $(nginx_worker_connections_text)"
  printf '%s\n' "HAProxy 配置: $(check_badge "${haproxy_config_state}")"
  printf '%s\n' "本地 TLS 探测: $(local_tls_probe_text_for_state "${tls_state}")"
  printf '%s\n' "证书用途: $(certificate_usage_text)"
  printf '%s\n' "路由拦截: $(xray_routing_block_text)"
  printf '%s\n' "证书到期: $(cert_expiry_text)"
  printf '%s\n' "证书操作: $(certificate_last_event_text)"
  printf '%s\n' "WARP 出站: $(warp_outbound_text)"
  printf '%s\n' "WARP 规则数: $(warp_rule_count_text)"
  printf '%s\n' "WARP Endpoint 解析: $(warp_endpoint_resolve_text)"
  # 本机诊断能证明的和不能证明的必须分开写：外部可达与客户端兼容只有真实客户端能给答案。
  printf '%s\n' "外部可达: 未验证（诊断只在本机采集，不含外部探测）"
  printf '%s\n' "客户端兼容: 未验证（需用真实客户端导入节点链接确认）"
  if [[ "${run_warp_probe}" -eq 1 ]]; then
    printf '%s\n' "WARP 出口 IP: ${warp_probe_result}"
  fi
  if [[ "${run_net_check}" -eq 1 ]]; then
    printf '%s\n' "-- 网络栈 --"
    net_stack_text
  fi

  [[ "${xray_state}" == "active" ]] || service_failures+=("xray 未运行")
  [[ "${haproxy_state}" == "active" ]] || service_failures+=("haproxy 未运行")
  [[ "${nginx_state}" == "active" ]] || service_failures+=("nginx 未运行")
  for port in "${judge_ports[@]}"; do
    case "${listen_state[${port}]}" in
      listening) ;;
      absent) port_failures+=("${port} 未监听（TCP）") ;;
      *) port_failures+=("${port} 无法确认（缺少 ss）") ;;
    esac
  done
  [[ "${xray_config_state}" == "ok" ]] || config_failures+=("Xray 配置校验失败")
  [[ "${nginx_config_state}" == "ok" ]] || config_failures+=("Nginx 配置校验失败")
  [[ "${haproxy_config_state}" == "ok" ]] || config_failures+=("HAProxy 配置校验失败")
  [[ "${H3_DECISION}" != blocked ]] || config_failures+=("H3 选择未满足：${H3_REASON}")
  case "${tls_state}" in
    ok) ;;
    untrusted)
      # 自签 / Origin CA 不受系统信任是预期；公网 CA 模式下不受信任才是故障。
      if [[ "${CERT_MODE:-}" == "acme-dns-cf" ]]; then
        tls_failures+=("本地 TLS 握手成功但证书不受系统信任（ACME 证书应受系统信任）")
      fi
      ;;
    na)
      tls_failures+=("本地 TLS 未探测（未配置 XHTTP 域名）")
      ;;
    unknown)
      tls_failures+=("本地 TLS 探测不可用（缺少 openssl）")
      ;;
    *)
      tls_failures+=("本地 TLS 探测失败（127.0.0.1:443 握手不成功）")
      ;;
  esac
  if [[ "${run_net_check}" -eq 1 ]]; then
    [[ "${net_stack_probe_state}" == "ok" ]] || config_failures+=("拥塞控制不是 bbr 系")
  fi
  if h3_enabled; then
    case "${quic_state}" in
      ok|unconfirmed) ;;
      *) port_failures+=("QUIC (UDP 443) 未确认：$(quic_port_text_for_state "${quic_state}")") ;;
    esac
  fi

  if [[ "${ENABLE_WARP:-no}" == "yes" ]]; then
    config_has_warp_outbound || warp_failures+=("config.json 缺少 WARP 出站")
    [[ -n "${WARP_PRIVATE_KEY:-}" ]] || warp_failures+=("WARP WireGuard 私钥缺失")
    [[ "$(warp_endpoint_resolve_state)" != "fail" ]] || warp_failures+=("WARP Endpoint 无法解析")
    if [[ "${run_warp_probe}" -eq 1 ]]; then
      [[ "${warp_probe_result}" != 未探测* ]] || warp_failures+=("WARP 出口 IP 未探测成功")
    fi
  fi

  failures=$(( ${#service_failures[@]} + ${#port_failures[@]} + ${#config_failures[@]} + ${#tls_failures[@]} + ${#warp_failures[@]} ))
  if [[ "${failures}" -gt 0 ]]; then
    printf '\n'
    printf '%s\n' "诊断摘要: 检测到 ${failures} 个问题"
    for item in "${service_failures[@]}"; do
      printf '%s\n' "服务: ${item}"
    done
    for item in "${port_failures[@]}"; do
      printf '%s\n' "端口: ${item}"
    done
    for item in "${config_failures[@]}"; do
      printf '%s\n' "配置: ${item}"
    done
    for item in "${tls_failures[@]}"; do
      printf '%s\n' "连接: ${item}"
    done
    for item in "${warp_failures[@]}"; do
      printf '%s\n' "WARP: ${item}"
    done
    return 1
  fi

  printf '\n'
  printf '%s\n' "诊断摘要: 未发现关键问题"
}

# 只有能证明「这个包是 xtun 装进来的」才允许在卸载时停掉对应服务。
# 没有归属记录（旧安装）时按保守处理：不停。
managed_service_preinstalled() {
  local unit_name="${1}"

  case "${unit_name}" in
    haproxy.service)
      ! package_installed_by_xtun haproxy
      ;;
    nginx.service)
      ! package_installed_by_xtun nginx
      ;;
    *)
      return 1
      ;;
  esac
}

restart_cmd() {
  local unit_name=""
  local restart_failed=0

  parse_command_without_options restart "$@"
  load_dashboard_context || return 1
  confirm_maintenance_action "重启托管服务" "不改配置" \
    "restart xray/nginx/HAProxy（已启用时包括网络优化）；现有连接可能中断" \
    "逐项报告实际服务状态；失败后运行 xtun diagnose" || return 1
  begin_mutation || return 1
  SERVICE_ACTION_RESULTS=()
  while IFS= read -r unit_name; do
    if ! restart_service_if_present "${unit_name}"; then
      restart_failed=1
      warn "重启服务失败：${unit_name}"
    fi
  done < <(restart_service_units)
  [[ "${restart_failed}" -eq 0 ]] || return 1
  log "服务已重启：$(service_results_text | tr '\n' ';')"
}

parse_command_without_options() {
  local command_label="${1}"
  shift

  while [[ $# -gt 0 ]]; do
    if handle_change_common_arg "${1}"; then shift; continue; fi
    case "${1}" in
      --help|-h|help)
        usage
        exit 0
        ;;
      *)
        die "未知的 ${command_label} 参数：${1}"
        ;;
    esac
    shift
  done
}

repair_perms_cmd() {
  local unit_name=""
  local failed=0

  parse_command_without_options repair-perms "$@"
  need_root
  confirm_maintenance_action "抢修托管文件权限" "托管目录、配置、日志的 owner/mode" \
    "restart xray/nginx/HAProxy；现有连接可能中断" \
    "修复失败时保留现场并报告服务状态" || return 1
  begin_mutation || return 1
  # 这条命令存在的意义就是「权限坏了来抢修」，抢修没成还报成功是最坏的结果。
  ensure_xray_user || return 1
  ensure_managed_permissions || return 1
  systemctl daemon-reload || return 1
  SERVICE_ACTION_RESULTS=()
  for unit_name in xray.service haproxy.service nginx.service; do
    service_exists "${unit_name}" || continue
    restart_service_verified "${unit_name}" || failed=1
  done
  if [[ "${failed}" -ne 0 ]]; then
    warn "权限已修复，但有服务没有回到 active：$(service_results_text | tr '\n' ';')"
    return 1
  fi
  log "已修复脚本托管文件权限，并确认 xray、haproxy、nginx 处于 active。"
}

# 脚本升级后，托管的 haproxy.cfg / nginx.conf / config.json 仍是旧模板渲染出来的，
# 除非正好跑一次 change-* 或重装，新版模板里的调优参数不会自己生效。
# 这条命令就是那个「按当前状态重渲染一遍」的入口。
# apply-config 是诊断/README 直接推荐给用户的修复入口，参数必须真的被接受：
#   --manage-nginx-main     接管 /etc/nginx/nginx.conf（先留首次原件）
#   --no-manage-nginx-main  停止接管，有可信原件才还原并翻转状态
apply_config_cmd() {
  local manage_nginx_main=""
  local old_nginx_main=""
  local -a paths=()
  local -a units=(xray.service haproxy.service nginx.service)

  reset_arg_groups
  while [[ $# -gt 0 ]]; do
    if handle_change_common_arg "${1}"; then
      shift
      continue
    fi
    case "${1}" in
      --manage-nginx-main=*|--no-manage-nginx-main=*)
        die "参数 ${1%%=*} 是无值开关，不接受 = 值。"
        ;;
      --manage-nginx-main|--no-manage-nginx-main)
        record_arg_group "nginx-main" "${1}"
        if [[ "${1}" == "--manage-nginx-main" ]]; then
          manage_nginx_main="yes"
        else
          manage_nginx_main="no"
        fi
        shift
        ;;
      *)
        die "未知的 apply-config 参数：${1}"
        ;;
    esac
  done

  prepare_change_context || return 1
  old_nginx_main="${NGINX_MAIN_MANAGED:-no}"
  [[ -z "${manage_nginx_main}" ]] || NGINX_MAIN_MANAGED="${manage_nginx_main}"
  confirm_change_preview "按当前模板重建托管配置" runtime || return 1
  NGINX_MAIN_MANAGED="${old_nginx_main}"
  open_change_session || return 1
  if [[ -n "${manage_nginx_main}" ]]; then
    paths+=("${NGINX_MAIN_CONFIG}")
  fi
  generation_legacy_scope paths units || return 1
  begin_generation "重建托管配置" no "${units[@]}" -- "${paths[@]}" || return 1
  if ! remove_legacy_managed_paths || ! ensure_xray_user lookup; then
    generation_failed "准备托管配置失败"
    return 1
  fi

  case "${manage_nginx_main}" in
    yes)
      if [[ "${NGINX_MAIN_MANAGED:-no}" == "yes" ]]; then
        log "${NGINX_MAIN_CONFIG} 已经处于接管状态。"
      else
        log_step "接管 ${NGINX_MAIN_CONFIG}（先保留首次原件）。"
        NGINX_MAIN_MANAGED="yes"
      fi
      ;;
    no)
      if [[ "${NGINX_MAIN_MANAGED:-no}" != "yes" ]]; then
        log "${NGINX_MAIN_CONFIG} 当前未接管，无需还原。"
      else
        log_step "停止接管 ${NGINX_MAIN_CONFIG}，还原接管前的文件。"
        if ! restore_nginx_main_config; then
          generation_failed "还原 nginx 主配置失败"
          return 1
        fi
        case "${NGINX_MAIN_RESTORE_RESULT}" in
          restored|deleted|legacy-restored)
            NGINX_MAIN_MANAGED="no"
            ;;
          *)
            generation_failed "找不到 ${NGINX_MAIN_CONFIG} 的可信原件，未改变接管状态"
            return 1
            ;;
        esac
      fi
      ;;
  esac

  log_step "按当前状态重新生成托管配置。"
  apply_managed_runtime_update || return 1
  finish_managed_change "托管配置已按当前状态重新生成。" "no"
}

apply_net_opt_cmd() {
  local bbr_kernel=""

  while [[ $# -gt 0 ]]; do
    if handle_change_common_arg "${1}"; then
      shift
      continue
    fi
    case "${1}" in
      --bbr-kernel|--bbr-kernel=*)
        option_take_value "--bbr-kernel" "${1}" "${@:2}"
        bbr_kernel="${OPTION_VALUE}"
        shift "${OPTION_ARGS_CONSUMED}"
        ;;
      *)
        die "未知的 apply-net-opt 参数：${1}"
        ;;
    esac
  done

  if [[ -n "${bbr_kernel}" ]]; then
    bbr_kernel="$(normalize_net_bbr_kernel_value "${bbr_kernel}")" || return 1
  fi
  ensure_debian_family
  prepare_change_context || return 1

  if [[ -n "${bbr_kernel}" ]]; then
    NET_BBR_KERNEL="${bbr_kernel}"
  fi

  ENABLE_NET_OPT="yes"
  NET_BBRV3_REBOOT_REQUIRED="no"
  confirm_change_preview "应用网络优化" net || return 1
  open_change_session || return 1
  begin_generation_paths "网络优化" "${NET_SERVICE_NAME}" -- \
    "${NET_SYSCTL_CONF}" \
    "${NET_HELPER_PATH}" \
    "${NET_SERVICE_FILE}" \
    "${STATE_FILE}" || return 1

  log_step "应用 Joey BBRv3 网络优化。"
  if ! install_network_optimization; then
    generation_failed "网络优化应用失败"
    return 1
  fi
  if ! write_state_file; then
    generation_failed "写入状态文件失败"
    return 1
  fi

  generation_commit || return 1
  log_success "网络优化已应用。"
  log "备份目录：${BACKUP_DIR}"
  if [[ "${NET_BBRV3_REBOOT_REQUIRED:-no}" == "yes" ]]; then
    if ! bbr_v3_active; then
      log "请重启 VPS 后加载 Joey BBRv3 内核。"
    fi
  fi
}

recover_cmd() {
  local assume_yes=0
  local answer=""
  local preview_digest=""
  local status=0

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --yes|-y) assume_yes=1 ;;
      --help|-h|help) usage; return 0 ;;
      *) die "未知的 recover 参数：${1}" ;;
    esac
    shift
  done
  need_root
  if ! pending_operation_present; then
    log "没有未完成的托管操作。"
    return 0
  fi
  if ! pending_operation_validate; then
    warn "恢复清单无效，未修改文件或服务：${PENDING_OP_FILE}。请保留现场检查备份。"
    return 1
  fi
  preview_digest="$(backup_file_digest "${PENDING_OP_FILE}")" || return 1
  log "待处理操作：$(pending_operation_text)"
  if [[ "${assume_yes}" -eq 0 ]]; then
    read_line_or_cancel answer "按持久清单恢复操作前文件和服务（已提交的操作只完成清理）？ [y/N]: " || return $?
    case "${answer}" in
      y|Y|yes|YES) ;;
      *) warn "已取消恢复。"; return 130 ;;
    esac
  fi
  acquire_script_lock || return 1
  if [[ "$(backup_file_digest "${PENDING_OP_FILE}")" != "${preview_digest}" ]]; then
    warn "确认期间恢复清单已变化，请重新查看后恢复。"
    release_script_lock
    return 1
  fi
  OPERATION_LOG_ENABLED=1
  install_mutation_traps
  recover_generation || status=1
  generation_report_recovery "恢复操作"
  if [[ "${GENERATION_RECOVERY_RESULT}" != committed && -f "${BACKUP_DIR}/install-stage.txt" ]]; then
    install_report_failure_context
  fi
  release_script_lock
  return "${status}"
}

uninstall_cmd() {
  local assume_yes=0
  local purge_packages=0
  local preview_fingerprint=""
  local locked_fingerprint=""
  local answer=""
  local unit_name=""
  local units=()
  local acme_cert_dir=""
  local item=""
  local haproxy_shared=0
  local haproxy_original=""
  local haproxy_original_existed=""
  local haproxy_config_remove=0
  local -a managed_paths=()
  local -a kept_services=()
  # 卸载报告：删了哪些、还原了哪些、留下哪些、哪些没能确认。
  # 少写一句「已保留」，用户就只能靠猜。
  local -a UNINSTALL_REMOVED=()
  local -a UNINSTALL_KEPT=()
  local -a UNINSTALL_UNCONFIRMED=()

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --purge)
        purge_packages=1
        ;;
      --yes|-y)
        assume_yes=1
        ;;
      --help|-h|help)
        usage
        exit 0
        ;;
      *)
        die "未知的 uninstall 参数：${1}"
        ;;
    esac
    shift
  done

  need_root
  load_existing_state
  preview_fingerprint="$(install_environment_fingerprint)" || return 1

  if [[ "${assume_yes}" -ne 1 ]]; then
    read_line_or_cancel answer "该操作会停止服务并删除脚本托管文件，但保留已安装的软件包。是否继续？ [y/N]: " || return $?
    answer="$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${answer}" != "y" && "${answer}" != "yes" ]]; then
      die "已取消卸载。"
    fi
    if [[ "${purge_packages}" -eq 1 ]]; then
      read_line_or_cancel answer "是否同时卸载软件包？输入 purge 确认（其它任何输入只删托管文件）： " || return $?
      if [[ "${answer}" != "purge" ]]; then
        purge_packages=0
      fi
    fi
  fi

  locked_fingerprint="$(install_environment_fingerprint)" || return 1
  if [[ "${locked_fingerprint}" != "${preview_fingerprint}" ]]; then
    warn "确认期间卸载现场发生变化，本次确认已失效，请重新查看预览。"
    return 1
  fi

  start_backup_session || return 1
  locked_fingerprint="$(install_environment_fingerprint)" || return 1
  if [[ "${locked_fingerprint}" != "${preview_fingerprint}" ]]; then
    warn "获得锁后卸载现场发生变化，本次确认已失效，请重新查看预览。"
    return 1
  fi

  # xray 的 unit 和核心是我们自己装的，卸载就该停；
  # haproxy/nginx 可能是用户为了别的站点早就装好的——那就不该因为卸 xtun 把它们停掉，
  # 只把我们的配置摘掉，再让服务自己 reload 一次。
  while IFS= read -r unit_name; do
    if managed_service_preinstalled "${unit_name}"; then
      [[ "${unit_name}" == "haproxy.service" ]] && haproxy_shared=1
      UNINSTALL_KEPT+=("${unit_name} 保持运行（安装前已存在，可能还托管其它站点）")
      kept_services+=("${unit_name}")
      continue
    fi
    stop_and_disable_service_if_present "${unit_name}"
  done < <(xray_managed_service_units)

  # acme.sh 是共享安装：只摘掉为这个域名申请的那份证书，
  # 本体和别人的证书都留着，不然一次 uninstall 会把别的站点续期也一起弄断。
  if [[ "${CERT_MODE:-}" == "acme-dns-cf" && -x "${ACME_SH_BIN}" && -n "${XHTTP_DOMAIN:-}" ]]; then
    "${ACME_SH_BIN}" --remove -d "${XHTTP_DOMAIN}" --ecc >/dev/null 2>&1 || true
    acme_cert_dir="${ACME_HOME}/${XHTTP_DOMAIN}_ecc"
    if [[ -d "${acme_cert_dir}" ]]; then
      backup_path "${acme_cert_dir}" || return 1
      rm -rf "${acme_cert_dir}" || return 1
      UNINSTALL_REMOVED+=("${acme_cert_dir}（xtun 为 ${XHTTP_DOMAIN} 申请的证书）")
    fi
    if [[ -d "${ACME_HOME}" ]]; then
      UNINSTALL_KEPT+=("${ACME_HOME}（acme.sh 本体，可能还有其它域名的证书）")
    fi
  fi

  if [[ "${haproxy_shared}" -eq 1 ]]; then
    haproxy_original="$(takeover_original_path "${HAPROXY_CONFIG}")"
    if [[ -e "${haproxy_original}" || -L "${haproxy_original}" ]]; then
      if restore_takeover_original "${HAPROXY_CONFIG}"; then
        UNINSTALL_KEPT+=("${HAPROXY_CONFIG}（已还原共享 HAProxy 操作前配置）")
      else
        warn "共享 HAProxy 的首次原件或登记校验失败，保留当前配置与恢复证据。"
        UNINSTALL_UNCONFIRMED+=("${HAPROXY_CONFIG}（共享 HAProxy 原件校验失败）")
      fi
    else
      haproxy_original_existed="$(takeover_original_existed "${HAPROXY_CONFIG}" 2>/dev/null || true)"
      if [[ "${haproxy_original_existed}" == "0" ]]; then
        warn "共享 HAProxy 接管前没有配置；当前配置仍是服务启动所需文件，本次保留并报告未完成清理。"
        UNINSTALL_UNCONFIRMED+=("${HAPROXY_CONFIG}（共享 HAProxy，接管前配置不存在）")
      else
        warn "找不到共享 HAProxy 配置的可信原件；为避免仍在运行的外来服务失去配置，本次保留 ${HAPROXY_CONFIG}。"
        UNINSTALL_UNCONFIRMED+=("${HAPROXY_CONFIG}（共享 HAProxy，缺少可核对的配置清理结果）")
      fi
    fi
  fi

  restore_nginx_main_config || return 1

  # 安装时若宿主已有自己的 xray.service / xray 核心，登记表里会是 existed=1。
  # 这两条路径属于别人，卸载要还原而不是删除（D11/D20.4，复核 H31/H32）。
  local xray_service_preexisted=0
  local xray_bin_preexisted=0
  if [[ -e "$(takeover_original_record_file)" || -L "$(takeover_original_record_file)" ]]; then
    xray_service_preexisted="$(takeover_original_existed "${XRAY_SERVICE_FILE}" 2>/dev/null || printf '0')"
    xray_bin_preexisted="$(takeover_original_existed "${XRAY_BIN}" 2>/dev/null || printf '0')"
  fi

  managed_paths=(
    "${SELF_COMMAND_PATH}"
    "${SELF_INSTALL_DIR}"
    "${XRAY_CONFIG_DIR}"
    "${XRAY_ASSET_DIR}"
    "${WARP_RULES_FILE}"
    "${XRAY_LOGROTATE_FILE}"
  )
  # 只有确认是 xtun 自己创建的核心与 unit 才删除；接管来的留给下面的还原分支。
  [[ "${xray_bin_preexisted}" == 1 ]] || managed_paths+=("${XRAY_BIN}")
  [[ "${xray_service_preexisted}" == 1 ]] || managed_paths+=("${XRAY_SERVICE_FILE}")
  if [[ "${haproxy_shared}" -eq 0 || "${haproxy_config_remove}" -eq 1 ]]; then
    managed_paths+=("${HAPROXY_CONFIG}")
  fi
  managed_paths+=(
    "${NGINX_CONFIG_FILE}"
    "${NGINX_LIMITS_DROPIN_FILE}"
    "${FALLBACK_SITE_DIR}"
    "${SSL_DIR}"
    "${NET_SYSCTL_CONF}"
    "${NET_HELPER_PATH}"
    "${NET_SERVICE_FILE}"
    "${ACME_RELOAD_HELPER}"
    "${OUTPUT_FILE}"
    "${QR_OUTPUT_DIR}"
    "${XRAY_LOG_DIR}"
    "${XRAY_STATE_DIR}"
    "${OP_LOG_DIR}"
  )
  # 删不掉就别往下报「已卸载」：config.json 和证书里有机密，留在盘上而用户以为
  # 已经清干净了，是这条命令上最糟的结果。重跑一次是幂等的。
  remove_managed_paths "${managed_paths[@]}" || return 1
  remove_legacy_managed_paths || return 1

  # 接管来的文件还原回原路径；失败时保留登记表与原件副本作为用户退路。
  if [[ "${xray_service_preexisted}" == 1 ]]; then
    if restore_takeover_original "${XRAY_SERVICE_FILE}"; then
      UNINSTALL_KEPT+=("${XRAY_SERVICE_FILE}（已还原安装前的 xray.service）")
    else
      warn "xray.service 的首次原件或登记校验失败，保留原件副本与登记表。"
      UNINSTALL_UNCONFIRMED+=("${XRAY_SERVICE_FILE}（接管前已存在，但还原失败）")
    fi
  fi
  if [[ "${xray_bin_preexisted}" == 1 ]]; then
    if restore_takeover_original "${XRAY_BIN}"; then
      UNINSTALL_KEPT+=("${XRAY_BIN}（已还原安装前的核心二进制）")
    else
      warn "xray 核心的首次原件或登记校验失败，保留原件副本与登记表。"
      UNINSTALL_UNCONFIRMED+=("${XRAY_BIN}（接管前已存在，但还原失败）")
    fi
  fi

  systemctl daemon-reload || return 1

  # 文件还原后按接管前记录恢复启用/运行状态；只还原文件不还原状态，
  # 用户的服务会静静地不上线（D20.4）。
  if [[ "${xray_service_preexisted}" == 1 ]]; then
    if restore_takeover_original_service_state "xray.service"; then
      UNINSTALL_KEPT+=("xray.service（已按接管前记录还原启用/运行状态）")
    else
      warn "xray.service 文件已还原，但缺少可核对的状态记录，未自动启用。"
      UNINSTALL_UNCONFIRMED+=("xray.service（已还原文件，未还原启用/运行状态）")
    fi
  fi
  for item in "${kept_services[@]}"; do
    [[ "$(service_active_state "${item}")" == "active" ]] || continue
    if ! systemctl reload "${item}" >/dev/null 2>&1 \
      || ! service_reaches_active_state "${item}"; then
      UNINSTALL_UNCONFIRMED+=("${item}（共享服务 reload 后未确认回到 active）")
      warn "${item} reload 失败或 reload 后不是 active，保留现场。"
    fi
  done
  mapfile -t units < <(xray_managed_service_units)
  systemctl reset-failed "${units[@]}" >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || true

  if [[ "${purge_packages}" -eq 1 ]]; then
    log_step "卸载脚本安装的软件包。"
    purge_managed_packages
    log "已尝试卸载脚本安装的软件包。"
  else
    UNINSTALL_KEPT+=("已安装的软件包（未请求 --purge）")
  fi

  # 原件登记表只在「原件已经真的还回去了」之后才能删。
  # 没能确认归属、当前文件原样保留时，那份副本是用户唯一的退路。
  if [[ -d "${ORIGINALS_ROOT}" ]]; then
    if [[ "${#UNINSTALL_UNCONFIRMED[@]}" -gt 0 ]]; then
      UNINSTALL_KEPT+=("${ORIGINALS_ROOT}（原件副本，确认不再需要后可自行删除）")
    else
      rm -rf "${ORIGINALS_ROOT}" || return 1
      UNINSTALL_REMOVED+=("${ORIGINALS_ROOT}（原件与包归属登记表）")
    fi
  fi

  log_step "卸载结果"
  if [[ "${#UNINSTALL_REMOVED[@]}" -gt 0 ]]; then
    for item in "${UNINSTALL_REMOVED[@]}"; do
      log "已删除：${item}"
    done
  fi
  if [[ "${#UNINSTALL_KEPT[@]}" -gt 0 ]]; then
    for item in "${UNINSTALL_KEPT[@]}"; do
      log "已保留：${item}"
    done
  fi
  if [[ "${#UNINSTALL_UNCONFIRMED[@]}" -gt 0 ]]; then
    for item in "${UNINSTALL_UNCONFIRMED[@]}"; do
      warn "未能确认：${item}"
    done
  fi

  log "备份目录：${BACKUP_DIR}"
  [[ "${#UNINSTALL_UNCONFIRMED[@]}" -eq 0 ]] || return 1
}

menu_install_task() {
  local answer=""
  local default_task=""
  local task=""
  local index=0
  local selection=""
  local discard_draft=0
  local INPUT_BACK_HANDLED=yes
  local -a tasks=()
  local -a labels=()

  while IFS= read -r task; do
    tasks+=("${task}")
    labels+=("$(install_task_label "${task}")")
  done < <(install_task_selection_order)
  default_task="${tasks[0]}"

  # 丢弃草稿也是一次明确选择：不把它藏在「重装」里悄悄发生（D06）。
  if install_draft_present; then
    tasks+=("discard-draft")
    labels+=("丢弃草稿并重新安装（全新安装）")
  fi

  printf '\n安装任务:\n'
  for task in "${tasks[@]}"; do
    index=$((index + 1))
    if [[ "${task}" == "discard-draft" ]]; then
      printf '  %s. %s\n' "${index}" "${labels[index - 1]}"
      continue
    fi
    printf '  %s. %s — %s\n' "${index}" "${labels[index - 1]}" "$(install_task_availability_text "${task}")"
  done
  printf '  0. 返回主菜单\n'

  while true; do
    read_line_or_cancel answer "请选择任务 [1=$(install_task_label "${default_task}")]: " || return $?
    [[ -n "${answer}" ]] || answer="1"
    if [[ "${answer}" == 0 || "${answer}" == :back ]]; then
      [[ "${IN_MAIN_MENU:-0}" != 1 ]] || return 10
      return 0
    fi
    if [[ "${answer}" =~ ^[1-9]$ ]] && (( answer <= ${#tasks[@]} )); then break; fi
    warn "无效的任务选择：${answer}"
  done

  selection="${tasks[answer - 1]}"
  if [[ "${selection}" == "discard-draft" ]]; then
    discard_draft=1
    selection="fresh"
  fi

  # 菜单只负责选任务：后面的问答、预检和确认与 CLI 完全同一条路径。
  if [[ "${discard_draft}" -eq 1 ]]; then
    run_cli_command install --discard-draft --task "${selection}"
    return
  fi
  run_cli_command install --task "${selection}"
}

menu_install_present() {
  [[ -f "${STATE_FILE}" || -f "${XRAY_CONFIG_FILE}" ]]
}

show_main_menu() {
  if menu_install_present; then
    cat <<'EOF'
  1. 获取节点
  2. 查看状态与诊断
  3. 修改节点
  4. 升级与维护
  5. 网络与可选功能
  6. 恢复与卸载
  0. 退出
EOF
  else
    cat <<'EOF'
  1. 安装 / 恢复草稿（先选任务）
  2. 检查环境与端口
  3. 检查 REALITY SNI
  4. 帮助
  0. 退出
EOF
  fi
  printf '输入 :cancel 取消动作；填写字段时 :back 返回编辑。\n'
}

show_task_menu() {
  case "${1}" in
    nodes)
      (show_links --summary) || printf '节点文档不可用；可返回主菜单诊断。\n'
      printf '\n输入节点编号复制链接；q N 查看该节点二维码；all 查看完整文档。\n'
      printf 'j N 导出 NAS / 原生 JSON（可选择 current / plain / ech）。\n'
      ;;
    status)
      printf '查看状态与诊断\n  1. 完整状态\n  2. 深度诊断\n  3. 检查 REALITY SNI\n  4. 上次动作与恢复信息\n'
      ;;
    change)
      printf '修改节点\n  1. 轮换 UUID\n  2. 修改 REALITY SNI\n  3. 修改 XHTTP 路径\n  4. 修改证书来源 / CDN 域名\n'
      ;;
    maintenance)
      printf '升级与维护\n  1. 升级 Xray 核心\n  2. 更新脚本\n  3. 重启服务\n  4. 抢修文件权限\n  5. 重建托管配置\n  6. 续期 / 刷新证书\n  7. 安装任务（恢复草稿 / 重建 / 轮换）\n  8. 独立重建二维码\n  9. 显式重装 Xray 核心\n'
      ;;
    network)
      printf '网络与可选功能\n  1. 开关 WARP\n  2. 查看 WARP 规则\n  3. 修改 WARP 规则\n  4. 开关 H3 直连\n  5. 重新应用网络优化\n  6. IPv6 / ECH 等高级项（沿用身份重建）\n'
      ;;
    recovery)
      printf '恢复与卸载\n  1. 恢复未完成操作\n  2. 查看操作与备份信息\n  3. 卸载\n'
      ;;
  esac
  printf '  0. 返回主菜单\n'
}

show_operation_details() {
  if pending_operation_present; then
    printf '未完成操作: %s\n恢复命令: xtun recover\n' "$(pending_operation_text)"
  else
    printf '没有未完成的托管操作。\n'
  fi
  printf '最近备份: %s\n操作日志: %s\n' "$(latest_backup_label)" "${OP_LOG_FILE}"
  if [[ -r "${OP_LOG_FILE}" ]]; then tail -n 12 "${OP_LOG_FILE}"; fi
}

menu_uuid_change() {
  local choice="" INPUT_BACK_HANDLED=yes
  while true; do
    read_line_or_cancel choice '轮换 UUID：1=全部，2=REALITY，3=XHTTP，0=返回: ' || return $?
    case "${choice}" in
      1) run_cli_command change-uuid; return $? ;;
      2) run_cli_command change-uuid --reality-only; return $? ;;
      3) run_cli_command change-uuid --xhttp-only; return $? ;;
      0|:back) return 10 ;;
      *) warn '请输入 1、2、3 或 0。' ;;
    esac
  done
}

menu_warp_rules_change() {
  local choice="" domain="" INPUT_BACK_HANDLED=yes
  while true; do
    read_line_or_cancel choice '规则操作：add=添加，del=删除，reset=恢复默认，0=返回: ' || return $?
    case "${choice}" in
      add|del)
        read_line_or_cancel domain '域名或 domain:/geosite: 规则: ' || return $?
        [[ "${domain}" != :back ]] || continue
        run_cli_command change-warp-rules "--${choice}-domain" "${domain}"
        return $?
        ;;
      reset) run_cli_command change-warp-rules --reset-defaults; return $? ;;
      0|:back) return 10 ;;
      *) warn '请输入 add、del、reset 或 0。' ;;
    esac
  done
}

pause_after_menu_action() {
  printf '\n'
  print_input_prompt "按回车继续..." || return 1
  if ! read -r _; then
    exit 0
  fi
}

run_cli_command() {
  local command="${1:-menu}"
  local status=0
  local previous_operation_log_enabled="${OPERATION_LOG_ENABLED:-1}"
  local previous_backup_dir="${BACKUP_DIR:-}"
  local NON_INTERACTIVE=0 SKIP_SNI_CHECK=0
  local INPUT_BACK_HANDLED=no
  local -a INPUT_FIELD_NAMES=() INPUT_FIELD_PROMPTS=() INPUT_FIELD_SECRET=() INPUT_FIELD_VALIDATORS=()
  local -A CHANGE_BEFORE=()
  local CHANGE_PREVIEW_FINGERPRINT=""

  if [[ $# -gt 0 ]]; then
    shift
  fi

  # 这里先把操作日志关掉：帮助、未知参数、缺值、EOF 和只读查看都不该写
  # /var/log/xtun。真正的写操作在开始改动时经 begin_mutation 打开日志并抢锁。
  OPERATION_LOG_ENABLED=0

  # 版本选择同样是「每次动作自己的」：进来先丢掉上一次动作的遗留（H15）。
  xray_release_version_context

  # 这个 `||` 把 xtun.sh 开头那句 set -Eeuo pipefail 关掉了，而且不只关一层：
  # bash 的 errexit 豁免会顺着整条动态调用链一路传到最底层的函数里。
  # 也就是说，dispatch 底下所有代码都跑在「失败不中止」的状态里，
  # 每一步是否把失败传出来，全靠显式的 `|| return 1`（tests 里有 lint 钉着）。
  # 菜单动作在子 shell 里执行；子 shell 失败只影响本次动作，主菜单继续。
  dispatch_cli_command "${command}" "$@" || status=$?

  # 操作成功才算一个完整的恢复点：失败或中断的那一份是排障现场，保留规则不许清。
  if [[ "${GENERATION_ACTIVE:-no}" == "yes" ]]; then
    generation_failed "动作退出时仍有未提交的托管变更" || true
    [[ "${status}" -ne 0 ]] || status=1
  elif [[ "${status}" -eq 0 && "${BACKUP_DIR:-}" != "${previous_backup_dir}" && "${BACKUP_SESSION_OPEN:-no}" == "yes" ]]; then
    finish_backup_session || status=1
  fi
  BACKUP_SESSION_OPEN="no"

  # 锁可能在 dispatch 中途（begin_mutation）才拿到，这里按实际状态回收：
  # 命令失败、返回非零都不能把锁留给自己，否则同一进程里的下一次动作进不来。
  if [[ "${SCRIPT_LOCK_HELD:-0}" -eq 1 ]]; then
    release_script_lock
  fi
  OPERATION_LOG_ENABLED="${previous_operation_log_enabled}"

  # 结束即释放：下一次动作按自己的请求重新解析，不沿用这一次的选择（H15）。
  xray_release_version_context

  return "${status}"
}
dispatch_cli_command() {
  local command="${1:-menu}"

  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "${command}" in
    menu)
      main_menu
      ;;
    install)
      install_cmd "$@"
      ;;
    update-script)
      update_script_cmd "$@"
      ;;
    upgrade)
      upgrade_cmd "$@"
      ;;
    recover)
      recover_cmd "$@"
      ;;
    check-sni)
      sni_check_cmd "$@"
      ;;
    change-uuid)
      change_uuid_cmd "$@"
      ;;
    change-sni)
      change_sni_cmd "$@"
      ;;
    change-path)
      change_path_cmd "$@"
      ;;
    change-h3)
      change_h3_cmd "$@"
      ;;
    change-warp)
      change_warp_cmd "$@"
      ;;
    change-warp-rules)
      change_warp_rules_cmd "$@"
      ;;
    change-cert-mode)
      change_cert_mode_cmd "$@"
      ;;
    renew-cert)
      renew_cert_cmd "$@"
      ;;
    acme-deploy)
      acme_deploy_cmd "$@"
      ;;
    uninstall)
      uninstall_cmd "$@"
      ;;
    show-links)
      show_links "$@"
      ;;
    export-client)
      export_client_cmd "$@"
      ;;
    rebuild-qr)
      rebuild_qr_cmd "$@"
      ;;
    diagnose)
      diagnose_cmd "$@"
      ;;
    status)
      status_cmd "$@"
      ;;
    restart)
      restart_cmd "$@"
      ;;
    repair-perms)
      repair_perms_cmd "$@"
      ;;
    apply-config)
      apply_config_cmd "$@"
      ;;
    apply-net-opt)
      apply_net_opt_cmd "$@"
      ;;
    help|--help|-h)
      usage
      ;;
    version|--version|-v)
      printf 'xtun.sh v%s\n' "${SCRIPT_VERSION}"
      ;;
    *)
      die "未知命令：${command}"
      ;;
  esac
}

menu_export_client() {
  local number="${1}" variant="" output=""
  prompt_with_default variant '变体 current / plain / ech' current || return $?
  prompt_with_default output 'JSON 输出文件' "/root/xtun-clients/node-${number}-${variant}.json" || return $?
  run_cli_command export-client --node "${number}" --variant "${variant}" --format json --output "${output}"
}

run_menu_choice() {
  local group="${1}" choice="${2:-}" version=""
  case "${group}:${choice}" in
    fresh:1) menu_install_task ;;
    fresh:2) install_readonly_prechecks ;;
    fresh:3|status:3) run_cli_command check-sni ;;
    fresh:4) run_cli_command help ;;
    nodes:s) run_cli_command show-links --summary ;;
    nodes:all) run_cli_command show-links ;;
    nodes:[1-9]) run_cli_command show-links --node "${choice}" ;;
    nodes:q\ [1-9]) run_cli_command show-links --qr --node "${choice#q }" ;;
    nodes:j\ [1-9]) menu_export_client "${choice#j }" ;;
    status:1) run_cli_command status ;;
    status:2) run_cli_command diagnose ;;
    status:4|recovery:2) show_operation_details ;;
    change:1) menu_uuid_change ;;
    change:2) run_cli_command change-sni ;;
    change:3) run_cli_command change-path ;;
    change:4) run_cli_command change-cert-mode ;;
    maintenance:1)
      read_line_or_cancel version 'Xray 版本 [latest-published，或 vX.Y.Z]: ' || return $?
      run_cli_command upgrade --xray-version "${version:-latest-published}"
      ;;
    maintenance:2) run_cli_command update-script ;;
    maintenance:3) run_cli_command restart ;;
    maintenance:4) run_cli_command repair-perms ;;
    maintenance:5) run_cli_command apply-config ;;
    maintenance:6) run_cli_command renew-cert ;;
    maintenance:7) menu_install_task ;;
    maintenance:8) run_cli_command rebuild-qr ;;
    maintenance:9)
      read_line_or_cancel version '重新安装 Xray 版本 [latest-published，或 vX.Y.Z]: ' || return $?
      run_cli_command upgrade --reinstall --xray-version "${version:-latest-published}"
      ;;
    network:1) run_cli_command change-warp ;;
    network:2) run_cli_command change-warp-rules --list ;;
    network:3) menu_warp_rules_change ;;
    network:4) run_cli_command change-h3 ;;
    network:5) run_cli_command apply-net-opt ;;
    network:6) run_cli_command install --task rebuild ;;
    recovery:1) run_cli_command recover ;;
    recovery:3) run_cli_command uninstall ;;
    *)
      warn "未知的菜单项：${choice}"
      return 1
      ;;
  esac
}

main_menu() {
  local choice=""
  local action_status=0
  local menu_exit_status=0
  local group="" old_int_trap="" old_term_trap=""
  local menu_action_pid="" menu_signal="" menu_input_fd=""
  local INPUT_BACK_HANDLED=yes
  old_int_trap="$(trap -p INT)"
  old_term_trap="$(trap -p TERM)"
  # wait 必须可以处理中断。TERM 可能只发给菜单 PID，需转交给动作并等恢复完成；
  # 终端 Ctrl-C 已发给整个前台进程组，不重复发送以免打断正在进行的恢复。
  exec {menu_input_fd}<&0
  trap 'menu_signal=INT' INT
  trap 'menu_signal=TERM; [[ -z "${menu_action_pid}" ]] || kill -TERM "${menu_action_pid}" 2>/dev/null || true' TERM

  while true; do
    if [[ -t 1 ]]; then
      clear >/dev/null 2>&1 || true
    fi
    if [[ -z "${group}" ]]; then
      show_dashboard_brief || warn "当前配置读取失败；可使用诊断或恢复入口。"
      show_main_menu
    else
      show_task_menu "${group}" || true
    fi
    print_input_prompt "请选择: " || break
    [[ "${menu_signal}" != TERM ]] || break
    if ! read -r choice; then
      break
    fi
    if [[ "${choice}" == 0 || "${choice}" == :back || "${choice}" == :cancel ]]; then
      if [[ -n "${group}" ]]; then group=""; continue; fi
      break
    fi
    if [[ -z "${group}" ]] && menu_install_present; then
      case "${choice}" in
        1) group=nodes; continue ;;
        2) group=status; continue ;;
        3) group=change; continue ;;
        4) group=maintenance; continue ;;
        5) group=network; continue ;;
        6) group=recovery; continue ;;
      esac
    fi
    action_status=0
    menu_signal=""
    (
      trap 'input_cancel_action' INT
      trap 'exit 143' TERM
      reset_loaded_runtime_context
      IN_MAIN_MENU=1 run_menu_choice "${group:-fresh}" "${choice}"
    ) <&"${menu_input_fd}" &
    menu_action_pid=$!
    while true; do
      action_status=0
      wait "${menu_action_pid}" || action_status=$?
      # trap 会打断 wait，但此时子进程可能仍在恢复；不能马上重画菜单或退出。
      kill -0 "${menu_action_pid}" 2>/dev/null || break
    done
    menu_action_pid=""
    [[ "${menu_signal}" != TERM ]] || break
    case "${action_status}" in
      0) ;;
      10) continue ;;
      130) warn '当前动作已取消，返回菜单。'; continue ;;
      131) break ;;
      143) menu_signal=TERM; break ;;
      *) warn '菜单操作失败，返回可用菜单；如有未完成动作，请运行 xtun recover。' ;;
    esac
    if ! pause_after_menu_action; then
      menu_exit_status=1
      break
    fi
  done
  trap - INT TERM
  [[ -z "${old_int_trap}" ]] || eval "${old_int_trap}"
  [[ -z "${old_term_trap}" ]] || eval "${old_term_trap}"
  exec {menu_input_fd}<&-
  [[ "${menu_signal}" != TERM ]] || return 143
  return "${menu_exit_status}"
}
