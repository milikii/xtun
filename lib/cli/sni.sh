# shellcheck shell=bash

# ------------------------------
# Reality 目标域名预检层
# 探测函数有网络副作用（测试中整函数覆盖成固定输出）；
# 判定函数必须是纯函数：只吃字符串、只吐 "LEVEL|名称|说明" 行。
# ------------------------------

# 探测层 ----------------------------------------------------------------

# 探测预算：只接受正整数秒。0 / 00 / 负数 / 文本都表示「没有上界」，一律拒绝；
# 前导零按数值规范化（010 -> 10），判定层拿到的总是规范形式（D07）。
sni_normalize_timeout() {
  local raw="${1-}"
  local normalized=""

  [[ "${raw}" =~ ^[0-9]+$ ]] || return 1
  normalized="$(printf '%s' "${raw}" | sed 's/^0*//')"
  [[ -n "${normalized}" ]] || return 1
  printf '%s' "${normalized}"
}

# 退出码是判定层要用的原始原因：0 有输出 / 2 无记录 / 124 超预算 / 3 无法探测。
# getent 自己没有超时参数，不包一层的话一次挂住的解析能让整个预检无限等待（D07/H08）。
sni_probe_dns() {
  local host="${1}"
  local timeout="${2:-10}"
  local output=""
  local status=0

  command -v getent >/dev/null 2>&1 || return 3
  output="$(timeout "${timeout}" getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1}' | sort -u)" || status=$?
  printf '%s' "${output}"
  case "${status}" in
    0) return 0 ;;
    124|137) return 124 ;;
    *) return 2 ;;
  esac
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

# 后量子就绪度观察（W17）。输出归一化记录：
#   STATUS=ok|unavailable / PQ=true|false / GROUP=<协商组> / CHAIN_BYTES=<非负整数> / REASON=<单行原因>
# 关键点：不锁 `-groups`，让本机 openssl 用它自己的默认分组，才有机会协商到
# X25519MLKEM768 这类混合组（OpenSSL 3.5+ 才带 ML-KEM）。本机不支持时握手照常
# 走经典分组，这里只如实记录协商结果，不据此断言目标站不支持。
sni_probe_pq() {
  local target="${1}"
  local sni="${2}"
  local timeout="${3}"
  local resolved_ip="${4:-}"
  local output=""
  local group=""
  local chain_bytes=0

  # resolved_ip 保留与其它探针一致的签名；连接仍走同一个 target（D09/§3.1）。
  : "${resolved_ip}"

  if ! command -v openssl >/dev/null 2>&1; then
    printf 'STATUS=unavailable\nREASON=本机缺少 openssl\n'
    return 0
  fi

  output="$(timeout "${timeout}" openssl s_client \
    -connect "${target}" \
    -servername "${sni}" \
    -tls1_3 \
    -showcerts \
    </dev/null 2>&1)" || true

  if [[ -z "${output}" ]]; then
    printf 'STATUS=unavailable\nREASON=握手无输出（超时或连接失败）\n'
    return 0
  fi

  group="$(printf '%s\n' "${output}" | sed -n 's/^\(Peer\|Server\) Temp Key: *\([^,]*\),.*/\2/p' | head -n 1 | tr -d ' ')"
  if [[ -z "${group}" ]]; then
    printf 'STATUS=unavailable\nREASON=未取到握手密钥组（握手失败或输出格式未知）\n'
    return 0
  fi

  # 证书链总长度：把 -showcerts 输出的每段 PEM 按字节累加（含换行）。
  chain_bytes="$(printf '%s\n' "${output}" | awk '
    /^-----BEGIN CERTIFICATE-----$/ {in_block=1}
    in_block {total += length($0) + 1}
    /^-----END CERTIFICATE-----$/ {in_block=0}
    END {print total + 0}
  ')"

  case "${group^^}" in
    *MLKEM*|*KYBER*|*ML-KEM*)
      printf 'STATUS=ok\nPQ=true\nGROUP=%s\nCHAIN_BYTES=%s\n' "${group}" "${chain_bytes}"
      ;;
    *)
      printf 'STATUS=ok\nPQ=false\nGROUP=%s\nCHAIN_BYTES=%s\n' "${group}" "${chain_bytes}"
      ;;
  esac
}

# 判定层 ----------------------------------------------------------------

sni_judge_line() {
  local level="${1}"
  local name="${2}"
  local detail="${3}"

  printf '%s|%s|%s\n' "${level}" "${name}" "${detail}"
}

sni_redirect_is_relative() {
  local url="${1}"

  [[ -n "${url}" ]] || return 1
  case "${url}" in
    //*) return 1 ;;
    *://*) return 1 ;;
    *) return 0 ;;
  esac
}

