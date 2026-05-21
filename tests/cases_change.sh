run_change_helper_case() {
  local original_prompt=""
  local workdir=""
  local -A uuid_request=()
  local -A warp_request=()
  local -A cert_request=()

  workdir="$(mktemp -d)"
  printf 'client-secret\n' > "${workdir}/warp-secret.txt"
  original_prompt="$(declare -f prompt_with_default)"
  NON_INTERACTIVE=0
  init_change_uuid_request uuid_request
  parse_change_uuid_args uuid_request \
    --non-interactive \
    --reality-uuid 11111111-1111-1111-1111-111111111111 \
    --xhttp-only
  [[ "${NON_INTERACTIVE}" -eq 1 ]]
  [[ "${uuid_request[rotate_reality]}" == "0" ]]
  [[ "${uuid_request[rotate_xhttp]}" == "1" ]]
  [[ "${uuid_request[reality_uuid]}" == "11111111-1111-1111-1111-111111111111" ]]

  NON_INTERACTIVE=0
  init_change_warp_request warp_request
  parse_change_warp_args warp_request \
    --non-interactive \
    --enable-warp \
    --warp-team team-name \
    --warp-client-id client-id \
    --warp-client-secret "@${workdir}/warp-secret.txt" \
    --warp-proxy-port 41000
  WARP_CLIENT_SECRET="${warp_request[warp_client_secret]}"
  resolve_install_input_sources
  [[ "${NON_INTERACTIVE}" -eq 1 ]]
  [[ "${warp_request[target_mode]}" == "enable" ]]
  [[ "${warp_request[warp_team_name]}" == "team-name" ]]
  [[ "${warp_request[warp_client_id]}" == "client-id" ]]
  [[ "${WARP_CLIENT_SECRET}" == "client-secret" ]]
  [[ "${warp_request[warp_proxy_port]}" == "41000" ]]

  NON_INTERACTIVE=0
  init_change_cert_mode_request cert_request
  parse_change_cert_mode_args cert_request \
    --non-interactive \
    --cert-mode existing \
    --xhttp-domain cdn.example.com \
    --cert-file /tmp/cert.pem \
    --key-file /tmp/key.pem \
    --cf-zone-id zone-id \
    --acme-email ops@example.com
  [[ "${NON_INTERACTIVE}" -eq 1 ]]
  [[ "${cert_request[cert_mode_overridden]}" == "1" ]]
  [[ "${cert_request[xhttp_domain_overridden]}" == "1" ]]
  [[ "${cert_request[cert_mode]}" == "existing" ]]
  [[ "${cert_request[xhttp_domain]}" == "cdn.example.com" ]]
  [[ "${cert_request[cert_source_file]}" == "/tmp/cert.pem" ]]
  [[ "${cert_request[key_source_file]}" == "/tmp/key.pem" ]]
  [[ "${cert_request[cf_zone_id]}" == "zone-id" ]]
  [[ "${cert_request[acme_email]}" == "ops@example.com" ]]

  CERT_SOURCE_FILE="old-cert.pem"
  apply_optional_override CERT_SOURCE_FILE ""
  [[ "${CERT_SOURCE_FILE}" == "old-cert.pem" ]]
  apply_optional_override CERT_SOURCE_FILE "new-cert.pem"
  [[ "${CERT_SOURCE_FILE}" == "new-cert.pem" ]]
  apply_optional_override CERT_SOURCE_FILE "" "1"
  [[ -z "${CERT_SOURCE_FILE}" ]]

  CF_DNS_ACCOUNT_ID="old-account"
  cert_request[cf_dns_account_id]=""
  cert_request["$(request_value_presence_key "cf_dns_account_id")"]="1"
  apply_request_overrides cert_request "cf_dns_account_id:CF_DNS_ACCOUNT_ID"
  [[ -z "${CF_DNS_ACCOUNT_ID}" ]]

  CERT_MODE="existing"
  XHTTP_DOMAIN="cdn.old.example.com"
  resolve_cert_mode_change_targets "existing" "cdn.old.example.com" 1 1 "1" "cdn.new.example.com"
  [[ "${CERT_MODE}" == "self-signed" ]]
  [[ "${XHTTP_DOMAIN}" == "cdn.new.example.com" ]]

  prompt_with_default() {
    local var_name="${1}"

    case "${var_name}" in
      CERT_MODE)
        printf -v "${var_name}" '%s' "3"
        ;;
      XHTTP_DOMAIN)
        printf -v "${var_name}" '%s' "cdn.prompt.example.com"
        ;;
      *)
        return 1
        ;;
    esac
  }

  resolve_cert_mode_change_targets "existing" "cdn.old.example.com" 0 0 "" ""
  [[ "${CERT_MODE}" == "cf-origin-ca" ]]
  [[ "${XHTTP_DOMAIN}" == "cdn.prompt.example.com" ]]
  [[ "$(cert_mode_choice_value "existing")" == "2" ]]

  eval "${original_prompt}"
}

