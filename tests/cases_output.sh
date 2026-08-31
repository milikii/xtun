# shellcheck shell=bash

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
  set_test_warp_credentials
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
  jq -e '.outbounds[] | select(.tag == "WARP") | .protocol == "wireguard"' "${XRAY_CONFIG_FILE}" >/dev/null
  jq -e '.outbounds[] | select(.tag == "WARP") | .settings.secretKey == "'"${TEST_WARP_PRIVATE_KEY}"'"' "${XRAY_CONFIG_FILE}" >/dev/null
  jq -e '.outbounds[] | select(.tag == "WARP") | .settings.address == ["172.16.0.2/32", "2606:4700:110:8a1b:cafe:1:2:3/128"]' "${XRAY_CONFIG_FILE}" >/dev/null
  jq -e '.outbounds[] | select(.tag == "WARP") | .settings.reserved == [3, 4, 5]' "${XRAY_CONFIG_FILE}" >/dev/null
  jq -e '.outbounds[] | select(.tag == "WARP") | .settings.peers[0].endpoint == "'"${DEFAULT_WARP_ENDPOINT}"'"' "${XRAY_CONFIG_FILE}" >/dev/null
  jq -e '.inbounds[] | select(.tag == "xhttp-cdn") | .streamSettings.xhttpSettings.xPaddingObfsMode == true' "${XRAY_CONFIG_FILE}" >/dev/null
  jq -e '.inbounds[] | select(.tag == "xhttp-cdn") | .streamSettings.xhttpSettings.xPaddingHeader == "Referer"' "${XRAY_CONFIG_FILE}" >/dev/null
  bash -n "${STATE_FILE}"

  # shellcheck disable=SC1090
  source "${STATE_FILE}"
  [[ "${WARP_PRIVATE_KEY}" == "${TEST_WARP_PRIVATE_KEY}" ]]
  [[ "${WARP_RESERVED}" == "3,4,5" ]]

  if grep -q "${TEST_WARP_PRIVATE_KEY}" "${OUTPUT_FILE}"; then
    return 1
  fi
  if grep -q "${TEST_WARP_PRIVATE_KEY}" "${SUBSCRIPTION_MANIFEST_FILE}"; then
    return 1
  fi

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
  set_test_warp_credentials
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
  assert_contains 'root /var/www/xtun-fallback;' "${NGINX_CONFIG_FILE}"
  assert_contains 'try_files $uri $uri/ /index.html;' "${NGINX_CONFIG_FILE}"
  assert_contains 'grpc_pass grpc://xtun_xhttp;' "${NGINX_CONFIG_FILE}"
  # upstream 块必须在 server 块外面，否则 nginx 直接起不来
  assert_contains 'upstream xtun_xhttp {' "${NGINX_CONFIG_FILE}"
  assert_contains 'server 127.0.0.1:8001;' "${NGINX_CONFIG_FILE}"
  assert_contains 'keepalive 64;' "${NGINX_CONFIG_FILE}"
  [[ "$(awk '/^upstream xtun_xhttp \{/ { print NR; exit }' "${NGINX_CONFIG_FILE}")" -lt \
     "$(awk '/^server \{/ { print NR; exit }' "${NGINX_CONFIG_FILE}")" ]]
  # 直连上游会退回一请求一连接，把 TIME-WAIT 重新堆起来
  assert_absent 'grpc_pass 127.0.0.1' "${NGINX_CONFIG_FILE}"
  # upstream 里那行 server 不能把状态回填的 server 块解析器带偏
  [[ "$(nginx_server_name "${XHTTP_PATH}")" == "cdn.example.com" ]]
  assert_contains 'grpc_read_timeout 1h;' "${NGINX_CONFIG_FILE}"
  assert_contains 'grpc_send_timeout 1h;' "${NGINX_CONFIG_FILE}"
  assert_contains 'grpc_buffer_size 64k;' "${NGINX_CONFIG_FILE}"
  assert_contains 'use_backend be_xhttp_cdn if { req.ssl_sni -i cdn.example.com }' "${HAPROXY_CONFIG}"
  assert_contains 'timeout tunnel 1h' "${HAPROXY_CONFIG}"
  assert_contains 'option splice-request' "${HAPROXY_CONFIG}"
  assert_contains 'option splice-response' "${HAPROXY_CONFIG}"
  assert_contains 'option tcp-smart-accept' "${HAPROXY_CONFIG}"
  assert_contains 'option tcp-smart-connect' "${HAPROXY_CONFIG}"
  # nbthread 由 HAProxy 自己按 CPU 数决定，写死只会把线程数改少
  assert_absent '^ *nbthread' "${HAPROXY_CONFIG}"
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

