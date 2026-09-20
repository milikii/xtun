# shellcheck shell=bash

run_batch_b_node_readonly_case() {
  local workdir="" before="" after="" output="" status=0
  load_functions
  stub_side_effects
  workdir="$(mktemp -d)"
  OUTPUT_FILE="${workdir}/output.md"
  QR_OUTPUT_DIR="${workdir}/qr"
  mkdir -p "${QR_OUTPUT_DIR}"
  cat > "${OUTPUT_FILE}" <<'EOF'
# Long unrelated deployment instructions
## 节点 1
vless://one@example.test:443#FIRST
## 节点 3
vless://three@example.test:443#THIRD
EOF
  printf png > "${QR_OUTPUT_DIR}/01-FIRST.png"
  before="$(find "${workdir}" -type f -exec sha256sum {} + | sort)"
  begin_mutation() { die 'view attempted mutation'; }
  write_output_file() { die 'view attempted output generation'; }
  output="$(run_cli_command show-links --node=3)"
  [[ "${output}" == *vless://three* && "${output}" != *vless://one* && "${output}" != *unrelated* ]]
  output="$(run_cli_command show-links --summary)"
  [[ "${output}" == *"${OUTPUT_FILE}"* && "${output}" == *"${QR_OUTPUT_DIR}/01-FIRST.png"* && "${output}" != *vless://* ]]
  for args in '--node 2' '--node 0' '--node 01' '--node 10' '--node bad' '--node' '--node=' '--node 1 --node 3' '--qr --summary'; do
    status=0
    # 参数向量仅来自此固定表，不含用户值。
    # shellcheck disable=SC2086
    (run_cli_command show-links ${args}) >/dev/null 2>&1 || status=$?
    [[ "${status}" -eq 1 ]]
  done
  after="$(find "${workdir}" -type f -exec sha256sum {} + | sort)"
  [[ "${before}" == "${after}" ]]
}

run_batch_b_qr_size_case() {
  local workdir="" output="" status=0
  load_functions
  stub_side_effects
  workdir="$(mktemp -d)"
  OUTPUT_FILE="${workdir}/output.md"
  QR_OUTPUT_DIR="${workdir}/qr"
  mkdir -p "${QR_OUTPUT_DIR}"
  printf '## 节点 1\nvless://one@example.test:443#FIRST\n' > "${OUTPUT_FILE}"
  printf png > "${QR_OUTPUT_DIR}/01-FIRST.png"
  have_qrencode() { return 0; }
  qrencode() { cat >/dev/null; printf 'SHORT-QR\n'; }
  output="$(run_cli_command show-links --qr --node 1)"
  [[ "${output}" == *SHORT-QR* && "${output}" != *vless://* && "${output}" != *'链接文件:'* ]]
  qrencode() { cat >/dev/null; printf '%090d\n' 1; }
  output="$(run_cli_command show-links --qr --node 1)"
  [[ "${output}" == *超出当前终端* && "${output}" == *01-FIRST.png* && "${output}" != *00000000* ]]
  have_qrencode() { return 1; }
  output="$(run_cli_command show-links --qr --node 1 2>&1)"
  [[ "${output}" == *qrencode* && "${output}" == *01-FIRST.png* ]]
  rm "${QR_OUTPUT_DIR}/01-FIRST.png"
  (run_cli_command show-links --qr --node 1) >/dev/null 2>&1 || status=$?
  [[ "${status}" == 1 ]]
}

run_batch_b_navigation_case() {
  local workdir="" status=0 output=""
  load_functions
  stub_side_effects
  workdir="$(mktemp -d)"
  NON_INTERACTIVE=0
  REALITY_SNI=""
  XHTTP_DOMAIN=""
  printf 'first.example.com\n:back\nbad!\nsecond.example.com\ncdn.example.com\n' > "${workdir}/answers"
  {
    prompt_validated_value REALITY_SNI SNI '' ensure_reality_sni_format
    prompt_validated_value XHTTP_DOMAIN CDN '' ensure_xhttp_domain_format
  } < "${workdir}/answers" > "${workdir}/out" 2> "${workdir}/err"
  [[ "${REALITY_SNI}" == second.example.com && "${XHTTP_DOMAIN}" == cdn.example.com ]]
  grep -q '输入不合法' "${workdir}/err"
  printf ':cancel\n' > "${workdir}/cancel"
  (prompt_with_default SERVER_IP 地址 default < "${workdir}/cancel") >/dev/null 2>&1 || status=$?
  [[ "${status}" == 130 ]]
  status=0
  (IN_MAIN_MENU=1 prompt_with_default SERVER_IP 地址 default </dev/null) >/dev/null 2>&1 || status=$?
  [[ "${status}" == 131 ]]
  status=0
  (prompt_with_default SERVER_IP 地址 default </dev/null) >/dev/null 2>&1 || status=$?
  [[ "${status}" == 1 ]]
  output="$(show_main_menu)"
  [[ "${output}" == *检查环境与端口* && "${output}" != *升级与维护* ]]
  mkdir -p "${XRAY_CONFIG_DIR}"
  printf '{}' > "${XRAY_CONFIG_FILE}"
  output="$(show_main_menu)"
  [[ "${output}" == *获取节点* && "${output}" == *恢复与卸载* && "${output}" != *'19.'* && "${output}" != *$'\033'* ]]

  # 首屏必须连同提示符一起放进 80×24；长域名和 pending 路径不能挤掉任务入口。
  load_dashboard_context() { :; }
  service_active_state() { printf 'not-installed'; }
  listening_port_text() { printf 'haproxy (pid=123456), another-process (pid=234567)'; }
  warp_rule_count_text() { printf '12'; }
  pending_operation_present() { return 0; }
  pending_operation_text() { printf '修改证书：/root/xtun-backups/20260914-operation-with-a-long-name'; }
  SERVER_IP=203.0.113.10
  SERVER_IP6=2001:db8:1234:5678:1234:5678:1234:5678
  XHTTP_DOMAIN=very-long-domain-label.very-long-second-label.example.com
  H3_INTENT=legacy-on
  output="$({ show_dashboard_brief; show_main_menu; printf '请选择: '; })"
  python3 - "${output}" <<'PY'
import sys
import unicodedata

lines = sys.argv[1].splitlines()
assert len(lines) <= 24, len(lines)
for line in lines:
    assert '\x1b' not in line, repr(line)
    width = sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in line)
    assert width <= 80, (width, line)
PY
}

run_batch_b_menu_reentry_case() {
  local workdir="" output=""
  load_functions
  stub_side_effects
  workdir="$(mktemp -d)"
  mkdir -p "${XRAY_CONFIG_DIR}"
  printf '{}' > "${XRAY_CONFIG_FILE}"
  show_dashboard_brief() { :; }
  show_task_menu() { printf 'GROUP:%s\n' "${1}"; }
  pause_after_menu_action() { :; }
  change_path_cmd() { NON_INTERACTIVE=1; ENABLE_WARP=yes; printf 'FAILED-ACTION\n'; return 1; }
  status_cmd() { [[ "${NON_INTERACTIVE}" == 0 && -z "${ENABLE_WARP}" ]]; printf 'STATUS-OK\n'; }
  printf '3\n3\n0\n2\n1\n0\n0\n' > "${workdir}/answers"
  output="$(main_menu < "${workdir}/answers" 2>&1)"
  [[ "${output}" == *FAILED-ACTION* && "${output}" == *'菜单操作失败'* && "${output}" == *STATUS-OK* ]]
  [[ "$(grep -c 'STATUS-OK' <<< "${output}")" == 1 ]]
  change_path_cmd() { read_line_or_cancel XHTTP_PATH 路径; die 'cancel fell through'; }
  printf '3\n3\n:cancel\n0\n2\n1\n0\n0\n' > "${workdir}/answers"
  output="$(main_menu < "${workdir}/answers" 2>&1)"
  [[ "${output}" == *当前动作已取消* && "${output}" == *STATUS-OK* && "${output}" != *'cancel fell through'* ]]
}

# 2026-09-20 实测回归：调用方把变量命名为 answer 时，prompt_* 里的同名局部变量
# 会把写入吃掉，`prompt_yes_no answer …` 之后调用方拿到空值（H3 高级项因此报
# 「H3 只能是 yes 或 no」）。写入目标必须永远是调用方给的变量。
run_prompt_write_target_case() {
  local workdir=""
  local answer=""

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"

  printf 'n\n' > "${workdir}/no.txt"
  answer=""
  prompt_yes_no answer "测试开关 [y/n]" "y" < "${workdir}/no.txt"
  [[ "${answer}" == "n" ]]

  printf '\n' > "${workdir}/empty.txt"
  answer=""
  prompt_with_default answer "测试默认值" "fallback" < "${workdir}/empty.txt"
  [[ "${answer}" == "fallback" ]]

  NON_INTERACTIVE=0
  printf 'token-value\n' > "${workdir}/secret.txt"
  answer=""
  prompt_secret answer "测试密钥" < "${workdir}/secret.txt" > /dev/null
  [[ "${answer}" == "token-value" ]]

  rm -rf "${workdir}"
  load_functions
}

run_batch_b_preview_noop_case() {
  local workdir="" output="" status=0
  load_functions
  stub_side_effects
  workdir="$(mktemp -d)"
  load_current_install_context() {
    REALITY_UUID=11111111-1111-4111-8111-111111111111
    XHTTP_UUID=22222222-2222-4222-8222-222222222222
    REALITY_SNI=old.example.com
    REALITY_TARGET=old.example.com:443
    XHTTP_PATH=/old
    H3_INTENT=off
  }
  change_environment_fingerprint() { printf unchanged; }
  begin_mutation() { die 'TRIPWIRE:mutation'; }
  output="$(run_cli_command change-uuid --reality-uuid 11111111-1111-4111-8111-111111111111 --xhttp-only --xhttp-uuid 22222222-2222-4222-8222-222222222222)"
  [[ "${output}" == *UUID* && "${output}" == *未创建备份* ]]
  printf 'n\n' > "${workdir}/no"
  (run_cli_command change-path --xhttp-path /new < "${workdir}/no") > "${workdir}/out" 2>&1 || status=$?
  [[ "${status}" == 130 ]]
  output="$(cat "${workdir}/out")"
  [[ "${output}" == *'/old → /new'* && "${output}" == *'2,3,4,5,7,8,9'* && "${output}" == *'所有经过 Xray 的连接'* && "${output}" != *TRIPWIRE* ]]
  load_current_install_context
  capture_change_context
  REALITY_UUID=33333333-3333-4333-8333-333333333333
  output="$(show_change_preview uuid xray)"
  [[ "${output}" == *'1,6'* && "${output}" != *11111111* && "${output}" != *33333333* ]]
}

run_batch_b_h3_intent_case() {
  local workdir="" before="" output="" status=0
  load_functions
  workdir="$(mktemp -d)"
  STATE_FILE="${workdir}/state"
  NGINX_CONFIG_FILE="${workdir}/nginx.conf"
  XHTTP_DOMAIN=cdn.example.com
  XHTTP_PATH=/test
  H3_DECISION=enabled
  nginx_config_text > "${NGINX_CONFIG_FILE}"
  printf 'STATE_VERSION=2\nXHTTP_DOMAIN=cdn.example.com\n' > "${STATE_FILE}"
  before="$(sha256sum "${NGINX_CONFIG_FILE}" "${STATE_FILE}")"
  load_existing_state
  [[ "${H3_INTENT}" == legacy-on && "${H3_DECISION}" == off ]]
  [[ "$(h3_intent_text)" == *待能力验证* ]]
  [[ "$(sha256sum "${NGINX_CONFIG_FILE}" "${STATE_FILE}")" == "${before}" ]]
  output="$(state_file_text)"
  [[ "${output}" == *H3_INTENT=legacy-on* ]]
  sed -i '/add_header Alt-Svc/d' "${NGINX_CONFIG_FILE}"
  load_existing_state
  [[ "${H3_INTENT}" == unknown ]]
  h3_prepare_generation >/dev/null 2>&1 || status=$?
  [[ "${status}" == 1 ]]
  parse_install_args --enable-h3
  [[ "${H3_INTENT}" == on ]]
  status=0
  (parse_install_args --enable-h3 --disable-h3) >/dev/null 2>&1 || status=$?
  [[ "${status}" == 1 ]]
  H3_INTENT=""
  NON_INTERACTIVE=1
  ENABLE_WARP=no
  install_apply_base_combo_defaults
  [[ "${H3_INTENT}" == off ]]
  h3_refresh_decision
  output="$(nginx_server_config)"
  [[ "${output}" != *'quic reuseport'* && "${output}" != *Alt-Svc* ]]
}

# 这里的信任库仅供测试，以本地 CA 模拟公共根入口；不声称这些夹具公网可信。
batch_b_certificate_fixtures() {
  local dir="${1}"
  mkdir -p "${dir}/newcerts"
  openssl req -new -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
    -subj /CN=xtun-test-root -keyout "${dir}/root.key" -out "${dir}/root.pem" \
    -addext 'basicConstraints=critical,CA:TRUE' >/dev/null 2>&1
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=xtun-test-intermediate \
    -keyout "${dir}/inter.key" -out "${dir}/inter.csr" >/dev/null 2>&1
  printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' > "${dir}/inter.ext"
  openssl x509 -req -in "${dir}/inter.csr" -CA "${dir}/root.pem" -CAkey "${dir}/root.key" \
    -set_serial 2 -days 2 -extfile "${dir}/inter.ext" -out "${dir}/inter.pem" >/dev/null 2>&1
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=cdn.example.com \
    -keyout "${dir}/leaf.key" -out "${dir}/leaf.csr" >/dev/null 2>&1
  printf 'subjectAltName=DNS:cdn.example.com\nextendedKeyUsage=serverAuth\n' > "${dir}/leaf.ext"
  openssl x509 -req -in "${dir}/leaf.csr" -CA "${dir}/inter.pem" -CAkey "${dir}/inter.key" \
    -set_serial 3 -days 2 -extfile "${dir}/leaf.ext" -out "${dir}/leaf.pem" >/dev/null 2>&1
  cat "${dir}/leaf.pem" "${dir}/inter.pem" > "${dir}/chain.pem"
  printf 'subjectAltName=DNS:cdn.example.com\nextendedKeyUsage=clientAuth\n' > "${dir}/client.ext"
  openssl x509 -req -in "${dir}/leaf.csr" -CA "${dir}/root.pem" -CAkey "${dir}/root.key" \
    -set_serial 5 -days 2 -extfile "${dir}/client.ext" -out "${dir}/client.pem" >/dev/null 2>&1
  openssl req -x509 -key "${dir}/leaf.key" -subj /CN=cdn.example.com -days 2 \
    -addext 'subjectAltName=DNS:cdn.example.com' -out "${dir}/self.pem" >/dev/null 2>&1
  openssl req -x509 -key "${dir}/root.key" -subj '/CN=Cloudflare Origin SSL Certificate Authority' \
    -days 2 -out "${dir}/origin-root.pem" >/dev/null 2>&1
  openssl x509 -req -in "${dir}/leaf.csr" -CA "${dir}/origin-root.pem" -CAkey "${dir}/root.key" \
    -set_serial 6 -days 2 -extfile "${dir}/leaf.ext" -out "${dir}/origin.pem" >/dev/null 2>&1
  : > "${dir}/index"
  printf '07\n' > "${dir}/serial"
  cat > "${dir}/ca.conf" <<EOF
[ca]
default_ca=ca_default
[ca_default]
database=${dir}/index
serial=${dir}/serial
new_certs_dir=${dir}/newcerts
certificate=${dir}/root.pem
private_key=${dir}/root.key
default_md=sha256
unique_subject=no
policy=policy
x509_extensions=server
[policy]
commonName=supplied
[server]
subjectAltName=DNS:cdn.example.com
extendedKeyUsage=serverAuth
EOF
  openssl ca -batch -notext -config "${dir}/ca.conf" -startdate 20360101000000Z -enddate 20370101000000Z \
    -in "${dir}/leaf.csr" -out "${dir}/future.pem" >/dev/null 2>&1
  openssl ca -batch -notext -config "${dir}/ca.conf" -startdate 20200101000000Z -enddate 20210101000000Z \
    -in "${dir}/leaf.csr" -out "${dir}/expired.pem" >/dev/null 2>&1
}

run_batch_b_certificate_capability_case() {
  local workdir="" output=""
  load_functions
  workdir="$(mktemp -d)"
  batch_b_certificate_fixtures "${workdir}"
  certificate_public_trust_roots() { cat "${workdir}/root.pem"; }
  certificate_origin_trust_roots() { cat "${workdir}/origin-root.pem"; }
  output="$(certificate_capability_report "${workdir}/chain.pem" "${workdir}/leaf.key" cdn.example.com)"
  [[ "${output}" == ready\|* ]]
  [[ "$(certificate_capability_report "${workdir}/leaf.pem" "${workdir}/leaf.key" cdn.example.com)" == untrusted\|* ]]
  [[ "$(certificate_capability_report "${workdir}/chain.pem" "${workdir}/root.key" cdn.example.com)" == mismatch\|* ]]
  [[ "$(certificate_capability_report "${workdir}/chain.pem" "${workdir}/leaf.key" wrong.example.com)" == hostname\|* ]]
  [[ "$(certificate_capability_report "${workdir}/expired.pem" "${workdir}/leaf.key" cdn.example.com)" == expired\|* ]]
  [[ "$(certificate_capability_report "${workdir}/future.pem" "${workdir}/leaf.key" cdn.example.com)" == not-yet-valid\|* ]]
  [[ "$(certificate_capability_report "${workdir}/client.pem" "${workdir}/leaf.key" cdn.example.com)" == purpose\|* ]]
  [[ "$(certificate_capability_report "${workdir}/self.pem" "${workdir}/leaf.key" cdn.example.com)" == self-signed\|* ]]
  [[ "$(certificate_capability_report "${workdir}/origin.pem" "${workdir}/leaf.key" cdn.example.com)" == origin-ca\|* ]]
  certificate_public_trust_roots() { return 1; }
  [[ "$(certificate_capability_report "${workdir}/chain.pem" "${workdir}/leaf.key" cdn.example.com)" == unverified\|* ]]
  [[ "$(certificate_capability_report /missing /missing cdn.example.com)" == unverified\|* ]]
}

run_batch_b_h3_matrix_case() {
  local intent="" module="" cert_state="" udp="" expected="" count=0
  load_functions
  nginx() { :; }
  nginx_v3_capable() { [[ "${module}" == ready ]]; }
  certificate_capability_report() { printf '%s|certificate fixture' "${cert_state}"; }
  h3_udp_ownership_state() { printf '%s' "${udp}"; }
  for intent in off on legacy-on unknown; do
    for module in ready unsupported; do
      for cert_state in ready origin-ca self-signed hostname expired not-yet-valid mismatch purpose untrusted unverified; do
        for udp in absent ok foreign unconfirmed unknown; do
          H3_INTENT="${intent}"
          h3_refresh_decision
          expected=blocked
          if [[ "${intent}" == off ]]; then expected=off
          elif [[ "${intent}" != unknown && "${module}" == ready && "${cert_state}" == ready && ( "${udp}" == absent || "${udp}" == ok ) ]]; then expected=enabled; fi
          [[ "${H3_DECISION}" == "${expected}" ]]
          count=$((count + 1))
        done
      done
    done
  done
  [[ "${count}" == 400 ]]
}

run_batch_b_udp_ownership_case() {
  load_functions
  ss() { printf '%s\n' 'UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=1,fd=1))' 'UNCONN 0 0 [::]:443 [::]:* users:(("foreign",pid=2,fd=1))'; }
  h3_nginx_listener_is_managed() { return 0; }
  [[ "$(h3_udp_ownership_state)" == foreign ]]
  ss() { printf '%s\n' 'UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=1,fd=1))'; }
  h3_nginx_listener_is_managed() { return 1; }
  [[ "$(h3_udp_ownership_state)" == foreign ]]
  ss() { return 1; }
  [[ "$(h3_udp_ownership_state)" == unknown ]]
  ss() { printf '%s\n' 'UNCONN 0 0 0.0.0.0:443 0.0.0.0:*'; }
  [[ "$(h3_udp_ownership_state)" == unconfirmed ]]
}

run_batch_b_h3_enable_rejection_case() {
  local status=0 output="" workdir=""
  load_functions
  stub_side_effects
  workdir="$(mktemp -d)"
  change_environment_fingerprint() { printf unchanged; }
  load_current_install_context() { H3_INTENT=off; XHTTP_DOMAIN=cdn.example.com; }
  nginx() { :; }
  nginx_v3_capable() { return 0; }
  certificate_capability_report() { printf 'self-signed|自签夹具'; }
  h3_udp_ownership_state() { printf absent; }
  begin_mutation() { die 'TRIPWIRE:mutation'; }
  (run_cli_command change-h3 --enable-h3 --non-interactive) > "${workdir}/out" 2>&1 || status=$?
  [[ "${status}" == 1 ]]
  output="$(cat "${workdir}/out")"
  [[ "${output}" == *'H3 选择未应用'* && "${output}" == *自签夹具* && "${output}" != *TRIPWIRE* ]]
  output="$(run_cli_command change-h3 --disable-h3 --non-interactive)"
  [[ "${output}" == *没有变化* ]]
}
