# shellcheck shell=bash

# ------------------------------
# 展示基础层
# 负责通用样式、状态探测与配置自检
# ------------------------------

style_text() {
  local style="${1}"
  local text="${2}"
  printf '%b%s%b' "${style}" "${text}" "${C_RESET}"
}

divider() {
  printf '%s\n' '--------------------------------------------------------------------'
}

panel_row() {
  printf '  %-18s %s\n' "${1}" "${2}"
}

short_value() {
  local value="${1}"
  local head="${2:-8}"
  local tail="${3:-6}"
  local len=0

  len="${#value}"
  if [[ "${len}" -le $((head + tail + 3)) ]]; then
    printf '%s' "${value}"
  else
    printf '%s...%s' "${value:0:head}" "${value: -tail}"
  fi
}

service_active_state() {
  local unit_name="${1}"
  local state=""

  if ! service_exists "${unit_name}"; then
    printf 'not-installed'
    return
  fi

  state="$(systemctl show "${unit_name}" -p ActiveState --value 2>/dev/null || true)"
  if [[ -n "${state}" ]]; then
    printf '%s' "${state}"
  else
    printf 'installed'
  fi
}

service_enable_state() {
  local unit_name="${1}"

  if ! service_exists "${unit_name}"; then
    printf 'not-installed'
    return
  fi

  case "$(systemctl show "${unit_name}" -p UnitFileState --value 2>/dev/null || true)" in
    enabled)
      printf 'enabled'
      ;;
    disabled|masked|static|indirect|generated|transient)
      printf 'installed'
      ;;
    *)
      printf 'installed'
      ;;
  esac
}

service_badge() {
  local state="${1}"

  case "${state}" in
    active)
      style_text "${C_GREEN}" "运行中"
      ;;
    inactive|failed|activating|deactivating)
      case "${state}" in
        inactive) style_text "${C_RED}" "未运行" ;;
        failed) style_text "${C_RED}" "失败" ;;
        activating) style_text "${C_YELLOW}" "启动中" ;;
        deactivating) style_text "${C_YELLOW}" "停止中" ;;
      esac
      ;;
    not-installed)
      style_text "${C_YELLOW}" "未安装"
      ;;
    *)
      style_text "${C_YELLOW}" "${state}"
      ;;
  esac
}

bool_badge() {
  case "${1}" in
    yes|enabled|true)
      style_text "${C_GREEN}" "已启用"
      ;;
    skipped)
      style_text "${C_YELLOW}" "已跳过"
      ;;
    no|disabled|false)
      style_text "${C_YELLOW}" "已禁用"
      ;;
    *)
      style_text "${C_YELLOW}" "${1:-未知}"
      ;;
  esac
}

service_install_state_label() {
  case "${1}" in
    enabled)
      printf '已启用'
      ;;
    installed)
      printf '已安装'
      ;;
    not-installed)
      printf '未安装'
      ;;
    *)
      printf '%s' "${1}"
      ;;
  esac
}

pretty_cert_mode() {
  case "${CERT_MODE:-unknown}" in
    self-signed)
      printf '自签名'
      ;;
    existing)
      printf '现有证书'
      ;;
    acme-dns-cf)
      printf 'ACME DNS CF'
      ;;
    *)
      printf '%s' "${CERT_MODE:-未知}"
      ;;
  esac
}

xray_version_line() {
  if [[ -x "${XRAY_BIN}" ]]; then
    "${XRAY_BIN}" version 2>/dev/null | head -n 1 || true
  fi
}

listening_port_text() {
  local port="${1}"
  local listeners=""

  if ! command -v ss >/dev/null 2>&1; then
    printf '未探测'
    return
  fi

  listeners="$(ss -ltnH "( sport = :${port} )" 2>/dev/null | awk '{print $4}' | sort -u | paste -sd, -)"
  if [[ -n "${listeners}" ]]; then
    printf '运行中 (%s)' "${listeners}"
  else
    printf '未监听'
  fi
}

is_port_listening() {
  local port="${1}"

  if ! command -v ss >/dev/null 2>&1; then
    return 1
  fi

  ss -ltnH "( sport = :${port} )" 2>/dev/null | grep -q .
}

cert_expiry_text() {
  if [[ ! -f "${TLS_CERT_FILE}" ]]; then
    printf '未找到证书'
    return
  fi

  openssl x509 -in "${TLS_CERT_FILE}" -noout -enddate 2>/dev/null \
    | sed 's/^notAfter=//' \
    | head -n 1
}

