run_warp_enabled_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults

  SERVER_IP="203.0.113.10"
  NODE_LABEL_PREFIX="HKG"
  REALITY_UUID="11111111-1111-1111-1111-111111111111"
  REALITY_SNI="reality.example.com"
  REALITY_TARGET="www.scu.edu:443"
  REALITY_SHORT_ID="abcd1234"
  REALITY_PRIVATE_KEY="private-key-value"
  REALITY_PUBLIC_KEY="public-key-value"
  XHTTP_UUID="22222222-2222-2222-2222-222222222222"
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/assets/v3"
  XHTTP_VLESS_ENCRYPTION_ENABLED="yes"
  XHTTP_VLESS_ENCRYPTION="enc-value-+=?&"
  XHTTP_VLESS_DECRYPTION="enc-value-+=?&"
  TLS_ALPN="h2"
  FINGERPRINT="chrome"
  ENABLE_WARP="yes"
  ENABLE_NET_OPT="no"
  WARP_PROXY_PORT="40000"
  WARP_TEAM_NAME="team-name"
  WARP_CLIENT_ID="client-id.access"
  WARP_CLIENT_SECRET=$'sec\'ret $? []'
  CERT_MODE="existing"
  CF_ZONE_ID="zone-id"
  CF_CERT_VALIDITY="5475"
  ACME_EMAIL="ops@example.com"
  ACME_CA="letsencrypt"
  CF_DNS_ACCOUNT_ID="account-id"
  CF_DNS_ZONE_ID="dns-zone-id"
  XHTTP_ECH_CONFIG_LIST="https://1.1.1.1/dns-query"
  XHTTP_ECH_FORCE_QUERY="ipv4"
  XHTTP_XPADDING_ENABLED="yes"
  XHTTP_XPADDING_KEY="x_padding"
  XHTTP_XPADDING_HEADER="Referer"
  XHTTP_XPADDING_PLACEMENT="queryInHeader"
  XHTTP_XPADDING_METHOD="tokenish"

  write_xray_config
  write_state_file
  OUTPUT_CLIENT_NAME=""
  write_output_file

  jq -e '.routing.rules | length == 2' "${XRAY_CONFIG_FILE}" >/dev/null
  jq -e '.outbounds[] | select(.tag == "WARP") | .settings.servers[0].port == 40000' "${XRAY_CONFIG_FILE}" >/dev/null
  jq -e '.inbounds[] | select(.tag == "xhttp-cdn") | .streamSettings.xhttpSettings.xPaddingObfsMode == true' "${XRAY_CONFIG_FILE}" >/dev/null
  jq -e '.inbounds[] | select(.tag == "xhttp-cdn") | .streamSettings.xhttpSettings.xPaddingHeader == "Referer"' "${XRAY_CONFIG_FILE}" >/dev/null
  bash -n "${STATE_FILE}"

  # shellcheck disable=SC1090
  source "${STATE_FILE}"
  [[ "${WARP_CLIENT_SECRET}" == $'sec\'ret $? []' ]]

  assert_contains '&ech=' "${OUTPUT_FILE}"
  assert_contains 'extra=' "${OUTPUT_FILE}"
  assert_contains 'xPaddingObfsMode' "${OUTPUT_FILE}"
  assert_contains 'xmux' "${OUTPUT_FILE}"
  assert_contains 'maxConcurrency' "${OUTPUT_FILE}"
  assert_contains 'hMaxReusableSecs' "${OUTPUT_FILE}"
  assert_contains 'scMinPostsIntervalMs' "${OUTPUT_FILE}"
  assert_contains 'alpn=h2' "${OUTPUT_FILE}"
  assert_contains 'fingerprint=chrome' "${OUTPUT_FILE}"
  assert_contains 'encryption=enc-value-%2B%3D%3F%26' "${OUTPUT_FILE}"
  assert_contains '已启用: 是' "${OUTPUT_FILE}"
  assert_contains '## XHTTP 缓存绕过（重要）' "${OUTPUT_FILE}"
  assert_contains "Raw VLESS 订阅: ${SUBSCRIPTION_RAW_FILE}" "${OUTPUT_FILE}"
  assert_contains "Base64 VLESS 订阅: ${SUBSCRIPTION_BASE64_FILE}" "${OUTPUT_FILE}"
  assert_contains '(http.host eq "cdn.example.com") or (http.request.uri.path contains "/assets/v3")' "${OUTPUT_FILE}"
  assert_contains '推荐操作步骤：' "${OUTPUT_FILE}"
  assert_contains 'Cache eligibility' "${OUTPUT_FILE}"
  if grep -q '## Clash Meta / Mihomo 片段' "${OUTPUT_FILE}"; then
    return 1
  fi
  if grep -q '## sing-box outbound 片段' "${OUTPUT_FILE}"; then
    return 1
  fi
  [[ -f "${SUBSCRIPTION_RAW_FILE}" ]]
  [[ -f "${SUBSCRIPTION_BASE64_FILE}" ]]
  [[ -f "${SUBSCRIPTION_MANIFEST_FILE}" ]]
  [[ "$(grep -c '^vless://' "${SUBSCRIPTION_RAW_FILE}")" -eq 5 ]]
  base64 -d "${SUBSCRIPTION_BASE64_FILE}" | grep -q '^vless://'
  if [[ -f "${SUBSCRIPTION_RAW_QR_FILE}" || -f "${SUBSCRIPTION_BASE64_QR_FILE}" ]]; then
    return 1
  fi
}

