# shellcheck shell=bash

# ------------------------------
# 同代提交与恢复层（D11/D12、H11/H13/H14）
# 一次托管变更是一个「代」：一批托管文件 + 服务 + state/output/PNG 一起提交，
# 任一步失败就整代回退，回退之后重新检查服务，最后如实报告结果。
# 这里钉着五条：
#   * 成功必须来自实际状态（systemctl 的 ActiveState），不是「命令返回 0」；
#   * 回退只做有证据的事：有快照就还原，清单写明原本不存在才删除，
#     其余一律保留并列入「未恢复」；
#   * 「已回退到旧代」和「回退失败」是两种结果，不共用成功提示；
#   * 变更期间掉电/中断会留下未完成操作清单，查看入口只报告、不自行恢复；
#   * 操作日志写不进去只警告，托管文件与 state/output 写不进去必须回退。
# ------------------------------

GENERATION_LABEL=""
GENERATION_ACTIVE="no"
GENERATION_STARTED=""
GENERATION_PENDING_DIGEST=""
GENERATION_RECOVERING="no"
BACKUP_MANIFEST_OVERRIDE=""
BACKUP_SESSION_OPEN="no"
GENERATION_INCLUDE_TLS="no"
GENERATION_PATHS=()
GENERATION_SERVICE_STATES=()
GENERATION_PERMISSION_STATES=()
GENERATION_UNRESTORED=()
GENERATION_RECOVERY_RESULT=""
SERVICE_ACTION_RESULTS=()
PENDING_OP_MARKED="no"
MUTATION_TRAPS_INSTALLED=0

service_reaches_active_state() {
  local unit_name="${1}"
  local attempt=0

  for attempt in 1 2 3 4; do
    if [[ "$(service_active_state "${unit_name}")" == "active" ]]; then
      # 连看两次：Restart=always 的核心在崩溃重启的间隙里也会短暂显示 active，
      # 只看一瞬间会把「起来又倒」判成成功。
      sleep 0.2
      [[ "$(service_active_state "${unit_name}")" == "active" ]] && return 0
    else
      sleep 0.2
    fi
  done

  return 1
}

# 重启并确认结果。返回值就是「这个服务现在是不是 active」，不是「systemctl 有没有报错」。
restart_service_verified() {
  local unit_name="${1}"
  local before=""
  local after=""

  before="$(service_active_state "${unit_name}")"
  if ! systemctl restart "${unit_name}" >/dev/null 2>&1; then
    after="$(service_active_state "${unit_name}")"
    SERVICE_ACTION_RESULTS+=("${unit_name}:重启命令失败（${before} → ${after}）")
    warn "重启 ${unit_name} 失败（${before} → ${after}）。"
    return 1
  fi

  if ! service_reaches_active_state "${unit_name}"; then
    after="$(service_active_state "${unit_name}")"
    SERVICE_ACTION_RESULTS+=("${unit_name}:重启后未达到 active（${before} → ${after}）")
    warn "重启后 ${unit_name} 未达到 active（${before} → ${after}）。"
    return 1
  fi

  SERVICE_ACTION_RESULTS+=("${unit_name}:active（原 ${before}）")
  return 0
}

service_results_text() {
  local entry=""

  [[ "${#SERVICE_ACTION_RESULTS[@]}" -gt 0 ]] || { printf '无'; return 0; }
  for entry in "${SERVICE_ACTION_RESULTS[@]}"; do
    printf '%s\n' "${entry}"
  done
}

# systemd 的缓存状态也要读取：unit 文件删掉，不代表旧进程已经停止。
# 返回 ActiveState / UnitFileState；查不到服务与查询失败是两件事。
generation_service_snapshot() {
  local unit="${1}"
  local output=""
  local status=0

  output="$(systemctl show "${unit}" -p LoadState -p ActiveState -p UnitFileState 2>/dev/null)" || status=$?
  awk -F= -v status="${status}" '
    $1 == "LoadState" { load=$2; nload++ }
    $1 == "ActiveState" { active=$2; nactive++ }
    $1 == "UnitFileState" { enabled=$2; nenabled++ }
    END {
      if (nload != 1 || nactive != 1 || nenabled != 1) exit 1
      if (load == "not-found" && active == "inactive" && enabled == "") {
        print "not-installed\tnot-installed"; exit 0
      }
      if (status || (load != "loaded" && load != "masked") || active == "" || enabled == "") exit 1
      print active "\t" enabled
    }
  ' <<< "${output}"
}

