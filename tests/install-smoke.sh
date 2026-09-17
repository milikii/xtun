#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_TMP_DIR=""
SMOKE_LOG_FILE=""
SMOKE_CONTAINER_MODE=0

report_smoke_failure() {
  local status="${1}" line="${2}" command_text="${3}"
  local message="tests/install-smoke.sh:${line}: ${command_text} (exit ${status})"

  if [[ -n "${SMOKE_LOG_FILE}" && -s "${SMOKE_LOG_FILE}" ]]; then
    message+=$'\n'"$(tail -n 30 "${SMOKE_LOG_FILE}")"
  fi
  if [[ "${SMOKE_CONTAINER_MODE}" -eq 1 ]]; then
    message+=$'\n'"$(journalctl --no-pager -u xray.service -u nginx.service -u haproxy.service -n 20 2>&1 || true)"
  fi
  printf '[fail] %s\n' "${message}" >&2
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    message="${message//\%/%25}"
    message="${message//$'\r'/%0D}"
    message="${message//$'\n'/%0A}"
    printf '::error title=Install smoke failure::%s\n' "${message}"
  fi
  exit "${status}"
}
trap 'report_smoke_failure "$?" "${LINENO}" "${BASH_COMMAND}"' ERR

usage() {
  printf '用法：tests/install-smoke.sh install-core|check-latest|container\n'
}

load_xray_version_module() {
  # shellcheck source=/dev/null
  . "${SCRIPT_ROOT}/lib/base/helpers.sh"
  # shellcheck source=/dev/null
  . "${SCRIPT_ROOT}/lib/base/versions.sh"
}

install_core() {
  local request="${XRAY_VERSION:?XRAY_VERSION is required}"
  local version_output=""
  local binary_path=""
  local arch=""

  load_xray_version_module
  SMOKE_TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${SMOKE_TMP_DIR:-}"' EXIT
  arch="$(detect_xray_arch)" || return 1

  xray_prepare_release_context "${request}" "${arch}"
  xray_download_release "${SMOKE_TMP_DIR}"
  unzip -qo "${SMOKE_TMP_DIR}/${XRAY_SELECTED_ARCHIVE_NAME}" -d "${SMOKE_TMP_DIR}/xray"
  binary_path="${SMOKE_TMP_DIR}/xray/xray"
  xray_validate_candidate_commands "${binary_path}" "${XRAY_SELECTED_TAG}"

  sudo install -m 0755 "${binary_path}" /usr/local/bin/xray
  # run -test 会加载路由中的 geoip/geosite；与核心一起使用同一校验归档的资源。
  sudo install -d -m 0755 /usr/local/share/xray
  sudo install -m 0644 "${SMOKE_TMP_DIR}/xray/geoip.dat" "${SMOKE_TMP_DIR}/xray/geosite.dat" /usr/local/share/xray/
  version_output="$(/usr/local/bin/xray version)"
  printf '%s\n' "${version_output}"
  printf 'tag=%s\ncommit=%s\narchive=%s\nsha256=%s\n' \
    "${XRAY_SELECTED_TAG}" \
    "${XRAY_SELECTED_COMMIT}" \
    "${XRAY_SELECTED_ARCHIVE_NAME}" \
    "${XRAY_SELECTED_EXPECTED_SHA256}"

  [[ "${version_output}" == "Xray ${XRAY_SELECTED_TAG#v} "* ]]
}

