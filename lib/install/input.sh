# shellcheck shell=bash

# ------------------------------
# 安装输入与预检层
# 负责交互输入、参数规范化与安装前校验
# ------------------------------

# 下面每处 `X="$(normalize_... )"` 后面的 `|| exit 1` 都是必须的，别当成噪音删掉：
# 这些 normalize_/validate_ 函数在参数不合法时走的是 die，而 die 是 exit——
# 它跑在 $( ) 的子 shell 里，只能把那个子 shell 打死。错误信息照样印在 stderr 上，
# 但命令替换的结果是空串，赋值把变量留成空，然后函数一路跑完返回 0。
# 于是 `是否启用 WARP？ [y/n]` 那里手一抖打成 "maybe"，屏幕上闪一行错误，
# 安装照常做完、报成功，只是 WARP 静默没装。ENABLE_NET_OPT / xpadding / ECH /
# VLESS Encryption 全是同一个形状。
# errexit 兜不住：dispatch_cli_command 那里是 `... || status=$?`，
# 整棵动态调用树里的 errexit 都被豁免了。
# 纯赋值语句（含数组追加、拼接赋值）的退出码就是最后那个命令替换的退出码，
# 所以 `|| exit 1` 接得住；写成 `local X="$(...)"` 就接不住了（shellcheck SC2155）。
# ------------------------------
# 安装任务（D06）：全新安装 / 恢复失败安装 / 按当前状态重建 / 明确轮换凭据。
# 菜单与 CLI 只是入口不同：两者都往 INSTALL_TASK_REQUEST 填值，之后走同一条
# prepare/确认路径，所以同一组输入必然得到同一份规范配置。
# 有现存安装或有草稿时，交互入口先让用户选任务；非交互入口只接受显式 --task，
# 不会把「安装」读懂成「重新生成身份」（H06）。
# ------------------------------

install_task_ids() {
  printf '%s\n' fresh resume rebuild rotate
}

normalize_install_task_value() {
  local value=""

  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "${value}" in
    fresh|new|install) printf 'fresh' ;;
    resume|resume-draft|recover|recover-draft) printf 'resume' ;;
    rebuild|rebuild-current|reinstall|reinstall-current) printf 'rebuild' ;;
    rotate|rotate-credentials|rotate-identity) printf 'rotate' ;;
    *) die "安装任务只能是 fresh、resume、rebuild 或 rotate：${1:-}" ;;
  esac
}

install_task_label() {
  case "${1}" in
    fresh) printf '全新安装' ;;
    resume) printf '恢复失败的安装' ;;
    rebuild) printf '按当前状态重建' ;;
    rotate) printf '明确轮换凭据' ;;
    *) printf '未知任务' ;;
  esac
}

install_state_present() {
  [[ -f "${STATE_FILE}" ]]
}

install_draft_present() {
  [[ -f "${INSTALL_DRAFT_FILE}" ]]
}

install_task_available() {
  case "${1}" in
    fresh) return 0 ;;
    resume) install_draft_present ;;
    rebuild|rotate) install_state_present ;;
    *) return 1 ;;
  esac
}

install_task_available_hint() {
  case "${1}" in
    resume) printf '没有找到未完成的安装草稿：%s' "${INSTALL_DRAFT_FILE}" ;;
    rebuild|rotate) printf '没有找到当前安装状态：%s' "${STATE_FILE}" ;;
    *) printf '当前环境不支持该任务' ;;
  esac
}

install_task_availability_text() {
  case "${1}" in
    fresh) printf '没有现存安装，从探测开始收集。' ;;
    resume) printf '沿用草稿里的完整选择与已生成的凭据。' ;;
    rebuild) printf '沿用当前安装的设置与全部凭据。' ;;
    rotate) printf '沿用当前安装设置，UUID/shortId/路径/REALITY 密钥重新生成一次。' ;;
    *) printf '' ;;
  esac
}

install_task_default_id() {
  if install_draft_present; then
    printf 'resume'
    return 0
  fi
  if install_state_present; then
    printf 'rebuild'
    return 0
  fi
  printf 'fresh'
}

# 菜单展示顺序：默认任务放第一项，其余按固定顺序跟在后面。
install_task_selection_order() {
  local task=""
  local default_task=""

  default_task="$(install_task_default_id)"
  printf '%s\n' "${default_task}"
  while IFS= read -r task; do
    [[ "${task}" != "${default_task}" ]] || continue
    install_task_available "${task}" || continue
    printf '%s\n' "${task}"
  done < <(install_task_ids)
}

show_install_task_menu() {
  local task=""
  local index=0

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    return 0
  fi

  printf '\n安装任务:\n'
  while IFS= read -r task; do
    index=$((index + 1))
    printf '  %s. %s — %s\n' "${index}" "$(install_task_label "${task}")" "$(install_task_availability_text "${task}")"
  done < <(install_task_selection_order)
}

prompt_install_task_selection() {
  local answer=""
  local selection=""
  local task=""
  local default_task=""
  local -a tasks=()

  while IFS= read -r task; do
    tasks+=("${task}")
  done < <(install_task_selection_order)
  [[ "${#tasks[@]}" -gt 0 ]] || die "没有可用的安装任务。"

  default_task="${tasks[0]}"
  show_install_task_menu
  read_line_or_cancel answer "请选择任务 [1=$(install_task_label "${default_task}")]: " || return $?
  [[ -n "${answer}" ]] || answer="1"

  if [[ "${answer}" =~ ^[0-9]+$ ]]; then
    (( answer >= 1 && answer <= ${#tasks[@]} )) || die "任务序号超出范围：${answer}"
    selection="${tasks[answer - 1]}"
  else
    selection="$(normalize_install_task_value "${answer}")" || exit 1
  fi

  install_task_available "${selection}" || die "任务「$(install_task_label "${selection}")」当前不可用。"
  INSTALL_TASK="${selection}"
  INSTALL_TASK_SOURCE="${INSTALL_TASK_SOURCE:-menu}"
}

# 决定本次动作的任务类型。显式请求优先；交互入口让用户选；非交互入口只在
# 「没有草稿」的明确情形下自动沿用当前安装，其余情况直接报错要求显式选择。
resolve_install_task() {
  local request="${INSTALL_TASK_REQUEST:-}"

  INSTALL_TASK=""
  INSTALL_TASK_SOURCE=""

  if [[ -n "${request}" ]]; then
    INSTALL_TASK="$(normalize_install_task_value "${request}")" || exit 1
    INSTALL_TASK_SOURCE="cli"
    install_task_available "${INSTALL_TASK}" \
      || die "任务「$(install_task_label "${INSTALL_TASK}")」当前不可用：$(install_task_available_hint "${INSTALL_TASK}")"
    return 0
  fi

  if install_draft_present; then
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      die "检测到未完成的安装草稿：请用 --task resume 继续、--discard-draft 丢弃，或 --task rebuild/rotate 显式重来。"
    fi
    prompt_install_task_selection
    return 0
  fi

  if install_state_present; then
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      # 已有安装又没有草稿：沿用当前安装重建，不生成新身份（H06）。
      INSTALL_TASK="rebuild"
      INSTALL_TASK_SOURCE="auto"
      return 0
    fi
    prompt_install_task_selection
    return 0
  fi

  INSTALL_TASK="fresh"
  INSTALL_TASK_SOURCE="auto"
}

# 任务决定之后才读来源文件：恢复读草稿，重建/轮换读当前 state，
# 全新安装不读任何上一次输入。
install_task_apply_context() {
  case "${INSTALL_TASK}" in
    resume)
      apply_install_draft_file || return 1
      INSTALL_TASK_SOURCE="draft"
      ;;
    rebuild|rotate)
      install_load_existing_state_preserving_provided
      install_default_managed_cert_inputs
      INSTALL_TASK_SOURCE="${INSTALL_TASK_SOURCE:-state}"
      ;;
    fresh)
      INSTALL_TASK_SOURCE="${INSTALL_TASK_SOURCE:-auto}"
      ;;
  esac
  return 0
}

# 重建/轮换沿用当前安装的证书来源。state 只记证书模式、不记路径（路径不是秘密，
# 但托管位置里放的就是当时用的那一份）：existing 模式既没有显式参数、也没有草稿
# 路径时回到托管路径，否则非交互重建会卡在「请提供 --cert-file」（实测 2026-09-14
# 测试 VPS：Phase B 用现有证书装好之后，--task rebuild --non-interactive 直接失败）。
# 托管文件不存在时不做任何猜测，交给只读检查与深预检报出真实原因。
install_default_managed_cert_inputs() {
  [[ "${CERT_MODE:-}" == "existing" ]] || return 0

  if [[ -z "${CERT_SOURCE_FILE}" && -z "${CERT_SOURCE_PEM}" && -f "${TLS_CERT_FILE}" ]]; then
    CERT_SOURCE_FILE="${TLS_CERT_FILE}"
  fi
  if [[ -z "${KEY_SOURCE_FILE}" && -z "${KEY_SOURCE_PEM}" && -f "${TLS_KEY_FILE}" ]]; then
    KEY_SOURCE_FILE="${TLS_KEY_FILE}"
  fi
}

