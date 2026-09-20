# shellcheck shell=bash
# shellcheck disable=SC2034

certificates_fixture() {
  local workdir="${1}" unit=""
  nodes_fixture "${workdir}"
  SSL_DIR="${workdir}/ssl"
  TLS_CERT_FILE="${SSL_DIR}/cert.pem"
  TLS_KEY_FILE="${SSL_DIR}/key.pem"
  ACME_HOME="${workdir}/acme"
  ACME_SH_BIN="${ACME_HOME}/acme.sh"
  ACME_RELOAD_HELPER="${workdir}/acme-reload.sh"
  SELF_INSTALL_DIR="${workdir}/bundle"
  XRAY_GID=0
  CERT_MODE=existing
  CERT_SOURCE_PEM="" KEY_SOURCE_PEM=""
  mkdir -p "${SSL_DIR}" "${workdir}/certs" "${ACME_HOME}" "${SELF_INSTALL_DIR}"
  batch_b_certificate_fixtures "${workdir}/certs"
  certificate_public_trust_roots() { cat "${workdir}/certs/root.pem"; }
  certificate_origin_trust_roots() { cat "${workdir}/certs/origin-root.pem"; }
  cp "${workdir}/certs/chain.pem" "${TLS_CERT_FILE}"
  cp "${workdir}/certs/leaf.key" "${TLS_KEY_FILE}"
  chmod 0640 "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"
  cp "${TLS_CERT_FILE}" "${workdir}/served.pem"
  openssl x509 -req -in "${workdir}/certs/leaf.csr" -CA "${workdir}/certs/inter.pem" \
    -CAkey "${workdir}/certs/inter.key" -set_serial 1234 -days 2 -extfile "${workdir}/certs/leaf.ext" \
    -out "${workdir}/certs/new-leaf.pem" >/dev/null 2>&1
  cat "${workdir}/certs/new-leaf.pem" "${workdir}/certs/inter.pem" > "${workdir}/certs/new-chain.pem"
  CERT_SOURCE_FILE="${workdir}/certs/new-chain.pem"
  KEY_SOURCE_FILE="${workdir}/certs/leaf.key"
  declare -gA GENERATION_TEST_INSTALLED GENERATION_TEST_ACTIVE GENERATION_TEST_ENABLED
  for unit in xray.service nginx.service haproxy.service; do
    GENERATION_TEST_INSTALLED[${unit}]=yes
    GENERATION_TEST_ACTIVE[${unit}]=active
    GENERATION_TEST_ENABLED[${unit}]=enabled
  done
  nginx() { :; }
  served_certificate_fingerprint() { certificate_fingerprint "${workdir}/served.pem"; }
  systemctl() {
    local action="${1}" unit="${2:-}"
    if [[ "${action}" == is-active && "${unit}" == --quiet ]]; then unit="${3}"; fi
    if [[ "${action}" == reload && "${CERT_TEST_FAIL_RELOAD:-no}" == yes ]]; then
      CERT_TEST_FAIL_RELOAD=no
      SYSTEMCTL_CALLS+="reload-failed ${unit}"$'\n'
      return 1
    fi
    if [[ ( "${action}" == start || "${action}" == restart ) && "${CERT_TEST_FAIL_RECOVERY:-no}" == yes ]]; then return 1; fi
    if [[ "${action}" == reload || "${action}" == start || "${action}" == restart ]]; then
      if [[ "${CERT_TEST_STALE_SERVED:-no}" != yes || "${action}" != reload ]]; then
        cp "${TLS_CERT_FILE}" "${workdir}/served.pem" || return 1
      fi
    fi
    generation_mock_systemctl "${action}" "${unit}" "${@:3}"
  }
  write_state_file
  write_output_file
}

