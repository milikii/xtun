#!/usr/bin/env bash
# 只在授权的测试 VPS 上挂载小型 tmpfs，不填充根文件系统。
set -Eeuo pipefail

[[ "${XTUN_TEST_ISOLATED_VPS:-no}" == yes && "${EUID}" -eq 0 ]] || { printf '需要测试 VPS、root 与 XTUN_TEST_ISOLATED_VPS=yes。\n' >&2; exit 2; }
TEST_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "${TEST_SCRIPT_PATH}")/.." && pwd)"
# shellcheck disable=SC1090
source <(sed '$d' "${ROOT_DIR}/xtun.sh")

filesystem_case_context() {
  TEST_CASE_ROOT="${1}"
  TEST_MOUNT="${TEST_CASE_ROOT}/volume"
  TEST_TARGET="${TEST_CASE_ROOT}/target"
  BACKUP_ROOT="${TEST_CASE_ROOT}/backups"
  PENDING_OP_FILE="${TEST_CASE_ROOT}/pending.tsv"
  SCRIPT_LOCK_FILE="${TEST_CASE_ROOT}/lock"
  OP_LOG_DIR="${TEST_CASE_ROOT}/logs"
  OP_LOG_FILE="${OP_LOG_DIR}/operations.log"
}

filesystem_assert_old_target() {
  [[ "$(cat "${TEST_TARGET}")" == old ]]
  [[ "$(stat -c %a "${TEST_TARGET}")" == 640 ]]
}

filesystem_case() {
  local scenario="${1}"
  local status=0

  mkdir -p "${TEST_MOUNT}"
  mount -t tmpfs -o size=1m,nosuid,nodev tmpfs "${TEST_MOUNT}"
  printf 'old\n' > "${TEST_TARGET}"
  chmod 0640 "${TEST_TARGET}"
  case "${scenario}" in
    marker-readonly|marker-full) PENDING_OP_FILE="${TEST_MOUNT}/pending.tsv" ;;
    manifest-readonly|manifest-full) BACKUP_ROOT="${TEST_MOUNT}/backups" ;;
    target-readonly)
      TEST_TARGET="${TEST_MOUNT}/target"
      printf 'old\n' > "${TEST_TARGET}"
      chmod 0640 "${TEST_TARGET}"
      ;;
  esac
  start_backup_session
  if [[ "${scenario}" == target-readonly ]]; then
    begin_generation_paths readonly-target -- "${TEST_TARGET}"
    mount -o remount,ro "${TEST_MOUNT}"
    filesystem_new_text() { printf 'new\n'; }
    write_generated_file_atomically "${TEST_TARGET}" filesystem_new_text || status=$?
    [[ "${status}" -ne 0 ]]
    filesystem_assert_old_target
    status=0
    generation_failed '目标只读' || status=$?
    [[ "${status}" -ne 0 && "${GENERATION_RECOVERY_RESULT}" == recovery-failed && -f "${PENDING_OP_FILE}" ]]
    mount -o remount,rw "${TEST_MOUNT}"
    release_script_lock
    bash "${TEST_SCRIPT_PATH}" --recover "${TEST_CASE_ROOT}" "${TEST_TARGET}"
    filesystem_assert_old_target
    [[ ! -e "${PENDING_OP_FILE}" ]]
  else
    case "${scenario}" in
      *-readonly) mount -o remount,ro "${TEST_MOUNT}" ;;
      *-full)
        dd if=/dev/zero of="${TEST_MOUNT}/fill" bs=64K count=32 status=none 2> "${TEST_CASE_ROOT}/enospc.log" || status=$?
        [[ "${status}" -ne 0 ]]
        grep -q 'No space left on device' "${TEST_CASE_ROOT}/enospc.log"
        ;;
    esac
    status=0
    begin_generation_paths "${scenario}" -- "${TEST_TARGET}" || status=$?
    [[ "${status}" -ne 0 && "${GENERATION_ACTIVE}" == no ]]
    filesystem_assert_old_target
    [[ ! -e "${PENDING_OP_FILE}" ]]
    if [[ "${scenario}" == *-readonly ]]; then mount -o remount,rw "${TEST_MOUNT}"; fi
  fi
  release_script_lock
  # 从 tmpfs 带走备份证据后卸载；root 分区只保存实际使用的一小段内容。
  rm -f "${TEST_MOUNT}/fill"
  cp -a "${TEST_MOUNT}" "${TEST_CASE_ROOT}/volume-evidence"
  umount "${TEST_MOUNT}"
}

filesystem_suite_cleanup() {
  local mountpoint=""

  for mountpoint in "${TEST_SUITE_ROOT}"/*/volume; do
    if mountpoint -q "${mountpoint}"; then
      umount "${mountpoint}" || true
    fi
  done
}

case "${1:-}" in
  --recover)
    filesystem_case_context "${2}"
    TEST_TARGET="${3}"
    run_cli_command recover --yes
    ;;
  --case)
    filesystem_case_context "${3}"
    filesystem_case "${2}"
    ;;
  *)
    TEST_SUITE_ROOT="$(mktemp -d /var/tmp/xtun-filesystem.XXXXXX)"
    trap filesystem_suite_cleanup EXIT
    failures=0
    for scenario in marker-readonly manifest-readonly marker-full manifest-full target-readonly; do
      mkdir "${TEST_SUITE_ROOT}/${scenario}"
      set +e
      LC_ALL=C bash "${TEST_SCRIPT_PATH}" --case "${scenario}" "${TEST_SUITE_ROOT}/${scenario}" > "${TEST_SUITE_ROOT}/${scenario}/result.log" 2>&1
      status=$?
      set -e
      printf '%s\t%s\n' "${scenario}" "${status}" | tee -a "${TEST_SUITE_ROOT}/results.tsv"
      if [[ "${status}" -ne 0 ]]; then
        failures=$((failures + 1))
        tail -20 "${TEST_SUITE_ROOT}/${scenario}/result.log"
      fi
    done
    printf 'filesystem evidence: %s\n' "${TEST_SUITE_ROOT}"
    [[ "${failures}" -eq 0 ]]
    ;;
esac
