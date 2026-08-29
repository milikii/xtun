# shellcheck shell=bash

run_state_context_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"

  NGINX_CONF_DIR="${workdir}/nginx"
  NGINX_CONFIG_FILE="${NGINX_CONF_DIR}/xtun.conf"
  HEALTH_STATE_FILE="${workdir}/health-state.env"
  HEALTH_HISTORY_FILE="${workdir}/health-history.log"
  NET_SERVICE_FILE="${workdir}/net.service"
  NET_SYSCTL_CONF="${workdir}/net.conf"
  mkdir -p "${NGINX_CONF_DIR}"

  cat > "${XRAY_CONFIG_FILE}" <<'EOF'
{
  "inbounds": [
    {
      "tag": "reality-vision",
      "settings": {
        "clients": [
          {
            "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
          }
        ]
      },
      "streamSettings": {
        "realitySettings": {
          "serverNames": [
            "reality.example.com"
          ],
          "target": "www.scu.edu:443",
          "shortIds": [
            "abcd1234"
          ],
          "privateKey": "private-key-value"
        }
      }
    },
    {
      "tag": "xhttp-cdn",
      "settings": {
        "clients": [
          {
            "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
          }
        ],
        "decryption": "enc-value"
      },
      "streamSettings": {
        "xhttpSettings": {
          "path": "/assets/v3"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "WARP",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "eHR1bi10ZXN0LXdhcnAtcHJpdmF0ZS1rZXktMzJieXQ=",
        "address": [
          "172.16.0.2/32",
          "2606:4700:110:8a1b:cafe:1:2:3/128"
        ],
        "peers": [
          {
            "publicKey": "eHR1bi10ZXN0LXdhcnAtcGVlci1wdWJsaWMta2V5LTM=",
            "allowedIPs": [
              "0.0.0.0/0",
              "::/0"
            ],
            "endpoint": "engage.cloudflareclient.com:2408"
          }
        ],
        "reserved": [
          3,
          4,
          5
        ],
        "mtu": 1280,
        "domainStrategy": "ForceIPv4v6"
      }
    }
  ]
}
EOF

  cat > "${NGINX_CONFIG_FILE}" <<'EOF'
server {
    listen 127.0.0.1:8443 ssl;
    server_name cdn.example.com;

    location /assets/v3 {
        grpc_pass 127.0.0.1:8001;
    }
}
EOF

  cat > "${STATE_FILE}" <<'EOF'
STATE_VERSION='1'
CERT_MODE='existing'
ACME_CA='letsencrypt'
XHTTP_ECH_CONFIG_LIST='https://1.1.1.1/dns-query'
XHTTP_ECH_FORCE_QUERY='none'
EOF

  cat > "${OUTPUT_FILE}" <<'EOF'
- 地址: 203.0.113.20
- 节点名前缀: HKG
- 公钥: public-key-value
- 指纹: firefox
EOF

  cat > "${HEALTH_STATE_FILE}" <<'EOF'
CORE_HEALTH_LAST_CHECK_AT='2026-04-21T12:00:00Z'
CORE_HEALTH_LAST_ACTION='ok'
CORE_HEALTH_LAST_REASON='services healthy'
EOF

  cat > "${HEALTH_HISTORY_FILE}" <<'EOF'
2026-04-21T12:00:00Z | core | ok | services healthy
2026-04-21T12:10:00Z | core | restarted | service inactive
EOF

  REALITY_UUID="" REALITY_SNI="" REALITY_TARGET="" REALITY_SHORT_ID="" REALITY_PRIVATE_KEY="" \
  REALITY_PUBLIC_KEY="" XHTTP_UUID="" XHTTP_DOMAIN="" XHTTP_PATH="" XHTTP_VLESS_DECRYPTION="" \
  XHTTP_VLESS_ENCRYPTION_ENABLED="" TLS_ALPN="" SERVER_IP="" NODE_LABEL_PREFIX="" FINGERPRINT="" \
  ENABLE_WARP="" ENABLE_NET_OPT="" WARP_PRIVATE_KEY="" WARP_ADDRESS_V4="" WARP_ADDRESS_V6="" \
  WARP_PEER_PUBLIC_KEY="" WARP_ENDPOINT="" WARP_RESERVED="" WARP_MTU="" \
  CERT_MODE="" ACME_CA="" XHTTP_ECH_CONFIG_LIST="" XHTTP_ECH_FORCE_QUERY="" \
  XHTTP_XPADDING_ENABLED="" XHTTP_XPADDING_KEY="" XHTTP_XPADDING_HEADER="" XHTTP_XPADDING_PLACEMENT="" \
  XHTTP_XPADDING_METHOD=""

  load_dashboard_context
  [[ "${REALITY_UUID}" == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" ]]
  [[ "${XHTTP_DOMAIN}" == "cdn.example.com" ]]
  [[ "${SERVER_IP}" == "203.0.113.20" ]]
  [[ "${NODE_LABEL_PREFIX}" == "HKG" ]]
  [[ "${REALITY_PUBLIC_KEY}" == "public-key-value" ]]
  [[ "${FINGERPRINT}" == "firefox" ]]
  [[ "${ENABLE_WARP}" == "yes" ]]
  [[ "${WARP_PRIVATE_KEY}" == "${TEST_WARP_PRIVATE_KEY}" ]]
  [[ "${WARP_ADDRESS_V4}" == "172.16.0.2" ]]
  [[ "${WARP_ADDRESS_V6}" == "2606:4700:110:8a1b:cafe:1:2:3" ]]
  [[ "${WARP_PEER_PUBLIC_KEY}" == "${TEST_WARP_PEER_PUBLIC_KEY}" ]]
  [[ "${WARP_ENDPOINT}" == "engage.cloudflareclient.com:2408" ]]
  [[ "${WARP_RESERVED}" == "3,4,5" ]]
  [[ "${WARP_MTU}" == "1280" ]]
  [[ "${XHTTP_VLESS_ENCRYPTION_ENABLED}" == "yes" ]]
  [[ "${ENABLE_NET_OPT}" == "no" ]]
  [[ -z "${XHTTP_ECH_CONFIG_LIST}" ]]
  [[ -z "${XHTTP_ECH_FORCE_QUERY}" ]]
  [[ "${XHTTP_XPADDING_ENABLED}" == "no" ]]
  [[ "${XHTTP_XPADDING_KEY}" == "x_padding" ]]
  [[ "${CORE_HEALTH_LAST_ACTION}" == "ok" ]]
  [[ "$(latest_health_history_text)" == "2026-04-21T12:10:00Z | core | restarted | service inactive" ]]
  HEALTH_HISTORY_NOW='2026-04-21T12:30:00Z'
  [[ "$(health_history_count_text 1 core)" == "1" ]]
  [[ "$(health_history_count_text 24 core)" == "1" ]]
  [[ "$(stability_signal_text)" == *"稳定"* ]]

  REALITY_UUID="" REALITY_SNI="" REALITY_TARGET="" REALITY_SHORT_ID="" REALITY_PRIVATE_KEY="" \
  REALITY_PUBLIC_KEY="" XHTTP_UUID="" XHTTP_DOMAIN="" XHTTP_PATH="" XHTTP_VLESS_DECRYPTION="" \
  XHTTP_VLESS_ENCRYPTION_ENABLED="" TLS_ALPN="" SERVER_IP="" NODE_LABEL_PREFIX="" FINGERPRINT="" \
  ENABLE_WARP="" ENABLE_NET_OPT="" WARP_PRIVATE_KEY="" WARP_ADDRESS_V4="" WARP_ADDRESS_V6="" \
  WARP_PEER_PUBLIC_KEY="" WARP_ENDPOINT="" WARP_RESERVED="" WARP_MTU="" \
  CERT_MODE="" ACME_CA="" XHTTP_ECH_CONFIG_LIST="" XHTTP_ECH_FORCE_QUERY="" \
  XHTTP_XPADDING_ENABLED="" XHTTP_XPADDING_KEY="" XHTTP_XPADDING_HEADER="" XHTTP_XPADDING_PLACEMENT="" \
  XHTTP_XPADDING_METHOD=""

  load_current_install_context
  [[ "${REALITY_PRIVATE_KEY}" == "private-key-value" ]]
  [[ "${TLS_ALPN}" == "h2" ]]
  [[ "${CERT_MODE}" == "existing" ]]
  [[ "${ACME_CA}" == "letsencrypt" ]]
}

run_state_version_case() {
  local workdir=""
  local warned=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  cat > "${STATE_FILE}" <<'EOF'
STATE_VERSION='0'
TLS_ALPN='h2'
EOF

  warn() {
    warned+="${1}"$'\n'
  }

  load_existing_state
  [[ "${TLS_ALPN}" == "h2" ]]
  printf '%s' "${warned}" | grep -q '旧版本状态文件'
}

run_health_history_count_without_python_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  HEALTH_HISTORY_FILE="${workdir}/health-history.log"
  cat > "${HEALTH_HISTORY_FILE}" <<'EOF'
2026-04-21T12:00:00Z | core | ok | services healthy
2026-04-21T12:10:00Z | core | restarted | service inactive
2026-04-21T12:05:00Z | warp | restarted | warp probe failed
EOF

  python3() {
    return 99
  }

  HEALTH_HISTORY_NOW='2026-04-21T12:30:00Z'
  [[ "$(health_history_count_text 1 core)" == "1" ]]
  [[ "$(health_history_count_text 1 warp)" == "1" ]]
  [[ "$(health_history_count_text 24 core)" == "1" ]]
  unset -f python3
}

run_state_file_decode_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
cat > "${STATE_FILE}" <<'EOF'
STATE_VERSION=1
CF_API_TOKEN=tok\'en\ 0\ \[\]
XHTTP_ECH_CONFIG_LIST=$'line1\nline2'
WARP_RULES_TEXT=$'geosite:google\ndomain:github.com'
NODE_CLIENTS_TEXT=$'tab\tbackslash\\done'
EOF

  load_existing_state
  [[ "${CF_API_TOKEN}" == "tok'en 0 []" ]]
  [[ "${XHTTP_ECH_CONFIG_LIST}" == $'line1\nline2' ]]
  [[ "${WARP_RULES_TEXT}" == $'geosite:google\ndomain:github.com' ]]
  [[ "${NODE_CLIENTS_TEXT}" == $'tab\tbackslash\\done' ]]
}

