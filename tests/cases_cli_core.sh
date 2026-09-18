# shellcheck shell=bash

run_usage_case() {
  local workdir=""
  local output=""

  workdir="$(mktemp -d)"
  ln -s "${ROOT_DIR}/xtun.sh" "${workdir}/xtun"
  output="$("${workdir}/xtun" help)"

  [[ "${output}" == *$'\n  xtun help'* ]]
  [[ "${output}" == *$'\n  xtun install [参数]'* ]]
  [[ "${output}" == *$'\n  xtun update-script'* ]]
  [[ "${output}" == *$'\n  xtun renew-cert [参数]'* ]]
  [[ "${output}" == *$'\n  xtun change-warp-rules [参数]'* ]]
  [[ "${output}" == *$'\n  xtun diagnose'* ]]
  [[ "${output}" == *$'\n  xtun apply-net-opt'* ]]
  [[ "${output}" == *$'\n  xtun apply-config'* ]]
  [[ "${output}" == *$'\n  xtun show-links [--qr] [--summary]'* ]]
}

run_show_links_without_state_case() {
  local workdir=""
  local output=""

  workdir="$(mktemp -d)"
  OUTPUT_FILE="${workdir}/output.md"
  STATE_FILE="${workdir}/missing-state.env"
  cat > "${OUTPUT_FILE}" <<'EOF'
vless://example-link
EOF

  output="$(show_links)"
  [[ "${output}" == "vless://example-link" ]]
}

run_show_links_summary_case() {
  local workdir=""
  local output=""

  workdir="$(mktemp -d)"
  OUTPUT_FILE="${workdir}/output.md"
  STATE_FILE="${workdir}/missing-state.env"
  XTUN_COMMAND_NAME='xtun-final-install.sh'
  cat > "${OUTPUT_FILE}" <<'EOF'
# Xray 部署信息

## 节点 1

链接:
vless://uuid@example.test:443#REALITY

## 节点 8

链接:
vless://uuid@example.test:443#H3
EOF

  output="$(show_links --summary)"
  [[ "${output}" == *"节点链接摘要"* ]]
  [[ "${output}" == *"完整内容: xtun show-links"* ]]
  [[ "${output}" == *"节点 1: REALITY"* ]]
  [[ "${output}" == *"节点 8: H3"* ]]
  [[ "${output}" != *"vless://"* ]]
  [[ "${output}" != *"xtun-final-install.sh show-links"* ]]

  if output="$(show_links --summary --qr)" 2>/dev/null; then
    return 1
  fi
}

run_quic_port_text_case() {
  h3_nginx_listener_is_managed() { return 0; }
  h3_enabled() { return 1; }
  ss() {
    printf '%s\n' 'UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("hysterity",pid=1,fd=3))'
  }
  [[ "$(quic_port_text)" == "不检查（H3 未启用）" ]]
  [[ "$(quic_port_state)" == "na" ]]

  h3_enabled() { return 0; }
  [[ "$(quic_port_text)" == "UDP 有监听，但不是 nginx" ]]
  [[ "$(quic_port_state)" == "foreign" ]]

  ss() {
    printf '%s\n' 'UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=1,fd=6))'
  }
  [[ "$(quic_port_text)" == "UDP 运行中（nginx）" ]]
  [[ "$(quic_port_state)" == "ok" ]]
  quic_port_listening

  ss() {
    printf '%s\n' 'UNCONN 0 0 0.0.0.0:443 0.0.0.0:*'
  }
  [[ "$(quic_port_text)" == "UDP 有监听，无法确认归属（需要 root）" ]]
  [[ "$(quic_port_state)" == "unconfirmed" ]]

  ss() { :; }
  [[ "$(quic_port_text)" == "UDP 未监听" ]]
  [[ "$(quic_port_state)" == "absent" ]]
  if quic_port_listening; then
    return 1
  fi

  unset -f ss
  unset -f h3_nginx_listener_is_managed
  h3_enabled() { return 1; }
}

# 面板与诊断的端口行必须写明 TCP，并能给出监听归属（H21/D09）。
run_port_listening_snapshot_case() {
  local saved_path=""

  ss() {
    printf '%s\n' \
      'LISTEN 0 511 *:443 *:* users:(("haproxy",pid=1,fd=7))' \
      'LISTEN 0 511 127.0.0.1:443 *:* users:(("nginx",pid=2,fd=9))'
  }
  [[ "$(port_listening_snapshot 443)" == "listening|TCP 运行中 (*:443,127.0.0.1:443 · haproxy,nginx)" ]]
  [[ "$(listening_port_text 443)" == "TCP 运行中 (*:443,127.0.0.1:443 · haproxy,nginx)" ]]
  is_port_listening 443

  # 地址/归属顺序不能跟着宿主 locale 变。开发机是 en_US.UTF-8，此时 sort 会把
  # 127.0.0.1 排在 * 前面；没有 LC_ALL=C 时同一台机器会出现两种文案，"
  # 「面板/诊断对不上」和「测试在本机红、在 CI 绿」都是这么来的。
  if command -v locale >/dev/null 2>&1 && LC_ALL=en_US.UTF-8 locale charmap >/dev/null 2>&1; then
    [[ "$(LC_ALL=en_US.UTF-8 port_listening_snapshot 443)" == "listening|TCP 运行中 (*:443,127.0.0.1:443 · haproxy,nginx)" ]]
  fi

  # 读不到进程归属时只报地址，不编造归属
  ss() { printf '%s\n' 'LISTEN 0 511 *:443 *:*'; }
  [[ "$(port_listening_snapshot 443)" == "listening|TCP 运行中 (*:443)" ]]

  ss() { :; }
  [[ "$(port_listening_snapshot 443)" == "absent|TCP 未监听" ]]
  if is_port_listening 443; then
    return 1
  fi

  unset -f ss
  # 没有 ss：既不能说运行中，也不能说未监听
  saved_path="${PATH}"
  # shellcheck disable=SC2123
  PATH="/nonexistent-xtun-test"
  [[ "$(port_listening_snapshot 443)" == "unknown|未探测（缺少 ss）" ]]
  PATH="${saved_path}"
}

# IPv6 双栈行也不能只写「运行中」：必须写明 TCP，且只听 IPv4 / 读不到时说法要有区别（H21/D09）。
run_ipv6_listen_text_case() {
  [[ "$(ipv6_listen_text listening 'TCP 运行中 (*:443 · haproxy)')" == "TCP 运行中" ]]
  [[ "$(ipv6_listen_text listening 'TCP 运行中 ([::]:443 · haproxy)')" == "TCP 运行中" ]]
  [[ "$(ipv6_listen_text listening 'TCP 运行中 (127.0.0.1:443 · nginx)')" == "TCP 未监听（仅 IPv4）" ]]
  [[ "$(ipv6_listen_text absent 'TCP 未监听')" == "TCP 未监听" ]]
  [[ "$(ipv6_listen_text unknown '未探测（缺少 ss）')" == "无法确认（缺少 ss）" ]]
  # 不能出现没有协议层的裸「运行中」。
  if ipv6_listen_text listening 'TCP 运行中 (*:443)' | grep -qx '运行中'; then
    return 1
  fi
}

# 本地 TLS 探测：预算有上界；「握手成功但证书不受信任」与「连不上」分开报告（H18/H21）。
run_local_tls_probe_state_case() {
  local workdir=""
  local saved_path=""

  workdir="$(mktemp -d)"
  XHTTP_DOMAIN="cdn.example.com"

  timeout() {
    printf 'timeout %s\n' "${1}" >> "${workdir}/timeout.txt"
    shift
    "$@"
  }
  openssl() {
    cat "${workdir}/openssl-out.txt"
  }

  printf 'CONNECTED(00000003)\nVerify return code: 0 (ok)\n' > "${workdir}/openssl-out.txt"
  [[ "$(local_tls_probe_state)" == "ok" ]]
  [[ "$(local_tls_probe_text_for_state ok)" == *"受系统信任"* ]]

  printf 'CONNECTED(00000003)\nVerify return code: 20 (unable to get local issuer certificate)\n' > "${workdir}/openssl-out.txt"
  [[ "$(local_tls_probe_state)" == "untrusted" ]]
  [[ "$(local_tls_probe_text_for_state untrusted)" == *"不受系统信任"* ]]

  : > "${workdir}/openssl-out.txt"
  [[ "$(local_tls_probe_state)" == "fail" ]]
  [[ "$(local_tls_probe_text_for_state fail)" == *"握手不成功"* ]]

  grep -q '^timeout 5$' "${workdir}/timeout.txt"

  XHTTP_DOMAIN=""
  [[ "$(local_tls_probe_state)" == "na" ]]
  XHTTP_DOMAIN="cdn.example.com"

  unset -f timeout openssl
  # 缺 openssl 时明确报未探测，不假装通过
  saved_path="${PATH}"
  # shellcheck disable=SC2123
  PATH="/nonexistent-xtun-test"
  [[ "$(local_tls_probe_state)" == "unknown" ]]
  PATH="${saved_path}"

  rm -rf "${workdir}"
}