# 双栈直接开关（2026-09-20 实测反馈）：新装默认关闭，回车不会多出节点 6/7；
# 需要时在基础问答里直接选，不再要求用户先知道确认页的 advanced 关键词。
# 明确选 y 才要求地址；地址留空等于「说要开却没地址」，用必填校验当场重问，
# 不能静默退回关闭。已有地址（state / 草稿 / --server-ip6）作为默认值沿用。
install_prompt_dual_stack() {
  local enable=""
  local default_answer="n"

  [[ -z "${SERVER_IP6:-}" ]] || default_answer="y"
  prompt_yes_no enable "是否启用 IPv6 直连双栈（生成节点 6/7）？ [y/n]" "${default_answer}" || return $?
  enable="$(normalize_yes_no_value "SERVER_IP6_ENABLED" "${enable}")" || exit 1

  if [[ "${enable}" == "yes" ]]; then
    prompt_validated_value SERVER_IP6 "REALITY 直连节点 IPv6" \
      "${SERVER_IP6:-$(guess_server_ip6)}" ensure_server_ip6_required || return $?
  else
    SERVER_IP6=""
  fi
}

# 基础向导。顺序按 D06：连接地址 → 双栈 → SNI/target/domain → 证书 →
# 基础组合/高级项 → 影响确认。自动凭据不占基础问答，只在内存里生成一次。
prepare_install_inputs() {
  # 1) 连接地址：显式 CLI 输入（--server-ip）优先，不再探测也不再询问。
  # 校验放在输入位置：这个值以前完全不查，写入摘要、走到确认页，直到安装中途的
  # validate_install_inputs 才炸（实测 2026-09-14 测试 VPS：地址填成 bad_sni! 时，
  # 摘要和确认页都显示它，用户在「确认开始」之后才看到失败）。
  if [[ "${SERVER_IP_PRESENCE:-absent}" != "provided" ]]; then
    prompt_validated_value SERVER_IP "REALITY 直连节点地址或 IP" "$(guess_server_ip)" ensure_server_ip_format || return $?
  fi

  # IPv6 新装默认关闭（D05）：回车不会自动多出节点 6/7；但需要双栈时不再要求
  # 用户先知道确认页的 advanced 关键词——基础问答里直接问一次（实测 2026-09-20：
  # 日志只提示「输入 advanced」，用户找不到直接开启的入口）。state、草稿和
  # --server-ip6 里的显式选择照旧优先，advanced 入口继续保留。
  case "${SERVER_IP6_PRESENCE:-absent}" in
    disabled)
      SERVER_IP6=""
      ;;
    provided)
      ;;
    *)
      if [[ "${NON_INTERACTIVE}" -ne 1 ]]; then
        install_prompt_dual_stack || return $?
      fi
      ;;
  esac

  install_prompt_connection_names || return 1
  install_prompt_cert_section || return 1
  install_ensure_identity_values || return 1
  install_apply_base_combo_defaults || return 1

  install_readonly_prechecks || return 1
  prompt_install_final_confirmation
}

# SNI / target / CDN domain：逐项校验，格式错误就地重填，不把一次手误变成整轮重来。
install_prompt_connection_names() {
  prompt_validated_value REALITY_SNI "REALITY 可见 SNI" "${DEFAULT_REALITY_SNI}" ensure_reality_sni_format || return $?
  prompt_validated_value REALITY_TARGET "REALITY 目标地址 host:port" \
    "$(default_reality_target_for_sni "${REALITY_SNI}")" ensure_reality_target_format || return $?
  prompt_validated_value XHTTP_DOMAIN "XHTTP CDN 域名" "" ensure_xhttp_domain_format || return $?
}

install_prompt_cert_section() {
  local reason=""
  local attempt=0

  while [[ "${attempt}" -lt 3 ]]; do
    attempt=$((attempt + 1))
    prompt_cert_mode_selection "TLS 证书模式序号" "${CERT_MODE:-self-signed}" || return $?
    prompt_cert_mode_inputs || return $?
    reason="$(cert_input_files_readonly_reason)"
    if [[ -z "${reason}" ]]; then
      return 0
    fi
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      die "${reason}"
    fi
    warn "证书设置不可用：${reason}"
    install_discard_unusable_cert_inputs
  done

  die "${reason}"
}

# 重填之前把不可用的证书输入清掉。prepare_existing_cert_inputs 只要看到
# CERT_SOURCE_FILE/KEY_SOURCE_FILE 里有一个非空就直接返回，不清掉的话下一轮
# 只会再问一次证书模式，同一个坏路径原样提交，三次之后终止——用户没有机会改。
install_discard_unusable_cert_inputs() {
  local files_usable="yes"

  if [[ -n "${CERT_SOURCE_FILE}" && ( ! -f "${CERT_SOURCE_FILE}" || ! -r "${CERT_SOURCE_FILE}" ) ]]; then
    files_usable="no"
  fi
  if [[ -n "${KEY_SOURCE_FILE}" && ( ! -f "${KEY_SOURCE_FILE}" || ! -r "${KEY_SOURCE_FILE}" ) ]]; then
    files_usable="no"
  fi
  if [[ "${files_usable}" == "no" ]]; then
    CERT_SOURCE_FILE=""
    KEY_SOURCE_FILE=""
  fi
  # PEM 必须成对出现：只填了一半就一起清掉，重填时重新粘贴。
  if [[ -z "${CERT_SOURCE_PEM}" || -z "${KEY_SOURCE_PEM}" ]]; then
    CERT_SOURCE_PEM=""
    KEY_SOURCE_PEM=""
  fi
}

# 自动凭据（UUID / 短 ID / 路径 / 节点前缀）：每种只生成一次。
# 返回、重试、重建都不重新生成；只有 rotate 任务或高级项明确要求时才换新。
install_ensure_identity_values() {
  local var_name=""
  local previous_path=""

  if [[ "${INSTALL_TASK}" == "rotate" && "${INSTALL_IDENTITY_ROTATED:-0}" != "1" ]]; then
    # 轮换后路径必须真的不同：random_path 只有 10 个候选，直接随机会有 1/10 的
    # 机会「换了个寂寞」（实测 2026-09-14 测试 VPS）。
    previous_path="${XHTTP_PATH}"
    # 轮换的是「客户端要重新导入的那些凭据」：UUID、shortId、路径、REALITY 密钥对，
    # 以及 XHTTP 的 VLESS Encryption 认证对。地址、证书、组合项都不动。
    for var_name in REALITY_UUID REALITY_SHORT_ID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY \
      XHTTP_UUID XHTTP_PATH XHTTP_VLESS_DECRYPTION XHTTP_VLESS_ENCRYPTION; do
      install_var_provided "${var_name}" && continue
      printf -v "${var_name}" '%s' ""
    done
    # 只轮换一次：重试、重入、再次准备都不允许把刚生成的凭据又换掉。
    INSTALL_IDENTITY_ROTATED=1
    INSTALL_ROTATE_PREVIOUS_PATH="${previous_path}"
  fi

  [[ -n "${NODE_LABEL_PREFIX}" ]] || NODE_LABEL_PREFIX="$(default_node_label_prefix)" || return 1
  [[ -n "${REALITY_UUID}" ]] || REALITY_UUID="$(random_uuid)" || return 1
  [[ -n "${REALITY_SHORT_ID}" ]] || REALITY_SHORT_ID="$(random_hex 8)" || return 1
  [[ -n "${XHTTP_UUID}" ]] || XHTTP_UUID="$(random_uuid)" || return 1
  [[ -n "${XHTTP_PATH}" ]] || XHTTP_PATH="$(random_path "${INSTALL_ROTATE_PREVIOUS_PATH:-}")" || return 1
  NODE_LABEL_PREFIX="$(normalize_node_label_prefix "${NODE_LABEL_PREFIX}")" || exit 1
}

# 基础组合的默认值（D05）：VLESS Encryption 保持开，其余可选能力一律关；
# 旧 state/草稿里的显式选择原样保留。高级项在确认页的 advanced 入口调整。
install_apply_base_combo_defaults() {
  H3_INTENT="${H3_INTENT:-off}"
  XHTTP_VLESS_ENCRYPTION_ENABLED="${XHTTP_VLESS_ENCRYPTION_ENABLED:-${DEFAULT_XHTTP_VLESS_ENCRYPTION_ENABLED}}"
  XHTTP_VLESS_ENCRYPTION_ENABLED="$(normalize_yes_no_value "XHTTP_VLESS_ENCRYPTION_ENABLED" "${XHTTP_VLESS_ENCRYPTION_ENABLED}")" || exit 1

  XHTTP_ECH_ENABLED="${XHTTP_ECH_ENABLED:-$(if [[ -n "${XHTTP_ECH_CONFIG_LIST:-}" ]]; then printf 'yes'; else printf 'no'; fi)}"
  configure_xhttp_ech_from_toggle

  XHTTP_XPADDING_ENABLED="${XHTTP_XPADDING_ENABLED:-${DEFAULT_XHTTP_XPADDING_ENABLED}}"
  XHTTP_XPADDING_ENABLED="$(normalize_yes_no_value "XHTTP_XPADDING_ENABLED" "${XHTTP_XPADDING_ENABLED}")" || exit 1
  if [[ "${XHTTP_XPADDING_ENABLED}" == "yes" ]]; then
    apply_xhttp_xpadding_defaults
  fi

  ENABLE_NET_OPT="${ENABLE_NET_OPT:-no}"
  ENABLE_NET_OPT="$(normalize_yes_no_value "ENABLE_NET_OPT" "${ENABLE_NET_OPT}")" || exit 1
  if [[ -z "${NET_BBR_KERNEL}" ]]; then
    NET_BBR_KERNEL="none"
  fi
  NET_BBR_KERNEL="$(normalize_net_bbr_kernel_value "${NET_BBR_KERNEL}")" || exit 1

  NGINX_MAIN_MANAGED="${NGINX_MAIN_MANAGED:-no}"
  NGINX_MAIN_MANAGED="$(normalize_yes_no_value "NGINX_MAIN_MANAGED" "${NGINX_MAIN_MANAGED}")" || exit 1

  ROUTE_BLOCK_CN="${ROUTE_BLOCK_CN:-no}"
  ROUTE_BLOCK_CN="$(normalize_yes_no_value "ROUTE_BLOCK_CN" "${ROUTE_BLOCK_CN}")" || exit 1

  ENABLE_WARP="${ENABLE_WARP:-no}"
  ENABLE_WARP="$(normalize_yes_no_value "ENABLE_WARP" "${ENABLE_WARP}")" || exit 1
  if [[ "${ENABLE_WARP}" == "yes" ]]; then
    prompt_warp_settings
  fi
}