run_node_client_state_case() {
  local duplicate_output=""
  local workdir=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults

  SERVER_IP="203.0.113.50"
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
  NODE_CLIENTS_TEXT=$'phone|33333333-3333-3333-3333-333333333333|44444444-4444-4444-4444-444444444444\nlaptop|55555555-5555-5555-5555-555555555555|66666666-6666-6666-6666-666666666666'

  write_state_file
  bash -n "${STATE_FILE}"

  NODE_CLIENTS_TEXT=""
  load_existing_state
  [[ "$(node_client_count)" == "3" ]]
  [[ "$(node_client_names_csv)" == "default, phone, laptop" ]]
  [[ "$(node_client_record_for_name phone)" == "phone|33333333-3333-3333-3333-333333333333|44444444-4444-4444-4444-444444444444" ]]

  append_node_client_record tablet "77777777-7777-7777-7777-777777777777" "88888888-8888-8888-8888-888888888888"
  [[ "$(node_client_count)" == "4" ]]
  node_client_exists tablet

  if duplicate_output="$(append_node_client_record duplicate-reality "11111111-1111-1111-1111-111111111111" "99999999-9999-9999-9999-999999999999" 2>&1)"; then
    return 1
  fi
  [[ "${duplicate_output}" == *"REALITY UUID 已被客户端 default 使用。"* ]]

  if duplicate_output="$(append_node_client_record duplicate-xhttp "99999999-9999-9999-9999-999999999999" "44444444-4444-4444-4444-444444444444" 2>&1)"; then
    return 1
  fi
  [[ "${duplicate_output}" == *"XHTTP UUID 已被客户端 phone 使用。"* ]]
}