run_change_command_case() {
  local output=""
  local runtime_updated=0
  local runtime_sni=""
  local runtime_target=""
  local state_written=0
  local output_written=0
  local written_prefix=""
  local shown_links=0
  local rules_written=""

  need_root() { :; }
  start_backup_session() { BACKUP_DIR="/tmp/change-backup"; }
  load_current_install_context() {
    REALITY_SNI="old.example.com"
    REALITY_TARGET="www.harvard.edu:443"
    XHTTP_PATH="/old"
    NODE_LABEL_PREFIX="HKG"
    CERT_MODE="existing"
    XHTTP_DOMAIN="cdn.old.example.com"
    ENABLE_WARP="no"
    WARP_TEAM_NAME="old-team"
    WARP_CLIENT_ID="old-id"
    WARP_CLIENT_SECRET="old-secret"
    WARP_PROXY_PORT="40000"
    WARP_RULES_TEXT=$'geosite:google\ndomain:github.com'
  }
  ensure_xray_user() { :; }
  begin_managed_output_change() {
    NODE_LABEL_PREFIX="HKG"
  }
  apply_managed_runtime_update() {
    runtime_updated=1
    runtime_sni="${REALITY_SNI}"
    runtime_target="${REALITY_TARGET}"
    rules_written="${WARP_RULES_TEXT}"
  }
  write_state_file() {
    state_written=1
    written_prefix="${NODE_LABEL_PREFIX}"
  }
  write_output_file() {
    output_written=1
  }
  show_links() {
    shown_links=$((shown_links + 1))
  }
  log() { :; }
  log_step() { :; }
  log_success() { :; }

  NON_INTERACTIVE=0
  change_sni_cmd --non-interactive --reality-sni new.example.com
  [[ "${runtime_updated}" -eq 1 ]]
  [[ "${runtime_sni}" == "new.example.com" ]]
  [[ "${runtime_target}" == "www.harvard.edu:443" ]]
  [[ "${shown_links}" -eq 1 ]]

  NON_INTERACTIVE=0
  change_label_prefix_cmd --non-interactive
  [[ "${state_written}" -eq 1 ]]
  [[ "${output_written}" -eq 1 ]]
  [[ "${written_prefix}" == "HKG" ]]
  [[ "${shown_links}" -eq 2 ]]

  load_current_install_context() {
    return 99
  }
  begin_managed_output_change() {
    NODE_LABEL_PREFIX="LAX"
    SERVER_IP="203.0.113.30"
    REALITY_UUID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    REALITY_SNI="reality.example.com"
    REALITY_PUBLIC_KEY="public-key"
    REALITY_SHORT_ID="abcd1234"
    XHTTP_UUID="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    XHTTP_DOMAIN="cdn.example.com"
    XHTTP_PATH="/edge"
    XHTTP_VLESS_ENCRYPTION_ENABLED="no"
    XHTTP_VLESS_ENCRYPTION=""
    XHTTP_VLESS_DECRYPTION="none"
    TLS_ALPN="h2"
    FINGERPRINT="chrome"
    ENABLE_WARP="no"
    ENABLE_NET_OPT="no"
    CERT_MODE="existing"
  }
  NON_INTERACTIVE=0
  change_label_prefix_cmd --non-interactive --node-label-prefix nrt
  [[ "${written_prefix}" == "NRT" ]]

  load_current_install_context() {
    REALITY_SNI="old.example.com"
    REALITY_TARGET="www.harvard.edu:443"
    XHTTP_PATH="/old"
    NODE_LABEL_PREFIX="HKG"
    CERT_MODE="existing"
    XHTTP_DOMAIN="cdn.old.example.com"
    ENABLE_WARP="no"
    WARP_TEAM_NAME="old-team"
    WARP_CLIENT_ID="old-id"
    WARP_CLIENT_SECRET="old-secret"
    WARP_PROXY_PORT="40000"
    WARP_RULES_TEXT=$'geosite:google\ndomain:github.com'
  }

  NON_INTERACTIVE=0
  change_warp_rules_cmd --non-interactive --add-domain chat.openai.com --del-domain github.com
  [[ "${runtime_updated}" -eq 1 ]]
  [[ "${rules_written}" == *$'domain:chat.openai.com'* ]]
  [[ "${rules_written}" != *$'domain:github.com'* ]]
  [[ "${shown_links}" -eq 4 ]]

  load_existing_state() {
    WARP_RULES_TEXT=$'geosite:google\ndomain:chat.openai.com'
  }
  runtime_updated=0
  shown_links=0
  output="$(change_warp_rules_cmd --list)"
  [[ "${runtime_updated}" -eq 0 ]]
  [[ "${shown_links}" -eq 0 ]]
  [[ "${output}" == *"domain:chat.openai.com"* ]]
}

