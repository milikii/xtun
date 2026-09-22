# shellcheck shell=bash

# ------------------------------
# W04：同代提交与回退（D11/D12、H11/H13/H14）
# 这些用例刻意跑真实的 start_backup_session / begin_generation / backup_path：
# 快照 + manifest 是回退唯一的证据来源，把这一层桩掉等于把被测逻辑一起换掉。
# ------------------------------

# 用例里给回退层用的最小环境：全部落在临时目录，日志与 systemctl 都收进变量。
generation_case_setup() {
  local workdir="${1}"

  prepare_workspace "${workdir}"
  BACKUP_ROOT="${workdir}/backups"
  PENDING_OP_FILE="${workdir}/pending-op.tsv"
  SCRIPT_LOCK_FILE="${workdir}/xtun.lock"
  OP_LOG_DIR="${workdir}/logs"
  OP_LOG_FILE="${OP_LOG_DIR}/operations.log"
  SESSION_LOG_FILE="${workdir}/session.log"

  ensure_xray_user() { :; }
  LOGGED=""
  SYSTEMCTL_CALLS=""
  log() { LOGGED+="${1}"$'\n'; }
  log_step() { LOGGED+="STEP:${1}"$'\n'; }
  log_success() { LOGGED+="OK:${1}"$'\n'; }
  warn() { LOGGED+="WARN:${1}"$'\n'; }
  declare -gA GENERATION_TEST_INSTALLED=()
  declare -gA GENERATION_TEST_ACTIVE=()
  declare -gA GENERATION_TEST_ENABLED=()
  systemctl() { generation_mock_systemctl "$@"; }
  service_active_state() {
    local snapshot=""
    snapshot="$(generation_service_snapshot "${1}")" || return 1
    printf '%s' "${snapshot%%$'\t'*}"
  }
}

# 保留真实 systemd 状态读取协议，仅用内存模拟本用例的 unit 与进程。
generation_mock_systemctl() {
  local action="${1}"
  local unit="${2:-}"
  local runtime="no"
  local load="not-found"
  local active="inactive"
  local enabled=""

  SYSTEMCTL_CALLS+="${*}"$'\n'
  if [[ "${unit}" == "--runtime" ]]; then runtime="yes"; unit="${3}"; fi
  [[ "${unit}" == *.* ]] || unit="${unit}.service"
  if [[ "${GENERATION_TEST_INSTALLED[${unit}]:-no}" == "yes" || -e "${SYSTEMD_UNIT_DIRS[0]}/${unit}" ]]; then
    load="loaded"
    enabled="${GENERATION_TEST_ENABLED[${unit}]:-disabled}"
  fi
  active="${GENERATION_TEST_ACTIVE[${unit}]:-inactive}"
  case "${action}" in
    show)
      if [[ "$*" == *'--value'* ]]; then
        if [[ "$*" == *'UnitFileState'* ]]; then printf '%s\n' "${enabled}"; else printf '%s\n' "${active}"; fi
      else
        printf 'LoadState=%s\nActiveState=%s\nUnitFileState=%s\n' "${load}" "${active}" "${enabled}"
      fi
      ;;
    restart|start)
      [[ "${load}" == "loaded" ]] || return 1
      GENERATION_TEST_ACTIVE[${unit}]="active"
      ;;
    stop) GENERATION_TEST_ACTIVE[${unit}]="inactive" ;;
    enable)
      GENERATION_TEST_ENABLED[${unit}]="enabled"
      [[ "${runtime}" == "no" ]] || GENERATION_TEST_ENABLED[${unit}]="enabled-runtime"
      ;;
    disable) GENERATION_TEST_ENABLED[${unit}]="disabled" ;;
    is-active) [[ "${active}" == "active" ]] ;;
  esac
}

