#!/usr/bin/env bash
# 会替换测试 VPS 的真实核心或 bundle。只在有权限重建的 VPS 上显式执行。
set -Eeuo pipefail

[[ "${XTUN_TEST_ISOLATED_VPS:-no}" == yes && "${EUID}" -eq 0 && -d /run/systemd/system ]] || exit 2
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source <(sed '$d' "${ROOT_DIR}/xtun.sh")
SCRIPT_SELF="${ROOT_DIR}/xtun.sh"
TEST_DEPLOYMENT_ROOT="$(mktemp -d /var/tmp/xtun-deployment.XXXXXX)"
[[ ! -e "${PENDING_OP_FILE}" ]] || { printf '先处理已有未完成操作。\n' >&2; exit 2; }

deployment_fingerprint() {
  local path=""

  for path in "$@"; do
    printf 'path\t%s\n' "${path}"
    if [[ -e "${path}" || -L "${path}" ]]; then
      backup_file_digest "${path}"
      stat -c '%a:%u:%g' "${path}"
      if [[ -f "${path}" && ! -L "${path}" ]] && command -v getcap >/dev/null 2>&1; then getcap "${path}"; fi
    else
      printf 'absent\n'
    fi
  done
}

deployment_assert_pending_scope() {
  local path=""

  for path in "$@"; do
    generation_has_path "${path}" || return 1
    backup_manifest_has_path "${path}" || return 1
  done
  cp "${PENDING_OP_FILE}" "${TEST_DEPLOYMENT_ROOT}/prewrite-pending.tsv"
  cp "$(backup_manifest_file)" "${TEST_DEPLOYMENT_ROOT}/prewrite-manifest.tsv"
}

