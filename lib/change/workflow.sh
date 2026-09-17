# shellcheck shell=bash

# ------------------------------
# 变更流程层
# 负责通用参数检查与托管变更执行
# ------------------------------

declare -gA CHANGE_BEFORE=()
CHANGE_PREVIEW_FINGERPRINT=""

change_snapshot_fields() {
  printf '%s\n' REALITY_UUID XHTTP_UUID REALITY_SNI REALITY_TARGET REALITY_PRIVATE_KEY \
    REALITY_PUBLIC_KEY REALITY_SHORT_ID XHTTP_DOMAIN XHTTP_PATH H3_INTENT CERT_MODE \
    ENABLE_WARP WARP_PRIVATE_KEY WARP_ADDRESS_V4 WARP_ADDRESS_V6 WARP_ENDPOINT \
    WARP_RESERVED WARP_MTU WARP_RULES_TEXT NGINX_MAIN_MANAGED ENABLE_NET_OPT NET_BBR_KERNEL
}

change_environment_fingerprint() {
  install_environment_fingerprint | sha256sum | awk '{print $1}'
}

capture_change_context() {
  local field=""
  CHANGE_BEFORE=()
  while IFS= read -r field; do CHANGE_BEFORE["${field}"]="${!field:-}"; done < <(change_snapshot_fields)
  CHANGE_PREVIEW_FINGERPRINT="$(change_environment_fingerprint)" || return 1
}

prepare_change_context() {
  need_root
  log_step "读取当前托管安装状态。"
  load_current_install_context || return 1
  capture_change_context
}

change_field_changed() {
  [[ "${CHANGE_BEFORE[${1}]-}" != "${!1-}" ]]
}

change_reimport_nodes() {
  local field="" nodes=" " number=""
  local -a affected=()
  while IFS= read -r field; do
    change_field_changed "${field}" || continue
    case "${field}" in
      REALITY_UUID) nodes+='1 6 ' ;;
      XHTTP_UUID|XHTTP_PATH) nodes+='2 3 4 5 7 8 9 ' ;;
      REALITY_SNI|REALITY_PRIVATE_KEY|REALITY_PUBLIC_KEY|REALITY_SHORT_ID) nodes+='1 2 4 5 6 7 ' ;;
      XHTTP_DOMAIN) nodes+='3 4 5 7 8 9 ' ;;
      H3_INTENT) nodes+='8 9 ' ;;
    esac
  done < <(change_snapshot_fields)
  for number in {1..9}; do
    [[ "${nodes}" == *" ${number} "* ]] && affected+=("${number}")
  done
  if [[ "${#affected[@]}" -gt 0 ]]; then
    local IFS=,
    printf '%s' "${affected[*]}"
  else
    printf '无（服务端变更）'
  fi
}