# 回退成功：旧文件回来、服务确认回到 active、只报一种结果。
run_generation_restore_verified_case() {
  local workdir=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"

  printf 'old-config\n' > "${XRAY_CONFIG_FILE}"
  printf 'old-state\n' > "${STATE_FILE}"
  printf 'old-output\n' > "${OUTPUT_FILE}"
  printf 'old-png' > "${workdir}/qr-old.png"

  # 服务在操作前是 active：回退之后必须重新核对它真的回来了（H11）。
  GENERATION_TEST_INSTALLED[xray.service]="yes"
  GENERATION_TEST_ACTIVE[xray.service]="active"
  GENERATION_TEST_ENABLED[xray.service]="enabled"

  start_backup_session
  begin_generation "同代回退测试" "no" xray.service
  generation_add_paths "${XRAY_CONFIG_FILE}" "${STATE_FILE}" "${OUTPUT_FILE}"
  backup_path "${XRAY_CONFIG_FILE}" || return 1
  backup_path "${STATE_FILE}" || return 1
  backup_path "${OUTPUT_FILE}" || return 1

  printf 'new-config\n' > "${XRAY_CONFIG_FILE}"
  printf 'new-state\n' > "${STATE_FILE}"
  printf 'new-output\n' > "${OUTPUT_FILE}"

  set +e
  generation_failed "测试失败" >/dev/null 2>&1
  status=$?
  set -e

  [[ "${status}" -ne 0 ]]
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == "old-config" ]]
  [[ "$(cat "${STATE_FILE}")" == "old-state" ]]
  [[ "$(cat "${OUTPUT_FILE}")" == "old-output" ]]
  [[ "${GENERATION_RECOVERY_RESULT}" == "restored-verified" ]]
  [[ "${GENERATION_ACTIVE}" == "no" ]]
  # 回退之后重新核对服务，而不是「systemctl 没报错就算回来了」
  [[ "${SYSTEMCTL_CALLS}" == *"restart xray.service"* ]]
  grep -q '测试失败：已回退到操作前的文件与服务，并确认服务回到操作前状态' <<< "${LOGGED}"
  # 失败的动作不消耗备份保留名额，也不留未完成操作标记。
  [[ -e "${BACKUP_DIR}/manifest.tsv" ]]
  [[ ! -e "${BACKUP_DIR}/completed" ]]
  [[ ! -e "${PENDING_OP_FILE}" ]]

  load_functions
}

# 回退失败：能还原的还原、还原不了的原样保留并逐个列出来，两种结果不能混为一谈。
run_generation_recovery_failed_case() {
  local workdir=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"

  printf 'old-config\n' > "${XRAY_CONFIG_FILE}"
  printf 'old-state\n' > "${STATE_FILE}"

  service_active_state() { printf 'not-installed'; }

  start_backup_session
  begin_generation "回退失败测试" "no"
  generation_add_paths "${XRAY_CONFIG_FILE}" "${STATE_FILE}"
  backup_path "${XRAY_CONFIG_FILE}" || return 1
  backup_path "${STATE_FILE}" || return 1

  printf 'new-config\n' > "${XRAY_CONFIG_FILE}"
  printf 'new-state\n' > "${STATE_FILE}"
  # 快照丢了：manifest 说这个路径操作前存在，但没有能还原的内容。
  rm -rf "${BACKUP_DIR:?}/$(backup_manifest_field "${STATE_FILE}" 6)"

  set +e
  generation_failed "测试失败" >/dev/null 2>&1
  status=$?
  set -e

  [[ "${status}" -ne 0 ]]
  # 有证据的照常还原
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == "old-config" ]]
  # 没证据的不许猜：既不能删也不能当成「以前不存在」，必须保持现状并报出来
  [[ "$(cat "${STATE_FILE}")" == "new-state" ]]
  [[ "${GENERATION_RECOVERY_RESULT}" == "recovery-failed" ]]
  [[ "${GENERATION_ACTIVE}" == "no" ]]
  grep -q '测试失败：回退没有完成' <<< "${LOGGED}"
  grep -q -- "- ${STATE_FILE}" <<< "${LOGGED}"
  # 回退失败要留下现场和未完成操作标记，下次维护动作才有入口
  [[ -e "${BACKUP_DIR}/manifest.tsv" ]]
  [[ ! -e "${BACKUP_DIR}/completed" ]]
  [[ -e "${PENDING_OP_FILE}" ]]

  load_functions
}

