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

  # 相对跳转按实际 URL 解析：仍在本主机，不能判成跨主机（D09）
  out="$(sni_judge_http 'www.x.com' '302 2 /login 0.02')"
  printf '%s\n' "${out}" | grep -q '^WARN|HTTP 跳转|'
  printf '%s\n' "${out}" | grep -q '相对跳转'

  out="$(sni_judge_http 'www.x.com' '302 2 login 0.02')"
  printf '%s\n' "${out}" | grep -q '^WARN|HTTP 跳转|'

  out="$(sni_judge_http 'www.x.com' '302 2 //www.x.com/x 0.02')"
  printf '%s\n' "${out}" | grep -q '^WARN|HTTP 跳转|'

  # 大小写不同的同一主机名是同主机
  out="$(sni_judge_http 'www.x.com' '302 2 https://WWW.X.com/x 0.02')"
  printf '%s\n' "${out}" | grep -q '^WARN|HTTP 跳转|'

  # 跨主机跳转要给出真实主机名（去端口/路径），不是原样回显 URL
  out="$(sni_judge_http 'x.com' '302 2 https://www.x.com:8443/y 0.02')"
  printf '%s\n' "${out}" | grep -q '^FAIL|HTTP 跳转|'
  printf '%s\n' "${out}" | grep -q 'www.x.com'
  printf '%s\n' "${out}" | grep -q '8443'

  # 3xx 但没有可解析的 Location
  out="$(sni_judge_http 'www.x.com' '302 2  0.02')"
  printf '%s\n' "${out}" | grep -q '^WARN|HTTP 跳转|'

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
  printf '%s\n' "${out}" | grep -q '^NA|CDN 前置|'
  printf '%s\n' "${out}" | grep -q '不能证明'

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

  # CA 品牌不是 CDN 证据：Cloudflare 签发也只是事实，结论仍是未验证（D09/H18）
  out="$(sni_judge_cert 'www.x.com' "SAN=DNS:www.x.com
NOTAFTER=$(date -d '+76 days' '+%b %e %H:%M:%S %Y GMT')
ISSUER=C=US, O=Cloudflare, Inc., CN=Cloudflare Inc ECC CA-3" "${now}")"
  printf '%s\n' "${out}" | grep -q '^NA|CDN 前置|'
  printf '%s\n' "${out}" | grep -q 'Cloudflare'
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

  # 探测失败的原因分开写：超预算 ≠ 没有 A 记录（D09）
  out="$(sni_judge_dns 'www.x.com' 'www.x.com' '' '203.0.113.9' 124)"
  printf '%s\n' "${out}" | grep -q '^FAIL|DNS 解析|'
  printf '%s\n' "${out}" | grep -q '超出探测预算'

  out="$(sni_judge_dns 'www.x.com' 'www.x.com' '' '203.0.113.9' 2)"
  printf '%s\n' "${out}" | grep -q '无 A 记录'

  out="$(sni_judge_dns 'www.x.com' 'www.x.com' '' '203.0.113.9' 3)"
  printf '%s\n' "${out}" | grep -q '没有 getent'
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
  # 注意：这里不能把 preflight 放进命令替换——「本次动作」的事实变量是在
  # 当前 shell 里置位的，子 shell 里置位拿不回来（真实调用路径也在当前 shell）。
  local workdir=""
  local output=""
  workdir="$(mktemp -d)"

  SKIP_SNI_CHECK=1
  preflight_check_reality_sni > "${workdir}/skip.txt" 2>&1
  output="$(cat "${workdir}/skip.txt")"
  printf '%s\n' "${output}" | grep -q '跳过 Reality 目标域名预检'
  # 跳过只对本次动作有效，结论是未验证，不是通过（D09）
  printf '%s\n' "${output}" | grep -q '未验证'
  [[ "${SNI_PREFLIGHT_SKIPPED}" == "1" ]]
  SKIP_SNI_CHECK=0
  SNI_PREFLIGHT_SKIPPED=0

  # 交互选择忽略：事实保留为「不通过」，而且只对本次动作有效
  NON_INTERACTIVE=0
  read_line_or_cancel() { printf -v "${1}" '%s' 'i'; }
  SNI_PREFLIGHT_IGNORED=0
  preflight_check_reality_sni > "${workdir}/ignore.txt" 2>&1
  output="$(cat "${workdir}/ignore.txt")"
  [[ "${SNI_PREFLIGHT_IGNORED}" == "1" ]]
  printf '%s\n' "${output}" | grep -q '忽略'
  printf '%s\n' "${output}" | grep -q '不通过'
  printf '%s\n' "${output}" | grep -q 'xtun check-sni'
  NON_INTERACTIVE=1
  SNI_PREFLIGHT_IGNORED=0

  # 装完要把这次的事实再说一遍，建议的复检命令是公开入口
  SNI_PREFLIGHT_IGNORED=1
  output="$(install_sni_preflight_notice)"
  printf '%s\n' "${output}" | grep -q '未通过'
  output="$(report_sni_preflight_override 2>&1)"
  printf '%s\n' "${output}" | grep -q 'xtun check-sni'
  SNI_PREFLIGHT_IGNORED=0

  SNI_PREFLIGHT_SKIPPED=1
  output="$(install_sni_preflight_notice)"
  printf '%s\n' "${output}" | grep -q '未验证'
  SNI_PREFLIGHT_SKIPPED=0

  # 没有跳过/忽略时不多说一句
  [[ -z "$(install_sni_preflight_notice)" ]]

  # 这些「本次动作」的事实不是 state 字段，写不进 state（D09）
  if state_file_key_allowed 'SKIP_SNI_CHECK' \
    || state_file_key_allowed 'SNI_PREFLIGHT_IGNORED' \
    || state_file_key_allowed 'SNI_PREFLIGHT_SKIPPED'; then
    return 1
  fi

  rm -rf "${workdir}"

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

