# shellcheck shell=bash

# ------------------------------
# CLI 核心层
# 负责状态、菜单、分发与通用维护命令
# ------------------------------

render_output_file_qr() {
  if ! have_qrencode; then
    warn "系统中未找到 qrencode，无法输出二维码；apt-get install -y qrencode 后重试。"
    return
  fi

  printf '\n'
  while IFS= read -r link; do
    [[ "${link}" == vless://* ]] || continue
    printf '%s\n' "二维码 (${link##*#}):"
    qrencode -t ANSIUTF8 "${link}" || true
    printf '\n'
  done < "${OUTPUT_FILE}"
}

show_links_summary() {
  local node_number=""
  local label=""
  local link_count=0

  printf '\n%s\n' "节点链接摘要"
  printf '链接文件: %s\n' "${OUTPUT_FILE}"
  printf '完整内容: xtun show-links\n'
  printf '终端二维码: xtun show-links --qr\n'
  printf '\n'

  while IFS=$'\t' read -r node_number label; do
    [[ -n "${node_number}" ]] || continue
    link_count=$((link_count + 1))
    printf '节点 %s: %s\n' "${node_number}" "${label}"
  done < <(
    awk '
      /^## 节点 [0-9]+$/ { node_number=$3; next }
      /^vless:\/\// {
        label=$0
        sub(/^.*#/, "", label)
        print node_number "\t" label
      }
    ' "${OUTPUT_FILE}"
  )

  if [[ "${link_count}" -eq 0 ]]; then
    warn "输出文件中没有找到节点链接。"
  fi
}

show_links() {
  local show_qr=0
  local summary=0

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --qr)
        show_qr=1
        ;;
      --summary)
        summary=1
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

  if [[ "${summary}" -eq 1 ]]; then
    show_links_summary
    return
  fi

  cat "${OUTPUT_FILE}"

  if [[ "${show_qr}" -eq 1 ]]; then
    render_output_file_qr
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

  if service_exists "${unit_name}"; then
    systemctl restart "${unit_name}" >/dev/null 2>&1 || true
  fi
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
  local warp_probe_result=""
  local -a service_failures=()
  local -a port_failures=()
  local -a config_failures=()
  local -a tls_failures=()
  local -a warp_failures=()

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

  load_dashboard_context

  xray_state="$(service_active_state 'xray.service')"
  haproxy_state="$(service_active_state 'haproxy.service')"
  nginx_state="$(service_active_state 'nginx.service')"

  printf '%s\n' "Xray 诊断"
  printf '%s\n' "脚本版本: ${SCRIPT_VERSION}"
  printf '%s\n' "xray: ${xray_state}"
  printf '%s\n' "haproxy: ${haproxy_state}"
  printf '%s\n' "nginx: ${nginx_state}"
  printf '%s\n' "监听 443: $(listening_port_text 443)"
  printf '%s\n' "监听 2443: $(listening_port_text 2443)"
  printf '%s\n' "监听 ${REALITY_FALLBACK_PORT}: $(listening_port_text "${REALITY_FALLBACK_PORT}")"
  printf '%s\n' "监听 8001: $(listening_port_text 8001)"
  printf '%s\n' "监听 8443: $(listening_port_text 8443)"
  printf '%s\n' "XHTTP H3: $(if h3_enabled; then printf '已启用（Alt-Svc h3=:443）'; else printf '未启用（%s）' "$(h3_disabled_reason)"; fi)"
  printf '%s\n' "QUIC (UDP 443): $(quic_port_text)"
  printf '%s\n' "监听 [::]:443: $(if ss -ltnH '( sport = :443 )' 2>/dev/null | grep -q '\[::\|\*:'; then printf '运行中'; else printf '未监听'; fi)"
  printf '%s\n' "Xray 配置: $(xray_config_check_text)"
  printf '%s\n' "Nginx 配置: $(nginx_config_check_text)"
  printf '%s\n' "Nginx worker_connections: $(nginx_worker_connections_text)"
  printf '%s\n' "HAProxy 配置: $(haproxy_config_check_text)"
  printf '%s\n' "本地 TLS 探测: $(local_tls_probe_text)"
  printf '%s\n' "路由拦截: $(xray_routing_block_text)"
  printf '%s\n' "证书到期: $(cert_expiry_text)"
  printf '%s\n' "WARP 出站: $(warp_outbound_text)"
  printf '%s\n' "WARP 规则数: $(warp_rule_count_text)"
  printf '%s\n' "WARP Endpoint 解析: $(warp_endpoint_resolve_text)"
  if [[ "${run_warp_probe}" -eq 1 ]]; then
    warp_probe_result="$(warp_egress_probe_text)"
    printf '%s\n' "WARP 出口 IP: ${warp_probe_result}"
  fi
  if [[ "${run_net_check}" -eq 1 ]]; then
    printf '%s\n' "-- 网络栈 --"
    net_stack_text
  fi

  [[ "${xray_state}" == "active" ]] || service_failures+=("xray 未运行")
  [[ "${haproxy_state}" == "active" ]] || service_failures+=("haproxy 未运行")
  [[ "${nginx_state}" == "active" ]] || service_failures+=("nginx 未运行")
  is_port_listening 443 || port_failures+=("443 未监听")
  is_port_listening 2443 || port_failures+=("2443 未监听")
  is_port_listening 8001 || port_failures+=("8001 未监听")
  is_port_listening 8443 || port_failures+=("8443 未监听")
  [[ "$(xray_config_check_state)" == "ok" ]] || config_failures+=("Xray 配置校验失败")
  [[ "$(nginx_config_check_state)" == "ok" ]] || config_failures+=("Nginx 配置校验失败")
  [[ "$(haproxy_config_check_state)" == "ok" ]] || config_failures+=("HAProxy 配置校验失败")
  [[ "$(local_tls_probe_state)" == "ok" ]] || tls_failures+=("本地 TLS 探测失败")
  if [[ "${run_net_check}" -eq 1 ]]; then
    [[ "$(net_stack_state)" == "ok" ]] || config_failures+=("拥塞控制不是 bbr 系")
  fi
  if h3_enabled; then
    case "$(quic_port_text)" in
      "运行中"|"有 UDP 监听，无法确认归属（需要 root）") ;;
      *) port_failures+=("QUIC (UDP 443) 未监听或非 nginx 监听") ;;
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

