run_usage_case() {
  local workdir=""
  local output=""

  workdir="$(mktemp -d)"
  ln -s "${ROOT_DIR}/xtun.sh" "${workdir}/xtun"
  output="$("${workdir}/xtun" help)"

  [[ "${output}" == *$'\n  xtun help'* ]]
  [[ "${output}" == *$'\n  xtun install [参数]'* ]]
  [[ "${output}" == *$'\n  xtun update-script'* ]]
  [[ "${output}" == *$'\n  xtun renew-cert [参数]'* ]]
  [[ "${output}" == *$'\n  xtun change-warp-rules [参数]'* ]]
  [[ "${output}" == *$'\n  xtun add-client NAME [参数]'* ]]
  [[ "${output}" == *$'\n  xtun list-clients'* ]]
  [[ "${output}" == *$'\n  xtun diagnose'* ]]
  [[ "${output}" == *$'\n  xtun apply-net-opt'* ]]
}

run_show_links_without_state_case() {
  local workdir=""
  local output=""

  workdir="$(mktemp -d)"
  OUTPUT_FILE="${workdir}/output.md"
  STATE_FILE="${workdir}/missing-state.env"
  cat > "${OUTPUT_FILE}" <<'EOF'
vless://example-link
EOF

  output="$(show_links)"
  [[ "${output}" == "vless://example-link" ]]
}

run_single_file_bootstrap_case() {
  local workdir=""
  local output=""
  local old_bundle=""

  workdir="$(mktemp -d)"
  cp "${ROOT_DIR}/xtun.sh" "${workdir}/xtun.sh"
  old_bundle="${workdir}/old-bundle"
  mkdir -p "${old_bundle}/lib/base" "${old_bundle}/static/fallback"
  cp "${ROOT_DIR}/xtun.sh" "${old_bundle}/xtun.sh"
  printf '# helper\n' > "${old_bundle}/lib/base/helpers.sh"
  printf '<!doctype html>\n' > "${old_bundle}/static/fallback/index.html"

  output="$(XTUN_SELF_INSTALL_DIR="${old_bundle}" XTUN_SELF_COMMAND_PATH="${workdir}/bin/xtun" XTUN_BOOTSTRAP_ROOT="${ROOT_DIR}" bash "${workdir}/xtun.sh" help)"
  [[ "${output}" == *$'\n  xtun.sh help'* ]]
  [[ "${output}" == *$'\n  xtun.sh diagnose'* ]]
}

run_bootstrap_archive_resolve_case() {
  local archive_url=""
  local original_bootstrap_archive_url="${BOOTSTRAP_ARCHIVE_URL:-}"
  local original_repo_owner="${BOOTSTRAP_REPO_OWNER:-}"
  local original_repo_name="${BOOTSTRAP_REPO_NAME:-}"
  local original_branch_ref="${BOOTSTRAP_BRANCH_REF:-}"

  BOOTSTRAP_ARCHIVE_URL=""
  BOOTSTRAP_REPO_OWNER="milikii"
  BOOTSTRAP_REPO_NAME="xtun"
  BOOTSTRAP_BRANCH_REF="main"

  curl() {
    printf '%s' '{"sha":"0123456789abcdef0123456789abcdef01234567"}'
  }
  archive_url="$(bootstrap_resolve_archive_url)"
  [[ "${archive_url}" == "https://codeload.github.com/milikii/xtun/tar.gz/0123456789abcdef0123456789abcdef01234567" ]]

  curl() {
    return 99
  }
  archive_url="$(bootstrap_resolve_archive_url)"
  [[ "${archive_url}" == "https://codeload.github.com/milikii/xtun/tar.gz/main" ]]

  BOOTSTRAP_ARCHIVE_URL="https://example.invalid/custom.tar.gz"
  archive_url="$(bootstrap_resolve_archive_url)"
  [[ "${archive_url}" == "https://example.invalid/custom.tar.gz" ]]

  BOOTSTRAP_ARCHIVE_URL="${original_bootstrap_archive_url}"
  BOOTSTRAP_REPO_OWNER="${original_repo_owner}"
  BOOTSTRAP_REPO_NAME="${original_repo_name}"
  BOOTSTRAP_BRANCH_REF="${original_branch_ref}"
  unset -f curl
}

run_install_self_command_case() {
  local workdir=""
  local output=""
  local source_bundle=""

  workdir="$(mktemp -d)"
  SELF_COMMAND_PATH="${workdir}/bin/xtun"
  SELF_INSTALL_DIR="${workdir}/bundle"
  SCRIPT_SELF="${ROOT_DIR}/xtun.sh"
  SCRIPT_ROOT="${ROOT_DIR}"

  install_self_command

  [[ -x "${SELF_COMMAND_PATH}" ]]
  [[ -f "${SELF_INSTALL_DIR}/xtun.sh" ]]
  [[ -f "${SELF_INSTALL_DIR}/lib/install.sh" ]]
  [[ -f "${SELF_INSTALL_DIR}/static/fallback/index.html" ]]

  output="$("${SELF_COMMAND_PATH}" help)"
  [[ "${output}" == *$'\n  xtun help'* ]]
  [[ "${output}" == *$'\n  xtun install [参数]'* ]]

  source_bundle="${workdir}/source-bundle"
  cp -a "${SELF_INSTALL_DIR}" "${source_bundle}"
  SELF_INSTALL_DIR="${source_bundle}"
  SELF_COMMAND_PATH="${workdir}/bin/xtun-reinstall"
  SCRIPT_SELF="${source_bundle}/xtun.sh"
  SCRIPT_ROOT="${source_bundle}"

  install_self_command
  [[ -x "${SELF_COMMAND_PATH}" ]]
  [[ -f "${SELF_INSTALL_DIR}/xtun.sh" ]]
  [[ -f "${SELF_INSTALL_DIR}/lib/ui/output.sh" ]]
  [[ -f "${SELF_INSTALL_DIR}/static/fallback/index.html" ]]
}