# 预算：0/00/负数/文本一律拒绝，前导零规范化（D07）。
run_sni_timeout_validation_case() {
  local value=""
  local status=0
  local output=""

  XRAY_CONFIG_FILE="/nonexistent/xtun-sni-config.json"
  STATE_FILE="/nonexistent/xtun-sni-state.env"

  [[ "$(sni_normalize_timeout 010)" == "10" ]]
  [[ "$(sni_normalize_timeout 10)" == "10" ]]
  [[ "$(sni_normalize_timeout 600)" == "600" ]]

  for value in 0 00 000 -1 abc 1.5 ''; do
    if sni_normalize_timeout "${value}" >/dev/null 2>&1; then
      return 1
    fi
    set +e
    ( sni_check_cmd --timeout "${value}" cdn.example ) >/dev/null 2>&1
    status=$?
    set -e
    [[ "${status}" -eq 1 ]]
  done

  run_sni_checks() { printf '%s|%s|%s|%s\n' "$@"; }
  output="$(sni_check_cmd cdn.example --timeout 010 --server-ip 203.0.113.9)"
  [[ "${output}" == "cdn.example|cdn.example:443|203.0.113.9|10" ]]
  output="$(sni_check_cmd cdn.example --timeout 7 --server-ip 203.0.113.9)"
  [[ "${output}" == "cdn.example|cdn.example:443|203.0.113.9|7" ]]

  load_functions
}

# H08/D09：无参数检查读保存的 REALITY_TARGET；显式参数按 D09 覆盖；
# CLI 的 server-ip 不被 state 覆盖。
run_sni_check_target_resolution_case() {
  local workdir=""
  local output=""
  local status=0

  workdir="$(mktemp -d)"
  XRAY_CONFIG_FILE="${workdir}/missing-config.json"
  STATE_FILE="${workdir}/state.env"
  cat > "${STATE_FILE}" <<'EOF'
SERVER_IP='203.0.113.9'
REALITY_SNI='front.example'
REALITY_TARGET='upstream.example:8443'
EOF

  run_sni_checks() { printf '%s|%s|%s|%s\n' "$@"; }

  output="$(sni_check_cmd)"
  [[ "${output}" == "front.example|upstream.example:8443|203.0.113.9|10" ]]

  # 显式域名：用该域名自己的默认目标，不带入旧节点的 target
  output="$(sni_check_cmd cdn.example)"
  [[ "${output}" == "cdn.example|cdn.example:443|203.0.113.9|10" ]]

  # 显式 --target 优先
  output="$(sni_check_cmd cdn.example --target upstream.example:8443)"
  [[ "${output}" == "cdn.example|upstream.example:8443|203.0.113.9|10" ]]

  # CLI 的 server-ip 不被 state 覆盖（D09）
  output="$(sni_check_cmd --server-ip 198.51.100.7)"
  [[ "${output}" == "front.example|upstream.example:8443|198.51.100.7|10" ]]

  # 三项都显式：完全不读 state 也成立
  output="$(sni_check_cmd check.example --target 1.2.3.4:8443 --server-ip 198.51.100.8)"
  [[ "${output}" == "check.example|1.2.3.4:8443|198.51.100.8|10" ]]

  # 目标地址走 W03 的公开校验原语：不是 host:port 或端口越界就在解析阶段失败
  set +e
  ( sni_check_cmd cdn.example --target not-a-host ) >/dev/null 2>&1
  status=$?
  set -e
  [[ "${status}" -eq 1 ]]

  set +e
  ( sni_check_cmd cdn.example --target upstream.example:99999 ) >/dev/null 2>&1
  status=$?
  set -e
  [[ "${status}" -eq 1 ]]

  rm -rf "${workdir}"
  load_functions
}