# 单个路径的回退规则：restored / deleted / untouched / unconfirmed 四种证据状态。
run_generation_path_restore_rules_case() {
  local workdir=""
  local status=0
  local result=""

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"

  start_backup_session

  # 有快照：还原
  printf 'old\n' > "${workdir}/aa"
  backup_path "${workdir}/aa" || return 1
  printf 'new\n' > "${workdir}/aa"
  result="$(restore_generation_path "${workdir}/aa")"
  [[ "${result}" == "restored" ]]
  [[ "$(cat "${workdir}/aa")" == "old" ]]

  # 清单说操作前不存在：删掉本次创建的东西
  backup_path "${workdir}/bb" || return 1
  printf 'created\n' > "${workdir}/bb"
  result="$(restore_generation_path "${workdir}/bb")"
  [[ "${result}" == "deleted" ]]
  [[ ! -e "${workdir}/bb" ]]

  # 没有任何记录：这次操作没碰过它，不许删（缺证据≠以前不存在）
  printf 'bystander\n' > "${workdir}/cc"
  status=0
  result="$(restore_generation_path "${workdir}/cc")" || status=$?
  [[ "${result}" == "untouched" ]]
  [[ "${status}" -eq 3 ]]
  [[ "$(cat "${workdir}/cc")" == "bystander" ]]

  # 有清单记录但快照没了：保持现状，报 unconfirmed
  printf 'old\n' > "${workdir}/dd"
  backup_path "${workdir}/dd" || return 1
  printf 'new\n' > "${workdir}/dd"
  rm -rf "${BACKUP_DIR:?}/$(backup_manifest_field "${workdir}/dd" 6)"
  status=0
  result="$(restore_generation_path "${workdir}/dd")" || status=$?
  [[ "${result}" == "unconfirmed" ]]
  [[ "${status}" -eq 2 ]]
  [[ "$(cat "${workdir}/dd")" == "new" ]]

  load_functions
}

run_generation_pending_persistence_case() {
  local workdir=""

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"

  start_backup_session
  begin_generation "升级" "no" xray.service
  generation_add_paths "${XRAY_BIN}" "${XRAY_ASSET_DIR}"

  grep -qF $'path\t'"${XRAY_BIN}" "${PENDING_OP_FILE}"
  grep -qF $'path\t'"${XRAY_ASSET_DIR}" "${PENDING_OP_FILE}"
  grep -qF $'service\txray.service\t' "${PENDING_OP_FILE}"
  grep -qF "${XRAY_BIN}" "${BACKUP_DIR}/manifest.tsv"
  grep -qF "${XRAY_ASSET_DIR}" "${BACKUP_DIR}/manifest.tsv"

  generation_commit
  rm -rf "${workdir}"
}

run_generation_marker_failure_case() {
  local workdir=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  printf 'old-config\n' > "${XRAY_CONFIG_FILE}"
  PENDING_OP_FILE="${workdir}/pending-op-directory"
  start_backup_session
  mkdir "${PENDING_OP_FILE}"
  set +e
  begin_generation "标记失败" "no" xray.service >/dev/null 2>&1
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  [[ -d "${PENDING_OP_FILE}" ]]
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == 'old-config' ]]

  rm -rf "${workdir}"
}

run_generation_inactive_service_restore_case() {
  local workdir=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  printf 'old-config\n' > "${XRAY_CONFIG_FILE}"
  GENERATION_TEST_INSTALLED[xray.service]="yes"
  GENERATION_TEST_ACTIVE[xray.service]="inactive"
  GENERATION_TEST_ENABLED[xray.service]="disabled"

  start_backup_session
  begin_generation "inactive" "no" xray.service
  printf 'new-config\n' > "${XRAY_CONFIG_FILE}"
  GENERATION_TEST_ACTIVE[xray.service]="active"
  GENERATION_TEST_ENABLED[xray.service]="enabled"

  set +e
  generation_failed "测试失败" >/dev/null 2>&1
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  [[ "${GENERATION_RECOVERY_RESULT}" == "restored-verified" ]]
  [[ "${GENERATION_TEST_ACTIVE[xray.service]}" == "inactive" ]]
  [[ "${GENERATION_TEST_ENABLED[xray.service]}" == "disabled" ]]
  [[ "${SYSTEMCTL_CALLS}" == *"disable xray.service"* ]]
  [[ "${SYSTEMCTL_CALLS}" == *"stop xray.service"* ]]

  rm -rf "${workdir}"
}