run_update_script_command_case() {
  local workdir=""
  local logged=""
  local stdout_output=""
  local installs=0
  local original_install_bundle_fn=""
  local original_log_step_fn=""
  local original_log_success_fn=""
  local original_log_fn=""

  workdir="$(mktemp -d)"
  SELF_INSTALL_DIR="${workdir}/bundle"
  SELF_COMMAND_PATH="${workdir}/bin/xtun"
  SCRIPT_VERSION="0.4.5"
  original_install_bundle_fn="$(capture_function_definition install_bundle_root_to_self)"
  original_log_step_fn="$(capture_function_definition log_step)"
  original_log_success_fn="$(capture_function_definition log_success)"
  original_log_fn="$(capture_function_definition log)"

  need_root() { :; }
  start_backup_session() { BACKUP_DIR="${workdir}/backup"; }
  bootstrap_resolve_archive_url() {
    printf '%s' "https://example.invalid/xtun.tar.gz"
  }
  curl() {
    local output_path=""

    while [[ $# -gt 0 ]]; do
      case "${1}" in
        -o)
          output_path="${2}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done

    printf 'archive' > "${output_path}"
  }
  tar() {
    local target_dir=""

    while [[ $# -gt 0 ]]; do
      case "${1}" in
        -C)
          target_dir="${2}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done

    mkdir -p "${target_dir}/bundle/lib/base" "${target_dir}/bundle/static/fallback"
    cat > "${target_dir}/bundle/xtun.sh" <<'EOF'
#!/usr/bin/env bash
SCRIPT_VERSION="9.9.9"
EOF
    printf '# helper\n' > "${target_dir}/bundle/lib/base/helpers.sh"
    printf '<!doctype html>\n' > "${target_dir}/bundle/static/fallback/index.html"
  }
  log_step() {
    logged+="STEP:${1}"$'\n'
  }
  log_success() {
    logged+="DONE:${1}"$'\n'
  }
  log() {
    logged+="${1}"$'\n'
  }
  backup_path() { :; }
  eval "${original_install_bundle_fn/install_bundle_root_to_self/real_install_bundle_root_to_self}"
  install_bundle_root_to_self() {
    installs=$((installs + 1))
    real_install_bundle_root_to_self "${1}"
  }
  reload_updated_script_if_needed() {
    SCRIPT_VERSION="${1}"
    logged+="RELOAD:${1}"$'\n'
  }

  update_script_cmd

  [[ -x "${SELF_COMMAND_PATH}" ]]
  [[ -f "${SELF_INSTALL_DIR}/xtun.sh" ]]
  [[ -f "${SELF_INSTALL_DIR}/static/fallback/index.html" ]]
  grep -q 'SCRIPT_VERSION="9.9.9"' "${SELF_INSTALL_DIR}/xtun.sh"
  grep -q 'STEP:下载最新脚本 bundle。' <<< "${logged}"
  grep -q 'STEP:安装脚本 bundle。' <<< "${logged}"
  grep -q '当前版本：9.9.9' <<< "${logged}"
  grep -q 'RELOAD:9.9.9' <<< "${logged}"
  [[ "${SCRIPT_VERSION}" == "9.9.9" ]]
  [[ "${installs}" -eq 1 ]]

  restore_function_definition "${original_log_step_fn}"
  restore_function_definition "${original_log_success_fn}"
  restore_function_definition "${original_log_fn}"
  stdout_output="$(update_script_cmd 2>&1)"
  [[ -x "${SELF_COMMAND_PATH}" ]]
  [[ -f "${SELF_INSTALL_DIR}/xtun.sh" ]]
  grep -q '下载来源：' <<< "${stdout_output}"
  grep -q '当前已经是最新脚本 bundle。' <<< "${stdout_output}"

  tar() {
    local target_dir=""

    while [[ $# -gt 0 ]]; do
      case "${1}" in
        -C)
          target_dir="${2}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done

    mkdir -p "${target_dir}/bundle/lib/base" "${target_dir}/bundle/static/fallback"
    cat > "${target_dir}/bundle/xtun.sh" <<'EOF'
#!/usr/bin/env bash
SCRIPT_VERSION="9.9.9"
echo changed
EOF
    printf '# helper\n' > "${target_dir}/bundle/lib/base/helpers.sh"
    printf '<!doctype html>\n' > "${target_dir}/bundle/static/fallback/index.html"
  }
  stdout_output="$(update_script_cmd 2>&1)"
  grep -q '脚本内容已更新，但版本号保持为 9.9.9。' <<< "${stdout_output}"
}

run_install_validation_case() {
  local output=""

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
ENABLE_WARP="no"
REALITY_SNI='bad"host'
REALITY_TARGET='www.scu.edu:443'
XHTTP_DOMAIN='cdn.example.com'
XHTTP_PATH='/assets/v3'
validate_install_inputs
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q 'REALITY SNI 不是合法域名'

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
ENABLE_WARP="no"
REALITY_SNI='reality.example.com'
REALITY_TARGET='www.scu.edu:bad'
XHTTP_DOMAIN='cdn.example.com'
XHTTP_PATH='/assets/v3'
validate_install_inputs
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q 'REALITY 目标地址 必须是 1-65535 之间的端口'

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
ENABLE_WARP="no"
REALITY_SNI='reality.example.com'
REALITY_TARGET='www.scu.edu:443'
XHTTP_DOMAIN='cdn.example.com'
XHTTP_PATH='/bad path'
validate_install_inputs
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q 'XHTTP 路径不能包含空白字符'

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
ENABLE_WARP="no"
REALITY_SNI='reality.example.com'
REALITY_TARGET='www.scu.edu:443'
XHTTP_DOMAIN='cdn.example.com'
XHTTP_PATH='/assets/v3'
XHTTP_XPADDING_ENABLED='yes'
XHTTP_XPADDING_KEY='bad key'
validate_install_inputs
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q 'XHTTP xpadding 参数名只能包含'
}

run_value_source_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  printf 'secret-from-file\n' > "${workdir}/secret.txt"

  WARP_PRIVATE_KEY="@${workdir}/secret.txt"
  resolve_value_source WARP_PRIVATE_KEY
  [[ "${WARP_PRIVATE_KEY}" == "secret-from-file" ]]

  WARP_ADDRESS_V4=""
  export WARP_ADDRESS_V4="172.16.0.9"
  resolve_value_source WARP_ADDRESS_V4
  [[ "${WARP_ADDRESS_V4}" == "172.16.0.9" ]]
  unset WARP_ADDRESS_V4
}

run_prompt_reuse_case() {
  local output=""
  local script_file=""

  script_file="$(mktemp)"
  cat > "${script_file}" <<EOF
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
NON_INTERACTIVE=0
SERVER_IP="203.0.113.10"
prompt_with_default SERVER_IP "REALITY 直连节点地址或 IP" "198.51.100.10"
printf '%s' "\${SERVER_IP}"
EOF
  output="$(printf '203.0.113.11\n' | bash "${script_file}")"
  rm -f "${script_file}"
  [[ "${output}" == "203.0.113.11" ]]

  script_file="$(mktemp)"
  cat > "${script_file}" <<EOF
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
NON_INTERACTIVE=0
SERVER_IP="203.0.113.10"
prompt_with_default SERVER_IP "REALITY 直连节点地址或 IP" "198.51.100.10"
printf '%s' "\${SERVER_IP}"
EOF
  output="$(printf '\n' | bash "${script_file}")"
  rm -f "${script_file}"
  [[ "${output}" == "203.0.113.10" ]]

  script_file="$(mktemp)"
  cat > "${script_file}" <<EOF
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
NON_INTERACTIVE=0
ENABLE_WARP="yes"
prompt_yes_no ENABLE_WARP "是否启用选择性 WARP 出站？ [y/n]" "y"
printf '%s' "\${ENABLE_WARP}"
EOF
  output="$(printf 'n\n' | bash "${script_file}")"
  rm -f "${script_file}"
  [[ "${output}" == "n" ]]

  script_file="$(mktemp)"
  cat > "${script_file}" <<EOF
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
NON_INTERACTIVE=0
WARP_PRIVATE_KEY="secret-old"
prompt_secret WARP_PRIVATE_KEY "WARP WireGuard 私钥"
printf '%s' "\${WARP_PRIVATE_KEY}"
EOF
  output="$(printf '\n' | bash "${script_file}")"
  rm -f "${script_file}"
  [[ "${output##*$'\n'}" == "secret-old" ]]
}

run_xray_digest_parse_case() {
  local workdir=""
  local dgst_file=""
  local hash_value=""
  local metadata_json=""

  workdir="$(mktemp -d)"
  dgst_file="${workdir}/Xray-linux-64.zip.dgst"
  cat > "${dgst_file}" <<'EOF'
SHA256 (Xray-linux-64.zip) = 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
SHA512 (Xray-linux-64.zip) = deadbeef
EOF

  hash_value="$(parse_xray_dgst_sha256 "${dgst_file}" "Xray-linux-64.zip")"
  [[ "${hash_value}" == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ]]

  cat > "${dgst_file}" <<'EOF'
Xray-linux-64.zip
sha256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
sha512: deadbeef
EOF

  hash_value="$(parse_xray_dgst_sha256 "${dgst_file}" "Xray-linux-64.zip")"
  [[ "${hash_value}" == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ]]

  metadata_json='{"assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://example.invalid/Xray-linux-64.zip","digest":"sha256:0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"}]}'
  hash_value="$(normalize_xray_sha256_value "$(xray_release_asset_field_from_metadata "${metadata_json}" "Xray-linux-64.zip" "digest")")"
  [[ "${hash_value}" == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ]]
  [[ "$(xray_release_asset_field_from_metadata "${metadata_json}" "Xray-linux-64.zip" "browser_download_url")" == "https://example.invalid/Xray-linux-64.zip" ]]
}

run_install_xray_checksum_failure_case() {
  local output=""

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
detect_xray_arch() { printf '64'; }
curl() {
  case "\$*" in
    *Xray-linux-64.zip.dgst*)
      printf '%s\n' 'SHA256 (Xray-linux-64.zip) = 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' > "\${4}"
      ;;
    *Xray-linux-64.zip*)
      printf '%s' 'not-a-real-zip' > "\${4}"
      ;;
  esac
}
install_xray
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q 'Xray-core 安装包 SHA256 校验失败'
}

