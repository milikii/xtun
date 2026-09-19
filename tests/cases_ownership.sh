# shellcheck shell=bash

run_backup_first_snapshot_case() {
  local workdir=""
  local session=""
  local target=""
  local rows=""

  load_functions
  workdir="$(mktemp -d)"
  BACKUP_ROOT="${workdir}/backups"
  BACKUP_KEEP_COUNT=5
  target="${workdir}/data/config.txt"
  mkdir -p "$(dirname "${target}")"
  printf 'BEFORE\n' > "${target}"

  start_backup_session
  session="${BACKUP_DIR}"
  backup_path "${target}"

  # 第二次备份时文件已经是 AFTER：第一次快照不能被它覆盖
  printf 'AFTER\n' > "${target}"
  backup_path "${target}"

  [[ "$(cat "${session}/$(backup_manifest_field "${target}" 6)")" == 'BEFORE' ]]
  rows="$(grep -cF "${target}"$'\t' "${session}/manifest.tsv")"
  [[ "${rows}" == '1' ]]
  grep -q "BEFORE" "${session}/$(backup_manifest_field "${target}" 6)"

  # 不存在的路径：清单记 existed=0，不留快照；恢复时按「本来就没有」删掉
  backup_path "${workdir}/data/new-file.txt"
  grep -qF "${workdir}/data/new-file.txt"$'\t0\tmanaged\tcreate' "${session}/manifest.tsv"
  [[ ! -e "${session}${workdir}/data/new-file.txt" ]]
  printf 'created\n' > "${workdir}/data/new-file.txt"
  restore_backup_path "${workdir}/data/new-file.txt"
  [[ ! -e "${workdir}/data/new-file.txt" ]]

  rm -rf "${workdir}"
}

run_backup_missing_path_first_record_case() {
  local workdir=""
  local session=""
  local target=""
  local rows=""

  load_functions
  workdir="$(mktemp -d)"
  BACKUP_ROOT="${workdir}/backups"
  SCRIPT_LOCK_FILE="${workdir}/xtun.lock"
  SCRIPT_LOCK_HELD=0
  target="${workdir}/data/created.txt"
  mkdir -p "$(dirname "${target}")"

  start_backup_session
  session="${BACKUP_DIR}"
  backup_path "${target}"
  printf 'created-by-this-action\n' > "${target}"
  backup_path "${target}"

  rows="$(grep -cF "${target}"$'\t' "${session}/manifest.tsv")"
  [[ "${rows}" == "1" ]]
  [[ "$(backup_manifest_field "${target}" 3)" == "0" ]]
  result="$(restore_generation_path "${target}")"
  [[ "${result}" == "deleted" ]]
  [[ ! -e "${target}" ]]
  restore_backup_path "${target}" || true

  rm -rf "${workdir}"
}

run_backup_manifest_failure_case() {
  local workdir=""
  local target=""

  load_functions
  workdir="$(mktemp -d)"
  target="${workdir}/data/config.txt"
  mkdir -p "$(dirname "${target}")"
  printf 'original\n' > "${target}"

  # 备份根是普通文件：会话不能创建，托管目标不能被改动。
  BACKUP_ROOT="${workdir}/not-a-directory"
  SCRIPT_LOCK_FILE="${workdir}/xtun.lock"
  SCRIPT_LOCK_HELD=0
  : > "${BACKUP_ROOT}"
  if ( start_backup_session >/dev/null 2>&1 ); then
    printf '[fail] 备份会话初始化失败不能返回成功\n' >&2
    return 1
  fi
  [[ "$(cat "${target}")" == 'original' ]]

  # manifest 变成目录：登记失败必须阻断，不能只留下快照。
  BACKUP_ROOT="${workdir}/backups"
  start_backup_session
  rm -f "${BACKUP_DIR}/manifest.tsv"
  mkdir "${BACKUP_DIR}/manifest.tsv"
  if ( backup_path "${target}" >/dev/null 2>&1 ); then
    printf '[fail] manifest 写入失败不能返回成功\n' >&2
    return 1
  fi
  [[ "$(cat "${target}")" == 'original' ]]
  [[ ! -e "${BACKUP_DIR}${target}" ]]

  rm -rf "${workdir}"
}

run_backup_restore_evidence_case() {
  local workdir=""
  local session=""
  local target=""

  load_functions
  workdir="$(mktemp -d)"
  BACKUP_ROOT="${workdir}/backups"
  SCRIPT_LOCK_FILE="${workdir}/xtun.lock"
  SCRIPT_LOCK_HELD=0
  target="${workdir}/data/important.txt"
  mkdir -p "$(dirname "${target}")"
  printf 'important\n' > "${target}"

  start_backup_session
  session="${BACKUP_DIR}"
  backup_path "${target}"

  # 清单缺失：不能把已有文件解释成本来不存在。
  rm -f "${session}/manifest.tsv"
  if ( restore_backup_path "${target}" >/dev/null 2>&1 ); then
    printf '[fail] 缺少 manifest 时恢复不能成功\n' >&2
    return 1
  fi
  [[ "$(cat "${target}")" == 'important' ]]

  # 摘要不符：快照不能冒充可信原件。
  start_backup_session
  session="${BACKUP_DIR}"
  backup_path "${target}"
  printf 'tampered-snapshot\n' > "${session}/$(backup_manifest_field "${target}" 6)"
  if ( restore_backup_path "${target}" >/dev/null 2>&1 ); then
    printf '[fail] 快照摘要不符时恢复不能成功\n' >&2
    return 1
  fi
  [[ "$(cat "${target}")" == 'important' ]]

  rm -rf "${workdir}"
}