run_generation_daemon_reload_failure_case() {
  local workdir=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  printf 'old-config\n' > "${XRAY_CONFIG_FILE}"
  GENERATION_TEST_INSTALLED[xray.service]="yes"
  GENERATION_TEST_ACTIVE[xray.service]="active"
  systemctl() {
    [[ "${1}" != "daemon-reload" ]] || return 1
    generation_mock_systemctl "$@"
  }

  start_backup_session
  begin_generation "daemon-reload" "no" xray.service
  printf 'new-config\n' > "${XRAY_CONFIG_FILE}"

  set +e
  generation_failed "测试失败" >/dev/null 2>&1
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  [[ "${GENERATION_RECOVERY_RESULT}" == "recovery-failed" ]]
  [[ -e "${PENDING_OP_FILE}" ]]

  rm -rf "${workdir}"
}

run_generation_created_service_restore_case() {
  local workdir=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  printf 'old-config\n' > "${XRAY_CONFIG_FILE}"

  start_backup_session
  begin_generation "created-service" "no" xray.service -- "${XRAY_SERVICE_FILE}"
  mkdir -p "$(dirname "${XRAY_SERVICE_FILE}")"
  printf '[Unit]\n' > "${XRAY_SERVICE_FILE}"
  printf 'new-config\n' > "${XRAY_CONFIG_FILE}"
  GENERATION_TEST_ACTIVE[xray.service]="active"

  set +e
  generation_failed "测试失败" >/dev/null 2>&1
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  [[ "${GENERATION_RECOVERY_RESULT}" == "restored-verified" ]]
  [[ ! -e "${XRAY_SERVICE_FILE}" ]]
  [[ "${SYSTEMCTL_CALLS}" == *"stop xray.service"* ]]

  rm -rf "${workdir}"
}

# 首次安装时，root 配置校验新建日志后，低权限服务仍必须能够打开日志。
run_install_fresh_log_permissions_case() {
  local workdir=""
  local path=""

  load_functions
  workdir="$(mktemp -d)"
  chmod 0755 "${workdir}"
  generation_case_setup "${workdir}"
  # 服务用户需要穿过夹具目录；不能让调用测试时的 umask 遮住日志权限问题。
  chmod 0755 "${XRAY_CONFIG_DIR}"
  XRAY_UID=65534
  XRAY_GID=65534
  XRAY_LOG_DIR="${workdir}/xray-logs"
  XRAY_BIN="${workdir}/xray-core"
  install -m 0755 "${TEST_HOST_XRAY_BIN}" "${XRAY_BIN}"
  install -d -m 0750 -o "${XRAY_UID}" -g "${XRAY_GID}" "${XRAY_LOG_DIR}"
  jq -cn --argjson log "$(xray_log_json)" \
    '{log: $log, inbounds: [], outbounds: [{protocol: "freedom", tag: "direct"}]}' > "${XRAY_CONFIG_FILE}"

  # 使用真实核心创建首批日志；其它服务的配置不属于本用例。
  validate_configs() { validate_xray_config; }
  verify_served_tls_assets() { :; }
  write_certificate_receipt() { :; }
  restart_services() {
    setpriv --reuid="${XRAY_UID}" --regid="${XRAY_GID}" --clear-groups \
      "${XRAY_BIN}" run -test -config "${XRAY_CONFIG_FILE}" > "${workdir}/service-user.log" 2>&1 || return 1
    printf 'service-user-ok\n' > "${workdir}/service-user-ok"
  }
  write_state_file() { printf 'committed-state\n' > "${STATE_FILE}"; }
  write_output_file() { printf 'committed-output\n' > "${OUTPUT_FILE}"; }

  start_backup_session
  if ! finalize_installation > "${workdir}/finalize.log" 2>&1; then
    [[ ! -f "${workdir}/service-user.log" ]] || cat "${workdir}/service-user.log" >&2
    printf '[fail] 全新日志的低权限启动失败：%s\n' "${LOGGED}" >&2
    return 1
  fi
  [[ -s "${workdir}/service-user-ok" ]]
  for path in "${XRAY_LOG_DIR}/access.log" "${XRAY_LOG_DIR}/error.log"; do
    [[ "$(stat -c '%u:%g:%a' "${path}")" == '65534:65534:640' ]]
  done
  [[ ! -e "${PENDING_OP_FILE}" ]]
  rm -rf "${workdir}"
  load_functions
}

