# shellcheck shell=bash

run_change_helper_case() {
  local original_prompt=""
  local workdir=""
  local -A uuid_request=()
  local -A warp_request=()
  local -A cert_request=()

  workdir="$(mktemp -d)"
  printf '%s\n' "${TEST_WARP_PRIVATE_KEY}" > "${workdir}/warp-private-key.txt"
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
    --warp-private-key "@${workdir}/warp-private-key.txt" \
    --warp-address-v4 172.16.0.2 \
    --warp-address-v6 2606:4700:110:8a1b:cafe:1:2:3 \
    --warp-reserved '[1, 2, 3]' \
    --warp-endpoint engage.cloudflareclient.com:2408 \
    --warp-mtu 1280
  WARP_PRIVATE_KEY="${warp_request[warp_private_key]}"
  resolve_install_input_sources
  [[ "${NON_INTERACTIVE}" -eq 1 ]]
  [[ "${warp_request[target_mode]}" == "enable" ]]
  [[ "${WARP_PRIVATE_KEY}" == "${TEST_WARP_PRIVATE_KEY}" ]]
  [[ "${warp_request[warp_address_v4]}" == "172.16.0.2" ]]
  [[ "${warp_request[warp_address_v6]}" == "2606:4700:110:8a1b:cafe:1:2:3" ]]
  [[ "${warp_request[warp_reserved]}" == "[1, 2, 3]" ]]
  [[ "${warp_request[warp_endpoint]}" == "engage.cloudflareclient.com:2408" ]]
  [[ "${warp_request[warp_mtu]}" == "1280" ]]
  [[ "$(normalize_warp_reserved_value "${warp_request[warp_reserved]}")" == "1,2,3" ]]

  NON_INTERACTIVE=0
  init_change_cert_mode_request cert_request
  parse_change_cert_mode_args cert_request \
    --non-interactive \
    --cert-mode existing \
    --xhttp-domain cdn.example.com \
    --cert-file /tmp/cert.pem \
    --key-file /tmp/key.pem \
    --acme-email ops@example.com
  [[ "${NON_INTERACTIVE}" -eq 1 ]]
  [[ "${cert_request[cert_mode_overridden]}" == "1" ]]
  [[ "${cert_request[xhttp_domain_overridden]}" == "1" ]]
  [[ "${cert_request[cert_mode]}" == "existing" ]]
  [[ "${cert_request[xhttp_domain]}" == "cdn.example.com" ]]
  [[ "${cert_request[cert_source_file]}" == "/tmp/cert.pem" ]]
  [[ "${cert_request[key_source_file]}" == "/tmp/key.pem" ]]
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
  apply_request_overrides cert_request "cf_dns_account_id|CF_DNS_ACCOUNT_ID"
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
  # 菜单序号 3 现在是 existing（cf-origin-ca 并入 existing）
  [[ "${CERT_MODE}" == "existing" ]]
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
  local shown_links_args=""
  local rules_written=""
  local backup_sessions=0
  local stdout_file=""

  stdout_file="$(mktemp)"

  need_root() { :; }
  start_backup_session() {
    backup_sessions=$((backup_sessions + 1))
    BACKUP_DIR="/tmp/change-backup"
  }
  load_current_install_context() {
    REALITY_SNI="old.example.com"
    REALITY_TARGET="www.harvard.edu:443"
    XHTTP_PATH="/old"
    NODE_LABEL_PREFIX="HKG"
    CERT_MODE="existing"
    XHTTP_DOMAIN="cdn.old.example.com"
    ENABLE_WARP="no"
    WARP_RULES_TEXT=$'geosite:google\ndomain:github.com'
  }
  ensure_xray_user() { :; }
  preflight_check_reality_sni() { :; }
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
    shown_links_args+="${*} "
  }
  log() { :; }
  log_step() { :; }
  log_success() { :; }

  NON_INTERACTIVE=0
  change_sni_cmd --non-interactive --reality-sni new.example.com
  [[ "${runtime_updated}" -eq 1 ]]
  [[ "${runtime_sni}" == "new.example.com" ]]
  # 改 SNI 时目标跟着换（0.11 只改 SNI 不改 target 是隐性缺陷）
  [[ "${runtime_target}" == "new.example.com:443" ]]
  [[ "${shown_links}" -eq 1 ]]
  [[ "${shown_links_args}" == "--summary " ]]

  # --opt=value 与 --opt value 必须等价
  runtime_sni=""
  NON_INTERACTIVE=0
  change_sni_cmd --non-interactive --reality-sni=eq.example.com
  [[ "${runtime_sni}" == "eq.example.com" ]]
  [[ "${shown_links}" -eq 2 ]]

  NON_INTERACTIVE=0

  load_current_install_context() {
    REALITY_SNI="old.example.com"
    REALITY_TARGET="www.harvard.edu:443"
    XHTTP_PATH="/old"
    NODE_LABEL_PREFIX="HKG"
    CERT_MODE="existing"
    XHTTP_DOMAIN="cdn.old.example.com"
    ENABLE_WARP="no"
    WARP_RULES_TEXT=$'geosite:google\ndomain:github.com'
  }

  NON_INTERACTIVE=0
  backup_sessions=0
  # 不能用 $(...) 收 stdout：那会把命令放进子 shell，计数器全传不回来
  change_warp_rules_cmd --non-interactive --add-domain chat.openai.com --del-domain github.com > "${stdout_file}"
  output="$(cat "${stdout_file}")"
  [[ "${runtime_updated}" -eq 1 ]]
  [[ "${backup_sessions}" -eq 1 ]]
  [[ "${rules_written}" == *$'domain:chat.openai.com'* ]]
  [[ "${rules_written}" != *$'domain:github.com'* ]]
  # 分流规则改的是服务端出站，客户端链接一个字都不会变，不该再喷一份部署文档
  [[ "${shown_links}" -eq 2 ]]
  [[ "${output}" == *"domain:chat.openai.com"* ]]

  # 规则没有实际变化时不能重启服务，也不该开备份会话挤掉真正的变更备份
  load_current_install_context() {
    REALITY_SNI="old.example.com"
    REALITY_TARGET="www.harvard.edu:443"
    XHTTP_PATH="/old"
    NODE_LABEL_PREFIX="HKG"
    CERT_MODE="existing"
    XHTTP_DOMAIN="cdn.old.example.com"
    ENABLE_WARP="no"
    WARP_RULES_TEXT=$'geosite:google\ndomain:chat.openai.com'
  }
  runtime_updated=0
  backup_sessions=0
  NON_INTERACTIVE=0
  change_warp_rules_cmd --non-interactive --add-domain chat.openai.com > "${stdout_file}"
  output="$(cat "${stdout_file}")"
  [[ "${runtime_updated}" -eq 0 ]]
  [[ "${backup_sessions}" -eq 0 ]]
  [[ "${shown_links}" -eq 2 ]]
  [[ "${output}" == *"domain:chat.openai.com"* ]]

  load_existing_state() {
    WARP_RULES_TEXT=$'geosite:google\ndomain:chat.openai.com'
  }
  runtime_updated=0
  shown_links=0
  change_warp_rules_cmd --list > "${stdout_file}"
  output="$(cat "${stdout_file}")"
  [[ "${runtime_updated}" -eq 0 ]]
  [[ "${shown_links}" -eq 0 ]]
  [[ "${output}" == *"domain:chat.openai.com"* ]]

  rm -f "${stdout_file}"
}

