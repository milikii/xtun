# shellcheck shell=bash

# ------------------------------
# 脚本自安装与自更新层
# 负责 wrapper/bundle 持久化与自更新流程
# ------------------------------

install_self_command() {
  local source_path="${SCRIPT_SELF:-$0}"
  local source_real=""
  local source_root=""
  local staging_dir=""
  local source_bundle_root=""

  if [[ ! -f "${source_path}" ]]; then
    warn "无法写入持久化管理命令，因为当前脚本路径不可用。"
    return
  fi

  source_real="$(readlink -f "${source_path}" 2>/dev/null || printf '%s' "${source_path}")"
  source_root="$(cd "$(dirname "${source_real}")" && pwd)"
  [[ -d "${source_root}/lib" ]] || die "当前脚本目录缺少 lib/，无法安装持久化管理命令。"
  source_bundle_root="${source_root}"

  if [[ "${source_root}" == "${SELF_INSTALL_DIR}" ]]; then
    staging_dir="$(mktemp -d)"
    install -m 0755 "${source_root}/xtun.sh" "${staging_dir}/xtun.sh"
    cp -a "${source_root}/lib" "${staging_dir}/lib"
    if [[ -d "${source_root}/static" ]]; then
      cp -a "${source_root}/static" "${staging_dir}/static"
    fi
    if [[ -f "${source_root}/.xtun-bundle.json" ]]; then
      cp -a "${source_root}/.xtun-bundle.json" "${staging_dir}/.xtun-bundle.json" || return 1
    fi
    source_bundle_root="${staging_dir}"
  fi

  install_bundle_root_to_self "${source_bundle_root}" || {
    [[ -n "${staging_dir}" ]] && rm -rf "${staging_dir}"
    return 1
  }
  if [[ -n "${staging_dir}" ]]; then
    rm -rf "${staging_dir}"
  fi

  return 0
}

bundle_script_version() {
  local bundle_root="${1}"

  sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "${bundle_root}/xtun.sh" 2>/dev/null | head -n 1
}

# 只哈希运行时会被安装的三个路径（xtun.sh / lib / static），与 SELF_INSTALL_DIR 的内容对齐。
# 源码归档（codeload tar.gz）里还有 README / tests / docs 等不进安装目录的文件，
# 若把它们算进去，installed_script_matches_bundle 永远为假，update-script 每次都全量重装。
bundle_script_signature() {
  [[ -d "${1}" ]] || return 0
  bundle_content_signature "${1}"
}

installed_script_version() {
  if [[ -f "${SELF_INSTALL_DIR}/xtun.sh" ]]; then
    bundle_script_version "${SELF_INSTALL_DIR}"
    return
  fi

  printf '%s' "${SCRIPT_VERSION}"
}

installed_script_matches_bundle() {
  local bundle_root="${1}"
  local installed_signature=""
  local bundle_signature=""

  bundle_identity_valid "${SELF_INSTALL_DIR}" || return 1
  installed_signature="$(bundle_script_signature "${SELF_INSTALL_DIR}")"
  bundle_signature="$(bundle_script_signature "${bundle_root}")"
  [[ -n "${installed_signature}" && -n "${bundle_signature}" && "${installed_signature}" == "${bundle_signature}" ]]
}

cleanup_script_bundle_tmp_dir() {
  local tmp_dir="${1:-}"

  [[ -n "${tmp_dir}" ]] || return 0
  rm -rf "${tmp_dir}"
}

install_bundle_root_to_self() {
  local source_bundle_root="${1}"
  local target_entry="${SELF_INSTALL_DIR}/xtun.sh"
  local wrapper_tmp=""
  bundle_root_ready "${source_bundle_root}" || die "脚本 bundle 缺少必需文件，无法安装。"

  backup_path "${SELF_INSTALL_DIR}" || return 1
  backup_path "${SELF_COMMAND_PATH}" || return 1

  rm -rf "${SELF_INSTALL_DIR}" || return 1
  install -d -m 0755 "${SELF_INSTALL_DIR}" || return 1
  install -d -m 0755 "$(dirname "${SELF_COMMAND_PATH}")" || return 1
  install -m 0755 "${source_bundle_root}/xtun.sh" "${target_entry}" || return 1
  cp -a "${source_bundle_root}/lib" "${SELF_INSTALL_DIR}/lib" || return 1
  if [[ -d "${source_bundle_root}/static" ]]; then
    cp -a "${source_bundle_root}/static" "${SELF_INSTALL_DIR}/static" || return 1
  fi
  write_bundle_install_identity "${source_bundle_root}" "${SELF_INSTALL_DIR}" || return 1

  wrapper_tmp="$(mktemp)"
  cat > "${wrapper_tmp}" <<EOF
#!/usr/bin/env bash
export XTUN_COMMAND_NAME="\$(basename "\$0")"
exec "${target_entry}" "\$@"
EOF
  install -m 0755 "${wrapper_tmp}" "${SELF_COMMAND_PATH}" || { rm -f "${wrapper_tmp}"; return 1; }
  rm -f "${wrapper_tmp}"
}

