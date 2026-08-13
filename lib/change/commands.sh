# shellcheck shell=bash

# ------------------------------
# 变更命令层
# 负责具体 change-* 与 upgrade 命令
# ------------------------------

upgrade_cmd() {
  local previous_version=""
  local current_version=""

  need_root
  ensure_debian_family
  [[ -x "${XRAY_BIN}" ]] || die "找不到当前 Xray 可执行文件：${XRAY_BIN}"

  start_backup_session
  backup_path "${XRAY_BIN}"
  backup_path "${XRAY_ASSET_DIR}"
  previous_version="$("${XRAY_BIN}" version 2>/dev/null | head -n 1 || true)"
  [[ -n "${previous_version}" ]] && log "升级前版本：${previous_version}"

  log_step "升级 Xray 核心。"
  install_xray
  ensure_xray_bind_capability
  if ! validate_configs; then
    warn "升级后的配置校验失败，正在回滚 Xray 核心文件。"
    restore_backup_path "${XRAY_BIN}" || true
    restore_backup_path "${XRAY_ASSET_DIR}" || true
    return 1
  fi
  log_step "重启 xray 服务。"
  if ! systemctl restart xray; then
    warn "xray 重启失败，正在回滚 Xray 核心文件。"
    restore_backup_path "${XRAY_BIN}" || true
    restore_backup_path "${XRAY_ASSET_DIR}" || true
    systemctl restart xray >/dev/null 2>&1 || true
    return 1
  fi

  current_version="$("${XRAY_BIN}" version 2>/dev/null | head -n 1 || true)"
  log_success "升级完成。"
  log "备份目录：${BACKUP_DIR}"
  [[ -n "${current_version}" ]] && log "当前版本：${current_version}"
}

change_uuid_cmd() {
  local -A request=()

  init_change_uuid_request request
  parse_change_uuid_args request "$@"

  if [[ "${request[rotate_reality]}" -eq 0 && "${request[rotate_xhttp]}" -eq 0 ]]; then
    die "没有需要修改的内容。请使用默认行为，或传入 --reality-only / --xhttp-only。"
  fi

  begin_managed_change

  if [[ "${request[rotate_reality]}" -eq 1 ]]; then
    REALITY_UUID="${request[reality_uuid]:-$(random_uuid)}"
  fi

  if [[ "${request[rotate_xhttp]}" -eq 1 ]]; then
    XHTTP_UUID="${request[xhttp_uuid]:-$(random_uuid)}"
  fi

  log_step "写入新的 UUID 配置。"
  write_xray_config
  log_step "校验并重启 xray。"
  validate_configs
  systemctl restart xray
  write_state_file
  write_output_file

  finish_managed_change "UUID 轮换完成。"
}

change_sni_cmd() {
  run_single_value_change_cmd \
    "--reality-sni" \
    "REALITY_SNI" \
    "新的 REALITY 可见 SNI" \
    "REALITY SNI 已更新。" \
    "未知的 change-sni 参数：" \
    "runtime" \
    "" \
    "ensure_reality_sni_format" \
    "$@"
}

change_path_cmd() {
  run_single_value_change_cmd \
    "--xhttp-path" \
    "XHTTP_PATH" \
    "新的 XHTTP 路径" \
    "XHTTP 路径已更新。" \
    "未知的 change-path 参数：" \
    "runtime" \
    "" \
    "ensure_xhttp_path_format" \
    "$@"
}

change_label_prefix_cmd() {
  run_single_value_change_cmd \
    "--node-label-prefix" \
    "NODE_LABEL_PREFIX" \
    "新的节点名前缀" \
    "节点名前缀已更新。" \
    "未知的 change-label-prefix 参数：" \
    "output" \
    "normalize_node_label_prefix" \
    "" \
    "$@"
}

change_warp_cmd() {
  local -A request=()

  init_change_warp_request request
  parse_change_warp_args request "$@"
  ensure_debian_family
  begin_managed_change

  apply_warp_change_request request
  run_change_warp_action "$(resolve_change_warp_target_mode "${request[target_mode]}")"
}

