# shellcheck shell=bash

# ------------------------------
# 证书与 TLS 资产层
# 负责证书输入、签发、校验与清理
# ------------------------------

clear_existing_cert_inputs() {
  CERT_SOURCE_FILE=""
  KEY_SOURCE_FILE=""
  CERT_SOURCE_PEM=""
  KEY_SOURCE_PEM=""
}

clear_cf_origin_ca_settings() {
  CF_ZONE_ID=""
  CF_API_TOKEN=""
  CF_CERT_VALIDITY="${DEFAULT_CF_CERT_VALIDITY}"
}

clear_acme_dns_cf_settings() {
  ACME_EMAIL=""
  ACME_CA="${DEFAULT_ACME_CA}"
  CF_DNS_TOKEN=""
  CF_DNS_ACCOUNT_ID=""
  CF_DNS_ZONE_ID=""
}

prompt_cf_origin_ca_inputs() {
  resolve_value_source CERT_SOURCE_PEM
  resolve_value_source KEY_SOURCE_PEM

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    if [[ -n "${CERT_SOURCE_FILE}" || -n "${KEY_SOURCE_FILE}" ]]; then
      [[ -n "${CERT_SOURCE_FILE}" && -n "${KEY_SOURCE_FILE}" ]] || die "cf-origin-ca 模式下，证书文件路径和私钥文件路径必须同时提供。"
      CERT_SOURCE_PEM=""
      KEY_SOURCE_PEM=""
      return
    fi

    [[ -n "${CERT_SOURCE_PEM}" && -n "${KEY_SOURCE_PEM}" ]] \
      || die "cf-origin-ca 模式下，请提供 --cert-pem/--key-pem，或 --cert-file/--key-file。"
    CERT_SOURCE_FILE=""
    KEY_SOURCE_FILE=""
    return
  fi

  CERT_SOURCE_FILE=""
  KEY_SOURCE_FILE=""
  prompt_multiline_value CERT_SOURCE_PEM "请输入 Cloudflare Origin CA 证书 PEM 内容"
  prompt_multiline_value KEY_SOURCE_PEM "请输入 Cloudflare Origin CA 私钥 PEM 内容"
}

prompt_optional_cloudflare_scope() {
  if [[ -z "${CF_DNS_ACCOUNT_ID}" && "${NON_INTERACTIVE}" -eq 0 ]]; then
    read -r -p "Cloudflare Account ID（可选）: " CF_DNS_ACCOUNT_ID
  fi
  if [[ -z "${CF_DNS_ZONE_ID}" && "${NON_INTERACTIVE}" -eq 0 ]]; then
    read -r -p "Cloudflare DNS API 使用的 Zone ID（可选）: " CF_DNS_ZONE_ID
  fi
}

prompt_acme_dns_cf_inputs() {
  prompt_with_default ACME_EMAIL "acme.sh 账户邮箱" "${ACME_EMAIL:-}"
  prompt_with_default ACME_CA "ACME CA" "${ACME_CA:-${DEFAULT_ACME_CA}}"
  prompt_secret CF_DNS_TOKEN "Cloudflare DNS API 令牌"
  prompt_optional_cloudflare_scope
}

