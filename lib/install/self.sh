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
    source_bundle_root="${staging_dir}"
  fi

  install_bundle_root_to_self "${source_bundle_root}"
  if [[ -n "${staging_dir}" ]]; then
    rm -rf "${staging_dir}"
  fi

  return 0
}

bundle_script_version() {
  local bundle_root="${1}"

  sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "${bundle_root}/xtun.sh" 2>/dev/null | head -n 1
}

bundle_script_signature() {
  local bundle_root="${1}"

  [[ -d "${bundle_root}" ]] || return 0
  (
    cd "${bundle_root}" || exit 0
    find . -type f -print | LC_ALL=C sort | while IFS= read -r path; do
      sha256sum "${path}"
    done | sha256sum | awk '{print $1}'
  )
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

  backup_path "${SELF_INSTALL_DIR}"
  backup_path "${SELF_COMMAND_PATH}"

  rm -rf "${SELF_INSTALL_DIR}"
  install -d -m 0755 "${SELF_INSTALL_DIR}"
  install -d -m 0755 "$(dirname "${SELF_COMMAND_PATH}")"
  install -m 0755 "${source_bundle_root}/xtun.sh" "${target_entry}"
  cp -a "${source_bundle_root}/lib" "${SELF_INSTALL_DIR}/lib"
  if [[ -d "${source_bundle_root}/static" ]]; then
    cp -a "${source_bundle_root}/static" "${SELF_INSTALL_DIR}/static"
  fi

  wrapper_tmp="$(mktemp)"
  cat > "${wrapper_tmp}" <<EOF
#!/usr/bin/env bash
export XTUN_COMMAND_NAME="\$(basename "\$0")"
exec "${target_entry}" "\$@"
EOF
  install -m 0755 "${wrapper_tmp}" "${SELF_COMMAND_PATH}"
  rm -f "${wrapper_tmp}"
}

download_latest_script_bundle() {
  local target_dir="${1}"
  local archive_url=""
  local archive_path="${target_dir}/xtun.tar.gz"
  local bundle_root=""

  archive_url="$(bootstrap_resolve_archive_url)"
  printf '[信息] %s\n' "下载来源：${archive_url}" >&2
  curl -fsSL "${archive_url}" -o "${archive_path}" || return 1
  tar -xzf "${archive_path}" -C "${target_dir}" || return 1
  bundle_root="$(find "${target_dir}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  bundle_root_ready "${bundle_root}" || return 1
  printf '%s' "${bundle_root}"
}

update_script_cmd() {
  local previous_version=""
  local current_version=""
  local tmp_dir=""
  local bundle_root=""

  need_root
  start_backup_session
  previous_version="$(installed_script_version)"

  tmp_dir="$(mktemp -d)"
  log_step "下载最新脚本 bundle。"
  if ! bundle_root="$(download_latest_script_bundle "${tmp_dir}")"; then
    cleanup_script_bundle_tmp_dir "${tmp_dir}"
    die "下载最新脚本 bundle 失败。"
  fi

  current_version="$(bundle_script_version "${bundle_root}")"
  if installed_script_matches_bundle "${bundle_root}"; then
    cleanup_script_bundle_tmp_dir "${tmp_dir}"
    log_success "当前已经是最新脚本 bundle。"
    [[ -n "${current_version}" ]] && log "当前版本：${current_version}"
    return 0
  fi

  log_step "安装脚本 bundle。"
  if ! install_bundle_root_to_self "${bundle_root}"; then
    warn "脚本 bundle 安装失败，正在回滚持久化脚本文件。"
    restore_backup_path "${SELF_INSTALL_DIR}" || true
    restore_backup_path "${SELF_COMMAND_PATH}" || true
    cleanup_script_bundle_tmp_dir "${tmp_dir}"
    return 1
  fi

  cleanup_script_bundle_tmp_dir "${tmp_dir}"
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

  if [[ "${IN_MAIN_MENU:-0}" == "1" && -x "${SELF_COMMAND_PATH}" ]]; then
    log "已更新到 ${current_version}，正在重新载入脚本。"
    exec "${SELF_COMMAND_PATH}"
  fi

  log "已更新到 ${current_version}。当前进程仍使用旧代码路径时，请重新运行脚本以完整载入新版本。"
}
