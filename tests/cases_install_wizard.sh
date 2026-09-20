#!/usr/bin/env bash

# ------------------------------
# W05：新装 / 草稿恢复 / 重建向导
# 钉住「用户意图 = 请求对象」：任务识别、默认值、问答次数、草稿完整性、
# 凭据稳定性、依赖阶段与端口归属。真实安装链路由测试 VPS 实测覆盖。
# ------------------------------

install_wizard_write_state() {
  local state_file="${1}"
  local cert_file="${state_file}.cert.pem"
  local key_file="${state_file}.key.pem"

  # 重建会在确认前检查证书输入；夹具必须自带证书，不能借用宿主机部署。
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj /CN=cdn.example.com -addext subjectAltName=DNS:cdn.example.com \
    -keyout "${key_file}" -out "${cert_file}" >/dev/null 2>&1
  chmod 0600 "${key_file}"

  cat > "${state_file}" <<'EOF'
STATE_VERSION=2
XRAY_VERSION_REQUEST=latest-published
SERVER_IP=203.0.113.10
SERVER_IP6=
NODE_LABEL_PREFIX=HKG
REALITY_UUID=11111111-1111-1111-1111-111111111111
REALITY_SNI=reality.example.com
REALITY_TARGET=reality.example.com:443
REALITY_SHORT_ID=abcd1234
REALITY_PRIVATE_KEY=state-private-key
REALITY_PUBLIC_KEY=state-public-key
XHTTP_UUID=22222222-2222-2222-2222-222222222222
XHTTP_DOMAIN=cdn.example.com
XHTTP_PATH=/edge
XHTTP_VLESS_ENCRYPTION_ENABLED=no
XHTTP_ECH_CONFIG_LIST=
XHTTP_ECH_FORCE_QUERY=
XHTTP_XPADDING_ENABLED=no
CERT_MODE=existing
ENABLE_WARP=no
ENABLE_NET_OPT=yes
NET_BBR_KERNEL=joey
NGINX_MAIN_MANAGED=no
ROUTE_BLOCK_CN=no
EOF
  printf 'CERT_SOURCE_FILE=%q\nKEY_SOURCE_FILE=%q\n' "${cert_file}" "${key_file}" >> "${state_file}"
}

# 问答桩：记录提示顺序，值取给定默认值（相当于用户一路回车）。
run_install_preserves_existing_proxy_binaries_case() {
  local workdir=""

  load_functions
  workdir="$(mktemp -d)"
  apt-get() { printf '%s\n' "$*" >> "${workdir}/apt-calls"; }
  record_package_origin() { printf '%s\n' "${1}" >> "${workdir}/package-origins"; }
  command() {
    if [[ "${1:-}" == -v && ( "${2:-}" == nginx || "${2:-}" == haproxy ) ]]; then return 0; fi
    builtin command "$@"
  }
  install_packages > "${workdir}/result.log"
  if grep -Eq '(^|[[:space:]])(nginx|haproxy)([[:space:]]|$)' "${workdir}/apt-calls"; then return 1; fi
  assert_absent 'nginx\|haproxy' "${workdir}/package-origins"
  grep -q -- '--force-confold' "${workdir}/apt-calls"
  grep -q '保留已有 nginx' "${workdir}/result.log"
  grep -q '保留已有 haproxy' "${workdir}/result.log"
  unset -f apt-get record_package_origin command
  load_functions
}

run_install_invalid_cert_parse_case() {
  local workdir=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  printf '%s\n' '-----BEGIN CERTIFICATE-----' invalid '-----END CERTIFICATE-----' > "${workdir}/cert.pem"
  printf '%s\n' '-----BEGIN PRIVATE KEY-----' invalid '-----END PRIVATE KEY-----' > "${workdir}/key.pem"
  ROOT_DIR="${ROOT_DIR}" TEST_CERT_DIR="${workdir}" bash -c '
    set -Eeuo pipefail
    source <(sed '\''$d'\'' "${ROOT_DIR}/xtun.sh")
    CERT_MODE=existing
    CERT_SOURCE_FILE="${TEST_CERT_DIR}/cert.pem"
    KEY_SOURCE_FILE="${TEST_CERT_DIR}/key.pem"
    preflight_check_cert_pair
  ' > "${workdir}/result.log" 2>&1 || status=$?
  [[ "${status}" -ne 0 ]]
  grep -q '无法解析证书' "${workdir}/result.log"
}

install_wizard_stub_prompts() {
  local workdir="${1}"

  prompt_with_default() {
    local var_name="${1}"
    printf 'wd:%s\n' "${var_name}" >> "${workdir}/questions.txt"
    if [[ -n "${!var_name:-}" ]]; then
      return 0
    fi
    printf -v "${var_name}" '%s' "${3}"
  }
  prompt_yes_no() {
    local var_name="${1}"
    printf 'yn:%s\n' "${var_name}" >> "${workdir}/questions.txt"
    if [[ -n "${!var_name:-}" ]]; then
      return 0
    fi
    printf -v "${var_name}" '%s' "${3}"
  }
  prompt_cert_mode_selection() {
    printf 'wd:CERT_MODE\n' >> "${workdir}/questions.txt"
    if [[ -n "${CERT_MODE:-}" ]]; then
      return 0
    fi
    CERT_MODE="$(validate_cert_mode_value "${2}")" || exit 1
  }
  prompt_cert_mode_inputs() { :; }
  prompt_warp_settings() { :; }
}

run_install_task_selection_case() {
  local workdir=""
  local output=""
  local draft_file=""

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  STATE_FILE="${XRAY_CONFIG_DIR}/node-meta.env"
  draft_file="${workdir}/install-draft.env"
  INSTALL_DRAFT_FILE="${draft_file}"
  NON_INTERACTIVE=1

  # 没有 state、也没有草稿 → fresh
  INSTALL_TASK_REQUEST=""
  resolve_install_task
  [[ "${INSTALL_TASK}" == "fresh" ]]

  # 有 state、没有草稿、非交互 → rebuild（沿用当前安装，不生成新身份）
  install_wizard_write_state "${STATE_FILE}"
  INSTALL_TASK_REQUEST=""
  resolve_install_task
  [[ "${INSTALL_TASK}" == "rebuild" ]]
  [[ "${INSTALL_TASK_SOURCE}" == "auto" ]]

  # 有草稿、非交互、没显式任务 → 必须报错：不能静默继承上一轮输入
  printf 'INSTALL_DRAFT_SCHEMA=1\n' > "${draft_file}"
  if output="$(resolve_install_task 2>&1)"; then
    printf '[fail] 草稿存在时非交互安装应当要求显式任务\n' >&2
    return 1
  fi
  printf '%s' "${output}" | grep -q '检测到未完成的安装草稿'

  # 显式任务优先，且别名可用
  INSTALL_TASK_REQUEST="resume-draft"
  resolve_install_task
  [[ "${INSTALL_TASK}" == "resume" ]]
  [[ "${INSTALL_TASK_SOURCE}" == "cli" ]]

  # 任务不可用（没有 state 却说 rebuild）要报错，不能退化成全新安装
  STATE_FILE="${workdir}/missing-state.env"
  INSTALL_DRAFT_FILE="${workdir}/missing-draft.env"
  INSTALL_TASK_REQUEST="rotate"
  if output="$(resolve_install_task 2>&1)"; then
    printf '[fail] 缺少 state 时 rotate 应当报错\n' >&2
    return 1
  fi
  printf '%s' "${output}" | grep -q '当前不可用'

  # 未知任务名报错
  INSTALL_TASK_REQUEST="bogus"
  if output="$(resolve_install_task 2>&1)"; then
    printf '[fail] 未知任务名应当报错\n' >&2
    return 1
  fi
  printf '%s' "${output}" | grep -q '安装任务只能是'

  # 交互入口：默认任务排第一项，序号选择落到对应任务
  rm -f "${draft_file}"
  install_wizard_write_state "${STATE_FILE}"
  INSTALL_DRAFT_FILE="${draft_file}"
  NON_INTERACTIVE=0
  INSTALL_TASK_REQUEST=""
  INSTALL_TASK=""
  INSTALL_TASK_SOURCE=""
  # 这里不能用管道：管道的每一段都在子 shell 里跑，INSTALL_TASK 传不回本 shell。
  printf '1\n' > "${workdir}/answer.txt"
  prompt_install_task_selection < "${workdir}/answer.txt" > "${workdir}/menu.txt" 2>/dev/null
  output="$(<"${workdir}/menu.txt")"
  [[ "${INSTALL_TASK}" == "rebuild" ]]
  [[ "${INSTALL_TASK_SOURCE}" == "menu" ]]
  printf '%s' "${output}" | grep -q '按当前状态重建'
  printf '%s' "${output}" | grep -q '明确轮换凭据'

  # 有草稿时默认任务是「恢复」
  printf 'INSTALL_DRAFT_SCHEMA=1\n' > "${draft_file}"
  INSTALL_TASK=""
  INSTALL_TASK_SOURCE=""
  printf '1\n' > "${workdir}/answer.txt"
  prompt_install_task_selection < "${workdir}/answer.txt" >/dev/null 2>&1
  [[ "${INSTALL_TASK}" == "resume" ]]

  rm -rf "${workdir}"
  load_functions
}