run_runtime_context_reset_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  WARP_RULES_FILE="${workdir}/missing-rules.list"
  HEALTH_STATE_FILE="${workdir}/missing-health.env"

  REALITY_UUID="stale-reality"
  XHTTP_DOMAIN="stale.example.com"
  ENABLE_WARP="yes"
  WARP_RULES_TEXT="domain:stale.example.com"
  CORE_HEALTH_LAST_ACTION="restarted"

  load_dashboard_context
  [[ -z "${REALITY_UUID}" ]]
  [[ -z "${XHTTP_DOMAIN}" ]]
  [[ -z "${ENABLE_WARP}" ]]
  [[ -z "${WARP_RULES_TEXT}" ]]
  [[ -z "${CORE_HEALTH_LAST_ACTION}" ]]
  [[ "$(warp_rule_count_text)" == "0" ]]
}

run_backup_path_without_session_case() {
  local output=""

  if ! output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
workdir="\$(mktemp -d)"
printf 'old\n' > "\${workdir}/managed.txt"
unset BACKUP_DIR
backup_path "\${workdir}/managed.txt"
cat "\${workdir}/managed.txt"
EOF
)"; then
    return 1
  fi

  [[ "${output}" == "old" ]]
}

run_begin_managed_change_resolves_xray_user_case() {
  local ensure_calls=0

  need_root() { :; }
  start_backup_session() { :; }
  log_step() { :; }
  load_current_install_context() { :; }
  ensure_xray_user() {
    ensure_calls=$((ensure_calls + 1))
    XRAY_UID="123"
    XRAY_GID="456"
  }

  XRAY_UID=""
  XRAY_GID=""
  begin_managed_change

  [[ "${ensure_calls}" -eq 1 ]]
  [[ "${XRAY_UID}" == "123" ]]
  [[ "${XRAY_GID}" == "456" ]]
}

# 这几个函数都在 `if ! xxx; then 回滚; fi` 里被调用，而 `if !` 会关掉整条调用链上的
# set -e。少一个显式 `|| return 1`，前一步失败后函数会继续跑到 log_success 并返回 0，
# 于是「校验没过 / 服务没起来」被当成成功，回滚永远不触发。这里正是钉住那条路径。
run_service_failure_propagation_case() {
  local status=0

  log_step() { :; }
  log_success() { :; }
  ensure_xray_user() { :; }
  ensure_managed_permissions() { :; }

  # xray 配置校验失败，后面两个校验通过：整体必须仍是失败。
  validate_xray_config() { return 1; }
  nginx() { return 0; }
  haproxy() { return 0; }
  status=0
  validate_configs || status=$?
  [[ "${status}" -ne 0 ]]

  # 反过来：xray 过了、nginx -t 挂了，也不能被后面的 haproxy 覆盖成成功。
  validate_xray_config() { return 0; }
  nginx() { return 1; }
  status=0
  validate_configs || status=$?
  [[ "${status}" -ne 0 ]]

  # 重启路径同理：xray 起不来时不能被后面 haproxy/nginx 的成功盖掉。
  systemctl() {
    case "${1:-}" in
      restart)
        [[ "${2:-}" == "xray" ]] && return 1
        return 0
        ;;
      is-active)
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  }
  status=0
  restart_core_services || status=$?
  [[ "${status}" -ne 0 ]]

  # nginx reload 失败同样要冒出来。
  systemctl() {
    case "${1:-}" in
      reload)
        [[ "${2:-}" == "nginx" ]] && return 1
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  }
  NGINX_RESTART_REQUIRED="no"
  status=0
  restart_core_services || status=$?
  [[ "${status}" -ne 0 ]]

  load_functions
}