restart_cmd() {
  local unit_name=""

  load_dashboard_context
  while IFS= read -r unit_name; do
    restart_service_if_present "${unit_name}"
  done < <(restart_service_units)
  log "服务已重启。"
}

repair_perms_cmd() {
  need_root
  # 这条命令存在的意义就是「权限坏了来抢修」，抢修没成还报成功是最坏的结果。
  ensure_xray_user || return 1
  ensure_managed_permissions || return 1
  systemctl daemon-reload || return 1
  systemctl restart xray haproxy nginx >/dev/null 2>&1 || true
  log "已修复脚本托管文件权限，并尝试重启 xray、haproxy 与 nginx。"
}

# 脚本升级后，托管的 haproxy.cfg / nginx.conf / config.json 仍是旧模板渲染出来的，
# 除非正好跑一次 change-* 或重装，新版模板里的调优参数不会自己生效。
# 这条命令就是那个「按当前状态重渲染一遍」的入口。
apply_config_cmd() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --help|-h|help)
        usage
        exit 0
        ;;
      *)
        die "未知的 apply-config 参数：${1}"
        ;;
    esac
  done

  need_root
  start_backup_session
  log_step "读取当前托管安装状态。"
  load_current_install_context
  remove_legacy_managed_paths || return 1
  ensure_xray_user || return 1

  log_step "按当前状态重新生成托管配置。"
  apply_managed_runtime_update || return 1
  finish_managed_change "托管配置已按当前状态重新生成。" "no"
}

apply_net_opt_cmd() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --help|-h|help)
        usage
        exit 0
        ;;
      *)
        die "未知的 apply-net-opt 参数：${1}"
        ;;
    esac
  done

  need_root
  ensure_debian_family
  start_backup_session
  log_step "读取当前托管安装状态。"
  load_current_install_context

  ENABLE_NET_OPT="yes"
  NET_BBRV3_REBOOT_REQUIRED="no"
  log_step "应用 Joey BBRv3 网络优化。"
  install_network_optimization || return 1
  write_state_file || return 1

  log_success "网络优化已应用。"
  log "备份目录：${BACKUP_DIR}"
  if [[ "${NET_BBRV3_REBOOT_REQUIRED:-no}" == "yes" ]]; then
    if ! bbr_v3_active; then
      log "请重启 VPS 后加载 Joey BBRv3 内核。"
    fi
  fi
}