run_shared_haproxy_uninstall_failure_case() {
  local workdir=""
  local output=""
  local item=""
  local -a stopped=()
  local unit_dir=""
  local -a systemctl_calls=()

  load_functions
  workdir="$(mktemp -d)"
  stopped_log="${workdir}/stopped.log"
  systemctl_log="${workdir}/systemctl.log"
  BACKUP_ROOT="${workdir}/backups"
  ORIGINALS_ROOT="${workdir}/originals"
  SCRIPT_LOCK_FILE="${workdir}/xtun.lock"
  SELF_COMMAND_PATH="${workdir}/usr/local/sbin/xtun"
  SELF_INSTALL_DIR="${workdir}/usr/local/lib/xtun"
  XRAY_BIN="${workdir}/usr/local/bin/xray"
  XRAY_CONFIG_DIR="${workdir}/usr/local/etc/xray"
  XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
  XRAY_ASSET_DIR="${workdir}/usr/local/share/xray"
  XRAY_SERVICE_FILE="${workdir}/etc/systemd/system/xray.service"
  XRAY_LOGROTATE_FILE="${workdir}/etc/logrotate.d/xtun"
  WARP_RULES_FILE="${XRAY_CONFIG_DIR}/warp-domains.list"
  STATE_FILE="${XRAY_CONFIG_DIR}/node-meta.env"
  HAPROXY_CONFIG="${workdir}/etc/haproxy/haproxy.cfg"
  NGINX_CONFIG_FILE="${workdir}/etc/nginx/conf.d/xtun.conf"
  NGINX_LIMITS_DROPIN_FILE="${workdir}/etc/systemd/system/nginx.service.d/xtun-limits.conf"
  NGINX_MAIN_CONFIG="${workdir}/etc/nginx/nginx.conf"
  FALLBACK_SITE_DIR="${workdir}/var/www/xtun-fallback"
  SSL_DIR="${workdir}/etc/ssl/xtun"
  NET_SYSCTL_CONF="${workdir}/etc/sysctl.d/98-xtun-net.conf"
  NET_HELPER_PATH="${workdir}/usr/local/sbin/xtun-net-optimize.sh"
  NET_SERVICE_FILE="${workdir}/etc/systemd/system/xtun-net-optimize.service"
  ACME_HOME="${workdir}/root/.acme.sh"
  ACME_SH_BIN="${ACME_HOME}/acme.sh"
  ACME_RELOAD_HELPER="${workdir}/usr/local/sbin/xtun-cert-reload.sh"
  OUTPUT_FILE="${workdir}/root/xtun-output.md"
  QR_OUTPUT_DIR="${workdir}/root/xtun-qr"
  XRAY_LOG_DIR="${workdir}/var/log/xray"
  XRAY_STATE_DIR="${workdir}/var/lib/xray"
  OP_LOG_DIR="${workdir}/var/log/xtun"
  INSTALL_DRAFT_FILE="${workdir}/root/.xtun-install-draft.env"
  LEGACY_PATH_ROOT="${workdir}"
  SYSTEMD_UNIT_DIRS=("${workdir}/etc/systemd/system")

  mkdir -p "$(dirname "${HAPROXY_CONFIG}")" "${SYSTEMD_UNIT_DIRS[0]}" "${ORIGINALS_ROOT}"
  printf 'global\n  daemon\n' > "${HAPROXY_CONFIG}"
  unit_dir="${SYSTEMD_UNIT_DIRS[0]}"
  printf '[Unit]\n' > "${unit_dir}/xray.service"
  printf '[Unit]\n' > "${unit_dir}/haproxy.service"
  {
    printf '# xtun-takeover-manifest\tv1\n'
    printf 'haproxy\t1\t2026-09-13T00:00:00Z\n'
  } > "${ORIGINALS_ROOT}/manifest.tsv"

  need_root() { :; }
  load_existing_state() {
    CERT_MODE="self-signed"
    NGINX_MAIN_MANAGED="no"
    ENABLE_NET_OPT="no"
  }
  install_port_ownership_text() { printf '空闲'; }
  ss() { :; }
  sysctl() { :; }
  stop_and_disable_service_if_present() { printf '%s\n' "${1}" >> "${stopped_log}"; }
  systemctl() {
    printf '%s\n' "$*" >> "${systemctl_log}"
    case "$*" in
      'show '*' -p ActiveState --value') printf 'active\n' ;;
      'reload haproxy.service') return 1 ;;
      *) return 0 ;;
    esac
  }

  if ( uninstall_cmd --yes > "${workdir}/uninstall.out" 2>&1 ); then
    printf '[fail] 共享 HAProxy reload 失败时卸载不能报成功\n' >&2
    return 1
  fi
  output="$(cat "${workdir}/uninstall.out")"
  [[ -f "${HAPROXY_CONFIG}" ]]
  [[ "${output}" == *'共享 HAProxy'* ]]
  [[ "${output}" == *'未能确认'* ]]
  grep -qx 'reload haproxy.service' "${systemctl_log}"
  [[ -f "${ORIGINALS_ROOT}/manifest.tsv" ]]

  rm -rf "${workdir}"
}