run_install_prompt_early_validation_case() {
  local workdir=""
  local output=""

  workdir="$(mktemp -d)"
  guess_server_ip() { printf '203.0.113.10'; }
  guess_server_ip6() { :; }
  default_node_label_prefix() { printf 'VPS'; }
  random_uuid() { printf '11111111-1111-1111-1111-111111111111'; }
  default_reality_target_for_sni() { printf '%s:443' "${1}"; }
  random_hex() { printf 'abcd1234'; }
  random_path() { printf '/assets/v3'; }
  prompt_with_default() {
    printf '%s\n' "${1}" >> "${workdir}/prompts.txt"
    case "${1}" in
      SERVER_IP) printf -v "${1}" '%s' "${PROMPT_TEST_SERVER_IP:-${3}}" ;;
      REALITY_SNI) printf -v "${1}" '%s' "${PROMPT_TEST_SNI-}" ;;
      REALITY_TARGET) printf -v "${1}" '%s' "${PROMPT_TEST_TARGET-}" ;;
      *) printf -v "${1}" '%s' "${3}" ;;
    esac
  }
  prompt_yes_no() { printf -v "${1}" '%s' 'no'; }
  prompt_cert_mode_selection() { CERT_MODE='self-signed'; }
  prompt_cert_mode_inputs() { :; }
  prompt_warp_settings() { :; }

  # 非法 SNI：就地重填，三次仍然非法才终止；不会先把后面的问答跑完。
  PROMPT_TEST_SNI=''
  PROMPT_TEST_TARGET='www.stanford.edu:443'
  : > "${workdir}/prompts.txt"
  if output="$(prepare_install_inputs 2> "${workdir}/error.txt")"; then
    return 1
  fi
  grep -q 'REALITY SNI 不是合法域名：' "${workdir}/error.txt"
  grep -q '^REALITY_SNI$' "${workdir}/prompts.txt"
  assert_absent '^REALITY_TARGET$' "${workdir}/prompts.txt"
  assert_absent '^XHTTP_UUID$' "${workdir}/prompts.txt"

  # 地址非法：在输入位置就挡住，不等到确认页之后的 validate_install_inputs。
  PROMPT_TEST_SERVER_IP='bad_sni!'
  PROMPT_TEST_SNI='www.stanford.edu'
  PROMPT_TEST_TARGET='www.stanford.edu:443'
  : > "${workdir}/prompts.txt"
  if output="$(prepare_install_inputs 2> "${workdir}/error.txt")"; then
    return 1
  fi
  grep -q 'REALITY 直连节点地址 不是合法域名：bad_sni!' "${workdir}/error.txt"
  grep -q '^SERVER_IP$' "${workdir}/prompts.txt"
  assert_absent '^REALITY_SNI$' "${workdir}/prompts.txt"

  # SNI 合法、target 非法：同样在进入下一步之前终止。
  PROMPT_TEST_SERVER_IP=''
  PROMPT_TEST_SNI='www.stanford.edu'
  PROMPT_TEST_TARGET=''
  : > "${workdir}/prompts.txt"
  if output="$(prepare_install_inputs 2> "${workdir}/error.txt")"; then
    return 1
  fi
  grep -q 'REALITY 目标地址 不能为空' "${workdir}/error.txt"
  grep -q '^REALITY_TARGET$' "${workdir}/prompts.txt"
  assert_absent '^XHTTP_DOMAIN$' "${workdir}/prompts.txt"

  rm -rf "${workdir}"
  load_functions
}

run_single_file_bootstrap_case() {
  local workdir=""
  local output=""
  local old_bundle=""

  workdir="$(mktemp -d)"
  cp "${ROOT_DIR}/xtun.sh" "${workdir}/xtun.sh"
  old_bundle="${workdir}/old-bundle"
  mkdir -p "${old_bundle}/lib/base" "${old_bundle}/static/fallback"
  cp "${ROOT_DIR}/xtun.sh" "${old_bundle}/xtun.sh"
  printf '# helper\n' > "${old_bundle}/lib/base/helpers.sh"
  printf '<!doctype html>\n' > "${old_bundle}/static/fallback/index.html"

  output="$(XTUN_SELF_INSTALL_DIR="${old_bundle}" XTUN_SELF_COMMAND_PATH="${workdir}/bin/xtun" XTUN_BOOTSTRAP_ROOT="${ROOT_DIR}" bash "${workdir}/xtun.sh" help)"
  [[ "${output}" == *$'\n  xtun.sh help'* ]]
  [[ "${output}" == *$'\n  xtun.sh diagnose'* ]]
}

run_bootstrap_archive_resolve_case() {
  local archive_url=""
  local original_bootstrap_archive_url="${BOOTSTRAP_ARCHIVE_URL:-}"
  local original_repo_owner="${BOOTSTRAP_REPO_OWNER:-}"
  local original_repo_name="${BOOTSTRAP_REPO_NAME:-}"
  local original_branch_ref="${BOOTSTRAP_BRANCH_REF:-}"

  BOOTSTRAP_ARCHIVE_URL=""
  BOOTSTRAP_REPO_OWNER="milikii"
  BOOTSTRAP_REPO_NAME="xtun"
  BOOTSTRAP_BRANCH_REF="main"

  curl() {
    printf '%s\n200' '{"sha":"0123456789abcdef0123456789abcdef01234567"}'
  }
  archive_url="$(bootstrap_resolve_archive_url)"
  [[ "${archive_url}" == "https://codeload.github.com/milikii/xtun/tar.gz/0123456789abcdef0123456789abcdef01234567" ]]

  curl() {
    return 99
  }
  if archive_url="$(bootstrap_resolve_archive_url)"; then return 1; fi

  BOOTSTRAP_ARCHIVE_URL="https://example.invalid/custom.tar.gz"
  archive_url="$(bootstrap_resolve_archive_url)"
  [[ "${archive_url}" == "https://example.invalid/custom.tar.gz" ]]

  BOOTSTRAP_ARCHIVE_URL="${original_bootstrap_archive_url}"
  BOOTSTRAP_REPO_OWNER="${original_repo_owner}"
  BOOTSTRAP_REPO_NAME="${original_repo_name}"
  BOOTSTRAP_BRANCH_REF="${original_branch_ref}"
  unset -f curl
}

run_install_self_command_case() {
  local workdir=""
  local output=""
  local source_bundle=""

  workdir="$(mktemp -d)"
  SELF_COMMAND_PATH="${workdir}/bin/xtun"
  SELF_INSTALL_DIR="${workdir}/bundle"
  SCRIPT_SELF="${ROOT_DIR}/xtun.sh"
  SCRIPT_ROOT="${ROOT_DIR}"

  install_self_command

  [[ -x "${SELF_COMMAND_PATH}" ]]
  [[ -f "${SELF_INSTALL_DIR}/xtun.sh" ]]
  [[ -f "${SELF_INSTALL_DIR}/lib/install.sh" ]]
  [[ -f "${SELF_INSTALL_DIR}/static/fallback/index.html" ]]

  output="$("${SELF_COMMAND_PATH}" help)"
  [[ "${output}" == *$'\n  xtun help'* ]]
  [[ "${output}" == *$'\n  xtun install [参数]'* ]]

  source_bundle="${workdir}/source-bundle"
  cp -a "${SELF_INSTALL_DIR}" "${source_bundle}"
  SELF_INSTALL_DIR="${source_bundle}"
  SELF_COMMAND_PATH="${workdir}/bin/xtun-reinstall"
  SCRIPT_SELF="${source_bundle}/xtun.sh"
  SCRIPT_ROOT="${source_bundle}"

  install_self_command
  [[ -x "${SELF_COMMAND_PATH}" ]]
  [[ -f "${SELF_INSTALL_DIR}/xtun.sh" ]]
  [[ -f "${SELF_INSTALL_DIR}/lib/ui/output.sh" ]]
  [[ -f "${SELF_INSTALL_DIR}/static/fallback/index.html" ]]
}

run_update_script_command_case() {
  local workdir="" source_root="" output="" before=""
  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  SELF_INSTALL_DIR="${workdir}/bundle"
  SELF_COMMAND_PATH="${workdir}/bin/xtun"
  source_root="${workdir}/source"
  mkdir "${source_root}"
  cp -a "${ROOT_DIR}/xtun.sh" "${ROOT_DIR}/lib" "${ROOT_DIR}/static" "${source_root}/"
  sed -i 's/^SCRIPT_VERSION=".*"/SCRIPT_VERSION="9.9.9"/' "${source_root}/xtun.sh"
  BOOTSTRAP_ARCHIVE_URL="file://${workdir}/candidate.tar.gz"
  tar -czf "${workdir}/candidate.tar.gz" -C "${workdir}" source
  run_cli_command update-script --non-interactive
  [[ -x "${SELF_COMMAND_PATH}" ]]
  [[ "$(bundle_script_version "${SELF_INSTALL_DIR}")" == 9.9.9 ]]
  bundle_identity_valid "${SELF_INSTALL_DIR}"
  before="$(backup_file_digest "${SELF_INSTALL_DIR}")"
  LOGGED=""
  run_cli_command update-script --non-interactive
  [[ "${LOGGED}" == *当前已经是最新脚本* ]]
  [[ "$(backup_file_digest "${SELF_INSTALL_DIR}")" == "${before}" ]]

  printf '\n# runtime content changed\n' >> "${source_root}/xtun.sh"
  tar -czf "${workdir}/candidate.tar.gz" -C "${workdir}" source
  LOGGED=""
  run_cli_command update-script --non-interactive
  [[ "${LOGGED}" == *脚本内容已更新*版本号保持* ]]
  bundle_identity_valid "${SELF_INSTALL_DIR}"
  [[ "$(backup_file_digest "${SELF_INSTALL_DIR}")" != "${before}" ]]
  rm "${SELF_INSTALL_DIR}/.xtun-bundle.json"
  if run_cli_command update-script --non-interactive; then return 1; fi
  run_cli_command update-script --reinstall --non-interactive
  bundle_identity_valid "${SELF_INSTALL_DIR}"
  rm -rf "${workdir}"
}

