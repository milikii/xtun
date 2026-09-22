# shellcheck shell=bash

# W03：参数存在性、校验与公开命令契约的回归。
# 这里钉的是「用户给的东西不会被吞掉、重解释或静默降级」：无值开关不吞参、
# 互斥开关不看顺序、非法地址进不到 state/config、推荐的修复命令真的收参数。

# `--no-ipv6` 是无值开关，而且「明确禁用」必须和「没给」分开记：
# 探测到 IPv6 也不能把它再打开，草稿里的地址也不能。
run_install_no_ipv6_case() {
  local workdir=""
  local output=""
  local args=""
  local order=""

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  reset_feature_defaults

  SERVER_IP="203.0.113.13"
  SERVER_IP_PRESENCE="absent"
  SERVER_IP6=""
  SERVER_IP6_PRESENCE="absent"
  ENABLE_WARP=""
  ENABLE_NET_OPT=""

  # 单独使用、紧邻别的开关：不能吞掉下一个参数
  parse_install_args --disable-warp --no-ipv6 --enable-net-opt
  [[ "${ENABLE_WARP}" == "no" ]]
  [[ "${ENABLE_NET_OPT}" == "yes" ]]
  [[ -z "${SERVER_IP6}" ]]
  [[ "${SERVER_IP6_PRESENCE}" == "disabled" ]]

  # 显式地址：记为 provided，且不会被当成无值开关
  SERVER_IP6_PRESENCE="absent"
  parse_install_args --server-ip6=2a01:7e01::1
  [[ "${SERVER_IP6}" == "2a01:7e01::1" ]]
  [[ "${SERVER_IP6_PRESENCE}" == "provided" ]]

  # 每个方向都要报冲突，不能最后一个赢
  for order in "--no-ipv6 --server-ip6 2a01:7e01::1" "--server-ip6 2a01:7e01::1 --no-ipv6"; do
    args="${order}"
    if output="$(bash <<ISOLATED 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
parse_install_args ${args}
ISOLATED
)"; then
      printf '[fail] 互斥参数应当报错：%s\n' "${order}" >&2
      return 1
    fi
    grep -q '互相冲突' <<< "${output}"
  done

  # 草稿里的 IPv6 不能越过 --no-ipv6；探测结果也不行
  INSTALL_DRAFT_FILE="${workdir}/draft.env"
  printf 'SERVER_IP6=2a01:dead::1\n' > "${INSTALL_DRAFT_FILE}"
  load_install_draft_file
  [[ "${SERVER_IP6}" == "2a01:dead::1" ]]
  parse_install_args --no-ipv6
  [[ "${SERVER_IP6_PRESENCE}" == "disabled" ]]

  NON_INTERACTIVE=1
  NODE_LABEL_PREFIX="HKG"
  REALITY_UUID="11111111-1111-1111-1111-111111111111"
  REALITY_SNI="reality.example.com"
  REALITY_TARGET="reality.example.com:443"
  REALITY_SHORT_ID="abcd1234"
  XHTTP_UUID="22222222-2222-2222-2222-222222222222"
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/edge"
  CERT_MODE="self-signed"
  ENABLE_WARP="no"
  ENABLE_NET_OPT="no"
  NGINX_MAIN_MANAGED="no"
  ROUTE_BLOCK_CN="no"
  guess_server_ip6() { printf '2a01:7e01::9999'; }
  prepare_install_inputs
  [[ -z "${SERVER_IP6}" ]]

  # 显式给出地址时不再探测（探测被调到会留下记录）
  : > "${workdir}/guess.log"
  guess_server_ip() { printf 'called\n' >> "${workdir}/guess.log"; printf '198.51.100.99'; }
  SERVER_IP_PRESENCE="absent"
  SERVER_IP=""
  parse_install_args --server-ip=198.51.100.7
  prepare_install_inputs
  [[ "${SERVER_IP}" == "198.51.100.7" ]]
  [[ ! -s "${workdir}/guess.log" ]]
}

# 方向相反的无值开关，两个顺序都必须报冲突（install 与 change-warp）。
run_switch_conflict_case() {
  local output=""
  local args=""

  for args in "--enable-warp --disable-warp" "--disable-warp --enable-warp"; do
    if output="$(bash <<ISOLATED 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
parse_install_args ${args}
ISOLATED
)"; then
      printf '[fail] install 互斥开关应当报错：%s\n' "${args}" >&2
      return 1
    fi
    grep -q '互相冲突' <<< "${output}"
  done

  for args in "--enable-warp --disable-warp" "--disable-warp --enable-warp"; do
    if output="$(bash <<ISOLATED 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
