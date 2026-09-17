# shellcheck shell=bash

# ------------------------------
# 变更命令层
# 负责具体 change-* 与 upgrade 命令
# ------------------------------

upgrade_cmd() {
  local previous_version=""
  local current_version=""
  local XRAY_REINSTALL=0 before_digest="" installed_tag=""

  parse_upgrade_args "$@"

  need_root
  ensure_debian_family
  [[ -x "${XRAY_BIN}" ]] || die "找不到当前 Xray 可执行文件：${XRAY_BIN}"
  if pending_operation_present; then warn "存在未完成操作，请先运行 xtun recover。"; return 1; fi
  previous_version="$("${XRAY_BIN}" version 2>/dev/null | head -n 1 || true)"
  xray_ensure_release_context "${XRAY_VERSION_REQUEST}" || return 1
  acquire_script_lock || return 1
  if pending_operation_present; then warn "存在未完成操作，请先运行 xtun recover。"; return 1; fi
  previous_version="$("${XRAY_BIN}" version 2>/dev/null | head -n 1 || true)"
  installed_tag="$(awk '/^Xray [0-9]+\.[0-9]+\.[0-9]+ / {print "v" $2; exit}' <<< "${previous_version}")"
  if [[ "${XRAY_REINSTALL}" -eq 0 && "${installed_tag}" == "${XRAY_SELECTED_TAG}" ]]; then
    xray_resolve_release_digest || return 1
    if xray_installed_matches_selected; then
      log_success "当前核心与 ${XRAY_SELECTED_TAG} 的可信安装身份一致；未替换文件、未创建备份、未重启服务。"
      return 0
    fi
    warn "版本号相同，但核心/geo/权限安装身份未核验或与候选不同。请显式运行 xtun upgrade --xray-version ${XRAY_SELECTED_TAG} --reinstall。"
    return 1
  fi
  before_digest="$(identity_file_sha256 "${XRAY_BIN}")" || return 1
  confirm_maintenance_action "Xray 核心：${previous_version:-未知} → ${XRAY_SELECTED_TAG}（显式重装=${XRAY_REINSTALL}）" \
    "${XRAY_BIN}、${XRAY_ASSET_DIR}；节点凭据保持" \
    "restart xray，所有 Xray 连接可能中断，无需重新导入链接" \
    "失败按同代清单恢复核心、资源和服务状态" || return 1
  begin_mutation || return 1
  if [[ "$(identity_file_sha256 "${XRAY_BIN}")" != "${before_digest}" ]]; then
    warn "确认期间核心发生变化，请重新执行升级。"; return 1
  fi
  start_backup_session || return 1
  # 核心文件也进同代边界：校验或重启失败时把二进制、资源目录一起退回去。
  begin_generation_paths "Xray 核心升级" xray.service -- "${XRAY_BIN}" "${XRAY_ASSET_DIR}" || return 1

  backup_path "${XRAY_BIN}" || return 1
  backup_path "${XRAY_ASSET_DIR}" || return 1
  previous_version="$("${XRAY_BIN}" version 2>/dev/null | head -n 1 || true)"
  [[ -n "${previous_version}" ]] && log "升级前版本：${previous_version}"

  log_step "升级 Xray 核心。"
  # 下载/校验/解包任何一步挂了都要在这里停住：再往下 validate_configs 校验的是磁盘上
  # 那份没被换掉的旧核心，它当然过得了，于是「升级失败」会被报成升级完成。
  if ! install_xray; then
    generation_failed "安装新的 Xray 核心失败"
    return 1
  fi
  if ! ensure_xray_bind_capability; then
    generation_failed "设置 Xray 绑定能力失败"
    return 1
  fi
  if ! validate_configs; then
    generation_failed "升级后的配置校验失败"
    return 1
  fi
  log_step "重启 xray 服务。"
  if ! restart_service_verified xray.service; then
    generation_failed "xray 重启失败"
    return 1
  fi

  current_version="$("${XRAY_BIN}" version 2>/dev/null | head -n 1 || true)"
  generation_commit || return 1
  log_success "升级完成。"
  log "备份目录：${BACKUP_DIR}"
  [[ -n "${current_version}" ]] && log "当前版本：${current_version}"
}

parse_upgrade_args() {
  XRAY_VERSION_REQUEST="latest-published"
  XRAY_REINSTALL=0
  while [[ $# -gt 0 ]]; do
    if handle_change_common_arg "${1}"; then shift; continue; fi
    case "${1}" in
      --reinstall)
        XRAY_REINSTALL=1
        shift
        ;;
      --xray-version|--xray-version=*)
        option_take_value "--xray-version" "${1}" "${@:2}"
        XRAY_VERSION_REQUEST="${OPTION_VALUE}"
        shift "${OPTION_ARGS_CONSUMED}"
        ;;
      --help|-h|help)
        usage
        exit 0
        ;;
      *)
        die "未知的 upgrade 参数：${1}"
        ;;
    esac
  done
}