# 取出重定向目标里真正的主机名（去 scheme、userinfo、端口、路径/查询/锚点）。
# 相对引用没有主机名，返回空串，调用方按「仍在本主机」处理（D09）。
sni_redirect_host() {
  local url="${1}"
  local rest=""

  case "${url}" in
    //*) rest="${url#//}" ;;
    *://*) rest="${url#*://}" ;;
    *) return 0 ;;
  esac

  rest="${rest%%[/?#]*}"
  rest="${rest##*@}"
  rest="${rest%%:*}"
  printf '%s' "${rest}"
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
  local probe_status="${5:-0}"
  local fail_detail=""
  local ip=""
  local private_count=0
  local total=0

  # 探测失败的原因要照原样说：超预算和「没有 A 记录」是两回事（D09）。
  case "${probe_status}" in
    124) fail_detail="解析 ${target_host} 超出探测预算（上游 DNS 无响应）" ;;
    3) fail_detail="本机没有 getent，无法解析 ${target_host}" ;;
    *) fail_detail="${target_host} 无 A 记录" ;;
  esac

  if [[ -z "${dns_output}" ]]; then
    sni_judge_line FAIL "DNS 解析" "${fail_detail}"
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

# 后量子就绪度是观察项：只有「协商到后量子混合组且证书链严格大于 3500 字节」
# 才 PASS，其它已测得的情况一律 WARN——增加告警计数，不改变 FAIL/退出码，也不阻断安装。
sni_judge_pq() {
  local probe_output="${1}"
  local status=""
  local pq=""
  local group=""
  local chain_bytes=""
  local reason=""
  local key_text=""
  local chain_text=""

  status="$(printf '%s\n' "${probe_output}" | sed -n 's/^STATUS=//p' | head -n 1)"
  pq="$(printf '%s\n' "${probe_output}" | sed -n 's/^PQ=//p' | head -n 1)"
  group="$(printf '%s\n' "${probe_output}" | sed -n 's/^GROUP=//p' | head -n 1)"
  chain_bytes="$(printf '%s\n' "${probe_output}" | sed -n 's/^CHAIN_BYTES=//p' | head -n 1)"
  reason="$(printf '%s\n' "${probe_output}" | sed -n 's/^REASON=//p' | head -n 1)"

  # 缺字段、非数字长度、命令缺失都只 WARN：不伪称目标不支持，也不阻断普通安装。
  if [[ "${status}" != "ok" ]]; then
    sni_judge_line WARN "后量子就绪度" "未取得握手信息（${reason:-未知原因}）"
    return 0
  fi
  if [[ ! "${chain_bytes}" =~ ^[0-9]+$ ]]; then
    sni_judge_line WARN "后量子就绪度" "证书链长度缺失或非数字（${reason:-未知}）"
    return 0
  fi

  if [[ "${pq}" == "true" && "${chain_bytes}" -gt 3500 ]]; then
    sni_judge_line PASS "后量子就绪度" "协商 ${group:-后量子混合组}；证书链 ${chain_bytes} 字节（>3500）"
    return 0
  fi

  if [[ "${pq}" == "true" ]]; then
    key_text="已协商 ${group:-后量子混合组}"
  elif [[ -n "${group}" ]]; then
    key_text="未协商后量子混合组（当前 ${group}）"
  else
    key_text="未协商后量子混合组"
  fi
  if [[ "${chain_bytes}" -gt 3500 ]]; then
    chain_text="证书链 ${chain_bytes} 字节（>3500）"
  else
    chain_text="证书链 ${chain_bytes} 字节（未超过 3500）"
  fi
  sni_judge_line WARN "后量子就绪度" "${key_text}；${chain_text}"
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

  # 第 9 项：目标是否在 CDN 后
  # 签发者只能证明证书链是谁签的，不能证明站点是否在 CDN 后：CDN 品牌的 CA 同样
  # 服务直接回源的站点，公共 CA 也大量签在被 CDN 代理的域名上。这里只陈述事实并把
  # 结论标成未验证，不再用 CA 品牌冒充 CDN 证据（D09/H18）。
  if [[ -n "${issuer_line}" ]]; then
    sni_judge_line NA "CDN 前置" "未验证：签发者「${issuer_line}」只说明证书链来源，不能证明站点在 CDN 后"
  else
    sni_judge_line NA "CDN 前置" "未验证：未读到签发者；CA 品牌不能证明站点在 CDN 后"
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
  # 相对跳转（/path、path、//host/path）都是站点内的跳转，不能按跨主机判掉；
  # 只有真正落到别的主机名的跳转才是 FAIL（D09）。
  if [[ "${code}" == "000" || -z "${code}" ]]; then
    sni_judge_line FAIL "HTTP 跳转" "HTTP 请求失败（可能被反爬或不可达）"
  elif [[ "${code}" =~ ^3[0-9][0-9]$ ]]; then
    if [[ -z "${redirect_url}" ]]; then
      sni_judge_line WARN "HTTP 跳转" "${code}（没有可解析的 Location）"
    elif sni_redirect_is_relative "${redirect_url}"; then
      sni_judge_line WARN "HTTP 跳转" "${code} -> ${redirect_url}（相对跳转，仍在本主机）"
    else
      redirect_host="$(sni_redirect_host "${redirect_url}")"
      if [[ -z "${redirect_host}" || "${redirect_host,,}" == "${sni,,}" ]]; then
        sni_judge_line WARN "HTTP 跳转" "${code} -> ${redirect_url}（同主机跳转）"
      else
        sni_judge_line FAIL "HTTP 跳转" "${code} -> ${redirect_url}（跨主机跳转，请直接使用 ${redirect_host}）"
      fi
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

# 探测预算时钟：date 不可用或被桩掉时按 0 处理，展示层的算术不能因此炸掉。
sni_now_epoch() {
  local now=""

  now="$(date '+%s' 2>/dev/null || true)"
  [[ "${now}" =~ ^[0-9]+$ ]] || now=0
  printf '%s' "${now}"
}

run_sni_checks() {
  local sni="${1}"
  local target="${2}"
  local server_ip="${3}"
  local timeout="${4}"
  local dns_output=""
  local tls_output=""
  local cert_output=""
  local http_output=""
  local pq_output=""
  local target_host="${target%:*}"
  local stage_count=5
  local dns_status=0
  local stage_start=0
  local round_start=0
  local line=""
  local level=""
  local name=""
  local detail=""
  local fails=0
  local warns=0
  local unverified=0
  local budget=$((stage_count * timeout))

  round_start="$(sni_now_epoch)"
  printf '%s\n' "Reality 目标域名预检: ${sni}  (target ${target})"
  printf '%s\n' "等待上界: ${stage_count} 个探针 × ${timeout}s = ${budget}s，每个探针只跑一次并同时供展示与判定使用"

  # 一次采集：四个探针各跑一次，结果既用于判定也用于展示，不再重复慢探测（D07/H21）。
  stage_start="$(sni_now_epoch)"
  printf '[1/%s] DNS 解析（预算 %ss）… ' "${stage_count}" "${timeout}"
  dns_status=0
  dns_output="$(sni_probe_dns "${target_host}" "${timeout}")" || dns_status=$?
  printf '完成 %ss\n' "$(( $(sni_now_epoch) - stage_start ))"

  stage_start="$(sni_now_epoch)"
  printf '[2/%s] TLS 1.3 握手（预算 %ss）… ' "${stage_count}" "${timeout}"
  tls_output="$(sni_probe_tls "${target}" "${sni}" "${timeout}")" || tls_output=""
  printf '完成 %ss\n' "$(( $(sni_now_epoch) - stage_start ))"

  stage_start="$(sni_now_epoch)"
  printf '[3/%s] 证书读取（预算 %ss）… ' "${stage_count}" "${timeout}"
  cert_output="$(sni_probe_cert "${target}" "${sni}" "${timeout}")" || cert_output=""
  printf '完成 %ss\n' "$(( $(sni_now_epoch) - stage_start ))"

  stage_start="$(sni_now_epoch)"
  printf '[4/%s] HTTP 探测（预算 %ss）… ' "${stage_count}" "${timeout}"
  http_output="$(sni_probe_http "${sni}" "${target}" "${timeout}")" || http_output=""
  printf '完成 %ss\n' "$(( $(sni_now_epoch) - stage_start ))"

  stage_start="$(sni_now_epoch)"
  printf '[5/%s] 后量子就绪度（预算 %ss）… ' "${stage_count}" "${timeout}"
  pq_output="$(sni_probe_pq "${target}" "${sni}" "${timeout}" "${server_ip}")" || pq_output=""
  printf '完成 %ss\n' "$(( $(sni_now_epoch) - stage_start ))"

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
      NA)
        unverified=$((unverified + 1))
        printf '%s %s %s\n' "$(style_text "${C_CYAN}" "未验证")" "$(printf '%-14s' "${name}")" "${detail}"
        ;;
      *)
        fails=$((fails + 1))
        printf '%s %s %s\n' "$(style_text "${C_RED}" "FAIL")" "$(printf '%-14s' "${name}")" "${detail}"
        ;;
    esac
  done <<EOF