run_install_new_defaults_case() {
  local workdir=""
  local state_file=""

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  STATE_FILE="${workdir}/node-meta.env"
  INSTALL_DRAFT_FILE="${workdir}/install-draft.env"
  NON_INTERACTIVE=1
  INSTALL_TASK_REQUEST="fresh"
  resolve_install_task
  install_wizard_stub_prompts "${workdir}"

  SERVER_IP="203.0.113.10"
  REALITY_SNI="reality.example.com"
  XHTTP_DOMAIN="cdn.example.com"
  TLS_CERT_FILE="${workdir}/cert.pem"
  TLS_KEY_FILE="${workdir}/key.pem"

  prepare_install_inputs > "${workdir}/summary.txt" 2> "${workdir}/error.txt"

  # D05 新装默认：可选高影响项一律关闭
  [[ "${ENABLE_NET_OPT}" == "no" ]]
  [[ "${ENABLE_WARP}" == "no" ]]
  [[ "${NGINX_MAIN_MANAGED}" == "no" ]]
  [[ "${ROUTE_BLOCK_CN}" == "no" ]]
  [[ "${XHTTP_ECH_ENABLED}" == "no" ]]
  [[ "${XHTTP_XPADDING_ENABLED}" == "no" ]]
  [[ "${NET_BBR_KERNEL}" == "none" ]]
  [[ -z "${SERVER_IP6}" ]]
  # VLESS Encryption 保持开启，且自动凭据已经生成
  [[ "${XHTTP_VLESS_ENCRYPTION_ENABLED}" == "yes" ]]
  [[ -n "${REALITY_UUID}" && -n "${REALITY_SHORT_ID}" && -n "${XHTTP_UUID}" && -n "${XHTTP_PATH}" ]]

  # 自动凭据只生成一次：再跑一遍准备流程不改变任何一项
  local reality_uuid="${REALITY_UUID}"
  local xhttp_path="${XHTTP_PATH}"
  install_ensure_identity_values
  [[ "${REALITY_UUID}" == "${reality_uuid}" ]]
  [[ "${XHTTP_PATH}" == "${xhttp_path}" ]]

  # 显式参数仍然能打开可选能力（默认值不是「禁止」）
  reset_feature_defaults
  ENABLE_WARP=""
  ENABLE_NET_OPT=""
  NGINX_MAIN_MANAGED=""
  XHTTP_ECH_ENABLED=""
  XHTTP_XPADDING_ENABLED=""
  NET_BBR_KERNEL=""
  install_apply_base_combo_defaults
  [[ "${ENABLE_WARP}" == "no" ]]

  ENABLE_WARP="yes"
  ENABLE_NET_OPT="yes"
  NET_BBR_KERNEL="joey"
  NGINX_MAIN_MANAGED="yes"
  XHTTP_ECH_ENABLED="yes"
  XHTTP_XPADDING_ENABLED="yes"
  prepare_install_inputs >/dev/null 2>&1 || true
  [[ "${ENABLE_WARP}" == "yes" ]]
  [[ "${NET_BBR_KERNEL}" == "joey" ]]
  [[ "${XHTTP_ECH_ENABLED}" == "yes" ]]
  [[ "${XHTTP_XPADDING_KEY}" == "${DEFAULT_XHTTP_XPADDING_KEY}" ]]

  # 旧 state 的显式选择在重建任务里原样保留
  state_file="${workdir}/state.env"
  install_wizard_write_state "${state_file}"
  STATE_FILE="${state_file}"
  INSTALL_TASK_REQUEST=""
  NON_INTERACTIVE=1
  resolve_install_task
  install_task_apply_context
  [[ "${ENABLE_NET_OPT}" == "yes" ]]
  [[ "${NET_BBR_KERNEL}" == "joey" ]]
  [[ "${ENABLE_WARP}" == "no" ]]
  [[ "${REALITY_UUID}" == "11111111-1111-1111-1111-111111111111" ]]

  rm -rf "${workdir}"
  load_functions
}