download_latest_script_bundle() {
  bootstrap_download_bundle "${1}"
}

update_script_cmd() {
  local previous_version=""
  local current_version=""
  local tmp_dir=""
  local bundle_root=""
  local reinstall=0 before_signature="" current_signature=""

  while [[ $# -gt 0 ]]; do
    if handle_change_common_arg "${1}"; then shift; continue; fi
    case "${1}" in
      --reinstall) reinstall=1; shift ;;
      --help|-h|help) usage; return 0 ;;
      *) die "未知的 update-script 参数：${1}" ;;
    esac
  done
  need_root
  previous_version="$(installed_script_version)"
  before_signature="$(bundle_script_signature "${SELF_INSTALL_DIR}")" || return 1

  tmp_dir="$(mktemp -d)"
  log_step "下载最新脚本 bundle。"
  if ! bundle_root="$(download_latest_script_bundle "${tmp_dir}")"; then
    cleanup_script_bundle_tmp_dir "${tmp_dir}"
    die "下载最新脚本 bundle 失败。"
  fi

  current_version="$(bundle_script_version "${bundle_root}")"
  if ! acquire_script_lock; then cleanup_script_bundle_tmp_dir "${tmp_dir}"; return 1; fi
  if pending_operation_present; then
    cleanup_script_bundle_tmp_dir "${tmp_dir}"
    warn "存在未完成操作，请先运行 xtun recover。"
    return 1
  fi
  if [[ "${reinstall}" -eq 0 ]] && installed_script_matches_bundle "${bundle_root}"; then
    cleanup_script_bundle_tmp_dir "${tmp_dir}"
    log_success "当前已经是最新脚本 bundle。"
    [[ -n "${current_version}" ]] && log "当前版本：${current_version}"
    return 0
  fi
  current_signature="$(bundle_script_signature "${bundle_root}")" || { cleanup_script_bundle_tmp_dir "${tmp_dir}"; return 1; }
  if [[ "${reinstall}" -eq 0 && -n "${before_signature}" && "${before_signature}" == "${current_signature}" ]]; then
    cleanup_script_bundle_tmp_dir "${tmp_dir}"
    warn "bundle 内容相同，但安装身份未核验。请显式运行 xtun update-script --reinstall 建立安装记录。"
    return 1
  fi
  local confirmation_status=0
  (confirm_maintenance_action "更新脚本：${previous_version} → ${current_version}" \
    "${SELF_INSTALL_DIR}、${SELF_COMMAND_PATH}" "不应用服务配置，不中断连接" \
    "失败恢复本次 bundle 与入口") || confirmation_status=$?
  if [[ "${confirmation_status}" -ne 0 ]]; then
    cleanup_script_bundle_tmp_dir "${tmp_dir}"
    return "${confirmation_status}"
  fi
  if ! begin_mutation; then
    cleanup_script_bundle_tmp_dir "${tmp_dir}"
    return 1
  fi
  if [[ "$(bundle_script_signature "${SELF_INSTALL_DIR}")" != "${before_signature}" ]]; then
    cleanup_script_bundle_tmp_dir "${tmp_dir}"
    warn "确认期间脚本现场发生变化，请重新执行更新。"
    return 1
  fi
  if ! start_backup_session || ! begin_generation_paths "脚本 bundle 更新" -- "${SELF_INSTALL_DIR}" "${SELF_COMMAND_PATH}"; then
    cleanup_script_bundle_tmp_dir "${tmp_dir}"
    return 1
  fi
  # 下载时不持有锁，获得锁后再次核对现场。
  previous_version="$(installed_script_version)"
  log_step "安装脚本 bundle。"
  if ! install_bundle_root_to_self "${bundle_root}"; then
    cleanup_script_bundle_tmp_dir "${tmp_dir}"
    generation_failed "脚本 bundle 安装失败"
    return 1
  fi

  cleanup_script_bundle_tmp_dir "${tmp_dir}"
  generation_commit || return 1
  log_success "脚本 bundle 已更新。"
  log "备份目录：${BACKUP_DIR}"
  [[ -n "${previous_version}" ]] && log "更新前版本：${previous_version}"
  [[ -n "${current_version}" ]] && log "当前版本：${current_version}"
  if [[ -n "${previous_version}" && -n "${current_version}" && "${previous_version}" == "${current_version}" ]]; then
    log "脚本内容已更新，但版本号保持为 ${current_version}。"
  fi
  reload_updated_script_if_needed "${current_version}"
}

reload_updated_script_if_needed() {
  local current_version="${1:-}"

  [[ -n "${current_version}" ]] || return 0
  SCRIPT_VERSION="${current_version}"

  if [[ "${IN_MAIN_MENU:-0}" == "1" ]]; then
    log "已更新到 ${current_version}。请退出并重新打开菜单以载入新版本。"
    return 0
  fi

  log "已更新到 ${current_version}。当前进程仍使用旧代码路径时，请重新运行脚本以完整载入新版本。"
}