run_certificate_candidate_validation_case() {
  local workdir="" item=""
  load_functions
  workdir="$(mktemp -d)"
  certificates_fixture "${workdir}"
  validate_tls_assets_with_paths "${workdir}/certs/chain.pem" "${workdir}/certs/leaf.key"
  validate_tls_assets_with_paths "${workdir}/certs/origin.pem" "${workdir}/certs/leaf.key"
  validate_tls_assets_with_paths "${workdir}/certs/self.pem" "${workdir}/certs/leaf.key"
  for item in leaf expired future client; do
    assert_false validate_tls_assets_with_paths "${workdir}/certs/${item}.pem" "${workdir}/certs/leaf.key"
  done
  assert_false validate_tls_assets_with_paths "${workdir}/certs/chain.pem" "${workdir}/certs/root.key"
  XHTTP_DOMAIN=wrong.example.com
  assert_false validate_tls_assets_with_paths "${workdir}/certs/chain.pem" "${workdir}/certs/leaf.key"
  XHTTP_DOMAIN=cdn.example.com
  CERT_MODE=acme-dns-cf
  assert_false validate_tls_assets_with_paths "${workdir}/certs/self.pem" "${workdir}/certs/leaf.key"
  # 名称里有 Cloudflare Origin 不能冒充官方 CA。
  certificate_origin_trust_roots() { cat "${SCRIPT_ROOT}/static/certificates/cloudflare-origin-ca-rsa.pem"; }
  CERT_MODE=existing
  assert_false validate_tls_assets_with_paths "${workdir}/certs/origin.pem" "${workdir}/certs/leaf.key"
  rm -rf "${workdir}"
}

run_certificate_only_command_case() {
  local workdir="" config_before="" nodes_before="" pngs_before="" lookup=""
  load_functions
  lookup="$(declare -f ensure_xray_user)"
  workdir="$(mktemp -d)"
  certificates_fixture "${workdir}"
  # Reproduce an independent CLI process with no cached UID/GID. Keep the real
  # lookup helper and only supply the sandbox's account identity.
  eval "${lookup}"
  XRAY_UID="" XRAY_GID=""
  id() {
    case "$*" in '-u xray'|'-g xray') printf '0\n' ;; *) command id "$@" ;; esac
  }
  config_before="$(identity_file_sha256 "${XRAY_CONFIG_FILE}")"
  nodes_before="$(output_node_link_entries)"
  pngs_before="$(jq -c .pngs "${QR_OUTPUT_DIR}/manifest.json")"
  run_cli_command renew-cert --non-interactive --cert-file "${CERT_SOURCE_FILE}" --key-file "${KEY_SOURCE_FILE}"
  [[ "${XRAY_UID}" == 0 && "${XRAY_GID}" == 0 ]]
  [[ "$(certificate_fingerprint "${TLS_CERT_FILE}")" == "$(certificate_fingerprint "${workdir}/certs/new-chain.pem")" ]]
  [[ "${SYSTEMCTL_CALLS}" == *'reload nginx'* && "${SYSTEMCTL_CALLS}" != *restart* ]]
  [[ "$(identity_file_sha256 "${XRAY_CONFIG_FILE}")" == "${config_before}" ]]
  [[ "$(output_node_link_entries)" == "${nodes_before}" ]]
  [[ "$(jq -c .pngs "${QR_OUTPUT_DIR}/manifest.json")" == "${pngs_before}" ]]
  load_export_node_objects >/dev/null
  jq -e '.trigger=="renew-cert" and .result=="success"' "${OP_LOG_DIR}/certificate.json" >/dev/null
  [[ ! -e "${PENDING_OP_FILE}" && "$(stat -c %a "${TLS_KEY_FILE}")" == 640 ]]
  [[ "$(stat -c %a "${SSL_DIR}/.xtun-certificate.json")" == 600 ]]
  rm -rf "${workdir}"
}

run_certificate_failure_recovery_case() {
  local workdir="" failure="" before="" status=0
  for failure in key-move reload served metadata; do
    (
      load_functions
      workdir="$(mktemp -d)"
      certificates_fixture "${workdir}"
      before="$(backup_file_digest "${SSL_DIR}"):$(backup_file_digest "${XRAY_CONFIG_DIR}"):$(backup_file_digest "${QR_OUTPUT_DIR}"):$(identity_file_sha256 "${OUTPUT_FILE}")"
      case "${failure}" in
        key-move)
          mv() {
            if [[ "${*: -1}" == "${TLS_KEY_FILE}" && "$*" == *'.key.pem.stage'* ]]; then
              touch "${workdir}/injected"
              return 1
            fi
            command mv "$@"
          } ;;
        reload) CERT_TEST_FAIL_RELOAD=yes ;;
        served) CERT_TEST_STALE_SERVED=yes ;;
        metadata) update_certificate_metadata() { touch "${workdir}/injected"; return 1; } ;;
      esac
      run_cli_command renew-cert --non-interactive --cert-file "${CERT_SOURCE_FILE}" --key-file "${KEY_SOURCE_FILE}" || status=$?
      [[ "${status}" == 1 && "${GENERATION_RECOVERY_RESULT}" == restored-verified && ! -e "${PENDING_OP_FILE}" ]]
      [[ "$(backup_file_digest "${SSL_DIR}"):$(backup_file_digest "${XRAY_CONFIG_DIR}"):$(backup_file_digest "${QR_OUTPUT_DIR}"):$(identity_file_sha256 "${OUTPUT_FILE}")" == "${before}" ]]
      [[ "${SYSTEMCTL_CALLS}" != *'stop xray'* && "${SYSTEMCTL_CALLS}" != *'stop haproxy'* ]]
      verify_served_tls_assets
      jq -e '.result == "failed"' "${OP_LOG_DIR}/certificate.json" >/dev/null
      case "${failure}" in key-move|metadata) [[ -f "${workdir}/injected" ]] ;; esac
      rm -rf "${workdir}"
    )
  done
}