run_multi_client_config_output_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults

  SERVER_IP="203.0.113.40"
  NODE_LABEL_PREFIX="HKG"
  REALITY_UUID="11111111-1111-1111-1111-111111111111"
  REALITY_SNI="reality.example.com"
  REALITY_TARGET="www.scu.edu:443"
  REALITY_SHORT_ID="abcd1234"
  REALITY_PRIVATE_KEY="private-key-value"
  REALITY_PUBLIC_KEY="public-key-value"
  XHTTP_UUID="22222222-2222-2222-2222-222222222222"
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/assets/v3"
  XHTTP_VLESS_ENCRYPTION_ENABLED="no"
  XHTTP_VLESS_ENCRYPTION=""
  XHTTP_VLESS_DECRYPTION="none"
  TLS_ALPN="h2"
  FINGERPRINT="chrome"
  ENABLE_WARP="no"
  ENABLE_NET_OPT="no"
  WARP_PROXY_PORT="40000"
  CERT_MODE="existing"
  NODE_CLIENTS_TEXT="phone|33333333-3333-3333-3333-333333333333|44444444-4444-4444-4444-444444444444"

  write_xray_config
  write_output_file phone

  jq -e '.inbounds[] | select(.tag == "reality-vision") | .settings.clients | length == 2' "${XRAY_CONFIG_FILE}" >/dev/null
  jq -e '.inbounds[] | select(.tag == "reality-vision") | .settings.clients[] | select(.email == "phone-reality-vision") | .id == "33333333-3333-3333-3333-333333333333"' "${XRAY_CONFIG_FILE}" >/dev/null
  jq -e '.inbounds[] | select(.tag == "xhttp-cdn") | .settings.clients[] | select(.email == "phone-xhttp-cdn") | .id == "44444444-4444-4444-4444-444444444444"' "${XRAY_CONFIG_FILE}" >/dev/null

  assert_contains 'HKG-phone-REALITY' "${OUTPUT_FILE}"
  assert_contains 'HKG-phone-XHTTP-CDN' "${OUTPUT_FILE}"
  assert_contains '- 当前导出: phone' "${OUTPUT_FILE}"
  assert_contains '- UUID: 33333333-3333-3333-3333-333333333333' "${OUTPUT_FILE}"
  assert_contains '- UUID: 44444444-4444-4444-4444-444444444444' "${OUTPUT_FILE}"
  assert_contains '33333333-3333-3333-3333-333333333333@203.0.113.40:443' "${SUBSCRIPTION_RAW_FILE}"
  assert_contains '44444444-4444-4444-4444-444444444444@cdn.example.com:443' "${SUBSCRIPTION_RAW_FILE}"
  if grep -q '11111111-1111-1111-1111-111111111111' "${SUBSCRIPTION_RAW_FILE}"; then
    return 1
  fi
  if grep -q '22222222-2222-2222-2222-222222222222' "${SUBSCRIPTION_RAW_FILE}"; then
    return 1
  fi
  [[ "$(grep -c '^vless://' "${SUBSCRIPTION_RAW_FILE}")" -eq 5 ]]

  OUTPUT_CLIENT_NAME=""
  write_output_file
  assert_contains 'HKG-REALITY' "${OUTPUT_FILE}"
  if grep -q 'HKG-phone-REALITY' "${OUTPUT_FILE}"; then
    return 1
  fi
}