uninstall_cmd() {
  local assume_yes=0
  local purge_packages=0
  local answer=""
  local unit_name=""
  local units=()

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
  start_backup_session
  load_existing_state

  if [[ "${assume_yes}" -ne 1 ]]; then
    read -r -p "该操作会停止服务并删除脚本托管文件，但保留已安装的软件包。是否继续？ [y/N]: " answer
    answer="$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${answer}" != "y" && "${answer}" != "yes" ]]; then
      die "已取消卸载。"
    fi
    if [[ "${purge_packages}" -eq 1 ]]; then
      read -r -p "是否同时卸载软件包？输入 purge 确认（其它任何输入只删托管文件）: " answer
      if [[ "${answer}" != "purge" ]]; then
        purge_packages=0
      fi
    fi
  fi

  while IFS= read -r unit_name; do
    stop_and_disable_service_if_present "${unit_name}"
  done < <(xray_managed_service_units)

  if [[ "${CERT_MODE:-}" == "acme-dns-cf" && -x "${ACME_SH_BIN}" && -n "${XHTTP_DOMAIN:-}" ]]; then
    "${ACME_SH_BIN}" --remove -d "${XHTTP_DOMAIN}" --ecc >/dev/null 2>&1 || true
  fi

  restore_nginx_main_config || return 1

  # 删不掉就别往下报「已卸载」：config.json 和证书里有机密，留在盘上而用户以为
  # 已经清干净了，是这条命令上最糟的结果。重跑一次是幂等的。
  remove_managed_paths \
    "${SELF_COMMAND_PATH}" \
    "${SELF_INSTALL_DIR}" \
    "${XRAY_BIN}" \
    "${XRAY_CONFIG_DIR}" \
    "${XRAY_ASSET_DIR}" \
    "${WARP_RULES_FILE}" \
    "${XRAY_SERVICE_FILE}" \
    "${XRAY_LOGROTATE_FILE}" \
    "${HAPROXY_CONFIG}" \
    "${NGINX_CONFIG_FILE}" \
    "${NGINX_LIMITS_DROPIN_FILE}" \
    "${FALLBACK_SITE_DIR}" \
    "${SSL_DIR}" \
    "${NET_SYSCTL_CONF}" \
    "${NET_HELPER_PATH}" \
    "${NET_SERVICE_FILE}" \
    "${ACME_RELOAD_HELPER}" \
    "${ACME_HOME}" \
    "${OUTPUT_FILE}" \
    "${QR_OUTPUT_DIR}" \
    "/var/log/xray" \
    "/var/lib/xray" \
    "${OP_LOG_DIR}" \
    || return 1
  remove_legacy_managed_paths || return 1

  systemctl daemon-reload
  mapfile -t units < <(xray_managed_service_units)
  systemctl reset-failed "${units[@]}" >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || true

  if [[ "${purge_packages}" -eq 1 ]]; then
    log_step "卸载脚本安装的软件包。"
    purge_managed_packages
    log "已尝试卸载脚本安装的软件包。"
  fi

  log "脚本托管文件已删除。"
  log "备份目录：${BACKUP_DIR}"
  if [[ "${purge_packages}" -eq 1 ]]; then
    log "软件包卸载流程已结束。"
  else
    log "已安装的软件包已保留。"
  fi
}

show_main_menu() {
  cat <<'EOF'
  1. 安装或重装
  2. 查看节点链接摘要
  3. 运行诊断
  4. 刷新状态面板
  5. 重启服务
  6. 更新脚本本身
  7. 升级 Xray 核心
  8. 轮换节点 UUID
  9. 修改 REALITY SNI
 10. 检查 REALITY SNI 域名
 11. 修改 XHTTP 路径
 12. 开关 WARP 分流
 13. 查看 WARP 分流规则
 14. 修改证书模式 / CDN 域名
 15. 续期 / 刷新证书
 16. 重新应用网络优化
 17. 重新生成托管配置
 18. 抢修文件权限
 19. 卸载
  0. 退出
EOF
}