run_bundle_script_signature_case() {
  local installed_dir=""
  local bundle_dir=""

  installed_dir="$(mktemp -d)/installed"
  bundle_dir="$(mktemp -d)/bundle"

  mkdir -p "${installed_dir}/lib/base" "${installed_dir}/static/fallback" \
    "${bundle_dir}/lib/base" "${bundle_dir}/static/fallback" "${bundle_dir}/tests"
  cp -a "${ROOT_DIR}/xtun.sh" "${ROOT_DIR}/lib" "${ROOT_DIR}/static" "${installed_dir}/"

  # 源码归档比安装目录多出 README / tests 等不进安装目录的文件：签名只看 xtun.sh / lib / static，应相等
  cp -a "${installed_dir}/xtun.sh" "${installed_dir}/lib" "${installed_dir}/static" "${bundle_dir}/"
  printf 'readme\n' > "${bundle_dir}/README.md"
  printf 'test\n' > "${bundle_dir}/tests/smoke.sh"

  SELF_INSTALL_DIR="${installed_dir}"
  [[ "$(bundle_script_signature "${installed_dir}")" == "$(bundle_script_signature "${bundle_dir}")" ]]
  write_bundle_install_identity "${bundle_dir}" "${installed_dir}"
  installed_script_matches_bundle "${bundle_dir}"

  # 运行文件有差异时签名必须不同
  printf '#!/usr/bin/env bash\nSCRIPT_VERSION="10.0.0"\n' > "${bundle_dir}/xtun.sh"
  [[ "$(bundle_script_signature "${installed_dir}")" != "$(bundle_script_signature "${bundle_dir}")" ]]
  assert_false installed_script_matches_bundle "${bundle_dir}"
}

run_install_validation_case() {
  local output=""

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
ENABLE_WARP="no"
SERVER_IP='203.0.113.13'
REALITY_SNI='bad"host'
REALITY_TARGET='www.scu.edu:443'
XHTTP_DOMAIN='cdn.example.com'
XHTTP_PATH='/assets/v3'
validate_install_inputs
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q 'REALITY SNI 不是合法域名'

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
ENABLE_WARP="no"
SERVER_IP='203.0.113.13'
REALITY_SNI='reality.example.com'
REALITY_TARGET='www.scu.edu:bad'
XHTTP_DOMAIN='cdn.example.com'
XHTTP_PATH='/assets/v3'
validate_install_inputs
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q 'REALITY 目标地址 必须是 1-65535 之间的端口'

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
ENABLE_WARP="no"
SERVER_IP='203.0.113.13'
REALITY_SNI='reality.example.com'
REALITY_TARGET='www.scu.edu:443'
XHTTP_DOMAIN='cdn.example.com'
XHTTP_PATH='/bad path'
validate_install_inputs
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q 'XHTTP 路径不能包含空白字符'

  # 一个反斜杠也得拦住：原来写成 *'\\'* 只挡得住连着写两个的，
  # /a\b 会一路进 nginx 的 location 前缀。
  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
ENABLE_WARP="no"
SERVER_IP='203.0.113.13'
REALITY_SNI='reality.example.com'
REALITY_TARGET='www.scu.edu:443'
XHTTP_DOMAIN='cdn.example.com'
XHTTP_PATH='/assets\v3'
validate_install_inputs
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q 'XHTTP 路径不能包含反斜杠'

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
ENABLE_WARP="no"
SERVER_IP='203.0.113.13'
REALITY_SNI='reality.example.com'
REALITY_TARGET='www.scu.edu:443'
XHTTP_DOMAIN='cdn.example.com'
XHTTP_PATH='/assets/v3'
XHTTP_XPADDING_ENABLED='yes'
XHTTP_XPADDING_KEY='bad key'
validate_install_inputs
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q 'XHTTP xpadding 参数名只能包含'
}

run_value_source_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  printf 'secret-from-file\n' > "${workdir}/secret.txt"

  WARP_PRIVATE_KEY="@${workdir}/secret.txt"
  resolve_value_source WARP_PRIVATE_KEY
  [[ "${WARP_PRIVATE_KEY}" == "secret-from-file" ]]

  WARP_ADDRESS_V4=""
  export WARP_ADDRESS_V4="172.16.0.9"
  resolve_value_source WARP_ADDRESS_V4
  [[ "${WARP_ADDRESS_V4}" == "172.16.0.9" ]]
  unset WARP_ADDRESS_V4
}

# 上面那条只喂了以 \n 结尾的干净文件。`$(<file)` 只剪结尾的换行，\r 一个不动，
# 而令牌文件在 Windows 上存过一手、或者从网页复制粘贴过来，内容就是 `token\r`。
# 带 \r 的令牌 curl 会把裸 CR 原样塞进 Authorization 头发出去（实测 curl 8.14 不拦），
# Cloudflare 回 401；带 \r 的 WARP 私钥会被 44 位 base64 正则当场拒掉，
# 操作员盯着一个数出来正好 44 位的密钥发懵。多出来的字节看不见，报错也不提它。
run_indirect_value_sanitize_case() {
  local workdir=""

  workdir="$(mktemp -d)"

  # Windows 换行的令牌文件
  printf 'cf-token-abc123\r\n' > "${workdir}/token.crlf"
  CF_DNS_TOKEN="@${workdir}/token.crlf"
  resolve_value_source CF_DNS_TOKEN
  [[ "${CF_DNS_TOKEN}" == "cf-token-abc123" ]]

  # 首尾空白和多余空行
  printf '  cf-token-def456  \n\n' > "${workdir}/token.pad"
  CF_API_TOKEN="@${workdir}/token.pad"
  resolve_value_source CF_API_TOKEN
  [[ "${CF_API_TOKEN}" == "cf-token-def456" ]]

  # 环境变量来源同样会带上 \r（CI 的 secret 往回喂一层命令替换也只剪 \n）
  WARP_PRIVATE_KEY=""
  export WARP_PRIVATE_KEY="${TEST_WARP_PRIVATE_KEY}"$'\r'
  resolve_value_source WARP_PRIVATE_KEY
  [[ "${WARP_PRIVATE_KEY}" == "${TEST_WARP_PRIVATE_KEY}" ]]
  is_valid_wireguard_key "${WARP_PRIVATE_KEY}"
  unset WARP_PRIVATE_KEY

  # PEM 是多行的：\r 要删，内部换行一行都不能少，删完还得是能解析的证书
  openssl req -x509 -newkey rsa:2048 -keyout "${workdir}/k.pem" -out "${workdir}/c.pem" \
    -days 1 -nodes -subj '/CN=xtun-test' 2>/dev/null
  sed 's/$/\r/' "${workdir}/c.pem" > "${workdir}/c.crlf.pem"
  CERT_SOURCE_PEM="@${workdir}/c.crlf.pem"
  resolve_value_source CERT_SOURCE_PEM
  printf '%s\n' "${CERT_SOURCE_PEM}" > "${workdir}/out.pem"
  assert_absent $'\r' "${workdir}/out.pem"
  [[ "$(wc -l < "${workdir}/out.pem")" -eq "$(wc -l < "${workdir}/c.pem")" ]]
  openssl x509 -in "${workdir}/out.pem" -noout -subject >/dev/null

  # 本来就干净的值不许被动到
  printf 'plain-token\n' > "${workdir}/token.lf"
  CF_DNS_TOKEN="@${workdir}/token.lf"
  resolve_value_source CF_DNS_TOKEN
  [[ "${CF_DNS_TOKEN}" == "plain-token" ]]

  rm -rf "${workdir}"
}

run_prompt_reuse_case() {
  local output=""
  local script_file=""

  script_file="$(mktemp)"
  cat > "${script_file}" <<EOF
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
NON_INTERACTIVE=0
SERVER_IP="203.0.113.10"
prompt_with_default SERVER_IP "REALITY 直连节点地址或 IP" "198.51.100.10"
printf '%s' "\${SERVER_IP}"
EOF
  output="$(printf '203.0.113.11\n' | bash "${script_file}")"
  rm -f "${script_file}"
  [[ "${output}" == "203.0.113.11" ]]

  script_file="$(mktemp)"
  cat > "${script_file}" <<EOF
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
NON_INTERACTIVE=0
SERVER_IP="203.0.113.10"
prompt_with_default SERVER_IP "REALITY 直连节点地址或 IP" "198.51.100.10"
printf '%s' "\${SERVER_IP}"
EOF
  output="$(printf '\n' | bash "${script_file}")"
  rm -f "${script_file}"
  [[ "${output}" == "203.0.113.10" ]]

  script_file="$(mktemp)"
  cat > "${script_file}" <<EOF
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
NON_INTERACTIVE=0
ENABLE_WARP="yes"
prompt_yes_no ENABLE_WARP "是否启用选择性 WARP 出站？ [y/n]" "y"
printf '%s' "\${ENABLE_WARP}"
EOF
  output="$(printf 'n\n' | bash "${script_file}")"
  rm -f "${script_file}"
  [[ "${output}" == "n" ]]

  script_file="$(mktemp)"
  cat > "${script_file}" <<EOF
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
NON_INTERACTIVE=0
WARP_PRIVATE_KEY="secret-old"
prompt_secret WARP_PRIVATE_KEY "WARP WireGuard 私钥"
printf '%s' "\${WARP_PRIVATE_KEY}"
EOF
  output="$(printf '\n' | bash "${script_file}")"
  rm -f "${script_file}"
  [[ "${output##*$'\n'}" == "secret-old" ]]
}

run_xray_digest_parse_case() {
  local workdir=""
  local dgst_file=""
  local hash_value=""
  local metadata_json=""

  workdir="$(mktemp -d)"
  dgst_file="${workdir}/Xray-linux-64.zip.dgst"
  cat > "${dgst_file}" <<'EOF'
SHA256 (Xray-linux-64.zip) = 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
SHA512 (Xray-linux-64.zip) = deadbeef
EOF

  hash_value="$(parse_xray_dgst_sha256 "${dgst_file}" "Xray-linux-64.zip")"
  [[ "${hash_value}" == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ]]

  cat > "${dgst_file}" <<'EOF'
Xray-linux-64.zip
sha256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
sha512: deadbeef
EOF

  hash_value="$(parse_xray_dgst_sha256 "${dgst_file}" "Xray-linux-64.zip")"
  [[ "${hash_value}" == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ]]

  cat > "${dgst_file}" <<'EOF'
MD5= 3e1fc0f4ca54dc32b733ecd0ade75100
SHA1= d8a8c3ecf4e620c34ed78e1e51a0a2de63fc808e
SHA2-256= 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
SHA2-512= cf6daeb9c85f6f75ccf02c895f67b8c900b7374c4af4c015bf2283cf5a6eebb80736540b764572f345a200b0afbc0b6c1346e3ff87828fe13dcfcf65de5d231e
EOF
  hash_value="$(parse_xray_dgst_sha256 "${dgst_file}" "Xray-linux-64.zip")"
  [[ "${hash_value}" == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ]]

  metadata_json='{"assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://example.invalid/Xray-linux-64.zip","digest":"sha256:0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"}]}'
  hash_value="$(normalize_xray_sha256_value "$(xray_release_asset_field "${metadata_json}" "Xray-linux-64.zip" "digest")")"
  [[ "${hash_value}" == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ]]
  [[ "$(xray_release_asset_field "${metadata_json}" "Xray-linux-64.zip" "browser_download_url")" == "https://example.invalid/Xray-linux-64.zip" ]]
}

