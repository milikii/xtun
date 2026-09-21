# shellcheck shell=bash

# ------------------------------
# 证书与 TLS 资产层
# 负责证书输入、签发、校验与清理
# ------------------------------

# 使用发行版随 ca-certificates 提供的 Mozilla 根，不接受管理员另外导入的
# /usr/local/share/ca-certificates（Origin CA / 私有 CA 不等于客户端公共信任）。
certificate_public_trust_roots() {
  local root="" found=0
  for root in /usr/share/ca-certificates/mozilla/*.crt; do
    [[ -r "${root}" ]] || continue
    cat "${root}" || return 1
    found=1
  done
  [[ "${found}" -eq 1 ]]
}

certificate_origin_trust_roots() {
  cat "${SCRIPT_ROOT}/static/certificates/cloudflare-origin-ca-rsa.pem" \
    "${SCRIPT_ROOT}/static/certificates/cloudflare-origin-ca-ecc.pem"
}

# 只读，输出 state|原因；不写临时证书、不加载私有信任、不联网补中间链。
# ready 只证明本机按公共根校验通过，不代表每个客户端的信任库或公网路径通过。
certificate_capability_report() {
  local cert="${1}" key="${2}" hostname="${3}"
  local cert_key="" private_key="" san="" subject="" issuer="" result="" roots=""
  if ! command -v openssl >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
    printf 'unverified|缺少 openssl/sha256sum，证书能力未验证'
    return
  fi
  if [[ ! -r "${cert}" || ! -r "${key}" || -z "${hostname}" ]]; then
    printf 'unverified|证书、私钥或域名尚未就绪'
    return
  fi
  if ! cert_key="$(openssl x509 -in "${cert}" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum)" \
    || ! private_key="$(openssl pkey -in "${key}" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum)"; then
    printf 'invalid|证书或私钥无法解析（不支持交互解密私钥）'
    return
  fi
  if [[ "${cert_key}" != "${private_key}" ]]; then
    printf 'mismatch|证书与私钥不匹配'
    return
  fi
  san="$(openssl x509 -in "${cert}" -noout -ext subjectAltName 2>/dev/null)" || {
    printf 'unverified|当前 openssl 无法读取证书 SAN'; return;
  }
  if [[ "${san}" != *DNS:* ]]; then
    printf 'hostname|证书缺少 DNS subjectAltName'
    return
  fi
  # 先只以叶证书作信任锚核对名称、时间及服务器用途，再单独核对公共信任链。
  if ! result="$(openssl verify -trusted "${cert}" -partial_chain -purpose sslserver \
      -verify_hostname "${hostname}" "${cert}" 2>&1)"; then
    case "${result}" in
      *'error 62 '*) printf 'hostname|证书 SAN 不匹配 XHTTP 域名' ;;
      *'error 10 '*) printf 'expired|证书或证书链已经过期' ;;
      *'error 9 '*) printf 'not-yet-valid|证书或证书链尚未生效' ;;
      *'error 26 '*) printf 'purpose|证书不适用于 TLS 服务器认证' ;;
      *) printf 'invalid|证书名称、有效期或用途校验失败' ;;
    esac
    return
  fi
  subject="$(openssl x509 -in "${cert}" -noout -subject -nameopt RFC2253 2>/dev/null)"
  issuer="$(openssl x509 -in "${cert}" -noout -issuer -nameopt RFC2253 2>/dev/null)"
  if [[ "${subject#subject=}" == "${issuer#issuer=}" ]]; then
    if ! openssl verify -check_ss_sig -trusted "${cert}" "${cert}" >/dev/null 2>&1; then
      printf 'invalid|自签证书签名校验失败'; return
    fi
    printf 'self-signed|自签证书不能证明客户端公共信任'
    return
  fi
  if roots="$(certificate_origin_trust_roots)" && [[ -n "${roots}" ]] \
    && openssl verify -trusted <(printf '%s\n' "${roots}") -untrusted "${cert}" \
      -purpose sslserver -verify_hostname "${hostname}" "${cert}" >/dev/null 2>&1; then
    printf 'origin-ca|Cloudflare Origin CA 链检查通过，仅用于回源，不是终端直连公共信任证书'
    return
  fi
  if ! roots="$(certificate_public_trust_roots)" || [[ -z "${roots}" ]]; then
    printf 'unverified|没有可用的发行版 Mozilla 公共根，信任未验证'
    return
  fi
  if ! result="$(openssl verify -trusted <(printf '%s\n' "${roots}") -untrusted "${cert}" \
      -purpose sslserver -verify_hostname "${hostname}" "${cert}" 2>&1)"; then
    case "${result}" in
      *'error 10 '*) printf 'expired|证书链已经过期' ;;
      *'error 9 '*) printf 'not-yet-valid|证书链尚未生效' ;;
      *'error 20 '*|*'error 21 '*|*'error 19 '*|*'error 18 '*)
        printf 'untrusted|证书链不受公共根信任（缺中间证书、私有 CA 或未知信任）' ;;
      *) printf 'unverified|公共信任链校验失败，未证明客户端信任' ;;
    esac
    return
  fi
  printf 'ready|密钥、SAN、有效期、服务器用途及公共信任链检查通过'
}

clear_existing_cert_inputs() {
  CERT_SOURCE_FILE=""
  KEY_SOURCE_FILE=""
  CERT_SOURCE_PEM=""
  KEY_SOURCE_PEM=""
}

clear_acme_dns_cf_settings() {
  ACME_EMAIL=""
  ACME_CA="${DEFAULT_ACME_CA}"
  CF_DNS_TOKEN=""
  CF_DNS_ACCOUNT_ID=""
  CF_DNS_ZONE_ID=""
}

prompt_optional_cloudflare_scope() {
  if [[ -z "${CF_DNS_ACCOUNT_ID}" && "${NON_INTERACTIVE}" -eq 0 ]]; then
    read_line_or_cancel CF_DNS_ACCOUNT_ID "Cloudflare Account ID（可选）: " || return $?
  fi
  if [[ -z "${CF_DNS_ZONE_ID}" && "${NON_INTERACTIVE}" -eq 0 ]]; then
    read_line_or_cancel CF_DNS_ZONE_ID "Cloudflare DNS API 使用的 Zone ID（可选）: " || return $?
  fi
}

prompt_acme_dns_cf_inputs() {
  prompt_validated_value ACME_EMAIL "acme.sh 账户邮箱" "${ACME_EMAIL:-}" ensure_acme_email_format || return $?
  prompt_with_default ACME_CA "ACME CA" "${ACME_CA:-${DEFAULT_ACME_CA}}" || return $?
  prompt_secret CF_DNS_TOKEN "Cloudflare DNS API 令牌" || return $?
  prompt_optional_cloudflare_scope
}

# ACME 家族的共同点：公网 CA 签发、必须过公共信任链、证书落在 ACME_HOME、换证/卸载要清理。
# 区别只在"怎么证明域名所有权"：acme-dns-cf 走 Cloudflare API 写 TXT，acme-http 走 80 端口。
# 只判"是不是 ACME"，避免每加一种校验方式就到十来个地方补 `||`。
cert_mode_is_acme() {
  case "${1:-${CERT_MODE:-}}" in
    acme-dns-cf|acme-http) return 0 ;;
    *) return 1 ;;
  esac
}

# HTTP-01：不需要 DNS 令牌，但要域名解析到本机、80 端口可达（见 preflight 与签发时的复核）。
prompt_acme_http_inputs() {
  prompt_validated_value ACME_EMAIL "acme.sh 账户邮箱" "${ACME_EMAIL:-}" ensure_acme_email_format || return $?
  prompt_with_default ACME_CA "ACME CA" "${ACME_CA:-${DEFAULT_ACME_CA}}" || return $?
  # 从 DNS 模式切过来时把令牌清掉，避免继续留在 state 里。
  CF_DNS_TOKEN=""
  CF_DNS_ACCOUNT_ID=""
  CF_DNS_ZONE_ID=""
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

  # 一次输入同时承担「选输入方式」和「给证书路径」：这条路是首次安装最常见的，
  # 多问一次「path 还是 pem」就多占一次必要输入（D06 的 8 次上限）。
  # 私钥路径默认跟证书同一个目录，回车即可。
  prompt_with_default CERT_SOURCE_FILE "证书文件路径（输入 pem 改为粘贴 PEM）" "${TLS_CERT_FILE}" || return $?
  first_input="${CERT_SOURCE_FILE}"

  case "${first_input}" in
    '')
      CERT_SOURCE_FILE="${TLS_CERT_FILE}"
      prompt_with_default KEY_SOURCE_FILE "现有私钥文件路径" "${TLS_KEY_FILE}" || return $?
      ;;
    pem)
      CERT_SOURCE_FILE=""
      prompt_multiline_value CERT_SOURCE_PEM "请输入证书 PEM 内容" || return $?
      prompt_multiline_value KEY_SOURCE_PEM "请输入私钥 PEM 内容" || return $?
      ;;
    *)
      if [[ -f "${first_input}" || "${first_input}" == /* || "${first_input}" == ./* || "${first_input}" == ../* ]]; then
        CERT_SOURCE_FILE="${first_input}"
        prompt_with_default KEY_SOURCE_FILE "现有私钥文件路径" "${TLS_KEY_FILE}" || return $?
      else
        die "证书输入方式只能是 path、pem，或者直接输入证书文件路径。"
      fi
      ;;
  esac
}

# 只读检查：existing 模式下证书/私钥必须存在且可读。
# 缺文件要在这里（确认前）就说清楚，不能等写完托管配置才发现（D07）。
# 原因用返回字符串的方式给出来（不 die），这样问答阶段可以在命令替换里取到它，
# 而 die 的版本留给预检和 validate。
cert_input_files_readonly_reason() {
  case "${CERT_MODE:-}" in
    existing) ;;
    *) return 0 ;;
  esac

  if [[ -n "${CERT_SOURCE_PEM}" || -n "${KEY_SOURCE_PEM}" ]]; then
    [[ -n "${CERT_SOURCE_PEM}" && -n "${KEY_SOURCE_PEM}" ]] \
      || printf 'existing 模式下，证书 PEM 内容和私钥 PEM 内容必须同时提供。'
    return 0
  fi

  if [[ -z "${CERT_SOURCE_FILE}" ]]; then
    printf 'existing 模式必须提供证书文件路径。'
  elif [[ -z "${KEY_SOURCE_FILE}" ]]; then
    printf 'existing 模式必须提供私钥文件路径。'
  elif [[ ! -f "${CERT_SOURCE_FILE}" ]]; then
    printf '证书文件不存在：%s' "${CERT_SOURCE_FILE}"
  elif [[ ! -r "${CERT_SOURCE_FILE}" ]]; then
    printf '证书文件不可读：%s' "${CERT_SOURCE_FILE}"
  elif [[ ! -f "${KEY_SOURCE_FILE}" ]]; then
    printf '私钥文件不存在：%s' "${KEY_SOURCE_FILE}"
  elif [[ ! -r "${KEY_SOURCE_FILE}" ]]; then
    printf '私钥文件不可读：%s' "${KEY_SOURCE_FILE}"
  fi
  return 0
}

cert_input_files_readonly_check() {
  local reason=""

  reason="$(cert_input_files_readonly_reason)"
  [[ -z "${reason}" ]] || die "${reason}"
}

prompt_cert_mode_inputs() {
  case "${CERT_MODE}" in
    self-signed)
      clear_existing_cert_inputs
      clear_acme_dns_cf_settings
      ;;
    existing)
      prepare_existing_cert_inputs
      clear_acme_dns_cf_settings
      ;;
    acme-dns-cf)
      clear_existing_cert_inputs
      prompt_acme_dns_cf_inputs
      ;;
    acme-http)
      clear_existing_cert_inputs
      prompt_acme_http_inputs
      ;;
    *)
      die "不支持的证书模式：${CERT_MODE}"
      ;;
  esac
}

write_acme_reload_helper() {
  local tmp_file=""
  tmp_file="$(mktemp)" || return 1
  # 只保存入口和域名；回调复用当前安装的锁、校验、generation 与服务验证。
  # 路径用 Bash %q 编码，不能把文件名当成 Shell 程序拼接。
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
    printf 'exec bash %q acme-deploy --domain %q\n' "${SELF_INSTALL_DIR}/xtun.sh" "${XHTTP_DOMAIN}"
  } > "${tmp_file}" || { rm -f "${tmp_file}"; return 1; }
  if ! backup_path "${ACME_RELOAD_HELPER}" || ! install -m 0755 "${tmp_file}" "${ACME_RELOAD_HELPER}"; then
    rm -f "${tmp_file}"; return 1
  fi
  rm -f "${tmp_file}"
}

install_acme_sh() {
  local tmp_file=""

  if [[ -x "${ACME_SH_BIN}" ]]; then
    return
  fi

  [[ -n "${ACME_EMAIL}" ]] || die "ACME 模式必须提供 ACME_EMAIL。"
  tmp_file="$(mktemp)" || return 1
  if ! curl -fsSL --connect-timeout 10 --max-time 60 https://get.acme.sh -o "${tmp_file}" \
    || ! sh "${tmp_file}" email="${ACME_EMAIL}" >/dev/null; then
    rm -f "${tmp_file}"; return 1
  fi
  rm -f "${tmp_file}"
  [[ -x "${ACME_SH_BIN}" ]] || die "acme.sh 安装失败。"
}

acme_stage_cert_file() { printf '%s/.acme-stage/cert.pem' "${SSL_DIR}"; }
acme_stage_key_file() { printf '%s/.acme-stage/key.pem' "${SSL_DIR}"; }

# acme.sh may log a reload error and still return 0. The deferred callback must
# acknowledge this operation's nonce and the exact two staged files.
acme_deferred_receipt_valid() {
  local cert_digest="" key_digest=""
  cert_digest="$(identity_file_sha256 "$(acme_stage_cert_file)")" || return 1
  key_digest="$(identity_file_sha256 "$(acme_stage_key_file)")" || return 1
  jq -e --arg nonce "${1}" --arg domain "${XHTTP_DOMAIN}" --arg cert "${cert_digest}" --arg key "${key_digest}" \
    '.nonce == $nonce and .domain == $domain and .cert_sha256 == $cert and .key_sha256 == $key' \
    "${BACKUP_DIR}/acme-deferred.json" >/dev/null 2>&1
}

# 环境只传给独立 ACME/回调进程；故意不污染父操作。
# shellcheck disable=SC2030,SC2031
issue_acme_cf_cert() {
  local cert_file="${1}" key_file="${2}" nonce="" status=0
  [[ -n "${ACME_EMAIL}" ]] || { warn "acme-dns-cf 模式必须提供 ACME_EMAIL。"; return 1; }
  [[ -n "${CF_DNS_TOKEN}" ]] || { warn "acme-dns-cf 模式必须提供 CF_DNS_TOKEN。"; return 1; }
  [[ "${GENERATION_ACTIVE:-no}" == yes && "${SCRIPT_LOCK_HELD:-0}" -eq 1 ]] || return 1
  install_acme_sh || return 1
  write_acme_reload_helper || return 1
  install -d -m 0700 "${SSL_DIR}/.acme-stage" || return 1
  nonce="$(cat /proc/sys/kernel/random/uuid)" || return 1
  rm -f "${BACKUP_DIR}/acme-deferred.json" || return 1
  (
    # 限定到本次子进程，避免下一次维护继承令牌或回调上下文。
    unset CF_Account_ID CF_Zone_ID
    export CF_Token="${CF_DNS_TOKEN}"
    if [[ -n "${CF_DNS_ACCOUNT_ID}" ]]; then export CF_Account_ID="${CF_DNS_ACCOUNT_ID}"; fi
    if [[ -n "${CF_DNS_ZONE_ID}" ]]; then export CF_Zone_ID="${CF_DNS_ZONE_ID}"; fi
    export XTUN_ACME_DEFER_OPERATION="${BACKUP_DIR}" XTUN_ACME_DEFER_NONCE="${nonce}"
    export XTUN_LOCK_FILE="${SCRIPT_LOCK_FILE}"
    "${ACME_SH_BIN}" --register-account -m "${ACME_EMAIL}" --server "${ACME_CA}" || exit 1
    "${ACME_SH_BIN}" --issue --dns dns_cf -d "${XHTTP_DOMAIN}" --server "${ACME_CA}" --keylength ec-256 \
      --key-file "$(acme_stage_key_file)" --fullchain-file "$(acme_stage_cert_file)" \
      --reloadcmd "${ACME_RELOAD_HELPER}" || status=$?
    # acme.sh 3.1.1: RENEW_SKIP=2 means the existing certificate is not due.
    [[ "${status}" -eq 0 || "${status}" -eq 2 ]] || exit "${status}"
    if [[ "${status}" -eq 2 ]]; then log "ACME 尚未到轮换日期，将重新校验和部署现有证书。"; fi
    rm -f "${BACKUP_DIR}/acme-deferred.json" || exit 1
    "${ACME_SH_BIN}" --install-cert -d "${XHTTP_DOMAIN}" --ecc \
      --key-file "$(acme_stage_key_file)" --fullchain-file "$(acme_stage_cert_file)" \
      --reloadcmd "${ACME_RELOAD_HELPER}" || exit 1
  ) || return 1
  acme_deferred_receipt_valid "${nonce}" || {
    warn "ACME 回调未确认本次证书，未把外层返回成功当作部署成功。"; return 1;
  }
  copy_acme_stage_pair "${cert_file}" "${key_file}" || return 1
}

# HTTP-01：不需要 DNS 令牌，但要求域名解析到本机且 80 端口可达。
# acme.sh 的 standalone 在签发与续期时都要占用 80；xtun 自己的 nginx（以及发行版默认站点）
# 也听 80，所以用 pre/post hook 让 nginx 在挑战窗口内让位。acme.sh 的成功与失败路径都会执行
# post-hook（_on_issue_success / _on_issue_err 都处理它），不会把 nginx 停在关闭状态。
# shellcheck disable=SC2030,SC2031
issue_acme_http_cert() {
  local cert_file="${1}" key_file="${2}" nonce="" status=0 resolved_ip=""

  [[ -n "${ACME_EMAIL}" ]] || { warn "acme-http 模式必须提供 ACME_EMAIL。"; return 1; }
  [[ "${GENERATION_ACTIVE:-no}" == yes && "${SCRIPT_LOCK_HELD:-0}" -eq 1 ]] || return 1
  command -v socat >/dev/null 2>&1 \
    || { warn "acme-http 模式需要 socat（acme.sh standalone）；请重新执行 install 补齐依赖。"; return 1; }
  resolved_ip="$(getent ahostsv4 "${XHTTP_DOMAIN}" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  if [[ -z "${resolved_ip}" ]]; then
    warn "acme-http 模式要求 ${XHTTP_DOMAIN} 解析到本机，当前无法解析。"; return 1
  fi
  if [[ -n "${SERVER_IP:-}" && "${resolved_ip}" != "${SERVER_IP}" ]]; then
    # 解析到别的地址可能是 Cloudflare 等代理；挑战能否转发到本机只有真签一次才知道，
    # 这里只告警，失败由外层如实回退。
    warn "acme-http：${XHTTP_DOMAIN} 解析为 ${resolved_ip}（不是本机 ${SERVER_IP}），按代理场景继续尝试。"
  fi
  install_acme_sh || return 1
  write_acme_reload_helper || return 1
  install -d -m 0700 "${SSL_DIR}/.acme-stage" || return 1
  nonce="$(cat /proc/sys/kernel/random/uuid)" || return 1
  rm -f "${BACKUP_DIR}/acme-deferred.json" || return 1
  (
    export XTUN_ACME_DEFER_OPERATION="${BACKUP_DIR}" XTUN_ACME_DEFER_NONCE="${nonce}"
    export XTUN_LOCK_FILE="${SCRIPT_LOCK_FILE}"
    "${ACME_SH_BIN}" --register-account -m "${ACME_EMAIL}" --server "${ACME_CA}" || exit 1
    "${ACME_SH_BIN}" --issue --standalone -d "${XHTTP_DOMAIN}" --server "${ACME_CA}" --keylength ec-256 \
      --pre-hook "systemctl stop nginx >/dev/null 2>&1 || true" \
      --post-hook "systemctl start nginx >/dev/null 2>&1 || true" \
      --key-file "$(acme_stage_key_file)" --fullchain-file "$(acme_stage_cert_file)" \
      --reloadcmd "${ACME_RELOAD_HELPER}" || status=$?
    # acme.sh 3.1.1: RENEW_SKIP=2 means the existing certificate is not due.
    [[ "${status}" -eq 0 || "${status}" -eq 2 ]] || exit "${status}"
    if [[ "${status}" -eq 2 ]]; then log "ACME 尚未到轮换日期，将重新校验和部署现有证书。"; fi
    rm -f "${BACKUP_DIR}/acme-deferred.json" || exit 1
    "${ACME_SH_BIN}" --install-cert -d "${XHTTP_DOMAIN}" --ecc \
      --key-file "$(acme_stage_key_file)" --fullchain-file "$(acme_stage_cert_file)" \
      --reloadcmd "${ACME_RELOAD_HELPER}" || exit 1
  ) || return 1
  acme_deferred_receipt_valid "${nonce}" || {
    warn "ACME 回调未确认本次证书，未把外层返回成功当作部署成功。"; return 1;
  }
  copy_acme_stage_pair "${cert_file}" "${key_file}" || return 1
}

validate_tls_assets_with_paths() {
  local report="" capability=""
  report="$(certificate_capability_report "${1}" "${2}" "${XHTTP_DOMAIN}")" || return 1
  capability="${report%%|*}"
  case "${capability}" in
    ready) ;;
    origin-ca|self-signed)
      if cert_mode_is_acme; then
        warn "ACME 候选必须通过公共信任链校验：${report#*|}"; return 1
      fi ;;
    *) warn "候选证书校验失败：${report#*|}"; return 1 ;;
  esac
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
  self_signed_tls_config > "${tls_config}" || { rm -f "${tls_config}"; return 1; }
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "${key_file}" \
    -out "${cert_file}" \
    -config "${tls_config}" >/dev/null 2>&1 || { rm -f "${tls_config}"; return 1; }
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

  chown 0:"${XRAY_GID}" "${cert_file}" "${key_file}" || return 1
  chmod 0640 "${cert_file}" "${key_file}" || return 1
  [[ ! -L "${TLS_CERT_FILE}" && ! -L "${TLS_KEY_FILE}" ]] || return 1
  sync_required_path "${cert_file}" || return 1
  sync_required_path "${key_file}" || return 1
  mv -fT -- "${cert_file}" "${TLS_CERT_FILE}" || return 1
  mv -fT -- "${key_file}" "${TLS_KEY_FILE}" || return 1
  sync_required_path "${SSL_DIR}" || return 1
}

# 签发/导入暂存证书并把它顶上去。所有失败都靠 return 传出去，暂存文件的清理
# 交给 write_tls_assets 统一做——这里不要再挂 RETURN trap，原因见下面那段注释。
stage_and_promote_tls_assets() {
  local stage_cert_file="${1}"
  local stage_key_file="${2}"

  case "${CERT_MODE}" in
    existing)
      write_existing_tls_assets "${stage_cert_file}" "${stage_key_file}" || return 1
      ;;
    acme-dns-cf)
      issue_acme_cf_cert "${stage_cert_file}" "${stage_key_file}" || return 1
      ;;
    acme-http)
      issue_acme_http_cert "${stage_cert_file}" "${stage_key_file}" || return 1
      ;;
    self-signed)
      write_self_signed_tls_assets "${stage_cert_file}" "${stage_key_file}" || return 1
      ;;
    *)
      die "不支持的证书模式：${CERT_MODE}"
      ;;
  esac

  # 签发/导入这一步没产出暂存文件就必须失败退出：再往下走 validate_tls_assets 校验的
  # 是磁盘上那份旧证书，它当然是好的，于是「换证书失败」会被报成换证书成功。
  [[ -f "${stage_cert_file}" && -f "${stage_key_file}" ]] || return 1
  validate_tls_assets_with_paths "${stage_cert_file}" "${stage_key_file}" || return 1
  h3_prepare_generation "${stage_cert_file}" "${stage_key_file}" || return 1
  promote_tls_assets "${stage_cert_file}" "${stage_key_file}" || return 1
}

write_tls_assets() {
  local stage_cert_file=""
  local stage_key_file=""
  local status=0

  mkdir -p "${SSL_DIR}" || return 1
  backup_path "${TLS_CERT_FILE}" || return 1
  backup_path "${TLS_KEY_FILE}" || return 1
  stage_cert_file="$(tls_stage_cert_file)"
  stage_key_file="$(tls_stage_key_file)"
  cleanup_tls_stage_files "${stage_cert_file}" "${stage_key_file}"

  # 这里以前挂的是 `trap '清理' RETURN`。RETURN trap 不会随本函数返回而消失：
  # 它会跟着调用栈继续往上，调用方返回时再触发一次，而那时 stage_cert_file 已经
  # 随本函数的局部作用域一起没了，set -u 当场把整个进程打死——
  # "stage_cert_file: unbound variable"，install / change-cert-mode / renew-cert
  # 在 apply_managed_files 返回的那一刻断在半路。
  # 测试没抓到是因为三处调用都写成 `( write_tls_assets )`，泄漏被子 shell 挡住了。
  # 改成显式接住退出码再清理，不留 trap。
  # die 路径上仍然会残留暂存文件（die 是 exit，本来 trap 也不触发），
  # 但文件名固定、每次进函数先清一遍，下一次证书操作就会覆盖清理。
  stage_and_promote_tls_assets "${stage_cert_file}" "${stage_key_file}" || status=$?
  cleanup_tls_stage_files "${stage_cert_file}" "${stage_key_file}"
  [[ "${status}" -eq 0 ]] || return "${status}"

  ensure_managed_permissions tls || return 1
  validate_tls_assets
}

cleanup_previous_acme_cert() {
  local old_cert_mode="${1:-}"
  local old_xhttp_domain="${2:-}"

  if cert_mode_is_acme "${old_cert_mode}" && [[ -x "${ACME_SH_BIN}" ]] && [[ -n "${old_xhttp_domain}" ]]; then
    if ! cert_mode_is_acme || [[ "${XHTTP_DOMAIN}" != "${old_xhttp_domain}" ]]; then
      "${ACME_SH_BIN}" --remove -d "${old_xhttp_domain}" --ecc >/dev/null 2>&1 || true
    fi
  fi
}

# ACME 写入独立收件目录；复制前后都核对摘要，拒绝半份/并发变化的输入。
copy_acme_stage_pair() {
  local cert="" key="" before="" after=""
  cert="$(acme_stage_cert_file)"; key="$(acme_stage_key_file)"
  before="$(identity_file_sha256 "${cert}"):$(identity_file_sha256 "${key}")" || return 1
  [[ "${before}" =~ ^[a-f0-9]{64}:[a-f0-9]{64}$ ]] || return 1
  install -m 0600 -- "${cert}" "${1}" || return 1
  install -m 0600 -- "${key}" "${2}" || return 1
  after="$(identity_file_sha256 "${cert}"):$(identity_file_sha256 "${key}")" || return 1
  [[ "${before}" == "${after}" && "${before}" == "$(identity_file_sha256 "${1}"):$(identity_file_sha256 "${2}")" ]]
}

certificate_fingerprint() {
  openssl x509 -in "${1}" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
}

served_certificate_fingerprint() {
  local certificate=""
  certificate="$(timeout 4 openssl s_client -connect "127.0.0.1:${NGINX_TLS_PORT}" \
    -servername "${XHTTP_DOMAIN}" -showcerts </dev/null 2>/dev/null)" || return 1
  openssl x509 -outform DER <<< "${certificate}" 2>/dev/null | sha256sum | awk '{print $1}'
}

verify_served_tls_assets() {
  local expected="" actual="" attempt=0
  expected="$(certificate_fingerprint "${TLS_CERT_FILE}")" || return 1
  for attempt in 1 2 3 4; do
    if actual="$(served_certificate_fingerprint)" && [[ "${actual}" == "${expected}" ]]; then return 0; fi
    sleep 0.2
  done
  warn "nginx 实际提供的证书未匹配候选证书，未确认部署成功。"
  return 1
}

write_certificate_receipt() {
  local temporary="" fingerprint="" report=""
  fingerprint="$(certificate_fingerprint "${TLS_CERT_FILE}")" || return 1
  report="$(certificate_capability_report "${TLS_CERT_FILE}" "${TLS_KEY_FILE}" "${XHTTP_DOMAIN}")" || return 1
  temporary="$(mktemp "${SSL_DIR}/.certificate.XXXXXX")" || return 1
  if ! jq -n --arg domain "${XHTTP_DOMAIN}" --arg fingerprint "${fingerprint}" --arg capability "${report%%|*}" \
    --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg operation "${BACKUP_DIR}" \
    '{schema:1,domain:$domain,sha256:$fingerprint,capability:$capability,served_verified_at:$at,operation:$operation}' \
    > "${temporary}" || ! durable_replace_file "${temporary}" "${SSL_DIR}/.xtun-certificate.json"; then
    rm -f "${temporary}"; return 1
  fi
}

certificate_next_renewal() {
  local conf="${ACME_HOME}/${XHTTP_DOMAIN}_ecc/${XHTTP_DOMAIN}.conf"
  cert_mode_is_acme && [[ -f "${conf}" ]] || return 0
  # acme.sh 的配置是 Shell；这里只读数字，不 source 邮箱、令牌或其它程序。
  awk -F= '$1 == "Le_NextRenewTime" {v=$2; gsub(/[\047\042]/,"",v); if (v ~ /^[0-9]+$/) print v}' "${conf}" | tail -n 1
}

certificate_record_event() {
  local temporary="" target="${OP_LOG_DIR}/certificate.json"
  if ! (umask 077; mkdir -p "${OP_LOG_DIR}") || ! temporary="$(mktemp "${OP_LOG_DIR}/.certificate.XXXXXX")"; then
    warn "证书操作记录无法写入；请保存本次终端结果。"; return 0
  fi
  if ! jq -n --arg trigger "${1}" --arg result "${2}" --arg detail "${3:-}" \
    --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg domain "${XHTTP_DOMAIN:-}" \
    --arg next "$(certificate_next_renewal)" --arg operation "${BACKUP_DIR:-}" \
    '{schema:1,trigger:$trigger,result:$result,detail:$detail,at:$at,domain:$domain,next_renewal_epoch:$next,operation:$operation}' \
    > "${temporary}" || ! durable_replace_file "${temporary}" "${target}"; then
    rm -f "${temporary}"; warn "证书操作记录未能持久化；请保存本次终端结果。"
  fi
  return 0
}

certificate_last_event_text() {
  local target="${OP_LOG_DIR}/certificate.json"
  [[ -f "${target}" && ! -L "${target}" ]] || { printf '无已保存记录'; return; }
  jq -er '.at + " " + .trigger + " / " + .result +
    (if .next_renewal_epoch == "" then "" else "；ACME 下次检查时间戳 " + .next_renewal_epoch end)' \
    "${target}" 2>/dev/null || printf '记录不可读'
}

# 同域名换证只改证书相关 state 字段，旧参数修订、身份及未识别键保持原样。
certificate_state_text() {
  local key=""
  if [[ ! -f "${STATE_FILE}" ]]; then state_file_text || return 1; return; fi
  awk '!/^(CERT_MODE|ACME_EMAIL|ACME_CA|CF_DNS_ACCOUNT_ID|CF_DNS_ZONE_ID)=/' "${STATE_FILE}" || return 1
  for key in CERT_MODE ACME_EMAIL ACME_CA CF_DNS_ACCOUNT_ID CF_DNS_ZONE_ID; do
    write_state_kv "${key}" "${!key:-}" || return 1
  done
}

update_certificate_metadata() {
  local temporary="" manifest="${QR_OUTPUT_DIR}/manifest.json"
  write_generated_file_atomically "${STATE_FILE}" certificate_state_text || return 1
  chmod 0600 "${STATE_FILE}" || return 1
  # 保留 URI/PNG 原字节，只更新与证书来源有关的说明和同代清单摘要。
  if [[ -f "${OUTPUT_FILE}" ]]; then
    temporary="$(mktemp "${OUTPUT_FILE}.tmp.XXXXXX")" || return 1
    if ! sed "s/^- 请将 Cloudflare SSL\/TLS 模式设置为 .*。$/- 请将 Cloudflare SSL\/TLS 模式设置为 $(cloudflare_ssl_mode_text)。/" \
      "${OUTPUT_FILE}" > "${temporary}" || ! durable_replace_file "${temporary}" "${OUTPUT_FILE}"; then
      rm -f "${temporary}"; return 1
    fi
  fi
  if [[ -f "${manifest}" ]]; then
    temporary="$(mktemp "${QR_OUTPUT_DIR}/.manifest.XXXXXX")" || return 1
    if ! jq --arg state "$(identity_file_sha256 "${STATE_FILE}")" --arg output "$(identity_file_sha256 "${OUTPUT_FILE}")" \
      '.state_sha256=$state | .output_sha256=$output' "${manifest}" > "${temporary}" \
      || ! durable_replace_file "${temporary}" "${manifest}"; then
      rm -f "${temporary}"; return 1
    fi
  fi
}

apply_certificate_only_update() {
  local trigger="${1:-manual}" source="${2:-manual}" cert="" key="" failed=no
  local -a paths=("${SSL_DIR}" "${TLS_CERT_FILE}" "${TLS_KEY_FILE}" "${ACME_RELOAD_HELPER}")
  # A fresh renew/callback process has not entered the Xray configuration path.
  ensure_xray_user lookup || return 1
  if [[ "${source}" == manual ]]; then
    paths+=("${STATE_FILE}" "${OUTPUT_FILE}" "${QR_OUTPUT_DIR}/manifest.json")
    if [[ -f "${QR_OUTPUT_DIR}/manifest.json" ]]; then load_export_node_objects >/dev/null || return 1; fi
  fi
  if cert_mode_is_acme; then paths+=("${ACME_HOME}/${XHTTP_DOMAIN}_ecc"); fi
  begin_generation_paths "证书更新 (${trigger})" nginx.service -- "${paths[@]}" || return 1
  certificate_record_event "${trigger}" started
  if [[ "${source}" == acme ]]; then
    cert="$(tls_stage_cert_file)"; key="$(tls_stage_key_file)"
    if ! copy_acme_stage_pair "${cert}" "${key}" || ! validate_tls_assets_with_paths "${cert}" "${key}" \
      || ! h3_prepare_generation "${cert}" "${key}" || ! promote_tls_assets "${cert}" "${key}"; then failed=yes; fi
    cleanup_tls_stage_files "${cert}" "${key}"
  elif ! write_tls_assets; then failed=yes; fi
  if [[ "${failed}" != yes ]]; then
    if ! nginx -t || ! reload_or_restart_service nginx || ! verify_served_tls_assets \
      || ! write_certificate_receipt; then failed=yes; fi
  fi
  if [[ "${failed}" != yes && "${source}" == manual ]] && ! update_certificate_metadata; then failed=yes; fi
  if [[ "${failed}" == yes ]]; then
    generation_failed "证书校验、部署或实际供证检查失败" || true
    certificate_record_event "${trigger}" failed "${GENERATION_RECOVERY_RESULT}；修复原因后重试，存在 pending 时先 recover"
    return 1
  fi
  if ! generation_commit; then
    generation_failed "证书提交记录未完成" || true
    certificate_record_event "${trigger}" failed "${GENERATION_RECOVERY_RESULT}"
    return 1
  fi
  certificate_record_event "${trigger}" success '已验证 nginx 实际提供的证书'
}

# 回退也验证实际供证；失败时保留 pending，不能只凭 nginx active 宣称恢复。
verify_recovered_tls_generation() {
  local entry="" needed=no
  if ! generation_has_path "${TLS_CERT_FILE}" && ! generation_has_path "${SSL_DIR}"; then return 0; fi
  for entry in "${GENERATION_SERVICE_STATES[@]}"; do
    [[ "${entry}" != nginx.service$'\t'active$'\t'* ]] || needed=yes
  done
  [[ "${needed}" == yes && -f "${TLS_CERT_FILE}" && -f "${STATE_FILE}" ]] || return 0
  (
    load_existing_state
    [[ -n "${XHTTP_DOMAIN:-}" ]] || return 1
    verify_served_tls_assets || return 1
  )
}

# 回调在另一进程读取继承环境，不读取上面子 shell 的父进程变量。
# shellcheck disable=SC2031
acme_deploy_cmd() {
  local domain="" cert_digest="" key_digest="" temporary=""
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --domain|--domain=*)
        option_take_value --domain "${1}" "${@:2}"
        domain="${OPTION_VALUE}"
        validate_hostname_value "ACME 域名" "${domain}"
        shift "${OPTION_ARGS_CONSUMED}" ;;
      --help|-h|help) usage; return 0 ;;
      *) die "未知的 acme-deploy 参数：${1}" ;;
    esac
  done
  [[ -n "${domain}" ]] || die "acme-deploy 需要 --domain，且只部署已校验的 ACME 暂存证书。"
  need_root
  if [[ -n "${XTUN_ACME_DEFER_OPERATION:-}" ]]; then
    # 外层安装/换证已持锁：回调只校验并确认输入，不抢锁、不移动文件、不启动服务。
    [[ "${XTUN_ACME_DEFER_NONCE:-}" =~ ^[a-zA-Z0-9_-]{16,64}$ ]] || return 1
    [[ "$(readlink -f /proc/self/fd/9)" == "$(readlink -f "${SCRIPT_LOCK_FILE}")" ]] || return 1
    flock -n 9 || return 1
    pending_operation_validate || return 1
    [[ "$(awk -F'\t' '$1 == "op_id" {print $2}' "${PENDING_OP_FILE}")" == "${XTUN_ACME_DEFER_OPERATION}" ]] || return 1
    # 回调进程还没读 state；任何 ACME 模式都要求公共信任链，这里只需 cert_mode_is_acme 为真。
    local CERT_MODE=acme-dns-cf XHTTP_DOMAIN="${domain}"
    validate_tls_assets_with_paths "$(acme_stage_cert_file)" "$(acme_stage_key_file)" || return 1
    cert_digest="$(identity_file_sha256 "$(acme_stage_cert_file)")" || return 1
    key_digest="$(identity_file_sha256 "$(acme_stage_key_file)")" || return 1
    temporary="$(mktemp "${XTUN_ACME_DEFER_OPERATION}/.acme-deferred.XXXXXX")" || return 1
    if ! jq -n --arg nonce "${XTUN_ACME_DEFER_NONCE}" --arg domain "${domain}" --arg cert "${cert_digest}" --arg key "${key_digest}" \
      '{nonce:$nonce,domain:$domain,cert_sha256:$cert,key_sha256:$key}' > "${temporary}" \
      || ! durable_replace_file "${temporary}" "${XTUN_ACME_DEFER_OPERATION}/acme-deferred.json"; then
      rm -f "${temporary}"; return 1
    fi
    return 0
  fi
  begin_mutation || return 1
  load_current_install_context || return 1
  if ! cert_mode_is_acme || [[ "${XHTTP_DOMAIN}" != "${domain}" ]]; then
    certificate_record_event acme-callback rejected '域名或证书来源已改变，保留当前证书'
    warn "此回调不属于当前 ACME 域名，未部署。"; return 1
  fi
  start_backup_session || return 1
  apply_certificate_only_update acme-callback acme || return 1
  log_success "ACME 证书已部署，并核对 nginx 实际供证。"
}