run_warp_disabled_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults

  SERVER_IP="203.0.113.11"
  NODE_LABEL_PREFIX="SFO"
  REALITY_UUID="33333333-3333-3333-3333-333333333333"
  REALITY_SNI="reality2.example.com"
  REALITY_TARGET="www.stanford.edu:443"
  REALITY_SHORT_ID="efgh5678"
  REALITY_PRIVATE_KEY="private-key-2"
  REALITY_PUBLIC_KEY="public-key-2"
  XHTTP_UUID="44444444-4444-4444-4444-444444444444"
  XHTTP_DOMAIN="cdn2.example.com"
  XHTTP_PATH="/x"
  XHTTP_VLESS_ENCRYPTION_ENABLED="no"
  XHTTP_VLESS_ENCRYPTION=""
  XHTTP_VLESS_DECRYPTION="none"
  TLS_ALPN="h2"
  FINGERPRINT="chrome"
  ENABLE_WARP="no"
  ENABLE_NET_OPT="no"
  WARP_PROXY_PORT="40000"
  CERT_MODE="self-signed"
  XHTTP_ECH_CONFIG_LIST=""
  XHTTP_ECH_FORCE_QUERY=""
  XHTTP_XPADDING_ENABLED="no"
  XHTTP_XPADDING_KEY="x_padding"
  XHTTP_XPADDING_HEADER="Referer"
  XHTTP_XPADDING_PLACEMENT="queryInHeader"
  XHTTP_XPADDING_METHOD="tokenish"

  write_xray_config
  write_output_file

  jq -e '.routing.rules | length == 0' "${XRAY_CONFIG_FILE}" >/dev/null
  jq -e '.outbounds | length == 2' "${XRAY_CONFIG_FILE}" >/dev/null
  if jq -e '.inbounds[] | select(.tag == "xhttp-cdn") | .streamSettings.xhttpSettings.xPaddingObfsMode' "${XRAY_CONFIG_FILE}" >/dev/null; then
    return 1
  fi

  if grep -q '&ech=' "${OUTPUT_FILE}"; then
    return 1
  fi

  assert_contains 'Cloudflare SSL/TLS 模式设置为 Full。' "${OUTPUT_FILE}"
  assert_contains 'encryption=none' "${OUTPUT_FILE}"
  assert_contains 'xmux' "${OUTPUT_FILE}"
  assert_contains 'maxConcurrency' "${OUTPUT_FILE}"
  assert_contains 'scMinPostsIntervalMs' "${OUTPUT_FILE}"
}