# xpadding 打开时补齐四项默认值（值本身仍可在高级项里改）。
apply_xhttp_xpadding_defaults() {
  XHTTP_XPADDING_KEY="${XHTTP_XPADDING_KEY:-${DEFAULT_XHTTP_XPADDING_KEY}}"
  XHTTP_XPADDING_HEADER="${XHTTP_XPADDING_HEADER:-${DEFAULT_XHTTP_XPADDING_HEADER}}"
  XHTTP_XPADDING_PLACEMENT="${XHTTP_XPADDING_PLACEMENT:-${DEFAULT_XHTTP_XPADDING_PLACEMENT}}"
  XHTTP_XPADDING_METHOD="${XHTTP_XPADDING_METHOD:-${DEFAULT_XHTTP_XPADDING_METHOD}}"
}

# 校验失败就重问；连续三次仍然非法才终止，避免非交互/输入耗尽时死循环。
prompt_validated_value() {
  local var_name="${1}"
  local prompt_text="${2}"
  local default_value="${3}"
  local validator="${4}"
  local last_valid_value="${!var_name:-}"
  local message=""
  local attempt=0
  local INPUT_FIELD_VALIDATOR="${validator}"

  while [[ "${attempt}" -lt 3 ]]; do
    attempt=$((attempt + 1))
    prompt_with_default "${var_name}" "${prompt_text}" "${default_value}" || return $?
    if message="$("${validator}" 2>&1 >/dev/null)"; then
      return 0
    fi
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      die "${message}"
    fi
    warn "输入不合法：${message}"
    # 重填要回到上一次的合法值。刚被判错的内容如果留在变量里，下一轮提示会把
    # 它当成默认值显示，用户回车就是原样再交一次同样的错，三次之后整轮安装终止
    # （2026-09-14 测试 VPS 实测：非法 SNI 后按回车只会连续报三次同样的错）。
    printf -v "${var_name}" '%s' "${last_valid_value}"
  done

  die "${message}"
}

# ------------------------------
# 确认前的只读检查、影响摘要与最终确认（D06/D07）
# 这一段只报告事实：不装包、不写文件、不假装检查通过。
# ------------------------------

# 依赖探测表：包名|命令。同一个包有多个命令时都列出来，缺任意一个都要准备。
install_dependency_probe_specs() {
  cat <<'EOF'
openssl|openssl
iproute2|ip
iproute2|ss
jq|jq
curl|curl
qrencode|qrencode
uuid-runtime|uuidgen
unzip|unzip
kmod|modprobe
EOF
  # HTTP-01（acme.sh standalone）会用到 socat，而深预检在它缺失时直接失败；
  # 只有 acme-http 模式才需要准备它（实测 2026-09-20：确认后才发现缺 socat，
  # 安装停在依赖准备后的深预检，其它包已经装了一半）。
  if [[ "${CERT_MODE:-}" == "acme-http" ]]; then
    printf 'socat|socat\n'
  fi
}

install_missing_dependency_packages() {
  local spec=""
  local package_name=""
  local probe_command=""
  local seen=" "

  while IFS='|' read -r package_name probe_command; do
    [[ -n "${package_name}" ]] || continue
    command -v "${probe_command}" >/dev/null 2>&1 && continue
    case "${seen}" in
      *" ${package_name} "*) continue ;;
    esac
    seen+="${package_name} "
    printf '%s\n' "${package_name}"
  done < <(install_dependency_probe_specs)
}

install_dependency_readonly_report() {
  local spec=""
  local package_name=""
  local probe_command=""
  local ready=""
  local missing=""
  local missing_packages=""
  local seen=" "

  while IFS='|' read -r package_name probe_command; do
    [[ -n "${package_name}" ]] || continue
    if command -v "${probe_command}" >/dev/null 2>&1; then
      ready+="${ready:+, }${probe_command}"
      continue
    fi
    missing+="${missing:+, }${probe_command}（${package_name}）"
    case "${seen}" in
      *" ${package_name} "*) continue ;;
    esac
    seen+="${package_name} "
    missing_packages+="${missing_packages:+, }${package_name}"
  done < <(install_dependency_probe_specs)

  printf '依赖状态（确认前只读检查，不改系统）:\n'
  printf '  已就绪: %s\n' "${ready:-无}"
  if [[ -n "${missing_packages}" ]]; then
    printf '  依赖准备后复检: %s\n' "${missing}"
    printf '  说明: 缺工具时相关检查不会被报告为通过；确认后先安装这些包再深预检。\n'
  else
    printf '  依赖准备后复检: 无\n'
  fi
}

# 端口归属：空闲 / 本脚本托管 / 外来占用 三种结论分开说。
# 判「本脚本托管」需要同时满足两条：监听进程是托管服务名，且对应的托管配置存在。
install_port_ownership_text() {
  local protocol="${1}"
  local port="${2}"
  local listeners=""
  local owners=""

  if ! command -v ss >/dev/null 2>&1; then
    printf '未探测（缺少 ss，依赖准备后复检）'
    return 0
  fi

  if [[ "${protocol}" == "tcp" ]]; then
    listeners="$(ss -ltnpH "( sport = :${port} )" 2>/dev/null || true)"
  else
    listeners="$(ss -lunpH "( sport = :${port} )" 2>/dev/null || true)"
  fi
  if [[ -z "${listeners}" ]]; then
    printf '空闲'
    return 0
  fi

  owners="$(printf '%s\n' "${listeners}" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | sort -u | tr '\n' '/')"
  owners="${owners%/}"
  if [[ -z "${owners}" ]]; then
    printf '被占用（无法确认归属，需要 root）'
    return 0
  fi

  if [[ -f "${HAPROXY_CONFIG}" || -f "${NGINX_CONFIG_FILE}" || -f "${XRAY_CONFIG_FILE}" ]]; then
    case "${owners}" in
      *xray*|*haproxy*|*nginx*) printf '被 %s 占用（本脚本托管，可复用）' "${owners}"; return 0 ;;
    esac
  fi

  printf '被 %s 占用（外来，不会停止或接管）' "${owners}"
}

install_resource_ownership_report() {
  local tcp443=""
  local tcp80=""
  local udp443=""
  local h3_text=""

  tcp443="$(install_port_ownership_text tcp 443)"
  tcp80="$(install_port_ownership_text tcp 80)"
  udp443="$(install_port_ownership_text udp 443)"

  printf '端口与资源归属:\n'
  printf '  TCP 443: %s\n' "${tcp443}"
  printf '  TCP 80: %s\n' "${tcp80}"
  printf '  UDP 443: %s\n' "${udp443}"

  h3_refresh_decision "${CERT_SOURCE_FILE:-${TLS_CERT_FILE}}" "${KEY_SOURCE_FILE:-${TLS_KEY_FILE}}"
  h3_text="$(h3_status_text)"
  printf '  H3: %s。\n' "${h3_text}"

  if [[ "${NGINX_MAIN_MANAGED:-no}" != "yes" ]]; then
    printf '  nginx 主配置: 不接管；worker_connections/fd 限额保持系统现状，\n'
    printf '               需要时执行 xtun apply-config --manage-nginx-main（会先展示原件与影响）。\n'
  fi

  install_takeover_report
}

# 安装前已存在、会被本次接管并在卸载时还原的托管路径。端口占用只能说明"有东西
# 在监听"，说明不了用户自己的 unit/核心/目录会被替换；这一项必须在确认前说清楚，
# 否则就是静默接管（D40）。
install_takeover_path_list() {
  local path=""
  local suffix=""

  for path in "${XRAY_SERVICE_FILE}" "${XRAY_BIN}" "${XRAY_ASSET_DIR}" \
    "${XRAY_CONFIG_DIR}" "${XRAY_LOG_DIR}" "${XRAY_STATE_DIR}"; do
    [[ -n "${path}" ]] || continue
    [[ -e "${path}" || -L "${path}" ]] || continue
    suffix=""
    if [[ "${path}" == "${XRAY_SERVICE_FILE}" ]]; then
      suffix="（$(service_enable_state "xray.service")/$(service_active_state "xray.service")）"
    fi
    printf '%s%s\n' "${path}" "${suffix}"
  done
}

install_takeover_report() {
  local list=""
  local line=""

  list="$(install_takeover_path_list)"
  [[ -n "${list}" ]] || return 0
  printf '  待接管（安装前已存在；卸载时会按登记还原）:\n'
  while IFS= read -r line; do
    printf '    %s\n' "${line}"
  done <<< "${list}"
}

install_readonly_prechecks() {
  log_step "确认前只读检查。"
  install_dependency_readonly_report
  install_resource_ownership_report
}