run_install_xray_checksum_failure_case() {
  local output=""
  local workdir=""
  local archive_sha256=""

  workdir="$(mktemp -d)"
  printf 'not-a-real-zip' >"${workdir}/archive"
  archive_sha256="$(sha256sum "${workdir}/archive" | awk '{print $1}')"

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
XRAY_SELECTED_TAG="v26.3.27"
XRAY_SELECTED_COMMIT="d2758a0000000000000000000000000000000000"
XRAY_SELECTED_ARCHIVE_NAME="Xray-linux-64.zip"
XRAY_SELECTED_ARCHIVE_URL="https://example.invalid/Xray-linux-64.zip"
XRAY_SELECTED_DGST_URL=""
XRAY_SELECTED_EXPECTED_SHA256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
curl() {
  local output_path="\${@: -1}"
  printf 'not-a-real-zip' >"\${output_path}"
}
xray_download_release "${workdir}"
EOF
)"; then
    rm -rf "${workdir}"
    return 1
  fi
  rm -rf "${workdir}"
  printf '%s' "${output}" | grep -q 'Xray 安装包 SHA256 校验失败'
}

run_install_packages_failure_case() {
  local output=""

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
apt-get() {
  return 1
}
install_packages
EOF
)"; then
    return 1
  fi

  printf '%s' "${output}" | grep -q '安装依赖包'
  if printf '%s' "${output}" | grep -q '依赖包安装完成'; then
    return 1
  fi
}

run_install_parse_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  printf '%s\n' "${TEST_WARP_PRIVATE_KEY}" > "${workdir}/warp-private-key.txt"
  NON_INTERACTIVE=0
  SERVER_IP=""
  NODE_LABEL_PREFIX=""
  REALITY_UUID=""
  REALITY_SNI=""
  REALITY_TARGET=""
  REALITY_SHORT_ID=""
  REALITY_PRIVATE_KEY=""
  XHTTP_UUID=""
  XHTTP_DOMAIN=""
  XHTTP_PATH=""
  XHTTP_VLESS_ENCRYPTION_ENABLED="yes"
  XHTTP_ECH_CONFIG_LIST=""
  XHTTP_ECH_FORCE_QUERY=""
  XHTTP_XPADDING_ENABLED="no"
  XHTTP_XPADDING_KEY=""
  XHTTP_XPADDING_HEADER=""
  XHTTP_XPADDING_PLACEMENT=""
  XHTTP_XPADDING_METHOD=""
  CERT_MODE=""
  CERT_SOURCE_FILE=""
  KEY_SOURCE_FILE=""
  ENABLE_WARP=""
  ENABLE_NET_OPT=""
  clear_test_warp_credentials

  parse_install_args \
    --non-interactive \
    --server-ip 198.51.100.10 \
    --node-label-prefix hkg \
    --reality-sni reality.example.com \
    --reality-target reality.example.com:443 \
    --xhttp-domain cdn.example.com \
    --xhttp-path /edge \
    --disable-xhttp-vless-encryption \
    --enable-xhttp-ech \
    --enable-xhttp-xpadding \
    --xhttp-xpadding-key x_pad \
    --xhttp-xpadding-header Referer \
    --cert-mode 2 \
    --cert-file /tmp/cert.pem \
    --key-file /tmp/key.pem \
    --enable-warp \
    --warp-private-key "@${workdir}/warp-private-key.txt" \
    --warp-address-v4 172.16.0.2 \
    --warp-address-v6 2606:4700:110:8a1b:cafe:1:2:3 \
    --warp-reserved '[1, 2, 3]' \
    --warp-endpoint engage.cloudflareclient.com:2408 \
    --warp-mtu 1280 \
    --disable-net-opt

  resolve_install_input_sources
  [[ "${NON_INTERACTIVE}" -eq 1 ]]
  [[ "${SERVER_IP}" == "198.51.100.10" ]]
  [[ "${NODE_LABEL_PREFIX}" == "hkg" ]]
  [[ "${REALITY_SNI}" == "reality.example.com" ]]
  [[ "${REALITY_TARGET}" == "reality.example.com:443" ]]
  [[ "${XHTTP_DOMAIN}" == "cdn.example.com" ]]
  [[ "${XHTTP_PATH}" == "/edge" ]]
  [[ "${XHTTP_VLESS_ENCRYPTION_ENABLED}" == "no" ]]
  [[ "${XHTTP_ECH_CONFIG_LIST}" == "https://dns.alidns.com/dns-query" ]]
  [[ -z "${XHTTP_ECH_FORCE_QUERY}" ]]
  [[ "${XHTTP_XPADDING_ENABLED}" == "yes" ]]
  [[ "${XHTTP_XPADDING_KEY}" == "x_pad" ]]
  [[ "${XHTTP_XPADDING_HEADER}" == "Referer" ]]
  [[ "${CERT_MODE}" == "2" ]]
  [[ "$(validate_cert_mode_value "${CERT_MODE}")" == "existing" ]]
  [[ "${CERT_SOURCE_FILE}" == "/tmp/cert.pem" ]]
  [[ "${KEY_SOURCE_FILE}" == "/tmp/key.pem" ]]
  [[ "${ENABLE_WARP}" == "yes" ]]
  [[ "${WARP_PRIVATE_KEY}" == "${TEST_WARP_PRIVATE_KEY}" ]]
  [[ "${WARP_ADDRESS_V4}" == "172.16.0.2" ]]
  [[ "${WARP_ADDRESS_V6}" == "2606:4700:110:8a1b:cafe:1:2:3" ]]
  [[ "${WARP_ENDPOINT}" == "engage.cloudflareclient.com:2408" ]]
  [[ "${WARP_MTU}" == "1280" ]]
  ensure_warp_outbound_format
  [[ "${WARP_RESERVED}" == "1,2,3" ]]
  [[ "${ENABLE_NET_OPT}" == "no" ]]
}

run_install_prepare_preserves_ech_flag_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults
  INSTALL_DRAFT_FILE="${workdir}/draft.env"
  SCRIPT_LOCK_FILE="${workdir}/lock"
  XRAY_CONFIG_FILE="${workdir}/missing-config.json"
  HAPROXY_CONFIG="${workdir}/missing-haproxy.cfg"
  SERVER_IP="198.51.100.10"
  NODE_LABEL_PREFIX="hkg"
  REALITY_UUID="11111111-1111-1111-1111-111111111111"
  REALITY_SNI="reality.example.com"
  REALITY_TARGET="reality.example.com:443"
  REALITY_SHORT_ID="abcd1234"
  REALITY_PRIVATE_KEY="private-key"
  XHTTP_UUID="22222222-2222-2222-2222-222222222222"
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/edge"
  CERT_MODE="self-signed"
  ENABLE_WARP="no"
  ENABLE_NET_OPT="no"

  need_root() { :; }
  ensure_debian_family() { :; }
  start_backup_session() { BACKUP_DIR="${workdir}/backup"; }
  install_prepare_and_preflight() { :; }

  prepare_install_command --non-interactive --enable-xhttp-ech --enable-xhttp-xpadding

  [[ "${XHTTP_ECH_CONFIG_LIST}" == "https://dns.alidns.com/dns-query" ]]
  [[ -z "${XHTTP_ECH_FORCE_QUERY}" ]]
  [[ "${XHTTP_XPADDING_ENABLED}" == "yes" ]]
}

run_sensitive_option_reject_case() {
  local output=""

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
parse_install_args --warp-private-key direct-key
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q '不支持直接明文传值'
  printf '%s' "${output}" | grep -q 'WARP_PRIVATE_KEY'

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
parse_install_args --warp-profile /tmp/profile.conf
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q '不支持直接明文传值'
}

# curl 的桩必须和真 curl 的契约一致，不然测出来的是桩的脾气不是代码的。
# 不带 -f 时：HTTP 错误照样退 0，body 原样给出来，-w '\n%{http_code}' 把状态码接在
# 最后一行；连不上时状态码是 000 且 body 为空。
# 这个桩以前是 `printf '%s' '{"success":false}'` 然后退 0——真 curl 带着 -f
# 永远不会这样，它把出错响应的 body 整个丢掉、退 22。桩比真货听话，于是
# 「任何坏令牌都被预检放行」这个缺陷在测试全绿的情况下活了下来。
preflight_token_probe() {
  local body="${1}"
  local http_code="${2}"
  local workdir="${3}"

  printf '%s\n%s' "${body}" "${http_code}" > "${workdir}/response"
  ROOT_DIR="${ROOT_DIR}" STUB_RESPONSE="${workdir}/response" \
    bash "${workdir}/probe.sh" 2>&1
}

run_preflight_token_verify_case() {
  local workdir=""
  local output=""

  workdir="$(mktemp -d)"
  cat > "${workdir}/probe.sh" <<'PROBE'
set -Eeuo pipefail
# shellcheck disable=SC1090
source <(sed '$d' "${ROOT_DIR}/xtun.sh")
curl() { cat "${STUB_RESPONSE}"; }
# 预检跑在安装包之前，宿主机可能还没有 jq——那条路要退回 sed 取错误信息。
if [[ -n "${STUB_NO_JQ:-}" ]]; then
  command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "jq" ]]; then
      return 1
    fi
    builtin command "$@"
  }
  jq() { return 99; }
