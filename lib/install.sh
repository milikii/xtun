# shellcheck shell=bash

# ------------------------------
# 安装与副作用层
# 负责安装依赖、证书处理、WARP、网络优化
# 以及安装前输入准备
# ------------------------------

install_packages() {
  log_step "安装依赖包。"
  apt-get update || return 1
  apt-get install -y ca-certificates curl gnupg haproxy nginx iproute2 jq kmod openssl unzip uuid-runtime libcap2-bin qrencode || return 1
  log_success "依赖包安装完成。"
}

managed_package_names() {
  printf '%s\n' \
    "haproxy" \
    "nginx" \
    "nginx-common" \
    "jq" \
    "uuid-runtime" \
    "qrencode"
}

normalize_xray_sha256_value() {
  xray_normalize_sha256 "${1:-}"
}

parse_xray_dgst_sha256() {
  xray_parse_dgst_sha256 "${1}" "${2}"
}

verify_file_sha256() {
  local file_path="${1}"
  local expected_sha256="${2}"
  local label="${3}"
  local actual_sha256=""

  [[ -n "${expected_sha256}" ]] || die "${label} 缺少 SHA256 校验值。"
  actual_sha256="$(sha256sum "${file_path}" | awk '{print tolower($1)}')"
  [[ "${actual_sha256}" == "${expected_sha256}" ]] || die "${label} SHA256 校验失败。"
}

install_xray() {
  local arch=""
  local tmp_dir=""

  arch="$(detect_xray_arch)" || exit 1
  tmp_dir="$(mktemp -d)"

  if ! xray_release_context_ready; then
    log_step "解析 Xray-core 版本。"
    xray_prepare_release_context "${XRAY_VERSION_REQUEST}" "${arch}" || return 1
  fi

  log_step "下载并校验 Xray-core ${XRAY_SELECTED_TAG}。"
  log "资源文件：${XRAY_SELECTED_ARCHIVE_NAME}"
  log "tag 指向提交：${XRAY_SELECTED_COMMIT}"
  if ! (
    trap 'rm -rf "${tmp_dir}"' EXIT
    xray_download_release "${tmp_dir}" || exit 1
    unzip -qo "${tmp_dir}/${XRAY_SELECTED_ARCHIVE_NAME}" -d "${tmp_dir}/xray" || exit 1
    xray_validate_candidate_archive "${tmp_dir}" || exit 1

    mkdir -p /usr/local/bin "${XRAY_CONFIG_DIR}" "${XRAY_ASSET_DIR}" /var/log/xray || exit 1
    install -m 0755 "${tmp_dir}/xray/xray" "${XRAY_BIN}" || exit 1
    if [[ -f "${tmp_dir}/xray/geoip.dat" ]]; then
      install -m 0644 "${tmp_dir}/xray/geoip.dat" "${XRAY_ASSET_DIR}/geoip.dat" || exit 1
    fi
    if [[ -f "${tmp_dir}/xray/geosite.dat" ]]; then
      install -m 0644 "${tmp_dir}/xray/geosite.dat" "${XRAY_ASSET_DIR}/geosite.dat" || exit 1
    fi
  ); then
    rm -rf "${tmp_dir}"
    return 1
  fi

  rm -rf "${tmp_dir}"
  log "校验来源：${XRAY_SELECTED_CHECKSUM_SOURCE}"
  log_success "Xray-core ${XRAY_SELECTED_TAG} 已安装到 ${XRAY_BIN}。"
}

ensure_xray_bind_capability() {
  if command -v setcap >/dev/null 2>&1; then
    setcap cap_net_bind_service=+ep "${XRAY_BIN}" || die "为 Xray 二进制设置 CAP_NET_BIND_SERVICE 失败。"
  else
    warn "系统中未找到 setcap，Xray 可能无法以普通用户绑定 443。"
  fi
}