# 托管文件每次变更都是整份重写。用户块必须能原样活过下一次重写，
# 否则 renew-cert 这种自动跑的命令会无声抹掉手工调优。
run_user_block_preserve_case() {
  local workdir=""
  local first_render=""

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

  write_haproxy_config
  write_nginx_config

  # 模拟手工在标记之间加参数
  sed -i '/>>> xtun-user:haproxy-defaults >>>/a\    timeout client 5m' "${HAPROXY_CONFIG}"
  sed -i '/>>> xtun-user:haproxy-extra >>>/a\listen stats\n    bind 127.0.0.1:9000' "${HAPROXY_CONFIG}"
  sed -i '/>>> xtun-user:nginx-server >>>/a\    client_max_body_size 64m;' "${NGINX_CONFIG_FILE}"

  # 换个域名再整份重写，等价于跑一次 change-cert-mode / renew-cert
  XHTTP_DOMAIN="cdn2.example.com"
  write_haproxy_config
  write_nginx_config

  assert_contains 'timeout client 5m' "${HAPROXY_CONFIG}"
  assert_contains 'bind 127.0.0.1:9000' "${HAPROXY_CONFIG}"
  assert_contains 'client_max_body_size 64m;' "${NGINX_CONFIG_FILE}"
  assert_contains 'server_name cdn2.example.com;' "${NGINX_CONFIG_FILE}"

  # 再写一次不能把用户块或提示行复制成两份
  first_render="$(grep -c 'timeout client 5m' "${HAPROXY_CONFIG}")"
  [[ "${first_render}" -eq 1 ]]
  write_haproxy_config
  [[ "$(grep -c 'timeout client 5m' "${HAPROXY_CONFIG}")" -eq 1 ]]
  [[ "$(grep -c 'xtun-user:haproxy-defaults' "${HAPROXY_CONFIG}")" -eq 2 ]]
  [[ "$(grep -c '不会被 xtun 覆盖' "${HAPROXY_CONFIG}")" -eq 2 ]]
}