run_install_packages_failure_case() {
  local output=""

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
apt-get() {
  return 1
}
install_packages
EOF
)"; then
    return 1
  fi

  printf '%s' "${output}" | grep -q '安装依赖包'
  if printf '%s' "${output}" | grep -q '依赖包安装完成'; then
    return 1
  fi
}

run_install_parse_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  printf '%s\n' "${TEST_WARP_PRIVATE_KEY}" > "${workdir}/warp-private-key.txt"
  NON_INTERACTIVE=0
  SERVER_IP=""
  NODE_LABEL_PREFIX=""
  REALITY_UUID=""
  REALITY_SNI=""
  REALITY_TARGET=""
  REALITY_SHORT_ID=""
  REALITY_PRIVATE_KEY=""
  XHTTP_UUID=""
  XHTTP_DOMAIN=""
  XHTTP_PATH=""
  XHTTP_VLESS_ENCRYPTION_ENABLED="yes"
  XHTTP_ECH_CONFIG_LIST=""
  XHTTP_ECH_FORCE_QUERY=""
  XHTTP_XPADDING_ENABLED="no"
  XHTTP_XPADDING_KEY=""
  XHTTP_XPADDING_HEADER=""
  XHTTP_XPADDING_PLACEMENT=""
  XHTTP_XPADDING_METHOD=""
  CERT_MODE=""
  CERT_SOURCE_FILE=""
  KEY_SOURCE_FILE=""
  ENABLE_WARP=""
  ENABLE_NET_OPT=""
  clear_test_warp_credentials

  parse_install_args \
    --non-interactive \
    --server-ip 198.51.100.10 \
    --node-label-prefix hkg \
    --reality-sni reality.example.com \
    --reality-target reality.example.com:443 \
    --xhttp-domain cdn.example.com \
    --xhttp-path /edge \
    --disable-xhttp-vless-encryption \
    --enable-xhttp-ech \
    --xhttp-ech-force-query none \
    --enable-xhttp-xpadding \
    --xhttp-xpadding-key x_pad \
    --xhttp-xpadding-header Referer \
    --cert-mode 2 \
    --cert-file /tmp/cert.pem \
    --key-file /tmp/key.pem \
    --enable-warp \
    --warp-private-key "@${workdir}/warp-private-key.txt" \
    --warp-address-v4 172.16.0.2 \
    --warp-address-v6 2606:4700:110:8a1b:cafe:1:2:3 \
    --warp-reserved '[1, 2, 3]' \
    --warp-endpoint engage.cloudflareclient.com:2408 \
    --warp-mtu 1280 \
    --disable-net-opt

  resolve_install_input_sources
  [[ "${NON_INTERACTIVE}" -eq 1 ]]
  [[ "${SERVER_IP}" == "198.51.100.10" ]]
  [[ "${NODE_LABEL_PREFIX}" == "hkg" ]]
  [[ "${REALITY_SNI}" == "reality.example.com" ]]
  [[ "${REALITY_TARGET}" == "reality.example.com:443" ]]
  [[ "${XHTTP_DOMAIN}" == "cdn.example.com" ]]
  [[ "${XHTTP_PATH}" == "/edge" ]]
  [[ "${XHTTP_VLESS_ENCRYPTION_ENABLED}" == "no" ]]
  [[ "${XHTTP_ECH_CONFIG_LIST}" == "cloudflare-ech.com+https://223.5.5.5/dns-query" ]]
  [[ "${XHTTP_ECH_FORCE_QUERY}" == "none" ]]
  [[ "${XHTTP_XPADDING_ENABLED}" == "yes" ]]
  [[ "${XHTTP_XPADDING_KEY}" == "x_pad" ]]
  [[ "${XHTTP_XPADDING_HEADER}" == "Referer" ]]
  [[ "${CERT_MODE}" == "2" ]]
  [[ "$(validate_cert_mode_value "${CERT_MODE}")" == "existing" ]]
  [[ "${CERT_SOURCE_FILE}" == "/tmp/cert.pem" ]]
  [[ "${KEY_SOURCE_FILE}" == "/tmp/key.pem" ]]
  [[ "${ENABLE_WARP}" == "yes" ]]
  [[ "${WARP_PRIVATE_KEY}" == "${TEST_WARP_PRIVATE_KEY}" ]]
  [[ "${WARP_ADDRESS_V4}" == "172.16.0.2" ]]
  [[ "${WARP_ADDRESS_V6}" == "2606:4700:110:8a1b:cafe:1:2:3" ]]
  [[ "${WARP_ENDPOINT}" == "engage.cloudflareclient.com:2408" ]]
  [[ "${WARP_MTU}" == "1280" ]]
  ensure_warp_outbound_format
  [[ "${WARP_RESERVED}" == "1,2,3" ]]
  [[ "${ENABLE_NET_OPT}" == "no" ]]
}