fi
verify_cloudflare_token "token-value" "Cloudflare API Token"
PROBE

  # 令牌没问题
  output="$(preflight_token_probe '{"success":true}' 200 "${workdir}")"
  printf '%s' "${output}" | grep -q 'Cloudflare API Token 校验通过'

  # 令牌是坏的：Cloudflare 回 401 加一段说清了原因的 JSON，必须死掉，
  # 而且要把它自己的错误信息带出来——「令牌不对」和「权限不够」是两回事
  if output="$(preflight_token_probe \
    '{"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}],"messages":[],"result":null}' \
    401 "${workdir}")"; then
    printf '[fail] 401 + Invalid API Token 时预检没有失败\n' >&2
    return 1
  fi
  printf '%s' "${output}" | grep -q 'Cloudflare API Token 校验未通过'
  printf '%s' "${output}" | grep -q 'HTTP 401'
  printf '%s' "${output}" | grep -q 'Invalid API Token'

  # 权限不足是另一条要给操作员看的信息
  if output="$(preflight_token_probe \
    '{"success":false,"errors":[{"code":9109,"message":"Unauthorized to access requested resource"}]}' \
    403 "${workdir}")"; then
    printf '[fail] 403 权限不足时预检没有失败\n' >&2
    return 1
  fi
  printf '%s' "${output}" | grep -q 'Unauthorized to access requested resource'

  # 关键的回归钉子：Cloudflare 答了话但 body 为空。旧代码「响应为空就当没连上」
  # 正是在这里放行的——答了话就不能再算没连上。
  if output="$(preflight_token_probe '' 403 "${workdir}")"; then
    printf '[fail] body 为空的 403 被当成「没连上」放行了\n' >&2
    return 1
  fi
  printf '%s' "${output}" | grep -q 'Cloudflare API Token 校验未通过'
  printf '%s' "${output}" | grep -q 'HTTP 403'

  # 真的连不上（状态码 000）才保留原来的宽容行为：警告一句然后放过
  output="$(preflight_token_probe '' 000 "${workdir}")"
  printf '%s' "${output}" | grep -q '无法在线校验 Cloudflare API Token'
  assert_false grep -q '校验未通过' <<< "${output}"

  # 没有 jq 时错误信息退回 sed 取，不能因此变成空话
  if output="$(STUB_NO_JQ=1 preflight_token_probe \
    '{"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}],"messages":[]}' \
    401 "${workdir}")"; then
    printf '[fail] 没有 jq 时 401 没有让预检失败\n' >&2
    return 1
  fi
  printf '%s' "${output}" | grep -q 'Invalid API Token'

  rm -rf "${workdir}"
}

run_preflight_domain_resolution_warning_case() {
  local output=""

  if ! output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
getent() {
  return 2
}
preflight_check_domain_resolution "cdn.example.test" "XHTTP CDN 域名"
EOF
)"; then
    return 1
  fi

  printf '%s' "${output}" | grep -q '预检提示：XHTTP CDN 域名 当前无法解析'
}

run_warp_rule_normalize_case() {
  local output=""

  output="$(normalize_warp_rules_text $' chat.openai.com \n# comment\ngeosite:google\ndomain:chat.openai.com\n')"
  [[ "${output}" == $'domain:chat.openai.com\ngeosite:google' ]]

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
normalize_warp_rules_text \$'bad rule with space'
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q 'WARP 分流规则不能包含空白字符'
}

# 菜单 13 的交互编辑器。read 的提示走 stderr，最终规则走 stdout，
# 所以喂一份脚本化的按键就能整条路径跑一遍。
run_warp_rules_editor_case() {
  local output=""
  local status=0

  WARP_RULES_TEXT=$'geosite:openai\ndomain:github.com'

  # a 添加裸域名（自动补 domain:）、d 按序号删、d 按规则名删、s 保存
  output="$(prompt_warp_rules_editor <<'EOF' 2>/dev/null
a
claude.ai
d
1
d
github.com
s
EOF
)"
  [[ "${output}" == 'domain:claude.ai' ]]

  # 非法输入只警告不退出：坏规则、坏操作、重复规则都要能继续，最后仍能保存
  output="$(prompt_warp_rules_editor <<'EOF' 2>/dev/null
a
bad rule
z
a
geosite:openai
s
EOF
)"
  [[ "${output}" == $'geosite:openai\ndomain:github.com' ]]

  # r 恢复默认
  output="$(prompt_warp_rules_editor <<'EOF' 2>/dev/null
r
s
EOF
)"
  [[ "${output}" == "$(default_warp_rules_text)" ]]

  # 直接回车等价于保存
  output="$(prompt_warp_rules_editor <<'EOF' 2>/dev/null

EOF
)"
  [[ "${output}" == $'geosite:openai\ndomain:github.com' ]]

  # q 放弃退出：返回非 0，且不能吐出任何规则
  output="$(prompt_warp_rules_editor <<'EOF' 2>/dev/null
q
EOF
)" || status=$?
  [[ "${status}" -ne 0 ]]
  [[ -z "${output}" ]]

  # 删空之后不许保存，否则等于无声关掉分流
  status=0
  output="$(prompt_warp_rules_editor <<'EOF' 2>/dev/null
d
1
d
1
s
q
EOF
)" || status=$?
  [[ "${status}" -ne 0 ]]
  [[ -z "${output}" ]]

  WARP_RULES_TEXT=""
}

run_optional_component_skip_case() {
  ENABLE_NET_OPT="no"
  ENABLE_WARP="no"

  install_network_optimization
  ensure_warp_credentials
}

run_joey_bbr_release_parse_case() {
  local metadata_json=""
  local tag_name=""
  local rows=""

  metadata_json='[
    {
      "tag_name": "x86_64-7.0.5",
      "published_at": "2026-05-08T12:29:14Z",
      "assets": [
        {
          "name": "linux-image-7.0.5-joeyblog-bbrv3_7.0.5-1_amd64.deb",
          "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "browser_download_url": "https://example.invalid/x86-image.deb"
        }
      ]
    },
    {
      "tag_name": "arm64-7.0.3",
      "published_at": "2026-05-04T16:33:05Z",
      "assets": [
        {
          "name": "linux-image-7.0.3-joeyblog-bbrv3_7.0.3-1_arm64.deb",
          "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "browser_download_url": "https://example.invalid/arm-image.deb"
        },
        {
          "name": "linux-image-7.0.3-joeyblog-bbrv3-dbg_7.0.3-1_arm64.deb",
          "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
          "browser_download_url": "https://example.invalid/arm-debug.deb"
        }
      ]
    }
  ]'

  [[ "$(joey_bbr_release_arch_filter aarch64)" == "arm64" ]]
  [[ "$(joey_bbr_release_arch_filter x86_64)" == "x86_64" ]]
  tag_name="$(joey_bbr_latest_tag_from_metadata "${metadata_json}" "arm64")"
  [[ "${tag_name}" == "arm64-7.0.3" ]]
  [[ "$(joey_bbr_latest_core_version_from_tag "${tag_name}")" == "7.0.3" ]]

  rows="$(joey_bbr_release_asset_rows_from_metadata "${metadata_json}" "${tag_name}")"
  printf '%s' "${rows}" | grep -q 'linux-image-7.0.3-joeyblog-bbrv3_7.0.3-1_arm64.deb'
  printf '%s' "${rows}" | grep -qv -- '-dbg_'
  validate_joey_bbr_asset_rows "${rows}"
}

run_joey_bbr_pending_reboot_case() {
  local fixture_json=""
  local downloaded=0
  local installed=0

  NET_BBRV3_REBOOT_REQUIRED="no"
  fixture_json='[
    {
      "tag_name": "arm64-7.0.3",
      "published_at": "2026-05-04T16:33:05Z",
      "assets": [
        {
          "name": "linux-image-7.0.3-joeyblog-bbrv3_7.0.3-1_arm64.deb",
          "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "browser_download_url": "https://example.invalid/arm-image.deb"
        }
      ]
    }
  ]'

  bbr_v3_active() { return 1; }
  uname() { printf '%s\n' "aarch64"; }
  fetch_joey_bbr_release_metadata_json() { printf '%s' "${fixture_json}"; }
  joey_bbr_installed_kernel_version() { printf '%s\n' "7.0.3-g90210de4b779-1"; }
  download_joey_bbrv3_assets() { downloaded=$((downloaded + 1)); }
  install_joey_bbrv3_deb_files() { installed=$((installed + 1)); }
  warn() { :; }
  log_success() { :; }

  install_joey_bbrv3_kernel_if_needed

  [[ "${NET_BBRV3_REBOOT_REQUIRED}" == "yes" ]]
  [[ "${downloaded}" -eq 0 ]]
  [[ "${installed}" -eq 0 ]]
  load_functions
}

run_install_network_joey_reboot_case() {
  local workdir=""
  local sysctl_calls=0
  local systemctl_calls=""

  workdir="$(mktemp -d)"
  NET_SYSCTL_CONF="${workdir}/net.conf"
  NET_HELPER_PATH="${workdir}/xtun-net-optimize.sh"
  NET_SERVICE_FILE="${workdir}/xtun-net-optimize.service"
  ENABLE_NET_OPT="yes"
  NET_BBRV3_REBOOT_REQUIRED="no"

  install_joey_bbrv3_kernel_if_needed() {
    NET_BBRV3_REBOOT_REQUIRED="yes"
  }
  available_cc() { :; }
  supports_default_qdisc() { return 1; }
  bbr_v3_active() { return 1; }
  modprobe() { :; }
  backup_path() { :; }
  sysctl() {
    sysctl_calls=$((sysctl_calls + 1))
    return 1
  }
  systemctl() {
    systemctl_calls+="$*"$'\n'
  }
  warn() { :; }
  log_success() { :; }

  install_network_optimization

  assert_contains 'net.core.default_qdisc = fq' "${NET_SYSCTL_CONF}"
  assert_contains 'net.ipv4.tcp_congestion_control = bbr' "${NET_SYSCTL_CONF}"
  [[ -x "${NET_HELPER_PATH}" ]]
  [[ -f "${NET_SERVICE_FILE}" ]]
  [[ "${sysctl_calls}" -eq 1 ]]
  printf '%s' "${systemctl_calls}" | grep -q '^daemon-reload$'
  printf '%s' "${systemctl_calls}" | grep -q "^enable --now ${NET_SERVICE_NAME}$"
  [[ "${ENABLE_NET_OPT}" == "yes" ]]
  load_functions
}