run_install_log_permission_failure_case() {
  local workdir=""
  local fail_once=1
  local path=""

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  XRAY_UID=65534
  XRAY_GID=65534
  XRAY_LOG_DIR="${workdir}/xray-logs"
  mkdir -m 0755 "${XRAY_LOG_DIR}"
  printf 'original-config\n' > "${XRAY_CONFIG_FILE}"
  for path in "${XRAY_LOG_DIR}/access.log" "${XRAY_LOG_DIR}/error.log"; do
    printf 'original-log\n' > "${path}"
    chmod 0644 "${path}"
  done
  validate_configs() { printf 'candidate-config\n' > "${XRAY_CONFIG_FILE}"; }
  restart_services() { printf 'unexpected\n' > "${workdir}/restarted"; }
  chown() {
    if [[ "${!#}" == "${XRAY_LOG_DIR}/error.log" && "${fail_once}" -eq 1 ]]; then
      fail_once=0
      return 1
    fi
    command chown "$@"
  }

  start_backup_session
  if finalize_installation > "${workdir}/finalize.log" 2>&1; then
    printf '[fail] 日志权限失败不能提交安装\n' >&2
    return 1
  fi
  [[ "${fail_once}" -eq 0 && ! -e "${workdir}/restarted" ]]
  [[ "${GENERATION_RECOVERY_RESULT}" == restored-verified && ! -e "${PENDING_OP_FILE}" ]]
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == original-config ]]
  [[ "$(stat -c '%u:%g:%a' "${XRAY_LOG_DIR}")" == '0:0:755' ]]
  for path in "${XRAY_LOG_DIR}/access.log" "${XRAY_LOG_DIR}/error.log"; do
    [[ "$(stat -c '%u:%g:%a' "${path}")" == '0:0:644' ]]
    [[ "$(cat "${path}")" == original-log ]]
  done
  unset -f chown
  rm -rf "${workdir}"
  load_functions
}

# 配置、state、输出与二维码是同一代的交付物：二维码生成失败会把已经写下的
# 新配置和新 state 一起退回去，不允许留下「新配置 + 旧产物」（H14/D12）。
run_generation_products_rollback_case() {
  local workdir=""
  local status=0
  local old_config=""

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  reset_feature_defaults

  SERVER_IP="203.0.113.30"
  NODE_LABEL_PREFIX="HKG"
  REALITY_UUID="11111111-1111-1111-1111-111111111111"
  REALITY_SNI="www.stanford.edu"
  REALITY_TARGET="www.stanford.edu:443"
  REALITY_SHORT_ID="abcd1234"
  # 真实的 x25519 密钥对：这一代配置要真的过一遍 xray 的校验。
  REALITY_PRIVATE_KEY="wAheTQX7Smg0ISm7KVrsW_cAssW_3kDeQmmsxUOAtXI"
  REALITY_PUBLIC_KEY="LTJN8tMabPnOjVqx9oUoqDljaaABtPFoeMP0SJW_bCU"
  XHTTP_UUID="22222222-2222-2222-2222-222222222222"
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/assets/v3"
  ENABLE_WARP="no"
  ENABLE_NET_OPT="no"
  CERT_MODE="existing"
  XHTTP_VLESS_ENCRYPTION_ENABLED=no
  XHTTP_VLESS_DECRYPTION=none
  XHTTP_VLESS_ENCRYPTION=""

  ensure_managed_permissions() { :; }
  write_xray_config
  old_config="$(cat "${XRAY_CONFIG_FILE}")"
  printf 'old-state\n' > "${STATE_FILE}"
  printf 'old-output\n' > "${OUTPUT_FILE}"
  # 装着 xray 的机器上日志目录是安装时建好的；校验会真的去初始化日志。
  mkdir -p "${XRAY_LOG_DIR}"
  mkdir -p "${QR_OUTPUT_DIR}"
  printf 'old-png' > "${QR_OUTPUT_DIR}/01-HKG-REALITY.png"

  # 二维码这一代画不出来：整批作废，不能提交（D12）。
  have_qrencode() { return 0; }
  qrencode() { printf 'called\n' >> "${workdir}/qr-attempts"; cat >/dev/null; return 1; }
  restart_xray_service() { :; }
  # 权限收尾要真实的 xray 用户，这条用例只关心同代边界。
  ensure_managed_permissions() { :; }
  h3_enabled() { return 1; }

  start_backup_session
  set +e
  apply_xray_only_managed_update >/dev/null 2>&1
  status=$?
  set -e

  [[ "${status}" -ne 0 ]]
  [[ -s "${workdir}/qr-attempts" ]] || { printf '[fail] 未到达二维码故障注入：%s\n' "${LOGGED}" >&2; return 1; }
  [[ "${GENERATION_RECOVERY_RESULT}" == "restored-verified" ]]
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == "${old_config}" ]]
  [[ "$(cat "${STATE_FILE}")" == "old-state" ]]
  [[ "$(cat "${OUTPUT_FILE}")" == "old-output" ]]
  # 上一代的二维码原样留着，暂存目录一个都不剩
  [[ "$(cat "${QR_OUTPUT_DIR}/01-HKG-REALITY.png")" == "old-png" ]]
  [[ -z "$(find "${workdir}" -maxdepth 3 -name '*.staging.*' -print -quit)" ]]
  grep -q '写入节点输出与二维码失败：已回退到操作前的文件' <<< "${LOGGED}"

  load_functions
}