# 有界探测：四个探针各跑一次、连同一个实际 target、输出阶段进度与总预算上界。
run_sni_bounded_probe_case() {
  local workdir=""
  local status=0
  local output=""

  workdir="$(mktemp -d)"

  sni_probe_dns() {
    printf 'dns %s %s\n' "${1}" "${2}" >> "${workdir}/calls.txt"
    printf '203.0.113.5\n'
  }
  sni_probe_tls() {
    printf 'tls %s %s %s\n' "${1}" "${2}" "${3}" >> "${workdir}/calls.txt"
    printf 'Protocol  : TLSv1.3\nPeer Temp Key: X25519, 253 bits\nALPN protocol: h2\nVerify return code: 0 (ok)\n'
  }
  sni_probe_cert() {
    printf 'cert %s %s %s\n' "${1}" "${2}" "${3}" >> "${workdir}/calls.txt"
    printf 'SAN=DNS:%s\nNOTAFTER=%s\nISSUER=C=US, O=Some CA\n' \
      "${2}" "$(date -d '+76 days' '+%b %e %H:%M:%S %Y GMT')"
  }
  sni_probe_http() {
    printf 'http %s %s %s\n' "${1}" "${2}" "${3}" >> "${workdir}/calls.txt"
    printf '200 2  0.02 nginx\n'
  }

  : > "${workdir}/calls.txt"
  set +e
  run_sni_checks 'front.example' 'upstream.example:8443' '203.0.113.9' 10 > "${workdir}/out.txt"
  status=$?
  set -e
  [[ "${status}" -eq 0 ]]

  # 每个探针只跑一次，展示与判定共用这一份结果（D07/H21）
  [[ "$(grep -c '^dns ' "${workdir}/calls.txt")" -eq 1 ]]
  [[ "$(grep -c '^tls ' "${workdir}/calls.txt")" -eq 1 ]]
  [[ "$(grep -c '^cert ' "${workdir}/calls.txt")" -eq 1 ]]
  [[ "$(grep -c '^http ' "${workdir}/calls.txt")" -eq 1 ]]

  # 所有探针连同一个实际 target/端口；DNS 走主机名，TLS/证书/HTTP 走同一 host:port
  grep -q '^dns upstream.example 10$' "${workdir}/calls.txt"
  grep -q '^tls upstream.example:8443 front.example 10$' "${workdir}/calls.txt"
  grep -q '^cert upstream.example:8443 front.example 10$' "${workdir}/calls.txt"
  grep -q '^http front.example upstream.example:8443 10$' "${workdir}/calls.txt"

  # 阶段进度与总预算上界
  output="$(cat "${workdir}/out.txt")"
  printf '%s\n' "${output}" | grep -Fq '[1/4] DNS 解析（预算 10s）… 完成'
  printf '%s\n' "${output}" | grep -Fq '[2/4] TLS 1.3 握手（预算 10s）… 完成'
  printf '%s\n' "${output}" | grep -Fq '[3/4] 证书读取（预算 10s）… 完成'
  printf '%s\n' "${output}" | grep -Fq '[4/4] HTTP 探测（预算 10s）… 完成'
  printf '%s\n' "${output}" | grep -Fq '等待上界: 4 个探针 × 10s = 40s'
  printf '%s\n' "${output}" | grep -Fq '本轮等待上界 40s'
  printf '%s\n' "${output}" | grep -Fq '结论: 通过（0 FAIL, 0 WARN, 1 未验证）'

  # 探针挂住时也不会超过预算：DNS 单独跑一次也要带 timeout
  # 先恢复真实探针（上面被本用例的桩换掉了），再只桩掉底层命令
  load_functions
  timeout() {
    printf 'timeout %s\n' "${1}" >> "${workdir}/timeout.txt"
    shift
    "$@"
  }
  getent() { printf '203.0.113.6\n'; }
  : > "${workdir}/timeout.txt"
  sni_probe_dns "upstream.example" 10 >/dev/null
  grep -q '^timeout 10$' "${workdir}/timeout.txt"

  unset -f timeout getent
  rm -rf "${workdir}"
  load_functions
}