run_net_sysctl_content_case() {
  local workdir=""
  local tcp_mem=""
  local low=0
  local mid=0
  local high=0

  workdir="$(mktemp -d)"
  NET_SYSCTL_CONF="${workdir}/net.conf"
  NET_HELPER_PATH="${workdir}/xtun-net-optimize.sh"
  NET_BBRV3_REBOOT_REQUIRED="no"

  backup_path() { :; }
  supports_default_qdisc() { return 0; }
  bbr_v3_active() { return 1; }
  modprobe() { :; }

  # 内核只暴露 bbr 时写 bbr。
  available_cc() { printf '%s' "reno cubic bbr"; }
  [[ "$(preferred_congestion_control)" == "bbr" ]]
  cc_has_bbr "$(available_cc)"

  # 暴露 bbr1 时优先 bbr1。
  available_cc() { printf '%s' "reno cubic bbr bbr1"; }
  [[ "$(preferred_congestion_control)" == "bbr1" ]]

  # 只有 bbr1 没有 bbr 的内核同样算支持，不能被安装流程判成不支持。
  available_cc() { printf '%s' "reno cubic bbr1"; }
  cc_has_bbr "$(available_cc)"
  assert_false cc_has_bbr "reno cubic"
  assert_false cc_has_bbr "reno cubic bbrplus"

  tcp_mem="$(net_tcp_mem_values)"
  read -r low mid high <<< "${tcp_mem}"
  [[ "${low}" -gt 0 && "${mid}" -gt "${low}" && "${high}" -gt "${mid}" ]]

  # fs.file-max 的三个分支：撑不到 LimitNOFILE 就不写，够了按 MemTotal/4 给，再大封顶。
  # 传 2GB：512k 个 struct file，低于 xray.service 要的 1048576，跳过。
  [[ -z "$(net_file_max_value 2097152 || true)" ]]
  [[ "$(net_file_max_value 4194304)" == "1048576" ]]
  [[ "$(net_file_max_value 24576680)" == "${NET_FILE_MAX_CEILING}" ]]
  # 读不到 MemTotal 时不能把非数字当 0 算下去。
  [[ -z "$(net_file_max_value 'unknown' || true)" ]]

  # 写文件这段跟跑测试的机器内存脱钩，否则小内存 CI 上断言会自己翻。
  net_file_max_value() { printf '%s' "1048576"; }

  write_net_sysctl_conf

  assert_contains 'net.core.default_qdisc = fq' "${NET_SYSCTL_CONF}"
  assert_contains 'net.ipv4.tcp_congestion_control = bbr1' "${NET_SYSCTL_CONF}"
  assert_contains "net.ipv4.tcp_mem = ${tcp_mem}" "${NET_SYSCTL_CONF}"
  assert_contains 'net.ipv4.tcp_no_metrics_save = 1' "${NET_SYSCTL_CONF}"
  assert_contains 'net.core.netdev_max_backlog = 32768' "${NET_SYSCTL_CONF}"
  assert_contains 'net.core.netdev_budget = 1200' "${NET_SYSCTL_CONF}"
  assert_contains 'net.core.netdev_budget_usecs = 8000' "${NET_SYSCTL_CONF}"
  assert_contains 'net.core.rmem_max = 67108864' "${NET_SYSCTL_CONF}"
  assert_contains 'net.core.wmem_max = 67108864' "${NET_SYSCTL_CONF}"
  assert_contains 'net.ipv4.udp_rmem_min = 262144' "${NET_SYSCTL_CONF}"
  # 这三个键原本靠手写的 99 覆盖层补，收进模板后 99 才能删掉。
  assert_contains 'net.ipv4.tcp_tw_reuse = 1' "${NET_SYSCTL_CONF}"
  assert_contains 'net.ipv4.tcp_fin_timeout = 15' "${NET_SYSCTL_CONF}"
  assert_contains 'fs.file-max = 1048576' "${NET_SYSCTL_CONF}"
  # §7.2：未发送数据上限，h2 多路复用下防小流被大流堵住
  assert_contains 'net.ipv4.tcp_notsent_lowat = 131072' "${NET_SYSCTL_CONF}"

  # 读不到内存信息时整段跳过，而不是写一行空值把 sysctl --system 弄失败。
  net_tcp_mem_values() { return 1; }
  net_file_max_value() { return 1; }
  write_net_sysctl_conf
  assert_absent 'tcp_mem' "${NET_SYSCTL_CONF}"
  assert_absent 'file-max' "${NET_SYSCTL_CONF}"

  # fq 的 limit / flow_limit 默认值在高 BDP 链路上会丢包，helper 必须带上放宽后的参数，
  # 同时保留老内核不认参数时的退路。
  write_net_helper_script
  assert_contains 'root fq limit 100000 flow_limit 1000' "${NET_HELPER_PATH}"
  assert_contains 'root fq >/dev/null 2>&1' "${NET_HELPER_PATH}"
  sh -n "${NET_HELPER_PATH}"

  # 云厂商 DHCP 下发的巨帧 MTU（Oracle VCN 给 9000）要夹回 1500，但只能往下夹：
  # PPPoE / 隧道那种 1492、1450 的链路被抬上去会直接黑洞。
  assert_contains 'ip link set dev "\$iface" mtu 1500' "${NET_HELPER_PATH}"
  assert_contains 'mtu 1500' "${NET_HELPER_PATH}"
  # 判定逻辑单独跑一遍，别只看文本里有没有这几行。
  eval "$(sed -n '/^mtu_over_1500()/,/^}/p' "${NET_HELPER_PATH}")"
  mtu_over_1500 9000
  mtu_over_1500 1501
  assert_false mtu_over_1500 1500
  assert_false mtu_over_1500 1492
  assert_false_silently mtu_over_1500 ''
  assert_false_silently mtu_over_1500 'unknown'
  unset -f mtu_over_1500

  rm -rf "${workdir}"
  load_functions
}

run_apply_net_opt_command_case() {
  local calls=""
  local logged=""
  local workdir=""

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  eval "$(declare -f start_backup_session | sed '1s/start_backup_session/case_real_start_backup_session/')"
  ENABLE_NET_OPT="no"
  NET_BBRV3_REBOOT_REQUIRED="stale"

  need_root() {
    calls+="root"$'\n'
  }
  ensure_debian_family() {
    calls+="debian"$'\n'
  }
  start_backup_session() {
    calls+="backup"$'\n'
    case_real_start_backup_session
  }
  load_current_install_context() {
    calls+="load"$'\n'
    ENABLE_NET_OPT="no"
    REALITY_UUID="11111111-1111-1111-1111-111111111111"
    XHTTP_UUID="22222222-2222-2222-2222-222222222222"
  }
  install_network_optimization() {
    calls+="net:${ENABLE_NET_OPT}:${NET_BBRV3_REBOOT_REQUIRED}"$'\n'
  }
  write_state_file() {
    calls+="state:${ENABLE_NET_OPT}"$'\n'
  }
  bbr_v3_active() {
    return 1
  }
  log_step() {
    logged+="STEP:${1}"$'\n'
  }
  log_success() {
    logged+="DONE:${1}"$'\n'
  }
  log() {
    logged+="${1}"$'\n'
  }

  apply_net_opt_cmd --non-interactive
  [[ "${ENABLE_NET_OPT}" == "yes" ]]
  [[ "${NET_BBRV3_REBOOT_REQUIRED}" == "no" ]]
  [[ "${calls}" == $'debian\nroot\nload\nbackup\nnet:yes:no\nstate:yes\n' ]]
  grep -q 'STEP:读取当前托管安装状态。' <<< "${logged}"
  grep -q 'STEP:应用 Joey BBRv3 网络优化。' <<< "${logged}"
  grep -q 'DONE:网络优化已应用。' <<< "${logged}"
  grep -q "备份目录：${BACKUP_DIR}" <<< "${logged}"

  NET_BBRV3_REBOOT_REQUIRED="yes"
  install_network_optimization() {
    NET_BBRV3_REBOOT_REQUIRED="yes"
    calls+="net-reboot"$'\n'
  }
  calls=""
  logged=""

  apply_net_opt_cmd --non-interactive
  grep -q '请重启 VPS 后加载 Joey BBRv3 内核。' <<< "${logged}"
  load_functions
}

# 脚本升级后没有任何东西会重渲染 haproxy.cfg / nginx.conf，
# apply-config 就是补这个缺口的；它不该顺手改客户端链接，所以不重刷部署文档。
run_apply_config_command_case() {
  local calls=""
  local logged=""
  local workdir=""

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  eval "$(declare -f start_backup_session | sed '1s/start_backup_session/case_real_start_backup_session/')"

  need_root() {
    calls+="root"$'\n'
  }
  start_backup_session() {
    calls+="backup"$'\n'
    case_real_start_backup_session
  }
  load_current_install_context() {
    calls+="load"$'\n'
  }
  ensure_xray_user() {
    calls+="xray-user"$'\n'
  }
  apply_managed_files() {
    calls+="apply:${1}"$'\n'
    generation_commit
  }
  show_links() {
    calls+="links"$'\n'
  }
  log_step() {
    logged+="STEP:${1}"$'\n'
  }
  log_success() {
    logged+="DONE:${1}"$'\n'
  }
  log() {
    logged+="${1}"$'\n'
  }

  apply_config_cmd --non-interactive
  # apply:no = 不重签 TLS 资产，只重渲染托管配置
  [[ "${calls}" == $'root\nload\nbackup\nxray-user\napply:no\n' ]]
  grep -q 'STEP:按当前状态重新生成托管配置。' <<< "${logged}"
  grep -q 'DONE:托管配置已按当前状态重新生成。' <<< "${logged}"
  grep -q "备份目录：${BACKUP_DIR}" <<< "${logged}"

  if (apply_config_cmd --bogus) 2>/dev/null; then
    return 1
  fi

  load_functions
}