run_install_prepare_preserves_ech_flag_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults
  INSTALL_DRAFT_FILE="${workdir}/draft.env"
  SCRIPT_LOCK_FILE="${workdir}/lock"
  XRAY_CONFIG_FILE="${workdir}/missing-config.json"
  HAPROXY_CONFIG="${workdir}/missing-haproxy.cfg"
  SERVER_IP="198.51.100.10"
  NODE_LABEL_PREFIX="hkg"
  REALITY_UUID="11111111-1111-1111-1111-111111111111"
  REALITY_SNI="reality.example.com"
  REALITY_TARGET="reality.example.com:443"
  REALITY_SHORT_ID="abcd1234"
  REALITY_PRIVATE_KEY="private-key"
  XHTTP_UUID="22222222-2222-2222-2222-222222222222"
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/edge"
  CERT_MODE="self-signed"
  ENABLE_WARP="no"
  ENABLE_NET_OPT="no"

  need_root() { :; }
  ensure_debian_family() { :; }
  start_backup_session() { BACKUP_DIR="${workdir}/backup"; }
  run_install_preflight_checks() { :; }

  prepare_install_command --non-interactive --enable-xhttp-ech --enable-xhttp-xpadding

  [[ "${XHTTP_ECH_CONFIG_LIST}" == "cloudflare-ech.com+https://223.5.5.5/dns-query" ]]
  [[ "${XHTTP_ECH_FORCE_QUERY}" == "none" ]]
  [[ "${XHTTP_XPADDING_ENABLED}" == "yes" ]]
}

