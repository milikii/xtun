# shellcheck shell=bash

# ------------------------------
# 基础工具层
# 负责最小核心工具与基础模块装配
# ------------------------------

append_operation_log() {
  local line="${1}"

  if mkdir -p "${OP_LOG_DIR}" 2>/dev/null; then
    printf '%s\n' "${line}" >> "${OP_LOG_FILE}" 2>/dev/null || true
  fi
  if [[ -n "${SESSION_LOG_FILE:-}" ]]; then
    if mkdir -p "$(dirname "${SESSION_LOG_FILE}")" 2>/dev/null; then
      printf '%s\n' "${line}" >> "${SESSION_LOG_FILE}" 2>/dev/null || true
    fi
  fi
}

emit_log() {
  local level="${1}"
  local stream="${2}"
  shift 2
  local message="$*"
  local timestamp=""
  local line=""

  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  line="[${timestamp}] [${level}] ${message}"
  if [[ "${stream}" == "stderr" ]]; then
    printf '%s\n' "${line}" >&2
  else
    printf '%s\n' "${line}"
  fi
  append_operation_log "${line}"
}

log() {
  emit_log "信息" "stdout" "$*"
}

log_step() {
  emit_log "步骤" "stdout" "$*"
}

log_success() {
  emit_log "完成" "stdout" "$*"
}

warn() {
  emit_log "警告" "stderr" "$*"
}

die() {
  emit_log "错误" "stderr" "$*"
  exit 1
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 用户运行此脚本。"
  fi
}

script_lock_dir_owner_alive() {
  local lock_dir="${1}"
  local owner_pid=""

  owner_pid="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
  [[ "${owner_pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${owner_pid}" 2>/dev/null || return 1
  return 0
}

acquire_script_lock_dir() {
  local lock_dir="${1}"

  if ! mkdir "${lock_dir}" 2>/dev/null; then
    # 目录还在但持有者已经消失（被 kill -9、断线、或 EXIT trap 被后续 trap 覆盖），
    # 属于陈旧锁，回收后重试一次，避免机器被永久锁死。
    script_lock_dir_owner_alive "${lock_dir}" && return 1
    rm -rf "${lock_dir}" 2>/dev/null || true
    mkdir "${lock_dir}" 2>/dev/null || return 1
  fi

  printf '%s\n' "$$" > "${lock_dir}/pid" 2>/dev/null || true
  SCRIPT_LOCK_DIR="${lock_dir}"
  SCRIPT_LOCK_HELD=1
}

acquire_script_lock() {
  local lock_file="${SCRIPT_LOCK_FILE}"
  local lock_opened=0

  [[ "${SCRIPT_LOCK_HELD}" -eq 1 ]] && return 0

  mkdir -p "$(dirname "${lock_file}")" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    if touch "${lock_file}" >/dev/null 2>&1; then
      exec 9>"${lock_file}"
      lock_opened=1
    else
      lock_file="/tmp/$(basename "${SCRIPT_LOCK_FILE}")"
      touch "${lock_file}" >/dev/null 2>&1 || die "无法创建脚本锁文件：${lock_file}"
      exec 9>"${lock_file}" || die "无法创建脚本锁文件：${lock_file}"
      lock_opened=1
    fi

    [[ "${lock_opened}" -eq 1 ]] || die "无法创建脚本锁文件。"
    flock -n 9 || die "检测到另一个 xtun 进程正在运行，请稍后重试。"
    SCRIPT_LOCK_HELD=1
    return
  fi

  acquire_script_lock_dir "${lock_file}.d" && return
  acquire_script_lock_dir "/tmp/$(basename "${SCRIPT_LOCK_FILE}").d" && return

  die "检测到另一个 xtun 进程正在运行，请稍后重试。"
}

release_script_lock() {
  [[ "${SCRIPT_LOCK_HELD}" -eq 1 ]] || return 0

  if [[ -n "${SCRIPT_LOCK_DIR}" ]]; then
    rm -rf "${SCRIPT_LOCK_DIR}" 2>/dev/null || true
    SCRIPT_LOCK_DIR=""
  else
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
  fi

  SCRIPT_LOCK_HELD=0
}

. "${SCRIPT_ROOT}/lib/base/input.sh"
. "${SCRIPT_ROOT}/lib/base/env.sh"