install_path_fingerprint() {
  local path="${1}"
  local entry=""

  printf 'path\t%s\n' "${path}"
  if [[ -L "${path}" ]]; then
    printf 'symlink\t%s\n' "$(readlink "${path}" 2>/dev/null || printf 'unreadable')"
    return 0
  fi
  if [[ -d "${path}" ]]; then
    printf 'directory\n'
    while IFS= read -r -d '' entry; do
      printf 'entry\t%s\n' "${entry#"${path}"/}"
      if [[ -L "${entry}" ]]; then
        printf 'link\t%s\n' "$(readlink "${entry}" 2>/dev/null || printf 'unreadable')"
      else
        printf 'sha256\t%s\n' "$(sha256sum "${entry}" 2>/dev/null | awk '{print $1}')"
      fi
    done < <(find "${path}" \( -type f -o -type l \) -print0 2>/dev/null | sort -z)
    return 0
  fi
  if [[ -f "${path}" ]]; then
    printf 'sha256\t%s\n' "$(sha256sum "${path}" 2>/dev/null | awk '{print $1}')"
    return 0
  fi
  printf 'absent\n'
}

install_environment_fingerprint() {
  local path=""
  local unit_name=""
  local -a paths=(
    "${STATE_FILE}"
    "${INSTALL_DRAFT_FILE}"
    "${XRAY_CONFIG_FILE}"
    "${HAPROXY_CONFIG}"
    "${NGINX_CONFIG_FILE}"
    "${NGINX_MAIN_CONFIG}"
    "${TLS_CERT_FILE}"
    "${TLS_KEY_FILE}"
    "${XRAY_BIN}"
    "${XRAY_ASSET_DIR}"
    "${SELF_COMMAND_PATH}"
    "${SELF_INSTALL_DIR}"
    "${XRAY_SERVICE_FILE}"
    "${NET_SERVICE_FILE}"
  )

  for path in "${paths[@]}"; do
    install_path_fingerprint "${path}"
  done
  printf 'tcp443\t%s\n' "$(install_port_ownership_text tcp 443)"
  printf 'tcp80\t%s\n' "$(install_port_ownership_text tcp 80)"
  printf 'udp443\t%s\n' "$(install_port_ownership_text udp 443)"
  for unit_name in xray.service haproxy.service nginx.service "${NET_SERVICE_NAME}"; do
    printf 'service\t%s\t%s\t%s\n' \
      "${unit_name}" \
      "$(service_active_state "${unit_name}")" \
      "$(service_enable_state "${unit_name}")"
  done
}

# 安装摘要：每个字段一行，最长 78 列，保证 80×24 终端不折行。
install_summary_line() {
  local text=""

  printf -v text '%s' "$*"
  if [[ "${#text}" -gt 78 ]]; then
    text="${text:0:77}…"
  fi
  printf '  %s\n' "${text}"
}

install_summary_text() {
  local vless_encryption_text=""
  local optional_text=""

  printf '安装摘要\n'
  install_summary_line "任务: $(install_task_label "${INSTALL_TASK}")（来源: ${INSTALL_TASK_SOURCE:-unknown}）"
  install_summary_line "连接地址: ${SERVER_IP}${SERVER_IP6:+；IPv6 ${SERVER_IP6}}"
  install_summary_line "REALITY: SNI=${REALITY_SNI} target=${REALITY_TARGET}"
  install_summary_line "XHTTP: 域名=${XHTTP_DOMAIN} 路径=${XHTTP_PATH}"
  install_summary_line "证书: ${CERT_MODE}$(install_summary_cert_detail)"
  vless_encryption_text="$(if [[ "${XHTTP_VLESS_ENCRYPTION_ENABLED}" == "yes" ]]; then printf '开'; else printf '关'; fi)"
  install_summary_line "基础组合: VLESS Encryption=${vless_encryption_text} ECH=$(yes_no_text "${XHTTP_ECH_ENABLED:-no}") xpadding=$(yes_no_text "${XHTTP_XPADDING_ENABLED:-no}")"
  optional_text="网络优化=$(yes_no_text "${ENABLE_NET_OPT:-no}")"
  if [[ "${ENABLE_NET_OPT:-no}" == "yes" ]]; then
    # 不换内核也是一次完整的网络优化：只有显式选 joey 才额外装第三方内核。
    if [[ "${NET_BBR_KERNEL}" == "joey" ]]; then
      optional_text+="（BBR 内核=joey）"
    else
      optional_text+="（当前内核）"
    fi
  fi
  install_summary_line "可选: ${optional_text} nginx主配置=$(yes_no_text "${NGINX_MAIN_MANAGED:-no}")"
  install_summary_line "      拦截回国=$(yes_no_text "${ROUTE_BLOCK_CN:-no}") WARP=$(yes_no_text "${ENABLE_WARP:-no}")"
  install_summary_line "H3: $(h3_intent_text)；应用前核对模块/证书/UDP，条件不足会失败并恢复。"
  install_summary_line "影响: 安装/更新依赖包；写入托管配置与服务单元；重启托管服务；写 state 与节点链接。"
  if [[ -n "$(install_takeover_path_list)" ]]; then
    install_summary_line "接管: 覆盖安装前已存在的托管路径，卸载时按登记还原（清单见上方端口与资源归属）。"
  fi
  install_summary_line "说明: 自动凭据（UUID/短ID/路径）本次只生成一次；重试与重建不会更换。"
  if [[ "${NGINX_MAIN_MANAGED:-no}" != "yes" ]]; then
    install_summary_line "说明: 未接管 nginx 主配置，连接数上限保持现状（见上方端口与资源归属）。"
  fi
}

install_summary_cert_detail() {
  case "${CERT_MODE:-}" in
    self-signed) printf '（自签名，不公网可信）' ;;
    existing)
      if [[ -n "${CERT_SOURCE_FILE:-}" ]]; then
        printf '（%s）' "${CERT_SOURCE_FILE}"
      else
        printf '（已提供 PEM）'
      fi
      ;;
    acme-dns-cf) printf '（ACME DNS Cloudflare，域名 %s）' "${XHTTP_DOMAIN:-}" ;;
    acme-http) printf '（ACME HTTP-01，域名 %s）' "${XHTTP_DOMAIN:-}" ;;
    *) printf '' ;;
  esac
}

yes_no_text() {
  if [[ "${1:-no}" == "yes" ]]; then
    printf '开'
  else
    printf '关'
  fi
}

show_install_advanced_menu() {
  cat <<'EOF'
高级设置（默认全部关闭；改完回到确认页，输入 0 返回）:
  1. IPv6 直连：为本机 IPv6 追加节点 6/7（双栈）
  2. XHTTP ECH：隐藏 CDN 上行真实 SNI（要求域名已有 ECH 记录）
  3. XHTTP xpadding：给 XHTTP 数据加随机长度填充，弱化包长特征
  4. 网络优化：当前内核即可开 BBR+fq 与 sysctl/qdisc 调优；第三方内核可选
  5. nginx 主配置接管：统一 worker_connections/fd 上限（先备份原件）
  6. 拦截回国流量：geoip:cn / geosite:cn 直接黑洞
  7. 选择性 WARP 出站：只让指定域名走 Cloudflare WARP
  8. 节点前缀与自动凭据：改链接名前缀，或自定义 UUID/短ID/路径
  9. H3 直连：XHTTP 下行走 QUIC(UDP/443)；需公网信任证书且 UDP 443 可用
  0. 返回确认页
EOF
}

prompt_install_advanced_settings() {
  local choice=""
  local INPUT_BACK_HANDLED=yes

  while true; do
    show_install_advanced_menu
    read_line_or_cancel choice "高级项选择（0 返回）: " || return $?
    case "${choice}" in
      ""|0|:back)
        return 0
        ;;
      1|2|3|4|5|6|7|8|9)
        prompt_install_advanced_item "${choice}"
        ;;
      *)
        warn "未知的高级项：${choice}"
        ;;
    esac
  done
}

