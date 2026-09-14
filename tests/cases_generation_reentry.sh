# shellcheck shell=bash

declare -A GENERATION_TEST_INSTALLED GENERATION_TEST_ACTIVE GENERATION_TEST_ENABLED

run_generation_log_permissions_reentry_case() {
  local workdir=""
  local logdir=""

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  logdir="${workdir}/runtime-log"
  mkdir "${logdir}"
  printf 'before\n' > "${logdir}/error.log"
  chmod 0755 "${logdir}"
  chmod 0644 "${logdir}/error.log"
  start_backup_session
  begin_generation_paths log-permissions -- "${XRAY_CONFIG_FILE}"
  generation_add_permissions "${logdir}" "${logdir}/error.log"
  grep -q $'^permission\t' "${PENDING_OP_FILE}"
  chmod 0700 "${logdir}"
  chmod 0600 "${logdir}/error.log"
  printf 'failure evidence\n' >> "${logdir}/error.log"
  generation_add_permissions "${logdir}" "${logdir}/error.log"
  release_script_lock
  # 清空原调用进程内存后，靠 pending 里的权限记录恢复，日志内容继续保留。
  load_functions
  generation_case_setup "${workdir}"
  run_cli_command recover --yes
  [[ "${GENERATION_RECOVERY_RESULT}" == restored-verified ]]
  [[ "$(stat -c %a "${logdir}")" == 755 && "$(stat -c %a "${logdir}/error.log")" == 644 ]]
  [[ "$(cat "${logdir}/error.log")" == $'before\nfailure evidence' ]]
  [[ ! -e "${PENDING_OP_FILE}" ]]
  load_functions
}

run_generation_permission_scope_case() {
  local workdir=""
  local real_user_helper=""
  local status=0

  load_functions
  real_user_helper="$(declare -f ensure_xray_user)"
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  eval "${real_user_helper}"
  id() { if [[ "${2:-}" == xray ]]; then printf '1001\n'; else command id "$@"; fi; }
  chown() { printf '%s\n' "${!#}" >> "${workdir}/permission-targets"; }
  useradd() { return 99; }
  XRAY_ASSET_DIR="${workdir}/must-not-create-assets"
  XRAY_LOG_DIR="${workdir}/logs-unmanaged"
  WARP_RULES_FILE="${workdir}/warp-rules"
  mkdir -p "${SSL_DIR}" "${XRAY_LOG_DIR}"
  printf 'original-config\n' > "${XRAY_CONFIG_FILE}"
  printf 'original-cert\n' > "${TLS_CERT_FILE}"
  printf 'original-key\n' > "${TLS_KEY_FILE}"
  printf 'original-rules\n' > "${WARP_RULES_FILE}"
  chmod 0664 "${XRAY_CONFIG_FILE}" "${TLS_CERT_FILE}" "${TLS_KEY_FILE}" "${WARP_RULES_FILE}"
  chmod 0755 "${SSL_DIR}" "${XRAY_LOG_DIR}"
  start_backup_session
  begin_generation_xray_only permissions
  ensure_xray_user lookup
  permission_candidate() { printf 'candidate\n'; }
  write_generated_file_atomically "${XRAY_CONFIG_FILE}" permission_candidate
  ensure_managed_permissions config
  [[ "$(stat -c %a "${XRAY_CONFIG_FILE}")" == 640 ]]
  [[ "$(cat "${workdir}/permission-targets")" == "${XRAY_CONFIG_FILE}" ]]
  [[ "$(stat -c %a "${TLS_CERT_FILE}")" == 664 && "$(stat -c %a "${TLS_KEY_FILE}")" == 664 ]]
  [[ "$(stat -c %a "${SSL_DIR}")" == 755 && "$(stat -c %a "${XRAY_LOG_DIR}")" == 755 ]]
  [[ "$(stat -c %a "${WARP_RULES_FILE}")" == 664 && ! -e "${XRAY_ASSET_DIR}" ]]
  generation_failed injected || status=$?
  [[ "${status}" -eq 1 && "${GENERATION_RECOVERY_RESULT}" == restored-verified ]]
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == original-config && "$(stat -c %a "${XRAY_CONFIG_FILE}")" == 664 ]]
  unset -f id chown useradd permission_candidate
  load_functions
}