change_cert_mode_cmd() {
  local old_cert_mode=""
  local old_xhttp_domain=""
  local -A request=()

  init_change_cert_mode_request request
  parse_change_cert_mode_args request "$@"
  begin_managed_change
  old_cert_mode="${CERT_MODE}"
  old_xhttp_domain="${XHTTP_DOMAIN}"

  apply_cert_mode_change_request request "${old_cert_mode}" "${old_xhttp_domain}"
  prompt_cert_mode_inputs
  validate_install_inputs
  apply_managed_update
  cleanup_previous_acme_cert "${old_cert_mode}" "${old_xhttp_domain}"

  finish_managed_change "证书模式已更新。"
}

renew_cert_cmd() {
  local -A request=()

  init_change_cert_mode_request request
  parse_change_cert_mode_args request "$@"

  if [[ "${request[cert_mode_overridden]}" == "1" || "${request[xhttp_domain_overridden]}" == "1" ]]; then
    die "renew-cert 不支持修改证书模式或 XHTTP 域名；如需切换请使用 change-cert-mode。"
  fi

  begin_managed_change
  apply_request_overrides request \
    "cert_source_file:CERT_SOURCE_FILE" \
    "key_source_file:KEY_SOURCE_FILE" \
    "cert_source_pem:CERT_SOURCE_PEM" \
    "key_source_pem:KEY_SOURCE_PEM" \
    "cf_zone_id:CF_ZONE_ID" \
    "cf_api_token:CF_API_TOKEN" \
    "cf_cert_validity:CF_CERT_VALIDITY" \
    "acme_email:ACME_EMAIL" \
    "acme_ca:ACME_CA" \
    "cf_dns_token:CF_DNS_TOKEN" \
    "cf_dns_account_id:CF_DNS_ACCOUNT_ID" \
    "cf_dns_zone_id:CF_DNS_ZONE_ID"
  resolve_install_input_sources
  prompt_cert_mode_inputs
  validate_install_inputs
  log_step "刷新 TLS 证书资产。"
  apply_managed_update

  finish_managed_change "证书已续期。"
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

  while [[ $# -gt 0 ]]; do
    if handle_change_common_arg "${1}"; then
      shift
      continue
    fi

    case "${1}" in
      --add-domain)
        require_option_value "${1}" "${@:2}"
        add_rules+=("$(normalize_warp_rule_value "${2}")")
        shift 2
        ;;
      --del-domain)
        require_option_value "${1}" "${@:2}"
        del_rules+=("$(normalize_warp_rule_value "${2}")")
        shift 2
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
  need_root
  log_step "读取当前托管安装状态。"
  load_current_install_context

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    current_rules+=("${line}")
  done < <(current_warp_rules_text)
  original_text="$(printf '%s\n' "${current_rules[@]}")"

  if [[ "${reset_defaults}" -eq 1 ]]; then
    updated_text="$(default_warp_rules_text)"
  elif [[ "${#add_rules[@]}" -eq 0 && "${#del_rules[@]}" -eq 0 ]] \
    && [[ "${NON_INTERACTIVE}" -eq 0 && -t 0 && -t 1 ]]; then
    # 不带任何修改参数又是交互终端，说明是从菜单点进来的：
    # 给一个能看能改的界面，而不是闷头重启一遍服务再吐一整份部署文档。
    updated_text="$(prompt_warp_rules_editor)" || {
      log "已放弃修改，WARP 分流规则保持不变。"
      return 0
    }
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

  start_backup_session
  ensure_xray_user
  WARP_RULES_TEXT="${updated_text}"
  log_step "更新 WARP 分流规则。"
  apply_managed_runtime_update
  # 分流规则不影响任何客户端链接，没必要再把整份部署文档喷一遍
  finish_managed_change "WARP 分流规则已更新。" "no"
  printf '%s\n' "${updated_text}"
}
