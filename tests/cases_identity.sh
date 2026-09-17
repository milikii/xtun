# shellcheck shell=bash
# shellcheck disable=SC2034

run_bundle_required_files_case() {
  local workdir="" file=""
  load_functions
  workdir="$(mktemp -d)"
  cp -a "${ROOT_DIR}/xtun.sh" "${ROOT_DIR}/lib" "${ROOT_DIR}/static" "${workdir}/"
  bundle_root_ready "${workdir}"
  while IFS= read -r file; do
    mv "${workdir}/${file}" "${workdir}/saved-file"
    if bundle_root_ready "${workdir}"; then return 1; fi
    mv "${workdir}/saved-file" "${workdir}/${file}"
  done < <(cd "${ROOT_DIR}" && find lib static -type f | sort)
  rm -rf "${workdir}"
}

run_bootstrap_metadata_errors_case() {
  local mock_api_body="" mock_http_code="" output="" mock_api_exit=0
  load_functions
  BOOTSTRAP_ARCHIVE_URL=""
  BOOTSTRAP_BRANCH_REF=main
  curl() { printf '%s\n%s' "${mock_api_body}" "${mock_http_code}"; return "${mock_api_exit}"; }
  for mock_http_code in 403 429 404 500 200; do
    mock_api_body='{}'
    if output="$(bootstrap_resolve_archive_url 2>&1)"; then return 1; fi
    [[ "${output}" != *'https://codeload.github.com/'* ]]
  done
  mock_http_code=403
  BOOTSTRAP_BRANCH_REF=v1.1.0
  if output="$(bootstrap_resolve_archive_url 2>&1)"; then return 1; fi
  [[ "${output}" == *API*限流* ]]
  mock_api_exit=7
  if output="$(bootstrap_resolve_archive_url 2>&1)"; then return 1; fi
  [[ "${output}" == *网络请求失败* ]]
}

run_bootstrap_fixed_entry_case() {
  local workdir="" archive="" commit="0123456789abcdef0123456789abcdef01234567"
  local downloaded="" entry_source=""
  load_functions
  workdir="$(mktemp -d)"
  mkdir -p "${workdir}/xtun-${commit}" "${workdir}/download"
  cp -a "${ROOT_DIR}/xtun.sh" "${ROOT_DIR}/lib" "${ROOT_DIR}/static" "${workdir}/xtun-${commit}/"
  archive="${workdir}/candidate.tar.gz"
  tar -czf "${archive}" -C "${workdir}" "xtun-${commit}"
  BOOTSTRAP_ARCHIVE_URL=""
  BOOTSTRAP_BRANCH_REF="${commit}"
  entry_source="${ROOT_DIR}/xtun.sh"
  curl() {
    if [[ "$*" == *raw.githubusercontent.com* ]]; then cp "${entry_source}" "${!#}";
    else cp "${archive}" "${!#}"; fi
  }
  downloaded="$(bootstrap_download_bundle "${workdir}/download")"
  bundle_root_ready "${downloaded}"
  [[ "$(awk -F'\t' '$1=="commit" {print $2}' "${downloaded}/.xtun-source.tsv")" == "${commit}" ]]
  printf '# different entry\n' > "${workdir}/other-entry"
  entry_source="${workdir}/other-entry"
  if bootstrap_download_bundle "${workdir}/download" >/dev/null 2>&1; then return 1; fi
  rm -rf "${workdir}"
}

run_bootstrap_write_no_fallback_case() {
  local workdir="" output=""
  load_functions
  workdir="$(mktemp -d)"
  mkdir "${workdir}/installed"
  cp "${ROOT_DIR}/xtun.sh" "${workdir}/xtun.sh"
  cp -a "${ROOT_DIR}/xtun.sh" "${ROOT_DIR}/lib" "${ROOT_DIR}/static" "${workdir}/installed/"
  # 已安装脚本保留所有模块，但派发只留痕；不触碰真实服务或路径。
  sed -i '$d' "${workdir}/installed/xtun.sh"
  printf '\nprintf "executed:%%s\\n" "${1}" > "${ENTRY_MARKER}"\n' >> "${workdir}/installed/xtun.sh"
  if output="$(env ROOT_DIR= XTUN_BOOTSTRAP_ARCHIVE_URL="file://${workdir}/missing.tar.gz" \
    XTUN_SELF_INSTALL_DIR="${workdir}/installed" ENTRY_MARKER="${workdir}/executed" \
    bash "${workdir}/xtun.sh" upgrade --non-interactive 2>&1)"; then return 1; fi
  [[ ! -e "${workdir}/executed" && "${output}" == *未执行本次写动作* ]]
  output="$(env ROOT_DIR= XTUN_BOOTSTRAP_ARCHIVE_URL="file://${workdir}/missing.tar.gz" \
    XTUN_SELF_INSTALL_DIR="${workdir}/installed" ENTRY_MARKER="${workdir}/executed" \
    bash "${workdir}/xtun.sh" status 2>&1)"
  [[ "${output}" == *本次只读使用已安装* && "$(cat "${workdir}/executed")" == executed:status ]]
  rm -rf "${workdir}"
}

