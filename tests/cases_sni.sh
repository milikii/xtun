# shellcheck shell=bash

run_sni_judge_tls_case() {
  local normal=""
  local no_h2=""
  local tls12=""

  normal='Protocol  : TLSv1.3
Cipher    : TLS_AES_128_GCM_SHA256
Peer Temp Key: X25519, 253 bits
ALPN protocol: h2
Verify return code: 0 (ok)'
  no_h2='Protocol  : TLSv1.3
Peer Temp Key: X25519, 253 bits
Verify return code: 0 (ok)'
  tls12='Protocol  : TLSv1.2
Verify return code: 0 (ok)'

  local out=""
  out="$(sni_judge_tls "${normal}")"
  printf '%s\n' "${out}" | grep -q '^PASS|TLS 1.3|'
  printf '%s\n' "${out}" | grep -q '^PASS|X25519|'
  printf '%s\n' "${out}" | grep -q '^PASS|HTTP/2 ALPN|'
  printf '%s\n' "${out}" | grep -q '^PASS|证书链|'
  [[ "$(printf '%s\n' "${out}" | grep -c '^PASS')" -eq 4 ]]

  out="$(sni_judge_tls "${no_h2}")"
  printf '%s\n' "${out}" | grep -q '^FAIL|HTTP/2 ALPN|'
  [[ "$(printf '%s\n' "${out}" | grep -c '^PASS')" -eq 3 ]]

  out="$(sni_judge_tls "${tls12}")"
  printf '%s\n' "${out}" | grep -q '^FAIL|TLS 1.3|'
  printf '%s\n' "${out}" | grep -q '^FAIL|X25519|'
}

run_sni_judge_http_case() {
  local out=""

  out="$(sni_judge_http 'www.x.com' '200 2  0.02')"
  printf '%s\n' "${out}" | grep -q '^PASS|HTTP 跳转|'
  printf '%s\n' "${out}" | grep -q '^PASS|HTTP 版本|'
  printf '%s\n' "${out}" | grep -q '^PASS|握手耗时|'

  out="$(sni_judge_http 'www.x.com' '301 2 https://www.x.com/ 0.02')"
  printf '%s\n' "${out}" | grep -q '^WARN|HTTP 跳转|'

  out="$(sni_judge_http 'x.com' '301 2 https://www.x.com/ 0.02')"
  printf '%s\n' "${out}" | grep -q '^FAIL|HTTP 跳转|'

  out="$(sni_judge_http 'www.x.com' '403 2  0.02')"
  printf '%s\n' "${out}" | grep -q '^WARN|HTTP 跳转|'

  out="$(sni_judge_http 'www.x.com' '000 0  0')"
  printf '%s\n' "${out}" | grep -q '^FAIL|HTTP 跳转|'

  out="$(sni_judge_http 'www.x.com' '200 2  1.4')"
  printf '%s\n' "${out}" | grep -q '^FAIL|握手耗时|'

  out="$(sni_judge_http 'www.x.com' '200 2  0.5')"
  printf '%s\n' "${out}" | grep -q '^WARN|握手耗时|'
}

run_sni_judge_cert_case() {
  local out=""
  local now=""

  now="$(date '+%s')"

  # SAN 精确匹配 + 到期充足 + 非 CDN 签发
  out="$(sni_judge_cert 'www.stanford.edu' "SAN=DNS:www.stanford.edu
NOTAFTER=$(date -d '+76 days' '+%b %e %H:%M:%S %Y GMT')
ISSUER=C=US, O=Some University, CN=Some University CA" "${now}")"
  printf '%s\n' "${out}" | grep -q '^PASS|证书 SAN|'
  printf '%s\n' "${out}" | grep -q '^PASS|证书到期|'
  printf '%s\n' "${out}" | grep -q '^PASS|CDN 前置|'

  # SAN 通配符匹配
  out="$(sni_judge_cert 'cdn.example.com' "SAN=DNS:*.example.com
NOTAFTER=$(date -d '+76 days' '+%b %e %H:%M:%S %Y GMT')
ISSUER=C=US, O=Some CA" "${now}")"
  printf '%s\n' "${out}" | grep -q '^PASS|证书 SAN|'

  # SAN 不匹配
  out="$(sni_judge_cert 'www.stanford.edu' "SAN=DNS:other.example.com
NOTAFTER=$(date -d '+76 days' '+%b %e %H:%M:%S %Y GMT')
ISSUER=C=US, O=Some CA" "${now}")"
  printf '%s\n' "${out}" | grep -q '^FAIL|证书 SAN|'

  # 到期不足 14 天
  out="$(sni_judge_cert 'www.stanford.edu' "SAN=DNS:www.stanford.edu
NOTAFTER=$(date -d '+10 days' '+%b %e %H:%M:%S %Y GMT')
ISSUER=C=US, O=Some CA" "${now}")"
  printf '%s\n' "${out}" | grep -q '^FAIL|证书到期|'

  # issuer 含 Cloudflare → CDN 前置 WARN
  out="$(sni_judge_cert 'www.x.com' "SAN=DNS:www.x.com
NOTAFTER=$(date -d '+76 days' '+%b %e %H:%M:%S %Y GMT')
ISSUER=C=US, O=Cloudflare, Inc., CN=Cloudflare Inc ECC CA-3" "${now}")"
  printf '%s\n' "${out}" | grep -q '^WARN|CDN 前置|'
}