change_uuid_cmd() {
  local -A request=()
  local before_digest=""

  init_change_uuid_request request
  parse_change_uuid_args request "$@"

  if [[ "${request[rotate_reality]}" -eq 0 && "${request[rotate_xhttp]}" -eq 0 ]]; then
    die "没有需要修改的内容。请使用默认行为，或传入 --reality-only / --xhttp-only。"
  fi

  begin_managed_change || return 1
  before_digest="$(generation_state_digest)"

  if [[ "${request[rotate_reality]}" -eq 1 ]]; then
    REALITY_UUID="${request[reality_uuid]:-$(random_uuid)}"
  fi

  if [[ "${request[rotate_xhttp]}" -eq 1 ]]; then
    XHTTP_UUID="${request[xhttp_uuid]:-$(random_uuid)}"
  fi
  if [[ "$(generation_state_digest)" == "${before_digest}" ]]; then
    log "UUID 与当前值一致，未创建备份、未重启服务。"
    return 0
  fi
  confirm_change_preview "轮换节点 UUID" xray || return 1
  open_change_session || return 1

  # 和其它变更走同一条边界：新配置校验不过或重启失败，就把配置、state、
  # 输出与二维码一起退回上一代，不留下「新配置 + 旧 state」的组合。
  apply_xray_only_managed_update || return 1

  finish_managed_change "UUID 轮换完成。"
}

change_sni_cmd() {
  run_single_value_change_cmd \
    "--reality-sni" \
    "REALITY_SNI" \
    "新的 REALITY 可见 SNI" \
    "REALITY SNI 已更新。" \
    "未知的 change-sni 参数：" \
    "" \
    "ensure_reality_sni_ready" \
    "$@"
}

change_path_cmd() {
  run_single_value_change_cmd \
    "--xhttp-path" \
    "XHTTP_PATH" \
    "新的 XHTTP 路径" \
    "XHTTP 路径已更新。" \
    "未知的 change-path 参数：" \
    "" \
    "ensure_xhttp_path_format" \
    "$@"
}

change_warp_cmd() {
  local -A request=()
  local target_mode=""
  local before_digest=""

  init_change_warp_request request
  parse_change_warp_args request "$@"
  ensure_debian_family

  # 必须先落到变量上再传进去。写成 `run_change_warp_action "$(resolve_...)"` 的话，
  # 命令替换的退出码会被 run_change_warp_action 自己的退出码整个盖掉——
  # resolve_change_warp_target_mode 在参数不合法时 die，die 是 exit，
  # 只打死了 $( ) 那个子 shell，于是这里会拿着一个空的 target_mode 往下跑。
  prepare_change_context || return 1
  before_digest="$(generation_state_digest)"
  target_mode="$(resolve_change_warp_target_mode "${request[target_mode]}")" || return $?

  # 已经关着再关一次是 noop：不开备份会话、不重启服务（D12）。
  if [[ "${target_mode}" == "disable" && "${ENABLE_WARP:-no}" != "yes" ]]; then
    log "WARP 分流当前未启用，没有需要修改的内容。"
    return 0
  fi

  apply_warp_change_request request
  if [[ "${target_mode}" == enable ]]; then
    ENABLE_WARP=yes
    resolve_install_input_sources || return 1
    prompt_warp_settings || return 1
    [[ -z "${WARP_PRIVATE_KEY:-}" ]] || ensure_warp_outbound_format || return 1
  else
    ENABLE_WARP=no
  fi
  if [[ "$(generation_state_digest)" == "${before_digest}" && -z "${WARP_PROFILE_SOURCE:-}" ]]; then
    log "WARP 设置没有变化，未创建备份、未重启服务。"
    return 0
  fi
  confirm_change_preview "${target_mode} WARP 分流" runtime || return 1
  open_change_session || return 1
  run_change_warp_action "${target_mode}"
}

change_h3_cmd() {
  local requested="" answer=""
  reset_arg_groups
  while [[ $# -gt 0 ]]; do
    if handle_change_common_arg "${1}"; then shift; continue; fi
    case "${1}" in
      --enable-h3|--disable-h3)
        record_arg_group h3 "${1}"
        if [[ "${1}" == --enable-h3 ]]; then requested=on; else requested=off; fi
        ;;
      *) die "未知的 change-h3 参数：${1}" ;;
    esac
    shift
  done
  prepare_change_context || return 1
  if [[ -z "${requested}" ]]; then
    [[ "${NON_INTERACTIVE:-0}" != 1 ]] || die "change-h3 需要 --enable-h3 或 --disable-h3。"
    printf 'H3 当前选择: %s\n' "$(h3_intent_text)"
    while true; do
      read_line_or_cancel answer 'H3 选择 [on/off]（:cancel 取消）: ' || return $?
      case "${answer}" in
        on|off) requested="${answer}"; break ;;
        *) warn '请输入 on 或 off。' ;;
      esac
    done
  fi
  H3_INTENT="${requested}"
  h3_prepare_generation || return 1
  if [[ "${CHANGE_BEFORE[H3_INTENT]}" == "${H3_INTENT}" ]]; then
    log "H3 选择没有变化，未创建备份、未重启服务。"
    return 0
  fi
  confirm_change_preview "H3 直连选择" runtime || return 1
  open_change_session || return 1
  apply_managed_runtime_update || return 1
  finish_managed_change "H3 选择已应用；公网和客户端路径仍需验证。"
}