$(sni_judge_hostname "${sni}")
$(sni_judge_dns "${sni}" "${target_host}" "${dns_output}" "${server_ip}" "${dns_status}")
$(sni_judge_tls "${tls_output}")
$(sni_judge_pq "${pq_output}")
$(sni_judge_cert "${sni}" "${cert_output}" "$(date '+%s')")
$(sni_judge_http "${sni}" "${http_output}")
EOF

  if [[ "${fails}" -gt 0 ]]; then
    printf '%s\n' "结论: 不通过（${fails} FAIL, ${warns} WARN, ${unverified} 未验证）；本轮等待上界 ${budget}s，实际 $(( $(sni_now_epoch) - round_start ))s"
    printf '%s\n' "安装时可用 --skip-sni-check 强行跳过（跳过不等于通过）。"
    return 2
  fi

  printf '%s\n' "结论: 通过（0 FAIL, ${warns} WARN, ${unverified} 未验证）；本轮等待上界 ${budget}s，实际 $(( $(sni_now_epoch) - round_start ))s"
  return 0
}

sni_check_cmd() {
  local sni=""
  local target=""
  local timeout="10"
  local server_ip=""
  local sni_given=0
  local target_given=0
  local server_ip_given=0
  local normalized=""

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --target|--target=*)
        option_take_value "--target" "${1}" "${@:2}"
        target="${OPTION_VALUE}"
        target_given=1
        shift "${OPTION_ARGS_CONSUMED}"
        ;;
      --timeout|--timeout=*)
        option_take_value "--timeout" "${1}" "${@:2}"
        timeout="${OPTION_VALUE}"
        shift "${OPTION_ARGS_CONSUMED}"
        ;;
      --server-ip|--server-ip=*)
        option_take_value "--server-ip" "${1}" "${@:2}"
        server_ip="${OPTION_VALUE}"
        server_ip_given=1
        shift "${OPTION_ARGS_CONSUMED}"
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
        sni_given=1
        shift
        ;;
    esac
  done

  # 0 / 00 / 负数 / 文本都等于「没有上界」，一律拒绝；前导零规范化（D07）。
  normalized="$(sni_normalize_timeout "${timeout}")" \
    || die "--timeout 必须是正整数秒（0 表示无上界，不接受）：${timeout}"
  timeout="${normalized}"

  # 有任意一项要走默认值，就先读已保存的安装上下文；只读，不写 state。
  if [[ "${sni_given}" -eq 0 || "${target_given}" -eq 0 || "${server_ip_given}" -eq 0 ]]; then
    load_existing_state
    if [[ -f "${XRAY_CONFIG_FILE}" ]]; then
      load_config_runtime_context || return 1
    fi
  fi

  if [[ "${sni_given}" -eq 0 ]]; then
    sni="${REALITY_SNI:-}"
  fi
  [[ -n "${sni}" ]] || die "请指定要检查的域名。"

  # target 解析（D09/H08）：显式 --target 优先；显式域名用该域名自己的默认目标，
  # 不带入旧节点的 target；菜单入口（无参数）才用保存的 REALITY_TARGET，
  # 只有确实没有 target 时才回退 SNI:443。
  if [[ "${target_given}" -eq 0 ]]; then
    if [[ "${sni_given}" -eq 1 ]]; then
      target="$(default_reality_target_for_sni "${sni}")"
    else
      target="${REALITY_TARGET:-$(default_reality_target_for_sni "${sni}")}"
    fi
  fi
  [[ -n "${target}" ]] || die "请指定要检查的域名。"
  validate_hostport_value "REALITY 目标地址" "${target}"

  # CLI 显式给出的 server-ip 不被 state 覆盖（D09）。
  if [[ "${server_ip_given}" -eq 0 ]]; then
    server_ip="${SERVER_IP:-}"
  fi

  # 域名/目标/本机地址三者一起进探测层：HTTP 与 TLS/证书用同一目标，
  # 逻辑 SNI/Host 保持为被检查的域名（D09）。
  run_sni_checks "${sni}" "${target}" "${server_ip}" "${timeout}"
}

# 安装 / change-sni 预检入口 --------------------------------------------

preflight_check_reality_sni() {
  local rounds=0
  local answer=""
  local target="${REALITY_TARGET:-$(default_reality_target_for_sni "${REALITY_SNI}")}"

  if [[ "${SKIP_SNI_CHECK:-0}" == "1" ]]; then
    SNI_PREFLIGHT_SKIPPED=1
    warn "已按要求跳过 Reality 目标域名预检；结论是未验证，不因跳过而变成通过。"
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

    read_line_or_cancel answer "重新输入 SNI (r) / 忽略继续 (i) / 退出 (q) [r]: " || return $?
    answer="${answer:-r}"
    case "${answer}" in
      r|R)
        prompt_with_default REALITY_SNI "REALITY 可见 SNI" "" || return $?
        prompt_with_default REALITY_TARGET "REALITY 目标地址 host:port" "$(default_reality_target_for_sni "${REALITY_SNI}")" || return $?
        target="${REALITY_TARGET}"
        ;;
      i|I)
        SNI_PREFLIGHT_IGNORED=1
        warn "已忽略本次预检失败并继续安装；结论仍是不通过，可用 xtun check-sni 复检。"
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