prompt_install_advanced_item() {
  local item="${1}"
  local answer=""

  case "${item}" in
    1)
      prompt_validated_value SERVER_IP6 "REALITY 直连节点 IPv6（留空关闭双栈）" "${SERVER_IP6:-}" ensure_server_ip6_format || return $?
      ;;
    2)
      prompt_yes_no XHTTP_ECH_ENABLED "是否启用 XHTTP CDN 的 ECH（隐藏真实 SNI，要求域名已有 ECH 记录）？ [y/n]" "$(yes_no_value "${XHTTP_ECH_ENABLED:-no}")" || return $?
      configure_xhttp_ech_from_toggle
      ;;
    3)
      prompt_yes_no XHTTP_XPADDING_ENABLED "是否启用 XHTTP xpadding（给数据加随机长度填充，弱化包长特征）？ [y/n]" "$(yes_no_value "${XHTTP_XPADDING_ENABLED:-no}")" || return $?
      XHTTP_XPADDING_ENABLED="$(normalize_yes_no_value "XHTTP_XPADDING_ENABLED" "${XHTTP_XPADDING_ENABLED}")" || exit 1
      if [[ "${XHTTP_XPADDING_ENABLED}" == "yes" ]]; then
        # 默认参数是脚本的既定值，不再占四次问答（2026-09-20 实测反馈）；
        # 已有自定义值原样保留，需要改时走 --xhttp-xpadding-* 参数。
        apply_xhttp_xpadding_defaults
        log "xpadding 已按以下参数开启：placement=${XHTTP_XPADDING_PLACEMENT} header=${XHTTP_XPADDING_HEADER} key=${XHTTP_XPADDING_KEY} method=${XHTTP_XPADDING_METHOD}；需要自定义请用 --xhttp-xpadding-* 参数。"
      fi
      ;;
    4)
      prompt_yes_no ENABLE_NET_OPT "是否启用网络优化（在当前内核开 BBR+fq 与 sysctl/qdisc 调优，不更换内核）？ [y/n]" "$(yes_no_value "${ENABLE_NET_OPT:-no}")" || return $?
      ENABLE_NET_OPT="$(normalize_yes_no_value "ENABLE_NET_OPT" "${ENABLE_NET_OPT}")" || exit 1
      if [[ "${ENABLE_NET_OPT}" == "yes" ]]; then
        prompt_yes_no NET_BBR_KERNEL "是否额外安装 Joey BBRv3 第三方内核？（可选：不装也保留当前内核的 BBR+fq 优化） [y/n]" "$(if [[ "${NET_BBR_KERNEL}" == "joey" ]]; then printf 'y'; else printf 'n'; fi)" || return $?
        NET_BBR_KERNEL="$(normalize_net_bbr_kernel_value "${NET_BBR_KERNEL}")" || exit 1
      fi
      ;;
    5)
      prompt_yes_no NGINX_MAIN_MANAGED "是否接管 /etc/nginx/nginx.conf（连接数与 fd 限额主配置）？ [y/n]" "$(yes_no_value "${NGINX_MAIN_MANAGED:-no}")" || return $?
      NGINX_MAIN_MANAGED="$(normalize_yes_no_value "NGINX_MAIN_MANAGED" "${NGINX_MAIN_MANAGED}")" || exit 1
      ;;
    6)
      prompt_yes_no ROUTE_BLOCK_CN "是否拦截回国流量（geoip:cn / geosite:cn）？ [y/n]" "$(yes_no_value "${ROUTE_BLOCK_CN:-no}")" || return $?
      ROUTE_BLOCK_CN="$(normalize_yes_no_value "ROUTE_BLOCK_CN" "${ROUTE_BLOCK_CN}")" || exit 1
      ;;
    7)
      prompt_yes_no ENABLE_WARP "是否启用选择性 WARP 出站？ [y/n]" "$(yes_no_value "${ENABLE_WARP:-no}")" || return $?
      ENABLE_WARP="$(normalize_yes_no_value "ENABLE_WARP" "${ENABLE_WARP}")" || exit 1
      if [[ "${ENABLE_WARP}" == "yes" ]]; then
        prompt_warp_settings
      fi
      ;;
    8)
      prompt_with_default NODE_LABEL_PREFIX "导出链接使用的节点名前缀" "${NODE_LABEL_PREFIX:-}" || return $?
      NODE_LABEL_PREFIX="$(normalize_node_label_prefix "${NODE_LABEL_PREFIX}")" || exit 1
      read_line_or_cancel answer "是否自定义自动凭据（UUID/短ID/路径）？ [y/N]: " || return $?
      answer="$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')"
      if [[ "${answer}" == "y" || "${answer}" == "yes" ]]; then
        prompt_with_default REALITY_UUID "REALITY UUID" "${REALITY_UUID}" || return $?
        prompt_with_default REALITY_SHORT_ID "REALITY 短 ID" "${REALITY_SHORT_ID}" || return $?
        prompt_with_default XHTTP_UUID "XHTTP UUID" "${XHTTP_UUID}" || return $?
        prompt_with_default XHTTP_PATH "XHTTP 路径" "${XHTTP_PATH}" || return $?
      fi
      ;;
    9)
      answer=""
      prompt_yes_no answer "开启 H3 直连（XHTTP 下行走 QUIC/UDP 443，需要公网信任证书且 UDP 443 可用）？ [y/n]" "$(if [[ "${H3_INTENT:-off}" == on || "${H3_INTENT:-off}" == legacy-on ]]; then printf y; else printf n; fi)" || return $?
      answer="$(normalize_yes_no_value H3 "${answer}")" || return 1
      if [[ "${answer}" == yes ]]; then H3_INTENT=on; else H3_INTENT=off; fi
      ;;
  esac
}

yes_no_value() {
  if [[ "${1:-no}" == "yes" ]]; then
    printf 'y'
  else
    printf 'n'
  fi
}

# 一次最终确认：默认「否」，EOF 直接取消（D02）；advanced 打开高级项，back 回到地址/域名/证书。
prompt_install_final_confirmation() {
  local answer=""
  local INPUT_BACK_HANDLED=yes

  while true; do
    install_summary_text
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      log "非交互模式：按已给出的参数确认，不再询问。"
      INSTALL_CONFIRMED=1
      return 0
    fi

    read_line_or_cancel answer "确认开始？[y/N]（输入 advanced 进入高级选项；输入 back 改地址/域名/证书）: " || return $?
    case "${answer}" in
      y|Y|yes|YES)
        INSTALL_CONFIRMED=1
        return 0
        ;;
      advanced|a)
        prompt_install_advanced_settings
        ;;
      back|b)
        install_prompt_connection_names || return $?
        install_prompt_cert_section || return $?
        ;;
      :back)
        input_edit_previous_fields || return 1
        ;;
      ""|n|N|no|NO)
        INSTALL_CONFIRMED=0
        die "已取消本次安装，未做任何修改。"
        ;;
      *)
        warn "请输入 y 开始安装、n 取消，或输入 advanced 进入高级选项、back 改地址/域名/证书。"
        ;;
    esac
  done
}
configure_xhttp_ech_from_toggle() {
  local enabled=""

  enabled="$(normalize_yes_no_value "XHTTP_ECH_ENABLED" "${XHTTP_ECH_ENABLED:-$(if [[ -n "${XHTTP_ECH_CONFIG_LIST:-}" ]]; then printf 'yes'; else printf 'no'; fi)}")" || exit 1
  if [[ "${enabled}" == "yes" ]]; then
    XHTTP_ECH_CONFIG_LIST="${XHTTP_ECH_CONFIG_LIST:-https://dns.alidns.com/dns-query}"
    return
  fi

  XHTTP_ECH_CONFIG_LIST=""
  XHTTP_ECH_FORCE_QUERY=""
}

default_reality_target_for_sni() {
  local sni="${1}"
  [[ -n "${sni}" ]] || return 0
  printf '%s:443' "${sni}"
}

normalize_net_bbr_kernel_value() {
  local value=""

  value="$(printf '%s' "${1}" | tr '[:upper:]' '[:lower:]')"
  case "${value}" in
    y|yes|joey) printf 'joey' ;;
    n|no|none|stock) printf 'none' ;;
    *) die "NET_BBR_KERNEL 只能是 joey 或 none。" ;;
  esac
}

normalize_yes_no_value() {
  local field_name="${1}"
  local raw_value="${2}"
  local value=""

  value="$(printf '%s' "${raw_value}" | tr '[:upper:]' '[:lower:]')"
  # prompt_yes_no 接受 y/yes/n/no/on/off/1/0/true/false，规范化必须同样收下这些
  # 拼写：以前只有 y/yes/n/no，用户在 y/n 提示里答「1」会被判成非法值直接终止。
  case "${value}" in
    y|yes|enable|enabled|on|1|true)
      printf 'yes'
      ;;
    n|no|disable|disabled|off|0|false)
      printf 'no'
      ;;
    *)
      die "${field_name} 只能是 yes 或 no。"
      ;;
  esac
}

normalize_warp_target_mode() {
  local value=""

  value="$(printf '%s' "${1}" | tr '[:upper:]' '[:lower:]')"
  case "${value}" in
    yes|enable|enabled)
      printf 'enable'
      ;;
    no|disable|disabled)
      printf 'disable'
      ;;
    *)
      die "WARP 操作只能是 enable 或 disable。"
      ;;
  esac
}

validate_cert_mode_value() {
  local value=""

  value="$(normalize_cert_mode "${1}")"
  case "${value}" in
    self-signed|existing|acme-dns-cf|acme-http)
      printf '%s' "${value}"
      ;;
    *)
      die "不支持的证书模式：${1}"
      ;;
  esac
}

show_cert_mode_menu() {
  cat <<'EOF'
证书模式:
  1. 自签名
  2. 现有证书（含 Cloudflare Origin CA）
  3. ACME DNS (Cloudflare)
  4. ACME HTTP (Let's Encrypt 等，不需要 DNS 令牌)
EOF
}

prompt_cert_mode_selection() {
  local prompt_text="${1}"
  local default_mode="${2}"
  local default_choice=""
  local previous="${CERT_MODE:-}" candidate=""

  if [[ "${NON_INTERACTIVE}" == 1 ]]; then
    default_choice="$(normalize_cert_mode "${default_mode}")"
  else
    default_choice="$(cert_mode_choice_value "${default_mode}")"
  fi
  [[ -n "${CERT_MODE:-}" ]] || show_cert_mode_menu
  while true; do
    prompt_with_default CERT_MODE "${prompt_text}" "${default_choice}" || return $?
    candidate="${CERT_MODE}"
    if [[ "${NON_INTERACTIVE}" != 1 ]]; then
      case "${candidate}" in 1) candidate=self-signed ;; 2) candidate=existing ;; 3) candidate=acme-dns-cf ;; 4) candidate=acme-http ;; esac
    fi
    candidate="$(validate_cert_mode_value "${candidate}")" || {
      [[ "${NON_INTERACTIVE}" != 1 ]] || return 1
      warn "请选择 1=self-signed、2=existing、3=acme-dns-cf、4=acme-http。"
      CERT_MODE="${previous}"
      continue
    }
    CERT_MODE="${candidate}"
    return 0
  done
}