run_change_warp_enable_rollback_case() {
  local rolled_back=0
  local status=0

  parse_change_warp_args() {
    local -n request_ref="${1}"
    request_ref[target_mode]="enable"
  }
  ensure_debian_family() { :; }
  begin_managed_change() { :; }
  apply_warp_change_request() { :; }
  prompt_warp_settings() { :; }
  install_warp() { :; }
  apply_managed_runtime_update() {
    return 1
  }
  rollback_optional_component_state() {
    rolled_back=$((rolled_back + 1))
  }

  set +e
  change_warp_cmd --enable-warp >/dev/null 2>&1
  status=$?
  set -e

  [[ "${status}" -ne 0 ]]
  [[ "${rolled_back}" -eq 1 ]]
  load_functions
}

run_renew_cert_command_case() {
  local applied=0
  local shown_links=0
  local logged=""
  local workdir=""

  workdir="$(mktemp -d)"
  printf 'dns-token\n' > "${workdir}/cf-dns-token.txt"
  need_root() { :; }
  start_backup_session() { BACKUP_DIR="/tmp/renew-backup"; }
  load_current_install_context() {
    CERT_MODE="acme-dns-cf"
    XHTTP_DOMAIN="cdn.old.example.com"
    REALITY_SNI="old.example.com"
    REALITY_TARGET="www.harvard.edu:443"
    XHTTP_PATH="/old"
    WARP_PROXY_PORT="40000"
  }
  ensure_xray_user() { :; }
  apply_managed_update() {
    applied=$((applied + 1))
  }
  show_links() {
    shown_links=$((shown_links + 1))
  }
  log() {
    logged+="${1}"$'\n'
  }
  log_step() {
    logged+="STEP:${1}"$'\n'
  }
  log_success() {
    logged+="OK:${1}"$'\n'
  }
  resolve_install_input_sources() { :; }
  prompt_cert_mode_inputs() { :; }
  validate_install_inputs() { :; }

  renew_cert_cmd --non-interactive --acme-email ops@example.com --cf-dns-token "@${workdir}/cf-dns-token.txt"
  [[ "${applied}" -eq 1 ]]
  [[ "${shown_links}" -eq 1 ]]
  printf '%s' "${logged}" | grep -q 'STEP:刷新 TLS 证书资产。'
  printf '%s' "${logged}" | grep -q 'OK:证书已续期。'
}