latest_backup_label() {
  local latest_path=""

  # 备份目录名是脚本自己按时间戳生成的，不含空白或通配符；
  # 换成 find 拿不到「按时间最新」这个排序。
  # shellcheck disable=SC2012
  latest_path="$(ls -1dt "${BACKUP_ROOT}"/* 2>/dev/null | head -n 1 || true)"
  if [[ -n "${latest_path}" ]]; then
    basename "${latest_path}"
  else
    printf '无'
  fi
}

warp_outbound_text() {
  local summary=""

  if [[ "${ENABLE_WARP:-no}" != "yes" ]]; then
    printf '未启用'
    return
  fi

  summary="wireguard"
  [[ -z "${WARP_ADDRESS_V4:-}" ]] || summary+=" · ${WARP_ADDRESS_V4}"
  [[ -z "${WARP_ADDRESS_V6:-}" ]] || summary+=" · ${WARP_ADDRESS_V6}"
  summary+=" · ${WARP_ENDPOINT:-${DEFAULT_WARP_ENDPOINT}}"
  [[ -z "${WARP_RESERVED:-}" ]] || summary+=" · reserved=${WARP_RESERVED}"
  printf '%s' "${summary}"
}

warp_output_addresses_text() {
  local addresses=""

  [[ -z "${WARP_ADDRESS_V4:-}" ]] || addresses="${WARP_ADDRESS_V4}/32"
  if [[ -n "${WARP_ADDRESS_V6:-}" ]]; then
    [[ -z "${addresses}" ]] || addresses+=", "
    addresses+="${WARP_ADDRESS_V6}/128"
  fi

  printf '%s' "${addresses:-未设置}"
}

warp_endpoint_host() {
  local endpoint="${WARP_ENDPOINT:-${DEFAULT_WARP_ENDPOINT}}"

  if [[ "${endpoint}" == *:* ]]; then
    printf '%s' "${endpoint%:*}"
  else
    printf '%s' "${endpoint}"
  fi
}

warp_endpoint_resolve_state() {
  local host=""

  if [[ "${ENABLE_WARP:-no}" != "yes" ]]; then
    printf 'unknown'
    return
  fi

  host="$(warp_endpoint_host)"
  if [[ -z "${host}" ]]; then
    printf 'fail'
    return
  fi
  if is_ipv4 "${host}"; then
    printf 'ok'
    return
  fi
  if ! command -v getent >/dev/null 2>&1; then
    printf 'unknown'
    return
  fi

  if getent ahosts "${host}" 2>/dev/null | grep -q .; then
    printf 'ok'
  else
    printf 'fail'
  fi
}

warp_endpoint_resolve_text() {
  check_badge "$(warp_endpoint_resolve_state)"
}

warp_probe_port() {
  local port=0
  local attempt=0

  while [[ "${attempt}" -lt 20 ]]; do
    port=$((41000 + RANDOM % 4000))
    if ! is_port_listening "${port}"; then
      printf '%s' "${port}"
      return 0
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

warp_egress_probe_text() {
  local port=""
  local config_file=""
  local probe_pid=""
  local ip=""
  local waited=0

  if [[ "${ENABLE_WARP:-no}" != "yes" ]]; then
    printf '未启用'
    return
  fi
  if [[ ! -x "${XRAY_BIN}" ]] || ! command -v curl >/dev/null 2>&1; then
    printf '未探测 (缺少 xray 或 curl)'
    return
  fi
  if [[ -z "${WARP_PRIVATE_KEY:-}" ]]; then
    printf '未探测 (缺少 WireGuard 私钥)'
    return
  fi
  if ! port="$(warp_probe_port)"; then
    printf '未探测 (找不到空闲端口)'
    return
  fi
  if ! config_file="$(mktemp "${TMPDIR:-/tmp}/xtun-warp-probe.XXXXXX.json")"; then
    printf '未探测 (无法创建临时配置)'
    return
  fi

  chmod 0600 "${config_file}"
  if ! jq -cn \
    --argjson outbound "$(xray_warp_outbound_json)" \
    --arg port "${port}" \
    '{
       log: { loglevel: "none" },
       inbounds: [
         {
           listen: "127.0.0.1",
           port: ($port | tonumber),
           protocol: "socks",
           settings: { udp: false }
         }
       ],
       outbounds: [$outbound]
     }' > "${config_file}" 2>/dev/null; then
    rm -f "${config_file}"
    printf '未探测 (生成临时配置失败)'
    return
  fi

  "${XRAY_BIN}" run -c "${config_file}" >/dev/null 2>&1 &
  probe_pid="$!"
  while [[ "${waited}" -lt 40 ]]; do
    is_port_listening "${port}" && break
    sleep 0.1
    waited=$((waited + 1))
  done

  if is_port_listening "${port}"; then
    ip="$(curl --socks5-hostname "127.0.0.1:${port}" \
      -fsSL --max-time 8 https://api.ipify.org 2>/dev/null | tr -d '\r\n')"
  fi

  kill "${probe_pid}" >/dev/null 2>&1 || true
  wait "${probe_pid}" 2>/dev/null || true
  rm -f "${config_file}"

  if [[ -n "${ip}" ]]; then
    printf '%s' "${ip}"
  else
    printf '未探测'
  fi
}