prompt_warp_settings() {
  local use_profile="no"

  resolve_value_source WARP_PRIVATE_KEY
  resolve_value_source WARP_PROFILE_SOURCE
  resolve_value_source WARP_RESERVED
  resolve_value_source WARP_ENDPOINT

  if warp_credentials_ready || [[ -n "${WARP_PROFILE_SOURCE}" ]]; then
    return
  fi

  log "WARP 出站由 Xray 内置 wireguard 承载，默认自动注册一台免费 WARP 设备。"
  prompt_yes_no use_profile "是否改为导入已有的 wgcf profile.conf？ [y/n]" "n" || return $?
  use_profile="$(normalize_yes_no_value "use_profile" "${use_profile}")" || exit 1
  [[ "${use_profile}" == "yes" ]] || return

  prompt_multiline_value WARP_PROFILE_SOURCE "粘贴 wgcf profile.conf 内容" || return $?
  [[ -n "${WARP_PROFILE_SOURCE}" ]] || die "未提供 WARP profile 内容。"
}

default_warp_rules_text() {
  cat <<'EOF'
geosite:openai
domain:chatgpt.com
domain:claude.ai
domain:anthropic.com
EOF
}

normalize_warp_rule_value() {
  local raw_value="${1:-}"
  local trimmed=""

  trimmed="$(printf '%s' "${raw_value}" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -n "${trimmed}" ]] || die "WARP 分流规则不能为空。"
  [[ "${trimmed}" != *[[:space:]]* ]] || die "WARP 分流规则不能包含空白字符：${trimmed}"

  case "${trimmed}" in
    domain:*)
      validate_hostname_value "WARP 域名规则" "${trimmed#domain:}"
      printf '%s' "${trimmed}"
      ;;
    geosite:*)
      [[ "${trimmed#geosite:}" =~ ^[A-Za-z0-9._-]+$ ]] || die "WARP geosite 规则不合法：${trimmed}"
      printf '%s' "${trimmed}"
      ;;
    *)
      validate_hostname_value "WARP 域名规则" "${trimmed}"
      printf 'domain:%s' "${trimmed}"
      ;;
  esac
}

normalize_warp_rules_text() {
  local input_text="${1:-}"
  local line=""
  local normalized_line=""
  local seen=""

  while IFS= read -r line; do
    line="$(printf '%s' "${line}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "${line}" ]] || continue
    [[ "${line}" != \#* ]] || continue
    normalized_line="$(normalize_warp_rule_value "${line}")" || exit 1

    case $'\n'"${seen}" in
      *$'\n'"${normalized_line}"$'\n'*)
        continue
        ;;
    esac

    seen+="${normalized_line}"$'\n'
    printf '%s\n' "${normalized_line}"
  done <<< "${input_text}"
}

current_warp_rules_text() {
  if [[ -n "${WARP_RULES_TEXT:-}" ]]; then
    printf '%s\n' "${WARP_RULES_TEXT}" | sed '/^$/d'
    return
  fi

  if [[ -f "${WARP_RULES_FILE}" ]]; then
    normalize_warp_rules_text "$(<"${WARP_RULES_FILE}")"
    return
  fi

  default_warp_rules_text
}

write_warp_rules_file() {
  local tmp_file=""
  local rules_text=""
  local current_text=""

  # 两层命令替换要拆开写。内层放在参数位置上时退出码会被外层整个吞掉：
  # current_warp_rules_text 读到一条非法规则会 die，而 die 是 exit，
  # 只打死了内层子 shell，外层就拿着一个空串当「当前规则」，
  # 接着把 WARP_RULES_FILE 原地清空——现有规则无声消失。
  current_text="$(current_warp_rules_text)" || return 1
  rules_text="$(normalize_warp_rules_text "${current_text}")" || return 1
  mkdir -p "${XRAY_CONFIG_DIR}" || return 1
  backup_path "${WARP_RULES_FILE}" || return 1
  tmp_file="$(mktemp "${XRAY_CONFIG_DIR}/.warp-domains.list.tmp.XXXXXX")"
  printf '%s\n' "${rules_text}" > "${tmp_file}" || { rm -f "${tmp_file}"; return 1; }
  mv -f "${tmp_file}" "${WARP_RULES_FILE}" || { rm -f "${tmp_file}"; return 1; }
  chmod 0640 "${WARP_RULES_FILE}"
}

resolve_install_input_sources() {
  install_record_secret_ref CERT_SOURCE_PEM
  install_record_secret_ref KEY_SOURCE_PEM
  install_record_secret_ref WARP_PRIVATE_KEY
  install_record_secret_ref WARP_PROFILE_SOURCE
  install_record_secret_ref CF_DNS_TOKEN
  resolve_value_source CERT_SOURCE_PEM
  resolve_value_source KEY_SOURCE_PEM
  resolve_value_source WARP_PRIVATE_KEY
  resolve_value_source WARP_PROFILE_SOURCE
  resolve_value_source CF_DNS_TOKEN
}

# 敏感输入的「来源」和「内容」分开：草稿只写 @路径 这类间接引用，
# 正文只在本次动作的内存里存在（D06）。
install_record_secret_ref() {
  local var_name="${1}"
  local value="${!var_name:-}"

  if [[ "${value}" == @* ]]; then
    printf -v "${var_name}_REF" '%s' "${value}"
    return 0
  fi
  printf -v "${var_name}_REF" '%s' ""
}

# 深预检（依赖准备之后）：证书与私钥必须是一对，不匹配就在写盘之前停住。
# 这一步依赖 openssl，所以放在依赖准备之后；缺 openssl 时明说「未复检」，
# 不把它当成通过（D07）。
preflight_check_cert_pair() {
  local cert_hash=""
  local key_hash=""

  case "${CERT_MODE:-}" in
    existing) ;;
    *) return 0 ;;
  esac
  cert_input_files_readonly_check || return 1
  [[ -n "${CERT_SOURCE_FILE}" ]] || return 0

  if ! command -v openssl >/dev/null 2>&1; then
    warn "预检失败：依赖准备后仍没有 openssl，无法复检证书与私钥。"
    return 1
  fi

  cert_hash="$(openssl x509 -in "${CERT_SOURCE_FILE}" -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')" \
    || die "预检失败：无法解析证书：${CERT_SOURCE_FILE}"
  key_hash="$(openssl pkey -in "${KEY_SOURCE_FILE}" -pubout -outform DER 2>/dev/null \
    | sha256sum | awk '{print $1}')" || die "预检失败：无法解析私钥：${KEY_SOURCE_FILE}"
  if [[ -z "${cert_hash}" || -z "${key_hash}" ]]; then
    die "预检失败：无法读取证书或私钥内容：${CERT_SOURCE_FILE} / ${KEY_SOURCE_FILE}"
  fi
  if [[ "${cert_hash}" != "${key_hash}" ]]; then
    die "预检失败：证书与私钥不匹配：${CERT_SOURCE_FILE} / ${KEY_SOURCE_FILE}"
  fi
}

# 443 被占用的三种情形分开处理：空闲放行；托管配置还在就按重装放行；
# 其余情况必须停在这里，但只说「端口已被占用」等于没给下一步。
# 实测（2026-09-14 测试 VPS）走到的正是第三条：uninstall 摘掉 haproxy.cfg 之后
# haproxy.service 仍以旧的内存配置监听 443，用户手里没有任何可执行线索。
# 所以这里把占用者名字带出来，能在托管服务名下就顺带给一条 systemctl 命令。
preflight_check_port_443() {
  local listeners=""
  local owners=""
  local stop_hint=""

  if ! command -v ss >/dev/null 2>&1; then
    warn "系统中未找到 ss，已跳过 443 端口占用预检。"
    return 0
  fi

  listeners="$(ss -ltnH '( sport = :443 )' 2>/dev/null || true)"
  [[ -z "${listeners}" ]] && return 0

  if [[ -f "${XRAY_CONFIG_FILE}" || -f "${HAPROXY_CONFIG}" ]]; then
    warn "检测到 443 端口已被当前机器上的现有服务占用，继续执行重装流程。"
    return 0
  fi

  owners="$(ss -ltnpH '( sport = :443 )' 2>/dev/null \
    | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | sort -u | tr '\n' '/')"
  owners="${owners%/}"
  case "${owners}" in
    *haproxy*) stop_hint="systemctl stop haproxy" ;;
    *nginx*) stop_hint="systemctl stop nginx" ;;
    *xray*) stop_hint="systemctl stop xray" ;;
  esac

  if [[ -z "${owners}" ]]; then
    die "预检失败：TCP 443 已被占用（当前用户看不到占用进程，请用 root 复核），且没有本脚本托管的 443 配置。请先释放该端口，或改用其它端口后重试。"
  fi
  if [[ -n "${stop_hint}" ]]; then
    die "预检失败：TCP 443 被 ${owners} 占用，且没有本脚本托管的 443 配置。请先释放该端口（如 ${stop_hint}；若该服务在托管别的站点，请改用其它端口）后重试。"
  fi
  die "预检失败：TCP 443 被 ${owners} 占用，且没有本脚本托管的 443 配置。请先停止占用 443 的进程，或改用其它端口后重试。"
}

preflight_check_domain_resolution() {
  local domain="${1}"
  local label="${2}"
  local resolved_ip=""

  [[ -n "${domain}" ]] || return 0
  resolved_ip="$(getent ahostsv4 "${domain}" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  if [[ -z "${resolved_ip}" ]]; then
    warn "预检提示：${label} 当前无法解析，后续请确认 DNS 配置。"
    return 0
  fi

  if [[ -n "${SERVER_IP:-}" && "${resolved_ip}" == "${SERVER_IP}" ]]; then
    log_success "${label} 已解析到当前服务器地址：${resolved_ip}"
    return 0
  fi

  warn "预检提示：${label} 当前解析为 ${resolved_ip}，如果使用了 Cloudflare 橙云，这可能是正常现象。"
}