declare -A local_request=()
init_change_warp_request local_request
parse_change_warp_args local_request ${args}
ISOLATED
)"; then
      printf '[fail] change-warp 互斥开关应当报错：%s\n' "${args}" >&2
      return 1
    fi
    grep -q '互相冲突' <<< "${output}"
  done

  # nginx 主配置开关同样处理
  if output="$(bash <<ISOLATED 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
parse_install_args --manage-nginx-main --no-manage-nginx-main
ISOLATED
)"; then
    printf '[fail] --manage-nginx-main 冲突未报错\n' >&2
    return 1
  fi
  grep -q '互相冲突' <<< "${output}"
}

# 地址校验：明显非法的输入必须在写盘之前被拒。
run_address_validation_case() {
  local output=""
  local field=""
  local bad_value=""

  assert_command_succeeds is_ipv4 "203.0.113.9"
  assert_command_succeeds is_ipv4 "255.255.255.255"
  assert_command_fails is_ipv4 "not-an-ip"
  assert_command_fails is_ipv4 "999.999.999.999"
  assert_command_fails is_ipv4 "1.2.3"
  assert_command_fails is_ipv4 "1.2.3.4.5"
  assert_command_fails is_ipv4 "1.2.3.256"
  assert_command_fails is_ipv4 ""

  assert_command_succeeds is_ipv6_address "2a01:7e01::1"
  assert_command_succeeds is_ipv6_address "::1"
  assert_command_succeeds is_ipv6_address "2001:db8:0:0:0:0:0:1"
  assert_command_succeeds is_ipv6_address "::ffff:192.168.0.1"
  assert_command_fails is_ipv6_address "2a01:7e01::zzzz"
  assert_command_fails is_ipv6_address "1:2:3:4:5:6:7"
  assert_command_fails is_ipv6_address "1:2:3:4:5:6:7:8:9"
  assert_command_fails is_ipv6_address "2a01:::1"
  assert_command_succeeds is_global_ipv6 "2a01:7e01::1"
  assert_command_fails is_global_ipv6 "fe80::1"
  assert_command_fails is_global_ipv6 "fd00::1"

  # 合法组合通过
  if ! output="$(bash <<ISOLATED 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
ENABLE_WARP="no"
SERVER_IP="203.0.113.13"
SERVER_IP6="2a01:7e01::1"
REALITY_SNI="reality.example.com"
REALITY_TARGET="reality.example.com:443"
XHTTP_DOMAIN="cdn.example.com"
XHTTP_PATH="/assets/v3"
validate_install_inputs
ISOLATED
)"; then
    printf '[fail] 合法地址组合被拒：%s\n' "${output}" >&2
    return 1
  fi

  for field in SERVER_IP SERVER_IP6 REALITY_TARGET; do
    case "${field}" in
      SERVER_IP) bad_value="999.999.999.999" ;;
      SERVER_IP6) bad_value="fe80::1" ;;
      REALITY_TARGET) bad_value="999.999.999.999:443" ;;
    esac
    if output="$(bash <<ISOLATED 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
ENABLE_WARP="no"
SERVER_IP="203.0.113.13"
SERVER_IP6="2a01:7e01::1"
REALITY_SNI="reality.example.com"
REALITY_TARGET="reality.example.com:443"
XHTTP_DOMAIN="cdn.example.com"
XHTTP_PATH="/assets/v3"
${field}='${bad_value}'
validate_install_inputs
ISOLATED
)"; then
      printf '[fail] 非法 %s 未被拒：%s\n' "${field}" "${bad_value}" >&2
      return 1
    fi
  done
}

# 证书模式：规范值、快捷编号、历史数字别名的往返都不能改语义。
run_cert_mode_roundtrip_case() {
  local mode=""
  local choice=""
  local output=""

  for mode in self-signed existing acme-dns-cf acme-http; do
    choice="$(cert_mode_choice_value "${mode}")"
    output="$(
      CERT_MODE=""
      NON_INTERACTIVE=0
      prompt_cert_mode_selection cert self-signed <<< "${choice}" >/dev/null
      printf '%s' "${CERT_MODE}"
    )"
    [[ "${output}" == "${mode}" ]]
    [[ "$(validate_cert_mode_value "${mode}")" == "${mode}" ]]
  done

  # 历史 CLI 数字：2/3 → existing，4 → acme-dns-cf，5 → acme-http，含义不变
  [[ "$(normalize_cert_mode 2)" == "existing" ]]
  [[ "$(normalize_cert_mode 3)" == "existing" ]]
  [[ "$(normalize_cert_mode 4)" == "acme-dns-cf" ]]
  [[ "$(normalize_cert_mode 5)" == "acme-http" ]]
  [[ "$(cert_mode_choice_value "existing")" == "2" ]]
  [[ "$(cert_mode_choice_value "acme-dns-cf")" == "3" ]]
  [[ "$(cert_mode_choice_value "acme-http")" == "4" ]]
  output="$(show_cert_mode_menu)"
  [[ "${output}" == *'3. ACME DNS (Cloudflare)'* && "${output}" == *'4. ACME HTTP'* ]]

  # 交互路径：显示的名称回车后还是同一个规范值
  output="$(bash <<ISOLATED 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