# 安装路径上是同一个坑：install_* 也都是在 `if ! xxx; then 回滚; fi` 里调用的。
# 里面每一步失败都必须冒出来，否则装到一半的机器会被当成装好了。
run_install_step_failure_propagation_case() {
  local status=0

  log_step() { :; }
  log_success() { :; }
  log() { :; }
  backup_path() { :; }

  # apt-get 挂了之后不能接着去装 xray，更不能因为后面几步成功就报成功。
  install_packages() { return 1; }
  install_self_command() { return 1; }
  install_xray() { return 1; }
  ensure_xray_bind_capability() { :; }
  ensure_xray_user() { :; }
  generate_reality_keys_if_needed() { :; }
  status=0
  install_xray_runtime || status=$?
  [[ "${status}" -ne 0 ]]

  # 只有中间一步挂：后面几步的成功不能把它盖掉。
  install_packages() { :; }
  install_self_command() { :; }
  install_xray() { return 1; }
  status=0
  install_xray_runtime || status=$?
  [[ "${status}" -ne 0 ]]

  # 写托管文件同理：证书写挂了就不该继续写后面的 unit。
  # 这里不去桩 write_runtime_managed_files：它自己那六步的传递性下面还要接着验。
  write_tls_assets() { return 1; }
  deploy_fallback_site() { :; }
  write_warp_rules_file() { :; }
  write_xray_config() { :; }
  write_haproxy_config() { :; }
  write_nginx_config() { :; }
  write_nginx_limits_dropin() { :; }
  write_xray_service() { :; }
  write_core_health_monitor() { :; }
  write_xray_logrotate_config() { :; }
  status=0
  write_install_managed_files || status=$?
  [[ "${status}" -ne 0 ]]

  # 网络优化是这组里最容易被吞的一个：它后面没有任何校验会兜住。
  install_network_optimization() { return 1; }
  warp_teardown_legacy() { :; }
  status=0
  install_optional_components || status=$?
  [[ "${status}" -ne 0 ]]

  # 托管文件是分别落盘的，写到一半失败要回滚，不能留半新半旧。
  local rollback_calls=0
  write_tls_assets() { :; }
  write_xray_config() { return 1; }
  validate_configs() { :; }
  restart_core_services() { :; }
  write_state_file() { :; }
  write_output_file() { :; }
  rollback_managed_runtime_state() { rollback_calls=$((rollback_calls + 1)); }
  status=0
  apply_managed_files "no" || status=$?
  [[ "${status}" -ne 0 ]]
  [[ "${rollback_calls}" -eq 1 ]]

  load_functions
}

# errexit 在这个脚本里是不生效的，而且不是疏忽：
#   lib/cli/core.sh 的 `dispatch_cli_command ... || status=$?`（CLI 入口）
#   lib/cli/core.sh 的 `run_menu_choice ... || true`（菜单入口，必须保留）
# 这两个 `||` 各自把整条动态调用链上的 set -e 豁免掉，一路穿透到最底层。
# 子 shell 和重新 set -e 都救不回来（bash 5.2 实测），所以「每一步是否把失败传出来」
# 只能靠显式的 `|| return 1`——它不是 errexit 的替代品，它就是这里唯一的机制。
# 这条用例把「必须传出失败」的步骤列出来，钉住它们在源码里的每个调用点都带守卫。
# 新加一行没写 `|| return 1` 的调用，这里就会红。
#
# 名单有两个来源，取并集：
#   1. errexit_returning_step_names —— 自动扫源码，函数体里出现 `return <非 0>` 的
#      都算「会把失败传出来的动作」。新写的函数不用手工登记就自动被钉住。
#   2. errexit_guarded_step_names —— 显式清单，只能往里加不能删。有些函数不写字面
#      return（靠最后一条命令或 die 传状态），自动扫描看不见，得手工兜住。
# 并集只会让 lint 变严：自动那半边漏了，显式清单还在；显式清单忘了登记，自动那半边补上。

# 自动检测：函数体里出现 `return 1` / `|| return 2` 这类字面非 0 返回的，
# 就是一个会失败、且把失败传出来的动作函数，它的调用点必须带守卫。
errexit_returning_step_names() {
  cd "${ROOT_DIR}" && find xtun.sh lib -name '*.sh' -type f -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 awk '
      /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{[[:space:]]*$/ {
        fn = $0
        sub(/\(\).*$/, "", fn)
        returns_failure = 0
        next
      }
      /^\}[[:space:]]*$/ {
        if (fn != "" && returns_failure) {
          print fn
        }
        fn = ""
        next
      }
      fn != "" && /(^|[^a-zA-Z0-9_])return[[:space:]]+[1-9]/ { returns_failure = 1 }
    '
}

errexit_guarded_step_names() {
  printf '%s\n' \
    install_packages install_self_command install_xray ensure_xray_bind_capability \
    generate_reality_keys_if_needed write_tls_assets write_runtime_managed_files \
    write_xray_service write_core_health_monitor write_core_health_helper \
    write_core_health_service write_core_health_timer write_xray_logrotate_config \
    install_network_optimization deploy_fallback_site write_warp_rules_file \
    write_xray_config write_haproxy_config write_nginx_config write_nginx_limits_dropin \
    write_generated_file_atomically ensure_warp_credentials \
    generate_xhttp_vless_encryption_if_needed backup_path install_bundle_root_to_self \
    validate_tls_assets_with_paths promote_tls_assets \
    write_net_sysctl_conf write_net_helper_script write_net_service \
    apply_managed_files apply_managed_update apply_managed_runtime_update \
    apply_xray_only_managed_update write_state_file write_output_file \
    write_subscription_files write_acme_reload_helper \
    write_existing_tls_assets write_self_signed_tls_assets \
    ensure_xray_user ensure_managed_permissions \
    begin_managed_change finish_managed_change select_output_client_if_requested
}