# 这里以前是 `curl -fsSL ... || true`，然后「响应为空就当没连上，跳过校验并返回 0」。
# -f 的作用恰恰是把出错响应的 body 整个丢掉、只留一个退出码 22——而 Cloudflare 对一个
# 坏令牌回的正是 401 加一段说清了原因的 JSON（实测：
# {"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}]}）。
# 于是「令牌被拒」和「网络不通」被压成同一件事：任何拼错、吊销、权限不足的令牌都会
# 印一句「无法在线校验，已跳过权限验证」然后放行。die 那条分支要求 HTTP 2xx 且
# success:false，Cloudflare 不这么回——也就是说这个预检存在的唯一目的（在装之前拦住
# 坏令牌）一次都没实现过，还顺手把锅甩给了网络。
# 代价是真的：acme-dns-cf 模式下要一路装完包、装完 xray、写完配置，才在 acme.sh
# 签发那一步炸；走 change-cert-mode 的话是整个托管变更回滚一次。
# 改成不带 -f，把 http_code 单独取出来：拿不到状态码（000）才是真的没连上，
# 这时才保留原来的宽容行为。Cloudflare 答了话就按它说的办，并把它自己的错误信息
# 带出来——「Invalid API Token」和「Unauthorized to access requested resource」
# 对操作员是两件完全不同的事。
verify_cloudflare_token() {
  local token="${1}"
  local label="${2}"
  local response=""
  local http_code=""
  local body=""
  local message=""

  [[ -n "${token}" ]] || return 0
  response="$(curl -sS --max-time 15 -w '\n%{http_code}' \
    https://api.cloudflare.com/client/v4/user/tokens/verify \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' 2>/dev/null || true)"
  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [[ ! "${http_code}" =~ ^[1-5][0-9]{2}$ ]]; then
    warn "预检提示：无法在线校验 ${label}，已跳过权限验证。"
    return 0
  fi

  if printf '%s' "${body}" | grep -Eq '"success"[[:space:]]*:[[:space:]]*true'; then
    log_success "${label} 校验通过。"
    return 0
  fi

  # 提不出 message 也要死掉：body 为空的 4xx 以前正是走「跳过」那条路的。
  message="$(cloudflare_error_message "${body}")"
  die "预检失败：${label} 校验未通过（HTTP ${http_code}${message:+：${message}}）。"
}