run_install_wizard_input_budget_case() {
  local workdir=""
  local original_read_line_or_cancel=""
  local input_lines=""

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  STATE_FILE="${workdir}/missing-state.env"
  INSTALL_DRAFT_FILE="${workdir}/install-draft.env"
  INSTALL_TASK_REQUEST="fresh"
  NON_INTERACTIVE=0
  resolve_install_task
  guess_server_ip() { printf '203.0.113.10'; }

  # 已有证书路径：标准托管位置放着证书/私钥，证书模式选 2（existing）
  mkdir -p "${SSL_DIR}"
  : > "${TLS_CERT_FILE}"
  : > "${TLS_KEY_FILE}"

  # 计数包装：仍然走真实的 prompt_with_default / read_line_or_cancel，
  # 只记录「问了什么、用户答了什么」。每个 prompt/确认都是一次用户输入。
  original_read_line_or_cancel="$(capture_function_definition read_line_or_cancel)"
  eval "${original_read_line_or_cancel/read_line_or_cancel ()/xtun_counted_read_line_or_cancel ()}"
  read_line_or_cancel() {
    printf 'read:%s\n' "${2}" >> "${workdir}/questions.txt"
    xtun_counted_read_line_or_cancel "$@"
  }
  local original_prompt_with_default=""
  original_prompt_with_default="$(capture_function_definition prompt_with_default)"
  eval "${original_prompt_with_default/prompt_with_default ()/xtun_counted_prompt_with_default ()}"
  prompt_with_default() {
    printf 'ask:%s\n' "${1}" >> "${workdir}/questions.txt"
    xtun_counted_prompt_with_default "$@"
  }

  # 干净环境 + 已有证书路径，一路接受默认值：
  # 地址确认 → 双栈（默认关） → SNI → target → CDN 域名 → 证书模式 → 证书路径
  # → 私钥路径 → 最终确认
  input_lines=$'\n\nreality.example.com\n\ncdn.example.com\n2\n\n\ny\n'
  # 重定向文件而不是管道：管道每一段都在子 shell 里，向导写入的变量传不回来。
  printf '%s' "${input_lines}" > "${workdir}/answers.txt"
  prepare_install_inputs < "${workdir}/answers.txt" \
    > "${workdir}/summary.txt" 2> "${workdir}/error.txt"

  [[ "$(grep -c '^read:' "${workdir}/questions.txt")" -le 9 ]]
  [[ "$(grep -c '^read:' "${workdir}/questions.txt")" -eq 9 ]]
  grep -q '^ask:SERVER_IP$' "${workdir}/questions.txt"
  grep -q '^ask:REALITY_SNI$' "${workdir}/questions.txt"
  grep -q '^ask:REALITY_TARGET$' "${workdir}/questions.txt"
  grep -q '^ask:XHTTP_DOMAIN$' "${workdir}/questions.txt"
  grep -q '^ask:CERT_MODE$' "${workdir}/questions.txt"
  # 双栈是基础问答里的直接选项，不再藏在 advanced 关键词后面
  grep -q '^read:是否启用 IPv6 直连双栈' "${workdir}/questions.txt"
  assert_absent '^ask:SERVER_IP6$' "${workdir}/questions.txt"
  # 自动值不占问答
  assert_absent '^ask:REALITY_UUID$' "${workdir}/questions.txt"
  assert_absent '^ask:REALITY_SHORT_ID$' "${workdir}/questions.txt"
  assert_absent '^ask:XHTTP_UUID$' "${workdir}/questions.txt"
  assert_absent '^ask:XHTTP_PATH$' "${workdir}/questions.txt"
  assert_absent '^ask:NODE_LABEL_PREFIX$' "${workdir}/questions.txt"
  # 顺序：地址 → 双栈 → SNI/target/域名 → 证书 → 最终确认
  [[ "$(grep -n '^ask:SERVER_IP$' "${workdir}/questions.txt" | cut -d: -f1)" \
    -lt "$(grep -n '^read:是否启用 IPv6 直连双栈' "${workdir}/questions.txt" | cut -d: -f1)" ]]
  [[ "$(grep -n '^read:是否启用 IPv6 直连双栈' "${workdir}/questions.txt" | cut -d: -f1)" \
    -lt "$(grep -n '^ask:REALITY_SNI$' "${workdir}/questions.txt" | cut -d: -f1)" ]]
  [[ "$(grep -n '^ask:REALITY_TARGET$' "${workdir}/questions.txt" | cut -d: -f1)" \
    -lt "$(grep -n '^ask:XHTTP_DOMAIN$' "${workdir}/questions.txt" | cut -d: -f1)" ]]
  [[ "$(grep -n '^ask:XHTTP_DOMAIN$' "${workdir}/questions.txt" | cut -d: -f1)" \
    -lt "$(grep -n '^ask:CERT_MODE$' "${workdir}/questions.txt" | cut -d: -f1)" ]]
  grep -q '^read:确认开始？' "${workdir}/questions.txt"
  # 摘要真的出现，确认页给出高级项入口
  grep -q '安装摘要' "${workdir}/summary.txt"
  # stdin 不是终端时不打印提示，所以提示文本从记录的调用参数上看。
  # 确认页必须明确告诉用户：输入 advanced 才能进高级选项，输入 back 才能改地址/域名/证书。
  grep -q '输入 advanced 进入高级选项' "${workdir}/questions.txt"
  grep -q '输入 back 改地址/域名/证书' "${workdir}/questions.txt"
  [[ "${CERT_SOURCE_FILE}" == "${TLS_CERT_FILE}" ]]
  [[ "${KEY_SOURCE_FILE}" == "${TLS_KEY_FILE}" ]]

  # 确认页回车 = 取消（EOF 也不会变成同意），不做任何修改
  : > "${workdir}/questions.txt"
  printf '%s' "${input_lines%y$'\n'}" > "${workdir}/answers.txt"
  # 取消走的是 die=exit，只能在子 shell 里验，否则会把整条用例一起带走。
  if ( prepare_install_inputs < "${workdir}/answers.txt" >/dev/null 2>&1 ); then
    printf '[fail] 默认确认必须是取消\n' >&2
    return 1
  fi

  rm -rf "${workdir}"
  load_functions
}

# 双栈必须是基础问答里的直接选项（2026-09-20 实测反馈）：
# 选 y 追问答地址并生效；回车/选 n 保持关闭且不再追问；选 y 但地址留空时重问。
run_install_dual_stack_prompt_case() {
  local workdir=""
  local idx=0
  local -a answers=()

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  : > "${workdir}/prompts.txt"

  # 直接驱动 prompt 层的输入，不经过真实终端：答案序列由用例控制。
  read_line_or_cancel() {
    printf '%s\n' "${2}" >> "${workdir}/prompts.txt"
    printf -v "${1}" '%s' "${answers[idx]}"
    idx=$((idx + 1))
  }
  guess_server_ip6() { printf ''; }

  # 明确选 y：追问地址并写入
  idx=0
  answers=("y" "2408:8120::1234")
  SERVER_IP6=""
  install_prompt_dual_stack
  [[ "${SERVER_IP6}" == "2408:8120::1234" ]]
  grep -q 'IPv6 直连双栈' "${workdir}/prompts.txt"
  grep -q '直连节点 IPv6' "${workdir}/prompts.txt"

  # 回车 = 默认 n：没有已保存地址时保持关闭，而且不追问地址
  idx=0
  answers=("")
  : > "${workdir}/prompts.txt"
  SERVER_IP6=""
  install_prompt_dual_stack
  [[ -z "${SERVER_IP6}" ]]
  [[ "$(wc -l < "${workdir}/prompts.txt")" -eq 1 ]]

  # 明确选 n：已有地址也被关掉，同样不追问地址
  idx=0
  answers=("n")
  : > "${workdir}/prompts.txt"
  SERVER_IP6="2408:8120::1234"
  install_prompt_dual_stack
  [[ -z "${SERVER_IP6}" ]]
  [[ "$(wc -l < "${workdir}/prompts.txt")" -eq 1 ]]

  # 选 y 但地址留空：不能静默变成关闭；重问到合法全局单播地址为止
  idx=0
  answers=("y" "" "2408:8120::5")
  SERVER_IP6=""
  : > "${workdir}/prompts.txt"
  install_prompt_dual_stack
  [[ "${SERVER_IP6}" == "2408:8120::5" ]]
  [[ "${idx}" -eq 3 ]]

  # 已有地址时默认 yes，回车沿用旧值（重建不会意外关掉已开的双栈）
  idx=0
  answers=("" "")
  SERVER_IP6="2408:8120::7"
  install_prompt_dual_stack
  [[ "${SERVER_IP6}" == "2408:8120::7" ]]

  rm -rf "${workdir}"
  load_functions
}

# 高级项菜单与逐项问答必须说清「是什么、有什么用」（2026-09-20 实测反馈：
# 到了确认页不知道 xpadding / H3 直连是什么，也不知道网络优化要不要换内核）。
run_install_advanced_menu_wording_case() {
  local output=""
  local prompts=""

  load_functions
  stub_side_effects

  # 菜单：每一项带一句说明；网络优化写明当前内核即可，换内核是可选项
  output="$(show_install_advanced_menu)"
  grep -q '高级设置（默认全部关闭' <<< "${output}"
  grep -q 'XHTTP xpadding：给 XHTTP 数据加随机长度填充，弱化包长特征' <<< "${output}"
  grep -q 'H3 直连：XHTTP 下行走 QUIC(UDP/443)' <<< "${output}"
  grep -q '网络优化：当前内核即可开 BBR+fq 与 sysctl/qdisc 调优；第三方内核可选' <<< "${output}"
  grep -q '0. 返回确认页' <<< "${output}"

  # 确认页入口：明确「输入 advanced 进入高级选项」「输入 back 改地址/域名/证书」
  prompts="$(capture_function_definition prompt_install_final_confirmation)"
  grep -q '输入 advanced 进入高级选项' <<< "${prompts}"
  grep -q '输入 back 改地址/域名/证书' <<< "${prompts}"

  # 逐项问答同样带解释：xpadding 的作用、H3 的条件、不换内核也能优化
  prompts="$(capture_function_definition prompt_install_advanced_item)"
  grep -q 'XHTTP xpadding（给数据加随机长度填充' <<< "${prompts}"
  grep -q '在当前内核开 BBR+fq 与 sysctl/qdisc 调优，不更换内核' <<< "${prompts}"
  grep -q '不装也保留当前内核的 BBR+fq 优化' <<< "${prompts}"
  grep -q 'XHTTP 下行走 QUIC/UDP 443' <<< "${prompts}"

  # 摘要也要能看出「不换内核」：选了网络优化但没选第三方内核时标注（当前内核）
  SERVER_IP="203.0.113.10"
  SERVER_IP6=""
  REALITY_SNI="reality.example.com"
  REALITY_TARGET="reality.example.com:443"
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/edge"
  CERT_MODE="self-signed"
  XHTTP_VLESS_ENCRYPTION_ENABLED="yes"
  XHTTP_ECH_ENABLED="no"
  XHTTP_XPADDING_ENABLED="no"
  NGINX_MAIN_MANAGED="no"
  ROUTE_BLOCK_CN="no"
  ENABLE_WARP="no"
  H3_INTENT="off"
  ENABLE_NET_OPT="yes"
  NET_BBR_KERNEL="none"
  grep -q '网络优化=开（当前内核）' <<< "$(install_summary_text)"
  NET_BBR_KERNEL="joey"
  grep -q '网络优化=开（BBR 内核=joey）' <<< "$(install_summary_text)"

  load_functions
}

