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

is_ipv4() {
  local ip="${1:-}"

  [[ -n "${ip}" ]] || return 1
  awk -F'.' '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/) exit 1
        if ($i < 0 || $i > 255) exit 1
      }
    }
    END { exit 0 }
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
    uuidgen | tr 'A-Z' 'a-z'
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

random_hex() {
  local bytes="${1}"
  openssl rand -hex "${bytes}"
}

random_path() {
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

  printf '%s' "${candidates[$((RANDOM % ${#candidates[@]}))]}"
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
      printf 'cf-origin-ca'
      ;;
    cf-origin-ca|cloudflare-origin-ca|cloudflare-origin|cf-origin|origin-ca|cfca|cloudflare-originca|cloudflare-ca|cf-origin-ca证书|cf-origin-ca模式)
      printf 'cf-origin-ca'
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

cert_mode_choice_value() {
  case "$(normalize_cert_mode "${1:-}")" in
    self-signed)
      printf '1'
      ;;
    existing)
      printf '2'
      ;;
    cf-origin-ca)
      printf '3'
      ;;
    acme-dns-cf)
      printf '4'
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

backup_path() {
  local path="${1}"
  local target=""

  [[ -n "${BACKUP_DIR:-}" ]] || return 0
  if [[ ! -e "${path}" ]]; then
    return
  fi

  target="${BACKUP_DIR}${path}"
  mkdir -p "$(dirname "${target}")"
  cp -a "${path}" "${target}"
}

restore_backup_path() {
  local path="${1}"
  local backup_path=""

  [[ -n "${BACKUP_DIR:-}" ]] || return 1
  backup_path="${BACKUP_DIR}${path}"

  if [[ -e "${backup_path}" || -L "${backup_path}" ]]; then
    mkdir -p "$(dirname "${path}")"
    rm -rf "${path}"
    cp -a "${backup_path}" "${path}"
    return 0
  fi

  rm -rf "${path}"
  return 0
}

start_backup_session() {
  local path=""
  local paths=()
  local index=0

  BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_DIR}"
  SESSION_LOG_FILE="${BACKUP_DIR}/operation.log"

  [[ "${BACKUP_KEEP_COUNT}" =~ ^[0-9]+$ ]] || return 0
  [[ "${BACKUP_KEEP_COUNT}" -gt 0 ]] || return 0

  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    paths+=("${path}")
  done < <(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}')

  for ((index = BACKUP_KEEP_COUNT; index < ${#paths[@]}; index++)); do
    rm -rf "${paths[index]}"
  done
}
