# shellcheck shell=bash

# ------------------------------
# Reality 目标域名预检层
# 探测函数有网络副作用（测试中整函数覆盖成固定输出）；
# 判定函数必须是纯函数：只吃字符串、只吐 "LEVEL|名称|说明" 行。
# ------------------------------

# 探测层 ----------------------------------------------------------------

sni_probe_dns() {
  local host="${1}"

  command -v getent >/dev/null 2>&1 || return 1
  getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1}' | sort -u
}

sni_probe_tls() {
  local target="${1}"
  local sni="${2}"
  local timeout="${3}"

  command -v openssl >/dev/null 2>&1 || return 1
  timeout "${timeout}" openssl s_client \
    -connect "${target}" \
    -servername "${sni}" \
    -tls1_3 \
    -groups X25519 \
    -alpn h2 \
    </dev/null 2>&1
}

# 输出三行：SAN=... / NOTAFTER=... / ISSUER=...
sni_probe_cert() {
  local target="${1}"
  local sni="${2}"
  local timeout="${3}"
  local pem=""

  command -v openssl >/dev/null 2>&1 || return 1
  pem="$(timeout "${timeout}" openssl s_client \
    -connect "${target}" \
    -servername "${sni}" \
    -tls1_3 \
    -groups X25519 \
    -alpn h2 \
    </dev/null 2>/dev/null | openssl x509 2>/dev/null)" || return 1
  [[ -n "${pem}" ]] || return 1

  printf 'SAN=%s\n' "$(printf '%s\n' "${pem}" | openssl x509 -noout -ext subjectAltName 2>/dev/null \
    | tail -n +2 | tr -d ' ' | tr ',' '\n' | paste -sd, -)"
  printf 'NOTAFTER=%s\n' "$(printf '%s\n' "${pem}" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  printf 'ISSUER=%s\n' "$(printf '%s\n' "${pem}" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
}

# 输出一行：<code> <http_version> <redirect_url> <time_appconnect> <server_header>
sni_probe_http() {
  local sni="${1}"
  local target="${2}"
  local timeout="${3}"
  local target_host="${target%:*}"
  local target_port="${target##*:}"
  local response=""

  if [[ "${target}" != *:* ]]; then
    target_port="443"
  fi

  command -v curl >/dev/null 2>&1 || return 1
  response="$(timeout "${timeout}" curl -sS -o /dev/null \
    --max-time "${timeout}" \
    --http2 \
    -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36' \
    --connect-to "${sni}:443:${target_host}:${target_port}" \
    -D - \
    -w '\n__META__%{http_code} %{http_version} %{redirect_url} %{time_appconnect}' \
    "https://${sni}/" 2>/dev/null)" || return 1

  local meta=""
  local server_header=""

  meta="$(printf '%s\n' "${response}" | sed -n 's/^__META__//p' | head -n 1)"
  server_header="$(printf '%s\n' "${response}" | sed -n 's/^[Ss]erver:[[:space:]]*//Ip' | head -n 1 | tr -d '\r')"
  # meta 本身是 "code ver redirect time"，空 redirect 时中间会有连续空格，原样保留，
  # 判定层按单空格手工拆。
  printf '%s %s\n' "${meta}" "${server_header}"
}

# 判定层 ----------------------------------------------------------------

sni_judge_line() {
  local level="${1}"
  local name="${2}"
  local detail="${3}"

  printf '%s|%s|%s\n' "${level}" "${name}" "${detail}"
}

sni_judge_hostname() {
  local sni="${1}"

  if is_valid_hostname "${sni}"; then
    sni_judge_line PASS "域名格式" "${sni}"
    return
  fi

  sni_judge_line FAIL "域名格式" "${sni} 不是合法域名"
}

sni_judge_dns() {
  local sni="${1}"
  local target_host="${2}"
  local dns_output="${3}"
  local server_ip="${4}"
  local ip=""
  local private_count=0
  local total=0

  if [[ -z "${dns_output}" ]]; then
    sni_judge_line FAIL "DNS 解析" "${target_host} 无 A 记录"
    return
  fi

  while IFS= read -r ip; do
    [[ -n "${ip}" ]] || continue
    total=$((total + 1))
    if [[ -n "${server_ip}" && "${ip}" == "${server_ip}" ]]; then
      sni_judge_line FAIL "DNS 解析" "${ip} 是本机地址，Reality 回落会形成回环"
      return
    fi
    if is_private_ipv4 "${ip}"; then
      private_count=$((private_count + 1))
    fi
  done <<< "${dns_output}"

  if [[ "${private_count}" -eq "${total}" ]]; then
    sni_judge_line FAIL "DNS 解析" "全部解析到私网地址：$(printf '%s' "${dns_output}" | head -n 1)"
    return
  fi

  sni_judge_line PASS "DNS 解析" "$(printf '%s' "${dns_output}" | head -n 1)"
}

sni_judge_tls() {
  local tls_output="${1}"
  local cipher=""

  if printf '%s' "${tls_output}" | grep -q 'TLSv1.3'; then
    cipher="$(printf '%s\n' "${tls_output}" | sed -n 's/^Cipher[[:space:]]*:[[:space:]]*//p' | head -n 1)"
    sni_judge_line PASS "TLS 1.3" "TLSv1.3${cipher:+, ${cipher}}"
  else
    sni_judge_line FAIL "TLS 1.3" "目标不支持 TLS 1.3 或连接失败"
  fi

  if printf '%s' "${tls_output}" | grep -Eq '(Peer|Server) Temp Key: X25519'; then
    sni_judge_line PASS "X25519" "临时密钥组为 X25519"
  else
    sni_judge_line FAIL "X25519" "握手未使用 X25519"
  fi

  if printf '%s' "${tls_output}" | grep -q 'ALPN protocol: h2'; then
    sni_judge_line PASS "HTTP/2 ALPN" "h2"
  else
    sni_judge_line FAIL "HTTP/2 ALPN" "目标未协商出 h2（Reality + Vision 要求 h2）"
  fi

  if printf '%s' "${tls_output}" | grep -q 'Verify return code: 0 (ok)'; then
    sni_judge_line PASS "证书链" "Verify return code: 0 (ok)"
  else
    sni_judge_line FAIL "证书链" "$(printf '%s\n' "${tls_output}" | sed -n 's/^Verify return code://p' | head -n 1 | sed 's/^ *//' | sed 's/^$/校验失败/')"
  fi
}

sni_judge_cert() {
  local sni="${1}"
  local cert_output="${2}"
  local now_epoch="${3}"
  local san_line=""
  local enddate_line=""
  local issuer_line=""
  local san_value=""
  local end_epoch=""
  local days_left=""
  local base_sni=""

  san_line="$(printf '%s\n' "${cert_output}" | sed -n 's/^SAN=//p' | head -n 1)"
  enddate_line="$(printf '%s\n' "${cert_output}" | sed -n 's/^NOTAFTER=//p' | head -n 1)"
  issuer_line="$(printf '%s\n' "${cert_output}" | sed -n 's/^ISSUER=//p' | head -n 1)"

  # 第 7 项：SAN 精确匹配或通配符匹配
  san_value="$(printf '%s' "${san_line}" | tr ',' '\n' | sed 's/^DNS://' | tr -d ' ')"
  base_sni="${sni#*.}"
  if printf '%s\n' "${san_value}" | grep -Fqx "${sni}" \
    || printf '%s\n' "${san_value}" | grep -Fqx "*.${base_sni}"; then
    sni_judge_line PASS "证书 SAN" "包含 ${sni}"
  else
    sni_judge_line FAIL "证书 SAN" "证书不覆盖 ${sni}（${san_line:-空}）"
  fi

  # 第 8 项：到期时间
  end_epoch="$(date -d "${enddate_line}" '+%s' 2>/dev/null || true)"
  if [[ -n "${end_epoch}" && -n "${now_epoch}" ]]; then
    days_left=$(( (end_epoch - now_epoch) / 86400 ))
    if (( days_left >= 30 )); then
      sni_judge_line PASS "证书到期" "${days_left} 天"
    elif (( days_left >= 14 )); then
      sni_judge_line WARN "证书到期" "${days_left} 天，快到期了"
    else
      sni_judge_line FAIL "证书到期" "仅剩 ${days_left} 天"
    fi
  else
    sni_judge_line FAIL "证书到期" "无法读取证书有效期"
  fi

  # 第 9 项：目标是否在 CDN 后（偷到的是边缘握手，可用但不理想）
  if printf '%s' "${issuer_line}" | grep -Eiq 'cloudflare|google trust|fastly|akamai|amazon|lets encrypt'; then
    sni_judge_line WARN "CDN 前置" "证书由 CDN/公共 CA 边缘签发，Reality 偷的是边缘握手"
  else
    sni_judge_line PASS "CDN 前置" "否"
  fi
}

sni_judge_http() {
  local sni="${1}"
  local http_output="${2}"
  local code=""
  local http_version=""
  local redirect_url=""
  local time_appconnect=""
  local server_header=""
  local redirect_host=""
  local now_epoch=""

  # 字段可能为空（redirect），awk 分词会错位，只能按单空格手工拆。
  code="${http_output%% *}"
  local rest="${http_output#"$code" }"
  http_version="${rest%% *}"
  rest="${rest#"$http_version" }"
  if [[ "${rest}" == " "* ]]; then
    redirect_url=""
    rest="${rest# }"
  else
    redirect_url="${rest%% *}"
    if [[ "${rest}" == *' '* ]]; then
      rest="${rest#"$redirect_url" }"
    else
      rest=""
    fi
  fi
  time_appconnect="${rest%% *}"
  server_header="${rest#"$time_appconnect" }"

  # 第 10 项：HTTP 跳转
  if [[ "${code}" == "000" || -z "${code}" ]]; then
    sni_judge_line FAIL "HTTP 跳转" "HTTP 请求失败（可能被反爬或不可达）"
  elif [[ "${code}" =~ ^3[0-9][0-9]$ ]]; then
    redirect_host="$(printf '%s' "${redirect_url}" | sed -E 's|^[a-zA-Z]+://([^/]+).*|\1|')"
    if [[ "${redirect_host}" == "${sni}" || -z "${redirect_host}" ]]; then
      sni_judge_line WARN "HTTP 跳转" "${code} -> ${redirect_url}（同主机跳转）"
    else
      sni_judge_line FAIL "HTTP 跳转" "${code} -> ${redirect_url}（跨主机跳转，请直接使用 ${redirect_host}）"
    fi
  elif [[ "${code}" =~ ^2[0-9][0-9]$ ]]; then
    sni_judge_line PASS "HTTP 跳转" "${code}，无跳转"
  elif [[ "${code}" =~ ^(403|429)$ ]]; then
    sni_judge_line WARN "HTTP 跳转" "${code}（目标站反爬，不影响 Reality 转发）"
  elif [[ "${code}" =~ ^5[0-9][0-9]$ ]]; then
    sni_judge_line WARN "HTTP 跳转" "${code}（目标站 5xx）"
  else
    sni_judge_line WARN "HTTP 跳转" "${code}"
  fi

  # 第 11 项：实际 HTTP 版本
  if [[ "${http_version}" == "2" ]]; then
    sni_judge_line PASS "HTTP 版本" "2"
  else
    sni_judge_line WARN "HTTP 版本" "${http_version:-未知}"
  fi

  # 第 12 项：握手耗时
  now_epoch="${time_appconnect}"
  if [[ "${now_epoch}" =~ ^[0-9]+\.?[0-9]*$ ]] && awk -v t="${now_epoch}" 'BEGIN { exit !(t > 1.0) }'; then
    sni_judge_line FAIL "握手耗时" "${now_epoch}s（每条新连接都要先把这个 RTT 付给远端）"
  elif [[ "${now_epoch}" =~ ^[0-9]+\.?[0-9]*$ ]] && awk -v t="${now_epoch}" 'BEGIN { exit !(t > 0.3) }'; then
    sni_judge_line WARN "握手耗时" "${now_epoch}s"
  elif [[ "${now_epoch}" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    sni_judge_line PASS "握手耗时" "${now_epoch}s"
  else
    sni_judge_line WARN "握手耗时" "未测得"
  fi
}

# 聚合 ------------------------------------------------------------------

run_sni_checks() {
  local sni="${1}"
  local target="${2}"
  local server_ip="${3}"
  local timeout="${4}"
  local dns_output=""
  local tls_output=""
  local cert_output=""
  local http_output=""
  local target_host="${target%:*}"
  local line=""
  local level=""
  local name=""
  local detail=""
  local fails=0
  local warns=0

  printf '%s\n' "Reality 目标域名预检: ${sni}  (target ${target})"

  dns_output="$(sni_probe_dns "${target_host}")" || dns_output=""

  tls_output="$(sni_probe_tls "${target}" "${sni}" "${timeout}")" || tls_output=""

  cert_output="$(sni_probe_cert "${target}" "${sni}" "${timeout}")" || cert_output=""

  http_output="$(sni_probe_http "${sni}" "${target}" "${timeout}")" || http_output=""

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    level="${line%%|*}"
    name="${line#*|}"
    detail="${name#*|}"
    name="${name%%|*}"
    case "${level}" in
      PASS) printf '%s %s %s\n' "$(style_text "${C_GREEN}" "PASS")" "$(printf '%-14s' "${name}")" "${detail}" ;;
      WARN)
        warns=$((warns + 1))
        printf '%s %s %s\n' "$(style_text "${C_YELLOW}" "WARN")" "$(printf '%-14s' "${name}")" "${detail}"
        ;;
      *)
        fails=$((fails + 1))
        printf '%s %s %s\n' "$(style_text "${C_RED}" "FAIL")" "$(printf '%-14s' "${name}")" "${detail}"
        ;;
    esac
  done <<EOF
$(sni_judge_hostname "${sni}")
$(sni_judge_dns "${sni}" "${target_host}" "${dns_output}" "${server_ip}")
$(sni_judge_tls "${tls_output}")
$(sni_judge_cert "${sni}" "${cert_output}" "$(date '+%s')")
$(sni_judge_http "${sni}" "${http_output}")
EOF

  if [[ "${fails}" -gt 0 ]]; then
    printf '%s\n' "结论: 不通过（${fails} FAIL, ${warns} WARN）；安装时可用 --skip-sni-check 强行跳过"
    return 2
  fi

  printf '%s\n' "结论: 通过（0 FAIL, ${warns} WARN）"
  return 0
}