run_warp_rules_file_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults
  WARP_RULES_FILE="${workdir}/warp-domains.list"

  SERVER_IP="203.0.113.15"
  REALITY_UUID="88888888-8888-8888-8888-888888888888"
  REALITY_SNI="reality5.example.com"
  REALITY_TARGET="www.scu.edu:443"
  REALITY_SHORT_ID="qrst7890"
  REALITY_PRIVATE_KEY="private-key-5"
  XHTTP_UUID="99999999-9999-9999-9999-999999999999"
  XHTTP_PATH="/assets/v4"
  ENABLE_WARP="yes"
  WARP_PROXY_PORT="41000"
  printf '%s\n' 'domain:custom.example.com' 'geosite:google' > "${WARP_RULES_FILE}"

  write_xray_config

  jq -e '.routing.rules[] | select(.outboundTag == "WARP") | .domain == ["domain:custom.example.com","geosite:google"]' "${XRAY_CONFIG_FILE}" >/dev/null
}

run_output_helper_case() {
  reset_feature_defaults
  SERVER_IP="203.0.113.12"
  NODE_LABEL_PREFIX="hkg"
  REALITY_UUID="55555555-5555-5555-5555-555555555555"
  REALITY_SNI="reality3.example.com"
  REALITY_PUBLIC_KEY="public-key-3"
  REALITY_SHORT_ID="ijkl9012"
  FINGERPRINT="chrome"

  [[ "$(prefixed_node_label "REALITY")" == "HKG-REALITY" ]]

  CERT_MODE="self-signed"
  [[ "$(cloudflare_ssl_mode_text)" == "Full" ]]

  CERT_MODE="existing"
  [[ "$(cloudflare_ssl_mode_text)" == "Full (strict)" ]]
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/assets/v3"
  [[ "$(cloudflare_xhttp_cache_bypass_expression)" == '(http.host eq "cdn.example.com") or (http.request.uri.path contains "/assets/v3")' ]]

  [[ "$(build_reality_uri "HKG-REALITY")" == *"vless://${REALITY_UUID}@${SERVER_IP}:443"* ]]
  [[ "$(build_reality_uri "HKG-REALITY")" == *"#HKG-REALITY" ]]
  jq -e '.routeOnly == true' <<<"$(xray_sniffing_json)" >/dev/null
}

run_output_default_transport_fields_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults

  SERVER_IP="203.0.113.20"
  NODE_LABEL_PREFIX="LAX"
  REALITY_UUID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  REALITY_SNI="reality.example.com"
  REALITY_TARGET="www.cloudflare.com:443"
  REALITY_SHORT_ID="deadbeef"
  REALITY_PRIVATE_KEY="private-key"
  REALITY_PUBLIC_KEY="public-key"
  XHTTP_UUID="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/status/check"
  XHTTP_VLESS_ENCRYPTION_ENABLED="yes"
  XHTTP_VLESS_ENCRYPTION="enc-value"
  XHTTP_VLESS_DECRYPTION="enc-value"
  TLS_ALPN=""
  FINGERPRINT=""
  ENABLE_WARP="no"
  ENABLE_NET_OPT="no"
  WARP_PROXY_PORT="40000"
  CERT_MODE="existing"
  XHTTP_ECH_CONFIG_LIST=""
  XHTTP_ECH_FORCE_QUERY=""
  XHTTP_XPADDING_ENABLED="no"
  XHTTP_XPADDING_KEY="x_padding"
  XHTTP_XPADDING_HEADER="Referer"
  XHTTP_XPADDING_PLACEMENT="queryInHeader"
  XHTTP_XPADDING_METHOD="tokenish"

  write_output_file
  write_state_file

  assert_contains 'alpn=h2' "${OUTPUT_FILE}"
  assert_contains 'fp=chrome' "${OUTPUT_FILE}"
  assert_contains 'fingerprint=chrome' "${OUTPUT_FILE}"
  assert_contains '- ALPN: h2' "${OUTPUT_FILE}"
  assert_contains '- 指纹: chrome' "${OUTPUT_FILE}"
  assert_contains 'TLS_ALPN=h2' "${STATE_FILE}"
  assert_contains 'FINGERPRINT=chrome' "${STATE_FILE}"
}