# 一个调用点是不是「函数的最后一条语句」——是的话退出码本来就会原样返回，
# 不需要守卫。手工维护白名单会随着代码漂移，所以这里直接看后面那一条语句。
#
# 整段用 awk 而不是 grep，因为有两件事 grep 做不到：
#   - 续行：`foo \` + 参数行 + `|| return 1` 是一条逻辑语句，守卫写在最后一行上，
#     按物理行看会把它误判成裸调用；
#   - 传播式结尾：调用点后面紧跟 `}` / `;;` / 裸 `return` 时，退出码原样往外传。
errexit_unguarded_call_sites() {
  local names="${1}"

  cd "${ROOT_DIR}" && find xtun.sh lib -name '*.sh' -type f -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 awk -v names="${names}" '
      BEGIN {
        total = split(names, list, "|")
        for (i = 1; i <= total; i++) {
          watched[list[i]] = 1
        }
      }
      function trim(text) {
        sub(/^[[:space:]]+/, "", text)
        sub(/[[:space:]]+$/, "", text)
        return text
      }
      function propagates(text) {
        return (text == "}" || text == ";;" || text == "return" || text == "return $?")
      }
      function resolve(text,   shown) {
        if (pending == "") {
          return
        }
        if (!propagates(text)) {
          shown = pending
          # 续行拼起来的语句可以很长，报错行截断一下才看得清是哪一处
          if (length(shown) > 72) {
            shown = substr(shown, 1, 72) " ..."
          }
          printf "%s:%d: %s\n", pending_file, pending_line, shown
        }
        pending = ""
      }
      FNR == 1 {
        resolve("")
        continued = 0
      }
      {
        if (continued) {
          logical = logical " " trim($0)
        } else {
          logical = $0
          logical_line = FNR
        }
        if (logical ~ /\\[[:space:]]*$/) {
          sub(/\\[[:space:]]*$/, "", logical)
          continued = 1
          next
        }
        continued = 0

        statement = trim(logical)
        if (statement == "" || statement ~ /^#/) {
          next
        }
        resolve(statement)

        token = statement
        sub(/[[:space:]].*$/, "", token)
        if (!(token in watched)) {
          next
        }
        if (statement ~ /(\|\||&&|;[[:space:]]*then|;[[:space:]]*do|;[[:space:]]*return)/) {
          next
        }
        pending = statement
        pending_file = FILENAME
        pending_line = logical_line
      }
      END {
        resolve("")
      }
    '
}

run_errexit_guard_lint_case() {
  local names=""
  local hit=""
  local violations=0

  names="$( { errexit_returning_step_names; errexit_guarded_step_names; } \
    | grep -vE '^[[:space:]]*$' | LC_ALL=C sort -u | paste -sd '|' -)"

  # 自动那半边一旦被改坏（awk 认不出函数定义了），名单会悄悄退化成只剩显式清单，
  # lint 看着还是绿的。这里钉两个一定在里面的名字，让它坏得出声。
  errexit_returning_step_names | grep -qx 'write_xray_config'
  errexit_returning_step_names | grep -qx 'install_cmd'

  while IFS= read -r hit; do
    [[ -n "${hit}" ]] || continue
    printf '[fail] %s 少了 `|| return 1`：这一步失败会被 set -e 豁免吞掉\n' "${hit}" >&2
    violations=$((violations + 1))
  done < <(errexit_unguarded_call_sites "${names}")

  [[ "${violations}" -eq 0 ]]
}

# .shellcheckrc 里 disable=SC2034（本文件赋值、别处读）顺手也关掉了「变量名拼错」
# 这个真信号：写 XHTTP_PATH_="/x" 不会有任何人报错，XHTTP_PATH 保持空串，
# 然后空着进 nginx 的 location 前缀。shellcheck 一次只看一个文件，判不了跨文件的读，
# 所以这里自己扫：xtun.sh 顶层那批全局配置，凡是全仓库没有任何读取点的都报出来。
xtun_toplevel_global_names() {
  cd "${ROOT_DIR}" && awk '
    # 函数体整段跳过，只留 0 缩进的顶层赋值
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { in_function = 1; next }
    in_function { if ($0 ~ /^\}/) { in_function = 0 } next }
    /^(readonly |declare -[a-zA-Z]+ )?[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?=/ {
      name = $0
      sub(/^readonly /, "", name)
      sub(/^declare -[a-zA-Z]+ /, "", name)
      sub(/(\[[^]]*\])?=.*$/, "", name)
      print name
    }
  ' xtun.sh | LC_ALL=C sort -u
}

# 读取点算三种：${NAME…}、$NAME、以及 lib/state.sh 里按名字列出的状态键白名单
# （CORE_HEALTH_* 那批就只在那儿被「读」，写成 ${} 反而是错的）。
xtun_unread_global_names() {
  local name=""

  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    grep -rqE "\\\$\{${name}[:%#/}\[-]|\\\$${name}([^A-Za-z0-9_]|\$)" xtun.sh lib \
      || printf '%s\n' "${name}"
  done < <(xtun_toplevel_global_names)
}

run_dead_global_lint_case() {
  local name=""
  local violations=0

  cd "${ROOT_DIR}" || return 1

  # 扫描器一旦被改坏（awk 认不出顶层赋值了），名单会悄悄变空，lint 看着还是绿的。
  # 钉一个数量下限和两个一定在里面的名字，让它坏得出声。
  [[ "$(xtun_toplevel_global_names | grep -c .)" -ge 100 ]]
  xtun_toplevel_global_names | grep -qx 'XHTTP_PATH'
  xtun_toplevel_global_names | grep -qx 'STATE_FILE'

  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    printf '[fail] %s 在 xtun.sh 里赋了值，但全仓库没有任何读取点——要么是拼错了名字，要么该删\n' \
      "${name}" >&2
    violations=$((violations + 1))
  done < <(xtun_unread_global_names)

  [[ "${violations}" -eq 0 ]]
}