run_certificate_recovery_retry_case() {
  local workdir="" status=0
  load_functions
  workdir="$(mktemp -d)"
  certificates_fixture "${workdir}"
  CERT_TEST_FAIL_RELOAD=yes CERT_TEST_FAIL_RECOVERY=yes
  run_cli_command renew-cert --non-interactive --cert-file "${CERT_SOURCE_FILE}" --key-file "${KEY_SOURCE_FILE}" || status=$?
  [[ "${status}" == 1 && -e "${PENDING_OP_FILE}" && "${GENERATION_RECOVERY_RESULT}" == recovery-failed ]]
  CERT_TEST_FAIL_RECOVERY=no
  run_cli_command recover --yes
  [[ ! -e "${PENDING_OP_FILE}" && "${GENERATION_RECOVERY_RESULT}" == restored-verified ]]
  verify_served_tls_assets
  rm -rf "${workdir}"
}

certificates_callback_worker() {
  local workdir="${1}" name=""
  {
    printf 'ROOT_DIR=%q\n' "${ROOT_DIR}"
    printf 'source <(sed '\''$d'\'' %q)\n' "${ROOT_DIR}/xtun.sh"
    for name in SSL_DIR TLS_CERT_FILE TLS_KEY_FILE ACME_HOME ACME_SH_BIN ACME_RELOAD_HELPER SELF_INSTALL_DIR \
      SCRIPT_LOCK_FILE PENDING_OP_FILE BACKUP_ROOT STATE_FILE XRAY_CONFIG_FILE XRAY_CONFIG_DIR XRAY_BIN \
      XRAY_ASSET_DIR OUTPUT_FILE QR_OUTPUT_DIR OP_LOG_DIR OP_LOG_FILE SESSION_LOG_FILE XRAY_GID; do
      printf '%s=%q\n' "${name}" "${!name}"
    done
    printf 'certificate_public_trust_roots() { cat %q; }\n' "${workdir}/certs/root.pem"
    printf 'run_cli_command "$@"\n'
  } > "${SELF_INSTALL_DIR}/xtun.sh"
  chmod 0700 "${SELF_INSTALL_DIR}/xtun.sh"
}

run_acme_deferred_callback_case() {
  local workdir="" status=0 before=""
  load_functions
  workdir="$(mktemp -d)"
  certificates_fixture "${workdir}"
  CERT_MODE=acme-dns-cf ACME_EMAIL=ops@example.test
  write_state_file
  write_output_file
  certificates_callback_worker "${workdir}"
  cat > "${ACME_SH_BIN}" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1" in --register-account) exit 0 ;; --issue) exit 2 ;; esac
cert="" key="" callback=""
while [[ $# -gt 0 ]]; do
 case "$1" in
   --key-file) key="$2"; shift ;;
   --fullchain-file) cert="$2"; shift ;;
   --reloadcmd) callback="$2"; shift ;;
 esac
 shift