# 2026-09-20 实测反馈两件事：
#   1. 高级项 9 回答 n 被误判成非法值——根因是调用方变量名 answer 被 prompt 函数
#      内部的同名局部变量遮蔽（prompt_yes_no 已改为内部前缀变量）。
#   2. 高级项 3 选 y 之后不该再追问四个 xpadding 参数，脚本应直接用默认值。
run_install_advanced_item_answer_case() {
  local workdir=""

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"

  # H3：n 是正常关闭，y 才打开；两种情况都不能报「H3 只能是 yes 或 no」
  H3_INTENT=off
  printf 'n\n' > "${workdir}/h3-no.txt"
  prompt_install_advanced_item 9 < "${workdir}/h3-no.txt" 2> "${workdir}/h3-no.err"
  [[ "${H3_INTENT}" == "off" ]]
  [[ ! -s "${workdir}/h3-no.err" ]]

  H3_INTENT=off
  printf 'y\n' > "${workdir}/h3-yes.txt"
  prompt_install_advanced_item 9 < "${workdir}/h3-yes.txt" 2> "${workdir}/h3-yes.err"
  [[ "${H3_INTENT}" == "on" ]]

  # xpadding：选 y 之后只读这一次输入，参数全部取默认值并打印出来
  : > "${workdir}/reads.txt"
  read_line_or_cancel() {
    printf 'read\n' >> "${workdir}/reads.txt"
    printf -v "${1}" '%s' "y"
  }
  XHTTP_XPADDING_ENABLED="no"
  XHTTP_XPADDING_KEY=""
  XHTTP_XPADDING_HEADER=""
  XHTTP_XPADDING_PLACEMENT=""
  XHTTP_XPADDING_METHOD=""
  prompt_install_advanced_item 3 > "${workdir}/xpadding.out" 2>&1
  [[ "${XHTTP_XPADDING_ENABLED}" == "yes" ]]
  [[ "${XHTTP_XPADDING_KEY}" == "${DEFAULT_XHTTP_XPADDING_KEY}" ]]
  [[ "${XHTTP_XPADDING_HEADER}" == "${DEFAULT_XHTTP_XPADDING_HEADER}" ]]
  [[ "${XHTTP_XPADDING_PLACEMENT}" == "${DEFAULT_XHTTP_XPADDING_PLACEMENT}" ]]
  [[ "${XHTTP_XPADDING_METHOD}" == "${DEFAULT_XHTTP_XPADDING_METHOD}" ]]
  [[ "$(wc -l < "${workdir}/reads.txt")" -eq 1 ]]
  grep -q "${DEFAULT_XHTTP_XPADDING_HEADER}" "${workdir}/xpadding.out"

  rm -rf "${workdir}"
  load_functions
}

run_install_identity_stability_case() {
  local workdir=""
  local state_file=""

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  state_file="${workdir}/state.env"
  install_wizard_write_state "${state_file}"
  STATE_FILE="${state_file}"
  INSTALL_DRAFT_FILE="${workdir}/install-draft.env"
  NON_INTERACTIVE=1

  # rebuild：沿用 state 里的身份，重试也不重新生成
  INSTALL_TASK_REQUEST="rebuild"
  resolve_install_task
  install_task_apply_context || return 1
  install_ensure_identity_values
  [[ "${REALITY_UUID}" == "11111111-1111-1111-1111-111111111111" ]]
  [[ "${REALITY_SHORT_ID}" == "abcd1234" ]]
  [[ "${XHTTP_UUID}" == "22222222-2222-2222-2222-222222222222" ]]
  [[ "${XHTTP_PATH}" == "/edge" ]]
  [[ "${REALITY_PRIVATE_KEY}" == "state-private-key" ]]
  install_ensure_identity_values
  [[ "${REALITY_UUID}" == "11111111-1111-1111-1111-111111111111" ]]
  [[ "${XHTTP_PATH}" == "/edge" ]]

  # rotate：身份重新生成一次，之后不再变
  INSTALL_TASK_REQUEST="rotate"
  resolve_install_task
  install_task_apply_context || return 1
  install_ensure_identity_values
  [[ "${REALITY_UUID}" != "11111111-1111-1111-1111-111111111111" ]]
  [[ "${REALITY_SHORT_ID}" != "abcd1234" ]]
  [[ "${XHTTP_PATH}" != "/edge" ]]
  [[ "${REALITY_PRIVATE_KEY}" != "state-private-key" ]]
  [[ -n "${REALITY_UUID}" && -n "${XHTTP_UUID}" && -n "${REALITY_SHORT_ID}" ]]
  local rotated_uuid="${REALITY_UUID}"
  local rotated_path="${XHTTP_PATH}"
  install_ensure_identity_values
  [[ "${REALITY_UUID}" == "${rotated_uuid}" ]]
  [[ "${XHTTP_PATH}" == "${rotated_path}" ]]
  # 地址、证书、组合项都不属于「身份」，rotate 不动它们
  [[ "${SERVER_IP}" == "203.0.113.10" ]]
  [[ "${CERT_MODE}" == "existing" ]]

  # 显式给出的凭据优先于 rotate 的重新生成
  INSTALL_TASK_REQUEST="rotate"
  resolve_install_task
  install_task_apply_context || return 1
  INSTALL_PROVIDED_VARS=" REALITY_UUID "
  REALITY_UUID="33333333-3333-3333-3333-333333333333"
  install_ensure_identity_values
  [[ "${REALITY_UUID}" == "33333333-3333-3333-3333-333333333333" ]]

  rm -rf "${workdir}"
  load_functions
}

run_install_generated_identity_reentry_case() {
  local workdir=""
  local reality_key=""
  local encryption=""
  local decryption=""

  load_functions
  stub_side_effects
  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  INSTALL_DRAFT_FILE="${workdir}/install-draft.env"
  INSTALL_TASK="fresh"
  INSTALL_CONFIRMED=1
  XHTTP_VLESS_ENCRYPTION_ENABLED="yes"
  install_ensure_identity_values
  write_install_draft_file
  generate_reality_keys_if_needed
  write_tls_assets() { :; }
  write_runtime_managed_files() { generate_xhttp_vless_encryption_if_needed; }
  write_xray_service() { :; }
  write_xray_logrotate_config() { :; }
  remove_legacy_managed_paths() { :; }
  write_install_managed_files
  reality_key="${REALITY_PRIVATE_KEY}"
  encryption="${XHTTP_VLESS_ENCRYPTION}"
  decryption="${XHTTP_VLESS_DECRYPTION}"
  [[ -n "${reality_key}" && -n "${encryption}" && -n "${decryption}" ]]

  # 不走失败 trap，丢掉原进程内存：安装写配置前的草稿必须已经包含生成的密钥对。
  load_functions
  stub_side_effects
  prepare_workspace "${workdir}"
  INSTALL_DRAFT_FILE="${workdir}/install-draft.env"
  INSTALL_TASK_REQUEST="resume"
  NON_INTERACTIVE=1
  resolve_install_task
  install_task_apply_context
  install_ensure_identity_values
  generate_reality_keys_if_needed
  generate_xhttp_vless_encryption_if_needed
  [[ "${REALITY_PRIVATE_KEY}" == "${reality_key}" ]]
  [[ "${XHTTP_VLESS_ENCRYPTION}" == "${encryption}" && "${XHTTP_VLESS_DECRYPTION}" == "${decryption}" ]]
  [[ "$(stat -c %a "${INSTALL_DRAFT_FILE}")" == 600 ]]
  rm -rf "${workdir}"
  load_functions
}