ensure_managed_permissions() {
  [[ -n "${XRAY_UID}" && -n "${XRAY_GID}" ]] || die "尚未解析 xray 用户的 UID/GID。"

  if [[ -f "${XRAY_CONFIG_FILE}" ]]; then
    chown 0:"${XRAY_GID}" "${XRAY_CONFIG_FILE}"
    chmod 0640 "${XRAY_CONFIG_FILE}"
  fi

  if [[ -f "${WARP_RULES_FILE}" ]]; then
    chown 0:"${XRAY_GID}" "${WARP_RULES_FILE}"
    chmod 0640 "${WARP_RULES_FILE}"
  fi

  if [[ -f "${TLS_CERT_FILE}" ]]; then
    chown 0:"${XRAY_GID}" "${TLS_CERT_FILE}"
    chmod 0640 "${TLS_CERT_FILE}"
  fi

  if [[ -f "${TLS_KEY_FILE}" ]]; then
    chown 0:"${XRAY_GID}" "${TLS_KEY_FILE}"
    chmod 0640 "${TLS_KEY_FILE}"
  fi

  if [[ -d "${SSL_DIR}" ]]; then
    chown 0:"${XRAY_GID}" "${SSL_DIR}"
    chmod 0750 "${SSL_DIR}"
  fi

  if [[ -d /var/log/xray ]]; then
    chown "${XRAY_UID}:${XRAY_GID}" /var/log/xray
    chmod 0750 /var/log/xray
    if [[ -f /var/log/xray/access.log ]]; then
      chown "${XRAY_UID}:${XRAY_GID}" /var/log/xray/access.log
      chmod 0640 /var/log/xray/access.log
    fi
    if [[ -f /var/log/xray/error.log ]]; then
      chown "${XRAY_UID}:${XRAY_GID}" /var/log/xray/error.log
      chmod 0640 /var/log/xray/error.log
    fi
  fi
}

ensure_xray_user() {
  if ! id -u xray >/dev/null 2>&1; then
    useradd --system --home /var/lib/xray --create-home --shell /usr/sbin/nologin xray
  fi

  XRAY_UID="$(id -u xray)"
  XRAY_GID="$(id -g xray)"
  [[ -n "${XRAY_UID}" && -n "${XRAY_GID}" ]] || die "无法解析 xray 用户的 UID/GID。"

  mkdir -p "${XRAY_CONFIG_DIR}" "${XRAY_ASSET_DIR}"
  install -d -o "${XRAY_UID}" -g "${XRAY_GID}" -m 0750 /var/log/xray
  install -d -o 0 -g "${XRAY_GID}" -m 0750 "${SSL_DIR}"
  ensure_managed_permissions
}

generate_reality_keys_if_needed() {
  local key_output=""

  if [[ -n "${REALITY_PRIVATE_KEY}" && -n "${REALITY_PUBLIC_KEY}" ]]; then
    return
  fi

  if [[ -n "${REALITY_PRIVATE_KEY}" && -z "${REALITY_PUBLIC_KEY}" ]]; then
    key_output="$("${XRAY_BIN}" x25519 -i "${REALITY_PRIVATE_KEY}")"
    REALITY_PUBLIC_KEY="$(printf '%s\n' "${key_output}" | awk '
      /^(Password \(PublicKey\)|Public key|PublicKey):/ {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        print
        exit
      }
    ')"
    [[ -n "${REALITY_PUBLIC_KEY}" ]] || die "无法从提供的 REALITY 私钥推导公钥。"
    return
  fi

  key_output="$("${XRAY_BIN}" x25519)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "${key_output}" | awk '
    /^(Private key|PrivateKey):/ {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      print
      exit
    }
  ')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "${key_output}" | awk '
    /^(Password \(PublicKey\)|Public key|PublicKey):/ {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      print
      exit
    }
  ')"

  [[ -n "${REALITY_PRIVATE_KEY}" ]] || die "生成 REALITY 私钥失败。"
  [[ -n "${REALITY_PUBLIC_KEY}" ]] || die "生成 REALITY 公钥失败。"
}