sni_check_cmd() {
  local sni=""
  local target=""
  local timeout="10"
  local server_ip="${SERVER_IP:-}"

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --target)
        [[ $# -ge 2 ]] || die "参数 --target 需要值。"
        target="${2}"
        shift 2
        ;;
      --timeout)
        [[ $# -ge 2 ]] || die "参数 --timeout 需要值。"
        timeout="${2}"
        shift 2
        ;;
      --server-ip)
        [[ $# -ge 2 ]] || die "参数 --server-ip 需要值。"
        server_ip="${2}"
        shift 2
        ;;
      --help|-h|help)
        usage
        exit 0
        ;;
      -*)
        die "未知的 check-sni 参数：${1}"
        ;;
      *)
        [[ -z "${sni}" ]] || die "只能指定一个域名。"
        sni="${1}"
        shift
        ;;
    esac
  done

  [[ "${timeout}" =~ ^[0-9]+$ ]] || die "--timeout 必须是正整数：${timeout}"

  if [[ -z "${sni}" ]]; then
    load_existing_state
    [[ -f "${XRAY_CONFIG_FILE}" ]] && load_config_runtime_context
    sni="${REALITY_SNI:-}"
  fi
  [[ -n "${sni}" ]] || die "请指定要检查的域名。"
  [[ -n "${target}" ]] || target="${sni:+$(default_reality_target_for_sni "${sni}")}"
  [[ -n "${target}" ]] || die "请指定要检查的域名。"
  if [[ -z "${target}" || "${target}" == "${sni}:443" ]]; then
    target="$(default_reality_target_for_sni "${sni}")"
  fi
  # 菜单入口没有参数：域名取当前安装的 REALITY_SNI
  if [[ -z "${server_ip}" && -f "${XRAY_CONFIG_FILE}" ]]; then
    load_existing_state
    load_config_runtime_context
    server_ip="${SERVER_IP:-}"
  fi
  [[ -n "${server_ip}" ]] || server_ip="${SERVER_IP:-}"

  run_sni_checks "${sni}" "${target}" "${server_ip}" "${timeout}"
}