prepare_existing_cert_inputs() {
  local input_mode=""
  local first_input=""

  resolve_value_source CERT_SOURCE_PEM
  resolve_value_source KEY_SOURCE_PEM

  if [[ -n "${CERT_SOURCE_FILE}" || -n "${KEY_SOURCE_FILE}" ]]; then
    [[ -n "${CERT_SOURCE_FILE}" && -n "${KEY_SOURCE_FILE}" ]] || die "existing 模式下，证书文件路径和私钥文件路径必须同时提供。"
    CERT_SOURCE_PEM=""
    KEY_SOURCE_PEM=""
    return
  fi

  if [[ -n "${CERT_SOURCE_PEM}" || -n "${KEY_SOURCE_PEM}" ]]; then
    [[ -n "${CERT_SOURCE_PEM}" && -n "${KEY_SOURCE_PEM}" ]] || die "existing 模式下，证书 PEM 内容和私钥 PEM 内容必须同时提供。"
    CERT_SOURCE_FILE=""
    KEY_SOURCE_FILE=""
    return
  fi

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    die "existing 模式下，请提供 --cert-file/--key-file，或 --cert-pem/--key-pem。"
  fi

  read -r -p "证书输入方式 [path/pem] [path]，也可以直接输入证书文件路径: " first_input
  input_mode="${first_input:-path}"

  case "${input_mode}" in
    path|'')
      prompt_with_default CERT_SOURCE_FILE "现有证书文件路径" ""
      prompt_with_default KEY_SOURCE_FILE "现有私钥文件路径" ""
      ;;
    pem)
      prompt_multiline_value CERT_SOURCE_PEM "请输入证书 PEM 内容"
      prompt_multiline_value KEY_SOURCE_PEM "请输入私钥 PEM 内容"
      ;;
    *)
      if [[ -f "${input_mode}" || "${input_mode}" == /* || "${input_mode}" == ./* || "${input_mode}" == ../* ]]; then
        CERT_SOURCE_FILE="${input_mode}"
        prompt_with_default KEY_SOURCE_FILE "现有私钥文件路径" ""
      else
        die "证书输入方式只能是 path、pem，或者直接输入证书文件路径。"
      fi
      ;;
  esac
}

prompt_cert_mode_inputs() {
  case "${CERT_MODE}" in
    self-signed)
      clear_existing_cert_inputs
      clear_cf_origin_ca_settings
      clear_acme_dns_cf_settings
      ;;
    existing)
      prepare_existing_cert_inputs
      clear_cf_origin_ca_settings
      clear_acme_dns_cf_settings
      ;;
    cf-origin-ca)
      prompt_cf_origin_ca_inputs
      clear_cf_origin_ca_settings
      clear_acme_dns_cf_settings
      ;;
    acme-dns-cf)
      clear_existing_cert_inputs
      clear_cf_origin_ca_settings
      prompt_acme_dns_cf_inputs
      ;;
    *)
      die "不支持的证书模式：${CERT_MODE}"
      ;;
  esac
}

write_acme_reload_helper() {
  local stage_cert_file="${1}"
  local stage_key_file="${2}"
  local tmp_file=""

  tmp_file="$(mktemp)"
  cat > "${tmp_file}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

cert_stage='${stage_cert_file}'
key_stage='${stage_key_file}'
cert_target='${TLS_CERT_FILE}'
key_target='${TLS_KEY_FILE}'

if [[ -f "\${cert_stage}" && -f "\${key_stage}" ]]; then
  openssl x509 -in "\${cert_stage}" -noout >/dev/null 2>&1 || exit 1
  openssl pkey -in "\${key_stage}" -noout >/dev/null 2>&1 || exit 1
  cert_pub_hash="\$(openssl x509 -in "\${cert_stage}" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print \$1}')"
  key_pub_hash="\$(openssl pkey -in "\${key_stage}" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print \$1}')"
  [[ -n "\${cert_pub_hash}" && "\${cert_pub_hash}" == "\${key_pub_hash}" ]] || exit 1

  chown 0:${XRAY_GID} "\${cert_stage}" "\${key_stage}" 2>/dev/null || true
  chmod 0640 "\${cert_stage}" "\${key_stage}" 2>/dev/null || true
  mv -f "\${cert_stage}" "\${cert_target}"
  mv -f "\${key_stage}" "\${key_target}"
fi

systemctl restart xray >/dev/null 2>&1 || true
systemctl restart nginx >/dev/null 2>&1 || true
EOF

  backup_path "${ACME_RELOAD_HELPER}"
  install -m 0755 "${tmp_file}" "${ACME_RELOAD_HELPER}"
  rm -f "${tmp_file}"
}

install_acme_sh() {
  local tmp_file=""

  if [[ -x "${ACME_SH_BIN}" ]]; then
    return
  fi

  [[ -n "${ACME_EMAIL}" ]] || die "acme-dns-cf 模式必须提供 ACME_EMAIL。"
  tmp_file="$(mktemp)"
  curl -fsSL https://get.acme.sh -o "${tmp_file}"
  sh "${tmp_file}" email="${ACME_EMAIL}" >/dev/null
  rm -f "${tmp_file}"
  [[ -x "${ACME_SH_BIN}" ]] || die "acme.sh 安装失败。"
}

issue_acme_cf_cert() {
  local cert_file="${1}"
  local key_file="${2}"

  [[ -n "${ACME_EMAIL}" ]] || die "acme-dns-cf 模式必须提供 ACME_EMAIL。"
  [[ -n "${CF_DNS_TOKEN}" ]] || die "acme-dns-cf 模式必须提供 CF_DNS_TOKEN。"

  install_acme_sh
  write_acme_reload_helper "${cert_file}" "${key_file}"

  unset CF_Account_ID CF_Zone_ID
  export CF_Token="${CF_DNS_TOKEN}"
  if [[ -n "${CF_DNS_ACCOUNT_ID}" ]]; then
    export CF_Account_ID="${CF_DNS_ACCOUNT_ID}"
  fi
  if [[ -n "${CF_DNS_ZONE_ID}" ]]; then
    export CF_Zone_ID="${CF_DNS_ZONE_ID}"
  fi

  "${ACME_SH_BIN}" --register-account -m "${ACME_EMAIL}" --server "${ACME_CA}" >/dev/null 2>&1 || true
  "${ACME_SH_BIN}" --issue --dns dns_cf -d "${XHTTP_DOMAIN}" --server "${ACME_CA}" --keylength ec-256
  "${ACME_SH_BIN}" --install-cert -d "${XHTTP_DOMAIN}" \
    --ecc \
    --key-file "${key_file}" \
    --fullchain-file "${cert_file}" \
    --reloadcmd "${ACME_RELOAD_HELPER}"
}

validate_tls_assets_with_paths() {
  local cert_file="${1}"
  local key_file="${2}"
  local cert_pub_hash=""
  local key_pub_hash=""

  openssl x509 -in "${cert_file}" -noout >/dev/null 2>&1 || die "写入后的证书内容无效：${cert_file}"
  openssl pkey -in "${key_file}" -noout >/dev/null 2>&1 || die "写入后的私钥内容无效：${key_file}"

  cert_pub_hash="$(openssl x509 -in "${cert_file}" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  key_pub_hash="$(openssl pkey -in "${key_file}" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"

  [[ -n "${cert_pub_hash}" && -n "${key_pub_hash}" ]] || die "无法校验证书与私钥是否匹配。"
  [[ "${cert_pub_hash}" == "${key_pub_hash}" ]] || die "证书与私钥不匹配，请检查输入内容。"
}

validate_tls_assets() {
  validate_tls_assets_with_paths "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"
}

self_signed_tls_config() {
  cat <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = ${XHTTP_DOMAIN}

[v3_req]
subjectAltName = @alt_names
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = ${XHTTP_DOMAIN}
EOF
}

write_existing_tls_assets() {
  local cert_file="${1}"
  local key_file="${2}"

  if [[ -n "${CERT_SOURCE_FILE}" || -n "${KEY_SOURCE_FILE}" ]]; then
    [[ -f "${CERT_SOURCE_FILE}" ]] || die "找不到证书文件：${CERT_SOURCE_FILE}"
    [[ -f "${KEY_SOURCE_FILE}" ]] || die "找不到私钥文件：${KEY_SOURCE_FILE}"

    install -o 0 -g "${XRAY_GID}" -m 0640 "${CERT_SOURCE_FILE}" "${cert_file}"
    install -o 0 -g "${XRAY_GID}" -m 0640 "${KEY_SOURCE_FILE}" "${key_file}"
    return
  fi

  [[ -n "${CERT_SOURCE_PEM}" ]] || die "existing 模式下缺少证书 PEM 内容。"
  [[ -n "${KEY_SOURCE_PEM}" ]] || die "existing 模式下缺少私钥 PEM 内容。"

  printf '%s\n' "${CERT_SOURCE_PEM}" > "${cert_file}"
  printf '%s\n' "${KEY_SOURCE_PEM}" > "${key_file}"
  chmod 0640 "${cert_file}" "${key_file}"
}

write_self_signed_tls_assets() {
  local cert_file="${1}"
  local key_file="${2}"
  local tls_config=""

  tls_config="$(mktemp)"
  self_signed_tls_config > "${tls_config}"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "${key_file}" \
    -out "${cert_file}" \
    -config "${tls_config}" >/dev/null 2>&1
  rm -f "${tls_config}"
  chmod 0640 "${cert_file}" "${key_file}"
}

tls_stage_cert_file() {
  printf '%s/.cert.pem.stage' "${SSL_DIR}"
}

tls_stage_key_file() {
  printf '%s/.key.pem.stage' "${SSL_DIR}"
}

cleanup_tls_stage_files() {
  rm -f "${1}" "${2}"
}

promote_tls_assets() {
  local cert_file="${1}"
  local key_file="${2}"

  chown 0:"${XRAY_GID}" "${cert_file}" "${key_file}"
  chmod 0640 "${cert_file}" "${key_file}"
  mv -f "${cert_file}" "${TLS_CERT_FILE}"
  mv -f "${key_file}" "${TLS_KEY_FILE}"
}

write_tls_assets() {
  local stage_cert_file=""
  local stage_key_file=""

  mkdir -p "${SSL_DIR}"
  backup_path "${TLS_CERT_FILE}"
  backup_path "${TLS_KEY_FILE}"
  stage_cert_file="$(tls_stage_cert_file)"
  stage_key_file="$(tls_stage_key_file)"
  cleanup_tls_stage_files "${stage_cert_file}" "${stage_key_file}"
  trap 'cleanup_tls_stage_files "${stage_cert_file}" "${stage_key_file}"' RETURN EXIT

  case "${CERT_MODE}" in
    existing)
      write_existing_tls_assets "${stage_cert_file}" "${stage_key_file}"
      ;;
    cf-origin-ca)
      write_existing_tls_assets "${stage_cert_file}" "${stage_key_file}"
      ;;
    acme-dns-cf)
      issue_acme_cf_cert "${stage_cert_file}" "${stage_key_file}"
      ;;
    *)
      write_self_signed_tls_assets "${stage_cert_file}" "${stage_key_file}"
      ;;
  esac

  if [[ -f "${stage_cert_file}" && -f "${stage_key_file}" ]]; then
    validate_tls_assets_with_paths "${stage_cert_file}" "${stage_key_file}"
    promote_tls_assets "${stage_cert_file}" "${stage_key_file}"
  fi

  ensure_managed_permissions
  validate_tls_assets

  trap - RETURN EXIT
}

cleanup_previous_acme_cert() {
  local old_cert_mode="${1:-}"
  local old_xhttp_domain="${2:-}"

  if [[ "${old_cert_mode}" == "acme-dns-cf" && -x "${ACME_SH_BIN}" && -n "${old_xhttp_domain}" ]]; then
    if [[ "${CERT_MODE}" != "acme-dns-cf" || "${XHTTP_DOMAIN}" != "${old_xhttp_domain}" ]]; then
      "${ACME_SH_BIN}" --remove -d "${old_xhttp_domain}" --ecc >/dev/null 2>&1 || true
    fi
  fi
}