generate_xhttp_vless_encryption_if_needed() {
  local enc_output=""
  local encryption_pair=""

  if [[ "${XHTTP_VLESS_ENCRYPTION_ENABLED}" != "yes" ]]; then
    XHTTP_VLESS_DECRYPTION=""
    XHTTP_VLESS_ENCRYPTION=""
    return
  fi

  if [[ -n "${XHTTP_VLESS_DECRYPTION}" && -n "${XHTTP_VLESS_ENCRYPTION}" ]]; then
    return
  fi

  enc_output="$("${XRAY_BIN}" vlessenc)"
  encryption_pair="$(parse_xhttp_vless_encryption_pair "${enc_output}")" || die "无法解析 XHTTP 的 VLESS Encryption 认证方案。"
  XHTTP_VLESS_DECRYPTION="$(printf '%s' "${encryption_pair}" | cut -f1)"
  XHTTP_VLESS_ENCRYPTION="$(printf '%s' "${encryption_pair}" | cut -f2)"

  [[ -n "${XHTTP_VLESS_DECRYPTION}" ]] || die "生成 XHTTP 的 VLESS decryption 失败。"
  [[ -n "${XHTTP_VLESS_ENCRYPTION}" ]] || die "生成 XHTTP 的 VLESS encryption 失败。"
}

install_draft_file_text() {
  write_state_kv "XRAY_VERSION_REQUEST" "${XRAY_VERSION_REQUEST-}"
  write_state_kv "SERVER_IP" "${SERVER_IP-}"
  write_state_kv "NODE_LABEL_PREFIX" "${NODE_LABEL_PREFIX-}"
  write_state_kv "REALITY_UUID" "${REALITY_UUID-}"
  write_state_kv "REALITY_SNI" "${REALITY_SNI-}"
  write_state_kv "REALITY_TARGET" "${REALITY_TARGET-}"
  write_state_kv "REALITY_SHORT_ID" "${REALITY_SHORT_ID-}"
  write_state_kv "REALITY_PRIVATE_KEY" "${REALITY_PRIVATE_KEY-}"
  write_state_kv "XHTTP_UUID" "${XHTTP_UUID-}"
  write_state_kv "XHTTP_DOMAIN" "${XHTTP_DOMAIN-}"
  write_state_kv "XHTTP_PATH" "${XHTTP_PATH-}"
  write_state_kv "XHTTP_VLESS_ENCRYPTION_ENABLED" "${XHTTP_VLESS_ENCRYPTION_ENABLED-}"
  write_state_kv "XHTTP_ECH_CONFIG_LIST" "${XHTTP_ECH_CONFIG_LIST-}"
  write_state_kv "XHTTP_ECH_FORCE_QUERY" "${XHTTP_ECH_FORCE_QUERY-}"
  write_state_kv "XHTTP_XPADDING_ENABLED" "${XHTTP_XPADDING_ENABLED-}"
  write_state_kv "XHTTP_XPADDING_KEY" "${XHTTP_XPADDING_KEY-}"
  write_state_kv "XHTTP_XPADDING_HEADER" "${XHTTP_XPADDING_HEADER-}"
  write_state_kv "XHTTP_XPADDING_PLACEMENT" "${XHTTP_XPADDING_PLACEMENT-}"
  write_state_kv "XHTTP_XPADDING_METHOD" "${XHTTP_XPADDING_METHOD-}"
  write_state_kv "CERT_MODE" "${CERT_MODE-}"
  write_state_kv "CERT_SOURCE_FILE" "${CERT_SOURCE_FILE-}"
  write_state_kv "KEY_SOURCE_FILE" "${KEY_SOURCE_FILE-}"
  write_state_kv "CERT_SOURCE_PEM" "${CERT_SOURCE_PEM-}"
  write_state_kv "KEY_SOURCE_PEM" "${KEY_SOURCE_PEM-}"
  write_state_kv "ACME_EMAIL" "${ACME_EMAIL-}"
  write_state_kv "ACME_CA" "${ACME_CA-}"
  write_state_kv "CF_DNS_TOKEN" "${CF_DNS_TOKEN-}"
  write_state_kv "CF_DNS_ACCOUNT_ID" "${CF_DNS_ACCOUNT_ID-}"
  write_state_kv "CF_DNS_ZONE_ID" "${CF_DNS_ZONE_ID-}"
  write_state_kv "ENABLE_WARP" "${ENABLE_WARP-}"
  write_state_kv "ENABLE_NET_OPT" "${ENABLE_NET_OPT-}"
  write_state_kv "WARP_PRIVATE_KEY" "${WARP_PRIVATE_KEY-}"
  write_state_kv "WARP_ADDRESS_V4" "${WARP_ADDRESS_V4-}"
  write_state_kv "WARP_ADDRESS_V6" "${WARP_ADDRESS_V6-}"
  write_state_kv "WARP_PEER_PUBLIC_KEY" "${WARP_PEER_PUBLIC_KEY-}"
  write_state_kv "WARP_ENDPOINT" "${WARP_ENDPOINT-}"
  write_state_kv "WARP_RESERVED" "${WARP_RESERVED-}"
  write_state_kv "WARP_MTU" "${WARP_MTU-}"
}