run_install_draft_schema_case() {
  local workdir=""
  local draft_file=""

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  draft_file="${workdir}/install-draft.env"
  INSTALL_DRAFT_FILE="${draft_file}"

  INSTALL_TASK="resume"
  INSTALL_TASK_SOURCE="draft"
  SERVER_IP="203.0.113.10"
  SERVER_IP6=""
  SERVER_IP6_PRESENCE="absent"
  NODE_LABEL_PREFIX="HKG"
  REALITY_SNI="reality.example.com"
  REALITY_TARGET="reality.example.com:443"
  REALITY_SHORT_ID="abcd1234"
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/edge"
  NET_BBR_KERNEL="joey"
  NGINX_MAIN_MANAGED="no"
  ROUTE_BLOCK_CN="yes"
  CERT_SOURCE_PEM_REF="@${workdir}/cert.pem"
  WARP_PROFILE_SOURCE_REF="@${workdir}/profile.conf"

  write_install_draft_file
  [[ "$(stat -c '%a' "${draft_file}")" == "600" ]]

  # schema / 来源 / 任务 / 更新时间齐全
  grep -q '^INSTALL_DRAFT_SCHEMA=' "${draft_file}"
  # write_state_kv 用 %q 转义：简单值不带引号，含特殊字符时才有。
  grep -qE "^INSTALL_DRAFT_TASK='?resume'?$" "${draft_file}"
  grep -qE "^INSTALL_DRAFT_SOURCE='?draft'?$" "${draft_file}"
  grep -q '^INSTALL_DRAFT_UPDATED_AT=' "${draft_file}"
  # 以前漏掉的五个选择
  grep -q '^SERVER_IP6=' "${draft_file}"
  grep -q '^SERVER_IP6_PRESENCE=' "${draft_file}"
  grep -q '^NET_BBR_KERNEL=' "${draft_file}"
  grep -q '^NGINX_MAIN_MANAGED=' "${draft_file}"
  grep -q '^ROUTE_BLOCK_CN=' "${draft_file}"
  grep -q '^WARP_PROFILE_SOURCE=' "${draft_file}"
  # 敏感内容只留间接引用
  grep -q '^CERT_SOURCE_PEM=.*@' "${draft_file}"

  # 恢复：草稿提供默认值
  SERVER_IP=""
  ROUTE_BLOCK_CN=""
  NET_BBR_KERNEL=""
  load_install_draft_file
  [[ "${SERVER_IP}" == "203.0.113.10" ]]
  [[ "${ROUTE_BLOCK_CN}" == "yes" ]]
  [[ "${NET_BBR_KERNEL}" == "joey" ]]
  [[ "${INSTALL_DRAFT_TASK}" == "resume" ]]

  # 但本次动作显式给出的值优先
  SERVER_IP=""
  INSTALL_PROVIDED_VARS=" SERVER_IP "
  SERVER_IP="198.51.100.7"
  apply_install_draft_file
  [[ "${SERVER_IP}" == "198.51.100.7" ]]
  [[ "${ROUTE_BLOCK_CN}" == "yes" ]]

  # --discard-draft 清掉草稿；与恢复草稿互斥
  need_root() { :; }
  ensure_debian_family() { :; }
  start_backup_session() { :; }
  install_draft_session_begin() { :; }
  resolve_install_task() { INSTALL_TASK="fresh"; }
  install_task_apply_context() { :; }
  resolve_install_input_sources() { :; }
  prepare_install_inputs() { INSTALL_CONFIRMED=1; }
  write_install_draft_file() { :; }
  validate_install_inputs() { :; }
  install_prepare_and_preflight() { :; }

  prepare_install_command --discard-draft --task fresh
  [[ ! -f "${draft_file}" ]]

  write_install_draft_file
  if ( prepare_install_command --discard-draft --task resume 2>/dev/null ); then
    printf '[fail] --discard-draft 不能和恢复草稿同时使用\n' >&2
    return 1
  fi

  rm -rf "${workdir}"
  load_functions
}

run_install_dependency_stage_case() {
  local workdir=""
  local output=""
  local expected_missing=""
  local apt_log=""
  local dependencies_ready=0

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  apt_log="${workdir}/apt.log"
  apt-get() {
    printf 'apt-get %s\n' "$*" >> "${apt_log}"
    [[ "${1}" != install ]] || dependencies_ready=1
    return 0
  }
  command() {
    case "${1:-}" in
      -v)
        case "${2:-}" in
          qrencode|socat) [[ "${dependencies_ready}" -eq 1 ]]; return ;;
          openssl|ip|ss|jq|curl|uuidgen|unzip|modprobe) return 0 ;;
        esac
        ;;
    esac
    builtin command "$@"
  }

  # 确认前只读：缺的工具列成「依赖准备后复检」，不调用 apt
  output="$(install_dependency_readonly_report)"
  printf '%s' "${output}" | grep -q '依赖准备后复检'
  printf '%s' "${output}" | grep -q 'qrencode'
  [[ ! -s "${apt_log}" ]]

  expected_missing="$(install_missing_dependency_packages)"
  printf '%s' "${expected_missing}" | grep -qx 'qrencode'
  # 探测命令齐全时不重复列出同一个包
  [[ "$(printf '%s\n' "${expected_missing}" | sort | uniq -d | wc -l)" -eq 0 ]]

  # 确认后：先准备最小的那部分依赖，再跑深预检
  run_install_preflight_checks() {
    printf 'preflight\n' >> "${workdir}/order.txt"
  }
  install_prepare_and_preflight
  grep -q 'apt-get install -y' "${apt_log}"
  grep -q 'qrencode' "${apt_log}"
  # 已就绪的工具不重复安装
  assert_absent 'apt-get install -y .*\(openssl\|jq\|curl\)' "${apt_log}"
  [[ "$(cat "${workdir}/order.txt")" == "preflight" ]]

  # acme-http（HTTP-01 standalone）要 socat：只有这个证书模式才把它列进探测表，
  # 并在最小依赖阶段装上，不能等到深预检才发现缺（实测 2026-09-20）。
  CERT_MODE="acme-http"
  dependencies_ready=0
  expected_missing="$(install_missing_dependency_packages)"
  printf '%s\n' "${expected_missing}" | grep -qx 'socat'
  output="$(install_dependency_readonly_report)"
  printf '%s' "${output}" | grep -q 'socat（socat）'
  : > "${apt_log}"
  : > "${workdir}/order.txt"
  install_prepare_and_preflight
  grep -q 'apt-get install -y .*socat' "${apt_log}"
  [[ "$(cat "${workdir}/order.txt")" == "preflight" ]]
  CERT_MODE=""
  dependencies_ready=1

  # 依赖准备失败：要说清软件包保留、托管状态未动，并且不再往下走深预检
  : > "${apt_log}"
  : > "${workdir}/order.txt"
  dependencies_ready=0
  apt-get() {
    printf 'apt-get %s\n' "$*" >> "${apt_log}"
    return 1
  }
  if install_prepare_and_preflight 2> "${workdir}/error.txt"; then
    printf '[fail] 依赖准备失败时不该继续\n' >&2
    return 1
  fi
  grep -q '软件包保留' "${workdir}/error.txt"
  grep -q '托管配置、state 与服务均未改动' "${workdir}/error.txt"
  [[ ! -s "${workdir}/order.txt" ]]

  # apt 返回成功但工具依然缺失，也不能进入深预检或应用配置。
  apt-get() { return 0; }
  if install_prepare_and_preflight 2> "${workdir}/missing-after-install.txt"; then
    return 1
  fi
  grep -q '依赖准备后仍缺少必要命令' "${workdir}/missing-after-install.txt"
  [[ ! -s "${workdir}/order.txt" ]]

  # 什么都不缺时一个包都不装
  : > "${apt_log}"
  install_missing_dependency_packages() { :; }
  run_install_preflight_checks() { printf 'preflight\n' >> "${workdir}/order.txt"; }
  install_prepare_and_preflight
  [[ ! -s "${apt_log}" ]]

  unset -f apt-get command run_install_preflight_checks install_missing_dependency_packages
  rm -rf "${workdir}"
  load_functions
}