# 上面那条只走了「标记行一个字节都没被碰过」的路。标记是逐字比对的，而手工编辑
# 恰恰最容易在看不见的地方改动它：行尾多敲一个空格或 Tab，或者整份文件被某些
# 编辑器存回成 CRLF，每行尾多一个 \r。对不上的表现不是报错——是这一段手工内容
# 在下一次整份重写里无声消失，配置照样校验通过。renew-cert 由 acme.sh 定时无人
# 值守跑，真丢起来没有任何人在看。所以比对前首尾空白都要剪掉。
run_user_block_marker_whitespace_case() {
  local workdir=""
  local variant=""
  local warning=""

  workdir="$(mktemp -d)"
  reset_feature_defaults
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/assets/v3"
  XHTTP_LOCAL_PORT="8001"
  NGINX_TLS_PORT="8443"
  TLS_CERT_FILE="/etc/ssl/xtun/cert.pem"
  TLS_KEY_FILE="/etc/ssl/xtun/key.pem"

  for variant in trailing-space trailing-tab crlf; do
    NGINX_CONF_DIR="${workdir}/${variant}/nginx"
    NGINX_CONFIG_FILE="${NGINX_CONF_DIR}/xtun.conf"
    HAPROXY_CONFIG="${workdir}/${variant}/haproxy.cfg"
    write_haproxy_config
    write_nginx_config

    sed -i '/>>> xtun-user:haproxy-defaults >>>/a\    timeout client 5m' "${HAPROXY_CONFIG}"
    sed -i '/>>> xtun-user:nginx-server >>>/a\    client_max_body_size 64m;' "${NGINX_CONFIG_FILE}"

    case "${variant}" in
      # 只动标记行本身，内容行不碰
      trailing-space)
        sed -i '/xtun-user:/ s/$/ /' "${HAPROXY_CONFIG}" "${NGINX_CONFIG_FILE}"
        ;;
      trailing-tab)
        sed -i '/xtun-user:/ s/$/\t/' "${HAPROXY_CONFIG}" "${NGINX_CONFIG_FILE}"
        ;;
      # 整份存成 CRLF：标记行和内容行都多一个 \r
      crlf)
        sed -i 's/$/\r/' "${HAPROXY_CONFIG}" "${NGINX_CONFIG_FILE}"
        ;;
    esac

    write_haproxy_config
    write_nginx_config

    assert_contains 'timeout client 5m' "${HAPROXY_CONFIG}"
    assert_contains 'client_max_body_size 64m;' "${NGINX_CONFIG_FILE}"
    # 认出来之后也不能顺手多复制一份
    [[ "$(grep -c 'timeout client 5m' "${HAPROXY_CONFIG}")" -eq 1 ]]
    [[ "$(grep -c 'xtun-user:haproxy-defaults' "${HAPROXY_CONFIG}")" -eq 2 ]]
    [[ "$(grep -c 'client_max_body_size 64m;' "${NGINX_CONFIG_FILE}")" -eq 1 ]]
  done

  # 更坏的一种：只有开始标记对得上，结束标记对不上（手工编辑时删掉了，或者只有那
  # 一行被改动过）。以前的写法是命中开始标记就一路 print 到文件尾，于是结束标记后面
  # 所有 xtun 自己生成的行都被当成「用户内容」搬进新的用户块——下一轮重写时这些陈旧的
  # 托管行既重复又被永久冻结。现在改成攒够一整段才吐，没等到结束标记就一个字都不吐。
  NGINX_CONF_DIR="${workdir}/unterminated/nginx"
  NGINX_CONFIG_FILE="${NGINX_CONF_DIR}/xtun.conf"
  HAPROXY_CONFIG="${workdir}/unterminated/haproxy.cfg"
  write_haproxy_config
  sed -i '/>>> xtun-user:haproxy-defaults >>>/a\    timeout client 5m' "${HAPROXY_CONFIG}"
  sed -i '/<<< xtun-user:haproxy-defaults <<</d' "${HAPROXY_CONFIG}"

  # 整份重写不能因此失败：renew-cert 挂掉意味着证书到期断服，比丢一段手工调优贵得多，
  # 而旧文件还在备份目录里。代价换成 stderr 上的一条警告。
  warning="$(write_haproxy_config 2>&1 >/dev/null)"
  [[ "${warning}" == *"只有开始标记"* ]]
  [[ "${warning}" == *"xtun-user:haproxy-defaults"* ]]
  # 警告只能走 stderr：producer 的 stdout 就是正在生成的那份配置文件
  assert_absent '只有开始标记' "${HAPROXY_CONFIG}"

  # 结束标记后面的托管内容一行都不许被搬进用户块
  [[ "$(grep -c '^frontend fe_tls_shared_443$' "${HAPROXY_CONFIG}")" -eq 1 ]]
  [[ "$(grep -c 'bind :443' "${HAPROXY_CONFIG}")" -eq 1 ]]
  [[ "$(grep -c '^backend be_xhttp_cdn$' "${HAPROXY_CONFIG}")" -eq 1 ]]
  [[ "$(grep -c 'xtun-user:haproxy-extra' "${HAPROXY_CONFIG}")" -eq 2 ]]
  [[ "$(grep -c 'xtun-user:haproxy-defaults' "${HAPROXY_CONFIG}")" -eq 2 ]]
  # 半个块一个字都不吐，所以这一段手工内容确实丢了——这是上面那句警告要说的事
  assert_absent 'timeout client 5m' "${HAPROXY_CONFIG}"

  rm -rf "${workdir}"
}

run_fallback_site_deploy_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  FALLBACK_SITE_SOURCE_DIR="${ROOT_DIR}/static/fallback"
  FALLBACK_SITE_DIR="${workdir}/site"
  BACKUP_DIR="${workdir}/backup"
  backup_path() { :; }

  deploy_fallback_site

  [[ -f "${FALLBACK_SITE_DIR}/index.html" ]]
  [[ -f "${FALLBACK_SITE_DIR}/desk-assets/styles.css" ]]
  [[ -f "${FALLBACK_SITE_DIR}/desk-assets/site.js" ]]
  grep -q 'AI Signals Review' "${FALLBACK_SITE_DIR}/index.html"
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
  CERT_MODE="existing"

  write_output_file

  [[ -f "${SUBSCRIPTION_RAW_QR_FILE}" ]]
  [[ -f "${SUBSCRIPTION_BASE64_QR_FILE}" ]]
  assert_contains "Raw QR PNG:" "${SUBSCRIPTION_MANIFEST_FILE}"
  assert_contains "${SUBSCRIPTION_RAW_QR_FILE}" "${OUTPUT_FILE}"
}

