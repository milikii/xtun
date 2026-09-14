#!/usr/bin/env bash
# 在用户授权的可重建 VPS 上执行；只创建带 xtun-recovery- 前缀的临时 unit。
set -Eeuo pipefail

[[ "${XTUN_TEST_ISOLATED_VPS:-no}" == yes ]] || { printf '设置 XTUN_TEST_ISOLATED_VPS=yes 后在隔离 VPS 运行。\n' >&2; exit 2; }
[[ "${EUID}" -eq 0 && -d /run/systemd/system ]] || { printf '需要 root 和真实 systemd。\n' >&2; exit 2; }
TEST_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "${TEST_SCRIPT_PATH}")/.." && pwd)"
# shellcheck disable=SC1090
source <(sed '$d' "${ROOT_DIR}/xtun.sh")

systemd_case_context() {
  TEST_CASE_ROOT="${1}"
  TEST_UNIT="${2}"
  TEST_UNIT_FILE="/etc/systemd/system/${TEST_UNIT}"
  TEST_PAYLOAD="${TEST_CASE_ROOT}/payload"
  BACKUP_ROOT="${TEST_CASE_ROOT}/backups"
  PENDING_OP_FILE="${TEST_CASE_ROOT}/pending.tsv"
  SCRIPT_LOCK_FILE="${TEST_CASE_ROOT}/lock"
  OP_LOG_DIR="${TEST_CASE_ROOT}/logs"
  OP_LOG_FILE="${OP_LOG_DIR}/operations.log"
  install -d -m 0700 "${TEST_CASE_ROOT}"
}

systemd_write_unit() {
  cat > "${TEST_UNIT_FILE}" <<UNIT
[Unit]
Description=xtun recovery regression fixture
[Service]
ExecStart=/bin/sleep infinity
[Install]
WantedBy=multi-user.target
UNIT
}

systemd_fixture() {
  local active="${1}"
  local enabled="${2}"

  mkdir -p "${TEST_PAYLOAD}/empty"
  printf 'old\n' > "${TEST_PAYLOAD}/config"
  chmod 0640 "${TEST_PAYLOAD}/config"
  ln -s missing "${TEST_PAYLOAD}/link"
  backup_file_digest "${TEST_PAYLOAD}" > "${TEST_CASE_ROOT}/before.sha256"
  systemd_write_unit
  systemctl daemon-reload
  case "${enabled}" in
    enabled) systemctl enable "${TEST_UNIT}" >/dev/null ;;
    enabled-runtime) systemctl enable --runtime "${TEST_UNIT}" >/dev/null ;;
    disabled) systemctl disable "${TEST_UNIT}" >/dev/null ;;
  esac
  [[ "${active}" != active ]] || systemctl start "${TEST_UNIT}"
  [[ "$(generation_service_snapshot "${TEST_UNIT}")" == "${active}"$'\t'"${enabled}" ]]
}

systemd_generation_begin() {
  start_backup_session
  begin_generation_paths "systemd:${1}" "${TEST_UNIT}" -- "${TEST_PAYLOAD}" "${TEST_UNIT_FILE}"
}

systemd_assert_restored() {
  local active="${1}"
  local enabled="${2}"

  [[ "$(backup_file_digest "${TEST_PAYLOAD}")" == "$(cat "${TEST_CASE_ROOT}/before.sha256")" ]]
  [[ "$(generation_service_snapshot "${TEST_UNIT}")" == "${active}"$'\t'"${enabled}" ]]
  [[ ! -e "${PENDING_OP_FILE}" ]]
}

systemd_expected_failure() {
  local status=0

  generation_failed '注入的候选失败' || status=$?
  [[ "${status}" -eq 1 ]]
}

systemd_reenter() {
  # 原 CLI 在返回前会释放锁；这里直接调用底层恢复，因此先模拟该退出边界。
  release_script_lock
  bash "${TEST_SCRIPT_PATH}" --recover "${TEST_CASE_ROOT}" "${TEST_UNIT}"
}