check_latest() {
  local arch=""

  load_xray_version_module
  SMOKE_TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${SMOKE_TMP_DIR:-}"' EXIT
  arch="$(detect_xray_arch)" || return 1

  xray_prepare_release_context "latest-published" "${arch}"
  xray_download_release "${SMOKE_TMP_DIR}"
  unzip -qo "${SMOKE_TMP_DIR}/${XRAY_SELECTED_ARCHIVE_NAME}" -d "${SMOKE_TMP_DIR}/xray"
  xray_validate_candidate_commands "${SMOKE_TMP_DIR}/xray/xray" "${XRAY_SELECTED_TAG}"

  printf 'tag=%s\nprerelease=%s\ncommit=%s\narchive=%s\nsha256=%s\n' \
    "${XRAY_SELECTED_TAG}" \
    "${XRAY_SELECTED_PRERELEASE}" \
    "${XRAY_SELECTED_COMMIT}" \
    "${XRAY_SELECTED_ARCHIVE_NAME}" \
    "${XRAY_SELECTED_EXPECTED_SHA256}"

  # Use this same resolved archive for semantics and real native transfers.
  # Do not install it over any host binary while checking latest.
  local -a runner=()
  if [[ "${EUID}" -ne 0 ]]; then runner=(sudo); fi
  "${runner[@]}" env TEST_HOST_XRAY_BIN="${SMOKE_TMP_DIR}/xray/xray" \
    TEST_HOST_XRAY_ASSET_DIR="${SMOKE_TMP_DIR}/xray" GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" \
    bash "${SCRIPT_ROOT}/tests/smoke.sh"
  "${runner[@]}" python3 "${SCRIPT_ROOT}/tests/native-transport.py" \
    --core "${SMOKE_TMP_DIR}/xray/xray" --assets "${SMOKE_TMP_DIR}/xray"
}

container_install() {
  local source_dir="${SCRIPT_ROOT}"
  local workdir="/root/xtun"
  local png_count=0
  local png_header=""
  local png_file=""
  local show_links_output=""
  local output_file="/root/xtun-output.md"
  local nginx_config="/etc/nginx/conf.d/xtun.conf"

  SMOKE_CONTAINER_MODE=1
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl openssl jq ca-certificates procps >/dev/null
  cp -a "${source_dir}" "${workdir}"
  cd "${workdir}"
  SMOKE_LOG_FILE="${workdir}/install-smoke.log"
  install -m 0600 /dev/null "${SMOKE_LOG_FILE}"

  bash xtun.sh install --non-interactive \
    --server-ip 127.0.0.1 \
    --reality-sni www.stanford.edu \
    --xhttp-domain cdn.example.test \
    --cert-mode self-signed \
    --disable-warp \
    --disable-net-opt \
    --no-manage-nginx-main \
    --skip-sni-check \
    --xray-version "${XRAY_VERSION:?XRAY_VERSION is required}" 2>&1 | tee "${SMOKE_LOG_FILE}"

  bash xtun.sh diagnose 2>&1 | tee -a "${SMOKE_LOG_FILE}"

  while IFS= read -r -d '' png_file; do
    png_count=$((png_count + 1))
    png_header="$(od -An -tx1 -N8 "${png_file}")"
    [[ "${png_header}" == *"89 50 4e 47 0d 0a 1a 0a"* ]]
  done < <(find /root/xtun-qr -maxdepth 1 -type f -name '*.png' -print0)
  [[ "${png_count}" -eq 5 ]]

  [[ ! -e /var/www/xtun-sub ]]
  if grep -q '/sub/' "${nginx_config}"; then
    printf 'nginx 配置不应包含 /sub/：\n' >&2
    exit 1
  fi

  show_links_output="$(xtun show-links --qr)"
  printf '%s\n' "${show_links_output}"
  [[ "$(grep -c '^节点 [1-5]: ' <<< "${show_links_output}")" -eq "${png_count}" ]]
  while IFS= read -r -d '' png_file; do
    [[ "${show_links_output}" == *"  PNG: ${png_file}"* ]]
  done < <(find /root/xtun-qr -maxdepth 1 -type f -name '*.png' -print0)
  grep -q '^## 二维码' "${output_file}"
}

main() {
  case "${1:-}" in
    install-core)
      install_core
      ;;
    check-latest)
      check_latest
      ;;
    container)
      container_install
      ;;
    *)
      usage >&2
      return 1
      ;;
  esac
}

main "$@"