service_unit_file_state() {
  local snapshot=""

  snapshot="$(generation_service_snapshot "${1}")" || return 1
  printf '%s' "${snapshot#*$'\t'}"
}

# manifest.tsv 是首次路径记录；每版 pending 另外引用一份不可变的副本。
# 追加路径时即便在替换 pending 前强杀，旧 pending 引用的证据也仍然有效。
restore_generation_path() {
  local path="${1}"
  local existed=""

  if ! backup_manifest_validate; then
    printf 'unconfirmed'
    return 2
  fi
  if ! backup_manifest_has_path "${path}"; then
    printf 'untouched'
    return 3
  fi
  existed="$(backup_manifest_field "${path}" 3)" || return 2
  if ! restore_backup_path "${path}"; then
    printf 'unconfirmed'
    return 2
  fi
  if [[ "${existed}" == "0" ]]; then
    printf 'deleted'
  else
    printf 'restored'
  fi
}

generation_register_paths() {
  local path=""
  local existing=""
  local found="no"

  for path in "$@"; do
    found="no"
    for existing in "${GENERATION_PATHS[@]}"; do
      [[ "${existing}" != "${path}" ]] || found="yes"
    done
    [[ "${found}" == "no" ]] || continue
    GENERATION_REGISTERING=yes backup_path "${path}" || return 1
    GENERATION_PATHS+=("${path}")
  done
}

generation_has_path() {
  # 追加失败时内存列表可能已扩展，只以已落盘的那版 pending 放行写入。
  pending_operation_validate || return 1
  awk -F'\t' -v path="${1}" '$1 == "path" && $2 == path {found=1} END {exit found ? 0 : 1}' "${PENDING_OP_FILE}"
}

generation_add_paths() {
  [[ "${GENERATION_ACTIVE:-no}" == "yes" ]] || return 1
  generation_register_paths "$@" || return 1
  mark_pending_operation "${GENERATION_LABEL}"
}

# 日志内容保留用于排障，只回退已有日志目录/文件的权限，不复制或截断日志。
# 必须在第一次权限修改前完成；失败时旧版 pending 仍可独立恢复。
generation_add_permissions() {
  local path=""
  local entry=""
  local kind=""
  local metadata=""
  local found="no"
  local changed="no"

  [[ "${GENERATION_ACTIVE:-no}" == yes ]] || return 1
  for path in "$@"; do
    backup_path_is_safe "${path}" || return 1
    [[ ! -L "${path}" ]] || return 1
    [[ -e "${path}" ]] || continue
    found=no
    for entry in "${GENERATION_PERMISSION_STATES[@]}"; do
      [[ "${entry%%$'\t'*}" != "${path}" ]] || found=yes
    done
    [[ "${found}" != yes ]] || continue
    if [[ -d "${path}" ]]; then kind="directory"; elif [[ -f "${path}" ]]; then kind="file"; else return 1; fi
    metadata="$(stat -c $'%a\t%u\t%g' -- "${path}")" || return 1
    GENERATION_PERMISSION_STATES+=("${path}"$'\t'"${kind}"$'\t'"${metadata}")
    changed=yes
  done
  [[ "${changed}" == yes ]] || return 0
  mark_pending_operation "${GENERATION_LABEL}"
}