run_backup_session_rotation_case() {
  local workdir=""
  local first=""
  local second=""
  local failed=""
  local newest=""

  load_functions
  workdir="$(mktemp -d)"
  BACKUP_ROOT="${workdir}/backups"
  BACKUP_KEEP_COUNT=2

  start_backup_session
  first="${BACKUP_DIR}"
  finish_backup_session

  start_backup_session
  second="${BACKUP_DIR}"
  finish_backup_session

  # 同一秒里的两次操作不能共用备份目录
  [[ "${first}" != "${second}" ]]

  # 中断/失败的那一份不写 completed，是排障现场，保留规则不许动它
  start_backup_session
  failed="${BACKUP_DIR}"

  start_backup_session
  newest="${BACKUP_DIR}"
  finish_backup_session

  touch -d '3 hours ago' "${first}"
  touch -d '2 hours ago' "${second}"
  touch -d '90 minutes ago' "${failed}"
  touch -d '1 minute ago' "${newest}"
  prune_backup_sessions

  [[ -d "${newest}" ]]
  [[ -d "${second}" ]]
  [[ ! -d "${first}" ]]
  [[ -d "${failed}" ]]
  [[ ! -f "${failed}/completed" ]]
  [[ -f "${newest}/completed" ]]

  rm -rf "${workdir}"
}

run_takeover_metadata_failure_case() {
  local workdir=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  ORIGINALS_ROOT="${workdir}/originals"
  NGINX_MAIN_CONFIG="${workdir}/nginx.conf"
  NGINX_MAIN_MANAGED=yes
  printf original > "${NGINX_MAIN_CONFIG}"
  record_takeover_original "${NGINX_MAIN_CONFIG}"
  printf candidate > "${NGINX_MAIN_CONFIG}"
  printf corrupted > "$(takeover_original_path "${NGINX_MAIN_CONFIG}")"
  restore_nginx_main_config >/dev/null 2>&1 || status=$?
  [[ "${status}" -ne 0 && "$(cat "${NGINX_MAIN_CONFIG}")" == candidate ]]

  ORIGINALS_ROOT="${workdir}/absent-originals"
  record_takeover_original "${workdir}/created.conf"
  printf created > "${workdir}/created.conf"
  record_takeover_original "${workdir}/created.conf"
  [[ "$(takeover_original_existed "${workdir}/created.conf")" == 0 ]]

  ORIGINALS_ROOT="${workdir}/sync-failure"
  sync_required_path() { return 1; }
  status=0
  record_takeover_original "${NGINX_MAIN_CONFIG}" || status=$?
  [[ "${status}" -ne 0 && "$(cat "${NGINX_MAIN_CONFIG}")" == candidate ]]
  unset -f sync_required_path
  rm -rf "${workdir}"
  load_functions
}

run_package_origin_metadata_failure_case() {
  local workdir=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  ORIGINALS_ROOT="${workdir}/unwritable"
  mkdir -p "${ORIGINALS_ROOT}/manifest.tsv"
  dpkg-query() { printf 'jq\tinstalled\n'; }
  record_package_origin jq || status=$?
  [[ "${status}" -ne 0 ]]

  ORIGINALS_ROOT="${workdir}/inventory-failure"
  dpkg-query() { return 1; }
  status=0
  record_package_origin jq || status=$?
  [[ "${status}" -ne 0 && ! -e "${ORIGINALS_ROOT}/manifest.tsv" ]]

  ORIGINALS_ROOT="${workdir}/working"
  dpkg-query() { printf 'jq\tinstalled\nunzip\tconfig-files\n'; }
  record_package_origin jq
  record_package_origin qrencode
  record_package_origin unzip
  ! package_installed_by_xtun jq
  ! package_installed_by_xtun unzip
  package_installed_by_xtun qrencode
  dpkg-query() { printf 'qrencode\tinstalled\n'; }
  record_package_origin qrencode
  package_installed_by_xtun qrencode
  printf 'broken-row\n' >> "${ORIGINALS_ROOT}/manifest.tsv"
  ! package_installed_by_xtun qrencode
  unset -f dpkg-query
  rm -rf "${workdir}"
  load_functions
}

run_backup_manifest_case() {
  local workdir=""
  local session=""
  local target=""

  load_functions
  workdir="$(mktemp -d)"
  BACKUP_ROOT="${workdir}/backups"
  target="${workdir}/etc/nginx/nginx.conf"
  mkdir -p "$(dirname "${target}")"
  printf 'foreign config\n' > "${target}"

  start_backup_session
  session="${BACKUP_DIR}"
  backup_path "${target}" takeover

  head -n 1 "${session}/manifest.tsv" | grep -q 'xtun-backup-manifest'
  grep -qF "${target}"$'\t1\ttakeover\treplace\t' "${session}/manifest.tsv"
  # 摘要列必须是真的 sha256，而不是占位符
  awk -F'\t' -v target="${target}" '$2 == target { print $7 }' "${session}/manifest.tsv" \
    | grep -qE '^[0-9a-f]{64}$'
  [[ "$(awk -F'\t' -v target="${target}" '$2 == target { print $7 }' "${session}/manifest.tsv")" \
    == "$(sha256sum "${target}" | awk '{print $1}')" ]]

  rm -rf "${workdir}"
}