run_install_draft_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  INSTALL_DRAFT_FILE="${workdir}/install-draft.env"
  SERVER_IP="203.0.113.10"
  NODE_LABEL_PREFIX="HKG"
  REALITY_SNI="reality.example.com"
  XHTTP_DOMAIN="cdn.example.com"
  ENABLE_WARP="yes"
  set_test_warp_credentials

  write_install_draft_file

  SERVER_IP=""
  NODE_LABEL_PREFIX=""
  REALITY_SNI=""
  XHTTP_DOMAIN=""
  ENABLE_WARP=""
  clear_test_warp_credentials
  load_install_draft_file
  [[ "${SERVER_IP}" == "203.0.113.10" ]]
  [[ "${NODE_LABEL_PREFIX}" == "HKG" ]]
  [[ "${REALITY_SNI}" == "reality.example.com" ]]
  [[ "${XHTTP_DOMAIN}" == "cdn.example.com" ]]
  [[ "${ENABLE_WARP}" == "yes" ]]
  [[ "${WARP_PRIVATE_KEY}" == "${TEST_WARP_PRIVATE_KEY}" ]]
  [[ "${WARP_ADDRESS_V4}" == "172.16.0.2" ]]
  [[ "${WARP_RESERVED}" == "3,4,5" ]]
  [[ "$(stat -c '%a' "${INSTALL_DRAFT_FILE}")" == "600" ]]

  clear_install_draft_file
  [[ ! -f "${INSTALL_DRAFT_FILE}" ]]
}

# acme.sh 的 reloadcmd 是无人值守跑的，大约每 60 天一次。生成的钩子里有两条硬要求：
# 一是不许重启 xray（这张证书 xray 一次都没引用，重启只是白掐 Reality 会话），
# 二是不许把失败吞掉（吞了就等于「证书换了但没生效」永远没人知道）。
run_acme_reload_helper_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  ACME_RELOAD_HELPER="${workdir}/xtun-cert-reload.sh"
  XRAY_GID="456"
  backup_path() { :; }

  write_acme_reload_helper "${workdir}/stage-cert.pem" "${workdir}/stage-key.pem"

  bash -n "${ACME_RELOAD_HELPER}"
  [[ -x "${ACME_RELOAD_HELPER}" ]]
  assert_absent 'restart xray' "${ACME_RELOAD_HELPER}"
  assert_contains 'exec bash .* acme-deploy --domain ' "${ACME_RELOAD_HELPER}"
  assert_absent 'mv -f' "${ACME_RELOAD_HELPER}"

  rm -rf "${workdir}"
  load_functions
}

# nginx 打包的 unit 没写 LimitNOFILE，fresh install 的 worker 只有 systemd 默认的
# 1024 个 fd。这个 drop-in 是唯一能在不接管 nginx.conf 的前提下抬起它的地方。
run_nginx_limits_dropin_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  NGINX_LIMITS_DROPIN_FILE="${workdir}/systemd/nginx.service.d/xtun-limits.conf"
  backup_path() { :; }

  NGINX_RESTART_REQUIRED="no"
  write_nginx_limits_dropin
  assert_contains '\[Service\]' "${NGINX_LIMITS_DROPIN_FILE}"
  assert_contains 'LimitNOFILE=1048576' "${NGINX_LIMITS_DROPIN_FILE}"
  [[ "$(stat -c '%a' "${NGINX_LIMITS_DROPIN_FILE}")" == "644" ]]
  # 新写进去就得让调用方知道要重启一次，reload 套不上 rlimit。
  [[ "${NGINX_RESTART_REQUIRED}" == "yes" ]]

  # 内容没变就别再要求重启：apply-config 会反复跑，不能每次都掐一遍 nginx。
  NGINX_RESTART_REQUIRED="no"
  write_nginx_limits_dropin
  [[ "${NGINX_RESTART_REQUIRED}" == "no" ]]

  rm -rf "${workdir}"
  load_functions
}

run_nginx_worker_connections_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  NGINX_MAIN_CONFIG="${workdir}/nginx.conf"

  # 读不到主配置时只报未知，不能因此把 diagnose 带崩，也别让 awk 往 stderr 吐一行。
  assert_false_silently nginx_worker_connections_value
  [[ "$(nginx_worker_connections_state)" == "unknown" ]]
  [[ "$(nginx_worker_connections_text)" == "未知" ]]

  # 发行版默认 768：反代要占两个 fd，实际只够 384 个客户端，得报出来。
  printf 'events {\n    worker_connections 768;\n}\n' > "${NGINX_MAIN_CONFIG}"
  [[ "$(nginx_worker_connections_value)" == "768" ]]
  [[ "$(nginx_worker_connections_state)" == "low" ]]
  case "$(nginx_worker_connections_text)" in
    768*384*"${NGINX_MAIN_CONFIG}"*) ;;
    *) return 1 ;;
  esac

  printf 'events {\n    worker_connections 8192;\n}\n' > "${NGINX_MAIN_CONFIG}"
  [[ "$(nginx_worker_connections_state)" == "ok" ]]
  [[ "$(nginx_worker_connections_text)" == "8192" ]]

  # 值不是数字就当读不到，别把脏值算进 -ge 比较里。
  printf 'events {\n    worker_connections auto;\n}\n' > "${NGINX_MAIN_CONFIG}"
  [[ "$(nginx_worker_connections_state)" == "unknown" ]]
  assert_false_silently nginx_worker_connections_value

  rm -rf "${workdir}"
  load_functions
}

run_cert_mode_input_case() {
  NON_INTERACTIVE=1

  CERT_MODE="existing"
  CERT_SOURCE_FILE="/tmp/old-cert.pem"
  KEY_SOURCE_FILE="/tmp/old-key.pem"
  CERT_SOURCE_PEM="old-cert-pem"
  KEY_SOURCE_PEM="old-key-pem"
  ACME_EMAIL="ops@example.com"
  ACME_CA="zerossl"
  CF_DNS_TOKEN="dns-token"
  CF_DNS_ACCOUNT_ID="account-id"
  CF_DNS_ZONE_ID="dns-zone-id"
  prompt_cert_mode_inputs
  [[ "${CERT_SOURCE_FILE}" == "/tmp/old-cert.pem" ]]
  [[ "${KEY_SOURCE_FILE}" == "/tmp/old-key.pem" ]]
  [[ -z "${CERT_SOURCE_PEM}" ]]
  [[ -z "${KEY_SOURCE_PEM}" ]]
  [[ -z "${ACME_EMAIL}" ]]
  [[ "${ACME_CA}" == "letsencrypt" ]]
  [[ -z "${CF_DNS_TOKEN}" ]]
  [[ -z "${CF_DNS_ACCOUNT_ID}" ]]
  [[ -z "${CF_DNS_ZONE_ID}" ]]

  # 旧别名 cf-origin-ca 并入 existing
  CERT_MODE="$(normalize_cert_mode 'cf-origin-ca')"
  [[ "${CERT_MODE}" == "existing" ]]
  CERT_MODE="$(normalize_cert_mode '3')"
  [[ "${CERT_MODE}" == "existing" ]]
  CERT_MODE="$(normalize_cert_mode '4')"
  [[ "${CERT_MODE}" == "acme-dns-cf" ]]

  CERT_MODE="acme-dns-cf"
  CERT_SOURCE_FILE="/tmp/old-cert.pem"
  KEY_SOURCE_FILE="/tmp/old-key.pem"
  CERT_SOURCE_PEM="old-cert-pem"
  KEY_SOURCE_PEM="old-key-pem"
  ACME_EMAIL="ops@example.com"
  ACME_CA="zerossl"
  CF_DNS_TOKEN="dns-token"
  CF_DNS_ACCOUNT_ID="account-id"
  CF_DNS_ZONE_ID="dns-zone-id"
  prompt_cert_mode_inputs
  [[ -z "${CERT_SOURCE_FILE}" ]]
  [[ -z "${KEY_SOURCE_FILE}" ]]
  [[ -z "${CERT_SOURCE_PEM}" ]]
  [[ -z "${KEY_SOURCE_PEM}" ]]
  [[ "${ACME_EMAIL}" == "ops@example.com" ]]
  [[ "${ACME_CA}" == "zerossl" ]]
  [[ "${CF_DNS_TOKEN}" == "dns-token" ]]
  [[ "${CF_DNS_ACCOUNT_ID}" == "account-id" ]]
  [[ "${CF_DNS_ZONE_ID}" == "dns-zone-id" ]]

  CERT_MODE="self-signed"
  CERT_SOURCE_FILE="/tmp/old-cert.pem"
  KEY_SOURCE_FILE="/tmp/old-key.pem"
  CERT_SOURCE_PEM="old-cert-pem"
  KEY_SOURCE_PEM="old-key-pem"
  ACME_EMAIL="ops@example.com"
  ACME_CA="zerossl"
  CF_DNS_TOKEN="dns-token"
  CF_DNS_ACCOUNT_ID="account-id"
  CF_DNS_ZONE_ID="dns-zone-id"
  prompt_cert_mode_inputs
  [[ -z "${CERT_SOURCE_FILE}" ]]
  [[ -z "${KEY_SOURCE_FILE}" ]]
  [[ -z "${CERT_SOURCE_PEM}" ]]
  [[ -z "${KEY_SOURCE_PEM}" ]]
  [[ -z "${ACME_EMAIL}" ]]
  [[ "${ACME_CA}" == "letsencrypt" ]]
  [[ -z "${CF_DNS_TOKEN}" ]]
  [[ -z "${CF_DNS_ACCOUNT_ID}" ]]
  [[ -z "${CF_DNS_ZONE_ID}" ]]
}

