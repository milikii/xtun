# shellcheck shell=bash

run_nginx_main_config_case() {
  local workdir=""
  local main_conf=""
  local conf_d=""

  workdir="$(mktemp -d)"
  main_conf="${workdir}/nginx.conf"
  conf_d="${workdir}/conf.d"
  NGINX_MAIN_CONFIG="${main_conf}"
  NGINX_CONF_DIR="${conf_d}"
  NGINX_CONFIG_FILE="${conf_d}/xtun.conf"
  mkdir -p "${conf_d}"
  reset_feature_defaults
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/assets/v3"
  XHTTP_LOCAL_PORT="8001"
  NGINX_TLS_PORT="8443"
  TLS_CERT_FILE="/etc/ssl/xtun/cert.pem"
  TLS_KEY_FILE="/etc/ssl/xtun/key.pem"
  nginx_version_at_least() { return 0; }

  # 未接管时不写主配置
  NGINX_MAIN_MANAGED="no"
  write_nginx_main_config
  [[ ! -e "${main_conf}" ]]

  # 接管：模板含 rlimit / worker_connections / 两个用户块
  NGINX_MAIN_MANAGED="yes"
  write_nginx_main_config

  assert_contains 'worker_rlimit_nofile 1048576;' "${main_conf}"
  assert_contains 'worker_connections 65535;' "${main_conf}"
  assert_contains 'worker_cpu_affinity auto;' "${main_conf}"
  assert_contains 'xtun-user:nginx-main' "${main_conf}"
  assert_contains 'xtun-user:nginx-http' "${main_conf}"
  # 用户块位置：nginx-main 在 events 之后、http 之前；nginx-http 在 http 内末尾
  [[ "$(awk '/xtun-user:nginx-main >>>/ { print NR; exit }' "${main_conf}")" -lt \
     "$(awk '/^http \{/ { print NR; exit }' "${main_conf}")" ]]
  [[ "$(awk '/xtun-user:nginx-http >>>/ { print NR; exit }' "${main_conf}")" -gt \
     "$(awk '/sites-enabled/ { print NR; exit }' "${main_conf}")" ]]

  # 用户块内容跨重写保留
  sed -i '/>>> xtun-user:nginx-main >>>/a\worker_priority -5;' "${main_conf}"
  sed -i '/>>> xtun-user:nginx-http >>>/a\    map $http_upgrade $connection_upgrade { default upgrade; }' "${main_conf}"
  write_nginx_main_config
  assert_contains 'worker_priority -5;' "${main_conf}"
  assert_contains 'connection_upgrade' "${main_conf}"
  # 不重复复制
  [[ "$(grep -c 'worker_priority -5;' "${main_conf}")" -eq 1 ]]

  rm -rf "${workdir}"
  load_functions
}

run_nginx_http2_compat_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  NGINX_CONF_DIR="${workdir}/conf.d"
  NGINX_CONFIG_FILE="${NGINX_CONF_DIR}/xtun.conf"
  mkdir -p "${NGINX_CONF_DIR}"
  reset_feature_defaults
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/assets/v3"
  XHTTP_LOCAL_PORT="8001"
  NGINX_TLS_PORT="8443"
  TLS_CERT_FILE="/etc/ssl/xtun/cert.pem"
  TLS_KEY_FILE="/etc/ssl/xtun/key.pem"

  # >= 1.25.1：独立 http2 on;
  nginx_version_at_least() { return 0; }
  write_nginx_config
  assert_contains 'http2 on;' "${NGINX_CONFIG_FILE}"
  assert_absent 'listen 127.0.0.1:8443 ssl http2;' "${NGINX_CONFIG_FILE}"

  # < 1.25.1（Ubuntu 24.04 的 1.24）：listen 行老语法
  nginx_version_at_least() { return 1; }
  write_nginx_config
  assert_contains 'listen 127.0.0.1:8443 ssl http2;' "${NGINX_CONFIG_FILE}"
  assert_absent 'http2 on;' "${NGINX_CONFIG_FILE}"

  rm -rf "${workdir}"
  load_functions
}