run_xray_api_failure_categories_case() {
  local mock_api_body="" mock_api_exit=0 mock_http_code="" output=""
  load_functions
  curl() { printf '%s\n%s' "${mock_api_body}" "${mock_http_code}"; return "${mock_api_exit}"; }
  for mock_http_code in 403 429; do
    if output="$(xray_prepare_release_context v26.9.9 64 2>&1)"; then return 1; fi
    [[ "${output}" == *API*限流*显式*tag* ]]
  done
  mock_http_code=404
  if output="$(xray_prepare_release_context v26.9.9 64 2>&1)"; then return 1; fi
  [[ "${output}" == *不存在* ]]
  mock_api_exit=7
  if output="$(xray_prepare_release_context latest-published 64 2>&1)"; then return 1; fi
  [[ "${output}" == *网络请求失败* ]]
}

# 包内假核心有严格的命令行为；下载、解包、文件替换、capability 与持久恢复均使用真实实现。
identity_core_fixture() {
  local workdir="${1}"
  generation_case_setup "${workdir}"
  XRAY_BIN="${workdir}/installed/xray"
  XRAY_ASSET_DIR="${workdir}/assets"
  IDENTITY_ARCHIVE="${workdir}/Xray-linux-64.zip"
  mkdir -p "${workdir}/candidate" "$(dirname "${XRAY_BIN}")" "${XRAY_ASSET_DIR}"
  cat > "${workdir}/candidate/xray" <<'SCRIPT'
#!/usr/bin/env bash
case "${1}" in
  version) printf 'Xray 26.10.1 (Xray, Penetrates Everything.) 2222222 (go1.27 linux/amd64)\n' ;;
  x25519) printf 'PrivateKey: private\nPassword (PublicKey): public\nHash32: hash\n' ;;
  vlessenc) printf 'Authentication: X25519\n"decryption": "mlkem768x25519plus.native.600s.test-decryption"\n"encryption": "mlkem768x25519plus.native.0rtt.test-encryption"\n' ;;
  run) ! grep -q 'this-is-not-json' "${4}" ;;
  *) exit 1 ;;
esac
SCRIPT
  chmod 0755 "${workdir}/candidate/xray"
  printf 'candidate-geoip' > "${workdir}/candidate/geoip.dat"
  printf 'candidate-geosite' > "${workdir}/candidate/geosite.dat"
  python3 - "${workdir}/candidate" "${IDENTITY_ARCHIVE}" <<'PY'
from pathlib import Path
import zipfile,sys
with zipfile.ZipFile(sys.argv[2], 'w') as z:
    for f in Path(sys.argv[1]).iterdir(): z.write(f, f.name)
PY
  xray_prepare_release_context() {
    xray_reset_release_context
    XRAY_SELECTED_TAG=v26.10.1
    XRAY_SELECTED_COMMIT=2222222222222222222222222222222222222222
    XRAY_SELECTED_ARCHIVE_NAME=Xray-linux-64.zip
    XRAY_SELECTED_ARCHIVE_URL="file://${IDENTITY_ARCHIVE}"
    XRAY_SELECTED_EXPECTED_SHA256="$(identity_file_sha256 "${IDENTITY_ARCHIVE}")"
    XRAY_SELECTED_CHECKSUM_SOURCE=test-fixture
    XRAY_CONTEXT_REQUEST="${1}"
    XRAY_CONTEXT_ARCH="${2}"
  }
  detect_xray_arch() { printf 64; }
  validate_configs() { :; }
  XRAY_VERSION_REQUEST=latest-published
  install_xray
  xray_installed_identity_valid
  GENERATION_TEST_INSTALLED['xray.service']=yes
  GENERATION_TEST_ACTIVE['xray.service']=active
  GENERATION_TEST_ENABLED['xray.service']=enabled
  SYSTEMCTL_CALLS=""
}

run_xray_identity_noop_case() {
  local workdir="" before=""
  load_functions
  workdir="$(mktemp -d)"
  identity_core_fixture "${workdir}"
  before="$(backup_file_digest "${XRAY_ASSET_DIR}")"
  run_cli_command upgrade --non-interactive
  [[ ! -d "${BACKUP_ROOT}" && ! -e "${PENDING_OP_FILE}" && "${SYSTEMCTL_CALLS}" != *restart* ]]
  [[ "$(backup_file_digest "${XRAY_ASSET_DIR}")" == "${before}" ]]
  [[ "${LOGGED}" == *可信安装身份一致* ]]
  rm -rf "${workdir}"
}