run_sensitive_option_reject_case() {
  local output=""

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
parse_install_args --warp-private-key direct-key
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q '不支持直接明文传值'
  printf '%s' "${output}" | grep -q 'WARP_PRIVATE_KEY'

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
parse_install_args --warp-profile /tmp/profile.conf
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q '不支持直接明文传值'
}

run_preflight_token_verify_case() {
  local output=""

  if ! output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
curl() {
  printf '%s' '{"success":true}'
}
jq() {
  return 99
}
verify_cloudflare_token "token-value" "Cloudflare API Token"
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q 'Cloudflare API Token 校验通过'

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
curl() {
  printf '%s' '{"success":false}'
}
verify_cloudflare_token "token-value" "Cloudflare API Token"
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q 'Cloudflare API Token 校验未通过'
}

run_preflight_domain_resolution_warning_case() {
  local output=""

  if ! output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
getent() {
  return 2
}
preflight_check_domain_resolution "cdn.example.test" "XHTTP CDN 域名"
EOF
)"; then
    return 1
  fi

  printf '%s' "${output}" | grep -q '预检提示：XHTTP CDN 域名 当前无法解析'
}

run_warp_rule_normalize_case() {
  local output=""

  output="$(normalize_warp_rules_text $' chat.openai.com \n# comment\ngeosite:google\ndomain:chat.openai.com\n')"
  [[ "${output}" == $'domain:chat.openai.com\ngeosite:google' ]]

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
normalize_warp_rules_text \$'bad rule with space'
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q 'WARP 分流规则不能包含空白字符'
}

run_optional_component_skip_case() {
  ENABLE_NET_OPT="no"
  ENABLE_WARP="no"

  install_network_optimization
  ensure_warp_credentials
}

run_joey_bbr_release_parse_case() {
  local metadata_json=""
  local tag_name=""
  local rows=""

  metadata_json='[
    {
      "tag_name": "x86_64-7.0.5",
      "published_at": "2026-05-08T12:29:14Z",
      "assets": [
        {
          "name": "linux-image-7.0.5-joeyblog-bbrv3_7.0.5-1_amd64.deb",
          "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "browser_download_url": "https://example.invalid/x86-image.deb"
        }
      ]
    },
    {
      "tag_name": "arm64-7.0.3",
      "published_at": "2026-05-04T16:33:05Z",
      "assets": [
        {
          "name": "linux-image-7.0.3-joeyblog-bbrv3_7.0.3-1_arm64.deb",
          "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "browser_download_url": "https://example.invalid/arm-image.deb"
        },
        {
          "name": "linux-image-7.0.3-joeyblog-bbrv3-dbg_7.0.3-1_arm64.deb",
          "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
          "browser_download_url": "https://example.invalid/arm-debug.deb"
        }
      ]
    }
  ]'

  [[ "$(joey_bbr_release_arch_filter aarch64)" == "arm64" ]]
  [[ "$(joey_bbr_release_arch_filter x86_64)" == "x86_64" ]]
  tag_name="$(joey_bbr_latest_tag_from_metadata "${metadata_json}" "arm64")"
  [[ "${tag_name}" == "arm64-7.0.3" ]]
  [[ "$(joey_bbr_latest_core_version_from_tag "${tag_name}")" == "7.0.3" ]]

  rows="$(joey_bbr_release_asset_rows_from_metadata "${metadata_json}" "${tag_name}")"
  printf '%s' "${rows}" | grep -q 'linux-image-7.0.3-joeyblog-bbrv3_7.0.3-1_arm64.deb'
  printf '%s' "${rows}" | grep -qv -- '-dbg_'
  validate_joey_bbr_asset_rows "${rows}"
}