change_cert_mode_cmd() {
  local old_cert_mode=""
  local old_xhttp_domain=""
  local -A request=()
  local before_digest=""
  local scope=tls

  init_change_cert_mode_request request
  parse_change_cert_mode_args request "$@"
  begin_managed_change || return 1
  before_digest="$(generation_state_digest)"
  old_cert_mode="${CERT_MODE}"
  old_xhttp_domain="${XHTTP_DOMAIN}"

  apply_cert_mode_change_request request "${old_cert_mode}" "${old_xhttp_domain}"
  prompt_cert_mode_inputs || return 1
  validate_install_inputs || return 1
  if [[ "${CERT_MODE}" == existing && "$(generation_state_digest)" == "${before_digest}" \
    && -n "${CERT_SOURCE_FILE}" && -n "${KEY_SOURCE_FILE}" ]] \
    && cmp -s "${CERT_SOURCE_FILE}" "${TLS_CERT_FILE}" && cmp -s "${KEY_SOURCE_FILE}" "${TLS_KEY_FILE}"; then
    log "证书、域名及设置没有变化，未创建备份、未重启服务。"
    return 0
  fi
  [[ "${XHTTP_DOMAIN}" != "${old_xhttp_domain}" ]] || scope=tls-only
  confirm_change_preview "证书来源 / CDN 域名" "${scope}" || return 1
  open_change_session || return 1
  # 换证书失败时不能往下走：cleanup_previous_acme_cert 会把旧域名从 acme.sh 里摘掉，
  # 于是回滚回来的那张还在服务的证书从此不再自动续期，而用户看到的是「已更新」。
  if [[ "${scope}" == tls-only ]]; then
    apply_certificate_only_update change-cert-mode || return 1
  else
    if ! apply_managed_update; then
      certificate_record_event change-cert-mode failed "${GENERATION_RECOVERY_RESULT}"
      return 1
    fi
    certificate_record_event change-cert-mode success '域名与证书均已更新，并验证实际供证'
  fi
  cleanup_previous_acme_cert "${old_cert_mode}" "${old_xhttp_domain}"

  if [[ "${scope}" == tls-only ]]; then
    finish_managed_change "证书模式已更新，已验证 nginx 实际供证。" no || return 1
  else
    finish_managed_change "证书模式已更新。" || return 1
  fi
}

renew_cert_cmd() {
  local -A request=()

  init_change_cert_mode_request request
  parse_change_cert_mode_args request "$@"

  if [[ "${request[cert_mode_overridden]}" == "1" || "${request[xhttp_domain_overridden]}" == "1" ]]; then
    die "renew-cert 不支持修改证书模式或 XHTTP 域名；如需切换请使用 change-cert-mode。"
  fi

  begin_managed_change || return 1
  apply_request_overrides request \
    "cert_source_file|CERT_SOURCE_FILE" \
    "key_source_file|KEY_SOURCE_FILE" \
    "cert_source_pem|CERT_SOURCE_PEM" \
    "key_source_pem|KEY_SOURCE_PEM" \
    "acme_email|ACME_EMAIL" \
    "acme_ca|ACME_CA" \
    "cf_dns_token|CF_DNS_TOKEN" \
    "cf_dns_account_id|CF_DNS_ACCOUNT_ID" \
    "cf_dns_zone_id|CF_DNS_ZONE_ID"
  resolve_install_input_sources
  prompt_cert_mode_inputs || return $?
  validate_install_inputs
  confirm_change_preview "续期 / 刷新证书" tls-only || return 1
  open_change_session || return 1
  log_step "刷新 TLS 证书资产。"
  apply_certificate_only_update renew-cert || return 1

  finish_managed_change "证书刷新完成，已验证 nginx 实际供证。" no
}