NON_INTERACTIVE=0
printf '\n' | { prompt_cert_mode_selection "TLS 证书模式序号" "acme-dns-cf" >/dev/null; printf '%s' "\${CERT_MODE}"; }
ISOLATED
)"
  [[ "${output}" == "acme-dns-cf" ]]
}

# 诊断与 README 推荐的两条修复命令必须真的被解析并进入工作流；
# 非法输入必须在任何写入之前失败。
run_fix_command_dispatch_case() {
  local workdir=""
  local output=""

  workdir="$(mktemp -d)"
  load_functions
  generation_case_setup "${workdir}"

  SCRIPT_LOCK_FILE="${workdir}/xtun.lock"
  OP_LOG_DIR="${workdir}"
  OP_LOG_FILE="${workdir}/operations.log"
  BACKUP_ROOT="${workdir}/backups"
  BACKUP_DIR=""

  need_root() { :; }
  ensure_debian_family() { :; }
  load_current_install_context() { NGINX_MAIN_MANAGED="${STUB_MANAGED:-no}"; }
  remove_legacy_managed_paths() { :; }
  ensure_xray_user() { :; }
  write_state_file() { :; }
  finish_managed_change() { :; }
  apply_managed_runtime_update() { printf 'APPLIED\n' >> "${workdir}/applied.log"; generation_commit; }
  install_network_optimization() { printf 'NETOPT %s|%s\n' "${ENABLE_NET_OPT}" "${NET_BBR_KERNEL}" >> "${workdir}/netopt.log"; }

  # apply-config --manage-nginx-main：翻转接管并走一次重新生成
  STUB_MANAGED="no"
  run_cli_command apply-config --non-interactive --manage-nginx-main
  [[ "${NGINX_MAIN_MANAGED}" == "yes" ]]
  assert_contains "APPLIED" "${workdir}/applied.log"

  # 停止接管：只有拿到可信原件才允许把状态翻回去
  STUB_MANAGED="yes"
  NGINX_MAIN_RESTORE_RESULT=""
  restore_nginx_main_config() { NGINX_MAIN_RESTORE_RESULT="restored"; }
  run_cli_command apply-config --non-interactive --no-manage-nginx-main
  [[ "${NGINX_MAIN_MANAGED}" == "no" ]]

  # apply-net-opt --bbr-kernel none：跳过第三方内核，仍然应用网络优化
  NET_BBR_KERNEL=""
  ENABLE_NET_OPT="no"
  run_cli_command apply-net-opt --non-interactive --bbr-kernel none
  [[ "${ENABLE_NET_OPT}" == "yes" ]]
  [[ "${NET_BBR_KERNEL}" == "none" ]]
  assert_contains "NETOPT yes|none" "${workdir}/netopt.log"

  NET_BBR_KERNEL=""
  run_cli_command apply-net-opt --non-interactive --bbr-kernel=joey
  [[ "${NET_BBR_KERNEL}" == "joey" ]]

  # 没有可信原件时不许假装「已停止接管」
  if output="$(bash <<ISOLATED 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source "${ROOT_DIR}/tests/common.sh"
source "${ROOT_DIR}/tests/cases_generation.sh"
load_functions
generation_case_setup "${workdir}/unconfirmed"
need_root() { :; }
warn() { printf '%s\n' "\$*" >&2; }
load_current_install_context() { NGINX_MAIN_MANAGED="yes"; }
remove_legacy_managed_paths() { :; }
ensure_xray_user() { :; }
restore_nginx_main_config() { NGINX_MAIN_RESTORE_RESULT="unconfirmed"; }
apply_managed_runtime_update() { printf 'APPLIED\n' >> "${workdir}/applied-unconfirmed.log"; }
finish_managed_change() { :; }
run_cli_command apply-config --non-interactive --no-manage-nginx-main
ISOLATED
)"; then
    printf '[fail] 找不到原件时不应报成功\n' >&2
    return 1
  fi
  grep -q '找不到' <<< "${output}"
  [[ ! -e "${workdir}/applied-unconfirmed.log" ]]

  # 非法参数绝不触达写入
  if output="$(bash <<ISOLATED 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source "${ROOT_DIR}/tests/common.sh"