run_warp_credential_helper_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  clear_test_warp_credentials

  [[ "$(warp_reserved_from_client_id 'AwQF')" == "3,4,5" ]]
  [[ -z "$(warp_reserved_from_client_id '')" ]]

  [[ "$(normalize_warp_reserved_value '[1, 2, 3]')" == "1,2,3" ]]
  [[ "$(normalize_warp_reserved_value ' 0,255 ')" == "0,255" ]]
  [[ -z "$(normalize_warp_reserved_value '')" ]]

  cat > "${workdir}/profile.conf" <<'PROFILE'
[Interface]
PrivateKey = eHR1bi10ZXN0LXdhcnAtcHJpdmF0ZS1rZXktMzJieXQ=
Address = 172.16.0.2/32, 2606:4700:110:8a1b:cafe:1:2:4/128
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = eHR1bi10ZXN0LXdhcnAtcGVlci1wdWJsaWMta2V5LTM=
AllowedIPs = 0.0.0.0/0
Endpoint = 162.159.192.1:2408
PROFILE

  warp_import_profile "$(cat "${workdir}/profile.conf")" >/dev/null
  [[ "${WARP_PRIVATE_KEY}" == "${TEST_WARP_PRIVATE_KEY}" ]]
  [[ "${WARP_ADDRESS_V4}" == "172.16.0.2" ]]
  [[ "${WARP_ADDRESS_V6}" == "2606:4700:110:8a1b:cafe:1:2:4" ]]
  [[ "${WARP_PEER_PUBLIC_KEY}" == "${TEST_WARP_PEER_PUBLIC_KEY}" ]]
  [[ "${WARP_ENDPOINT}" == "162.159.192.1:2408" ]]
  [[ "${WARP_MTU}" == "1280" ]]
  # wgcf 标准 profile 不含 Reserved，留空由 --warp-reserved 手工补
  [[ -z "${WARP_RESERVED}" ]]
  warp_credentials_ready
  ensure_warp_outbound_format

  clear_test_warp_credentials
  printf '%s\n' 'Reserved = [9, 8, 7]' >> "${workdir}/profile.conf"
  warp_import_profile "$(cat "${workdir}/profile.conf")" >/dev/null
  [[ "${WARP_RESERVED}" == "9,8,7" ]]

  clear_test_warp_credentials
  if warp_import_profile "$(printf '%s\n' '[Interface]' 'Address = 172.16.0.2/32')" 2>/dev/null; then
    return 1
  fi
  if warp_import_profile "$(printf '%s\n' '[Interface]' "PrivateKey = ${TEST_WARP_PRIVATE_KEY}")" 2>/dev/null; then
    return 1
  fi

  clear_test_warp_credentials
  ENABLE_WARP="no"
  ensure_warp_credentials

  ENABLE_WARP="yes"
  set_test_warp_credentials
  warp_register_free_device() {
    return 1
  }
  ensure_warp_credentials
  [[ "${WARP_PRIVATE_KEY}" == "${TEST_WARP_PRIVATE_KEY}" ]]
  load_functions
}

run_warp_credential_ensure_failure_case() {
  local output=""

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
ENABLE_WARP="yes"
WARP_PRIVATE_KEY=""
WARP_ADDRESS_V4=""
WARP_ADDRESS_V6=""
WARP_PROFILE_SOURCE=""
warp_legacy_team_detected() { return 1; }
warp_register_free_device() { return 1; }
ensure_warp_credentials
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q '\-\-warp-profile'
  printf '%s' "${output}" | grep -q '\-\-disable-warp'
}

# 0.11 遗留的巡检与 WARP Team 托管文件，升级 / 卸载 / 重装时由
# remove_legacy_managed_paths 兜底清一遍。路径经 LEGACY_PATH_ROOT 改写进沙箱。
run_legacy_cleanup_case() {
  local workdir=""
  local stopped=""
  local logged=""

  workdir="$(mktemp -d)"
  LEGACY_PATH_ROOT="${workdir}"
  mkdir -p "${workdir}/usr/local/sbin" "${workdir}/etc/systemd/system" "${workdir}/root"

  printf 'legacy\n' > "${workdir}/usr/local/sbin/xtun-core-health.sh"
  printf 'legacy\n' > "${workdir}/etc/systemd/system/xtun-core-health.service"
  printf 'legacy\n' > "${workdir}/etc/systemd/system/xtun-core-health.timer"
  printf 'legacy\n' > "${workdir}/usr/local/etc-xray-stand-in"
  mkdir -p "${workdir}/root/xtun-subscriptions" "${workdir}/var/www/xtun-sub/tok1234"
  printf 'legacy\n' > "${workdir}/root/xtun-subscriptions/vless.txt"
  printf 'legacy\n' > "${workdir}/var/www/xtun-sub/tok1234/vless.txt"
  printf 'legacy\n' > "${workdir}/var-lib-cloudflare-warp.md"
  mv "${workdir}/var-lib-cloudflare-warp.md" "${workdir}/keep.md"

  service_exists() { return 1; }
  stop_and_disable_service_if_present() {
    stopped+="${1}"$'\n'
  }
  log() {
    logged+="${1}"$'\n'
  }
  log_step() {
    logged+="STEP:${1}"$'\n'
  }

  remove_legacy_managed_paths

  [[ "${#stopped[@]}" -ne 0 ]]
  printf '%s' "${stopped}" | grep -q 'xtun-core-health.timer'
  printf '%s' "${stopped}" | grep -q 'xtun-warp-health.timer'
  printf '%s' "${stopped}" | grep -q 'warp-svc.service'
  [[ ! -e "${workdir}/usr/local/sbin/xtun-core-health.sh" ]]
  [[ ! -e "${workdir}/etc/systemd/system/xtun-core-health.service" ]]
  [[ ! -e "${workdir}/etc/systemd/system/xtun-core-health.timer" ]]
  [[ ! -d "${workdir}/root/xtun-subscriptions" ]]
  [[ ! -d "${workdir}/var/www/xtun-sub" ]]
  printf '%s' "${logged}" | grep -q 'STEP:清理旧版本遗留的托管文件。'
  [[ -e "${workdir}/keep.md" ]]

  # 没有遗留文件时是安静幂等：不再 log_step，也不碰 systemd
  stopped=""
  logged=""
  remove_legacy_managed_paths
  [[ -z "${stopped}" ]]
  [[ -z "${logged}" ]]

  LEGACY_PATH_ROOT=""
  load_functions
}

run_warp_credential_ensure_failure_case() {
  local output=""

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
ENABLE_WARP="yes"
WARP_PRIVATE_KEY=""
WARP_ADDRESS_V4=""
WARP_ADDRESS_V6=""
WARP_PROFILE_SOURCE=""
warp_legacy_team_detected() { return 1; }
warp_register_free_device() { return 1; }
ensure_warp_credentials
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q '\-\-warp-profile'
  printf '%s' "${output}" | grep -q '\-\-disable-warp'
}

run_warp_legacy_teardown_case() {
  local workdir=""
  local stopped=()
  local removed=()
  local logged=""

  workdir="$(mktemp -d)"
  printf 'legacy\n' > "${workdir}/mdm.xml"

  legacy_warp_paths() {
    printf '%s\n' "${workdir}/mdm.xml" "${workdir}/missing.list"
  }
  service_exists() { return 1; }
  stop_and_disable_service_if_present() {
    stopped+=("${1}")
  }
  remove_managed_paths() {
    removed=("$@")
  }
  systemctl() { :; }
  log() {
    logged+="${1}"$'\n'
  }
  log_step() {
    logged+="STEP:${1}"$'\n'
  }

  warp_teardown_legacy

  [[ " ${stopped[*]} " == *" xtun-warp-health.timer "* ]]
  [[ " ${stopped[*]} " == *" xtun-warp-health.service "* ]]
  [[ " ${stopped[*]} " == *" warp-svc.service "* ]]
  [[ "${removed[*]}" == "${workdir}/mdm.xml" ]]
  printf '%s' "${logged}" | grep -q 'STEP:清理旧版 WARP Team 托管文件。'
  printf '%s' "${logged}" | grep -q 'apt-get purge -y cloudflare-warp'

  rm -f "${workdir}/mdm.xml"
  stopped=()
  removed=()
  logged=""
  warp_teardown_legacy
  [[ "${#removed[@]}" -eq 0 ]]
  [[ -z "${logged}" ]]
  load_functions
}

run_render_output_file_qr_case() {
  local workdir=""
  local output=""
  local call_log=""

  workdir="$(mktemp -d)"
  OUTPUT_FILE="${workdir}/output.md"
  cat > "${OUTPUT_FILE}" <<'EOF'
vless://11111111-1111-1111-1111-111111111111@203.0.113.30:443?security=reality#HKG-A
vless://22222222-2222-2222-2222-222222222222@203.0.113.30:443?security=reality#HKG-B
其他文本行
EOF

  call_log="${workdir}/qr-calls.log"
  have_qrencode() { return 0; }
  qrencode() {
    cat >/dev/null
    printf 'qrencode:%s\n' "${2}" >> "${call_log}"
    printf 'ANSI-QR'
  }

  output="$(render_output_file_qr 2>&1)"

  printf '%s' "${output}" | grep -q '节点 1: HKG-A'
  printf '%s' "${output}" | grep -q '节点 2: HKG-B'
  [[ "$(grep -c 'qrencode:' "${call_log}")" -eq 2 ]]

  # 缺 qrencode：只告警，不画
  load_functions
  OUTPUT_FILE="${workdir}/output.md"
  have_qrencode() { return 1; }
  local status=0
  output="$(render_output_file_qr 2>&1)" || status=$?
  [[ "${status}" == 1 ]]
  printf '%s' "${output}" | grep -q 'qrencode'

  load_functions
}