pause_after_menu_action() {
  printf '\n'
  read -r -p "按回车继续..." _
}

script_lock_command_needs_lock() {
  local command="${1:-menu}"
  local arg=""

  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "${command}" in
    menu|status|diagnose|check-sni|help|--help|-h|version|--version|-v)
      # 菜单本身不写任何东西；菜单里选中的动作会各自再进一次 run_cli_command 并单独加锁。
      return 1
      ;;
    show-links)
      # 只读地 cat 输出文件。
      return 1
      ;;
  esac

  return 0
}

run_cli_command() {
  local command="${1:-menu}"
  local lock_taken=0
  local status=0

  if [[ $# -gt 0 ]]; then
    shift
  fi

  if script_lock_command_needs_lock "${command}" "$@"; then
    if [[ "${SCRIPT_LOCK_HELD}" -eq 0 ]]; then
      acquire_script_lock
      lock_taken=1
    fi
  fi

  # 这个 `||` 把 xtun.sh 开头那句 set -Eeuo pipefail 关掉了，而且不只关一层：
  # bash 的 errexit 豁免会顺着整条动态调用链一路传到最底层的函数里。
  # 也就是说 dispatch 底下所有代码都跑在「失败不中止」的状态里，
  # 每一步是否把失败传出来，全靠显式的 `|| return 1`（tests 里有 lint 钉着）。
  #
  # 别试图在这里「修好」它：
  #   - 换成裸调用能救回 CLI 这条路，但救不了菜单——main_menu 里的
  #     `run_menu_choice ... || true` 是必须的（一次操作失败不能把菜单打死），
  #     那个豁免同样会穿透下去。两条入口只有显式守卫这一个共同机制。
  #   - 子 shell 也救不回来：`( set -e; ... )` 实测照样被豁免（bash 5.2）。
  #   - 这里的 status 也不是为了释放锁：flock 挂在 fd 9 上，进程无论怎么死内核都会
  #     放掉；退化到目录锁时 acquire_script_lock_dir 有 PID 陈旧检测。
  dispatch_cli_command "${command}" "$@" || status=$?

  if [[ "${lock_taken}" -eq 1 ]]; then
    release_script_lock
  fi

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
    uninstall)
      uninstall_cmd "$@"
      ;;
    show-links)
      show_links "$@"
      ;;
    diagnose)
      diagnose_cmd "$@"
      ;;
    status)
      status_cmd "$@"
      ;;
    restart)
      restart_cmd
      ;;
    repair-perms)
      repair_perms_cmd
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

run_menu_choice() {
  case "${1}" in
    1) run_cli_command install ;;
    2) run_cli_command show-links --summary ;;
    3) run_cli_command diagnose ;;
    4) run_cli_command status ;;
    5) run_cli_command restart ;;
    6) run_cli_command update-script ;;
    7) run_cli_command upgrade ;;
    8) run_cli_command change-uuid ;;
    9) run_cli_command change-sni ;;
    10) run_cli_command check-sni ;;
    11) run_cli_command change-path ;;
    12) run_cli_command change-warp ;;
    13) run_cli_command change-warp-rules --list ;;
    14) run_cli_command change-cert-mode ;;
    15) run_cli_command renew-cert ;;
    16) run_cli_command apply-net-opt ;;
    17) run_cli_command apply-config ;;
    18) run_cli_command repair-perms ;;
    19) run_cli_command uninstall ;;
    *)
      warn "未知的菜单项：${1}"
      return 1
      ;;
  esac
}

main_menu() {
  local choice=""

  while true; do
    if [[ -t 1 ]]; then
      clear >/dev/null 2>&1 || true
    fi
    show_dashboard_brief
    show_main_menu
    read -r -p "请选择: " choice
    if [[ "${choice}" == "0" ]]; then
      exit 0
    fi
    IN_MAIN_MENU=1
    # 这个 `|| true` 是菜单必须的：单次操作失败不能把菜单进程带走。
    # 代价是它同样会把整条调用链的 errexit 豁免掉（见 run_cli_command 里的说明），
    # 所以菜单这条路上的失败也只能靠底下的 `|| return 1` 传回来。
    run_menu_choice "${choice}" || true
    IN_MAIN_MENU=0
    pause_after_menu_action
  done
}