run_sni_judge_dns_case() {
  local out=""

  out="$(sni_judge_dns 'www.x.com' 'www.x.com' '171.67.215.200' '203.0.113.9')"
  printf '%s\n' "${out}" | grep -q '^PASS|DNS 解析|'

  out="$(sni_judge_dns 'www.x.com' 'www.x.com' '203.0.113.9' '203.0.113.9')"
  printf '%s\n' "${out}" | grep -q '^FAIL|DNS 解析|'
  printf '%s\n' "${out}" | grep -q '回环'

  out="$(sni_judge_dns 'www.x.com' 'www.x.com' '192.168.1.10' '203.0.113.9')"
  printf '%s\n' "${out}" | grep -q '^FAIL|DNS 解析|'

  out="$(sni_judge_dns 'www.x.com' 'www.x.com' '' '203.0.113.9')"
  printf '%s\n' "${out}" | grep -q '^FAIL|DNS 解析|'
}

run_sni_probe_http_target_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  SNI_CURL_ARGS_FILE="${workdir}/curl-args.txt"
  curl() { printf '%s\n' "$*" >> "${SNI_CURL_ARGS_FILE}"; }
  timeout() {
    shift
    curl "$@"
  }

  sni_probe_http 'www.stanford.edu' '1.2.3.4:8443' 5 > /dev/null
  grep -Fq -- '--connect-to www.stanford.edu:443:1.2.3.4:8443' "${SNI_CURL_ARGS_FILE}"
  grep -Fq -- 'https://www.stanford.edu/' "${SNI_CURL_ARGS_FILE}"

  SNI_CURL_ARGS_FILE="${workdir}/curl-args-default-port.txt"
  sni_probe_http 'www.stanford.edu' 'www.stanford.edu:443' 5 > /dev/null
  grep -Fq -- '--connect-to www.stanford.edu:443:www.stanford.edu:443' "${SNI_CURL_ARGS_FILE}"

  unset -f curl timeout
  unset SNI_CURL_ARGS_FILE
  rm -rf "${workdir}"
}

run_sni_check_cmd_case() {
  local workdir=""
  local status=0

  workdir="$(mktemp -d)"
  XRAY_CONFIG_FILE="${workdir}/missing-config.json"
  STATE_FILE="${workdir}/missing-state.env"

  sni_probe_dns() { printf '171.67.215.200\n'; }
  sni_probe_tls() { printf 'Protocol  : TLSv1.3\nPeer Temp Key: X25519, 253 bits\nALPN protocol: h2\nVerify return code: 0 (ok)\n'; }
  sni_probe_cert() {
    printf 'SAN=DNS:%s\nNOTAFTER=%s\nISSUER=C=US, O=Some CA\n' \
      "${2}" "$(date -d '+76 days' '+%b %e %H:%M:%S %Y GMT')"
  }
  sni_probe_http() { printf '200 2  0.02 nginx\n'; }

  set +e
  run_sni_checks 'www.stanford.edu' 'www.stanford.edu:443' '203.0.113.9' 10 > "${workdir}/out.txt"
  status=$?
  set -e
  [[ "${status}" -eq 0 ]]
  printf '%s\n' "$(cat "${workdir}/out.txt")" | grep -q '结论: 通过'

  sni_probe_tls() { printf 'Protocol  : TLSv1.2\n'; }
  set +e
  run_sni_checks 'www.stanford.edu' 'www.stanford.edu:443' '203.0.113.9' 10 > "${workdir}/out2.txt"
  status=$?
  set -e
  [[ "${status}" -eq 2 ]]
  printf '%s\n' "$(cat "${workdir}/out2.txt")" | grep -q '结论: 不通过'

  # 参数错误：timeout 非数字退出 1
  set +e
  ( sni_check_cmd --timeout abc ) > /dev/null 2>&1
  status=$?
  set -e
  [[ "${status}" -eq 1 ]]

  # --target 覆盖
  sni_probe_dns() {
    [[ "${1}" == '1.2.3.4' ]] || return 1
    printf '1.2.3.4\n'
  }
  # run_sni_checks 此时仍会退 2（TLS 探测桩还是 1.2），只断言表头与目标参数
  output="$(sni_check_cmd www.stanford.edu --target 1.2.3.4:443 2>/dev/null)" || true
  printf '%s\n' "${output}" | grep -q '(target 1.2.3.4:443)'

  # 菜单 10 无参数：从已保存状态回填 SNI / target / 本机 IP
  STATE_FILE="${workdir}/state.env"
  cat > "${STATE_FILE}" <<'EOF'
SERVER_IP='203.0.113.9'
REALITY_SNI='www.stanford.edu'
REALITY_TARGET='www.stanford.edu:443'
EOF
  run_sni_checks() { printf '%s|%s|%s|%s\n' "$@"; }
  output="$(sni_check_cmd)"
  [[ "${output}" == "www.stanford.edu|www.stanford.edu:443|203.0.113.9|10" ]]

  rm -rf "${workdir}"
  load_functions
}