run_change_warp_enable_rollback_case() {
  local rolled_back=0
  local applied=0
  local status=0
  local NON_INTERACTIVE=1

  parse_change_warp_args() {
    local -n request_ref="${1}"
    request_ref[target_mode]="enable"
  }
  ensure_debian_family() { :; }
  need_root() { :; }
  load_current_install_context() { ENABLE_WARP="no"; }
  open_change_session() { :; }
  apply_warp_change_request() { :; }
  prompt_warp_settings() { :; }
  apply_managed_runtime_update() {
    applied=$((applied + 1))
    return 1
  }
  rollback_optional_component_state() {
    rolled_back=$((rolled_back + 1))
  }

  set +e
  change_warp_cmd --enable-warp --non-interactive >/dev/null 2>&1
  status=$?
  set -e

  [[ "${status}" -ne 0 ]]
  [[ "${applied}" -eq 1 ]]
  # 托管应用已经负责同代回退，旧 helper 不能再停掉既有网络优化服务。
  [[ "${rolled_back}" -eq 0 ]]
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
  }
  ensure_xray_user() { :; }
  apply_certificate_only_update() {
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
  [[ "${shown_links}" -eq 0 ]]
  printf '%s' "${logged}" | grep -q 'STEP:刷新 TLS 证书资产。'
  printf '%s' "${logged}" | grep -q 'OK:证书刷新完成，已验证 nginx 实际供证。'
}