run_service_config_helper_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  NGINX_CONF_DIR="${workdir}/nginx"
  reset_feature_defaults
  NGINX_CONFIG_FILE="${NGINX_CONF_DIR}/xtun.conf"
  HAPROXY_CONFIG="${workdir}/haproxy.cfg"
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/assets/v3"
  XHTTP_LOCAL_PORT="8001"
  NGINX_TLS_PORT="8443"
  TLS_CERT_FILE="/etc/ssl/xtun/cert.pem"
  TLS_KEY_FILE="/etc/ssl/xtun/key.pem"
  CORE_HEALTH_HELPER="${workdir}/core-health.sh"
  CORE_HEALTH_SERVICE_FILE="${workdir}/core-health.service"
  CORE_HEALTH_TIMER_FILE="${workdir}/core-health.timer"
  CORE_HEALTH_SERVICE_NAME="xtun-core-health.service"
  CORE_HEALTH_TIMER_NAME="xtun-core-health.timer"
  HEALTH_STATE_FILE="${workdir}/health-state.env"
  HEALTH_HISTORY_FILE="${workdir}/health-history.log"

  write_nginx_config
  write_haproxy_config
  write_core_health_monitor

  assert_contains 'server_name cdn.example.com;' "${NGINX_CONFIG_FILE}"
  assert_contains 'proxy_pass https://www.harvard.edu;' "${NGINX_CONFIG_FILE}"
  assert_contains 'grpc_pass 127.0.0.1:8001;' "${NGINX_CONFIG_FILE}"
  assert_contains 'use_backend be_xhttp_cdn if { req.ssl_sni -i cdn.example.com }' "${HAPROXY_CONFIG}"
  assert_contains 'server nginx_cdn 127.0.0.1:8443 check' "${HAPROXY_CONFIG}"
  assert_contains 'check_port 443' "${CORE_HEALTH_HELPER}"
  assert_contains 'check_port 2443' "${CORE_HEALTH_HELPER}"
  assert_contains 'check_port 8001' "${CORE_HEALTH_HELPER}"
  assert_contains "health_state_file='${HEALTH_STATE_FILE}'" "${CORE_HEALTH_HELPER}"
  assert_contains "health_history_file='${workdir}/health-history.log'" "${CORE_HEALTH_HELPER}"
  assert_contains 'dirname "${health_state_file}"' "${CORE_HEALTH_HELPER}"
  assert_contains '$(date -u '\''+%Y-%m-%dT%H:%M:%SZ'\'')' "${CORE_HEALTH_HELPER}"
  assert_contains "ExecStart=${CORE_HEALTH_HELPER}" "${CORE_HEALTH_SERVICE_FILE}"
  assert_contains 'OnUnitActiveSec=3min' "${CORE_HEALTH_TIMER_FILE}"
  assert_contains "Unit=${CORE_HEALTH_SERVICE_NAME}" "${CORE_HEALTH_TIMER_FILE}"
  XRAY_LOGROTATE_FILE="${workdir}/xray-logrotate"
  write_xray_logrotate_config
  assert_contains '/var/log/xray/access.log /var/log/xray/error.log /var/log/xtun/operations.log {' "${XRAY_LOGROTATE_FILE}"
  assert_contains 'rotate 7' "${XRAY_LOGROTATE_FILE}"
}