run_install_preflight_sni_case() {
  local status=0

  NON_INTERACTIVE=1
  SERVER_IP="203.0.113.9"
  REALITY_SNI="www.stanford.edu"
  REALITY_TARGET="www.stanford.edu:443"
  SKIP_SNI_CHECK=0

  # 预检有 FAIL 且非交互 → die
  run_sni_checks() { return 2; }
  set +e
  ( preflight_check_reality_sni ) >/dev/null 2>&1
  status=$?
  set -e
  assert_false test "${status}" -eq 0

  # --skip-sni-check → 直接跳过
  SKIP_SNI_CHECK=1
  local output=""
  output="$(preflight_check_reality_sni 2>&1)"
  printf '%s\n' "${output}" | grep -q '跳过 Reality 目标域名预检'
  SKIP_SNI_CHECK=0

  # 预检通过 → 0
  run_sni_checks() { return 0; }
  preflight_check_reality_sni

  load_functions
}

# §5.7 dokodemo-door 回落
run_reality_fallback_inbound_case() {
  local workdir=""
  local config_text=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults

  SERVER_IP="203.0.113.10"
  REALITY_UUID="11111111-1111-1111-1111-111111111111"
  REALITY_SNI="www.stanford.edu"
  REALITY_TARGET="www.stanford.edu:443"
  REALITY_SHORT_ID="abcd1234"
  REALITY_PRIVATE_KEY="private-key-value"
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

  config_text="$(xray_config_text)"

  # reality 入站的 target 固定指向本机 dokodemo
  jq -e '.inbounds[] | select(.tag == "reality-vision") | .streamSettings.realitySettings.target == "127.0.0.1:2444"' <<<"${config_text}" >/dev/null
  jq -e '.inbounds[] | select(.tag == "reality-vision") | .streamSettings.realitySettings.serverNames == ["www.stanford.edu"]' <<<"${config_text}" >/dev/null

  # dokodemo 入站
  jq -e '.inbounds[1].tag == "reality-fallback"' <<<"${config_text}" >/dev/null
  jq -e '.inbounds[1].protocol == "dokodemo-door"' <<<"${config_text}" >/dev/null
  jq -e '.inbounds[1].listen == "127.0.0.1"' <<<"${config_text}" >/dev/null
  jq -e '.inbounds[1].port == 2444' <<<"${config_text}" >/dev/null
  jq -e '.inbounds[1].settings.address == "www.stanford.edu"' <<<"${config_text}" >/dev/null
  jq -e '.inbounds[1].settings.port == 443' <<<"${config_text}" >/dev/null
  jq -e '.inbounds[1].sniffing.destOverride == ["tls"]' <<<"${config_text}" >/dev/null
  jq -e '.inbounds[1].sniffing.routeOnly == true' <<<"${config_text}" >/dev/null

  # 路由最前两条：SNI 命中放行，其余 blackhole
  jq -e '.routing.rules[0].inboundTag == ["reality-fallback"]' <<<"${config_text}" >/dev/null
  jq -e '.routing.rules[0].domain == ["full:www.stanford.edu"]' <<<"${config_text}" >/dev/null
  jq -e '.routing.rules[0].outboundTag == "direct"' <<<"${config_text}" >/dev/null
  jq -e '.routing.rules[1].inboundTag == ["reality-fallback"]' <<<"${config_text}" >/dev/null
  jq -e '.routing.rules[1].outboundTag == "block"' <<<"${config_text}" >/dev/null

  # xray -test 真跑一遍（并入 config 有效性）
  printf '%s' "${config_text}" > "${XRAY_CONFIG_FILE}"
  XRAY_UID="" XRAY_GID=""
  bash -n "${XRAY_CONFIG_FILE}" 2>/dev/null || true

  # IP 目标、非 443 端口同样拆得对
  REALITY_TARGET="203.0.113.10:8443"
  jq -e '.settings.address == "203.0.113.10"' <<<"$(xray_reality_fallback_inbound_json)" >/dev/null
  jq -e '.settings.port == 8443' <<<"$(xray_reality_fallback_inbound_json)" >/dev/null

  # 状态回填：从新形状 config 读回 REALITY_TARGET
  REALITY_TARGET=""
  load_config_runtime_context
  [[ "${REALITY_TARGET}" == "www.stanford.edu:443" ]]
}