run_install_rotate_path_case() {
  local workdir=""
  local value=""
  local index=0

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"

  # 轮换必须换出不同的值：候选池只有 10 个路径，直接随机会有 1/10 的机会不变。
  for ((index = 0; index < 50; index++)); do
    value="$(random_path "/api/v1/ping")"
    [[ "${value}" != "/api/v1/ping" ]]
  done
  # 没有排除值时就是普通候选
  [[ -n "$(random_path '')" ]]

  REALITY_UUID="11111111-1111-1111-1111-111111111111"
  REALITY_SHORT_ID="abcd1234"
  REALITY_PRIVATE_KEY="private-key"
  REALITY_PUBLIC_KEY="public-key"
  XHTTP_UUID="22222222-2222-2222-2222-222222222222"
  XHTTP_PATH="/api/v1/ping"
  XHTTP_VLESS_DECRYPTION="dec"
  XHTTP_VLESS_ENCRYPTION="enc"
  INSTALL_TASK="rotate"
  for ((index = 0; index < 20; index++)); do
    INSTALL_IDENTITY_ROTATED=0
    XHTTP_PATH="/api/v1/ping"
    install_ensure_identity_values
    [[ "${XHTTP_PATH}" != "/api/v1/ping" ]]
    [[ "${REALITY_UUID}" != "11111111-1111-1111-1111-111111111111" ]]
  done
  # 同一轮动作里不能换第二次：重入只会沿用刚生成的值
  # （基准值必须显式设回 /api/v1/ping，否则「新值 != 旧值」不等于「新值 != ping」）
  XHTTP_PATH="/api/v1/ping"
  INSTALL_IDENTITY_ROTATED=0
  install_ensure_identity_values
  value="${XHTTP_PATH}"
  [[ "${value}" != "/api/v1/ping" ]]
  install_ensure_identity_values
  [[ "${XHTTP_PATH}" == "${value}" ]]

  rm -rf "${workdir}"
  load_functions
}

run_install_rebuild_cert_source_case() {
  local workdir=""

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  mkdir -p "${SSL_DIR}"
  : > "${TLS_CERT_FILE}"
  : > "${TLS_KEY_FILE}"

  # 真实 state 只记证书模式，不记证书路径（state_file_text 不写这两个键）。
  install_wizard_write_state "${XRAY_CONFIG_DIR}/node-meta.env"
  sed -i '/^CERT_SOURCE_FILE=/d; /^KEY_SOURCE_FILE=/d' "${XRAY_CONFIG_DIR}/node-meta.env"
  install_wizard_stub_prompts "${workdir}"

  NON_INTERACTIVE=1
  INSTALL_TASK_REQUEST="rebuild"
  resolve_install_task
  install_task_apply_context

  # 证书已经在托管位置：重建回到托管路径，不再要求 --cert-file
  [[ "${CERT_SOURCE_FILE}" == "${TLS_CERT_FILE}" ]]
  [[ "${KEY_SOURCE_FILE}" == "${TLS_KEY_FILE}" ]]
  prepare_install_inputs >/dev/null 2>&1
  [[ "${INSTALL_CONFIRMED}" -eq 1 ]]

  # 托管文件不存在时不猜，留给只读检查/预检报真实原因
  rm -f "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"
  CERT_SOURCE_FILE=""
  KEY_SOURCE_FILE=""
  install_task_apply_context
  [[ -z "${CERT_SOURCE_FILE}" ]]
  [[ -z "${KEY_SOURCE_FILE}" ]]

  # 全新安装不走这条回退：上次留下的文件不能被当成这次的证书来源
  : > "${TLS_CERT_FILE}"
  : > "${TLS_KEY_FILE}"
  INSTALL_TASK_REQUEST="fresh"
  CERT_SOURCE_FILE=""
  KEY_SOURCE_FILE=""
  resolve_install_task
  install_task_apply_context
  [[ -z "${CERT_SOURCE_FILE}" ]]
  [[ -z "${KEY_SOURCE_FILE}" ]]

  rm -rf "${workdir}"
  load_functions
}

run_install_invalid_value_refill_case() {
  local workdir=""
  local idx=0
  local prompt_text=""
  local -a answers=()

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  : > "${workdir}/prompts.txt"

  # 第一次给非法值，第二次直接回车：应当回到上一次的合法值，而不是把刚被判错的
  # 内容当成默认值再交一遍（那样三次之后整轮安装会被取消，用户没有出路）。
  answers=("bad_sni!" "")
  read_line_or_cancel() {
    printf '%s\n' "${2}" >> "${workdir}/prompts.txt"
    printf -v "${1}" '%s' "${answers[idx]}"
    idx=$((idx + 1))
  }
  REALITY_SNI="www.stanford.edu"

  prompt_validated_value REALITY_SNI "REALITY 可见 SNI" "" ensure_reality_sni_format     2> "${workdir}/error.txt"

  grep -q '输入不合法' "${workdir}/error.txt"
  [[ "${idx}" -eq 2 ]]
  [[ "${REALITY_SNI}" == "www.stanford.edu" ]]
  # 重填提示里显示的是上一个合法值，不是一个会被再次判错的值
  [[ "$(sed -n '2p' "${workdir}/prompts.txt")" == *"www.stanford.edu"* ]]
  [[ "$(sed -n '2p' "${workdir}/prompts.txt")" != *"bad_sni!"* ]]

  rm -rf "${workdir}"
  load_functions
}

run_install_cert_path_refill_case() {
  local workdir=""
  local idx=0
  local -a answers=()

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  mkdir -p "${SSL_DIR}"
  : > "${TLS_CERT_FILE}"
  : > "${TLS_KEY_FILE}"
  : > "${workdir}/prompts.txt"

  # 第一次填一个不存在的证书路径；重填时必须再次问到路径，而不是只重问一次
  # 证书模式、把同一个坏路径原样再交一遍。
  answers=("2" "${workdir}/missing-cert.pem" "" "" "${TLS_CERT_FILE}" "")
  read_line_or_cancel() {
    printf '%s\n' "${2}" >> "${workdir}/prompts.txt"
    printf -v "${1}" '%s' "${answers[idx]}"
    idx=$((idx + 1))
  }

  install_prompt_cert_section 2> "${workdir}/error.txt"

  grep -q '证书设置不可用' "${workdir}/error.txt"
  [[ "${CERT_MODE}" == "existing" ]]
  [[ "${CERT_SOURCE_FILE}" == "${TLS_CERT_FILE}" ]]
  [[ "${KEY_SOURCE_FILE}" == "${TLS_KEY_FILE}" ]]
  [[ "${idx}" -eq 6 ]]

  rm -rf "${workdir}"
  load_functions
}

run_install_confirmation_boundary_case() {
  local workdir=""

  load_functions
  stub_side_effects
  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"

  OP_LOG_DIR="${workdir}/logs"
  OP_LOG_FILE="${OP_LOG_DIR}/operations.log"
  BACKUP_ROOT="${workdir}/backups"
  INSTALL_DRAFT_FILE="${workdir}/install-draft.env"
  SCRIPT_LOCK_FILE="${workdir}/xtun.lock"
  SCRIPT_LOCK_HELD=0
  SCRIPT_LOCK_DIR=""
  INSTALL_TASK_REQUEST="fresh"
  NON_INTERACTIVE=0

  need_root() { :; }
  ensure_debian_family() { :; }
  resolve_install_task() { INSTALL_TASK="fresh"; INSTALL_TASK_SOURCE="test"; }
  install_task_apply_context() { :; }
  resolve_install_input_sources() { :; }
  validate_install_inputs() { :; }
  install_prepare_and_preflight() { printf 'TRIPWIRE:preflight\\n'; }
  # 用户回答 n：向导在最终确认处取消，函数应停止且不进入修改边界。
  prepare_install_inputs() {
    INSTALL_CONFIRMED=0
    die "已取消本次安装，未做任何修改。"
  }

  if ( prepare_install_command --task fresh >/dev/null 2>&1 ); then
    printf '[fail] 安装最终确认取消后不应成功\n' >&2
    return 1
  fi
  assert_absent_path "${OP_LOG_DIR}" '安装取消不应创建操作日志'
  assert_absent_path "${BACKUP_ROOT}" '安装取消不应创建备份'
  assert_absent_path "${INSTALL_DRAFT_FILE}" '安装取消不应创建隐式草稿'
  assert_absent_path "${SCRIPT_LOCK_FILE}" '安装取消不应创建锁文件'
  assert_absent_path "${SCRIPT_LOCK_FILE}.d" '安装取消不应创建目录锁'
  [[ "${SCRIPT_LOCK_HELD}" -eq 0 ]]

  rm -rf "${workdir}"
  load_functions
}

