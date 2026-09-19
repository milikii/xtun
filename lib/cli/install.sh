# shellcheck shell=bash

# ------------------------------
# 安装 CLI 层
# 负责 install 参数解析与安装命令编排
# ------------------------------

# 格式：`--选项|变量|值[|互斥组]`。互斥组相同的选项不能同时出现，
# 顺序无关：--enable-warp --disable-warp 和反过来一样报错。
# 分隔符不用冒号：值里可能出现 `https://` 这类文本，冒号分隔会被 read 截断。
install_flag_specs() {
  cat <<'EOF'
--non-interactive|NON_INTERACTIVE|1
--skip-sni-check|SKIP_SNI_CHECK|1
--manage-nginx-main|NGINX_MAIN_MANAGED|yes|nginx-main
--no-manage-nginx-main|NGINX_MAIN_MANAGED|no|nginx-main
--block-cn|ROUTE_BLOCK_CN|yes|block-cn
--no-block-cn|ROUTE_BLOCK_CN|no|block-cn
--enable-xhttp-vless-encryption|XHTTP_VLESS_ENCRYPTION_ENABLED|yes|xhttp-vless-encryption
--disable-xhttp-vless-encryption|XHTTP_VLESS_ENCRYPTION_ENABLED|no|xhttp-vless-encryption
--enable-xhttp-ech|XHTTP_ECH_CONFIG_LIST|https://dns.alidns.com/dns-query|xhttp-ech
--disable-xhttp-ech|XHTTP_ECH_CONFIG_LIST||xhttp-ech
--enable-xhttp-xpadding|XHTTP_XPADDING_ENABLED|yes|xhttp-xpadding
--disable-xhttp-xpadding|XHTTP_XPADDING_ENABLED|no|xhttp-xpadding
--enable-warp|ENABLE_WARP|yes|warp
--disable-warp|ENABLE_WARP|no|warp
--enable-net-opt|ENABLE_NET_OPT|yes|net-opt
--disable-net-opt|ENABLE_NET_OPT|no|net-opt
--enable-h3|H3_INTENT|on|h3
--disable-h3|H3_INTENT|off|h3
--no-ipv6|SERVER_IP6||ipv6
--resume-draft|INSTALL_TASK_REQUEST|resume|task
--rebuild-current|INSTALL_TASK_REQUEST|rebuild|task
--rotate-credentials|INSTALL_TASK_REQUEST|rotate|task
--discard-draft|INSTALL_DRAFT_DISCARD_REQUEST|1
EOF
}

install_value_specs() {
  cat <<'EOF'
--task|INSTALL_TASK_REQUEST|task
--xray-version|XRAY_VERSION_REQUEST
--server-ip|SERVER_IP
--server-ip6|SERVER_IP6|ipv6
--node-label-prefix|NODE_LABEL_PREFIX
--reality-uuid|REALITY_UUID
--reality-sni|REALITY_SNI
--reality-target|REALITY_TARGET
--reality-short-id|REALITY_SHORT_ID
--reality-private-key|REALITY_PRIVATE_KEY
--xhttp-uuid|XHTTP_UUID
--xhttp-domain|XHTTP_DOMAIN
--xhttp-path|XHTTP_PATH
--xhttp-ech-config-list|XHTTP_ECH_CONFIG_LIST
--xhttp-xpadding-key|XHTTP_XPADDING_KEY
--xhttp-xpadding-header|XHTTP_XPADDING_HEADER
--xhttp-xpadding-placement|XHTTP_XPADDING_PLACEMENT
--xhttp-xpadding-method|XHTTP_XPADDING_METHOD
--cert-mode|CERT_MODE
--cert-file|CERT_SOURCE_FILE
--key-file|KEY_SOURCE_FILE
--cert-pem|CERT_SOURCE_PEM
--key-pem|KEY_SOURCE_PEM
--acme-email|ACME_EMAIL
--acme-ca|ACME_CA
--cf-dns-token|CF_DNS_TOKEN
--cf-dns-account-id|CF_DNS_ACCOUNT_ID
--cf-dns-zone-id|CF_DNS_ZONE_ID
--warp-private-key|WARP_PRIVATE_KEY
--warp-profile|WARP_PROFILE_SOURCE
--warp-address-v4|WARP_ADDRESS_V4
--warp-address-v6|WARP_ADDRESS_V6
--warp-peer-public-key|WARP_PEER_PUBLIC_KEY
--warp-endpoint|WARP_ENDPOINT
--warp-reserved|WARP_RESERVED
--warp-mtu|WARP_MTU
--bbr-kernel|NET_BBR_KERNEL
EOF
}

apply_install_flag_spec() {
  local option="${1}"
  local spec="${2}"
  local spec_option=""
  local var_name=""
  local value=""
  local conflict_group=""

  IFS='|' read -r spec_option var_name value conflict_group <<< "${spec}"
  reject_flag_assignment "${spec_option}" "${option}"
  [[ "${option}" == "${spec_option}" ]] || return 1
  record_arg_group "${conflict_group}" "${spec_option}"
  printf -v "${var_name}" '%s' "${value}"
  install_record_provided_var "${var_name}"
  return 0
}