warp_rule_count_text() {
  local count=0

  if [[ -z "${WARP_RULES_TEXT:-}" && ! -f "${WARP_RULES_FILE}" ]]; then
    printf '0'
    return
  fi

  while IFS= read -r _; do
    count=$((count + 1))
  done < <(current_warp_rules_text)

  printf '%s' "${count}"
}

# 从 config.json 读 block 规则，报 private / cn 拦截状态。
xray_routing_block_text() {
  local count=""
  local cn=""

  if [[ ! -f "${XRAY_CONFIG_FILE}" ]] || ! command -v jq >/dev/null 2>&1; then
    printf '未知'
    return
  fi

  count="$(config_jq_read '[.routing.rules[] | select(.outboundTag=="block")] | length')"
  if [[ -z "${count}" ]] || ! [[ "${count}" =~ ^[0-9]+$ ]]; then
    printf '未知'
    return
  fi

  cn="$(config_jq_read '.routing.rules[] | select(.outboundTag=="block") | .domain[]? | select(. == "geosite:cn")')"
  if [[ -n "${cn}" ]]; then
    printf 'private+cn（%s 条 block 规则）' "${count}"
  else
    printf 'private（%s 条 block 规则）' "${count}"
  fi
}

# ------------------------------
# 网络栈探测（diagnose --net）
# 下面这些读取函数测试里整函数覆盖成固定值；组装函数只做拼装与判定。
# ------------------------------

net_kernel_version() {
  uname -r 2>/dev/null || true
}

net_current_cc() {
  if [[ -r /proc/sys/net/ipv4/tcp_congestion_control ]]; then
    cat /proc/sys/net/ipv4/tcp_congestion_control
  else
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true
  fi
}

net_tcp_bbr_version() {
  bbr_module_version
}

net_default_qdisc() {
  if [[ -r /proc/sys/net/core/default_qdisc ]]; then
    cat /proc/sys/net/core/default_qdisc
  else
    sysctl -n net.core.default_qdisc 2>/dev/null || true
  fi
}

net_default_nic() {
  ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}'
}

net_nic_qdisc_line() {
  local nic="${1}"

  command -v tc >/dev/null 2>&1 || return 0
  tc qdisc show dev "${nic}" root 2>/dev/null | head -n 1
}

net_nic_mtu() {
  local nic="${1}"

  cat "/sys/class/net/${nic}/mtu" 2>/dev/null || true
}

net_sysctl_value() {
  local key="${1}"

  if [[ -r "/proc/sys/${key//.//}" ]]; then
    cat "/proc/sys/${key//.//}"
  else
    sysctl -n "${key}" 2>/dev/null || true
  fi
}

net_nginx_worker_rlimit_text() {
  local wc_value=""
  local rl_value=""

  wc_value="$(nginx_worker_connections_value)" || wc_value="未知"
  rl_value="$(awk '$1 == "worker_rlimit_nofile" { sub(/;.*/, "", $2); print $2; exit }' "${NGINX_MAIN_CONFIG}" 2>/dev/null)"
  printf '%s / %s' "${wc_value:-未知}" "${rl_value:-未知}"
}

net_nginx_master_limitnofile() {
  local pid=""
  local limit=""

  pid="$(pgrep -o -x nginx 2>/dev/null || true)"
  [[ -n "${pid}" ]] || { printf '未知'; return; }
  limit="$(awk '/Max open files/ { print $4; exit }' "/proc/${pid}/limits" 2>/dev/null)"
  printf '%s' "${limit:-未知}"
}

net_haproxy_maxconn() {
  awk '$1 == "maxconn" { sub(/;.*/, "", $2); print $2; exit }' "${HAPROXY_CONFIG}" 2>/dev/null || true
}

