# shellcheck shell=bash

# ------------------------------
# 环境与通用辅助层
# 负责 IP、随机值、归一化、系统探测与备份
# ------------------------------

guess_server_ip() {
  local guessed=""
  local fallback=""

  guessed="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"

  if is_public_ipv4 "${guessed}"; then
    printf '%s' "${guessed}"
    return
  fi

  fallback="${guessed}"
  guessed="$(fetch_public_ipv4)"
  if is_public_ipv4 "${guessed}"; then
    printf '%s' "${guessed}"
    return
  fi

  if [[ -z "${fallback}" ]]; then
    fallback="$(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}')"
  fi
  printf '%s' "${fallback}"
}

# 取本机全局单播 IPv6：路由探测 + 2000::/3（含 3xxx）前缀校验。
# 链路本地 / ULA / 探测失败一律返回空，视为不支持双栈。
guess_server_ip6() {
  local guessed=""

  guessed="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
  is_global_ipv6 "${guessed}" || return 0
  printf '%s' "${guessed}"
}

# 完整解析 IPv6 文本，不靠前缀猜。
# 以前只看首字符是不是 2/3，于是 `fe80::zzzz`、`2:2:2:2:2:2:2:2:2` 这类
# 明显不是地址的字符串也会被当成全局单播，直接写进客户端链接。
is_ipv6_address() {
  local ip="${1:-}"
  local head=""
  local tail=""
  local group=""
  local count=0
  local -a groups=()

  [[ -n "${ip}" ]] || return 1
  [[ "${ip}" != *[!0-9A-Fa-f:.]* ]] || return 1
  [[ "${ip}" == *:* ]] || return 1

  # 内嵌 IPv4（::ffff:198.51.100.7 这类）：按 IPv4 校验后用两组 0 占位，
  # 剩下的分组逻辑不变。
  if [[ "${ip}" == *.* ]]; then
    is_ipv4 "${ip##*:}" || return 1
    ip="${ip%:*}:0:0"
  fi

  if [[ "${ip}" == *"::"* ]]; then
    head="${ip%%::*}"
    tail="${ip#*::}"
    [[ "${tail}" != *"::"* ]] || return 1
  else
    head="${ip}"
    tail=""
  fi

  if [[ -n "${head}" ]]; then
    IFS=':' read -r -a groups <<< "${head}"
    for group in "${groups[@]}"; do
      [[ "${group}" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
      count=$((count + 1))
    done
  fi
  if [[ -n "${tail}" ]]; then
    IFS=':' read -r -a groups <<< "${tail}"
    for group in "${groups[@]}"; do
      [[ "${group}" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
      count=$((count + 1))
    done
  fi

  # `::` 至少要压缩一组，所以补齐前最多 7 组；没有 `::` 时必须正好 8 组。
  if [[ "${ip}" == *"::"* ]]; then
    [[ "${count}" -le 7 ]]
    return
  fi
  [[ "${count}" -eq 8 ]]
}

is_global_ipv6() {
  local ip="${1:-}"

  is_ipv6_address "${ip}" || return 1
  # 2000::/3：首字符 2 或 3（2001::、2408::、2606::、3fff:: 等全是全局单播）
  [[ "${ip}" =~ ^[23] ]]
}

# 以前这段 awk 在 `exit 1` 之后还是会跑 END 规则，而 END 里的 `exit 0`
# 把退出码又改回 0：`not-an-ip`、`999.999.999.999`、`1.2.3` 全部通过。
# 判定塞进一个变量，只在 END 里 exit 一次。
is_ipv4() {
  local ip="${1:-}"

  [[ -n "${ip}" ]] || return 1
  awk -F'.' '
    BEGIN { bad = 0 }
    NF != 4 { bad = 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/) bad = 1
        else if ($i + 0 > 255) bad = 1
      }
    }
    END { exit bad }
  ' <<<"${ip}" >/dev/null 2>&1
}

is_private_ipv4() {
  local ip="${1:-}"

  is_ipv4 "${ip}" || return 1

  case "${ip}" in
    10.*|127.*|0.*|192.168.*|169.254.*)
      return 0
      ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
      return 0
      ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*)
      return 0
      ;;
  esac

  return 1
}