apply_install_value_spec() {
  local option="${1}"
  local spec="${2}"
  local spec_option=""
  local var_name=""
  local conflict_group=""

  shift 2
  IFS='|' read -r spec_option var_name conflict_group <<< "${spec}"
  [[ "${option}" == "${spec_option}" || "${option}" == "${spec_option}="* ]] || return 1
  option_take_value "${spec_option}" "${option}" "$@"
  record_arg_group "${conflict_group}" "${spec_option}"
  printf -v "${var_name}" '%s' "${OPTION_VALUE}"
  install_record_provided_var "${var_name}"
  return 0
}

# 「本次动作显式给了哪些变量」的登记表。草稿加载、rotate 判定和摘要都靠它
# 区分「本次输入」和「沿用已保存选择」。
install_record_provided_var() {
  local var_name="${1:-}"

  [[ -n "${var_name}" ]] || return 0
  case "${INSTALL_PROVIDED_VARS:- }" in
    *" ${var_name} "*) return 0 ;;
  esac
  INSTALL_PROVIDED_VARS="${INSTALL_PROVIDED_VARS:- }${var_name} "
}

install_var_provided() {
  local var_name="${1:-}"

  [[ -n "${var_name}" ]] || return 1
  case "${INSTALL_PROVIDED_VARS:- }" in
    *" ${var_name} "*) return 0 ;;
  esac
  return 1
}

install_provided_var_names() {
  local var_name=""

  # shellcheck disable=SC2086
  for var_name in ${INSTALL_PROVIDED_VARS:-}; do
    printf '%s\n' "${var_name}"
  done
}

# 存在性（absent / provided / disabled）和值分开记：`--no-ipv6` 之后再也不能被
# 探测结果或旧 state 重新启用，显式地址也不会被空探测覆盖。
mark_install_option_presence() {
  case "${1}" in
    --no-ipv6)
      SERVER_IP6_PRESENCE="disabled"
      install_record_provided_var SERVER_IP6_PRESENCE
      ;;
    --server-ip6)
      SERVER_IP6_PRESENCE="provided"
      install_record_provided_var SERVER_IP6_PRESENCE
      ;;
    --server-ip)
      SERVER_IP_PRESENCE="provided"
      install_record_provided_var SERVER_IP_PRESENCE
      ;;
  esac
  return 0
}

parse_install_args() {
  local spec=""

  reset_arg_groups
  # 每次解析都是一次动作自己的请求：上一次动作的显式输入、存在性判断都不继承。
  INSTALL_PROVIDED_VARS=" "
  SERVER_IP_PRESENCE="absent"
  SERVER_IP6_PRESENCE="absent"
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --help|-h|help)
        usage
        exit 0
        ;;
    esac

    while IFS= read -r spec; do
      [[ -n "${spec}" ]] || continue
      if apply_install_flag_spec "${1}" "${spec}"; then
        mark_install_option_presence "${1}"
        shift
        continue 2
      fi
    done < <(install_flag_specs)

    while IFS= read -r spec; do
      [[ -n "${spec}" ]] || continue
      if apply_install_value_spec "${1}" "${spec}" "${@:2}"; then
        mark_install_option_presence "${spec%%|*}"
        shift "${OPTION_ARGS_CONSUMED}"
        continue 2
      fi
    done < <(install_value_specs)

    if handle_change_common_arg "${1}"; then
      shift
      continue
    fi

    die "未知的 install 参数：${1}"
  done
}

prepare_install_command() {
  local preview_fingerprint=""
  local locked_fingerprint=""

  install_draft_reset_session_state
  parse_install_args "$@" || return 1

  # 草稿要么被显式恢复，要么被显式丢弃；两条都不选时它不参与本次动作（H06）。
  if [[ "${INSTALL_DRAFT_DISCARD_REQUEST:-0}" -eq 1 ]]; then
    [[ "${INSTALL_TASK_REQUEST:-}" != "resume" ]] || die "--discard-draft 不能和恢复草稿同时使用。"
    if install_draft_present; then
      clear_install_draft_file || return 1
      log "已丢弃未完成的安装草稿：${INSTALL_DRAFT_FILE}"
    fi
  fi

  need_root
  ensure_debian_family
  resolve_install_task || return 1
  install_task_apply_context || return 1
  resolve_install_input_sources || return 1
  preview_fingerprint="$(install_environment_fingerprint)" || return 1
  prepare_install_inputs || return 1
  [[ "${INSTALL_CONFIRMED:-0}" -eq 1 ]] || return 1
  locked_fingerprint="$(install_environment_fingerprint)" || return 1
  if [[ "${locked_fingerprint}" != "${preview_fingerprint}" ]]; then
    warn "确认期间安装现场发生变化，本次确认已失效，请重新查看预览。"
    return 1
  fi
  validate_install_inputs || return 1
  start_backup_session || return 1
  locked_fingerprint="$(install_environment_fingerprint)" || return 1
  if [[ "${locked_fingerprint}" != "${preview_fingerprint}" ]]; then
    warn "获得锁后安装现场发生变化，本次确认已失效，请重新查看预览。"
    return 1
  fi
  install_draft_session_begin
  # 草稿只是给中断后重跑用的便利文件，写不下不该把这次安装拦掉；
  # 但它没写成，重跑时输入就得从头再敲一遍，值得说一声。
  write_install_draft_file || warn "安装草稿未能写入，中断后重跑需要重新输入参数。"
  if ! install_record_package_baseline; then
    warn "无法保存安装前包清单，未开始依赖安装。"
    install_draft_session_abort || true
    return 1
  fi
  if ! install_prepare_and_preflight; then
    install_draft_session_abort || true
    return 1
  fi
}