# 安装 / change-sni 预检入口 --------------------------------------------

preflight_check_reality_sni() {
  local rounds=0
  local answer=""
  local target="${REALITY_TARGET:-$(default_reality_target_for_sni "${REALITY_SNI}")}"

  if [[ "${SKIP_SNI_CHECK:-0}" == "1" ]]; then
    warn "已按要求跳过 Reality 目标域名预检。"
    return 0
  fi

  while :; do
    if run_sni_checks "${REALITY_SNI}" "${target}" "${SERVER_IP:-}" "10"; then
      return 0
    fi

    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      die "预检失败：Reality 目标域名不满足要求；确认无误可加 --skip-sni-check。"
    fi

    rounds=$((rounds + 1))
    if [[ "${rounds}" -ge 3 ]]; then
      die "预检失败：Reality 目标域名连续 ${rounds} 轮不满足要求。"
    fi

    read -r -p "重新输入 SNI (r) / 忽略继续 (i) / 退出 (q) [r]: " answer
    answer="${answer:-r}"
    case "${answer}" in
      r|R)
        prompt_with_default REALITY_SNI "REALITY 可见 SNI" ""
        prompt_with_default REALITY_TARGET "REALITY 目标地址 host:port" "$(default_reality_target_for_sni "${REALITY_SNI}")"
        target="${REALITY_TARGET}"
        ;;
      i|I)
        warn "已忽略预检失败，继续安装。"
        return 0
        ;;
      q|Q)
        die "已取消：Reality 目标域名预检未通过。"
        ;;
      *)
        warn "无法识别的输入：${answer}"
        ;;
    esac
  done
}