# renew-cert 是 acme.sh 的 cron 自动跑的：这里报「已续期」没人会去核对，
# 于是一张过期证书能一路服务到用户连不上为止，才有人发现续期其实早就失败了。
run_renew_cert_failure_case() {
  local status=0
  local logged=""
  local shown_links=0
  local workdir=""

  workdir="$(mktemp -d)"
  printf 'dns-token\n' > "${workdir}/cf-dns-token.txt"

  need_root() { :; }
  start_backup_session() { BACKUP_DIR="/tmp/renew-backup"; }
  load_current_install_context() {
    CERT_MODE="acme-dns-cf"
    XHTTP_DOMAIN="cdn.old.example.com"
  }
  ensure_xray_user() { :; }
  resolve_install_input_sources() { :; }
  prompt_cert_mode_inputs() { :; }
  validate_install_inputs() { :; }
  apply_certificate_only_update() { return 1; }
  show_links() { shown_links=$((shown_links + 1)); }
  log() { logged+="${1}"$'\n'; }
  log_step() { logged+="STEP:${1}"$'\n'; }
  log_success() { logged+="OK:${1}"$'\n'; }

  set +e
  renew_cert_cmd --non-interactive --acme-email ops@example.com --cf-dns-token "@${workdir}/cf-dns-token.txt"
  status=$?
  set -e

  [[ "${status}" -ne 0 ]]
  [[ "${shown_links}" -eq 0 ]]
  [[ "${logged}" != *"OK:证书刷新完成，已验证 nginx 实际供证。"* ]]

  rm -rf "${workdir}"
  load_functions
}

# 换证书失败后如果不停下来，cleanup_previous_acme_cert 会把旧域名从 acme.sh 里摘掉：
# 回滚回来、还在服务的那张证书从此不再自动续期——一颗带到期日的定时炸弹。
run_change_cert_mode_failure_case() {
  local status=0
  local cleanup_calls=0
  local logged=""
  local shown_links=0

  need_root() { :; }
  start_backup_session() { BACKUP_DIR="/tmp/cert-backup"; }
  load_current_install_context() {
    CERT_MODE="acme-dns-cf"
    XHTTP_DOMAIN="cdn.old.example.com"
  }
  ensure_xray_user() { :; }
  prompt_cert_mode_inputs() { :; }
  validate_install_inputs() { :; }
  apply_certificate_only_update() { return 1; }
  cleanup_previous_acme_cert() { cleanup_calls=$((cleanup_calls + 1)); }
  show_links() { shown_links=$((shown_links + 1)); }
  log() { logged+="${1}"$'\n'; }
  log_step() { logged+="STEP:${1}"$'\n'; }
  log_success() { logged+="OK:${1}"$'\n'; }

  set +e
  # 明确切成 self-signed：这正是成功路径上 cleanup_previous_acme_cert 一定会开火的场景。
  change_cert_mode_cmd --non-interactive \
    --cert-mode self-signed \
    --xhttp-domain cdn.old.example.com </dev/null
  status=$?
  set -e

  [[ "${status}" -ne 0 ]]
  # 这条是这批里最贵的断言：还在服务的那张证书，注册绝不能被摘。
  [[ "${cleanup_calls}" -eq 0 ]]
  [[ "${shown_links}" -eq 0 ]]
  [[ "${logged}" != *"OK:证书模式已更新。"* ]]

  load_functions
}