run_install_draft_cleanup_commit_case() {
  local workdir=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  printf 'old\n' > "${XRAY_CONFIG_FILE}"
  start_backup_session
  begin_generation_paths draft-cleanup -- "${XRAY_CONFIG_FILE}"
  INSTALL_CONFIRMED=1
  install_draft_session_begin
  printf 'committed\n' > "${XRAY_CONFIG_FILE}"
  generation_commit
  INSTALL_DRAFT_FILE="${workdir}/draft-directory"
  mkdir "${INSTALL_DRAFT_FILE}"
  install_draft_session_finish 2>/dev/null || status=$?
  [[ "${status}" -eq 1 && "${GENERATION_ACTIVE}" == no ]]
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == committed && ! -e "${PENDING_OP_FILE}" ]]
  [[ "${LOGGED}" == *'安装已提交，但安装草稿清理失败'* ]]
  load_functions
}

run_backup_directory_symlink_case() {
  local workdir=""
  local before=""
  local snapshot=""

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  mkdir -p "${workdir}/bundle/empty" "${workdir}/bundle/lib"
  printf 'before\n' > "${workdir}/bundle/lib/core"
  chmod 0751 "${workdir}/bundle/lib/core"
  ln -s missing-target "${workdir}/bundle/dangling"
  before="$(backup_file_digest "${workdir}/bundle")"
  start_backup_session
  backup_path "${workdir}/bundle"
  backup_path "${workdir}/bundle/lib/core"
  backup_path "${workdir}/bundle/dangling"
  snapshot="${BACKUP_DIR}/$(backup_manifest_field "${workdir}/bundle" 6)"
  [[ "$(backup_file_digest "${snapshot}")" == "${before}" ]]
  printf 'after\n' > "${workdir}/bundle/lib/core"
  rm "${workdir}/bundle/dangling"
  ln -s other-target "${workdir}/bundle/dangling"
  backup_path "${workdir}/bundle"
  backup_path "${workdir}/bundle/lib/core"
  restore_backup_path "${workdir}/bundle/lib/core"
  restore_backup_path "${workdir}/bundle/dangling"
  [[ "$(cat "${workdir}/bundle/lib/core")" == before ]]
  [[ "$(readlink "${workdir}/bundle/dangling")" == missing-target ]]
  printf 'extra' > "${workdir}/bundle/extra"
  restore_backup_path "${workdir}/bundle"
  [[ "$(backup_file_digest "${workdir}/bundle")" == "${before}" ]]
  [[ "$(stat -c %a "${workdir}/bundle/lib/core")" == 751 ]]
  load_functions
}

# 真实派发链处于 errexit 豁免上下文；元数据失败必须挡住第一条托管写入。
run_generation_callsite_prewrite_failure_case() {
  local action=""
  local workdir=""
  local status=0
  local writes=0

  for action in install upgrade update-script apply-config apply-net-opt; do
    load_functions
    workdir="$(mktemp -d)"
    generation_case_setup "${workdir}"
    XRAY_BIN="${workdir}/core"
    printf '#!/bin/sh\nprintf old-core\\n\n' > "${XRAY_BIN}"
    chmod 0755 "${XRAY_BIN}"
    printf 'old-config\n' > "${XRAY_CONFIG_FILE}"
    writes=0
    need_root() { :; }
    ensure_debian_family() { :; }
    prepare_install_command() { start_backup_session; }
    load_current_install_context() { :; }
    mark_pending_operation() { return 1; }
    download_latest_script_bundle() { printf '%s' "${workdir}/candidate"; }
    installed_script_matches_bundle() { return 1; }
    bundle_script_version() { printf '2'; }
    install_xray_runtime() { writes=$((writes + 1)); }
    install_xray() { writes=$((writes + 1)); }
    install_bundle_root_to_self() { writes=$((writes + 1)); }
    write_runtime_managed_files() { writes=$((writes + 1)); }
    install_network_optimization() { writes=$((writes + 1)); }
    status=0
    run_cli_command "${action}" --non-interactive > "${workdir}/result" 2>&1 || status=$?
    [[ "${status}" -ne 0 ]]
    [[ "${writes}" -eq 0 ]]
    [[ "$(cat "${XRAY_CONFIG_FILE}")" == old-config ]]
    [[ "${GENERATION_ACTIVE}" == no ]]
  done
  load_functions
}