case "${1:-}" in
  upgrade)
    paths=("${XRAY_BIN}" "${XRAY_ASSET_DIR}" "${XRAY_CONFIG_FILE}")
    deployment_fingerprint "${paths[@]}" > "${TEST_DEPLOYMENT_ROOT}/before.txt"
    generation_service_snapshot xray.service > "${TEST_DEPLOYMENT_ROOT}/service-before.txt"
    eval "$(declare -f install_xray | sed '1s/install_xray/deployment_real_install_xray/')"
    install_xray() {
      deployment_assert_pending_scope "${XRAY_BIN}" "${XRAY_ASSET_DIR}" || return 1
      deployment_real_install_xray || return 1
      "${XRAY_BIN}" version > "${TEST_DEPLOYMENT_ROOT}/candidate-version.txt"
      cp "${XRAY_BIN}" "${TEST_DEPLOYMENT_ROOT}/candidate-core"
      return 0
    }
    # 真实下载、摘要/核心校验、二进制与 geo 替换之后注入失败。
    validate_configs() { return 1; }
    status=0
    run_cli_command upgrade --reinstall --non-interactive --xray-version "${XRAY_VERSION:-v26.9.9}" > "${TEST_DEPLOYMENT_ROOT}/operation.log" 2>&1 || status=$?
    [[ "${status}" -eq 1 && -s "${TEST_DEPLOYMENT_ROOT}/candidate-version.txt" ]]
    [[ "${GENERATION_RECOVERY_RESULT}" == restored-verified && ! -e "${PENDING_OP_FILE}" ]]
    deployment_fingerprint "${paths[@]}" > "${TEST_DEPLOYMENT_ROOT}/after.txt"
    generation_service_snapshot xray.service > "${TEST_DEPLOYMENT_ROOT}/service-after.txt"
    cmp "${TEST_DEPLOYMENT_ROOT}/before.txt" "${TEST_DEPLOYMENT_ROOT}/after.txt"
    cmp "${TEST_DEPLOYMENT_ROOT}/service-before.txt" "${TEST_DEPLOYMENT_ROOT}/service-after.txt"
    ;;
  update-script)
    paths=("${SELF_INSTALL_DIR}" "${SELF_COMMAND_PATH}")
    deployment_fingerprint "${paths[@]}" > "${TEST_DEPLOYMENT_ROOT}/before.txt"
    download_latest_script_bundle() {
      mkdir "${1}/bundle"
      command cp -a "${ROOT_DIR}/xtun.sh" "${ROOT_DIR}/lib" "${ROOT_DIR}/static" "${1}/bundle/"
      printf '%s' "${1}/bundle"
    }
    cp() {
      if [[ "${!#}" == "${SELF_INSTALL_DIR}/lib" ]]; then
        deployment_assert_pending_scope "${SELF_INSTALL_DIR}" "${SELF_COMMAND_PATH}" || return 1
        [[ -f "${SELF_INSTALL_DIR}/xtun.sh" ]] || return 1
        mkdir -p "${SELF_INSTALL_DIR}/lib"
        command cp "${ROOT_DIR}/lib/base/env.sh" "${SELF_INSTALL_DIR}/lib/partial.sh"
        printf 'copy-failed-after-first-runtime-file\n' > "${TEST_DEPLOYMENT_ROOT}/injection.txt"
        return 1
      fi
      command cp "$@"
    }
    status=0
    run_cli_command update-script --reinstall --non-interactive > "${TEST_DEPLOYMENT_ROOT}/operation.log" 2>&1 || status=$?
    [[ "${status}" -eq 1 && -s "${TEST_DEPLOYMENT_ROOT}/injection.txt" ]]
    [[ "${GENERATION_RECOVERY_RESULT}" == restored-verified && ! -e "${PENDING_OP_FILE}" ]]
    deployment_fingerprint "${paths[@]}" > "${TEST_DEPLOYMENT_ROOT}/after.txt"
    cmp "${TEST_DEPLOYMENT_ROOT}/before.txt" "${TEST_DEPLOYMENT_ROOT}/after.txt"
    ;;
  install-output-failure)
    eval "$(declare -f begin_install_generation | sed '1s/begin_install_generation/deployment_real_begin_install_generation/')"
    begin_install_generation() {
      deployment_real_begin_install_generation || return 1
      deployment_assert_pending_scope "${SELF_INSTALL_DIR}" "${SELF_COMMAND_PATH}" "${XRAY_BIN}" "${XRAY_ASSET_DIR}" \
        "${XRAY_CONFIG_DIR}" "${XRAY_CONFIG_FILE}" "${STATE_FILE}" "${SSL_DIR}" "${TLS_CERT_FILE}" "${TLS_KEY_FILE}" \
        "${XRAY_SERVICE_FILE}" "${XRAY_LOGROTATE_FILE}" "${HAPROXY_CONFIG}" "${NGINX_CONFIG_FILE}" \
        "${NGINX_MAIN_CONFIG}" "${OUTPUT_FILE}" "${QR_OUTPUT_DIR}" || return 1
      TEST_DEPLOYMENT_PATHS=("${GENERATION_PATHS[@]}")
      if command -v nginx >/dev/null 2>&1; then TEST_DEPLOYMENT_PATHS+=("$(command -v nginx)"); fi
      deployment_fingerprint "${TEST_DEPLOYMENT_PATHS[@]}" > "${TEST_DEPLOYMENT_ROOT}/before.txt"
      printf '%s\n' "${GENERATION_SERVICE_STATES[@]}" > "${TEST_DEPLOYMENT_ROOT}/services-before.tsv"
    }
    eval "$(declare -f write_output_file | sed '1s/write_output_file/deployment_real_write_output_file/')"
    write_output_file() {
      deployment_real_write_output_file || return 1
      [[ "$(stat -c %a "${OUTPUT_FILE}")" == 600 ]] || return 1
      cp "${STATE_FILE}" "${TEST_DEPLOYMENT_ROOT}/candidate-state.env" || return 1
      printf 'failed-after-state-output-png\n' > "${TEST_DEPLOYMENT_ROOT}/injection.txt"
      return 1
    }
    status=0
    DEBIAN_FRONTEND=noninteractive run_cli_command install --task fresh --non-interactive \
      --server-ip 127.0.0.1 --reality-sni www.stanford.edu --xhttp-domain recovery.example.test \
      --cert-mode self-signed --disable-warp --disable-net-opt --bbr-kernel none --manage-nginx-main \
      --skip-sni-check --xray-version "${XRAY_VERSION:-v26.9.9}" > "${TEST_DEPLOYMENT_ROOT}/operation.log" 2>&1 || status=$?
    [[ "${status}" -eq 1 && -s "${TEST_DEPLOYMENT_ROOT}/injection.txt" ]]
    # 首次安装的软件包 unit 会保留；这种情况必须准确报 recovery-failed。
    [[ "${GENERATION_RECOVERY_RESULT}" == restored-verified || "${GENERATION_RECOVERY_RESULT}" == recovery-failed ]]
    deployment_fingerprint "${TEST_DEPLOYMENT_PATHS[@]}" > "${TEST_DEPLOYMENT_ROOT}/after.txt"
    cmp "${TEST_DEPLOYMENT_ROOT}/before.txt" "${TEST_DEPLOYMENT_ROOT}/after.txt"
    while IFS=$'\t' read -r unit active enabled; do
      if [[ "${active}" != not-installed ]]; then
        [[ "$(generation_service_snapshot "${unit}")" == "${active}"$'\t'"${enabled}" ]]
      else
        [[ "${GENERATION_RECOVERY_RESULT}" == recovery-failed || "$(generation_service_snapshot "${unit}")" == $'not-installed\tnot-installed' ]]
      fi
    done < "${TEST_DEPLOYMENT_ROOT}/services-before.tsv"
    (
      load_shell_kv_file "${TEST_DEPLOYMENT_ROOT}/candidate-state.env"
      expected_reality_key="${REALITY_PRIVATE_KEY}"
      expected_encryption="${XHTTP_VLESS_ENCRYPTION}"
      expected_decryption="${XHTTP_VLESS_DECRYPTION}"
      load_install_draft_file
      [[ "${REALITY_PRIVATE_KEY}" == "${expected_reality_key}" ]]
      [[ "${XHTTP_VLESS_ENCRYPTION}" == "${expected_encryption}" && "${XHTTP_VLESS_DECRYPTION}" == "${expected_decryption}" ]]
    )
    printf 'recovery=%s\npending=%s\n' "${GENERATION_RECOVERY_RESULT}" "$(pending_operation_present && printf yes || printf no)" > "${TEST_DEPLOYMENT_ROOT}/result.txt"
    ;;
  *) printf '用法: tests/deployment-recovery.sh upgrade|update-script|install-output-failure\n' >&2; exit 2 ;;
esac
printf '%s\t0\n' "${1}" | tee "${TEST_DEPLOYMENT_ROOT}/results.tsv"
printf 'deployment evidence: %s\n' "${TEST_DEPLOYMENT_ROOT}"