run_warp_outbound_json_shape_case() {
  local outbound=""

  reset_feature_defaults
  ENABLE_WARP="yes"
  set_test_warp_credentials

  outbound="$(xray_warp_outbound_json)"
  jq -e '.tag == "WARP"' <<<"${outbound}" >/dev/null
  jq -e '.protocol == "wireguard"' <<<"${outbound}" >/dev/null
  jq -e '.settings.secretKey == "'"${TEST_WARP_PRIVATE_KEY}"'"' <<<"${outbound}" >/dev/null
  jq -e '.settings.address == ["172.16.0.2/32", "2606:4700:110:8a1b:cafe:1:2:3/128"]' <<<"${outbound}" >/dev/null
  jq -e '.settings.peers | length == 1' <<<"${outbound}" >/dev/null
  jq -e '.settings.peers[0].publicKey == "'"${TEST_WARP_PEER_PUBLIC_KEY}"'"' <<<"${outbound}" >/dev/null
  jq -e '.settings.peers[0].allowedIPs == ["0.0.0.0/0", "::/0"]' <<<"${outbound}" >/dev/null
  jq -e '.settings.peers[0].endpoint == "'"${DEFAULT_WARP_ENDPOINT}"'"' <<<"${outbound}" >/dev/null
  jq -e '.settings.reserved == [3, 4, 5]' <<<"${outbound}" >/dev/null
  jq -e '.settings.mtu == '"${DEFAULT_WARP_MTU}" <<<"${outbound}" >/dev/null
  jq -e '.settings.domainStrategy == "'"${DEFAULT_WARP_DOMAIN_STRATEGY}"'"' <<<"${outbound}" >/dev/null

  WARP_RESERVED=""
  outbound="$(xray_warp_outbound_json)"
  jq -e '.settings | has("reserved") | not' <<<"${outbound}" >/dev/null

  WARP_ADDRESS_V6=""
  jq -e '. == ["172.16.0.2/32"]' <<<"$(xray_warp_addresses_json)" >/dev/null
  WARP_ADDRESS_V4=""
  WARP_ADDRESS_V6="2606:4700:110:8a1b:cafe:1:2:3"
  jq -e '. == ["2606:4700:110:8a1b:cafe:1:2:3/128"]' <<<"$(xray_warp_addresses_json)" >/dev/null
  WARP_ADDRESS_V6=""
  jq -e '. == []' <<<"$(xray_warp_addresses_json)" >/dev/null

  WARP_RESERVED="1, 2,3"
  jq -e '. == [1, 2, 3]' <<<"$(xray_warp_reserved_json)" >/dev/null
}

run_warp_config_json_valid_case() {
  local workdir=""
  local config_text=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults

  SERVER_IP="203.0.113.60"
  REALITY_UUID="11111111-1111-1111-1111-111111111111"
  REALITY_SNI="reality.example.com"
  REALITY_TARGET="www.scu.edu:443"
  REALITY_SHORT_ID="abcd1234"
  REALITY_PRIVATE_KEY="private-key-value"
  XHTTP_UUID="22222222-2222-2222-2222-222222222222"
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/assets/v3"
  XHTTP_VLESS_ENCRYPTION_ENABLED="no"
  XHTTP_VLESS_ENCRYPTION=""
  XHTTP_VLESS_DECRYPTION="none"
  ENABLE_WARP="yes"
  ENABLE_NET_OPT="no"
  CERT_MODE="existing"
  set_test_warp_credentials

  config_text="$(xray_config_text)"
  jq -e '.outbounds | map(.tag) == ["direct", "WARP", "block"]' <<<"${config_text}" >/dev/null
  jq -e '.routing.rules | map(.outboundTag) == ["direct", "WARP"]' <<<"${config_text}" >/dev/null
  jq -e '[.routing.rules[] | select(.outboundTag == "WARP") | .domain[]] | length > 0' <<<"${config_text}" >/dev/null
  jq -e '.outbounds[] | select(.tag == "WARP") | .settings.peers[0].endpoint | test(":[0-9]+$")' <<<"${config_text}" >/dev/null
}