# §7.4 diagnose --net。读取函数全部覆盖成固定值，断言输出行与失败判定。
run_diagnose_net_case() {
  net_kernel_version() { printf '7.0.3-joeyblog-bbrv3'; }
  net_current_cc() { printf 'bbr1'; }
  available_cc() { printf 'reno cubic bbr bbr1'; }
  net_tcp_bbr_version() { printf '3'; }
  net_default_qdisc() { printf 'fq'; }
  net_default_nic() { printf 'eth0'; }
  net_nic_qdisc_line() { printf 'fq limit 100000p flow_limit 1000p'; }
  net_nic_mtu() { printf '1500'; }
  net_sysctl_value() {
    case "${1}" in
      net.ipv4.tcp_notsent_lowat) printf '131072' ;;
      fs.file-max) printf '2097152' ;;
      *) printf '' ;;
    esac
  }
  net_nginx_worker_rlimit_text() { printf '65535 / 1048576'; }
  net_nginx_master_limitnofile() { printf '1048576'; }
  net_haproxy_maxconn() { printf '20000'; }
  net_cc_distribution() { printf 'bbr1=37 cubic=0'; }

  local output=""
  output="$(net_stack_text)"
  printf '%s\n' "${output}" | grep -q '内核:            7.0.3-joeyblog-bbrv3'
  printf '%s\n' "${output}" | grep -q '拥塞控制:        bbr1'
  printf '%s\n' "${output}" | grep -q 'tcp_bbr 模块:    version 3'
  printf '%s\n' "${output}" | grep -q '默认 qdisc:      fq'
  printf '%s\n' "${output}" | grep -q '出网网卡 qdisc:  fq limit 100000p'
  printf '%s\n' "${output}" | grep -q 'MTU:             1500'
  printf '%s\n' "${output}" | grep -q 'tcp_notsent_lowat: 131072'
  printf '%s\n' "${output}" | grep -q 'fs.file-max:     2097152'
  printf '%s\n' "${output}" | grep -q 'nginx worker_connections / worker_rlimit_nofile:  65535 / 1048576'
  printf '%s\n' "${output}" | grep -q 'nginx master LimitNOFILE:  1048576'
  printf '%s\n' "${output}" | grep -q 'haproxy maxconn: 20000'
  printf '%s\n' "${output}" | grep -q '已建立连接拥塞算法分布:  bbr1=37 cubic=0'

  [[ "$(net_stack_state)" == "ok" ]]

  # 非 bbr 系 → fail（diagnose 里计入失败）
  net_current_cc() { printf 'cubic'; }
  [[ "$(net_stack_state)" == "fail" ]]

  load_functions
}

# §7.3 BBR 内核开关
run_bbr_kernel_switch_case() {
  local output=""
  local workdir=""
  local joey_called=0

  [[ "$(normalize_net_bbr_kernel_value 'y')" == "joey" ]]
  [[ "$(normalize_net_bbr_kernel_value 'none')" == "none" ]]

  local output=""
  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
normalize_net_bbr_kernel_value maybe
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q '只能是 joey 或 none'

  # install_network_optimization 在 NET_BBR_KERNEL=none 时跳过内核安装
  ENABLE_NET_OPT="yes"
  NET_BBR_KERNEL="none"
  install_joey_bbrv3_kernel_if_needed() {
    joey_called=$((joey_called + 1))
  }
  available_cc() { printf 'reno cubic bbr1'; }
  supports_default_qdisc() { return 0; }
  bbr_v3_active() { return 1; }
  modprobe() { :; }
  workdir="$(mktemp -d)"
  NET_SYSCTL_CONF="${workdir}/net.conf"
  NET_HELPER_PATH="${workdir}/helper.sh"
  NET_SERVICE_FILE="${workdir}/svc.service"
  backup_path() { :; }
  systemctl() { :; }
  sysctl() { return 0; }
  log_success() { :; }

  install_network_optimization

  [[ "${joey_called}" -eq 0 ]]
  [[ -x "${NET_HELPER_PATH}" ]]
  [[ -f "${NET_SERVICE_FILE}" ]]
  rm -rf "${workdir}"
  load_functions
}

run_ipv6_links_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults

  SERVER_IP="203.0.113.30"
  SERVER_IP6="2408:8120::1234"
  NODE_LABEL_PREFIX="HKG"
  REALITY_UUID="11111111-1111-1111-1111-111111111111"
  REALITY_SNI="www.stanford.edu"
  REALITY_TARGET="www.stanford.edu:443"
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

  # 7 条链接，v6 节点地址带 []
  [[ "$(grep -c '^vless://' <(vless_links_text))" -eq 7 ]]
  vless_links_text > "${workdir}/links.txt"
  grep -qF "vless://${REALITY_UUID}@[2408:8120::1234]:443" "${workdir}/links.txt"
  grep -q "HKG-REALITY-V6" "${workdir}/links.txt"
  grep -q "vless://${XHTTP_UUID}@\[2408:8120::1234\]:443" "${workdir}/links.txt"
  # 节点 7 的 downloadSettings.address 是 IPv6（URL 编码后是 %22%5B...%5D%22）
  grep -qF 'address%22%3A%22%5B2408%3A8120%3A%3A1234%5D%22' "${workdir}/links.txt"
  grep -q "HKG-XHTTP-SPLIT-CDN-REALITY-V6" "${workdir}/links.txt"

  # 输出文件有节点 6 / 节点 7
  write_output_file
  assert_contains '## 节点 6' "${OUTPUT_FILE}"
  assert_contains '## 节点 7' "${OUTPUT_FILE}"
  assert_contains '\[2408:8120::1234\]（Reality）' "${OUTPUT_FILE}"

  # SERVER_IP6 为空时回到 5 条
  SERVER_IP6=""
  [[ "$(grep -c '^vless://' <(vless_links_text))" -eq 5 ]]

  # guess_server_ip6：非全局单播返回空
  ip() {
    case "${1}" in
      -6) printf '2606:4700:4700::1111 from ::1 via ... src fe80::1 dev eth0' ;;
      *) printf '' ;;
    esac
  }
  [[ -z "$(guess_server_ip6)" ]]
  ip() {
    case "${1}" in
      -6) printf '2606:4700:4700::1111 from 2606:4700::1 via ... src 2408:8120::1234 dev eth0' ;;
      *) printf '' ;;
    esac
  }
  [[ "$(guess_server_ip6)" == "2408:8120::1234" ]]

  rm -rf "${workdir}"
  load_functions
}