run_nginx_original_restore_case() {
  local workdir=""
  local foreign=""
  local legacy_root=""
  local output=""
  local -a unconfirmed=()

  load_functions
  workdir="$(mktemp -d)"
  BACKUP_ROOT="${workdir}/backups"
  ORIGINALS_ROOT="${workdir}/originals"
  NGINX_MAIN_CONFIG="${workdir}/etc/nginx/nginx.conf"
  mkdir -p "$(dirname "${NGINX_MAIN_CONFIG}")"
  printf 'user 自己写的 nginx 主配置\n' > "${NGINX_MAIN_CONFIG}"
  foreign="$(cat "${NGINX_MAIN_CONFIG}")"

  # 接管时先留原件，再整体重写
  NGINX_MAIN_MANAGED="yes"
  write_nginx_main_config
  [[ -f "$(takeover_original_path "${NGINX_MAIN_CONFIG}")" ]]
  [[ "$(cat "$(takeover_original_path "${NGINX_MAIN_CONFIG}")")" == "${foreign}" ]]
  [[ "$(cat "${NGINX_MAIN_CONFIG}")" != "${foreign}" ]]

  # 卸载：有首次接管原件就还原它
  restore_nginx_main_config
  [[ "$(cat "${NGINX_MAIN_CONFIG}")" == "${foreign}" ]]

  # 接管前不存在：卸载应当删除我们创建的那份，而不是写默认模板
  NGINX_MAIN_CONFIG="${workdir}/etc/nginx-created/nginx.conf"
  ORIGINALS_ROOT="${workdir}/originals-created"
  NGINX_MAIN_MANAGED="yes"
  write_nginx_main_config
  [[ -f "${NGINX_MAIN_CONFIG}" ]]
  restore_nginx_main_config
  [[ ! -e "${NGINX_MAIN_CONFIG}" ]]

  # 没有接管标记：保留当前文件，一个字节都不动
  NGINX_MAIN_CONFIG="${workdir}/etc/nginx-foreign/nginx.conf"
  ORIGINALS_ROOT="${workdir}/originals-foreign"
  mkdir -p "$(dirname "${NGINX_MAIN_CONFIG}")"
  printf '另一个站点的 nginx 主配置\n' > "${NGINX_MAIN_CONFIG}"
  NGINX_MAIN_MANAGED="no"
  output="$(restore_nginx_main_config 2>&1)"
  [[ "${output}" == *'保留当前文件'* ]]
  [[ "$(cat "${NGINX_MAIN_CONFIG}")" == '另一个站点的 nginx 主配置' ]]

  # 旧安装没有首次接管原件，但旧备份目录里有：用最早的那一份
  legacy_root="${workdir}/backups-legacy"
  mkdir -p "${legacy_root}/20260101-000000/etc/nginx" "${legacy_root}/20260202-000000/etc/nginx"
  printf '最早的手工配置\n' > "${legacy_root}/20260101-000000/etc/nginx/nginx.conf"
  printf '后来的快照\n' > "${legacy_root}/20260202-000000/etc/nginx/nginx.conf"
  BACKUP_ROOT="${legacy_root}"
  ORIGINALS_ROOT="${workdir}/originals-legacy"
  NGINX_MAIN_CONFIG="${workdir}/etc/nginx-legacy/nginx.conf"
  mkdir -p "$(dirname "${NGINX_MAIN_CONFIG}")"
  printf '被 xtun 接管过的配置\n' > "${NGINX_MAIN_CONFIG}"
  NGINX_MAIN_MANAGED="yes"
  restore_nginx_main_config
  [[ "$(cat "${NGINX_MAIN_CONFIG}")" == '最早的手工配置' ]]

  # 旧备份里只有 xtun 自己生成的主配置：不能拿它冒充原件「还原成功」
  BACKUP_ROOT="${workdir}/backups-selfmade"
  mkdir -p "${BACKUP_ROOT}/20260101-000000/etc/nginx" "${BACKUP_ROOT}/20260202-000000/etc/nginx"
  printf '# Generated by xtun.sh —— 旧会话里我们自己的主配置\nuser www-data;\n' \
    > "${BACKUP_ROOT}/20260101-000000/etc/nginx/nginx.conf"
  printf '后来的一份普通快照\n' > "${BACKUP_ROOT}/20260202-000000/etc/nginx/nginx.conf"
  ORIGINALS_ROOT="${workdir}/originals-selfmade"
  NGINX_MAIN_CONFIG="${workdir}/etc/nginx-selfmade/nginx.conf"
  mkdir -p "$(dirname "${NGINX_MAIN_CONFIG}")"
  printf '现在的配置\n' > "${NGINX_MAIN_CONFIG}"
  NGINX_MAIN_MANAGED="yes"
  restore_nginx_main_config
  # 只有那份「后来的普通快照」可信（不是 xtun 写的），xtun 自己的那份要跳过
  [[ "$(cat "${NGINX_MAIN_CONFIG}")" == '后来的一份普通快照' ]]

  # 找不到任何可信原件：保留当前文件并登记为「未能确认」，绝不写发行版默认模板
  BACKUP_ROOT="${workdir}/backups-empty"
  ORIGINALS_ROOT="${workdir}/originals-empty"
  NGINX_MAIN_CONFIG="${workdir}/etc/nginx-unknown/nginx.conf"
  mkdir -p "$(dirname "${NGINX_MAIN_CONFIG}")"
  printf '无从考证的配置\n' > "${NGINX_MAIN_CONFIG}"
  NGINX_MAIN_MANAGED="yes"
  UNINSTALL_UNCONFIRMED=()
  # 不能放进 $( )：真实调用点没有子 shell，数组是在当前 shell 里累加的
  restore_nginx_main_config > "${workdir}/restore.out" 2>&1
  output="$(cat "${workdir}/restore.out")"
  [[ "${output}" == *'找不到'* ]]
  [[ "$(cat "${NGINX_MAIN_CONFIG}")" == '无从考证的配置' ]]
  [[ "${#UNINSTALL_UNCONFIRMED[@]}" -eq 1 ]]

  rm -rf "${workdir}"
}