source "${ROOT_DIR}/tests/cases_generation.sh"
load_functions
generation_case_setup "${workdir}/invalid"
need_root() { :; }
ensure_debian_family() { :; }
load_current_install_context() { :; }
install_network_optimization() { printf 'TOUCHED\n' >> "${workdir}/touch.log"; }
run_cli_command apply-net-opt --non-interactive --bbr-kernel turbo
ISOLATED
)"; then
    printf '[fail] 非法 --bbr-kernel 应当失败\n' >&2
    return 1
  fi
  grep -q 'NET_BBR_KERNEL 只能是 joey 或 none' <<< "${output}"
  [[ ! -e "${workdir}/touch.log" ]]
  [[ ! -e "${workdir}/invalid/backups" && ! -e "${workdir}/invalid/xtun.lock" ]]
}

# 公开解析路径统一收 `--key value` 与 `--key=value`；缺值、无值开关带值、
# 敏感值直接明文都在执行前失败。
run_option_assignment_case() {
  local workdir=""
  local output=""
  local token=""
  local -A request=()

  workdir="$(mktemp -d)"
  load_functions
  printf '%s\n' "${TEST_WARP_PRIVATE_KEY}" > "${workdir}/warp-key.txt"

  parse_install_args --server-ip=198.51.100.7 --xhttp-path=/edge --node-label-prefix=hkg
  [[ "${SERVER_IP}" == "198.51.100.7" ]]
  [[ "${SERVER_IP_PRESENCE}" == "provided" ]]
  [[ "${XHTTP_PATH}" == "/edge" ]]
  [[ "${NODE_LABEL_PREFIX}" == "hkg" ]]

  XRAY_VERSION_REQUEST=""
  parse_upgrade_args --xray-version=v26.9.9
  [[ "${XRAY_VERSION_REQUEST}" == "v26.9.9" ]]

  init_change_warp_request request
  parse_change_warp_args request --warp-mtu=1280 --warp-endpoint=engage.cloudflareclient.com:2408
  [[ "${request[warp_mtu]}" == "1280" ]]
  [[ "${request[warp_endpoint]}" == "engage.cloudflareclient.com:2408" ]]

  # 内联值真的被解析器取到：非法值会在校验处报错
  if output="$(bash <<ISOLATED 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
sni_check_cmd --timeout=abc
ISOLATED
)"; then
    printf '[fail] --timeout=abc 应当失败\n' >&2
    return 1
  fi
  grep -q '必须是正整数' <<< "${output}"

  # 缺值：分离写法和内联写法都不能把空串带进流程
  for token in "--server-ip" "--server-ip="; do
    if output="$(bash <<ISOLATED 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
parse_install_args ${token}
ISOLATED
)"; then
      printf '[fail] %s 缺值应当失败\n' "${token}" >&2
      return 1
    fi
    grep -q '需要值' <<< "${output}"
  done

  # 无值开关不接受 = 值
  if output="$(bash <<ISOLATED 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
parse_install_args --no-ipv6=1
ISOLATED
)"; then
    printf '[fail] --no-ipv6=1 应当失败\n' >&2
    return 1
  fi
  grep -q '无值开关' <<< "${output}"

  # 敏感值：两种写法都只收 @文件；内联的明文同样拒绝
  parse_install_args "--warp-private-key=@${workdir}/warp-key.txt"
  [[ "${WARP_PRIVATE_KEY}" == "@${workdir}/warp-key.txt" ]]
  resolve_install_input_sources
  [[ "${WARP_PRIVATE_KEY}" == "${TEST_WARP_PRIVATE_KEY}" ]]

  if output="$(bash <<ISOLATED 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
parse_install_args --warp-private-key=direct-key
ISOLATED
)"; then
    printf '[fail] 明文敏感值应当失败\n' >&2
    return 1
  fi
  grep -q '不支持直接明文传值' <<< "${output}"

  # 未知项仍然报未知，不会被当成值吞掉
  if output="$(bash <<ISOLATED 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
parse_install_args --definitely-not-an-option value
ISOLATED
)"; then
    printf '[fail] 未知参数应当失败\n' >&2
    return 1
  fi
  grep -q '未知的 install 参数' <<< "${output}"
}