run_haproxy_bind_v4v6_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  HAPROXY_CONFIG="${workdir}/haproxy.cfg"
  reset_feature_defaults
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/assets/v3"
  NGINX_TLS_PORT="8443"

  write_haproxy_config

  assert_contains 'bind :::443 v4v6' "${HAPROXY_CONFIG}"
  assert_absent '^ *bind :443$' "${HAPROXY_CONFIG}"

  rm -rf "${workdir}"
  load_functions
}

run_h3_nginx_listen_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  NGINX_CONF_DIR="${workdir}/conf.d"
  NGINX_CONFIG_FILE="${NGINX_CONF_DIR}/xtun.conf"
  mkdir -p "${NGINX_CONF_DIR}"
  reset_feature_defaults
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/assets/v3"
  XHTTP_LOCAL_PORT="8001"
  NGINX_TLS_PORT="8443"
  TLS_CERT_FILE="/etc/ssl/xtun/cert.pem"
  TLS_KEY_FILE="/etc/ssl/xtun/key.pem"
  CERT_MODE="existing"
  nginx_version_at_least() { return 0; }
  stub_h3_capability_ready

  # 条件满足：quic 监听 + Alt-Svc
  nginx_v3_capable() { return 0; }
  write_nginx_config
  assert_contains 'listen 443 quic reuseport;' "${NGINX_CONFIG_FILE}"
  assert_contains "Alt-Svc 'h3=" "${NGINX_CONFIG_FILE}"
  assert_contains 'ma=86400' "${NGINX_CONFIG_FILE}"

  # 有 IPv6 时加 [::]:443
  SERVER_IP6="2408:8120::1234"
  write_nginx_config
  assert_contains 'listen \[::\]:443 quic reuseport;' "${NGINX_CONFIG_FILE}"

  # 条件不满足：整段关闭
  SERVER_IP6=""
  nginx_v3_capable() { return 1; }
  h3_refresh_decision
  write_nginx_config
  assert_absent 'quic reuseport' "${NGINX_CONFIG_FILE}"
  assert_absent 'Alt-Svc' "${NGINX_CONFIG_FILE}"
  [[ -n "$(h3_disabled_reason)" ]]

  # 自签名证书同样关闭
  nginx_v3_capable() { return 0; }
  CERT_MODE="self-signed"
  certificate_capability_report() { printf 'self-signed|fixture'; }
  h3_refresh_decision
  [[ -n "$(h3_disabled_reason)" ]]
  write_nginx_config
  assert_absent 'quic reuseport' "${NGINX_CONFIG_FILE}"

  rm -rf "${workdir}"
  load_functions
}

run_h3_links_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults

  SERVER_IP="203.0.113.30"
  NODE_LABEL_PREFIX="HKG"
  REALITY_UUID="11111111-1111-1111-1111-111111111111"
  REALITY_SNI="www.stanford.edu"
  REALITY_TARGET="www.stanford.edu:443"
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
  stub_h3_capability_ready

  # 5 + 2 条 H3 链接
  [[ "$(grep -c '^vless://' <(vless_links_text))" -eq 7 ]]
  vless_links_text > "${workdir}/links.txt"
  grep -qF 'HKG-XHTTP-TLS-H3' "${workdir}/links.txt"
  grep -qF "vless://${XHTTP_UUID}@203.0.113.30:443" "${workdir}/links.txt"
  grep -qF 'alpn=h3' "${workdir}/links.txt"
  grep -qF 'sni=cdn.example.com' "${workdir}/links.txt"
  grep -qF 'HKG-XHTTP-SPLIT-CDN-H3' "${workdir}/links.txt"
  # split 节点下行 alpn=h3 且地址是 SERVER_IP
  grep -qF 'alpn%22%3A%5B%22h3%22%5D' "${workdir}/links.txt"

  # 模块缺失时回到 5 条
  nginx_v3_capable() { return 1; }
  h3_refresh_decision
  [[ "$(grep -c '^vless://' <(vless_links_text))" -eq 5 ]]

  rm -rf "${workdir}"
  load_functions
}