run_install_lock_recheck_case() {
  local workdir=""

  load_functions
  stub_side_effects
  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  : > "${STATE_FILE}"

  INSTALL_TASK_REQUEST="fresh"
  NON_INTERACTIVE=1
  need_root() { :; }
  ensure_debian_family() { :; }
  resolve_install_task() { INSTALL_TASK="fresh"; INSTALL_TASK_SOURCE="test"; }
  install_task_apply_context() { :; }
  resolve_install_input_sources() { :; }
  prepare_install_inputs() { INSTALL_CONFIRMED=1; }
  validate_install_inputs() { :; }
  install_prepare_and_preflight() { printf 'TRIPWIRE:preflight\\n'; }
  start_backup_session() {
    printf 'changed-after-confirm\n' > "${STATE_FILE}"
    SCRIPT_LOCK_HELD=1
  }

  if ( prepare_install_command --non-interactive --task fresh >/dev/null 2>&1 ); then
    printf '[fail] 拿锁后现场变化不能继续使用旧确认\n' >&2
    return 1
  fi
  [[ "$(cat "${STATE_FILE}")" == 'changed-after-confirm' ]]

  rm -rf "${workdir}"
  load_functions
}

run_uninstall_confirmation_boundary_case() {
  local workdir=""

  load_functions
  stub_side_effects
  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"

  OP_LOG_DIR="${workdir}/logs"
  OP_LOG_FILE="${OP_LOG_DIR}/operations.log"
  BACKUP_ROOT="${workdir}/backups"
  SCRIPT_LOCK_FILE="${workdir}/xtun.lock"
  SCRIPT_LOCK_HELD=0
  SCRIPT_LOCK_DIR=""

  need_root() { :; }
  load_existing_state() { :; }

  if ( uninstall_cmd </dev/null >/dev/null 2>&1 ); then
    printf '[fail] 卸载 EOF 不能被当作确认\n' >&2
    return 1
  fi
  assert_absent_path "${OP_LOG_DIR}" '卸载取消不应创建操作日志'
  assert_absent_path "${BACKUP_ROOT}" '卸载取消不应创建备份'
  assert_absent_path "${SCRIPT_LOCK_FILE}" '卸载取消不应创建锁文件'
  assert_absent_path "${SCRIPT_LOCK_FILE}.d" '卸载取消不应创建目录锁'
  [[ "${SCRIPT_LOCK_HELD}" -eq 0 ]]

  rm -rf "${workdir}"
  load_functions
}

run_install_resource_ownership_case() {
  local workdir=""
  local output=""

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  HAPROXY_CONFIG="${workdir}/haproxy.cfg"
  NGINX_CONFIG_FILE="${workdir}/xtun.conf"
  XRAY_CONFIG_FILE="${workdir}/config.json"

  # 空闲
  ss() { :; }
  [[ "$(install_port_ownership_text tcp 443)" == "空闲" ]]

  # 有监听但拿不到归属：不能算成可用
  ss() { printf 'UNCONN 0 0 0.0.0.0:443 0.0.0.0:*\n'; }
  [[ "$(install_port_ownership_text udp 443)" == *"无法确认归属"* ]]

  # 外来进程占用：明说不会停止或接管
  ss() { printf 'UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("hysteria",pid=41,fd=7))\n'; }
  [[ "$(install_port_ownership_text udp 443)" == *hysteria* ]]
  [[ "$(install_port_ownership_text udp 443)" == *外来* ]]

  # 本脚本托管：托管配置存在 + 监听者是我们托管的服务
  : > "${HAPROXY_CONFIG}"
  ss() { printf 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("haproxy",pid=7,fd=5))\n'; }
  [[ "$(install_port_ownership_text tcp 443)" == *"本脚本托管"* ]]

  # 缺 ss：报告为未探测，不假装通过。宿主机装着 ss，所以把 command -v 也桩掉，
  # 否则这条分支只会在「碰巧没装 iproute2」的机器上被验到。
  unset -f ss
  command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "ss" ]]; then
      return 1
    fi
    builtin command "$@"
  }
  [[ "$(install_port_ownership_text tcp 443)" == "未探测"* ]]
  unset -f command

  # 显式开启，模块/证书满足，但 UDP 443 被外来占用：摘要必须明确拒绝。
  stub_h3_capability_ready
  unset -f h3_udp_ownership_state
  source "${ROOT_DIR}/lib/ui/core.sh"
  nginx_v3_capable() { return 0; }
  ss() { printf 'UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("hysteria",pid=41,fd=7))\n'; }
  output="$(install_resource_ownership_report)"
  printf '%s' "${output}" | grep -q 'UDP 443:.*hysteria.*外来'
  printf '%s' "${output}" | grep -q 'UDP 443 不能使用'

  # 未接管主配置：给出可执行的后续动作
  NGINX_MAIN_MANAGED="no"
  printf '%s' "${output}" | grep -q 'xtun apply-config --manage-nginx-main'

  unset -f ss h3_enabled
  rm -rf "${workdir}"
  load_functions
}

run_install_preflight_port_case() {
  local workdir=""
  local stderr=""

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  HAPROXY_CONFIG="${workdir}/haproxy.cfg"
  NGINX_CONFIG_FILE="${workdir}/xtun.conf"
  XRAY_CONFIG_FILE="${workdir}/config.json"

  # 空闲：放行
  ss() { :; }
  assert_command_succeeds preflight_check_port_443

  # 托管配置还在（重装）：放行，但要说明
  : > "${HAPROXY_CONFIG}"
  ss() { printf 'LISTEN 0 4096 *:443 *:* users:(("haproxy",pid=7,fd=5))\n'; }
  assert_command_succeeds preflight_check_port_443
  : > "${XRAY_CONFIG_FILE}"
  rm -f "${HAPROXY_CONFIG}"
  assert_command_succeeds preflight_check_port_443

  # 托管配置已不在、占用者还在：必须停下，并给出占用者与可执行命令。
  # 这正是 2026-09-14 测试 VPS 上 uninstall 后重装走到的分支。
  rm -f "${XRAY_CONFIG_FILE}"
  if stderr="$(preflight_check_port_443 2>&1 >/dev/null)"; then
    printf '[fail] 443 被外来 haproxy 占用时预检应当失败\n' >&2
    rm -rf "${workdir}"
    return 1
  fi
  [[ "${stderr}" == *haproxy* ]]
  [[ "${stderr}" == *"systemctl stop haproxy"* ]]
  [[ "${stderr}" != *"端口已被占用，请先释放端口或确认是否为当前脚本托管服务"* ]]

  # 非托管服务名：说清是谁占用，但不建议停一个我们不认识的服务
  ss() { printf 'LISTEN 0 4096 *:443 *:* users:(("someproxy",pid=9,fd=5))\n'; }
  if stderr="$(preflight_check_port_443 2>&1 >/dev/null)"; then
    printf '[fail] 443 被外来进程占用时预检应当失败\n' >&2
    rm -rf "${workdir}"
    return 1
  fi
  [[ "${stderr}" == *someproxy* ]]
  [[ "${stderr}" != *"systemctl stop"* ]]

  # 拿不到占用进程（非 root）：不假装通过，也不编造名字
  ss() { printf 'LISTEN 0 4096 *:443 *:*\n'; }
  if stderr="$(preflight_check_port_443 2>&1 >/dev/null)"; then
    printf '[fail] 看不到占用进程时预检应当失败\n' >&2
    rm -rf "${workdir}"
    return 1
  fi
  [[ "${stderr}" == *"看不到占用进程"* ]]

  # 缺 ss：报告未探测，不拦安装
  unset -f ss
  command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "ss" ]]; then
      return 1
    fi
    builtin command "$@"
  }
  assert_command_succeeds preflight_check_port_443
  unset -f command

  rm -rf "${workdir}"
  load_functions
}