run_service_reload_preference_case() {
  local calls=""

  log_step() { :; }
  log_success() { :; }
  ensure_xray_user() { :; }
  ensure_managed_permissions() { :; }
  systemctl() {
    calls="${calls}${*}\n"
    case "${1:-}" in
      is-active)
        [[ "${3:-}" == "nginx" || "${3:-}" == "haproxy" ]]
        ;;
      *)
        return 0
        ;;
    esac
  }

  NGINX_RESTART_REQUIRED="no"
  restart_core_services

  # xray 没有热重载，只能重启；另外两个必须走 reload。
  [[ "${calls}" == *"restart xray"* ]]
  [[ "${calls}" == *"reload haproxy"* ]]
  [[ "${calls}" == *"reload nginx"* ]]
  [[ "${calls}" != *"restart haproxy"* ]]
  [[ "${calls}" != *"restart nginx"* ]]

  # 没在跑的服务 reload 不了，退回 restart。
  calls=""
  systemctl() {
    calls="${calls}${*}\n"
    case "${1:-}" in
      is-active) return 1 ;;
      *) return 0 ;;
    esac
  }
  restart_core_services
  [[ "${calls}" == *"restart nginx"* ]]
  [[ "${calls}" != *"reload nginx"* ]]

  # drop-in 刚改过时这一次必须重启，否则新的 rlimit 套不上。
  calls=""
  systemctl() {
    calls="${calls}${*}\n"
    case "${1:-}" in
      is-active) return 0 ;;
      *) return 0 ;;
    esac
  }
  NGINX_RESTART_REQUIRED="yes"
  restart_core_services
  [[ "${calls}" == *"daemon-reload"* ]]
  [[ "${calls}" == *"restart nginx"* ]]
  [[ "${NGINX_RESTART_REQUIRED}" == "no" ]]
}

run_managed_apply_case() {
  local tls_calls=0
  local runtime_calls=0
  local validate_calls=0
  local restart_calls=0
  local state_calls=0
  local output_calls=0
  local xray_write_calls=0
  local xray_validate_calls=0
  local xray_restart_calls=0

  write_tls_assets() {
    tls_calls=$((tls_calls + 1))
  }
  write_runtime_managed_files() {
    runtime_calls=$((runtime_calls + 1))
  }
  validate_configs() {
    validate_calls=$((validate_calls + 1))
  }
  restart_core_services() {
    restart_calls=$((restart_calls + 1))
  }
  write_state_file() {
    state_calls=$((state_calls + 1))
  }
  write_output_file() {
    output_calls=$((output_calls + 1))
  }
  write_xray_config() {
    xray_write_calls=$((xray_write_calls + 1))
  }
  validate_xray_config() {
    xray_validate_calls=$((xray_validate_calls + 1))
  }
  restart_xray_service() {
    xray_restart_calls=$((xray_restart_calls + 1))
  }

  apply_managed_runtime_update
  [[ "${tls_calls}" -eq 0 ]]
  [[ "${runtime_calls}" -eq 1 ]]
  [[ "${validate_calls}" -eq 1 ]]
  [[ "${restart_calls}" -eq 1 ]]
  [[ "${state_calls}" -eq 1 ]]
  [[ "${output_calls}" -eq 1 ]]

  apply_managed_update
  [[ "${tls_calls}" -eq 1 ]]
  [[ "${runtime_calls}" -eq 2 ]]
  [[ "${validate_calls}" -eq 2 ]]
  [[ "${restart_calls}" -eq 2 ]]
  [[ "${state_calls}" -eq 2 ]]
  [[ "${output_calls}" -eq 2 ]]

  apply_xray_only_managed_update
  [[ "${xray_write_calls}" -eq 1 ]]
  [[ "${xray_validate_calls}" -eq 1 ]]
  [[ "${xray_restart_calls}" -eq 1 ]]
  [[ "${runtime_calls}" -eq 2 ]]
  [[ "${restart_calls}" -eq 2 ]]
  [[ "${state_calls}" -eq 3 ]]
  [[ "${output_calls}" -eq 3 ]]
}

run_tls_stage_failure_case() {
  local workdir=""
  local status=0

  workdir="$(mktemp -d)"
  SSL_DIR="${workdir}/ssl"
  TLS_CERT_FILE="${SSL_DIR}/cert.pem"
  TLS_KEY_FILE="${SSL_DIR}/key.pem"
  CERT_MODE="cf-origin-ca"
  XHTTP_DOMAIN="cdn.example.com"
  CERT_SOURCE_PEM=""
  KEY_SOURCE_PEM=""
  XRAY_GID="0"
  mkdir -p "${SSL_DIR}"

  printf 'old-cert\n' > "${TLS_CERT_FILE}"
  printf 'old-key\n' > "${TLS_KEY_FILE}"

  set +e
  ( write_tls_assets ) >/dev/null 2>&1
  status=$?
  set -e

  [[ "${status}" -ne 0 ]]
  [[ "$(cat "${TLS_CERT_FILE}")" == "old-cert" ]]
  [[ "$(cat "${TLS_KEY_FILE}")" == "old-key" ]]
  [[ ! -e "${SSL_DIR}/.cert.pem.stage" ]]
  [[ ! -e "${SSL_DIR}/.key.pem.stage" ]]
}