run_joey_bbr_pending_reboot_case() {
  local fixture_json=""
  local downloaded=0
  local installed=0

  NET_BBRV3_REBOOT_REQUIRED="no"
  fixture_json='[
    {
      "tag_name": "arm64-7.0.3",
      "published_at": "2026-05-04T16:33:05Z",
      "assets": [
        {
          "name": "linux-image-7.0.3-joeyblog-bbrv3_7.0.3-1_arm64.deb",
          "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "browser_download_url": "https://example.invalid/arm-image.deb"
        }
      ]
    }
  ]'

  bbr_v3_active() { return 1; }
  uname() { printf '%s\n' "aarch64"; }
  fetch_joey_bbr_release_metadata_json() { printf '%s' "${fixture_json}"; }
  joey_bbr_installed_kernel_version() { printf '%s\n' "7.0.3-g90210de4b779-1"; }
  download_joey_bbrv3_assets() { downloaded=$((downloaded + 1)); }
  install_joey_bbrv3_deb_files() { installed=$((installed + 1)); }
  warn() { :; }
  log_success() { :; }

  install_joey_bbrv3_kernel_if_needed

  [[ "${NET_BBRV3_REBOOT_REQUIRED}" == "yes" ]]
  [[ "${downloaded}" -eq 0 ]]
  [[ "${installed}" -eq 0 ]]
  load_functions
}

run_install_network_joey_reboot_case() {
  local workdir=""
  local sysctl_calls=0
  local systemctl_calls=""

  workdir="$(mktemp -d)"
  NET_SYSCTL_CONF="${workdir}/net.conf"
  NET_HELPER_PATH="${workdir}/xtun-net-optimize.sh"
  NET_SERVICE_FILE="${workdir}/xtun-net-optimize.service"
  ENABLE_NET_OPT="yes"
  NET_BBRV3_REBOOT_REQUIRED="no"

  install_joey_bbrv3_kernel_if_needed() {
    NET_BBRV3_REBOOT_REQUIRED="yes"
  }
  available_cc() { :; }
  supports_default_qdisc() { return 1; }
  bbr_v3_active() { return 1; }
  modprobe() { :; }
  backup_path() { :; }
  sysctl() {
    sysctl_calls=$((sysctl_calls + 1))
    return 1
  }
  systemctl() {
    systemctl_calls+="$*"$'\n'
  }
  warn() { :; }
  log_success() { :; }

  install_network_optimization

  assert_contains 'net.core.default_qdisc = fq' "${NET_SYSCTL_CONF}"
  assert_contains 'net.ipv4.tcp_congestion_control = bbr' "${NET_SYSCTL_CONF}"
  [[ -x "${NET_HELPER_PATH}" ]]
  [[ -f "${NET_SERVICE_FILE}" ]]
  [[ "${sysctl_calls}" -eq 1 ]]
  printf '%s' "${systemctl_calls}" | grep -q '^daemon-reload$'
  printf '%s' "${systemctl_calls}" | grep -q "^enable --now ${NET_SERVICE_NAME}$"
  [[ "${ENABLE_NET_OPT}" == "yes" ]]
  load_functions
}

run_apply_net_opt_command_case() {
  local calls=""
  local logged=""
  local workdir=""

  workdir="$(mktemp -d)"
  ENABLE_NET_OPT="no"
  NET_BBRV3_REBOOT_REQUIRED="stale"

  need_root() {
    calls+="root"$'\n'
  }
  ensure_debian_family() {
    calls+="debian"$'\n'
  }
  start_backup_session() {
    calls+="backup"$'\n'
    BACKUP_DIR="${workdir}/backup"
  }
  load_current_install_context() {
    calls+="load"$'\n'
    ENABLE_NET_OPT="no"
    REALITY_UUID="11111111-1111-1111-1111-111111111111"
    XHTTP_UUID="22222222-2222-2222-2222-222222222222"
  }
  install_network_optimization() {
    calls+="net:${ENABLE_NET_OPT}:${NET_BBRV3_REBOOT_REQUIRED}"$'\n'
  }
  write_state_file() {
    calls+="state:${ENABLE_NET_OPT}"$'\n'
  }
  bbr_v3_active() {
    return 1
  }
  log_step() {
    logged+="STEP:${1}"$'\n'
  }
  log_success() {
    logged+="DONE:${1}"$'\n'
  }
  log() {
    logged+="${1}"$'\n'
  }

  apply_net_opt_cmd

  [[ "${ENABLE_NET_OPT}" == "yes" ]]
  [[ "${NET_BBRV3_REBOOT_REQUIRED}" == "no" ]]
  [[ "${calls}" == $'root\ndebian\nbackup\nload\nnet:yes:no\nstate:yes\n' ]]
  grep -q 'STEP:读取当前托管安装状态。' <<< "${logged}"
  grep -q 'STEP:应用 Joey BBRv3 网络优化。' <<< "${logged}"
  grep -q 'DONE:网络优化已应用。' <<< "${logged}"
  grep -q "备份目录：${workdir}/backup" <<< "${logged}"

  NET_BBRV3_REBOOT_REQUIRED="yes"
  install_network_optimization() {
    NET_BBRV3_REBOOT_REQUIRED="yes"
    calls+="net-reboot"$'\n'
  }
  calls=""
  logged=""

  apply_net_opt_cmd

  grep -q '请重启 VPS 后加载 Joey BBRv3 内核。' <<< "${logged}"
  load_functions
}