run_uninstall_ownership_case() {
  local workdir=""
  local output=""
  local apt_log=""
  local foreign_nginx=""
  local foreign_cert=""
  local item=""
  local -a stopped=()
  local -a systemctl_calls=()

  load_functions
  workdir="$(mktemp -d)"
  apt_log="${workdir}/apt.log"

  BACKUP_ROOT="${workdir}/backups"
  ORIGINALS_ROOT="${workdir}/originals"
  SELF_COMMAND_PATH="${workdir}/usr/local/sbin/xtun"
  SELF_INSTALL_DIR="${workdir}/usr/local/lib/xtun"
  XRAY_BIN="${workdir}/usr/local/bin/xray"
  XRAY_CONFIG_DIR="${workdir}/usr/local/etc/xray"
  XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
  XRAY_ASSET_DIR="${workdir}/usr/local/share/xray"
  XRAY_SERVICE_FILE="${workdir}/etc/systemd/system/xray.service"
  XRAY_LOGROTATE_FILE="${workdir}/etc/logrotate.d/xtun"
  WARP_RULES_FILE="${XRAY_CONFIG_DIR}/warp-domains.list"
  STATE_FILE="${XRAY_CONFIG_DIR}/node-meta.env"
  HAPROXY_CONFIG="${workdir}/etc/haproxy/haproxy.cfg"
  NGINX_CONFIG_FILE="${workdir}/etc/nginx/conf.d/xtun.conf"
  NGINX_LIMITS_DROPIN_FILE="${workdir}/etc/systemd/system/nginx.service.d/xtun-limits.conf"
  NGINX_MAIN_CONFIG="${workdir}/etc/nginx/nginx.conf"
  FALLBACK_SITE_DIR="${workdir}/var/www/xtun-fallback"
  SSL_DIR="${workdir}/etc/ssl/xtun"
  NET_SYSCTL_CONF="${workdir}/etc/sysctl.d/98-xtun-net.conf"
  NET_HELPER_PATH="${workdir}/usr/local/sbin/xtun-net-optimize.sh"
  NET_SERVICE_FILE="${workdir}/etc/systemd/system/${NET_SERVICE_NAME}"
  ACME_HOME="${workdir}/root/.acme.sh"
  ACME_SH_BIN="${ACME_HOME}/acme.sh"
  ACME_RELOAD_HELPER="${workdir}/usr/local/sbin/xtun-cert-reload.sh"
  OUTPUT_FILE="${workdir}/root/xtun-output.md"
  QR_OUTPUT_DIR="${workdir}/root/xtun-qr"
  OP_LOG_DIR="${workdir}/var/log/xtun"
  OP_LOG_FILE="${OP_LOG_DIR}/operations.log"
  LEGACY_PATH_ROOT="${workdir}"
  INSTALL_DRAFT_FILE="${workdir}/root/.xtun-install-draft.env"
  SCRIPT_LOCK_FILE="${workdir}/run/xtun.lock"

  # 托管文件：卸载应当删掉
  mkdir -p "${XRAY_CONFIG_DIR}" "${XRAY_ASSET_DIR}" "${SSL_DIR}" "${QR_OUTPUT_DIR}" \
    "$(dirname "${XRAY_BIN}")" "$(dirname "${XRAY_SERVICE_FILE}")" \
    "$(dirname "${NGINX_CONFIG_FILE}")" "$(dirname "${OUTPUT_FILE}")"
  printf '{"xray":true}\n' > "${XRAY_CONFIG_FILE}"
  printf 'xray binary\n' > "${XRAY_BIN}"
  printf 'xtun 自己写的 unit\n' > "${XRAY_SERVICE_FILE}"
  printf 'managed nginx drop-in\n' > "${NGINX_CONFIG_FILE}"
  printf 'managed output\n' > "${OUTPUT_FILE}"
  printf 'png\n' > "${QR_OUTPUT_DIR}/node-1.png"

  # 外部资源：卸载必须原样保留
  printf '别人家的 nginx 主配置\n' > "${NGINX_MAIN_CONFIG}"
  foreign_nginx="$(sha256sum "${NGINX_MAIN_CONFIG}" | awk '{print $1}')"
  mkdir -p "${ACME_HOME}/other.example_ecc" "${ACME_HOME}/cdn.example.com_ecc"
  printf '#!/bin/sh\nexit 0\n' > "${ACME_SH_BIN}"
  chmod 0755 "${ACME_SH_BIN}"
  printf '别人的证书\n' > "${ACME_HOME}/other.example_ecc/cert.pem"
  printf '我们的证书\n' > "${ACME_HOME}/cdn.example.com_ecc/cert.pem"
  foreign_cert="$(sha256sum "${ACME_HOME}/other.example_ecc/cert.pem" | awk '{print $1}')"
  mkdir -p "${workdir}/var/lib/cloudflare-warp"
  printf 'client registration\n' > "${workdir}/var/lib/cloudflare-warp/mdm.xml"

  # 包归属：nginx 是我们装的，haproxy 用户原本就有
  SYSTEMD_UNIT_DIRS=("${workdir}/etc/systemd/system")
  mkdir -p "${SYSTEMD_UNIT_DIRS[0]}" "$(dirname "${HAPROXY_CONFIG}")" "$(dirname "$(takeover_original_path "${HAPROXY_CONFIG}")")"
  printf '[Unit]\nDescription=shared haproxy\n' > "${SYSTEMD_UNIT_DIRS[0]}/haproxy.service"
  printf 'foreign-haproxy-config\n' > "$(takeover_original_path "${HAPROXY_CONFIG}")"
  printf 'managed-haproxy-config\n' > "${HAPROXY_CONFIG}"
  mkdir -p "${ORIGINALS_ROOT}"
  {
    printf '# xtun-takeover-manifest\tv1\n'
    printf 'nginx\t0\t2026-09-13T00:00:00Z\n'
    printf 'haproxy\t1\t2026-09-13T00:00:00Z\n'
    printf '%s\t1\t2026-09-13T00:00:00Z\n' "${HAPROXY_CONFIG}"
  } > "${ORIGINALS_ROOT}/manifest.tsv"

  need_root() { :; }
  load_existing_state() {
    CERT_MODE="acme-dns-cf"
    XHTTP_DOMAIN="cdn.example.com"
    NGINX_MAIN_MANAGED="no"
    ENABLE_NET_OPT="no"
  }
  stop_and_disable_service_if_present() { stopped+=("${1}"); }
  systemctl() {
    systemctl_calls+=("$*")
    case "$*" in
      'show '*' -p ActiveState --value') printf 'active\n' ;;
      *) return 0 ;;
    esac
  }
  sysctl() { :; }
  apt-get() { printf '%s\n' "$*" >> "${apt_log}"; }

  # 不能放进 $( )：真实调用点没有子 shell，报告和服务桩都在当前 shell 里累加
  uninstall_cmd --yes --purge > "${workdir}/uninstall.out" 2>&1
  output="$(cat "${workdir}/uninstall.out")"

  # 外部资源一个都不能动
  [[ "$(sha256sum "${NGINX_MAIN_CONFIG}" | awk '{print $1}')" == "${foreign_nginx}" ]]
  [[ -f "${ACME_HOME}/other.example_ecc/cert.pem" ]]
  [[ "$(sha256sum "${ACME_HOME}/other.example_ecc/cert.pem" | awk '{print $1}')" == "${foreign_cert}" ]]
  [[ -f "${ACME_SH_BIN}" ]]
  [[ -f "${workdir}/var/lib/cloudflare-warp/mdm.xml" ]]

  # 托管文件与我们的证书目录被删掉
  [[ ! -e "${XRAY_CONFIG_FILE}" ]]
  [[ ! -e "${XRAY_SERVICE_FILE}" ]]
  [[ ! -e "${XRAY_BIN}" ]]
  [[ ! -e "${NGINX_CONFIG_FILE}" ]]
  [[ ! -e "${ACME_HOME}/cdn.example.com_ecc" ]]
  [[ ! -e "${OUTPUT_FILE}" ]]

  # 报告要说清删了什么、留下什么
  [[ "${output}" == *'已删除：'* ]]
  [[ "${output}" == *'已保留：'* ]]
  [[ "${output}" == *"${ACME_HOME}"* ]]

  # 服务边界：haproxy 是用户原本就装的，不能被停；xray 是我们装的，必须停
  for item in "${stopped[@]}"; do
    if [[ "${item}" == "haproxy.service" ]]; then
      printf '[fail] haproxy.service 不能因为卸载 xtun 被停掉\n' >&2
      return 1
    fi
  done
  [[ " ${stopped[*]} " == *' xray.service '* ]]

  # 保留的服务要 reload 一次，让它把我们的配置放下
  [[ " ${systemctl_calls[*]} " == *' reload haproxy.service '* ]]
  [[ "$(cat "${HAPROXY_CONFIG}")" == 'foreign-haproxy-config' ]]

  # --purge 只卸我们自己装进来的包：nginx 进列表，用户原有的 haproxy 不进
  if grep -q 'haproxy' "${apt_log}"; then
    printf '[fail] haproxy 是用户原本就装的，不该被 purge\n' >&2
    return 1
  fi
  if ! grep -q 'purge -y nginx' "${apt_log}"; then
    printf '[fail] nginx 是我们装的，应当进入 purge 列表\n' >&2
    return 1
  fi

  rm -rf "${workdir}"
}