# 签发这一步失败但没走 die 时，最容易出的错是「报成功」：函数会接着往下跑到
# validate_tls_assets，而它校验的是磁盘上那份没被换掉的旧证书——旧证书当然是好的。
# 于是 change-cert-mode / renew-cert 会告诉用户换好了，实际上一个字节都没换。
run_tls_issue_failure_not_reported_ok_case() {
  local workdir=""
  local status=0

  workdir="$(mktemp -d)"
  SSL_DIR="${workdir}/ssl"
  TLS_CERT_FILE="${SSL_DIR}/cert.pem"
  TLS_KEY_FILE="${SSL_DIR}/key.pem"
  CERT_MODE="acme-dns-cf"
  XHTTP_DOMAIN="cdn.example.com"
  XRAY_GID="0"
  mkdir -p "${SSL_DIR}"

  # 磁盘上留一份「校验得过」的旧证书，正是它会把失败盖成成功。
  printf 'old-cert\n' > "${TLS_CERT_FILE}"
  printf 'old-key\n' > "${TLS_KEY_FILE}"
  backup_path() { :; }
  ensure_managed_permissions() { :; }
  validate_tls_assets() { :; }
  issue_acme_cf_cert() { return 1; }

  set +e
  ( write_tls_assets ) >/dev/null 2>&1
  status=$?
  set -e

  [[ "${status}" -ne 0 ]]
  [[ "$(cat "${TLS_CERT_FILE}")" == "old-cert" ]]

  # 签发「成功」了却没落下暂存文件，同样不能算换成功。
  issue_acme_cf_cert() { :; }
  set +e
  ( write_tls_assets ) >/dev/null 2>&1
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]

  rm -rf "${workdir}"
  load_functions
}

# add-client 走的是这条：写配置失败后如果不停下来，validate_xray_config 校验的是
# 磁盘上那份旧 config.json，一样会过，于是「客户端已添加」是假的。
run_xray_only_update_write_failure_case() {
  local status=0
  local rollback_calls=0
  local validated=0

  log() { :; }
  log_step() { :; }
  log_success() { :; }
  write_xray_config() { return 1; }
  validate_xray_config() { validated=$((validated + 1)); }
  write_state_file() { :; }
  write_output_file() { :; }
  restart_xray_service() { :; }
  rollback_xray_config_state() { rollback_calls=$((rollback_calls + 1)); }

  status=0
  apply_xray_only_managed_update || status=$?

  [[ "${status}" -ne 0 ]]
  [[ "${rollback_calls}" -eq 1 ]]
  # 写都没写成，就不该再拿旧配置去「校验通过」。
  [[ "${validated}" -eq 0 ]]

  load_functions
}

run_managed_rollback_case() {
  local workdir=""
  local status=0
  local recovery_calls=0

  workdir="$(mktemp -d)"
  XRAY_CONFIG_DIR="${workdir}/xray"
  XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
  HAPROXY_CONFIG="${workdir}/haproxy.cfg"
  NGINX_CONFIG_FILE="${workdir}/nginx.conf"
  BACKUP_DIR="${workdir}/backup"
  mkdir -p "${XRAY_CONFIG_DIR}" "${BACKUP_DIR}"

  printf 'old-xray\n' > "${XRAY_CONFIG_FILE}"
  printf 'old-haproxy\n' > "${HAPROXY_CONFIG}"
  printf 'old-nginx\n' > "${NGINX_CONFIG_FILE}"

  backup_path() {
    local path="${1}"
    local target=""

    if [[ ! -e "${path}" ]]; then
      return
    fi

    target="${BACKUP_DIR}${path}"
    mkdir -p "$(dirname "${target}")"
    cp -a "${path}" "${target}"
  }
  write_runtime_managed_files() {
    backup_path "${XRAY_CONFIG_FILE}"
    backup_path "${HAPROXY_CONFIG}"
    backup_path "${NGINX_CONFIG_FILE}"
    printf 'new-xray\n' > "${XRAY_CONFIG_FILE}"
    printf 'new-haproxy\n' > "${HAPROXY_CONFIG}"
    printf 'new-nginx\n' > "${NGINX_CONFIG_FILE}"
  }
  validate_configs() {
    return 1
  }
  ensure_xray_user() {
    recovery_calls=$((recovery_calls + 1))
  }
  ensure_managed_permissions() { :; }
  systemctl() { :; }
  log() { :; }
  warn() { :; }

  set +e
  apply_managed_runtime_update >/dev/null 2>&1
  status=$?
  set -e

  [[ "${status}" -ne 0 ]]
  [[ "${recovery_calls}" -eq 1 ]]
  [[ "$(cat "${XRAY_CONFIG_FILE}")" == "old-xray" ]]
  [[ "$(cat "${HAPROXY_CONFIG}")" == "old-haproxy" ]]
  [[ "$(cat "${NGINX_CONFIG_FILE}")" == "old-nginx" ]]
}