# 未完成操作标记：开始时写、提交时清、回退失败时留；面板只报告不自行恢复。
run_pending_operation_marker_case() {
  local workdir=""
  local status=0
  local brief=""

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"

  # 面板依赖的一圈查询全部桩掉：这条用例只看「上次动作」这一行。
  load_dashboard_context() { :; }
  divider() { :; }
  panel_row() { printf '%s: %s\n' "${1}" "${2}"; }
  style_text() { printf '%s' "${2}"; }
  service_badge() { printf '%s' "${1}"; }
  listening_port_text() { printf 'x'; }
  warp_rule_count_text() { printf '0'; }
  net_current_cc() { printf 'cubic'; }
  net_default_qdisc() { printf 'fq'; }
  bool_badge() { printf '%s' "${1}"; }
  h3_enabled() { return 1; }
  service_active_state() { printf 'active'; }

  brief="$(show_dashboard_brief 2>/dev/null)"
  [[ "${brief}" != *"未完成"* ]]

  start_backup_session
  begin_generation "改 SNI" "no"

  pending_operation_present
  [[ "$(pending_operation_text)" == *"改 SNI"* ]]
  [[ "$(pending_operation_text)" == *"${BACKUP_DIR}"* ]]
  # 面板要能看出来有一次没做完的动作，但只是报告
  brief="$(show_dashboard_brief 2>/dev/null)"
  [[ "${brief}" == *"未完成：改 SNI"* ]]
  [[ -e "${PENDING_OP_FILE}" ]]

  # 提交：标记清掉，这次动作才可以消耗备份保留名额
  generation_commit
  [[ ! -e "${PENDING_OP_FILE}" ]]
  [[ -e "${BACKUP_DIR}/completed" ]]
  brief="$(show_dashboard_brief 2>/dev/null)"
  [[ "${brief}" != *"未完成"* ]]

  # 回退成功同样不留标记
  start_backup_session
  begin_generation "再改一次" "no"
  set +e
  generation_failed "测试失败" >/dev/null 2>&1
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  [[ ! -e "${PENDING_OP_FILE}" ]]

  load_functions
}

# 变更中途 Ctrl-C / TERM：先回退再退出，退出码按 D04（130 / 143）。
run_mutation_interrupt_handler_case() {
  local workdir=""
  local status=0
  local output=""

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  service_active_state() { printf 'not-installed'; }

  # 真正的变更入口开始时装上 INT/TERM trap
  begin_mutation
  trap -p INT | grep -q mutation_interrupt_handler
  trap -p TERM | grep -q mutation_interrupt_handler

  printf 'old-config\n' > "${XRAY_CONFIG_FILE}"

  set +e
  output="$(
    (
      log() { :; }
      log_step() { :; }
      log_success() { :; }
      warn() { printf 'WARN:%s\n' "${1}"; }
      start_backup_session
      begin_generation "中断测试" "no"
      backup_path "${XRAY_CONFIG_FILE}" || exit 1
      printf 'new-config\n' > "${XRAY_CONFIG_FILE}"
      mutation_interrupt_handler 143 TERM
      printf '不该跑到这里\n'
    ) 2>&1
  )"
  status=$?
  set -e

  [[ "${status}" -eq 143 ]]
  [[ "${output}" == *"收到 TERM"* ]]
  [[ "${output}" == *"已回退到操作前的文件"* ]]
  [[ "${output}" != *"不该跑到这里"* ]]
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == "old-config" ]]
  # 回退成功后不留未完成操作标记，现场仍在备份目录里
  [[ ! -e "${PENDING_OP_FILE}" ]]

  load_functions
}