load_install_draft_file() {
  [[ -f "${INSTALL_DRAFT_FILE}" ]] || return 0
  load_shell_kv_file "${INSTALL_DRAFT_FILE}"
}

write_install_draft_file() {
  write_generated_file_atomically "${INSTALL_DRAFT_FILE}" install_draft_file_text || return 1
  chmod 0600 "${INSTALL_DRAFT_FILE}"
}

clear_install_draft_file() {
  rm -f "${INSTALL_DRAFT_FILE}"
}

purge_managed_packages() {
  local packages=()

  mapfile -t packages < <(managed_package_names)
  [[ "${#packages[@]}" -gt 0 ]] || return 0
  apt-get purge -y "${packages[@]}" >/dev/null 2>&1 || warn "部分软件包卸载失败，请手动检查 apt 输出。"
  apt-get autoremove -y >/dev/null 2>&1 || true
}

install_draft_session_begin() {
  INSTALL_DRAFT_SESSION_ACTIVE="1"
  trap 'install_draft_session_handle_exit "$?"' EXIT
  trap 'install_draft_session_handle_signal 130' INT
  trap 'install_draft_session_handle_signal 143' TERM
}

install_draft_session_disarm() {
  trap - EXIT INT TERM
  INSTALL_DRAFT_SESSION_ACTIVE="0"
}

install_draft_session_persist() {
  write_install_draft_file >/dev/null 2>&1 || true
}

install_draft_session_handle_exit() {
  local exit_status="${1:-0}"

  if [[ "${INSTALL_DRAFT_SESSION_ACTIVE:-0}" == "1" && "${exit_status}" -ne 0 ]]; then
    install_draft_session_persist
  fi

  install_draft_session_disarm
  return "${exit_status}"
}

install_draft_session_handle_signal() {
  local exit_status="${1}"

  if [[ "${INSTALL_DRAFT_SESSION_ACTIVE:-0}" == "1" ]]; then
    install_draft_session_persist
  fi

  install_draft_session_disarm
  exit "${exit_status}"
}

install_draft_session_abort() {
  if [[ "${INSTALL_DRAFT_SESSION_ACTIVE:-0}" == "1" ]]; then
    install_draft_session_persist
  fi

  install_draft_session_disarm
}

install_draft_session_finish() {
  clear_install_draft_file
  install_draft_session_disarm
}
. "${SCRIPT_ROOT}/lib/install/input.sh"
. "${SCRIPT_ROOT}/lib/install/self.sh"
. "${SCRIPT_ROOT}/lib/install/certs.sh"
. "${SCRIPT_ROOT}/lib/install/network.sh"
. "${SCRIPT_ROOT}/lib/install/warp.sh"