net_cc_distribution() {
  command -v ss >/dev/null 2>&1 || return 0
  ss -tin 2>/dev/null | grep -oE '(cubic|bbr1|bbr|reno)' | sort | uniq -c     | awk '{ printf "%s=%s ", $2, $1 }' | sed 's/ $//'
}

# 拥塞控制不在 bbr 系时计一次失败；其它读取失败只显示未知，不算失败。
net_stack_state() {
  local cc=""

  cc="$(net_current_cc)"
  if cc_has_bbr " ${cc:-} "; then
    printf 'ok'
  else
    printf 'fail'
  fi
}

net_stack_text() {
  local nic=""
  local qdisc_line=""

  nic="$(net_default_nic)"
  printf '内核:            %s\n' "$(net_kernel_version)"
  printf '拥塞控制:        %s  (可用: %s)\n' "$(net_current_cc)" "$(available_cc)"
  printf 'tcp_bbr 模块:    version %s\n' "$(net_tcp_bbr_version)"
  printf '默认 qdisc:      %s\n' "$(net_default_qdisc)"
  if [[ -n "${nic}" ]]; then
    qdisc_line="$(net_nic_qdisc_line "${nic}")"
    printf '出网网卡 qdisc:  %s   (tc qdisc show dev %s root)\n' "${qdisc_line:-未知}" "${nic}"
    printf 'MTU:             %s\n' "$(net_nic_mtu "${nic}")"
  fi
  printf 'tcp_notsent_lowat: %s\n' "$(net_sysctl_value net.ipv4.tcp_notsent_lowat)"
  printf 'fs.file-max:     %s\n' "$(net_sysctl_value fs.file-max)"
  printf 'nginx worker_connections / worker_rlimit_nofile:  %s\n' "$(net_nginx_worker_rlimit_text)"
  printf 'nginx master LimitNOFILE:  %s   (/proc/<pid>/limits)\n' "$(net_nginx_master_limitnofile)"
  printf 'haproxy maxconn: %s\n' "$(net_haproxy_maxconn)"
  printf '已建立连接拥塞算法分布:  %s   (ss -tin)\n' "$(net_cc_distribution)"
}

# nginx 编译里有没有 http_v3 模块。
nginx_v3_capable() {
  command -v nginx >/dev/null 2>&1 || return 1
  nginx -V 2>&1 | grep -q -- '-with-http_v3_module\|http_v3_module'
}

# H3 直连下行的启用条件：模块在 + 证书模式客户端能校验（自签名不行）。
# 两者任一不满足整段功能自动关闭，h3_disabled_reason 给出原因。
h3_disabled_reason() {
  if ! nginx_v3_capable; then
    printf '当前 nginx 未编译 http_v3 模块（Debian 13 自带；Debian 12 / Ubuntu 24.04 需 nginx.org 官方源）'
    return
  fi
  case "${CERT_MODE:-}" in
    existing|acme-dns-cf) return ;;
    self-signed) printf '证书为自签名，客户端无法校验 H3（需 existing / acme-dns-cf 模式）' ;;
    *) printf '证书模式未就绪' ;;
  esac
}

h3_enabled() {
  [[ -z "$(h3_disabled_reason)" ]]
}

have_qrencode() {
  command -v qrencode >/dev/null 2>&1
}

# UDP 443（QUIC）监听探测
quic_port_listening() {
  [[ "$(quic_port_text)" == "运行中" ]]
}

quic_port_text() {
  local listeners=""

  if ! command -v ss >/dev/null 2>&1; then
    printf '未探测'
    return
  fi
  if ! h3_enabled; then
    printf '不检查（H3 未启用）'
    return
  fi

  listeners="$(ss -lunpH '( sport = :443 )' 2>/dev/null)"
  if grep -Fq 'users:(("nginx"' <<< "${listeners}"; then
    printf '运行中'
    return
  fi
  if [[ -z "${listeners}" ]]; then
    printf '未监听'
    return
  fi
  if ! grep -q 'users:' <<< "${listeners}"; then
    printf '有 UDP 监听，无法确认归属（需要 root）'
    return
  fi

  printf '有 UDP 监听，但不是 nginx'
}

check_badge() {
  case "${1}" in
    ok)
      style_text "${C_GREEN}" "通过"
      ;;
    fail)
      style_text "${C_RED}" "失败"
      ;;
    *)
      style_text "${C_YELLOW}" "${1:-未探测}"
      ;;
  esac
}