run_optional_component_rollback_case() {
  local stopped=()
  local rolled=()
  local sysctl_calls=0
  local warned=""

  ENABLE_WARP="yes"
  ENABLE_NET_OPT="yes"
  stop_and_disable_service_if_present() {
    stopped+=("${1}")
  }
  rollback_managed_paths() {
    rolled=("$@")
  }
  systemctl() { :; }
  sysctl() {
    sysctl_calls=$((sysctl_calls + 1))
  }
  warn() {
    warned+="${1}"$'\n'
  }

  rollback_optional_component_state
  [[ " ${stopped[*]} " == *" ${NET_SERVICE_NAME} "* ]]
  [[ " ${stopped[*]} " != *" warp-svc.service "* ]]
  [[ " ${rolled[*]} " == *" ${NET_SYSCTL_CONF} "* ]]
  [[ " ${rolled[*]} " == *" ${NET_HELPER_PATH} "* ]]
  [[ " ${rolled[*]} " == *" ${NET_SERVICE_FILE} "* ]]
  [[ "${sysctl_calls}" -eq 1 ]]
  printf '%s' "${warned}" | grep -q '可选组件应用失败'

  stopped=()
  rolled=()
  sysctl_calls=0
  warned=""
  ENABLE_NET_OPT="no"
  rollback_optional_component_state
  [[ "${#stopped[@]}" -eq 0 ]]
  [[ "${#rolled[@]}" -eq 0 ]]
  [[ "${sysctl_calls}" -eq 0 ]]
  [[ -z "${warned}" ]]
  load_functions
}

run_install_rollback_helper_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  BACKUP_DIR="${workdir}/backup"
  XRAY_CONFIG_DIR="${workdir}/xray"
  XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
  HAPROXY_CONFIG="${workdir}/haproxy.cfg"
  NGINX_CONFIG_FILE="${workdir}/nginx.conf"
  XRAY_SERVICE_FILE="${workdir}/xray.service"
  SSL_DIR="${workdir}/ssl"
  TLS_CERT_FILE="${SSL_DIR}/cert.pem"
  TLS_KEY_FILE="${SSL_DIR}/key.pem"
  ACME_RELOAD_HELPER="${workdir}/cert-reload.sh"
  mkdir -p "${BACKUP_DIR}" "${XRAY_CONFIG_DIR}" "${SSL_DIR}"

  printf 'old-xray\n' > "${XRAY_CONFIG_FILE}"
  printf 'old-haproxy\n' > "${HAPROXY_CONFIG}"
  printf 'old-nginx\n' > "${NGINX_CONFIG_FILE}"
  printf 'old-service\n' > "${XRAY_SERVICE_FILE}"
  printf 'old-cert\n' > "${TLS_CERT_FILE}"
  printf 'old-key\n' > "${TLS_KEY_FILE}"
  printf 'old-helper\n' > "${ACME_RELOAD_HELPER}"

  backup_path() {
    local path="${1}"
    local target=""

    if [[ ! -e "${path}" ]]; then
      return
    fi

    target="${BACKUP_DIR}${path}"
    mkdir -p "$(dirname "${target}")"
    cp -a "${path}" "${target}"
  }
  backup_path "${XRAY_CONFIG_FILE}"
  backup_path "${HAPROXY_CONFIG}"
  backup_path "${NGINX_CONFIG_FILE}"
  backup_path "${XRAY_SERVICE_FILE}"
  backup_path "${TLS_CERT_FILE}"
  backup_path "${TLS_KEY_FILE}"
  backup_path "${ACME_RELOAD_HELPER}"

  printf 'new-xray\n' > "${XRAY_CONFIG_FILE}"
  printf 'new-haproxy\n' > "${HAPROXY_CONFIG}"
  printf 'new-nginx\n' > "${NGINX_CONFIG_FILE}"
  printf 'new-service\n' > "${XRAY_SERVICE_FILE}"
  printf 'new-cert\n' > "${TLS_CERT_FILE}"
  printf 'new-key\n' > "${TLS_KEY_FILE}"
  printf 'new-helper\n' > "${ACME_RELOAD_HELPER}"

  ensure_xray_user() { :; }
  ensure_managed_permissions() { :; }
  systemctl() { :; }
  warn() { :; }

  rollback_managed_runtime_state "yes" "yes"

  [[ "$(cat "${XRAY_CONFIG_FILE}")" == "old-xray" ]]
  [[ "$(cat "${HAPROXY_CONFIG}")" == "old-haproxy" ]]
  [[ "$(cat "${NGINX_CONFIG_FILE}")" == "old-nginx" ]]
  [[ "$(cat "${XRAY_SERVICE_FILE}")" == "old-service" ]]
  [[ "$(cat "${TLS_CERT_FILE}")" == "old-cert" ]]
  [[ "$(cat "${TLS_KEY_FILE}")" == "old-key" ]]
  [[ "$(cat "${ACME_RELOAD_HELPER}")" == "old-helper" ]]
}

run_restart_optional_service_case() {
  local restarted=()

  load_dashboard_context() {
    ENABLE_WARP="no"
    ENABLE_NET_OPT="no"
  }
  restart_service_if_present() {
    restarted+=("${1}")
  }
  log() { :; }

  restart_cmd
  [[ " ${restarted[*]} " == *" xray.service "* ]]
  [[ " ${restarted[*]} " == *" haproxy.service "* ]]
  [[ " ${restarted[*]} " == *" nginx.service "* ]]
  [[ " ${restarted[*]} " == *" ${CORE_HEALTH_TIMER_NAME} "* ]]
  [[ " ${restarted[*]} " != *" warp-svc.service "* ]]
  [[ " ${restarted[*]} " != *" ${NET_SERVICE_NAME} "* ]]

  restarted=()
  load_dashboard_context() {
    ENABLE_WARP="yes"
    ENABLE_NET_OPT="yes"
  }

  restart_cmd
  [[ " ${restarted[*]} " == *" ${NET_SERVICE_NAME} "* ]]
  [[ " ${restarted[*]} " != *" warp-svc.service "* ]]
  load_functions
}