show_change_preview() {
  local title="${1}" scope="${2:-runtime}" field="" old="" new="" rule=""
  printf '\n变更预览: %s\n' "${title}"
  while IFS= read -r field; do
    change_field_changed "${field}" || continue
    old="${CHANGE_BEFORE[${field}]-未设置}"
    new="${!field:-未设置}"
    case "${field}" in
      *UUID|*KEY|*SHORT_ID) printf '  %s: 凭据将更换（不显示正文）\n' "${field}" ;;
      WARP_RULES_TEXT)
        printf '  WARP 规则: %s 条 → %s 条\n' "$(printf '%s\n' "${old}" | awk 'NF {n++} END {print n+0}')" "$(printf '%s\n' "${new}" | awk 'NF {n++} END {print n+0}')"
        while IFS= read -r rule; do
          [[ -z "${rule}" ]] || grep -Fxq -- "${rule}" <<< "${new}" || printf '    删除 %s\n' "${rule}"
        done <<< "${old}"
        while IFS= read -r rule; do
          [[ -z "${rule}" ]] || grep -Fxq -- "${rule}" <<< "${old}" || printf '    添加 %s\n' "${rule}"
        done <<< "${new}"
        ;;
      *) printf '  %s: %s → %s\n' "${field}" "${old}" "${new}" ;;
    esac
  done < <(change_snapshot_fields)
  printf '  需重新导入节点（存在/启用时）: %s\n' "$(change_reimport_nodes)"
  case "${scope}" in
    net)
      printf '  文件: %s\n        %s\n        %s、%s\n' "${NET_SYSCTL_CONF}" "${NET_HELPER_PATH}" "${NET_SERVICE_FILE}" "${STATE_FILE}"
      printf '  服务: 应用 %s；改变实时 sysctl/qdisc，可能影响连接。\n' "${NET_SERVICE_NAME}"
      printf '  边界: 已装内核/软件包及实时网络参数不能保证自动撤销。\n'
      ;;
    xray)
      printf '  文件: %s\n        %s\n        %s、%s\n' "${XRAY_CONFIG_FILE}" "${STATE_FILE}" "${OUTPUT_FILE}" "${QR_OUTPUT_DIR}"
      printf '  服务: restart xray；所有经过 Xray 的连接可能中断。\n'
      ;;
    tls-only)
      printf '  文件: %s、%s；证书来源状态和节点清单摘要。\n' "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"
      printf '  服务: reload nginx，并核对实际提供的证书；已有请求由旧 worker 完成。\n'
      ;;
    *)
      printf '  文件: Xray/nginx/HAProxy 托管配置、state、节点文档和 PNG。\n'
      printf '        %s\n        %s\n        %s\n' "${XRAY_CONFIG_FILE}" "${NGINX_CONFIG_FILE}" "${HAPROXY_CONFIG}"
      printf '  服务: restart xray；reload nginx/HAProxy，必要时 restart。\n'
      printf '  连接: 所有经过 Xray 的连接可能中断；共享 nginx/HAProxy 也可能受影响。\n'
      ;;
  esac
  if [[ "${scope}" == tls ]]; then
    printf '  证书: %s、%s；签发/导入后检查 H3 条件。\n' "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"
  fi
  if [[ "${H3_INTENT:-off}" != off ]]; then printf '  H3: %s；条件失效会拒绝本次应用。\n' "$(h3_intent_text)"; fi
  printf '  恢复: 写入前创建同代文件/服务恢复点；失败自动恢复，未完成时用 xtun recover。\n'
}

confirm_change_preview() {
  local title="${1}" scope="${2:-runtime}" answer=""
  local INPUT_BACK_HANDLED=yes
  while true; do
    show_change_preview "${title}" "${scope}"
    if [[ "${NON_INTERACTIVE:-0}" == 1 ]]; then
      printf '  按 --non-interactive 的显式请求执行。\n'
      return 0
    fi
    read_line_or_cancel answer '确认应用？[y/N]（:back 返回编辑，:cancel 取消）: ' || return $?
    case "${answer}" in
      y|Y|yes|YES) return 0 ;;
      :back)
        input_edit_previous_fields || return 1
        [[ -z "${CHANGE_REVALIDATE_FN:-}" ]] || "${CHANGE_REVALIDATE_FN}" || return 1
        ;;
      ''|n|N|no|NO) input_cancel_action ;;
      *) warn '请输入 y、n、:back 或 :cancel。' ;;
    esac
  done
}

confirm_maintenance_action() {
  local title="${1}" files="${2}" services="${3}" recovery="${4}" answer=""
  local INPUT_BACK_HANDLED=yes
  printf '\n操作预览: %s\n  文件: %s\n  服务与连接: %s\n  恢复: %s\n' "${title}" "${files}" "${services}" "${recovery}"
  [[ "${NON_INTERACTIVE:-0}" != 1 ]] || return 0
  while true; do
    read_line_or_cancel answer '确认执行？[y/N]（:cancel 取消）: ' || return $?
    case "${answer}" in
      y|Y|yes|YES) return 0 ;;
      ''|n|N|no|NO|:back) input_cancel_action ;;
      *) warn '请输入 y、n 或 :cancel。' ;;
    esac
  done
}

apply_managed_update() {
  apply_managed_files "yes"
}