is_public_ipv4() {
  local ip="${1:-}"

  is_ipv4 "${ip}" || return 1
  is_private_ipv4 "${ip}" && return 1
  return 0
}

fetch_public_ipv4() {
  local url=""
  local ip=""

  for url in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://ipv4.icanhazip.com"
  do
    ip="$(curl -4fsSL --max-time 4 "${url}" 2>/dev/null | tr -d '\r\n')"
    if is_public_ipv4 "${ip}"; then
      printf '%s' "${ip}"
      return
    fi
  done

  return 1
}

random_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

random_hex() {
  local bytes="${1}"

  [[ "${bytes}" =~ ^[1-9][0-9]*$ ]] || return 1
  # 确认前不能为了生成 shortId 安装 openssl；极简系统仍使用内核随机源。
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "${bytes}"
  else
    od -An -N "${bytes}" -tx1 /dev/urandom | tr -d '[:space:]'
  fi
}

# excluded 用于轮换：候选只有 10 个，必须保证换出来的值和原值不同。
random_path() {
  local excluded="${1:-}"
  local value=""
  local attempt=0
  local candidates=(
    "/api/v1/ping"
    "/health"
    "/status/check"
    "/service/healthz"
    "/v1/report"
    "/metrics/pulse"
    "/gateway/ping"
    "/session/refresh"
    "/edge/check"
    "/content/live"
  )

  while [[ "${attempt}" -lt 20 ]]; do
    attempt=$((attempt + 1))
    value="${candidates[$((RANDOM % ${#candidates[@]}))]}"
    if [[ -z "${excluded}" || "${value}" != "${excluded}" ]]; then
      printf '%s' "${value}"
      return 0
    fi
  done
  printf '%s' "${value}"
}

normalize_cert_mode() {
  local input="${1:-}"

  case "${input}" in
    1)
      printf 'self-signed'
      ;;
    self-signed|自签名|selfsigned)
      printf 'self-signed'
      ;;
    2)
      printf 'existing'
      ;;
    existing|现有证书|已有证书|现有)
      printf 'existing'
      ;;
    3)
      printf 'existing'
      ;;
    cf-origin-ca|cloudflare-origin-ca|cloudflare-origin|cf-origin|origin-ca|cfca|cloudflare-originca|cloudflare-ca)
      printf 'existing'
      ;;
    4)
      printf 'acme-dns-cf'
      ;;
    acme-dns-cf|acme|acme-dns|acme-cf|acme证书)
      printf 'acme-dns-cf'
      ;;
    *)
      printf '%s' "${input}"
      ;;
  esac
}

# 菜单使用独立的 1/2/3 编号；prompt_cert_mode_selection 负责反向映射。
# normalize_cert_mode 仍保留历史 CLI 的 3=existing、4=ACME，不能拿来解码 UI。
cert_mode_choice_value() {
  case "$(normalize_cert_mode "${1:-}")" in
    self-signed)
      printf '1'
      ;;
    existing)
      printf '2'
      ;;
    acme-dns-cf)
      printf '3'
      ;;
  esac
}

normalize_node_label_prefix() {
  local input="${1:-}"
  local cleaned=""

  cleaned="$(printf '%s' "${input}" \
    | tr '[:lower:]' '[:upper:]' \
    | sed -E 's/[^A-Z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"

  if [[ -z "${cleaned}" || "${cleaned}" == "LOCALHOST" ]]; then
    cleaned="VPS"
  fi

  printf '%s' "${cleaned}"
}

default_node_label_prefix() {
  local guessed=""

  guessed="$(hostname -s 2>/dev/null || true)"
  normalize_node_label_prefix "${guessed}"
}

ensure_debian_family() {
  if [[ ! -f /etc/os-release ]]; then
    die "不支持的系统：找不到 /etc/os-release。"
  fi

  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    debian|ubuntu)
      return
      ;;
  esac

  if [[ "${ID_LIKE:-}" == *debian* ]]; then
    return
  fi

  die "当前脚本仅支持 Debian 和 Ubuntu。"
}

detect_xray_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf '64'
      ;;
    aarch64|arm64)
      printf 'arm64-v8a'
      ;;
    *)
      die "不支持的 CPU 架构：$(uname -m)"
      ;;
  esac
}