# 同值修改是 noop：不写文件、不重启服务、不开备份会话、不写操作日志。
run_service_unit_name_case() {
  local workdir=""
  local unit_dir=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  unit_dir="${workdir}/units"
  mkdir -p "${unit_dir}"
  SYSTEMD_UNIT_DIRS=("${unit_dir}")
  printf '[Unit]\nDescription=test\n' > "${unit_dir}/haproxy.service"

  systemctl() {
    case "${1:-}" in
      show)
        [[ "${2:-}" == *haproxy* ]] && printf 'active'
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  }

  # systemctl 认简写，xtun 也得认：拿「haproxy」去查文件会查不到，
  # 于是装着的服务被报成 not-installed、重启核对跟着报失败（实机安装踩过）。
  service_exists haproxy.service
  service_exists haproxy
  [[ "$(service_active_state haproxy.service)" == "active" ]]
  [[ "$(service_active_state haproxy)" == "active" ]]

  # 真的没装的仍然要判 not-installed，不能被这条规则洗白
  status=0
  service_exists does-not-exist || status=$?
  [[ "${status}" -ne 0 ]]
  [[ "$(service_active_state does-not-exist)" == "not-installed" ]]

  load_functions
}

# 同值修改是 noop：不写文件、不重启服务、不开备份会话、不写操作日志。
run_same_value_change_noop_case() {
  local workdir=""
  local backup_sessions=0
  local runtime_updates=0
  local shown_links=0
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"

  need_root() { :; }
  ensure_xray_user() { :; }
  preflight_check_reality_sni() { :; }
  ensure_reality_sni_ready() { :; }
  apply_managed_runtime_update() { runtime_updates=$((runtime_updates + 1)); }
  show_links() { shown_links=$((shown_links + 1)); }
  start_backup_session() {
    backup_sessions=$((backup_sessions + 1))
    BACKUP_DIR="${workdir}/backup-${backup_sessions}"
    mkdir -p "${BACKUP_DIR}"
  }

  load_current_install_context() {
    REALITY_SNI="old.example.com"
    REALITY_TARGET="www.harvard.edu:443"
    XHTTP_PATH="/old"
    NODE_LABEL_PREFIX="HKG"
    CERT_MODE="existing"
    XHTTP_DOMAIN="cdn.old.example.com"
    ENABLE_WARP="no"
  }

  NON_INTERACTIVE=0
  change_sni_cmd --non-interactive --reality-sni old.example.com >/dev/null 2>&1
  [[ "${backup_sessions}" -eq 0 ]]
  [[ "${runtime_updates}" -eq 0 ]]
  [[ "${shown_links}" -eq 0 ]]
  [[ "${LOGGED}" == *"没有需要修改的内容"* ]]
  [[ ! -e "${OP_LOG_FILE}" ]]

  # 值真的变了才开会话：noop 判定看的是内容，不是命令有没有带参数
  load_current_install_context() {
    REALITY_SNI="old.example.com"
    REALITY_TARGET="www.harvard.edu:443"
    XHTTP_PATH="/old"
    NODE_LABEL_PREFIX="HKG"
    CERT_MODE="existing"
    XHTTP_DOMAIN="cdn.old.example.com"
    ENABLE_WARP="no"
  }
  NON_INTERACTIVE=0
  set +e
  change_sni_cmd --non-interactive --reality-sni new.example.com >/dev/null 2>&1
  status=$?
  set -e
  [[ "${status}" -eq 0 ]]
  [[ "${backup_sessions}" -eq 1 ]]
  [[ "${runtime_updates}" -eq 1 ]]
  [[ "${shown_links}" -eq 1 ]]

  load_functions
}