run_install_draft_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  INSTALL_DRAFT_FILE="${workdir}/install-draft.env"
  SERVER_IP="203.0.113.10"
  NODE_LABEL_PREFIX="HKG"
  REALITY_SNI="reality.example.com"
  XHTTP_DOMAIN="cdn.example.com"
  ENABLE_WARP="yes"
  set_test_warp_credentials

  write_install_draft_file

  SERVER_IP=""
  NODE_LABEL_PREFIX=""
  REALITY_SNI=""
  XHTTP_DOMAIN=""
  ENABLE_WARP=""
  clear_test_warp_credentials
  load_install_draft_file
  [[ "${SERVER_IP}" == "203.0.113.10" ]]
  [[ "${NODE_LABEL_PREFIX}" == "HKG" ]]
  [[ "${REALITY_SNI}" == "reality.example.com" ]]
  [[ "${XHTTP_DOMAIN}" == "cdn.example.com" ]]
  [[ "${ENABLE_WARP}" == "yes" ]]
  [[ "${WARP_PRIVATE_KEY}" == "${TEST_WARP_PRIVATE_KEY}" ]]
  [[ "${WARP_ADDRESS_V4}" == "172.16.0.2" ]]
  [[ "${WARP_RESERVED}" == "3,4,5" ]]
  [[ "$(stat -c '%a' "${INSTALL_DRAFT_FILE}")" == "600" ]]

  clear_install_draft_file
  [[ ! -f "${INSTALL_DRAFT_FILE}" ]]
}

run_cert_mode_input_case() {
  NON_INTERACTIVE=1

  CERT_MODE="cf-origin-ca"
  CERT_SOURCE_FILE="/tmp/old-cert.pem"
  KEY_SOURCE_FILE="/tmp/old-key.pem"
  CERT_SOURCE_PEM="old-cert-pem"
  KEY_SOURCE_PEM="old-key-pem"
  CF_ZONE_ID="zone-id"
  CF_API_TOKEN="api-token"
  CF_CERT_VALIDITY="365"
  ACME_EMAIL="ops@example.com"
  ACME_CA="zerossl"
  CF_DNS_TOKEN="dns-token"
  CF_DNS_ACCOUNT_ID="account-id"
  CF_DNS_ZONE_ID="dns-zone-id"
  prompt_cert_mode_inputs
  [[ "${CERT_SOURCE_FILE}" == "/tmp/old-cert.pem" ]]
  [[ "${KEY_SOURCE_FILE}" == "/tmp/old-key.pem" ]]
  [[ -z "${CERT_SOURCE_PEM}" ]]
  [[ -z "${KEY_SOURCE_PEM}" ]]
  [[ -z "${CF_ZONE_ID}" ]]
  [[ -z "${CF_API_TOKEN}" ]]
  [[ "${CF_CERT_VALIDITY}" == "5475" ]]
  [[ -z "${ACME_EMAIL}" ]]
  [[ "${ACME_CA}" == "letsencrypt" ]]
  [[ -z "${CF_DNS_TOKEN}" ]]
  [[ -z "${CF_DNS_ACCOUNT_ID}" ]]
  [[ -z "${CF_DNS_ZONE_ID}" ]]

  CERT_MODE="acme-dns-cf"
  CERT_SOURCE_FILE="/tmp/old-cert.pem"
  KEY_SOURCE_FILE="/tmp/old-key.pem"
  CERT_SOURCE_PEM="old-cert-pem"
  KEY_SOURCE_PEM="old-key-pem"
  CF_ZONE_ID="zone-id"
  CF_API_TOKEN="api-token"
  CF_CERT_VALIDITY="365"
  ACME_EMAIL="ops@example.com"
  ACME_CA="zerossl"
  CF_DNS_TOKEN="dns-token"
  CF_DNS_ACCOUNT_ID="account-id"
  CF_DNS_ZONE_ID="dns-zone-id"
  prompt_cert_mode_inputs
  [[ -z "${CERT_SOURCE_FILE}" ]]
  [[ -z "${KEY_SOURCE_FILE}" ]]
  [[ -z "${CERT_SOURCE_PEM}" ]]
  [[ -z "${KEY_SOURCE_PEM}" ]]
  [[ -z "${CF_ZONE_ID}" ]]
  [[ -z "${CF_API_TOKEN}" ]]
  [[ "${CF_CERT_VALIDITY}" == "5475" ]]
  [[ "${ACME_EMAIL}" == "ops@example.com" ]]
  [[ "${ACME_CA}" == "zerossl" ]]
  [[ "${CF_DNS_TOKEN}" == "dns-token" ]]
  [[ "${CF_DNS_ACCOUNT_ID}" == "account-id" ]]
  [[ "${CF_DNS_ZONE_ID}" == "dns-zone-id" ]]

  CERT_MODE="self-signed"
  CERT_SOURCE_FILE="/tmp/old-cert.pem"
  KEY_SOURCE_FILE="/tmp/old-key.pem"
  CERT_SOURCE_PEM="old-cert-pem"
  KEY_SOURCE_PEM="old-key-pem"
  CF_ZONE_ID="zone-id"
  CF_API_TOKEN="api-token"
  CF_CERT_VALIDITY="365"
  ACME_EMAIL="ops@example.com"
  ACME_CA="zerossl"
  CF_DNS_TOKEN="dns-token"
  CF_DNS_ACCOUNT_ID="account-id"
  CF_DNS_ZONE_ID="dns-zone-id"
  prompt_cert_mode_inputs
  [[ -z "${CERT_SOURCE_FILE}" ]]
  [[ -z "${KEY_SOURCE_FILE}" ]]
  [[ -z "${CERT_SOURCE_PEM}" ]]
  [[ -z "${KEY_SOURCE_PEM}" ]]
  [[ -z "${CF_ZONE_ID}" ]]
  [[ -z "${CF_API_TOKEN}" ]]
  [[ "${CF_CERT_VALIDITY}" == "5475" ]]
  [[ -z "${ACME_EMAIL}" ]]
  [[ "${ACME_CA}" == "letsencrypt" ]]
  [[ -z "${CF_DNS_TOKEN}" ]]
  [[ -z "${CF_DNS_ACCOUNT_ID}" ]]
  [[ -z "${CF_DNS_ZONE_ID}" ]]
}