xray_config_check_state() {
  if [[ ! -x "${XRAY_BIN}" || ! -f "${XRAY_CONFIG_FILE}" ]]; then
    printf 'unknown'
    return
  fi

  if "${XRAY_BIN}" run -test -config "${XRAY_CONFIG_FILE}" >/dev/null 2>&1; then
    printf 'ok'
  else
    printf 'fail'
  fi
}

xray_config_check_text() {
  check_badge "$(xray_config_check_state)"
}

nginx_config_check_state() {
  if ! command -v nginx >/dev/null 2>&1 || [[ ! -f "${NGINX_CONFIG_FILE}" ]]; then
    printf 'unknown'
    return
  fi

  if nginx -t >/dev/null 2>&1; then
    printf 'ok'
  else
    printf 'fail'
  fi
}

nginx_config_check_text() {
  check_badge "$(nginx_config_check_state)"
}

# worker_connections 只能写在 events 块里，而 xtun 只接管 conf.d/ 下的一个 server 段，
# 够不着它——xtun-limits.conf 抬上去的 LimitNOFILE 到这里会被这个更小的上限截住。
# 更要命的是它在反代场景下要打对折：一条客户端连接占两个 fd（下游一个、到 xray 的
# 上游一个），发行版默认的 768 实际只够 384 个客户端。改不了就至少报出来。
NGINX_WORKER_CONNECTIONS_ADVISED="4096"

# 与 1.25.1 比较；nginx 不存在或读不到版本时按「不满足」处理。
nginx_version_at_least() {
  local want="${1}"
  local have=""

  command -v nginx >/dev/null 2>&1 || return 1
  have="$(nginx -v 2>&1 | sed -n 's/^nginx version: nginx\///p')"
  [[ -n "${have}" ]] || return 1

  [[ "$(printf '%s\n' "${want}" "${have}" | sort -V | head -n 1)" == "${want}" ]]
}

nginx_main_managed() {
  [[ "${NGINX_MAIN_MANAGED:-no}" == "yes" ]]
}

nginx_worker_connections_value() {
  local value=""

  [[ -r "${NGINX_MAIN_CONFIG}" ]] || return 1
  value="$(awk '$1 == "worker_connections" { sub(/;.*$/, "", $2); print $2; exit }' "${NGINX_MAIN_CONFIG}")"
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1

  printf '%s' "${value}"
}

nginx_worker_connections_state() {
  local value=""

  if ! value="$(nginx_worker_connections_value)"; then
    printf 'unknown'
    return
  fi

  if [[ "${value}" -ge "${NGINX_WORKER_CONNECTIONS_ADVISED}" ]]; then
    printf 'ok'
  else
    printf 'low'
  fi
}

nginx_worker_connections_text() {
  local value=""

  if ! value="$(nginx_worker_connections_value)"; then
    printf '未知'
    return
  fi

  if [[ "$(nginx_worker_connections_state)" == "low" ]]; then
    if nginx_main_managed; then
      printf '%s（每 worker 只够 %s 条被代理的连接；建议在 %s 的 events 块里调到 %s 以上）' \
        "${value}" "$((value / 2))" "${NGINX_MAIN_CONFIG}" "${NGINX_WORKER_CONNECTIONS_ADVISED}"
    else
      printf '%s（每 worker 只够 %s 条被代理的连接；建议在 %s 的 events 块里调到 %s 以上，或运行 xtun apply-config --manage-nginx-main 交由 xtun 接管）' \
        "${value}" "$((value / 2))" "${NGINX_MAIN_CONFIG}" "${NGINX_WORKER_CONNECTIONS_ADVISED}"
    fi
    return
  fi

  printf '%s' "${value}"
}

haproxy_config_check_state() {
  if ! command -v haproxy >/dev/null 2>&1 || [[ ! -f "${HAPROXY_CONFIG}" ]]; then
    printf 'unknown'
    return
  fi

  if haproxy -c -f "${HAPROXY_CONFIG}" >/dev/null 2>&1; then
    printf 'ok'
  else
    printf 'fail'
  fi
}

haproxy_config_check_text() {
  check_badge "$(haproxy_config_check_state)"
}

local_tls_probe_state() {
  if ! command -v openssl >/dev/null 2>&1; then
    printf 'unknown'
    return
  fi

  if [[ -z "${XHTTP_DOMAIN:-}" ]]; then
    printf 'unknown'
    return
  fi

  if echo | openssl s_client -connect 127.0.0.1:443 -servername "${XHTTP_DOMAIN}" >/dev/null 2>&1; then
    printf 'ok'
  else
    printf 'fail'
  fi
}

local_tls_probe_text() {
  check_badge "$(local_tls_probe_state)"
}