done
fixture="$(dirname "$0")/../certs"
cp "${fixture}/new-chain.pem" "$cert"
cp "${fixture}/leaf.key" "$key"
if [[ -f "${fixture}/lose-stage" ]]; then rm "$key"; fi
# 复现 acme.sh 3.1.1：回调失败被日志处理掩盖，外层仍返回 0。
"$callback" || true
SH
  chmod 0700 "${ACME_SH_BIN}"
  printf 'test-token\n' > "${workdir}/token"
  run_cli_command renew-cert --non-interactive --cf-dns-token "@${workdir}/token" --acme-email ops@example.test
  [[ "$(certificate_fingerprint "${TLS_CERT_FILE}")" == "$(certificate_fingerprint "${workdir}/certs/new-chain.pem")" ]]
  [[ -f "$(acme_stage_cert_file)" && -f "$(acme_stage_key_file)" ]]
  [[ "${SYSTEMCTL_CALLS}" == *'reload nginx'* && "${SYSTEMCTL_CALLS}" != *restart* ]]
  [[ -z "${XTUN_ACME_DEFER_OPERATION:-}" && -z "${CF_Token:-}" ]]
  before="$(backup_file_digest "${SSL_DIR}")"
  touch "${workdir}/certs/lose-stage"
  run_cli_command renew-cert --non-interactive --cf-dns-token "@${workdir}/token" --acme-email ops@example.test || status=$?
  [[ "${status}" == 1 && "$(backup_file_digest "${SSL_DIR}")" == "${before}" ]]
  [[ "${LOGGED}" == *'未确认本次证书'* ]]
  rm -rf "${workdir}"
}

run_acme_automatic_callback_case() {
  local workdir="" state_before="" links_before="" status=0
  load_functions
  workdir="$(mktemp -d)"
  certificates_fixture "${workdir}"
  CERT_MODE=acme-dns-cf
  write_state_file
  write_output_file
  state_before="$(identity_file_sha256 "${STATE_FILE}")"
  links_before="$(backup_file_digest "${QR_OUTPUT_DIR}"):$(identity_file_sha256 "${OUTPUT_FILE}")"
  mkdir -p "${SSL_DIR}/.acme-stage"
  cp "${workdir}/certs/new-chain.pem" "$(acme_stage_cert_file)"
  cp "${workdir}/certs/leaf.key" "$(acme_stage_key_file)"
  run_cli_command acme-deploy --domain cdn.example.com
  [[ "$(certificate_fingerprint "${TLS_CERT_FILE}")" == "$(certificate_fingerprint "${workdir}/certs/new-chain.pem")" ]]
  [[ "$(identity_file_sha256 "${STATE_FILE}")" == "${state_before}" ]]
  [[ "$(backup_file_digest "${QR_OUTPUT_DIR}"):$(identity_file_sha256 "${OUTPUT_FILE}")" == "${links_before}" ]]
  jq -e '.trigger=="acme-callback" and .result=="success"' "${OP_LOG_DIR}/certificate.json" >/dev/null
  rm "$(acme_stage_key_file)"
  run_cli_command acme-deploy --domain cdn.example.com || status=$?
  [[ "${status}" == 1 && "${GENERATION_RECOVERY_RESULT}" == restored-verified ]]
  status=0
  run_cli_command acme-deploy --domain other.example.com || status=$?
  [[ "${status}" == 1 && ! -e "${PENDING_OP_FILE}" ]]
  rm -rf "${workdir}"
}

run_acme_callback_lock_case() {
  local workdir="" pid="" attempt=0 status=0 before=""
  load_functions
  workdir="$(mktemp -d)"
  certificates_fixture "${workdir}"
  certificates_callback_worker "${workdir}"
  before="$(backup_file_digest "${SSL_DIR}"):$(identity_file_sha256 "${STATE_FILE}")"
  (
    exec 8>"${SCRIPT_LOCK_FILE}"
    flock -n 8
    touch "${workdir}/locked"
    sleep 15
  ) & pid=$!
  for attempt in {1..50}; do [[ ! -f "${workdir}/locked" ]] || break; sleep 0.05; done
  [[ -f "${workdir}/locked" ]]
  bash "${SELF_INSTALL_DIR}/xtun.sh" acme-deploy --domain cdn.example.com > "${workdir}/callback.log" 2>&1 || status=$?
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  [[ "${status}" == 1 && "$(backup_file_digest "${SSL_DIR}"):$(identity_file_sha256 "${STATE_FILE}")" == "${before}" ]]
  assert_contains '另一个 xtun 进程' "${workdir}/callback.log"
  [[ ! -e "${PENDING_OP_FILE}" ]]
  rm -rf "${workdir}"
}