# 只取第一条 errors[].message。jq 在预检这一步不一定装上了（安装包还没跑），
# 所以没有 jq 就退回 sed，取不到就返回空串，由调用方决定怎么说。
cloudflare_error_message() {
  local body="${1:-}"

  [[ -n "${body}" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "${body}" | jq -r '.errors[0].message? // empty' 2>/dev/null && return 0
  fi

  printf '%s' "${body}" \
    | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

# 跳过/忽略 SNI 预检是「本次动作」的选择：装完必须再报一次事实，
# 不能把它写成默认值，也不能因为忽略就当成通过（D09）。
install_sni_preflight_notice() {
  if [[ "${SNI_PREFLIGHT_SKIPPED:-0}" == "1" ]]; then
    printf '未验证：REALITY 目标域名预检已跳过（--skip-sni-check）；Reality 转发是否可用尚未验证。'
    return 0
  fi
  if [[ "${SNI_PREFLIGHT_IGNORED:-0}" == "1" ]]; then
    printf '未通过：REALITY 目标域名预检失败后选择忽略；Reality 转发可能不可用。'
    return 0
  fi
  return 0
}

report_sni_preflight_override() {
  local notice=""

  notice="$(install_sni_preflight_notice)"
  [[ -z "${notice}" ]] || warn "${notice}（复检: xtun check-sni）"
}

run_install_preflight_checks() {
  log_step "执行安装前预检。"
  preflight_check_port_443 || return 1
  preflight_check_domain_resolution "${XHTTP_DOMAIN}" "XHTTP CDN 域名" || return 1
  preflight_check_reality_sni || return 1
  report_sni_preflight_override
  preflight_check_cert_pair || return 1

  case "${CERT_MODE}" in
    acme-dns-cf)
      verify_cloudflare_token "${CF_DNS_TOKEN}" "Cloudflare DNS Token"
      ;;
    acme-http)
      preflight_check_acme_http_domain
      ;;
  esac
}

# HTTP-01 要求 CA 能从公网访问 http://<域名>/.well-known/acme-challenge/。
# 域名解析不到 = 一定签不下来，直接挡在确认前；解析到别的地址可能是 Cloudflare 等
# 代理（挑战仍可能被转发到源站），所以只告警继续——真失败会由签发与回退如实报告。
preflight_check_acme_http_domain() {
  local resolved_ip=""

  [[ "${CERT_MODE:-}" == "acme-http" ]] || return 0
  [[ -n "${XHTTP_DOMAIN:-}" ]] || die "acme-http 模式必须提供 XHTTP 域名。"
  resolved_ip="$(getent ahostsv4 "${XHTTP_DOMAIN}" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  [[ -n "${resolved_ip}" ]] || die "acme-http 模式要求 ${XHTTP_DOMAIN} 解析到本机，当前无法解析。"
  if [[ -n "${SERVER_IP:-}" && "${resolved_ip}" != "${SERVER_IP}" ]]; then
    warn "预检提示：${XHTTP_DOMAIN} 解析为 ${resolved_ip}，不是本机 ${SERVER_IP}；如果它经过 Cloudflare 等代理，挑战需要转发到本机 80 端口，否则签发会失败。"
  fi
  command -v socat >/dev/null 2>&1 || die "acme-http 模式需要 socat（acme.sh standalone）。"
  log_success "acme-http 域名 ${XHTTP_DOMAIN} 已解析到本机：${resolved_ip}"
}

is_valid_hostname() {
  local host="${1:-}"
  local label=""

  [[ -n "${host}" ]] || return 1
  [[ "${#host}" -le 253 ]] || return 1
  [[ "${host}" != .* && "${host}" != *..* && "${host}" != *. ]] || return 1
  [[ "${host}" =~ ^[A-Za-z0-9.-]+$ ]] || return 1

  # 必须是 local IFS。手工存一份再在末尾还原是不够的：下面三条 return 1
  # 全都从还原语句上面跳走，调用方的 IFS 就被永久留成 "."，
  # 之后所有不加引号的展开、$*、read 全按 "." 分词。
  # local 让 bash 在函数返回时自己还原，无论从哪条路径返回。
  local IFS='.'
  for label in ${host}; do
    [[ -n "${label}" ]] || return 1
    [[ "${#label}" -le 63 ]] || return 1
    [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done

  return 0
}

validate_hostname_value() {
  local field_name="${1}"
  local host="${2:-}"

  is_valid_hostname "${host}" || die "${field_name} 不是合法域名：${host}"
}

validate_port_value() {
  local field_name="${1}"
  local port="${2:-}"

  [[ "${port}" =~ ^[0-9]+$ ]] || die "${field_name} 必须是 1-65535 之间的端口：${port}"
  (( port >= 1 && port <= 65535 )) || die "${field_name} 必须是 1-65535 之间的端口：${port}"
}

# 只由数字和点组成的「主机名」必须真的是 IPv4：`999.999.999.999` 一类拼写
# 会被域名校验放过，但它不可能是用户想要的结果。
require_valid_ipv4_like_host() {
  local field_name="${1}"
  local host="${2:-}"

  [[ "${host}" =~ ^[0-9.]+$ ]] || return 0
  is_ipv4 "${host}" || die "${field_name} 不是合法 IPv4：${host}"
}

validate_hostport_value() {
  local field_name="${1}"
  local hostport="${2:-}"
  local host=""
  local port=""

  [[ -n "${hostport}" ]] || die "${field_name} 不能为空。"
  [[ "${hostport}" == *:* ]] || die "${field_name} 必须是 host:port 格式：${hostport}"
  host="${hostport%:*}"
  port="${hostport##*:}"
  [[ -n "${host}" && -n "${port}" ]] || die "${field_name} 必须是 host:port 格式：${hostport}"

  if ! is_ipv4 "${host}"; then
    require_valid_ipv4_like_host "${field_name}" "${host}"
    validate_hostname_value "${field_name}" "${host}"
  fi
  validate_port_value "${field_name}" "${port}"
}

# 节点地址：IPv4 或域名；IPv6 有独立字段，混进来只会生成打不开的链接。
ensure_server_ip_format() {
  local address="${SERVER_IP:-}"

  [[ -n "${address}" ]] || die "REALITY 直连节点地址不能为空。"
  is_ipv4 "${address}" && return 0
  [[ "${address}" != *:* ]] || die "REALITY 直连节点地址填的是 IPv6：${address}；IPv6 请使用 --server-ip6。"
  require_valid_ipv4_like_host "REALITY 直连节点地址" "${address}"
  validate_hostname_value "REALITY 直连节点地址" "${address}"
}

# IPv6 直连地址：留空表示不做双栈；给了就必须是能出网的全局单播。
ensure_server_ip6_format() {
  local address="${SERVER_IP6:-}"

  [[ -n "${address}" ]] || return 0
  is_ipv6_address "${address}" || die "IPv6 直连地址不是合法 IPv6：${address}"
  is_global_ipv6 "${address}" || die "IPv6 直连地址不是全局单播地址（2000::/3）：${address}"
}

# 基础问答里明确选了启用双栈时的地址校验：留空等于「说要开却没地址」，
# 当场重问，不能按 ensure_server_ip6_format 的「留空即关闭」静默滑过去。
ensure_server_ip6_required() {
  [[ -n "${SERVER_IP6:-}" ]] || die "已选择启用 IPv6 双栈，请填写本机全局单播 IPv6 地址（2000::/3）。"
  ensure_server_ip6_format
}

ensure_reality_sni_format() {
  validate_hostname_value "REALITY SNI" "${REALITY_SNI}"
}

# change-sni 的 post_update：改 SNI 时目标跟着换（0.11 只改 SNI 不改 target 是隐性缺陷），
# 然后跑一次预检。
ensure_reality_sni_ready() {
  ensure_reality_sni_format
  REALITY_TARGET="$(default_reality_target_for_sni "${REALITY_SNI}")"
  preflight_check_reality_sni
}

ensure_xhttp_domain_format() {
  validate_hostname_value "XHTTP CDN 域名" "${XHTTP_DOMAIN}"
}

ensure_reality_target_format() {
  validate_hostport_value "REALITY 目标地址" "${REALITY_TARGET}"
}

reality_target_host() {
  local hostport="${1:-${REALITY_TARGET}}"
  validate_hostport_value "REALITY 目标地址" "${hostport}"
  printf '%s' "${hostport%:*}"
}

reality_target_port() {
  local hostport="${1:-${REALITY_TARGET}}"
  validate_hostport_value "REALITY 目标地址" "${hostport}"
  printf '%s' "${hostport##*:}"
}

ensure_xhttp_path_format() {
  [[ -n "${XHTTP_PATH}" ]] || die "XHTTP 路径不能为空。"
  [[ "${XHTTP_PATH}" == /* ]] || die "XHTTP 路径必须以 / 开头。"
  [[ "${XHTTP_PATH}" != *$'\n'* && "${XHTTP_PATH}" != *$'\r'* ]] || die "XHTTP 路径不能包含换行。"
  [[ "${XHTTP_PATH}" != *'"'* ]] || die "XHTTP 路径不能包含双引号。"
  # 单引号里的 `\\` 是两个字面反斜杠，只挡得住连着写两个的路径；
  # 挡一个反斜杠要写 '\'。原来的写法让 /a\b 这种路径直接通过，
  # 然后原样进 nginx 的 location 前缀。
  # shellcheck disable=SC1003
  [[ "${XHTTP_PATH}" != *'\'* ]] || die "XHTTP 路径不能包含反斜杠。"
  [[ "${XHTTP_PATH}" != *[[:space:]]* ]] || die "XHTTP 路径不能包含空白字符。"
}

xhttp_ech_value_valid() {
  local value="${1}" url="" numbers="" length=0 offset=2 size=0 supported=no
  local -a bytes=()
  [[ -n "${value}" ]] || return 0
  [[ "${value}" != *[[:space:]]* ]] || return 1
  if [[ "${value}" == *://* ]]; then
    url="${value}"
    if [[ "${value}" == *+* ]]; then
      is_valid_hostname "${value%%+*}" || return 1
      url="${value#*+}"
    fi
    [[ "${url}" =~ ^(https|h2c|udp)://(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9.-]+)(:[0-9]+)?(/[^[:space:]\#]*)?$ ]] || return 1
    if [[ -n "${BASH_REMATCH[3]}" ]]; then
      local port="${BASH_REMATCH[3]#:}"
      [[ "${#port}" -le 5 ]] && (( 10#${port} >= 1 && 10#${port} <= 65535 )) || return 1
    fi
    return 0
  fi
  [[ "${value}" =~ ^[A-Za-z0-9+/]+={0,2}$ && $(( ${#value} % 4 )) -eq 0 ]] || return 1
  numbers="$(printf '%s' "${value}" | base64 --decode | od -An -v -tu1)" || return 1
  IFS=' ' read -r -a bytes <<< "${numbers//$'\n'/ }"
  [[ "${#bytes[@]}" -ge 6 ]] || return 1
  length=$((bytes[0] * 256 + bytes[1] + 2))
  [[ "${length}" -eq "${#bytes[@]}" ]] || return 1
  while [[ "${offset}" -lt "${length}" ]]; do
    [[ $((offset + 4)) -le "${length}" ]] || return 1
    size=$((bytes[offset + 2] * 256 + bytes[offset + 3]))
    [[ "${size}" -gt 0 && $((offset + 4 + size)) -le "${length}" ]] || return 1
    if [[ "${bytes[offset]}" -eq 254 && "${bytes[offset + 1]}" -eq 13 ]]; then supported=yes; fi
    offset=$((offset + 4 + size))
  done
  [[ "${supported}" == yes ]]
}

ensure_xhttp_ech_format() {
  xhttp_ech_value_valid "${XHTTP_ECH_CONFIG_LIST}" || die "XHTTP ECH 需要有效的 DoH/UDP 查询地址或完整 Base64 ECHConfigList。"
}

ensure_xhttp_xpadding_format() {
  XHTTP_XPADDING_ENABLED="$(normalize_yes_no_value "XHTTP_XPADDING_ENABLED" "${XHTTP_XPADDING_ENABLED:-${DEFAULT_XHTTP_XPADDING_ENABLED}}")" || exit 1
  if [[ "${XHTTP_XPADDING_ENABLED}" != "yes" ]]; then
    return
  fi

  [[ -n "${XHTTP_XPADDING_KEY}" ]] || die "XHTTP xpadding 参数名不能为空。"
  [[ -n "${XHTTP_XPADDING_HEADER}" ]] || die "XHTTP xpadding Header 名不能为空。"
  [[ "${XHTTP_XPADDING_KEY}" =~ ^[A-Za-z0-9._-]+$ ]] || die "XHTTP xpadding 参数名只能包含字母、数字、点、下划线或横线。"
  [[ "${XHTTP_XPADDING_HEADER}" =~ ^[A-Za-z0-9._-]+$ ]] || die "XHTTP xpadding Header 名只能包含字母、数字、点、下划线或横线。"
  case "${XHTTP_XPADDING_PLACEMENT}" in
    cookie|header|query|queryInHeader) ;;
    *) die "XHTTP xpadding placement 只能是 cookie、header、query 或 queryInHeader。" ;;
  esac
  case "${XHTTP_XPADDING_METHOD}" in
    repeat-x|tokenish) ;;
    *) die "XHTTP xpadding method 只能是 repeat-x 或 tokenish。" ;;
  esac
}

normalize_warp_reserved_value() {
  local raw_value="${1:-}"
  local byte=""
  local normalized=""

  raw_value="$(printf '%s' "${raw_value}" | tr -d '\r' | tr -d '[]' | tr -d ' ')"
  [[ -n "${raw_value}" ]] || return 0

  while IFS= read -r byte; do
    [[ -n "${byte}" ]] || continue
    [[ "${byte}" =~ ^[0-9]+$ ]] || die "WARP reserved 只能是逗号分隔的 0-255 整数：${1}"
    (( byte >= 0 && byte <= 255 )) || die "WARP reserved 只能是逗号分隔的 0-255 整数：${1}"
    normalized+="${byte},"
  done < <(printf '%s\n' "${raw_value}" | tr ',' '\n')

  printf '%s' "${normalized%,}"
}

is_valid_wireguard_key() {
  local key="${1:-}"

  [[ "${key}" =~ ^[A-Za-z0-9+/]{42}[A-Za-z0-9+/=]{2}$ ]]
}

ensure_warp_outbound_format() {
  is_valid_wireguard_key "${WARP_PRIVATE_KEY}" \
    || die "WARP WireGuard 私钥必须是 44 位 base64 字符串。"
  is_valid_wireguard_key "${WARP_PEER_PUBLIC_KEY:-${DEFAULT_WARP_PEER_PUBLIC_KEY}}" \
    || die "WARP 对端公钥必须是 44 位 base64 字符串。"
  [[ -n "${WARP_ADDRESS_V4}" || -n "${WARP_ADDRESS_V6}" ]] \
    || die "启用 WARP 时必须提供至少一个 WireGuard 内网地址。"
  if [[ -n "${WARP_ADDRESS_V4}" ]]; then
    is_ipv4 "${WARP_ADDRESS_V4}" || die "WARP IPv4 内网地址不合法：${WARP_ADDRESS_V4}"
  fi
  if [[ -n "${WARP_ADDRESS_V6}" ]]; then
    is_ipv6_address "${WARP_ADDRESS_V6}" || die "WARP IPv6 内网地址不合法：${WARP_ADDRESS_V6}"
  fi
  validate_hostport_value "WARP Endpoint" "${WARP_ENDPOINT:-${DEFAULT_WARP_ENDPOINT}}"
  validate_port_value "WARP MTU" "${WARP_MTU:-${DEFAULT_WARP_MTU}}"
  WARP_RESERVED="$(normalize_warp_reserved_value "${WARP_RESERVED}")" || exit 1
}

validate_install_inputs() {
  ensure_server_ip_format
  ensure_server_ip6_format
  ensure_reality_sni_format
  ensure_reality_target_format
  ensure_xhttp_domain_format
  ensure_xhttp_path_format
  ensure_xhttp_ech_format
  ensure_xhttp_xpadding_format
  cert_input_files_readonly_check

  if [[ "${ENABLE_WARP:-no}" == "yes" && -n "${WARP_PRIVATE_KEY}" ]]; then
    ensure_warp_outbound_format
  fi
}