run_install_summary_width_case() {
  local output=""
  local line=""

  load_functions
  stub_side_effects

  INSTALL_TASK="fresh"
  INSTALL_TASK_SOURCE="cli"
  SERVER_IP="203.0.113.10"
  SERVER_IP6=""
  REALITY_SNI="reality.example.com"
  REALITY_TARGET="reality.example.com:443"
  XHTTP_DOMAIN="cdn.example.com"
  XHTTP_PATH="/edge"
  CERT_MODE="existing"
  CERT_SOURCE_FILE="/etc/ssl/xtun/cert.pem"
  XHTTP_VLESS_ENCRYPTION_ENABLED="yes"
  XHTTP_ECH_ENABLED="no"
  XHTTP_XPADDING_ENABLED="no"
  ENABLE_NET_OPT="no"
  NGINX_MAIN_MANAGED="no"
  ROUTE_BLOCK_CN="no"
  ENABLE_WARP="no"

  output="$(install_summary_text)"

  while IFS= read -r line; do
    [[ "${#line}" -le 80 ]] || { printf '[fail] 摘要行超过 80 列：%s\n' "${line}" >&2; return 1; }
  done <<< "${output}"
  [[ "$(printf '%s\n' "${output}" | wc -l)" -le 24 ]]

  printf '%s' "${output}" | grep -q '安装摘要'
  printf '%s' "${output}" | grep -q '任务: 全新安装'
  printf '%s' "${output}" | grep -q '连接地址: 203.0.113.10'
  printf '%s' "${output}" | grep -q 'REALITY: SNI=reality.example.com target=reality.example.com:443'
  printf '%s' "${output}" | grep -q 'VLESS Encryption=开'
  printf '%s' "${output}" | grep -q 'WARP=关'
  printf '%s' "${output}" | grep -q '不会更换'

  load_functions
}

run_install_cli_menu_parity_case() {
  local workdir=""
  local cli_config=""
  local menu_config=""

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  install_wizard_write_state "${XRAY_CONFIG_DIR}/node-meta.env"
  INSTALL_DRAFT_FILE="${workdir}/install-draft.env"
  NON_INTERACTIVE=1
  install_wizard_stub_prompts "${workdir}"

  # CLI 入口：显式任务
  local original_state_file="${STATE_FILE}"
  local original_config_file="${XRAY_CONFIG_FILE}"
  STATE_FILE="${XRAY_CONFIG_DIR}/node-meta.env"
  XRAY_CONFIG_FILE="${workdir}/config-cli.json"
  reset_feature_defaults
  INSTALL_TASK_REQUEST="rebuild"
  resolve_install_task
  install_task_apply_context || return 1
  resolve_install_input_sources
  prepare_install_inputs >/dev/null
  cli_config="$(xray_config_text)"

  # 菜单入口：用户在同一台机器上选第一项（默认 = 按当前状态重建）
  XRAY_CONFIG_FILE="${workdir}/config-menu.json"
  reset_feature_defaults
  INSTALL_TASK_REQUEST=""
  INSTALL_TASK=""
  INSTALL_TASK_SOURCE=""
  printf '1\n' > "${workdir}/answer.txt"
  prompt_install_task_selection < "${workdir}/answer.txt" >/dev/null 2>&1
  [[ "${INSTALL_TASK}" == "rebuild" ]]
  install_task_apply_context || return 1
  resolve_install_input_sources
  prepare_install_inputs >/dev/null
  menu_config="$(xray_config_text)"

  [[ -n "${cli_config}" ]]
  [[ "${cli_config}" == "${menu_config}" ]]

  STATE_FILE="${original_state_file}"
  XRAY_CONFIG_FILE="${original_config_file}"
  rm -rf "${workdir}"
  load_functions
}

run_install_menu_task_dispatch_case() {
  local workdir=""
  local output=""
  local draft_file=""
  local menu_output=""
  local discard_index=""

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  STATE_FILE="${XRAY_CONFIG_DIR}/node-meta.env"
  draft_file="${workdir}/install-draft.env"
  INSTALL_DRAFT_FILE="${draft_file}"

  run_cli_command() { printf '%s\n' "$*" >> "${workdir}/calls.txt"; }

  # 全新机器：只有一项可选，默认就是它
  output="$(printf '\n' | menu_install_task 2>/dev/null)"
  grep -qx 'install --task fresh' "${workdir}/calls.txt"

  # 已有安装：默认「按当前状态重建」，序号 3 是轮换
  install_wizard_write_state "${STATE_FILE}"
  : > "${workdir}/calls.txt"
  printf '3\n' | menu_install_task >/dev/null 2>&1
  grep -qx 'install --task rotate' "${workdir}/calls.txt"

  # 有草稿：多出「丢弃草稿并重新安装」这一项，而且是显式动作
  printf 'INSTALL_DRAFT_SCHEMA=1\n' > "${draft_file}"
  : > "${workdir}/calls.txt"
  menu_output="$(printf '0\n' | menu_install_task 2>/dev/null)"
  printf '%s' "${menu_output}" | grep -q '丢弃草稿并重新安装'
  discard_index="$(printf '%s\n' "${menu_output}" | awk '/丢弃草稿/ {print $1}' | tr -d '.')"
  [[ -n "${discard_index}" ]]
  printf '%s\n' "${discard_index}" > "${workdir}/answer.txt"
  menu_install_task < "${workdir}/answer.txt" >/dev/null 2>&1
  grep -qx 'install --discard-draft --task fresh' "${workdir}/calls.txt"

  # 返回主菜单不触发任何安装
  : > "${workdir}/calls.txt"
  printf '0\n' | menu_install_task >/dev/null 2>&1
  [[ ! -s "${workdir}/calls.txt" ]]

  rm -rf "${workdir}"
  load_functions
}

# 重建/轮换读 state 时，本次动作显式给出的 CLI 值优先（D03/D09）。
run_install_rebuild_explicit_input_case() {
  local workdir=""

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  prepare_workspace "${workdir}"
  install_wizard_write_state "${XRAY_CONFIG_DIR}/node-meta.env"
  install_wizard_stub_prompts "${workdir}"

  NON_INTERACTIVE=1
  INSTALL_TASK_REQUEST="rebuild"
  resolve_install_task

  # 这次动作显式给出的值（相当于 --reality-target / --cert-mode / --xhttp-domain）
  INSTALL_PROVIDED_VARS=" REALITY_TARGET CERT_MODE XHTTP_DOMAIN CERT_SOURCE_FILE "
  REALITY_TARGET="198.51.100.9:8443"
  CERT_MODE="self-signed"
  XHTTP_DOMAIN="explicit.example.test"
  CERT_SOURCE_FILE="/tmp/explicit-cert.pem"
  install_task_apply_context
  [[ "${REALITY_TARGET}" == "198.51.100.9:8443" ]]
  [[ "${CERT_MODE}" == "self-signed" ]]
  [[ "${XHTTP_DOMAIN}" == "explicit.example.test" ]]
  [[ "${CERT_SOURCE_FILE}" == "/tmp/explicit-cert.pem" ]]

  # 没显式给的字段仍然沿用 state：state 是默认值来源，不是不存在
  [[ "${REALITY_SNI}" == "reality.example.com" ]]
  [[ "${REALITY_UUID}" == "11111111-1111-1111-1111-111111111111" ]]

  # rotate 走同一条路
  INSTALL_TASK_REQUEST="rotate"
  resolve_install_task
  INSTALL_PROVIDED_VARS=" REALITY_TARGET "
  REALITY_TARGET="198.51.100.10:8443"
  install_task_apply_context
  [[ "${REALITY_TARGET}" == "198.51.100.10:8443" ]]

  rm -rf "${workdir}"
  load_functions
}