apply_managed_runtime_update() {
  apply_managed_files "no"
}

handle_change_common_arg() {
  case "${1}" in
    --non-interactive|--yes)
      reject_flag_assignment "${1}" "${1}"
      NON_INTERACTIVE=1
      return 0
      ;;
    --skip-sni-check)
      reject_flag_assignment "${1}" "${1}"
      SKIP_SNI_CHECK=1
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

# 公开参数契约（D03）：
#   * `--opt value` 与 `--opt=value` 等价；
#   * 缺值、空值、未知项都在解析阶段失败，不把问题留到写入/安装阶段；
#   * 敏感值无论哪种写法都必须走 @文件或环境变量；
#   * 互斥开关不看顺序，同时给出就报冲突，不采用「最后一个赢」。
OPTION_VALUE=""
OPTION_ARGS_CONSUMED=2
XTUN_APPLIED_ARG_GROUPS=""

reset_arg_groups() {
  XTUN_APPLIED_ARG_GROUPS=""
}

record_arg_group() {
  local group="${1:-}"
  local option_name="${2:-}"
  local entry=""

  [[ -n "${group}" ]] || return 0
  for entry in ${XTUN_APPLIED_ARG_GROUPS}; do
    [[ "${entry}" == "${group}:${option_name}" ]] && return 0
    if [[ "${entry}" == "${group}:"* ]]; then
      die "参数 ${option_name} 与 ${entry#*:} 互相冲突，不能同时给出。"
    fi
  done
  XTUN_APPLIED_ARG_GROUPS+=" ${group}:${option_name}"
}

validate_option_value() {
  local option_name="${1}"
  local value="${2:-}"

  [[ -n "${value}" ]] || die "参数 ${option_name} 需要值。"
  enforce_indirect_option_value "${option_name}" "${value}"
}

# 已经和选项分开的值：`assign_option_value VAR --opt <rest...>`。
assign_option_value() {
  local var_name="${1}"
  local option_name="${2}"

  shift 2
  require_option_value "${option_name}" "$@"
  validate_option_value "${option_name}" "${1}"
  printf -v "${var_name}" '%s' "${1}"
  OPTION_ARGS_CONSUMED=2
}

# 还拿着原始 token 的解析器：识别 `--opt=value`，把值写进 OPTION_VALUE，
# 消耗的参数个数写进 OPTION_ARGS_CONSUMED（1 = 内联，2 = 下一个参数）。
option_take_value() {
  local option_name="${1}"
  local token="${2:-}"

  shift 2
  if [[ "${token}" == "${option_name}="* ]]; then
    OPTION_VALUE="${token#*=}"
    OPTION_ARGS_CONSUMED=1
  else
    require_option_value "${option_name}" "$@"
    OPTION_VALUE="${1}"
    OPTION_ARGS_CONSUMED=2
  fi
  validate_option_value "${option_name}" "${OPTION_VALUE}"
}

# 无值开关被写成 `--flag=value` 时明确报错，而不是掉进「未知参数」。
reject_flag_assignment() {
  local option_name="${1}"
  local token="${2:-}"

  [[ "${token}" == "${option_name}="* ]] || return 0
  die "参数 ${option_name} 是无值开关，不接受 = 值。"
}

run_change_warp_action() {
  local target_mode="${1}"

  case "${target_mode}" in
    enable)
      ENABLE_WARP="yes"
      if ! apply_managed_runtime_update; then
        return 1
      fi
      finish_managed_change "WARP 分流已启用。" "no" || return 1
      log "出站: $(warp_outbound_text)"
      log "规则数: $(warp_rule_count_text)"
      ;;
    disable)
      ENABLE_WARP="no"
      apply_managed_runtime_update || return 1
      finish_managed_change "WARP 分流已禁用。" "no"
      ;;
    *)
      die "WARP 操作只能是 enable 或 disable。"
      ;;
  esac
}

begin_managed_change() {
  prepare_change_context
}