run_generation_extension_rename_failure_case() {
  local workdir=""
  local before=""
  local status=0
  local fail_replace=1

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  printf 'old\n' > "${XRAY_CONFIG_FILE}"
  start_backup_session
  begin_generation_paths extend -- "${XRAY_CONFIG_FILE}"
  before="$(backup_file_digest "${PENDING_OP_FILE}")"
  printf 'new\n' > "${XRAY_CONFIG_FILE}"
  mv() {
    if [[ "${fail_replace}" -eq 1 && "${!#}" == "${PENDING_OP_FILE}" ]]; then return 1; fi
    command mv "$@"
  }
  generation_add_paths "${workdir}/extra" || status=$?
  [[ "${status}" -ne 0 ]]
  [[ "$(backup_file_digest "${PENDING_OP_FILE}")" == "${before}" ]]
  status=0
  backup_path "${workdir}/extra" || status=$?
  [[ "${status}" -ne 0 ]]
  # 主 manifest 已扩展，但旧 pending 的不可变清单仍可独立恢复。
  grep -qF "${workdir}/extra" "${BACKUP_DIR}/manifest.tsv"
  fail_replace=0
  recover_generation
  [[ "${GENERATION_RECOVERY_RESULT}" == restored-verified ]]
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == old ]]
  [[ ! -e "${workdir}/extra" && ! -e "${PENDING_OP_FILE}" ]]
  unset -f mv
  load_functions
}

run_generation_metadata_corruption_case() {
  local workdir=""
  local manifest=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  printf 'old\n' > "${XRAY_CONFIG_FILE}"
  start_backup_session
  begin_generation_paths corrupt -- "${XRAY_CONFIG_FILE}"
  printf 'new\n' > "${XRAY_CONFIG_FILE}"
  manifest="$(awk -F'\t' '$1 == "manifest" {print $2}' "${PENDING_OP_FILE}")"
  printf 'corrupted\n' >> "${BACKUP_DIR}/${manifest}"
  recover_generation || status=$?
  [[ "${status}" -ne 0 && "${GENERATION_RECOVERY_RESULT}" == recovery-failed ]]
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == new ]]
  [[ -f "${PENDING_OP_FILE}" ]]
  [[ -z "${SYSTEMCTL_CALLS}" ]]
  load_functions
}

run_generation_stop_failure_retry_case() {
  local workdir=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  GENERATION_TEST_INSTALLED[xray.service]=yes
  GENERATION_TEST_ACTIVE[xray.service]=inactive
  GENERATION_TEST_ENABLED[xray.service]=disabled
  printf 'old\n' > "${XRAY_CONFIG_FILE}"
  start_backup_session
  begin_generation_xray_only stop-failure
  printf 'new\n' > "${XRAY_CONFIG_FILE}"
  GENERATION_TEST_ACTIVE[xray.service]=active
  GENERATION_TEST_ENABLED[xray.service]=enabled
  systemctl() {
    [[ "${1}" != stop ]] || return 1
    generation_mock_systemctl "$@"
  }
  generation_failed injected || status=$?
  [[ "${status}" -ne 0 && "${GENERATION_RECOVERY_RESULT}" == recovery-failed ]]
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == new ]]
  [[ -f "${PENDING_OP_FILE}" ]]
  [[ "${GENERATION_UNRESTORED[*]}" == *'xray.service:stop'* ]]
  systemctl() { generation_mock_systemctl "$@"; }
  run_cli_command recover --yes
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == old ]]
  [[ "${GENERATION_TEST_ACTIVE[xray.service]}" == inactive ]]
  [[ "${GENERATION_TEST_ENABLED[xray.service]}" == disabled ]]
  [[ ! -e "${PENDING_OP_FILE}" ]]
  load_functions
}

run_generation_commit_cleanup_reentry_case() {
  local workdir=""
  local session=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  printf 'old\n' > "${XRAY_CONFIG_FILE}"
  start_backup_session
  session="${BACKUP_DIR}"
  begin_generation_paths commit-cleanup -- "${XRAY_CONFIG_FILE}"
  printf 'new\n' > "${XRAY_CONFIG_FILE}"
  clear_pending_operation() { return 1; }
  generation_commit || status=$?
  [[ "${status}" -ne 0 && "${GENERATION_ACTIVE}" == no ]]
  [[ -f "${PENDING_OP_FILE}" && -f "${session}/completed" ]]
  load_functions
  generation_case_setup "${workdir}"
  run_cli_command recover --yes
  [[ "${GENERATION_RECOVERY_RESULT}" == committed ]]
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == new ]]
  [[ ! -e "${PENDING_OP_FILE}" ]]
  load_functions
}