# 复核 H31/H32：安装前宿主已有自己的 xray.service 与 /usr/local/bin/xray 时，
# 卸载必须还原这两条路径（含启用/运行状态），而不是删掉用户的东西。
run_uninstall_takeover_restore_case() {
  local workdir=""
  local output=""
  local status=0
  local service_digest=""
  local binary_digest=""

  load_functions
  workdir="$(mktemp -d)"

  BACKUP_ROOT="${workdir}/backups"
  ORIGINALS_ROOT="${workdir}/originals"
  SELF_COMMAND_PATH="${workdir}/usr/local/sbin/xtun"
  SELF_INSTALL_DIR="${workdir}/usr/local/lib/xtun"
  XRAY_BIN="${workdir}/usr/local/bin/xray"
  XRAY_CONFIG_DIR="${workdir}/usr/local/etc/xray"
  XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
  XRAY_ASSET_DIR="${workdir}/usr/local/share/xray"
  XRAY_SERVICE_FILE="${workdir}/etc/systemd/system/xray.service"
  XRAY_LOGROTATE_FILE="${workdir}/etc/logrotate.d/xtun"
  WARP_RULES_FILE="${XRAY_CONFIG_DIR}/warp-domains.list"
  STATE_FILE="${XRAY_CONFIG_DIR}/node-meta.env"
  HAPROXY_CONFIG="${workdir}/etc/haproxy/haproxy.cfg"
  NGINX_CONFIG_FILE="${workdir}/etc/nginx/conf.d/xtun.conf"
  NGINX_LIMITS_DROPIN_FILE="${workdir}/etc/systemd/system/nginx.service.d/xtun-limits.conf"
  NGINX_MAIN_CONFIG="${workdir}/etc/nginx/nginx.conf"
  FALLBACK_SITE_DIR="${workdir}/var/www/xtun-fallback"
  SSL_DIR="${workdir}/etc/ssl/xtun"
  NET_SYSCTL_CONF="${workdir}/etc/sysctl.d/98-xtun-net.conf"
  NET_HELPER_PATH="${workdir}/usr/local/sbin/xtun-net-optimize.sh"
  NET_SERVICE_FILE="${workdir}/etc/systemd/system/${NET_SERVICE_NAME}"
  ACME_HOME="${workdir}/root/.acme.sh"
  ACME_SH_BIN="${ACME_HOME}/acme.sh"
  ACME_RELOAD_HELPER="${workdir}/usr/local/sbin/xtun-cert-reload.sh"
  OUTPUT_FILE="${workdir}/root/xtun-output.md"
  QR_OUTPUT_DIR="${workdir}/root/xtun-qr"
  OP_LOG_DIR="${workdir}/var/log/xtun"
  OP_LOG_FILE="${OP_LOG_DIR}/operations.log"
  LEGACY_PATH_ROOT="${workdir}"
  INSTALL_DRAFT_FILE="${workdir}/root/.xtun-install-draft.env"
  SCRIPT_LOCK_FILE="${workdir}/run/xtun.lock"

  XRAY_LOG_DIR="${workdir}/var/log/xray"
  XRAY_STATE_DIR="${workdir}/var/lib/xray"

  # 宿主的原件与 xtun 接管后的当前文件
  mkdir -p "$(dirname "$(takeover_original_path "${XRAY_SERVICE_FILE}")")" \
    "$(dirname "$(takeover_original_path "${XRAY_BIN}")")" \
    "$(dirname "${XRAY_SERVICE_FILE}")" "$(dirname "${XRAY_BIN}")" \
    "${ORIGINALS_ROOT}/service-state" "${XRAY_CONFIG_DIR}" "${XRAY_ASSET_DIR}"
  printf 'foreign-xray-unit\n' > "$(takeover_original_path "${XRAY_SERVICE_FILE}")"
  printf 'foreign-xray-core\n' > "$(takeover_original_path "${XRAY_BIN}")"
  mkdir -p "$(takeover_original_path "${XRAY_LOG_DIR}")" "$(takeover_original_path "${XRAY_STATE_DIR}")"
  printf 'foreign-log\n' > "$(takeover_original_path "${XRAY_LOG_DIR}")/error.log"
  printf 'foreign-state\n' > "$(takeover_original_path "${XRAY_STATE_DIR}")/state.db"
  printf 'xtun-xray-unit\n' > "${XRAY_SERVICE_FILE}"
  printf 'xtun-xray-core\n' > "${XRAY_BIN}"
  mkdir -p "${XRAY_LOG_DIR}" "${XRAY_STATE_DIR}"
  printf 'xtun-log\n' > "${XRAY_LOG_DIR}/error.log"
  printf 'xtun-state\n' > "${XRAY_STATE_DIR}/state.db"
  printf '{"xray":true}\n' > "${XRAY_CONFIG_FILE}"

  service_digest="$(backup_file_digest "$(takeover_original_path "${XRAY_SERVICE_FILE}")")"
  binary_digest="$(backup_file_digest "$(takeover_original_path "${XRAY_BIN}")")"
  log_digest="$(backup_file_digest "$(takeover_original_path "${XRAY_LOG_DIR}")")"
  state_digest="$(backup_file_digest "$(takeover_original_path "${XRAY_STATE_DIR}")")"
  {
    printf '# xtun-takeover-manifest\tv2\n'
    # nginx/haproxy 记为 xtun 自己装的（existed=0），避免走进共享 HAProxy 分支
    printf 'haproxy\t0\t2026-09-19T00:00:00Z\t-\n'
    printf 'nginx\t0\t2026-09-19T00:00:00Z\t-\n'
    printf '%s\t1\t2026-09-19T00:00:00Z\t%s\n' "${XRAY_SERVICE_FILE}" "${service_digest}"
    printf '%s\t1\t2026-09-19T00:00:00Z\t%s\n' "${XRAY_BIN}" "${binary_digest}"
    printf '%s\t1\t2026-09-19T00:00:00Z\t%s\n' "${XRAY_LOG_DIR}" "${log_digest}"
    printf '%s\t1\t2026-09-19T00:00:00Z\t%s\n' "${XRAY_STATE_DIR}" "${state_digest}"
  } > "${ORIGINALS_ROOT}/manifest.tsv"
  # 接管前 xray.service 是启用且运行中的
  printf 'ENABLED=enabled\nACTIVE=active\n' > "${ORIGINALS_ROOT}/service-state/xray.service.state"

  SYSTEMD_UNIT_DIRS=("${workdir}/etc/systemd/system")

  need_root() { :; }
  load_existing_state() {
    CERT_MODE="self-signed"
    XHTTP_DOMAIN=""
    NGINX_MAIN_MANAGED="no"
    ENABLE_NET_OPT="no"
  }
  stop_and_disable_service_if_present() { :; }
  systemctl() {
    case "$*" in
      'enable xray.service'*) printf 'enable\n' >> "${workdir}/systemctl.log" ;;
      'start xray.service'*) printf 'start\n' >> "${workdir}/systemctl.log" ;;
      'show '*' -p ActiveState --value') printf 'active\n' ;;
    esac
    return 0
  }
  sysctl() { :; }
  apt-get() { :; }

  status=0
  uninstall_cmd --yes > "${workdir}/uninstall.out" 2>&1 || status=$?
  output="$(cat "${workdir}/uninstall.out")"

  [[ "${status}" -eq 0 ]]
  # 文件还原成宿主原来的内容，而不是被删掉
  [[ "$(cat "${XRAY_SERVICE_FILE}")" == 'foreign-xray-unit' ]]
  [[ "$(cat "${XRAY_BIN}")" == 'foreign-xray-core' ]]
  # 宿主服务依赖的日志/状态目录也还原，而不是被删掉
  [[ "$(cat "${XRAY_LOG_DIR}/error.log")" == 'foreign-log' ]]
  [[ "$(cat "${XRAY_STATE_DIR}/state.db")" == 'foreign-state' ]]
  [[ ! -e "${XRAY_LOG_DIR}/xtun-log" ]]
  # 启用/运行状态按接管前记录恢复
  grep -q '^enable$' "${workdir}/systemctl.log"
  grep -q '^start$' "${workdir}/systemctl.log"
  # 报告要说明这两条是还原的
  [[ "${output}" == *"已还原安装前的 xray.service"* ]]
  [[ "${output}" == *"已还原安装前的核心二进制"* ]]

  rm -rf "${workdir}"
  load_functions
}