run_warp_credential_helper_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  clear_test_warp_credentials

  [[ "$(warp_reserved_from_client_id 'AwQF')" == "3,4,5" ]]
  [[ -z "$(warp_reserved_from_client_id '')" ]]

  [[ "$(normalize_warp_reserved_value '[1, 2, 3]')" == "1,2,3" ]]
  [[ "$(normalize_warp_reserved_value ' 0,255 ')" == "0,255" ]]
  [[ -z "$(normalize_warp_reserved_value '')" ]]

  cat > "${workdir}/profile.conf" <<'PROFILE'
[Interface]
PrivateKey = eHR1bi10ZXN0LXdhcnAtcHJpdmF0ZS1rZXktMzJieXQ=
Address = 172.16.0.2/32, 2606:4700:110:8a1b:cafe:1:2:4/128
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = eHR1bi10ZXN0LXdhcnAtcGVlci1wdWJsaWMta2V5LTM=
AllowedIPs = 0.0.0.0/0
Endpoint = 162.159.192.1:2408
PROFILE

  warp_import_profile "$(cat "${workdir}/profile.conf")" >/dev/null
  [[ "${WARP_PRIVATE_KEY}" == "${TEST_WARP_PRIVATE_KEY}" ]]
  [[ "${WARP_ADDRESS_V4}" == "172.16.0.2" ]]
  [[ "${WARP_ADDRESS_V6}" == "2606:4700:110:8a1b:cafe:1:2:4" ]]
  [[ "${WARP_PEER_PUBLIC_KEY}" == "${TEST_WARP_PEER_PUBLIC_KEY}" ]]
  [[ "${WARP_ENDPOINT}" == "162.159.192.1:2408" ]]
  [[ "${WARP_MTU}" == "1280" ]]
  # wgcf 标准 profile 不含 Reserved，留空由 --warp-reserved 手工补
  [[ -z "${WARP_RESERVED}" ]]
  warp_credentials_ready
  ensure_warp_outbound_format

  clear_test_warp_credentials
  printf '%s\n' 'Reserved = [9, 8, 7]' >> "${workdir}/profile.conf"
  warp_import_profile "$(cat "${workdir}/profile.conf")" >/dev/null
  [[ "${WARP_RESERVED}" == "9,8,7" ]]

  clear_test_warp_credentials
  if warp_import_profile "$(printf '%s\n' '[Interface]' 'Address = 172.16.0.2/32')" 2>/dev/null; then
    return 1
  fi
  if warp_import_profile "$(printf '%s\n' '[Interface]' "PrivateKey = ${TEST_WARP_PRIVATE_KEY}")" 2>/dev/null; then
    return 1
  fi

  clear_test_warp_credentials
  ENABLE_WARP="no"
  ensure_warp_credentials

  ENABLE_WARP="yes"
  set_test_warp_credentials
  warp_register_free_device() {
    return 1
  }
  ensure_warp_credentials
  [[ "${WARP_PRIVATE_KEY}" == "${TEST_WARP_PRIVATE_KEY}" ]]
  load_functions
}

run_warp_credential_ensure_failure_case() {
  local output=""

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
ENABLE_WARP="yes"
WARP_PRIVATE_KEY=""
WARP_ADDRESS_V4=""
WARP_ADDRESS_V6=""
WARP_PROFILE_SOURCE=""
warp_legacy_team_detected() { return 1; }
warp_register_free_device() { return 1; }
ensure_warp_credentials
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q '\-\-warp-profile'
  printf '%s' "${output}" | grep -q '\-\-disable-warp'
}

run_warp_legacy_teardown_case() {
  local workdir=""
  local stopped=()
  local removed=()
  local logged=""

  workdir="$(mktemp -d)"
  printf 'legacy\n' > "${workdir}/mdm.xml"

  legacy_warp_paths() {
    printf '%s\n' "${workdir}/mdm.xml" "${workdir}/missing.list"
  }
  service_exists() { return 1; }
  stop_and_disable_service_if_present() {
    stopped+=("${1}")
  }
  remove_managed_paths() {
    removed=("$@")
  }
  systemctl() { :; }
  log() {
    logged+="${1}"$'\n'
  }
  log_step() {
    logged+="STEP:${1}"$'\n'
  }

  warp_teardown_legacy

  [[ " ${stopped[*]} " == *" xtun-warp-health.timer "* ]]
  [[ " ${stopped[*]} " == *" xtun-warp-health.service "* ]]
  [[ " ${stopped[*]} " == *" warp-svc.service "* ]]
  [[ "${removed[*]}" == "${workdir}/mdm.xml" ]]
  printf '%s' "${logged}" | grep -q 'STEP:清理旧版 WARP Team 托管文件。'
  printf '%s' "${logged}" | grep -q 'apt-get purge -y cloudflare-warp'

  rm -f "${workdir}/mdm.xml"
  stopped=()
  removed=()
  logged=""
  warp_teardown_legacy
  [[ "${#removed[@]}" -eq 0 ]]
  [[ -z "${logged}" ]]
  load_functions
}