run_xray_identity_unknown_case() {
  local workdir="" before="" status=0
  load_functions
  workdir="$(mktemp -d)"
  identity_core_fixture "${workdir}"
  rm "$(xray_identity_file)"
  before="$(backup_file_digest "${XRAY_ASSET_DIR}")"
  run_cli_command upgrade --non-interactive || status=$?
  [[ "${status}" -eq 1 && ! -d "${BACKUP_ROOT}" && ! -e "${PENDING_OP_FILE}" ]]
  [[ "${LOGGED}" == *--reinstall* && "${SYSTEMCTL_CALLS}" != *restart* ]]
  [[ "$(backup_file_digest "${XRAY_ASSET_DIR}")" == "${before}" ]]
  run_cli_command upgrade --reinstall --non-interactive
  xray_installed_identity_valid
  [[ "${SYSTEMCTL_CALLS}" == *restart* && ! -e "${PENDING_OP_FILE}" ]]
  rm -rf "${workdir}"
}

run_xray_identity_drift_case() {
  local workdir="" kind="" status=0
  for kind in binary geoip geosite mode capability; do
    (
      load_functions
      workdir="$(mktemp -d)"
      identity_core_fixture "${workdir}"
      case "${kind}" in
        binary) printf '\n# local change\n' >> "${XRAY_BIN}" ;;
        geoip|geosite) printf 'changed' > "${XRAY_ASSET_DIR}/${kind}.dat" ;;
        mode) chmod 0700 "${XRAY_BIN}" ;;
        capability) setcap -r "${XRAY_BIN}" ;;
      esac
      if xray_installed_identity_valid; then return 1; fi
      run_cli_command upgrade --non-interactive || status=$?
      [[ "${status}" -eq 1 && ! -d "${BACKUP_ROOT}" && "${SYSTEMCTL_CALLS}" != *restart* ]]
      rm -rf "${workdir}"
    )
  done
}

run_xray_reinstall_recovery_case() {
  local workdir="" phase="" before_core="" before_assets="" before_cap="" status=0
  for phase in download unzip geo setcap identity config restart; do
    (
      load_functions
      workdir="$(mktemp -d)"
      identity_core_fixture "${workdir}"
      before_core="$(backup_file_digest "${XRAY_BIN}")"
      before_assets="$(backup_file_digest "${XRAY_ASSET_DIR}")"
      before_cap="$(xray_binary_capabilities)"
      case "${phase}" in
        download) curl() { return 22; } ;;
        unzip) unzip() { return 1; } ;;
        geo) install() { [[ "${!#}" != "${XRAY_ASSET_DIR}/geosite.dat" ]] || return 1; command install "$@"; } ;;
        setcap) setcap() { return 1; } ;;
        identity)
          eval "$(declare -f durable_replace_file | sed '1s/durable_replace_file/identity_real_replace/')"
          durable_replace_file() { [[ "${2}" != "$(xray_identity_file)" ]] || return 1; identity_real_replace "$@"; }
          ;;
        config) validate_configs() { return 1; } ;;
        restart)
          eval "$(declare -f restart_service_verified | sed '1s/restart_service_verified/identity_real_restart/')"
          restart_service_verified() {
            if [[ ! -e "${workdir}/restart-failed" ]]; then touch "${workdir}/restart-failed"; return 1; fi
            identity_real_restart "$@"
          }
          ;;
      esac
      run_cli_command upgrade --reinstall --non-interactive || status=$?
      [[ "${status}" -eq 1 && "${GENERATION_RECOVERY_RESULT}" == restored-verified && ! -e "${PENDING_OP_FILE}" ]]
      [[ "$(backup_file_digest "${XRAY_BIN}")" == "${before_core}" ]]
      [[ "$(backup_file_digest "${XRAY_ASSET_DIR}")" == "${before_assets}" ]]
      [[ "$(xray_binary_capabilities)" == "${before_cap}" ]]
      [[ "${GENERATION_TEST_ACTIVE[xray.service]}" == active && "${GENERATION_TEST_ENABLED[xray.service]}" == enabled ]]
      rm -rf "${workdir}"
    )
  done
}

run_xray_candidate_geo_required_case() {
  local workdir="" before="" status=0
  load_functions
  workdir="$(mktemp -d)"
  identity_core_fixture "${workdir}"
  before="$(backup_file_digest "${XRAY_ASSET_DIR}")"
  python3 - "${workdir}/candidate/xray" "${IDENTITY_ARCHIVE}" <<'PY'
import zipfile,sys
with zipfile.ZipFile(sys.argv[2], 'w') as z: z.write(sys.argv[1], 'xray')
PY
  xray_release_version_context
  install_xray || status=$?
  [[ "${status}" -eq 1 && "$(backup_file_digest "${XRAY_ASSET_DIR}")" == "${before}" ]]
  rm -rf "${workdir}"
}