change_warp_rules_cmd() {
  local add_rules=()
  local del_rules=()
  local current_rules=()
  local new_rules=()
  local line=""
  local list_only=0
  local reset_defaults=0
  local rule=""
  local skip_rule=0
  local original_text=""
  local updated_text=""
  local current_text=""

  while [[ $# -gt 0 ]]; do
    if handle_change_common_arg "${1}"; then
      shift
      continue
    fi

    case "${1}" in
      --add-domain|--add-domain=*)
        option_take_value "--add-domain" "${1}" "${@:2}"
        add_rules+=("$(normalize_warp_rule_value "${OPTION_VALUE}")") || exit 1
        shift "${OPTION_ARGS_CONSUMED}"
        ;;
      --del-domain|--del-domain=*)
        option_take_value "--del-domain" "${1}" "${@:2}"
        del_rules+=("$(normalize_warp_rule_value "${OPTION_VALUE}")") || exit 1
        shift "${OPTION_ARGS_CONSUMED}"
        ;;
      --reset-defaults)
        reset_defaults=1
        shift
        ;;
      --list)
        list_only=1
        shift
        ;;
      *)
        die "未知的 change-warp-rules 参数：${1}"
        ;;
    esac
  done

  if [[ "${list_only}" -eq 1 ]]; then
    [[ "${#add_rules[@]}" -eq 0 && "${#del_rules[@]}" -eq 0 && "${reset_defaults}" -eq 0 ]] \
      || die "--list 不能和修改参数一起使用。"
    load_existing_state
    current_warp_rules_text
    return
  fi

  # 备份会话要等到确认真的有变更再开：菜单里点进来看一眼就退出的情况很常见，
  # 每看一次就挤掉一份真正的变更备份（默认只留 5 份）划不来。
  prepare_change_context || return 1

  # 先把当前规则整段取出来。写成 `done < <(current_warp_rules_text)` 的话，
  # 进程替换的退出码根本没地方可去：规则文件里混进一条非法规则时
  # current_warp_rules_text 会 die，die 是 exit，只打死了那个子进程，
  # 循环读到 0 行、current_rules 空，然后这条命令会把规则文件按空列表重写一遍，
  # 把原有规则全删掉还报成功。
  current_text="$(current_warp_rules_text)" || exit 1
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    current_rules+=("${line}")
  done <<< "${current_text}"
  original_text="$(printf '%s\n' "${current_rules[@]}")"
  CHANGE_BEFORE[WARP_RULES_TEXT]="${original_text}"

  if [[ "${reset_defaults}" -eq 1 ]]; then
    updated_text="$(default_warp_rules_text)"
  elif [[ "${#add_rules[@]}" -eq 0 && "${#del_rules[@]}" -eq 0 ]] \
    && [[ "${NON_INTERACTIVE}" -eq 0 && -t 0 && -t 1 ]]; then
    # 不带任何修改参数又是交互终端，说明是从菜单点进来的：
    # 只打印当前规则和 CLI 用法，不再进交互编辑器。
    printf '%s\n' "当前 WARP 分流规则（命中的域名走 WARP，其它流量直连）:"
    printf '%s\n' "${original_text}"
    printf '%s\n' "修改规则请使用 CLI，例如："
    printf '%s\n' "  xtun change-warp-rules --add-domain example.com"
    printf '%s\n' "  xtun change-warp-rules --del-domain example.com"
    printf '%s\n' "  xtun change-warp-rules --reset-defaults"
    return 0
  else
    for line in "${current_rules[@]}"; do
      skip_rule=0
      for rule in "${del_rules[@]}"; do
        if [[ "${line}" == "${rule}" ]]; then
          skip_rule=1
          break
        fi
      done
      if [[ "${skip_rule}" -eq 0 ]]; then
        new_rules+=("${line}")
      fi
    done

    for rule in "${add_rules[@]}"; do
      skip_rule=0
      for line in "${new_rules[@]}"; do
        if [[ "${line}" == "${rule}" ]]; then
          skip_rule=1
          break
        fi
      done
      if [[ "${skip_rule}" -eq 0 ]]; then
        new_rules+=("${rule}")
      fi
    done

    [[ "${#new_rules[@]}" -gt 0 ]] || die "WARP 分流规则不能为空。"
    updated_text="$(printf '%s\n' "${new_rules[@]}")"
  fi

  if [[ "${updated_text}" == "${original_text}" ]]; then
    # 规则没动就别重启：xray/haproxy/nginx 一起重启会掐断所有在跑的连接。
    log "WARP 分流规则没有变化，未做任何修改。"
    printf '%s\n' "${original_text}"
    return 0
  fi

  WARP_RULES_TEXT="${updated_text}"
  confirm_change_preview "修改 WARP 分流规则" runtime || return 1
  open_change_session || return 1
  log_step "更新 WARP 分流规则。"
  apply_managed_runtime_update || return 1
  # 分流规则不影响任何客户端链接，没必要再把整份部署文档喷一遍
  finish_managed_change "WARP 分流规则已更新。" "no" || return 1
  printf '%s\n' "${updated_text}"
}