run_served_certificate_socket_case() {
  local workdir="" port="" pid="" attempt=0
  load_functions
  workdir="$(mktemp -d)"
  certificates_fixture "${workdir}"
  # 本用例恢复真实 socket 读证书逻辑；故障用例用独立 served.pem 模拟 worker。
  eval "$(sed -n '/^served_certificate_fingerprint() {/,/^}/p' "${ROOT_DIR}/lib/install/certs.sh")"
  port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  NGINX_TLS_PORT="${port}"
  openssl s_server -accept "127.0.0.1:${port}" -cert "${TLS_CERT_FILE}" -key "${TLS_KEY_FILE}" -www -quiet \
    > "${workdir}/server.log" 2>&1 & pid=$!
  for attempt in {1..30}; do
    if served_certificate_fingerprint >/dev/null 2>&1; then break; fi
    sleep 0.05
  done
  verify_served_tls_assets
  cp "${workdir}/certs/new-chain.pem" "${TLS_CERT_FILE}"
  # 磁盘证书变了但服务仍用旧证书，必须失败。
  assert_false verify_served_tls_assets
  kill "${pid}"
  wait "${pid}" 2>/dev/null || true
  rm -rf "${workdir}"
}

# HTTP-01 证书模式（acme-http）：不需要 DNS 令牌；要求域名解析到本机；
# 签发走 acme.sh standalone，并用 pre/post hook 让 nginx 在挑战窗口内让位。
run_acme_http_issue_case() {
  local workdir=""
  local args_log=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  certificates_fixture "${workdir}"
  args_log="${workdir}/acme-args.log"

  # 模式识别与规范化：acme-http 属于 ACME 家族，别名与菜单编号都能落到同一个值
  CERT_MODE=acme-http; cert_mode_is_acme
  CERT_MODE=acme-dns-cf; cert_mode_is_acme
  CERT_MODE=self-signed
  if cert_mode_is_acme; then
    printf '[fail] self-signed 不属于 ACME 家族\n' >&2; return 1
  fi
  [[ "$(normalize_cert_mode 5)" == 'acme-http' ]]
  [[ "$(normalize_cert_mode acme-http01)" == 'acme-http' ]]
  [[ "$(validate_cert_mode_value acme-http)" == 'acme-http' ]]
  [[ "$(cert_mode_choice_value acme-http)" == '4' ]]

  # 预检：域名没解析到本机时必须挡住（HTTP-01 签不下来）
  CERT_MODE=acme-http
  XHTTP_DOMAIN='cdn.example.com'
  SERVER_IP='203.0.113.10'
  getent() { printf '198.51.100.7 STREAM x\n'; }
  if ( preflight_check_acme_http_domain ) >/dev/null 2>&1; then
    printf '[fail] acme-http 域名解析到别处时必须拒绝\n' >&2; return 1
  fi
  getent() { printf '203.0.113.10 STREAM x\n'; }
  socat() { :; }
  ( preflight_check_acme_http_domain ) >/dev/null 2>&1

  # 签发参数：standalone + pre/post hook，且不带 dns_cf、不带 CF_Token
  ACME_EMAIL='ops@example.test'
  ACME_CA="${DEFAULT_ACME_CA:-letsencrypt}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> %q\n' "${args_log}"
    printf 'printf "CF_Token=%%s\\n" "${CF_Token:-}" >> %q\n' "${args_log}"
    printf 'case "$*" in *--register-account*) exit 0 ;; esac\n'
    printf 'exit 1\n'
  } > "${ACME_SH_BIN}"
  chmod 0755 "${ACME_SH_BIN}"
  backup_path() { :; }
  BACKUP_DIR="${workdir}/backups"
  mkdir -p "${BACKUP_DIR}"
  GENERATION_ACTIVE=yes
  SCRIPT_LOCK_HELD=1

  issue_acme_http_cert "${workdir}/stage-cert.pem" "${workdir}/stage-key.pem" || status=$?
  [[ "${status}" -ne 0 ]]
  grep -q -- '--issue --standalone' "${args_log}"
  grep -q -- '--pre-hook' "${args_log}"
  grep -q -- '--post-hook' "${args_log}"
  grep -q '^CF_Token=$' "${args_log}"
  if grep -q 'dns_cf' "${args_log}"; then
    printf '[fail] acme-http 不应使用 DNS-01\n' >&2; return 1
  fi

  rm -rf "${workdir}"
  load_functions
}