# 复核 H31/H32 的另一半：安装时就要把宿主原有的 xray.service / xray 核心登记成
# 「接管前已存在」，并记住 service 当时的启用/运行状态；否则卸载无从还原。
run_xray_takeover_record_case() {
  local workdir=""

  load_functions
  workdir="$(mktemp -d)"

  BACKUP_ROOT="${workdir}/backups"
  ORIGINALS_ROOT="${workdir}/originals"
  XRAY_BIN="${workdir}/usr/local/bin/xray"
  XRAY_SERVICE_FILE="${workdir}/etc/systemd/system/xray.service"
  XRAY_LOG_DIR="${workdir}/var/log/xray"
  XRAY_STATE_DIR="${workdir}/var/lib/xray"
  SYSTEMD_UNIT_DIRS=("${workdir}/etc/systemd/system")

  mkdir -p "$(dirname "${XRAY_BIN}")" "${SYSTEMD_UNIT_DIRS[0]}" "${XRAY_LOG_DIR}" "${XRAY_STATE_DIR}"
  printf 'foreign-xray-unit\n' > "${XRAY_SERVICE_FILE}"
  printf 'foreign-xray-core\n' > "${XRAY_BIN}"
  printf 'foreign-log\n' > "${XRAY_LOG_DIR}/error.log"
  printf 'foreign-state\n' > "${XRAY_STATE_DIR}/state.db"

  systemctl() {
    case "$*" in
      'show xray.service -p UnitFileState --value') printf 'enabled\n' ;;
      'show xray.service -p ActiveState --value') printf 'active\n' ;;
    esac
    return 0
  }
  backup_path() { :; }
  install_packages() { :; }
  install_self_command() { :; }
  install_xray() { printf 'xtun-new-core\n' > "${XRAY_BIN}"; }
  ensure_xray_bind_capability() { :; }
  ensure_xray_user() { :; }
  generate_reality_keys_if_needed() { :; }

  install_xray_runtime
  write_xray_service

  # 两条路径都登记为「接管前已存在」，原件保存的是宿主原来的内容
  [[ "$(takeover_original_existed "${XRAY_SERVICE_FILE}")" == 1 ]]
  [[ "$(takeover_original_existed "${XRAY_BIN}")" == 1 ]]
  [[ "$(takeover_original_existed "${XRAY_LOG_DIR}")" == 1 ]]
  [[ "$(takeover_original_existed "${XRAY_STATE_DIR}")" == 1 ]]
  [[ "$(cat "$(takeover_original_path "${XRAY_SERVICE_FILE}")")" == 'foreign-xray-unit' ]]
  [[ "$(cat "$(takeover_original_path "${XRAY_BIN}")")" == 'foreign-xray-core' ]]
  [[ "$(cat "$(takeover_original_path "${XRAY_LOG_DIR}")/error.log")" == 'foreign-log' ]]
  [[ "$(cat "$(takeover_original_path "${XRAY_STATE_DIR}")/state.db")" == 'foreign-state' ]]
  # 接管前的启用/运行状态被记下来
  grep -q '^ENABLED=enabled$' "${ORIGINALS_ROOT}/service-state/xray.service.state"
  grep -q '^ACTIVE=active$' "${ORIGINALS_ROOT}/service-state/xray.service.state"
  # 当前文件确实是 xtun 写的新内容
  grep -q 'Description=Xray Service' "${XRAY_SERVICE_FILE}"
  [[ "$(cat "${XRAY_BIN}")" == 'xtun-new-core' ]]

  rm -rf "${workdir}"
  load_functions
}