# 精确范围接口：label，受影响服务，--，本次可能写入的所有路径。
begin_generation_paths() {
  local label="${1}"
  local unit=""
  local snapshot=""
  local -a units=()

  shift
  [[ "${GENERATION_ACTIVE:-no}" != "yes" ]] || return 1
  if pending_operation_present; then
    warn "存在未完成操作；请先运行 xtun recover，再开始新的变更。"
    return 1
  fi
  while [[ $# -gt 0 && "${1}" != "--" ]]; do
    units+=("${1}")
    shift
  done
  [[ $# -gt 0 ]] || return 1
  shift
  [[ $# -gt 0 ]] || return 1
  backup_manifest_validate || return 1

  GENERATION_LABEL="${label}"
  GENERATION_PATHS=()
  GENERATION_SERVICE_STATES=()
  GENERATION_PERMISSION_STATES=()
  GENERATION_UNRESTORED=()
  GENERATION_RECOVERY_RESULT=""
  GENERATION_STARTED="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1
  PENDING_OP_MARKED="no"

  for unit in "${units[@]}"; do
    if ! snapshot="$(generation_service_snapshot "${unit}")"; then
      warn "无法读取 ${unit} 的操作前状态，未开始托管变更。"
      return 1
    fi
    GENERATION_SERVICE_STATES+=("${unit}"$'\t'"${snapshot}")
  done
  if ! generation_register_paths "$@" || ! mark_pending_operation "${label}"; then
    warn "首次备份或恢复清单未能持久化，未开始托管变更；证据目录：${BACKUP_DIR}。"
    return 1
  fi
  GENERATION_ACTIVE="yes"
}

begin_generation_xray_only() {
  begin_generation_paths "${1}" xray.service -- \
    "${XRAY_CONFIG_FILE}" "${STATE_FILE}" "${OUTPUT_FILE}" "${QR_OUTPUT_DIR}"
}

# 普通运行配置的共同范围；-- 后可在首次落盘前补充安装/维护专有路径。
begin_generation() {
  local label="${1}"
  local include_tls="${2:-no}"
  local -a units=()
  local -a paths=(
    "${XRAY_CONFIG_FILE}" "${HAPROXY_CONFIG}" "${NGINX_CONFIG_FILE}"
    "${NGINX_LIMITS_DROPIN_FILE}" "${WARP_RULES_FILE}" "${FALLBACK_SITE_DIR}"
    "${STATE_FILE}" "${OUTPUT_FILE}" "${QR_OUTPUT_DIR}"
  )

  shift 2
  while [[ $# -gt 0 && "${1}" != "--" ]]; do
    units+=("${1}")
    shift
  done
  [[ $# -eq 0 ]] || shift
  paths+=("$@")
  if [[ "${include_tls}" == "yes" ]]; then
    paths+=("${SSL_DIR}" "${TLS_CERT_FILE}" "${TLS_KEY_FILE}" "${ACME_RELOAD_HELPER}")
    if cert_mode_is_acme && [[ -n "${XHTTP_DOMAIN:-}" ]]; then
      paths+=("${ACME_HOME}/${XHTTP_DOMAIN}_ecc")
    fi
  fi
  if [[ "${NGINX_MAIN_MANAGED:-no}" == "yes" ]]; then
    paths+=("${NGINX_MAIN_CONFIG}")
  fi
  begin_generation_paths "${label}" "${units[@]}" -- "${paths[@]}"
}

pending_operation_present() {
  [[ -n "${PENDING_OP_FILE:-}" && ( -e "${PENDING_OP_FILE}" || -L "${PENDING_OP_FILE}" ) ]]
}

pending_operation_validate() {
  local marker="${1:-${PENDING_OP_FILE:-}}"

  [[ -f "${marker}" && ! -L "${marker}" ]] || return 1
  awk -F'\t' '
    function path_ok(s) {
      return s ~ /^\// && s != "/" && s !~ /[\r\n]/ && s !~ /\/\.?\.?\// && s !~ /\/$/ && s !~ /\/\.?\.?$/
    }
    NR == 1 { if ($0 != "# xtun-pending-operation\tv2") bad=1; next }
    $1 == "label" { if (NF != 2 || $2 == "" || count[$1]++) bad=1; next }
    $1 == "op_id" { if (NF != 2 || !path_ok($2) || count[$1]++) bad=1; next }
    $1 == "started" { if (NF != 2 || $2 == "" || count[$1]++) bad=1; next }
    $1 == "manifest" {
      if (NF != 3 || $2 !~ /^recovery-[A-Za-z0-9]+\.tsv$/ || $3 !~ /^[a-f0-9]+$/ || length($3) != 64 || count[$1]++) bad=1
      next
    }
    $1 == "path" { if (NF != 2 || !path_ok($2) || paths[$2]++) bad=1; npath++; next }
    $1 == "permission" {
      if (NF != 6 || !path_ok($2) || permissions[$2]++ || $3 !~ /^(file|directory)$/) bad=1
      if ($4 !~ /^[0-7]+$/ || length($4) < 3 || length($4) > 4 || $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/) bad=1
      next
    }
    $1 == "service" {
      if (NF != 4 || $2 !~ /^[A-Za-z0-9][A-Za-z0-9_.@:-]*\.(service|timer)$/ || services[$2]++) bad=1
      if ($3 !~ /^(active|inactive|failed|not-installed)$/) bad=1
      if ($4 !~ /^(enabled|enabled-runtime|disabled|static|indirect|masked|masked-runtime|alias|linked|linked-runtime|generated|transient|not-installed)$/) bad=1
      if (($3 == "not-installed") != ($4 == "not-installed")) bad=1
      next
    }
    { bad=1 }
    END { exit (bad || count["label"] != 1 || count["op_id"] != 1 || count["started"] != 1 || count["manifest"] != 1 || !npath) ? 1 : 0 }
  ' "${marker}"
}

mark_pending_operation() {
  local label="${1}"
  local marker="${PENDING_OP_FILE:-}"
  local temporary=""
  local manifest=""
  local digest=""
  local entry=""

  [[ -n "${marker}" ]] || return 1
  if pending_operation_present; then
    [[ "${PENDING_OP_MARKED:-no}" == "yes" ]] || return 1
    pending_operation_validate || return 1
    [[ "$(awk -F'\t' '$1 == "op_id" {print $2}' "${marker}")" == "${BACKUP_DIR}" ]] || return 1
  fi
  backup_manifest_validate || return 1
  manifest="$(mktemp "${BACKUP_DIR}/recovery-XXXXXX.tsv")" || return 1
  cp -- "$(backup_manifest_file)" "${manifest}" || return 1
  chmod 0600 "${manifest}" || return 1
  sync_required_path "${manifest}" || return 1
  digest="$(backup_file_digest "${manifest}")" || return 1

  mkdir -p "$(dirname "${marker}")" || return 1
  temporary="$(mktemp "${marker}.tmp.XXXXXX")" || return 1
  if ! {
    printf '# xtun-pending-operation\tv2\nlabel\t%s\nop_id\t%s\nstarted\t%s\nmanifest\t%s\t%s\n' \
      "${label}" "${BACKUP_DIR}" "${GENERATION_STARTED}" "${manifest##*/}" "${digest}"
    for entry in "${GENERATION_SERVICE_STATES[@]}"; do
      printf 'service\t%s\n' "${entry}" || return 1
    done
    for entry in "${GENERATION_PERMISSION_STATES[@]}"; do
      printf 'permission\t%s\n' "${entry}" || return 1
    done
    for entry in "${GENERATION_PATHS[@]}"; do
      printf 'path\t%s\n' "${entry}" || return 1
    done
  } > "${temporary}"; then
    rm -f "${temporary}"
    return 1
  fi
  if ! pending_operation_validate "${temporary}" || ! durable_replace_file "${temporary}" "${marker}"; then
    rm -f "${temporary}"
    return 1
  fi
  pending_operation_validate || return 1
  PENDING_OP_MARKED="yes"
}

pending_operation_text() {
  local marker="${PENDING_OP_FILE:-}"

  if ! pending_operation_validate; then
    printf '恢复清单无效（%s）；请保留现场并检查备份' "${marker}"
    return 0
  fi
  awk -F'\t' '
    $1 == "label" { label=$2 }
    $1 == "started" { started=$2 }
    $1 == "op_id" { op=$2 }
    END { printf "%s（开始于 %s，现场：%s）", label, started, op }
  ' "${marker}"
}

pending_operation_paths() {
  pending_operation_validate || return 1
  awk -F'\t' '$1 == "path" { print $2 }' "${PENDING_OP_FILE}"
}

pending_operation_services() {
  pending_operation_validate || return 1
  awk -F'\t' '$1 == "service" { print $2 "\t" $3 "\t" $4 }' "${PENDING_OP_FILE}"
}

# 只解析数据，不 source/eval；清单必须属于本机备份根目录且摘要吻合。
load_pending_operation() {
  local op_dir=""
  local manifest=""
  local digest=""
  local path=""
  local -a paths=()
  local -a services=()

  pending_operation_validate || return 1
  op_dir="$(awk -F'\t' '$1 == "op_id" {print $2}' "${PENDING_OP_FILE}")" || return 1
  [[ "$(dirname "${op_dir}")" == "${BACKUP_ROOT}" && -d "${op_dir}" && ! -L "${op_dir}" ]] || return 1
  IFS=$'\t' read -r manifest digest < <(awk -F'\t' '$1 == "manifest" {print $2 "\t" $3}' "${PENDING_OP_FILE}")
  manifest="${op_dir}/${manifest}"
  [[ -f "${manifest}" && ! -L "${manifest}" ]] || return 1
  [[ "$(backup_file_digest "${manifest}")" == "${digest}" ]] || return 1
  BACKUP_DIR="${op_dir}"
  BACKUP_MANIFEST_OVERRIDE="${manifest}"
  backup_manifest_validate || return 1
  mapfile -t paths < <(pending_operation_paths)
  mapfile -t services < <(pending_operation_services)
  for path in "${paths[@]}"; do
    backup_manifest_has_path "${path}" || return 1
  done
  GENERATION_PATHS=("${paths[@]}")
  GENERATION_SERVICE_STATES=("${services[@]}")
  mapfile -t GENERATION_PERMISSION_STATES < <(awk -F'\t' '$1 == "permission" {print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6}' "${PENDING_OP_FILE}")
  GENERATION_LABEL="$(awk -F'\t' '$1 == "label" {print $2}' "${PENDING_OP_FILE}")"
  GENERATION_STARTED="$(awk -F'\t' '$1 == "started" {print $2}' "${PENDING_OP_FILE}")"
  GENERATION_PENDING_DIGEST="$(backup_file_digest "${PENDING_OP_FILE}")" || return 1
  SESSION_LOG_FILE="${BACKUP_DIR}/operation.log"
  BACKUP_SESSION_OPEN="no"
  PENDING_OP_MARKED="yes"
  GENERATION_ACTIVE="yes"
}

clear_pending_operation() {
  [[ "${PENDING_OP_MARKED:-no}" == "yes" ]] || return 0
  [[ "${1:-}" != "recovery-failed" ]] || return 0
  pending_operation_validate || return 1
  [[ "$(awk -F'\t' '$1 == "op_id" {print $2}' "${PENDING_OP_FILE}")" == "${BACKUP_DIR}" ]] || return 1
  rm -f -- "${PENDING_OP_FILE}" || return 1
  sync_required_path "$(dirname "${PENDING_OP_FILE}")" || return 1
  PENDING_OP_MARKED="no"
}

generation_write_outcome() {
  local result="${1}"
  local temporary=""

  temporary="$(mktemp "${BACKUP_DIR}/outcome.tmp.XXXXXX")" || return 1
  printf '%s\t%s\n' "${result}" "${GENERATION_PENDING_DIGEST}" > "${temporary}" || return 1
  if ! durable_replace_file "${temporary}" "${BACKUP_DIR}/outcome.tsv"; then
    rm -f "${temporary}"
    return 1
  fi
}

generation_read_outcome() {
  local outcome="${BACKUP_DIR}/outcome.tsv"

  [[ -e "${outcome}" || -L "${outcome}" ]] || { printf 'pending'; return 0; }
  [[ -f "${outcome}" && ! -L "${outcome}" ]] || return 1
  awk -F'\t' -v digest="${GENERATION_PENDING_DIGEST}" '
    { if (NR != 1 || NF != 2 || $2 != digest || $1 !~ /^(committed|restored-verified)$/) bad=1; result=$1 }
    END { if (bad || NR != 1) exit 1; print result }
  ' "${outcome}"
}

generation_sync_paths() {
  local path=""
  local entry=""

  for path in "${GENERATION_PATHS[@]}"; do
    sync_required_path "${path}" || return 1
  done
  for entry in "${GENERATION_PERMISSION_STATES[@]}"; do
    sync_required_path "${entry%%$'\t'*}" || return 1
  done
}

restore_generation_permissions() {
  local path="${1}"
  local kind="${2}"
  local mode="${3}"
  local uid="${4}"
  local gid="${5}"

  [[ ! -L "${path}" ]] || return 1
  if [[ "${kind}" == directory ]]; then [[ -d "${path}" ]] || return 1; else [[ -f "${path}" ]] || return 1; fi
  chown "${uid}:${gid}" "${path}" || return 1
  chmod "${mode}" "${path}" || return 1
  [[ "$(stat -c '%a:%u:%g' -- "${path}")" == "${mode}:${uid}:${gid}" ]]
}

generation_commit() {
  [[ "${GENERATION_ACTIVE:-no}" == "yes" ]] || return 1
  if ! load_pending_operation || ! generation_sync_paths; then
    generation_failed "提交前无法验证或同步恢复清单与托管文件"
    return 1
  fi
  # 先记录提交决定，再完成备份、清 pending。决定已写入后不能再自动回退。
  if ! generation_write_outcome committed; then
    GENERATION_ACTIVE="no"
    warn "提交结果未能确认，已保留恢复证据；请运行 xtun recover 检查。"
    return 1
  fi
  GENERATION_ACTIVE="no"
  if ! finish_backup_session no-prune || ! clear_pending_operation committed; then
    warn "本次变更已提交，但收尾失败；请运行 xtun recover 完成清理。"
    return 1
  fi
  prune_backup_sessions || warn "备份轮转失败，已保留现有备份。"
}

restore_service_enable_state() {
  local unit="${1}"
  local wanted="${2}"
  local current=""

  current="$(service_unit_file_state "${unit}")" || return 1
  [[ "${current}" != "${wanted}" ]] || return 0
  [[ "${wanted}" != "not-installed" && "${current}" != "not-installed" ]] || return 1
  if [[ "${current}" == masked* ]]; then
    systemctl unmask "${unit}" >/dev/null 2>&1 || return 1
    systemctl unmask --runtime "${unit}" >/dev/null 2>&1 || return 1
  fi
  case "${wanted}" in
    enabled|enabled-runtime)
      systemctl disable "${unit}" >/dev/null 2>&1 || return 1
      if [[ "${wanted}" == "enabled-runtime" ]]; then
        systemctl enable --runtime "${unit}" >/dev/null 2>&1 || return 1
      else
        systemctl enable "${unit}" >/dev/null 2>&1 || return 1
      fi
      ;;
    masked|masked-runtime)
      if [[ "${wanted}" == "masked-runtime" ]]; then
        systemctl mask --runtime "${unit}" >/dev/null 2>&1 || return 1
      else
        systemctl mask "${unit}" >/dev/null 2>&1 || return 1
      fi
      ;;
    *)
      systemctl disable "${unit}" >/dev/null 2>&1 || return 1
      ;;
  esac
  [[ "$(service_unit_file_state "${unit}")" == "${wanted}" ]]
}

restore_service_runtime_state() {
  local unit="${1}"
  local wanted="${2}"
  local snapshot=""

  if [[ "${wanted}" == "active" ]]; then
    restart_service_verified "${unit}" || return 1
  fi
  snapshot="$(generation_service_snapshot "${unit}")" || return 1
  [[ "${snapshot%%$'\t'*}" == "${wanted}" ]]
}

generation_stop_before_restore() {
  local entry=""
  local unit=""
  local wanted=""
  local enabled=""
  local snapshot=""
  local current=""
  local failed=0

  for entry in "${GENERATION_SERVICE_STATES[@]}"; do
    IFS=$'\t' read -r unit wanted enabled <<< "${entry}"
    if ! snapshot="$(generation_service_snapshot "${unit}")"; then
      GENERATION_UNRESTORED+=("${unit}:query")
      failed=1
      continue
    fi
    current="${snapshot%%$'\t'*}"
    # 先停止新运行实例，再还原或删除 unit；不能只凭磁盘上已没有 unit 就跳过 stop。
    if [[ "${current}" != "not-installed" && "${current}" != "inactive" && ! ( "${current}" == "failed" && "${wanted}" == "failed" ) ]]; then
      if ! systemctl stop "${unit}" >/dev/null 2>&1; then
        GENERATION_UNRESTORED+=("${unit}:stop")
        failed=1
        continue
      fi
      if ! snapshot="$(generation_service_snapshot "${unit}")" || [[ "${snapshot%%$'\t'*}" != "inactive" && "${snapshot%%$'\t'*}" != "not-installed" ]]; then
        GENERATION_UNRESTORED+=("${unit}:stop-state")
        failed=1
        continue
      fi
    fi
    if [[ "${wanted}" == "not-installed" && "${current}" != "not-installed" ]]; then
      if ! systemctl disable "${unit}" >/dev/null 2>&1; then
        GENERATION_UNRESTORED+=("${unit}:disable")
        failed=1
      fi
    fi
  done
  [[ "${failed}" -eq 0 ]]
}

recover_generation() {
  local path=""
  local entry=""
  local unit=""
  local active=""
  local enabled=""
  local result=""
  local outcome=""
  local kind=""
  local mode=""
  local uid=""
  local gid=""

  GENERATION_UNRESTORED=()
  GENERATION_RECOVERY_RESULT="recovery-failed"
  GENERATION_RECOVERING="yes"
  if ! load_pending_operation || ! outcome="$(generation_read_outcome)"; then
    warn "持久恢复证据无效，保留所有目标文件与服务；现场：${PENDING_OP_FILE}。"
    GENERATION_UNRESTORED+=("recovery-metadata")
  elif [[ "${outcome}" != "pending" ]]; then
    # 提交/恢复已落盘而清 pending 时被中断，只补收尾，不重复执行文件回退。
    if [[ "${outcome}" != "committed" ]] || finish_backup_session no-prune; then
      if clear_pending_operation "${outcome}"; then
        GENERATION_RECOVERY_RESULT="${outcome}"
      else
        GENERATION_UNRESTORED+=("pending-cleanup")
      fi
    else
      GENERATION_UNRESTORED+=("backup-completion")
    fi
  else
    warn "本次变更没有完成，正在回退到操作前的文件与服务。"
    if generation_stop_before_restore; then
      for path in "${GENERATION_PATHS[@]}"; do
        result="$(restore_generation_path "${path}" 2>/dev/null)" || true
        case "${result}" in
          restored) log "已还原：${path}" ;;
          deleted) log "已删除本次创建：${path}" ;;
          *) GENERATION_UNRESTORED+=("${path}"); warn "缺少可信快照或文件恢复失败，未确认恢复：${path}" ;;
        esac
      done
      for entry in "${GENERATION_PERMISSION_STATES[@]}"; do
        IFS=$'\t' read -r path kind mode uid gid <<< "${entry}"
        restore_generation_permissions "${path}" "${kind}" "${mode}" "${uid}" "${gid}" || GENERATION_UNRESTORED+=("${path}:permissions")
      done
      if [[ "${#GENERATION_SERVICE_STATES[@]}" -gt 0 ]] && ! systemctl daemon-reload >/dev/null 2>&1; then
        GENERATION_UNRESTORED+=("daemon-reload")
      fi
      for entry in "${GENERATION_SERVICE_STATES[@]}"; do
        IFS=$'\t' read -r unit active enabled <<< "${entry}"
        restore_service_enable_state "${unit}" "${enabled}" || GENERATION_UNRESTORED+=("${unit}:enable:${enabled}")
        restore_service_runtime_state "${unit}" "${active}" || GENERATION_UNRESTORED+=("${unit}:runtime:${active}")
      done
      verify_recovered_tls_generation || GENERATION_UNRESTORED+=("nginx.service:served-certificate")
      generation_sync_paths || GENERATION_UNRESTORED+=("restored-files-sync")
      if [[ "${#GENERATION_UNRESTORED[@]}" -eq 0 ]]; then
        if generation_write_outcome restored-verified && clear_pending_operation restored-verified; then
          GENERATION_RECOVERY_RESULT="restored-verified"
        else
          GENERATION_UNRESTORED+=("recovery-completion")
        fi
      fi
    else
      # 停服失败时没有改动任何目标；其余已停止的服务也不能被漏报成已恢复。
      for path in "${GENERATION_PATHS[@]}"; do GENERATION_UNRESTORED+=("${path}:not-restored"); done
      for entry in "${GENERATION_PERMISSION_STATES[@]}"; do GENERATION_UNRESTORED+=("${entry%%$'\t'*}:permissions-not-restored"); done
      for entry in "${GENERATION_SERVICE_STATES[@]}"; do
        IFS=$'\t' read -r unit active enabled <<< "${entry}"
        GENERATION_UNRESTORED+=("${unit}:state-not-restored")
      done
    fi
  fi
  GENERATION_ACTIVE="no"
  GENERATION_RECOVERING="no"
  [[ "${GENERATION_RECOVERY_RESULT}" != "recovery-failed" ]]
}

generation_report_recovery() {
  local reason="${1}"
  local item=""

  case "${GENERATION_RECOVERY_RESULT}" in
    restored-verified)
      warn "${reason}：已回退到操作前的文件与服务，并确认服务回到操作前状态；原变更没有生效。"
      ;;
    committed)
      log "上次变更已完成提交，本次仅完成恢复记录清理。"
      ;;
    *)
      warn "${reason}：回退没有完成，以下对象尚未确认恢复："
      for item in "${GENERATION_UNRESTORED[@]}"; do warn "  - ${item}"; done
      warn "现场保留在 ${BACKUP_DIR:-未知}；修复失败原因后运行 xtun recover 重试。"
      ;;
  esac
  # 内核与队列状态不能从配置文件/oneshot 服务状态推断已还原。
  for item in "${GENERATION_PATHS[@]}"; do
    if [[ "${item}" == "${NET_SYSCTL_CONF}" || "${item}" == "${NET_HELPER_PATH}" ]]; then
      warn "网络优化的实时 sysctl、qdisc、RPS/XPS 与已安装内核不在文件/服务恢复范围；请另行核对，不能据此确认网络参数已还原。"
      break
    fi
  done
}

# 原动作即便恢复成功仍返回非零，不能把「恢复成功」说成「修改成功」。
generation_failed() {
  local reason="${1}"

  if [[ "${GENERATION_ACTIVE:-no}" != "yes" ]]; then
    warn "${reason}"
    return 1
  fi
  recover_generation || true
  generation_report_recovery "${reason}"
  return 1
}

generation_recover_on_interrupt() {
  [[ "${GENERATION_ACTIVE:-no}" == "yes" && "${GENERATION_RECOVERING:-no}" != "yes" ]] || return 0
  recover_generation || true
  generation_report_recovery "操作中断"
}

mutation_interrupt_handler() {
  local exit_code="${1}"
  local signal_name="${2}"

  trap - INT TERM
  warn "收到 ${signal_name}，正在结束当前动作。"
  generation_recover_on_interrupt
  release_script_lock
  exit "${exit_code}"
}

mutation_exit_handler() {
  local status="${1}"

  trap - EXIT
  if [[ "${GENERATION_ACTIVE:-no}" == "yes" ]]; then
    generation_recover_on_interrupt
    [[ "${status}" -ne 0 ]] || status=1
  fi
  if [[ "${SCRIPT_LOCK_HELD:-0}" -eq 1 ]]; then
    release_script_lock
  fi
  exit "${status}"
}

install_mutation_traps() {
  trap 'mutation_interrupt_handler 130 INT' INT
  trap 'mutation_interrupt_handler 143 TERM' TERM
  trap 'mutation_exit_handler "$?"' EXIT
  MUTATION_TRAPS_INSTALLED=1
}

generation_state_digest() {
  state_file_text | sha256sum | awk '{print $1}'
}