run_generation_pending_blocks_new_mutation_case() {
  local workdir=""
  local session=""
  local status=0
  local before=""

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  start_backup_session
  session="${BACKUP_DIR}"
  begin_generation_paths pending -- "${XRAY_CONFIG_FILE}"
  before="$(backup_file_digest "${PENDING_OP_FILE}")"
  start_backup_session || status=$?
  [[ "${status}" -ne 0 && "${BACKUP_DIR}" == "${session}" ]]
  [[ "$(backup_file_digest "${PENDING_OP_FILE}")" == "${before}" ]]
  recover_generation
  [[ ! -f "${session}/completed" ]]
  # 随后的只读命令不能把上次失败的备份标成 completed。
  status_cmd() { :; }
  run_cli_command status
  [[ ! -f "${session}/completed" ]]
  load_functions
}

run_generation_sigkill_reentry_case() {
  local workdir=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  set +e
  TEST_GENERATION_WORKDIR="${workdir}" TEST_GENERATION_SOURCE="${ROOT_DIR}" TEST_SANDBOX_ROOT="${TEST_SANDBOX_ROOT}" bash -c '
    source "${TEST_GENERATION_SOURCE}/tests/common.sh"
    source "${TEST_GENERATION_SOURCE}/tests/cases_generation.sh"
    load_functions
    generation_case_setup "${TEST_GENERATION_WORKDIR}"
    printf "old\n" > "${XRAY_CONFIG_FILE}"
    start_backup_session
    begin_generation_paths strong-kill -- "${XRAY_CONFIG_FILE}"
    printf "new\n" > "${XRAY_CONFIG_FILE}"
    kill -KILL "$$"
  ' > "${workdir}/killed.log" 2>&1
  status=$?
  set -e
  [[ "${status}" -eq 137 ]]
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == new ]]
  [[ -f "${PENDING_OP_FILE}" ]]
  # 没有使用被杀进程的任何内存变量，真实 dispatch 从磁盘重建恢复上下文。
  run_cli_command recover --yes
  [[ "${GENERATION_RECOVERY_RESULT}" == restored-verified ]]
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == old ]]
  [[ ! -e "${PENDING_OP_FILE}" && ! -f "${BACKUP_DIR}/completed" ]]
  load_functions
}

run_generation_exit_signal_recovery_case() {
  local workdir=""
  local action=""
  local status=0
  local expected=0

  for action in exit TERM INT; do
    load_functions
    workdir="$(mktemp -d)"
    generation_case_setup "${workdir}"
    set +e
    TEST_GENERATION_ACTION="${action}" TEST_GENERATION_WORKDIR="${workdir}" TEST_GENERATION_SOURCE="${ROOT_DIR}" TEST_SANDBOX_ROOT="${TEST_SANDBOX_ROOT}" bash -c '
      source "${TEST_GENERATION_SOURCE}/tests/common.sh"
      source "${TEST_GENERATION_SOURCE}/tests/cases_generation.sh"
      load_functions
      generation_case_setup "${TEST_GENERATION_WORKDIR}"
      printf "old\n" > "${XRAY_CONFIG_FILE}"
      start_backup_session
      begin_generation_paths exit-test -- "${XRAY_CONFIG_FILE}"
      printf "new\n" > "${XRAY_CONFIG_FILE}"
      if [[ "${TEST_GENERATION_ACTION}" == exit ]]; then exit 7; fi
      kill -s "${TEST_GENERATION_ACTION}" "$$"
    ' > "${workdir}/interrupted.log" 2>&1
    status=$?
    set -e
    case "${action}" in exit) expected=7 ;; TERM) expected=143 ;; INT) expected=130 ;; esac
    [[ "${status}" -eq "${expected}" ]]
    [[ "$(cat "${XRAY_CONFIG_FILE}")" == old ]]
    [[ ! -e "${PENDING_OP_FILE}" ]]
  done
  load_functions
}