run_upgrade_command_case() {
  local workdir=""
  local logged=""
  local systemctl_calls=""
  local status=0

  # 这条用例要跑真实的 start_backup_session / backup_path：快照 + manifest
  # 就是同代回退唯一的证据来源（D11），不能换成空操作。
  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"
  BACKUP_ROOT="${workdir}/backups"
  XRAY_BIN="${workdir}/xray-core"
  XRAY_ASSET_DIR="${workdir}/xray-assets"
  printf '#!/usr/bin/env bash\n' > "${XRAY_BIN}"
  chmod 0755 "${XRAY_BIN}"
  mkdir -p "${XRAY_ASSET_DIR}"
  printf 'old-geoip\n' > "${XRAY_ASSET_DIR}/geoip.dat"

  need_root() { :; }
  ensure_debian_family() { :; }
  xray_ensure_release_context() { XRAY_SELECTED_TAG=v26.9.9; }
  install_xray() {
    printf 'new-core\n' > "${XRAY_BIN}"
    printf 'new-geoip\n' > "${XRAY_ASSET_DIR}/geoip.dat"
  }
  ensure_xray_bind_capability() { :; }
  validate_configs() { return 1; }
  systemctl() { systemctl_calls+="$*"$'\n'; generation_mock_systemctl "$@"; }
  log() { logged+="${1}"$'\n'; }
  log_step() { logged+="STEP:${1}"$'\n'; }
  log_success() { logged+="OK:${1}"$'\n'; }
  warn() { logged+="WARN:${1}"$'\n'; }

  set +e
  upgrade_cmd --non-interactive
  status=$?
  set -e

  [[ "${status}" -ne 0 ]]
  # 校验失败：核心文件与资源目录都回到升级前，xray 一次都没重启。
  [[ "$(cat "${XRAY_BIN}")" == '#!/usr/bin/env bash' ]]
  [[ "$(cat "${XRAY_ASSET_DIR}/geoip.dat")" == "old-geoip" ]]
  # 回退本身要做一次 daemon-reload（还原的 unit 文件才作数），那不是重启；
  # 这里按「动作」断言而不是按 systemctl 被调用的次数。
  [[ "${systemctl_calls}" != *"restart"* ]]
  [[ -n "${BACKUP_DIR}" && -f "${BACKUP_DIR}/manifest.tsv" ]]
  # 不用 printf | grep -q：grep 命中就退出，printf 还在写就吃 SIGPIPE，pipefail 下
  # 整条用例以 141 挂掉（2026-09-22 真机 smoke 复现一次）。
  grep -q 'STEP:升级 Xray 核心。' <<< "${logged}"
  grep -q 'WARN:升级后的配置校验失败' <<< "${logged}"
  grep -q '已回退到操作前的文件' <<< "${logged}"
  # 失败的动作不允许消耗备份保留名额：成功标记不该落下。
  [[ ! -e "${BACKUP_DIR}/completed" ]]

  load_functions
}

