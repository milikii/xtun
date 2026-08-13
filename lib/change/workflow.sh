# shellcheck shell=bash

# ------------------------------
# 变更流程层
# 负责通用参数检查与托管变更执行
# ------------------------------

apply_managed_update() {
  apply_managed_files "yes"
}

apply_managed_runtime_update() {
  apply_managed_files "no"
}

handle_change_common_arg() {
  case "${1}" in
    --non-interactive)
      NON_INTERACTIVE=1
      return 0
      ;;
    --help|-h|help)
      usage
      exit 0
      ;;
  esac

  return 1
}

require_option_value() {
  local option_name="${1}"
  shift
  [[ $# -gt 0 ]] || die "参数 ${option_name} 需要值。"
}

assign_option_value() {
  local var_name="${1}"
  local option_name="${2}"

  shift 2
  require_option_value "${option_name}" "$@"
  enforce_indirect_option_value "${option_name}" "${1}"
  printf -v "${var_name}" '%s' "${1}"
}

run_change_warp_action() {
  local target_mode="${1}"

  case "${target_mode}" in
    enable)
      ENABLE_WARP="yes"
      prompt_warp_settings
      if ! apply_managed_runtime_update; then
        rollback_optional_component_state
        return 1
      fi
      warp_teardown_legacy
      finish_managed_change "WARP 分流已启用。" "no"
      log "出站: $(warp_outbound_text)"
      log "规则数: $(warp_rule_count_text)"
      ;;
    disable)
      ENABLE_WARP="no"
      apply_managed_runtime_update
      warp_teardown_legacy
      finish_managed_change "WARP 分流已禁用。" "no"
      ;;
    *)
      die "WARP 操作只能是 enable 或 disable。"
      ;;
  esac
}

begin_managed_change() {
  need_root
  start_backup_session
  log_step "读取当前托管安装状态。"
  load_current_install_context
  ensure_xray_user
}

begin_managed_output_change() {
  need_root
  start_backup_session
  log_step "读取当前托管输出状态。"
  [[ -f "${STATE_FILE}" ]] || die "找不到当前状态文件：${STATE_FILE}"
  load_existing_state
  load_output_runtime_context
  normalize_runtime_defaults
}

finish_managed_change() {
  local message="${1}"
  local show_links_after="${2:-yes}"

  log_success "${message}"
  log "备份目录：${BACKUP_DIR}"
  # 只有真的改了客户端链接才值得再喷一整份部署文档；
  # WARP 出站与分流规则都在服务端侧，链接一个字都不会变。
  [[ "${show_links_after}" == "yes" ]] || return 0
  show_links
}

run_single_value_change_cmd() {
  local option_name="${1}"
  local state_var_name="${2}"
  local prompt_text="${3}"
  local success_message="${4}"
  local unknown_arg_prefix="${5}"
  local apply_mode="${6}"
  local normalizer_fn="${7:-}"
  local post_update_fn="${8:-}"
  local current_value=""
  local new_value=""
  local overridden=0
  local -n state_ref="${state_var_name}"
  shift 8

  while [[ $# -gt 0 ]]; do
    if handle_change_common_arg "${1}"; then
      shift
      continue
    fi

    case "${1}" in
      "${option_name}")
        assign_option_value new_value "$@"
        overridden=1
        shift
        ;;
      "${option_name}="*)
        # 其余命令都收 --opt=value，这里也收，避免同一个脚本里两套写法
        new_value="${1#*=}"
        enforce_indirect_option_value "${option_name}" "${new_value}"
        overridden=1
        ;;
      *)
        die "${unknown_arg_prefix}${1}"
        ;;
    esac
    shift
  done

  case "${apply_mode}" in
    runtime)
      begin_managed_change
      ;;
    output)
      begin_managed_output_change
      ;;
    *)
      die "未知的变更应用模式：${apply_mode}"
      ;;
  esac
  current_value="${state_ref}"
  resolve_change_value "${state_var_name}" "${prompt_text}" "${current_value}" "${overridden}" "${new_value}"

  if [[ -n "${normalizer_fn}" ]]; then
    state_ref="$("${normalizer_fn}" "${state_ref}")"
  fi
  if [[ -n "${post_update_fn}" ]]; then
    "${post_update_fn}"
  fi

  case "${apply_mode}" in
    runtime)
      log_step "应用运行时配置变更。"
      apply_managed_runtime_update
      ;;
    output)
      log_step "刷新状态与输出文件。"
      write_state_file
      write_output_file
      ;;
  esac

  finish_managed_change "${success_message}"
}