run_xray_config_escape_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults

  SERVER_IP="203.0.113.13"
  REALITY_UUID="66666666-6666-6666-6666-666666666666"
  REALITY_SNI="reality4.example.com"
  REALITY_TARGET='mirror"host.example.com:443'
  REALITY_SHORT_ID="mnop3456"
  REALITY_PRIVATE_KEY='private"key'
  XHTTP_UUID="77777777-7777-7777-7777-777777777777"
  XHTTP_PATH='/assets/"quoted"'
  XHTTP_VLESS_ENCRYPTION_ENABLED="yes"
  XHTTP_VLESS_DECRYPTION='enc"value'
  XHTTP_VLESS_ENCRYPTION='enc"value'
  ENABLE_WARP="no"
  WARP_PROXY_PORT="40000"

  write_xray_config

  jq -e '.inbounds[] | select(.tag == "reality-vision") | .streamSettings.realitySettings.target == "mirror\"host.example.com:443"' "${XRAY_CONFIG_FILE}" >/dev/null
  jq -e '.inbounds[] | select(.tag == "reality-vision") | .streamSettings.realitySettings.privateKey == "private\"key"' "${XRAY_CONFIG_FILE}" >/dev/null
  jq -e '.inbounds[] | select(.tag == "xhttp-cdn") | .streamSettings.xhttpSettings.path == "/assets/\"quoted\""' "${XRAY_CONFIG_FILE}" >/dev/null
  jq -e '.inbounds[] | select(.tag == "xhttp-cdn") | .settings.decryption == "enc\"value"' "${XRAY_CONFIG_FILE}" >/dev/null
}

run_generated_file_atomic_failure_case() {
  local workdir=""
  local status=0

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults
  NGINX_CONF_DIR="${workdir}/nginx"
  NGINX_CONFIG_FILE="${NGINX_CONF_DIR}/xtun.conf"
  HAPROXY_CONFIG="${workdir}/haproxy.cfg"
  mkdir -p "${NGINX_CONF_DIR}"

  printf 'old-xray\n' > "${XRAY_CONFIG_FILE}"
  printf 'old-nginx\n' > "${NGINX_CONFIG_FILE}"
  printf 'old-haproxy\n' > "${HAPROXY_CONFIG}"

  fail_producer() {
    return 1
  }

  set +e
  write_generated_file_atomically "${XRAY_CONFIG_FILE}" fail_producer >/dev/null 2>&1
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == "old-xray" ]]

  set +e
  write_generated_file_atomically "${NGINX_CONFIG_FILE}" fail_producer >/dev/null 2>&1
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  [[ "$(cat "${NGINX_CONFIG_FILE}")" == "old-nginx" ]]

  set +e
  write_generated_file_atomically "${HAPROXY_CONFIG}" fail_producer >/dev/null 2>&1
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  [[ "$(cat "${HAPROXY_CONFIG}")" == "old-haproxy" ]]

  if find "${workdir}" -name '.*.tmp.*' | grep -q .; then
    return 1
  fi
}

run_subscription_qr_success_case() {
  local workdir=""
  local fakebin=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults
  fakebin="${workdir}/bin"
  mkdir -p "${fakebin}"
  cat > "${fakebin}/qrencode" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      shift
      printf 'png\n' > "$1"
      exit 0
      ;;
  esac
  shift
done
exit 0
EOF
  chmod +x "${fakebin}/qrencode"
  PATH="${fakebin}:${PATH}"

  SERVER_IP="203.0.113.30"
  NODE_LABEL_PREFIX="HKG"
  REALITY_UUID="11111111-1111-1111-1111-111111111111"
  REALITY_SNI="reality.example.com"
  REALITY_TARGET="www.scu.edu:443"
  REALITY_SHORT_ID="abcd1234"
  REALITY_PUBLIC_KEY="public-key-value"
  XHTTP_UUID="22222222-2222-2222-2222-222222222222"
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/assets/v3"
  XHTTP_VLESS_ENCRYPTION_ENABLED="no"
  XHTTP_VLESS_ENCRYPTION=""
  XHTTP_VLESS_DECRYPTION="none"
  ENABLE_WARP="no"
  ENABLE_NET_OPT="no"
  WARP_PROXY_PORT="40000"
  CERT_MODE="existing"

  write_output_file

  [[ -f "${SUBSCRIPTION_RAW_QR_FILE}" ]]
  [[ -f "${SUBSCRIPTION_BASE64_QR_FILE}" ]]
  assert_contains "Raw QR PNG:" "${SUBSCRIPTION_MANIFEST_FILE}"
  assert_contains "${SUBSCRIPTION_RAW_QR_FILE}" "${OUTPUT_FILE}"
}