run_diagnose_command_case() {
  local output=""
  local status=0
  local probe_file=""
  local counts_file=""
  local state_file=""
  local state_before=""
  local state_after=""

  probe_file="$(mktemp)"
  counts_file="$(mktemp)"
  printf '0' > "${probe_file}"
  : > "${counts_file}"

  count_call() {
    printf '%s\n' "${1}" >> "${counts_file}"
  }

  load_dashboard_context() { :; }
  service_active_state() {
    case "${1}" in
      xray.service|haproxy.service|nginx.service)
        printf 'active'
        ;;
      *)
        printf 'unknown'
        ;;
    esac
  }
  # 一次采集：每个慢探测/端口只允许被问一次，展示与判定复用同一份结果（H21）。
  port_listening_snapshot() {
    count_call "port:${1}"
    printf 'listening|TCP 运行中 (*:%s · test)' "${1}"
  }
  xray_config_check_state() { count_call "xray-config"; printf 'ok'; }
  nginx_config_check_state() { count_call "nginx-config"; printf 'ok'; }
  haproxy_config_check_state() { count_call "haproxy-config"; printf 'ok'; }
  local_tls_probe_state() { count_call "tls"; printf 'ok'; }
  quic_port_state() { count_call "quic"; printf 'ok'; }
  # 诊断不允许借机写 state 或执行 repair/apply。
  begin_mutation() { count_call "begin-mutation"; }
  write_state_kv() { count_call "write-state"; }
  write_state_file() { count_call "write-state-file"; }
  xray_config_check_text() { printf '通过'; }
  nginx_config_check_text() { printf '通过'; }
  nginx_worker_connections_text() { printf '768（偏低）'; }
  haproxy_config_check_text() { printf '通过'; }
  local_tls_probe_text() { printf '通过'; }
  cert_expiry_text() { printf 'Jun  1 00:00:00 2026 GMT'; }
  warp_endpoint_resolve_state() { printf 'ok'; }
  warp_endpoint_resolve_text() { printf '通过'; }
  warp_rule_count_text() { printf '4'; }
  config_has_warp_outbound() { return 0; }
  warp_egress_probe_text() {
    local count=0
    count="$(cat "${probe_file}" 2>/dev/null || printf '0')"
    printf '%s' "$((count + 1))" > "${probe_file}"
    printf '203.0.113.99'
  }
  health_event_text() { printf 'ok'; }
  latest_health_history_text() { printf 'latest history'; }

  ENABLE_WARP="yes"
  CERT_MODE="self-signed"
  set_test_warp_credentials

  state_file="${STATE_FILE:-}"
  state_file="$(mktemp)"
  STATE_FILE="${state_file}"
  printf 'STATE_VERSION=%s\n' "${STATE_VERSION_CURRENT}" > "${state_file}"
  state_before="$(cat "${state_file}")"

  output="$(diagnose_cmd)"
  printf '%s' "${output}" | grep -q 'Xray 诊断'
  printf '%s' "${output}" | grep -Fq '监听 443: TCP 运行中 (*:443 · test)'
  printf '%s' "${output}" | grep -Fq '监听 [::]:443: TCP 运行中'
  printf '%s' "${output}" | grep -q 'Nginx worker_connections: 768（偏低）'
  # 证书用途、本地探测、外部/客户端验证必须分开写（D09/H18）
  printf '%s' "${output}" | grep -q '证书用途: self-signed'
  printf '%s' "${output}" | grep -q '本地 TLS 探测: 通过（证书受系统信任）'
  printf '%s' "${output}" | grep -q '外部可达: 未验证'
  printf '%s' "${output}" | grep -q '客户端兼容: 未验证'
  # 只是提示，不该把 diagnose 判成失败。
  printf '%s' "${output}" | grep -q '诊断摘要: 未发现关键问题'
  printf '%s' "${output}" | grep -q 'WARP 出站: wireguard · 172.16.0.2'
  printf '%s' "${output}" | grep -q 'WARP 规则数: 4'
  if printf '%s' "${output}" | grep -q 'WARP 出口 IP'; then
    return 1
  fi
  [[ "$(cat "${probe_file}")" == "0" ]]

  [[ "$(grep -c '^port:443$' "${counts_file}")" -eq 1 ]]
  [[ "$(grep -c '^port:2443$' "${counts_file}")" -eq 1 ]]
  [[ "$(grep -c '^port:8001$' "${counts_file}")" -eq 1 ]]
  [[ "$(grep -c '^port:8443$' "${counts_file}")" -eq 1 ]]
  [[ "$(grep -c '^xray-config$' "${counts_file}")" -eq 1 ]]
  [[ "$(grep -c '^nginx-config$' "${counts_file}")" -eq 1 ]]
  [[ "$(grep -c '^haproxy-config$' "${counts_file}")" -eq 1 ]]
  [[ "$(grep -c '^tls$' "${counts_file}")" -eq 1 ]]
  [[ "$(grep -c '^quic$' "${counts_file}")" -eq 1 ]]

  # 诊断是只读动作：不写 state、不执行 repair/apply。
  state_after="$(cat "${state_file}")"
  [[ "${state_before}" == "${state_after}" ]]
  for item in begin-mutation write-state write-state-file; do
    [[ "$(grep -c "^${item}$" "${counts_file}")" -eq 0 ]]
  done

  output="$(diagnose_cmd --warp-probe)"
  printf '%s' "${output}" | grep -q 'WARP 出口 IP: 203.0.113.99'
  [[ "$(cat "${probe_file}")" == "1" ]]

  # 自签 / Origin CA：握手成功但证书不受系统信任是预期，不该判失败（H18）
  local_tls_probe_state() { printf 'untrusted'; }
  CERT_MODE="self-signed"
  output="$(diagnose_cmd 2>&1)"
  printf '%s' "${output}" | grep -q '握手成功，证书不受系统信任'
  printf '%s' "${output}" | grep -q '诊断摘要: 未发现关键问题'

  # 公网 CA 模式下不受信任才是故障
  CERT_MODE="acme-dns-cf"
  set +e
  output="$(diagnose_cmd 2>&1)"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  printf '%s' "${output}" | grep -q 'ACME 证书应受系统信任'
  CERT_MODE="self-signed"

  # 没装 ss：端口状态是「无法确认」，不能报成「未监听」这种确定结论
  local_tls_probe_state() { printf 'ok'; }
  port_listening_snapshot() { printf 'unknown|未探测（缺少 ss）'; }
  set +e
  output="$(diagnose_cmd 2>&1)"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  printf '%s' "${output}" | grep -q '443 无法确认（缺少 ss）'
  printf '%s' "${output}" | grep -Fq '监听 [::]:443: 无法确认（缺少 ss）'
  port_listening_snapshot() {
    count_call "port:${1}"
    printf 'listening|TCP 运行中 (*:%s · test)' "${1}"
  }

  # 只听 IPv4 时 IPv6 行不能报成「运行中」（H21/D09）
  port_listening_snapshot() {
    count_call "port:${1}"
    if [[ "${1}" == "443" ]]; then
      printf 'listening|TCP 运行中 (127.0.0.1:443 · test)'
      return 0
    fi
    printf 'listening|TCP 运行中 (*:%s · test)' "${1}"
  }
  output="$(diagnose_cmd 2>&1)"
  printf '%s' "${output}" | grep -Fq '监听 [::]:443: TCP 未监听（仅 IPv4）'
  port_listening_snapshot() {
    count_call "port:${1}"
    printf 'listening|TCP 运行中 (*:%s · test)' "${1}"
  }

  service_active_state() { printf 'failed'; }
  printf '0' > "${probe_file}"
  set +e
  output="$(diagnose_cmd 2>&1)"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  printf '%s' "${output}" | grep -q '诊断摘要: 检测到'
  printf '%s' "${output}" | grep -q '服务: xray 未运行'
  [[ "$(cat "${probe_file}")" == "0" ]]

  WARP_PRIVATE_KEY=""
  set +e
  output="$(diagnose_cmd 2>&1)"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  printf '%s' "${output}" | grep -q 'WARP: WARP WireGuard 私钥缺失'
}