# 这三个都是在 `if ! xxx; then 回滚; fi` 里调用的，而 `if !` 会把整条调用链上的
# set -e 关掉：某一步返回非 0 之后函数会接着往下跑，最终返回最后一条命令的状态。
# 里面的步骤有的走 die（直接退出，不受影响），有的只 return 1（就会被吞），
# 所以每一步都得显式 `|| return 1`，不能靠 errexit。
install_xray_runtime() {
  install_packages || return 1
  install_self_command || return 1
  backup_path "${XRAY_BIN}" || return 1
  # 宿主自带的 /usr/local/bin/xray（别人的核心）也按首次接管登记；卸载时还原，
  # 不再直接删掉用户原来的核心（复核 H32）。
  record_takeover_original "${XRAY_BIN}" || return 1
  backup_path "${XRAY_ASSET_DIR}" || return 1
  # 宿主自带的 geo 资源目录与 xray 配置目录同样属于别人：卸载按登记还原，
  # 不再把用户原有的 /usr/local/share/xray、/usr/local/etc/xray 直接删掉。
  record_takeover_original "${XRAY_ASSET_DIR}" || return 1
  record_takeover_original "${XRAY_CONFIG_DIR}" || return 1
  # 宿主服务用的日志/状态目录（例如别人家的 xray.service 把 ReadWritePaths 指到
  # /var/log/xray、/var/lib/xray）：卸载直接删会让还原后的服务起不来（复核 H33）。
  record_takeover_original "${XRAY_LOG_DIR}" || return 1
  record_takeover_original "${XRAY_STATE_DIR}" || return 1
  install_xray || return 1
  ensure_xray_bind_capability || return 1
  ensure_xray_user || return 1
  generate_reality_keys_if_needed || return 1
}

write_install_managed_files() {
  generate_xhttp_vless_encryption_if_needed || return 1
  # 此时核心已可用，REALITY 与 Encryption 密钥已生成；在写配置前保存，
  # 强杀后重新进入也能沿用身份，不依赖失败 trap 才补写草稿。
  install_draft_session_persist || true
  write_tls_assets || return 1
  write_runtime_managed_files || return 1
  write_xray_service || return 1
  write_xray_logrotate_config || return 1
  remove_legacy_managed_paths || return 1
}

install_optional_components() {
  install_network_optimization || return 1
}

# 安装失败的统一出口：先留住草稿（下次重跑不用重新输入），再按同代边界回退。
# 回退结果由 generation_failed 如实报告；返回值始终非零。
install_abort_with_recovery() {
  local reason="${1}"

  install_draft_session_abort || true
  generation_failed "${reason}"
  return 1
}

install_cmd() {
  log_step "准备安装参数与运行环境。"
  prepare_install_command "$@" || return 1

  # 安装是最长的一条写入链：从这一刻起，任何一步失败都按同代边界回退到
  # 安装前（管理命令、核心二进制、托管文件、服务、state/输出一起）。
  if ! install_record_stage "创建托管文件与服务的恢复点" || ! begin_install_generation; then
    install_draft_session_abort || true
    return 1
  fi

  log_step "安装 Xray 运行时。"
  if ! install_record_stage "安装 Xray 运行时" || ! install_xray_runtime; then
    install_abort_with_recovery "安装 Xray 运行时失败"
    return 1
  fi
  log_step "写入托管配置文件。"
  if ! install_record_stage "写入托管配置文件" || ! write_install_managed_files; then
    install_abort_with_recovery "写入托管配置文件失败"
    return 1
  fi
  log_step "安装可选组件。"
  if ! install_record_stage "安装可选组件" || ! install_optional_components; then
    install_abort_with_recovery "安装可选组件失败"
    return 1
  fi
  log_step "校验并启动托管服务。"
  if ! install_record_stage "校验、启动服务与提交状态产物" || ! finalize_installation; then
    install_draft_session_abort || true
    return 1
  fi

  install_draft_session_finish || return 1
  report_sni_preflight_override
  log "部署完成。"
  log "备份目录：${BACKUP_DIR}"
  log "管理命令：${SELF_COMMAND_PATH}"
  log "节点链接已写入：${OUTPUT_FILE}"
  show_links --summary
}