systemd_case() {
  local scenario="${1}"
  local status=0

  case "${scenario}" in
    active|inactive|enabled-runtime)
      case "${scenario}" in
        active) systemd_fixture active enabled ;;
        inactive) systemd_fixture inactive disabled ;;
        enabled-runtime) systemd_fixture inactive enabled-runtime ;;
      esac
      systemd_generation_begin "${scenario}"
      printf 'new\n' > "${TEST_PAYLOAD}/config"
      chmod 0600 "${TEST_PAYLOAD}/config"
      systemctl disable "${TEST_UNIT}" >/dev/null
      systemctl enable --now "${TEST_UNIT}" >/dev/null
      systemd_expected_failure
      [[ "${GENERATION_RECOVERY_RESULT}" == restored-verified ]]
      case "${scenario}" in
        active) systemd_assert_restored active enabled ;;
        inactive) systemd_assert_restored inactive disabled ;;
        enabled-runtime) systemd_assert_restored inactive enabled-runtime ;;
      esac
      ;;
    absent)
      [[ "$(generation_service_snapshot "${TEST_UNIT}")" == $'not-installed\tnot-installed' ]]
      systemd_generation_begin absent
      mkdir "${TEST_PAYLOAD}"
      printf 'new\n' > "${TEST_PAYLOAD}/config"
      systemd_write_unit
      systemctl daemon-reload
      systemctl enable --now "${TEST_UNIT}" >/dev/null
      systemd_expected_failure
      [[ "${GENERATION_RECOVERY_RESULT}" == restored-verified ]]
      [[ ! -e "${TEST_UNIT_FILE}" && ! -e "${TEST_PAYLOAD}" && ! -e "${PENDING_OP_FILE}" ]]
      [[ "$(generation_service_snapshot "${TEST_UNIT}")" == $'not-installed\tnot-installed' ]]
      ;;
    stop-failure|reload-failure|restart-failure)
      systemd_fixture active enabled
      systemd_generation_begin "${scenario}"
      printf 'new\n' > "${TEST_PAYLOAD}/config"
      systemctl() {
        case "${scenario}:${1}" in
          stop-failure:stop|reload-failure:daemon-reload|restart-failure:restart) return 1 ;;
        esac
        command systemctl "$@"
      }
      systemd_expected_failure
      [[ "${GENERATION_RECOVERY_RESULT}" == recovery-failed && -f "${PENDING_OP_FILE}" ]]
      if [[ "${scenario}" == stop-failure ]]; then [[ "$(cat "${TEST_PAYLOAD}/config")" == new ]]; fi
      unset -f systemctl
      systemd_reenter
      systemd_assert_restored active enabled
      ;;
    shared-unit)
      # 模拟由软件包增加的共享 unit：它不在托管路径中，恢复不能擅自删除它。
      start_backup_session
      begin_generation_paths shared-unit "${TEST_UNIT}" -- "${TEST_PAYLOAD}"
      mkdir "${TEST_PAYLOAD}"
      systemd_write_unit
      systemctl daemon-reload
      systemctl enable --now "${TEST_UNIT}" >/dev/null
      systemd_expected_failure
      [[ "${GENERATION_RECOVERY_RESULT}" == recovery-failed && -f "${TEST_UNIT_FILE}" && -f "${PENDING_OP_FILE}" ]]
      [[ "$(generation_service_snapshot "${TEST_UNIT}")" == $'inactive\tdisabled' ]]
      # 测试清理掉模拟包单元后，再以持久证据重试。
      rm "${TEST_UNIT_FILE}"
      systemctl daemon-reload
      systemd_reenter
      [[ ! -e "${PENDING_OP_FILE}" ]]
      ;;
    committed-cleanup)
      systemd_fixture active enabled
      systemd_generation_begin committed-cleanup
      printf 'committed\n' > "${TEST_PAYLOAD}/config"
      clear_pending_operation() { return 1; }
      generation_commit || status=$?
      [[ "${status}" -ne 0 && -f "${PENDING_OP_FILE}" && -f "${BACKUP_DIR}/completed" ]]
      systemd_reenter
      [[ "$(cat "${TEST_PAYLOAD}/config")" == committed && ! -e "${PENDING_OP_FILE}" ]]
      ;;
    KILL|TERM|INT|exit)
      systemd_fixture inactive disabled
      set +e
      bash "${TEST_SCRIPT_PATH}" --interrupt "${TEST_CASE_ROOT}" "${TEST_UNIT}" "${scenario}" > "${TEST_CASE_ROOT}/interrupt.log" 2>&1
      status=$?
      set -e
      case "${scenario}" in
        KILL)
          [[ "${status}" -eq 137 && -f "${PENDING_OP_FILE}" ]]
          [[ "$(cat "${TEST_PAYLOAD}/config")" == new ]]
          systemd_reenter
          ;;
        TERM) [[ "${status}" -eq 143 ]] ;;
        INT) [[ "${status}" -eq 130 ]] ;;
        exit) [[ "${status}" -eq 7 ]] ;;
      esac
      systemd_assert_restored inactive disabled
      ;;
    *) return 2 ;;
  esac
}

systemd_suite_cleanup() {
  local unit=""

  for unit in "${TEST_SUITE_UNITS[@]}"; do
    systemctl disable --now "${unit}" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${unit}"
  done
  systemctl daemon-reload
}

case "${1:-}" in
  --recover)
    systemd_case_context "${2}" "${3}"
    run_cli_command recover --yes
    ;;
  --interrupt)
    systemd_case_context "${2}" "${3}"
    systemd_generation_begin "${4}"
    printf 'new\n' > "${TEST_PAYLOAD}/config"
    systemctl enable --now "${TEST_UNIT}" >/dev/null
    if [[ "${4}" == exit ]]; then exit 7; fi
    kill -s "${4}" "$$"
    ;;
  --case)
    systemd_case_context "${3}" "${4}"
    systemd_case "${2}"
    ;;
  *)
    TEST_SUITE_ROOT="$(mktemp -d /var/tmp/xtun-recovery.XXXXXX)"
    TEST_SUITE_UNITS=()
    trap systemd_suite_cleanup EXIT
    failures=0
    for scenario in active inactive enabled-runtime absent stop-failure reload-failure restart-failure shared-unit committed-cleanup KILL TERM INT exit; do
      unit="xtun-recovery-${TEST_SUITE_ROOT##*.}-${scenario}.service"
      TEST_SUITE_UNITS+=("${unit}")
      mkdir "${TEST_SUITE_ROOT}/${scenario}"
      set +e
      bash "${TEST_SCRIPT_PATH}" --case "${scenario}" "${TEST_SUITE_ROOT}/${scenario}" "${unit}" > "${TEST_SUITE_ROOT}/${scenario}/result.log" 2>&1
      status=$?
      set -e
      printf '%s\t%s\n' "${scenario}" "${status}" | tee -a "${TEST_SUITE_ROOT}/results.tsv"
      if [[ "${status}" -ne 0 ]]; then
        failures=$((failures + 1))
        tail -15 "${TEST_SUITE_ROOT}/${scenario}/result.log"
      fi
    done
    printf 'systemd evidence: %s\n' "${TEST_SUITE_ROOT}"
    [[ "${failures}" -eq 0 ]]
    ;;
esac