run_upgrade_command_case() {
  local logged=""
  local restored=()
  local restarted=0
  local status=0
  local workdir=""

  workdir="$(mktemp -d)"

  need_root() { :; }
  ensure_debian_family() { :; }
  start_backup_session() { BACKUP_DIR="/tmp/upgrade-backup"; }
  backup_path() { :; }
  install_xray() { :; }
  ensure_xray_bind_capability() { :; }
  validate_configs() { return 1; }
  restore_backup_path() {
    restored+=("${1}")
  }
  systemctl() {
    restarted=$((restarted + 1))
  }
  log() {
    logged+="${1}"$'\n'
  }
  log_step() {
    logged+="STEP:${1}"$'\n'
  }
  log_success() {
    logged+="OK:${1}"$'\n'
  }
  warn() {
    logged+="WARN:${1}"$'\n'
  }
  XRAY_BIN="${workdir}/xray"
  XRAY_ASSET_DIR="${workdir}/xray-assets"
  printf '#!/usr/bin/env bash\n' > "${XRAY_BIN}"
  chmod 0755 "${XRAY_BIN}"
  mkdir -p "${XRAY_ASSET_DIR}"

  set +e
  upgrade_cmd
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  [[ "${restored[*]}" == "${XRAY_BIN} ${XRAY_ASSET_DIR}" ]]
  [[ "${restarted}" -eq 0 ]]
  printf '%s' "${logged}" | grep -q 'STEP:升级 Xray 核心。'
  printf '%s' "${logged}" | grep -q 'WARN:升级后的配置校验失败，正在回滚 Xray 核心文件。'
}

run_diagnose_command_case() {
  local output=""
  local status=0
  local probe_file=""

  probe_file="$(mktemp)"

  load_dashboard_context() { :; }
  service_active_state() {
    case "${1}" in
      xray.service|haproxy.service|nginx.service|warp-svc.service|${CORE_HEALTH_TIMER_NAME}|${WARP_HEALTH_TIMER_NAME})
        printf 'active'
        ;;
      *)
        printf 'unknown'
        ;;
    esac
  }
  listening_port_text() { printf '运行中'; }
  is_port_listening() { return 0; }
  xray_config_check_state() { printf 'ok'; }
  nginx_config_check_state() { printf 'ok'; }
  haproxy_config_check_state() { printf 'ok'; }
  local_tls_probe_state() { printf 'ok'; }
  xray_config_check_text() { printf '通过'; }
  nginx_config_check_text() { printf '通过'; }
  haproxy_config_check_text() { printf '通过'; }
  local_tls_probe_text() { printf '通过'; }
  cert_expiry_text() { printf 'Jun  1 00:00:00 2026 GMT'; }
  warp_exit_ip_text() {
    local count=0
    count="$(cat "${probe_file}" 2>/dev/null || printf '0')"
    printf '%s' "$((count + 1))" > "${probe_file}"
    printf '203.0.113.99'
  }
  health_event_text() { printf 'ok'; }
  latest_health_history_text() { printf 'latest history'; }

  output="$(diagnose_cmd)"
  printf '%s' "${output}" | grep -q 'Xray WARP 诊断'
  printf '%s' "${output}" | grep -q '监听 443: 运行中'
  printf '%s' "${output}" | grep -q '诊断摘要: 未发现关键问题'
  [[ "$(cat "${probe_file}")" == "1" ]]

  service_active_state() { printf 'failed'; }
  printf '0' > "${probe_file}"
  set +e
  output="$(diagnose_cmd 2>&1)"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  printf '%s' "${output}" | grep -q '诊断摘要: 检测到'
  printf '%s' "${output}" | grep -q '服务: xray 未运行'
  [[ "$(cat "${probe_file}")" == "1" ]]
}