# 只在确认「这次真的会改东西」之后才开操作会话：同值修改/无差异返回 noop 时，
# 不该产生备份目录，也不该抢锁写操作日志（D11/D12、H13）。
open_change_session() {
  begin_mutation || return 1
  if [[ -n "${CHANGE_PREVIEW_FINGERPRINT:-}" && "$(change_environment_fingerprint)" != "${CHANGE_PREVIEW_FINGERPRINT}" ]]; then
    warn "获得锁后现场已变化，本次预览失效；请重新发起操作。"
    return 1
  fi
  start_backup_session || return 1
}

finish_managed_change() {
  local message="${1}"
  local show_links_after="${2:-yes}"

  log_success "${message}"
  log "备份目录：${BACKUP_DIR}"
  # 只有真的改了客户端链接才值得提示重新导入；完整文档留在输出文件里；
  # WARP 出站与分流规则都在服务端侧，链接一个字都不会变。
  [[ "${show_links_after}" == "yes" ]] || return 0
  show_links --summary
}

run_single_value_change_cmd() {
  local option_name="${1}"
  local state_var_name="${2}"
  local prompt_text="${3}"
  local success_message="${4}"
  local unknown_arg_prefix="${5}"
  local normalizer_fn="${6:-}"
  local post_update_fn="${7:-}"
  local current_value=""
  local new_value=""
  local overridden=0
  local before_digest=""
  local input_validator="${post_update_fn}"
  local CHANGE_REVALIDATE_FN="${post_update_fn}"
  local -n state_ref="${state_var_name}"
  shift 7

  while [[ $# -gt 0 ]]; do
    if handle_change_common_arg "${1}"; then
      shift
      continue
    fi

    case "${1}" in
      "${option_name}"|"${option_name}="*)
        option_take_value "${option_name}" "${1}" "${@:2}"
        new_value="${OPTION_VALUE}"
        overridden=1
        shift "${OPTION_ARGS_CONSUMED}"
        continue
        ;;
      *)
        die "${unknown_arg_prefix}${1}"
        ;;
    esac
    shift
  done

  # 读状态、取值、规范化和 post_update 都是只读或内存操作：先算清楚
  # 「改完和现在一不一样」，再决定要不要开这一次操作会话。
  prepare_change_context || return 1
  before_digest="$(generation_state_digest)"
  current_value="${state_ref}"
  if [[ "${state_var_name}" == REALITY_SNI ]]; then input_validator=ensure_reality_sni_format; fi
  if [[ "${overridden}" == 0 && -n "${post_update_fn}" ]]; then
    prompt_validated_value "${state_var_name}" "${prompt_text}" "${current_value}" "${input_validator}" || return $?
  else
    resolve_change_value "${state_var_name}" "${prompt_text}" "${current_value}" "${overridden}" "${new_value}"
  fi

  if [[ -n "${normalizer_fn}" ]]; then
    state_ref="$("${normalizer_fn}" "${state_ref}")" || return 1
  fi
  if [[ -n "${post_update_fn}" ]]; then
    "${post_update_fn}" || return 1
  fi

  # 同值修改（含规范化和 post_update 之后的同值）是 noop：不写文件、不重启服务、
  # 不开备份会话，也不提示重新导入链接。
  if [[ "$(generation_state_digest)" == "${before_digest}" ]]; then
    log "没有需要修改的内容：${state_var_name} 与当前值一致，未写入任何文件、未重启服务。"
    return 0
  fi

  confirm_change_preview "${prompt_text}" runtime || return 1
  # 返回编辑可能撤销刚才的变化，确认后再次计算 noop/规范化。
  if [[ "$(generation_state_digest)" == "${before_digest}" ]]; then
    log "没有需要修改的内容，未创建备份、未重启服务。"
    return 0
  fi
  open_change_session || return 1

  # apply_* 失败时里面已经回滚过了，这里必须跟着失败：
  # 再往下就是 finish_managed_change 的 log_success，会把回滚过的变更报成改好了。
  log_step "应用运行时配置变更。"
  apply_managed_runtime_update || return 1

  finish_managed_change "${success_message}"
}