backup_session_id() {
  printf '%s' "$(basename "${BACKUP_DIR}")"
}

# 轻量文件清单：一次操作一行，回答「这个路径原本存在吗、是谁的、
# 本次打算创建还是替换、原件快照在哪、摘要是多少」。
# 不引入数据库，就是一个 TSV；卸载、回滚和排障都以它为准。
backup_manifest_file() {
  printf '%s' "${BACKUP_MANIFEST_OVERRIDE:-${BACKUP_DIR:-}/manifest.tsv}"
}

backup_manifest_validate() {
  local record=""
  local header=""
  local fields_header=""

  [[ -n "${BACKUP_DIR:-}" ]] || return 1
  record="$(backup_manifest_file)"
  [[ -f "${record}" && ! -L "${record}" ]] || return 1
  IFS= read -r header < "${record}" || return 1
  [[ "${header}" == $'# xtun-backup-manifest\tv1' || "${header}" == $'# xtun-backup-manifest\tv2' ]] || return 1
  IFS= read -r fields_header < <(sed -n '3p' "${record}") || return 1
  [[ "${fields_header}" == $'# fields\top_id\tpath\texisted\torigin\tintent\tsnapshot\tsha256' ]] || return 1

  awk -F'\t' -v op="$(backup_session_id)" '
    NR == 1 || NR == 3 { next }
    NR == 2 { if ($0 != "# operation\t" op) bad = 1; next }
    {
      if (NF != 7 || $1 != op || seen[$2]++) bad = 1
      if ($2 !~ /^\// || $2 == "/" || $2 ~ /[\r\n]/ || $2 ~ /\/\.?\.?\// || $2 ~ /\/$/ || $2 ~ /\/\.?\.?$/) bad = 1
      if ($4 != "managed" && $4 != "takeover") bad = 1
      if ($3 == "0") {
        if ($5 != "create" || $6 != "-" || $7 != "-") bad = 1
      } else if ($3 == "1") {
        if ($5 != "replace" || $6 == "" || $6 ~ /^\// || $6 ~ /(^|\/)\.\.?(\/|$)/ || $7 !~ /^[a-f0-9]+$/ || length($7) != 64) bad = 1
      } else bad = 1
    }
    END { exit bad ? 1 : 0 }
  ' "${record}"
}

# GNU sync -f 刷新所在文件系统；不能把可选日志的「尽力而为」用于恢复证据。
sync_required_path() {
  local path="${1}"

  while [[ ! -e "${path}" && ! -L "${path}" ]]; do
    path="$(dirname "${path}")" || return 1
  done
  [[ ! -L "${path}" ]] || path="$(dirname "${path}")"
  sync -f "${path}" || return 1
}

durable_replace_file() {
  local temporary="${1}"
  local target="${2}"

  [[ -f "${temporary}" && ! -L "${temporary}" ]] || return 1
  [[ ! -e "${target}" && ! -L "${target}" || -f "${target}" && ! -L "${target}" ]] || return 1
  chmod 0600 "${temporary}" || return 1
  sync_required_path "${temporary}" || return 1
  mv -fT -- "${temporary}" "${target}" || return 1
  sync_required_path "$(dirname "${target}")"
}

backup_manifest_init() {
  local record=""

  [[ -n "${BACKUP_DIR:-}" ]] || return 1
  record="$(backup_manifest_file)"

  {
    printf '# xtun-backup-manifest\tv2\n'
    printf '# operation\t%s\n' "$(backup_session_id)"
    printf '# fields\top_id\tpath\texisted\torigin\tintent\tsnapshot\tsha256\n'
  } > "${record}" || return 1
  chmod 0600 "${record}" || return 1
  backup_manifest_validate || return 1
  sync_required_path "${record}"
}

backup_manifest_has_path() {
  local path="${1}"
  local record=""

  backup_manifest_validate || return 1
  record="$(backup_manifest_file)"
  awk -F'\t' -v target="${path}" '
    $0 ~ /^#/ { next }
    $2 == target { found = 1 }
    END { exit found ? 0 : 1 }
  ' "${record}"
}

backup_manifest_record() {
  local path="${1}"
  local existed="${2}"
  local origin="${3}"
  local intent="${4}"
  local snapshot="${5}"
  local digest="${6}"
  local record=""
  local value=""
  local temporary=""

  for value in "${path}" "${existed}" "${origin}" "${intent}" "${snapshot}" "${digest}"; do
    [[ "${value}" != *$'\t'* && "${value}" != *$'\n'* ]] || return 1
  done
  [[ -n "${BACKUP_DIR:-}" ]] || return 1
  backup_manifest_validate || return 1
  backup_manifest_has_path "${path}" && return 1
  record="$(backup_manifest_file)"

  temporary="$(mktemp "${record}.tmp.XXXXXX")" || return 1
  if ! { cat "${record}" && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(backup_session_id)" "${path}" "${existed}" "${origin}" "${intent}" "${snapshot}" "${digest}" \
    ; } > "${temporary}"; then
    rm -f "${temporary}"
    return 1
  fi
  if ! BACKUP_MANIFEST_OVERRIDE="${temporary}" backup_manifest_validate || ! durable_replace_file "${temporary}" "${record}"; then
    rm -f "${temporary}"
    return 1
  fi
  backup_manifest_validate
}

backup_manifest_field() {
  local path="${1}"
  local field="${2}"
  local record=""

  backup_manifest_validate || return 1
  record="$(backup_manifest_file)"
  awk -F'\t' -v target="${path}" -v want="${field}" '
    $0 ~ /^#/ { next }
    $2 == target && !found { value = $want; found = 1 }
    END { if (!found) exit 1; print value }
  ' "${record}"
}

backup_file_digest() {
  local path="${1}"

  if [[ -L "${path}" ]]; then
    ( set -o pipefail; readlink -- "${path}" | sha256sum | awk '{print $1}' ) || return 1
    return 0
  fi
  if [[ -f "${path}" ]]; then
    ( set -o pipefail; sha256sum < "${path}" | awk '{print $1}' ) || return 1
    return 0
  fi
  if [[ -d "${path}" ]]; then
    # 相对路径、稳定顺序和固定 mtime；同时覆盖空目录、权限及软链接。
    # 旧实现把备份目录的绝对路径算进摘要，复制回原位置后永远无法通过核验。
    ( set -o pipefail
      LC_ALL=C tar --sort=name --format=gnu --mtime=@0 --numeric-owner -cf - -C "${path}" . \
        | sha256sum | awk '{print $1}'
    ) || return 1
    return 0
  fi
  return 1
}

backup_snapshot_name() {
  local path="${1}"
  local digest=""

  digest="$(printf '%s' "${path}" | sha256sum)" || return 1
  printf 'snapshots/%s' "${digest%% *}"
}

backup_path_is_safe() {
  local path="${1}"

  [[ "${path}" == /* && "${path}" != / && "${path}" != */ ]] || return 1
  [[ "${path}" != *$'\t'* && "${path}" != *$'\n'* && "${path}" != *$'\r'* ]] || return 1
  [[ "/${path#/}/" != *//* && "/${path#/}/" != */./* && "/${path#/}/" != */../* ]]
}

# 单次操作里同一个路径只留第一次快照：
# 同一次操作重复备份同一路径时，第二次拿到的可能已经是改过的内容，
# 覆盖第一次就等于把「操作前的状态」丢了——回滚会把坏内容当成原状还原。
backup_path() {
  local path="${1}"
  local origin="${2:-managed}"
  local target=""
  local snapshot=""
  local digest=""

  [[ -n "${BACKUP_DIR:-}" ]] || return 0
  backup_path_is_safe "${path}" || return 1
  backup_manifest_validate || return 1
  if [[ "${GENERATION_ACTIVE:-no}" == "yes" && "${GENERATION_REGISTERING:-no}" != "yes" ]]; then
    if ! generation_has_path "${path}"; then
      warn "路径尚未进入持久恢复清单，拒绝写入：${path}"
      return 1
    fi
  fi
  backup_manifest_has_path "${path}" && return 0
  # 每条记录有独立快照，父目录与子路径不会覆盖对方的首次证据。
  snapshot="$(backup_snapshot_name "${path}")" || return 1
  target="${BACKUP_DIR}/${snapshot}"
  [[ ! -e "${target}" && ! -L "${target}" ]] || return 1

  if [[ ! -e "${path}" && ! -L "${path}" ]]; then
    backup_manifest_record "${path}" "0" "${origin}" "create" "-" "-" || return 1
    return 0
  fi

  mkdir -p "$(dirname "${target}")" || return 1
  cp -aT -- "${path}" "${target}" || return 1
  digest="$(backup_file_digest "${target}")" || return 1
  [[ "${digest}" =~ ^[a-f0-9]{64}$ ]] || return 1
  sync_required_path "${target}" || return 1
  backup_manifest_record "${path}" "1" "${origin}" "replace" "${snapshot}" "${digest}" || return 1
}

restore_backup_path() {
  local path="${1}"
  local backup_path=""
  local existed=""
  local snapshot=""
  local expected_digest=""
  local actual_digest=""
  local verified_digest=""
  local original_caps=""
  local restored_caps=""

  [[ -n "${BACKUP_DIR:-}" ]] || return 1
  backup_manifest_validate || return 1
  existed="$(backup_manifest_field "${path}" 3)" || return 1
  snapshot="$(backup_manifest_field "${path}" 6)" || return 1
  expected_digest="$(backup_manifest_field "${path}" 7)" || return 1

  if [[ "${existed}" == "0" ]]; then
    if [[ -e "${path}" || -L "${path}" ]]; then
      rm -rf "${path}" || return 1
    fi
    return 0
  fi
  [[ "${existed}" == "1" ]] || return 1
  backup_path_is_safe "${path}" || return 1
  [[ "${snapshot}" == "${path#/}" || "${snapshot}" == "$(backup_snapshot_name "${path}")" ]] || return 1
  [[ "${expected_digest}" != "-" ]] || return 2

  backup_path="${BACKUP_DIR}/${snapshot}"
  [[ -e "${backup_path}" || -L "${backup_path}" ]] || return 2
  actual_digest="$(backup_file_digest "${backup_path}")" || return 2
  [[ "${actual_digest}" == "${expected_digest}" ]] || return 2
  verified_digest="${actual_digest}"

  mkdir -p "$(dirname "${path}")" || return 1
  rm -rf "${path}" || return 1
  cp -aT -- "${backup_path}" "${path}" || return 1
  actual_digest="$(backup_file_digest "${path}")" || return 2
  [[ "${actual_digest}" == "${verified_digest}" ]] || return 2
  [[ "$(stat -c '%a:%u:%g' "${backup_path}")" == "$(stat -c '%a:%u:%g' "${path}")" ]] || return 2
  if [[ -f "${path}" && ! -L "${path}" ]] && command -v getcap >/dev/null 2>&1; then
    original_caps="$(getcap "${backup_path}")" || return 2
    restored_caps="$(getcap "${path}")" || return 2
    [[ "${original_caps#"${backup_path}"}" == "${restored_caps#"${path}"}" ]] || return 2
  fi
  return 0
}

takeover_original_path() {
  printf '%s%s' "${ORIGINALS_ROOT}" "${1}"
}

takeover_original_record_file() {
  printf '%s/manifest.tsv' "${ORIGINALS_ROOT}"
}

takeover_manifest_validate() {
  local record="${1:-$(takeover_original_record_file)}"

  [[ -f "${record}" && ! -L "${record}" ]] || return 1
  awk -F'\t' '
    function path_ok(s) {
      return s ~ /^\// && s != "/" && s !~ /[\r\n]/ && s !~ /\/\.?\.?\// && s !~ /\/$/ && s !~ /\/\.?\.?$/
    }
    NR == 1 {
      if ($0 == "# xtun-takeover-manifest\tv1") version=1
      else if ($0 == "# xtun-takeover-manifest\tv2") version=2
      else bad=1
      next
    }
    {
      if (NF != (version == 1 ? 3 : 4) || seen[$1]++ || $2 !~ /^(0|1)$/ || $3 == "") bad=1
      ispath=path_ok($1)
      if (!ispath && $1 !~ /^[a-z0-9][a-z0-9+.-]*(:[a-z0-9-]+)?$/) bad=1
      if (version == 2) {
        if (ispath && $2 == "1") {
          if ($4 != "legacy" && ($4 !~ /^[a-f0-9]+$/ || length($4) != 64)) bad=1
        } else if ($4 != "-") bad=1
      }
    }
    END {exit (bad || !version) ? 1 : 0}
  ' "${record}"
}

takeover_manifest_field() {
  local key="${1}"
  local field="${2}"
  local record=""

  record="$(takeover_original_record_file)"
  takeover_manifest_validate "${record}" || return 1
  awk -F'\t' -v key="${key}" -v field="${field}" '
    NR == 1 {legacy=($2 == "v1"); next}
    $1 == key {
      found=1
      if (field == 4 && legacy) print ($1 ~ /^\// && $2 == "1" ? "legacy" : "-")
      else print $field
    }
    END {if (!found) exit 1}
  ' "${record}"
}

# 新登记写 v2。v1 的原件没有历史摘要，显式记为 legacy，不伪造旧时校验值。
takeover_manifest_record() {
  local key="${1}"
  local existed="${2}"
  local digest="${3}"
  local record=""
  local temporary=""
  local recorded_at=""

  record="$(takeover_original_record_file)"
  [[ ! -L "${ORIGINALS_ROOT}" ]] || return 1
  if [[ -e "${record}" || -L "${record}" ]]; then
    takeover_manifest_validate "${record}" || return 1
    if takeover_manifest_field "${key}" 2 >/dev/null; then return 0; fi
  fi
  mkdir -p "${ORIGINALS_ROOT}" || return 1
  chmod 0700 "${ORIGINALS_ROOT}" || return 1
  temporary="$(mktemp "${record}.tmp.XXXXXX")" || return 1
  recorded_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1
  if ! {
    printf '# xtun-takeover-manifest\tv2\n' &&
    { [[ ! -f "${record}" ]] || awk -F'\t' 'BEGIN {OFS="\t"} NR == 1 {legacy=($2 == "v1"); next}
      {if (legacy) print $0, ($1 ~ /^\// && $2 == "1" ? "legacy" : "-"); else print}' "${record}"; } &&
    printf '%s\t%s\t%s\t%s\n' "${key}" "${existed}" "${recorded_at}" "${digest}"
  } > "${temporary}"; then
    rm -f "${temporary}"
    return 1
  fi
  if ! takeover_manifest_validate "${temporary}" || ! durable_replace_file "${temporary}" "${record}"; then
    rm -f "${temporary}"
    return 1
  fi
  takeover_manifest_validate "${record}"
}

takeover_original_verify() {
  local path="${1}"
  local original=""
  local expected=""

  backup_path_is_safe "${path}" || return 1
  [[ "$(takeover_manifest_field "${path}" 2)" == 1 ]] || return 1
  original="$(takeover_original_path "${path}")"
  [[ -e "${original}" || -L "${original}" ]] || return 1
  expected="$(takeover_manifest_field "${path}" 4)" || return 1
  if [[ "${expected}" == legacy ]]; then
    warn "${path} 的旧原件登记没有历史摘要；本次仅按已有登记与原件恢复，内容完整性未获历史摘要验证。"
    return 0
  fi
  [[ "$(backup_file_digest "${original}")" == "${expected}" ]]
}

restore_takeover_original() {
  local path="${1}"
  local original=""
  local temporary=""

  takeover_original_verify "${path}" || return 1
  original="$(takeover_original_path "${path}")"
  mkdir -p "$(dirname "${path}")" || return 1
  temporary="$(mktemp "$(dirname "${path}")/.$(basename "${path}").restore.XXXXXX")" || return 1
  if ! cp -aT -- "${original}" "${temporary}" \
    || [[ "$(backup_file_digest "${temporary}")" != "$(backup_file_digest "${original}")" ]] \
    || [[ "$(stat -c '%a:%u:%g' "${temporary}")" != "$(stat -c '%a:%u:%g' "${original}")" ]] \
    || ! sync_required_path "${temporary}" || ! mv -fT -- "${temporary}" "${path}"; then
    rm -f "${temporary}"
    return 1
  fi
  sync_required_path "${path}"
}

# 首次接管原件的登记：只认第一次。接管的文件属于别人，
# 必须和会轮转的事务备份分开存放，否则第一份原件会被保留规则清掉。
record_takeover_original() {
  local path="${1}"
  local record=""
  local original=""
  local existed="0"
  local digest="-"
  local temporary=""

  backup_path_is_safe "${path}" || return 1
  record="$(takeover_original_record_file)"
  original="$(takeover_original_path "${path}")"

  if [[ -e "${record}" || -L "${record}" ]]; then
    takeover_manifest_validate "${record}" || return 1
    if existed="$(takeover_manifest_field "${path}" 2)"; then
      [[ "${existed}" == 0 ]] || takeover_original_verify "${path}" || return 1
      return 0
    fi
  fi
  existed="0"
  [[ ! -L "${ORIGINALS_ROOT}" ]] || return 1
  mkdir -p "${ORIGINALS_ROOT}" "$(dirname "${original}")" || return 1
  chmod 0700 "${ORIGINALS_ROOT}" || return 1
  if [[ -e "${path}" || -L "${path}" ]]; then
    if [[ ! -e "${original}" && ! -L "${original}" ]]; then
      temporary="$(mktemp "${original}.tmp.XXXXXX")" || return 1
      if ! cp -aT -- "${path}" "${temporary}" || ! sync_required_path "${temporary}" \
        || ! mv -fT -- "${temporary}" "${original}" || ! sync_required_path "$(dirname "${original}")"; then
        rm -f "${temporary}"
        return 1
      fi
    else
      # 前次可能在登记前中断；仅在目标仍与孤立快照一致时继续，不能用新配置充当旧原件。
      [[ "$(backup_file_digest "${path}")" == "$(backup_file_digest "${original}")" ]] || return 1
      [[ "$(stat -c '%a:%u:%g' "${path}")" == "$(stat -c '%a:%u:%g' "${original}")" ]] || return 1
    fi
    existed="1"
    digest="$(backup_file_digest "${original}")" || return 1
    sync_required_path "${original}" || return 1
  elif [[ -e "${original}" || -L "${original}" ]]; then
    return 1
  fi
  takeover_manifest_record "${path}" "${existed}" "${digest}"
}

takeover_original_existed() {
  takeover_manifest_field "${1}" 2
}

# 只保留成功的操作记录：失败或中断的那一份是排障现场，
# 保留规则不能把唯一一份现场清掉。
prune_backup_sessions() {
  local path=""
  local paths=()
  local index=0

  [[ "${BACKUP_KEEP_COUNT}" =~ ^[0-9]+$ ]] || return 0
  [[ "${BACKUP_KEEP_COUNT}" -gt 0 ]] || return 0
  [[ -d "${BACKUP_ROOT}" ]] || return 0

  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    [[ -f "${path}/completed" ]] || continue
    paths+=("${path}")
  done < <(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}')

  for ((index = BACKUP_KEEP_COUNT; index < ${#paths[@]}; index++)); do
    rm -rf "${paths[index]}"
  done
}

finish_backup_session() {
  [[ -n "${BACKUP_DIR:-}" && -d "${BACKUP_DIR}" ]] || return 0
  : > "${BACKUP_DIR}/completed" || return 1
  sync_required_path "${BACKUP_DIR}/completed" || return 1
  BACKUP_SESSION_OPEN="no"
  [[ "${1:-prune}" == "prune" ]] || return 0
  prune_backup_sessions
}

start_backup_session() {
  begin_mutation || return 1
  mkdir -p "${BACKUP_ROOT}" || return 1
  # 操作 ID 不能只精确到秒：同一秒内的两次操作会共用同一个备份目录，
  # 一旦共用，第一次的原件就被第二次的快照和清理规则搅在一起了。
  BACKUP_DIR="$(mktemp -d "${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)-XXXXXX")" || return 1
  BACKUP_MANIFEST_OVERRIDE=""
  BACKUP_SESSION_OPEN="yes"
  SESSION_LOG_FILE="${BACKUP_DIR}/operation.log"
  backup_manifest_init || return 1
}
