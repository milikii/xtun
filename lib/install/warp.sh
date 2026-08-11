# shellcheck shell=bash

# ------------------------------
# WARP 出站层
# 负责 Cloudflare WARP 的 WireGuard 凭据供给
# 出站由 Xray 内置 wireguard 协议承载，不安装守护进程
# ------------------------------

warp_generate_x25519_keypair() {
  local key_pem=""
  local private_key=""
  local public_key=""

  key_pem="$(openssl genpkey -algorithm X25519 2>/dev/null)" || return 1
  private_key="$(printf '%s\n' "${key_pem}" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 -w0)" || return 1
  public_key="$(printf '%s\n' "${key_pem}" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0)" || return 1

  [[ -n "${private_key}" && -n "${public_key}" ]] || return 1
  printf '%s\n%s\n' "${private_key}" "${public_key}"
}

warp_reserved_from_client_id() {
  local client_id="${1:-}"
  local decoded_bytes=""

  [[ -n "${client_id}" ]] || return 0
  decoded_bytes="$(printf '%s' "${client_id}" | base64 -d 2>/dev/null | od -An -tu1 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | paste -sd, -)" || return 0
  printf '%s' "${decoded_bytes}"
}

warp_register_free_device() {
  local install_id=""
  local keypair=""
  local private_key=""
  local public_key=""
  local response=""
  local client_id=""
  local address_v4=""
  local address_v6=""
  local peer_public_key=""
  local peer_host=""
  local peer_port=""

  log_step "正在向 Cloudflare 注册免费 WARP 设备。"
  keypair="$(warp_generate_x25519_keypair)" || {
    warn "生成 WireGuard 密钥对失败。"
    return 1
  }
  private_key="$(printf '%s\n' "${keypair}" | sed -n '1p')"
  public_key="$(printf '%s\n' "${keypair}" | sed -n '2p')"
  install_id="$(head -c 16 /dev/urandom | base64 -w0 | tr -d '=+/' | cut -c1-22)"

  response="$(curl -fsSL --max-time 20 \
    -X POST "${WARP_REGISTER_API:-${DEFAULT_WARP_REGISTER_API}}" \
    -H 'Content-Type: application/json' \
    -H 'CF-Client-Version: a-6.30-3596' \
    -H 'User-Agent: okhttp/3.12.1' \
    --data "$(jq -cn \
      --arg key "${public_key}" \
      --arg install_id "${install_id}" \
      '{key: $key, install_id: $install_id, fcm_token: "", tos: "2019-06-21T00:00:00.000+02:00", model: "PC", serial_number: $install_id, locale: "en_US"}')" \
    2>/dev/null)" || {
    warn "调用 Cloudflare 注册接口失败；机房 IP 常被拒绝注册。"
    warn "可以在别处执行 wgcf register 取得 profile.conf，再用 --warp-profile @文件路径 导入。"
    return 1
  }

  address_v4="$(printf '%s' "${response}" | jq -r '.config.interface.addresses.v4 // empty' 2>/dev/null)"
  address_v6="$(printf '%s' "${response}" | jq -r '.config.interface.addresses.v6 // empty' 2>/dev/null)"
  peer_public_key="$(printf '%s' "${response}" | jq -r '.config.peers[0].public_key // empty' 2>/dev/null)"
  peer_host="$(printf '%s' "${response}" | jq -r '.config.peers[0].endpoint.host // empty' 2>/dev/null)"
  client_id="$(printf '%s' "${response}" | jq -r '.config.client_id // empty' 2>/dev/null)"

  if [[ -z "${address_v4}" ]]; then
    warn "Cloudflare 注册响应缺少内网地址，无法启用 WARP 出站。"
    warn "可以在别处执行 wgcf register 取得 profile.conf，再用 --warp-profile @文件路径 导入。"
    return 1
  fi

  WARP_PRIVATE_KEY="${private_key}"
  WARP_ADDRESS_V4="${address_v4}"
  WARP_ADDRESS_V6="${address_v6}"
  WARP_PEER_PUBLIC_KEY="${peer_public_key:-${DEFAULT_WARP_PEER_PUBLIC_KEY}}"
  WARP_RESERVED="$(warp_reserved_from_client_id "${client_id}")"
  WARP_MTU="${WARP_MTU:-${DEFAULT_WARP_MTU}}"
  if [[ -n "${peer_host}" ]]; then
    peer_port="${DEFAULT_WARP_ENDPOINT##*:}"
    case "${peer_host}" in
      *:*) WARP_ENDPOINT="${peer_host}" ;;
      *) WARP_ENDPOINT="${peer_host}:${peer_port}" ;;
    esac
  else
    WARP_ENDPOINT="${DEFAULT_WARP_ENDPOINT}"
  fi

  log_success "免费 WARP 设备注册成功。"
}

warp_profile_value() {
  local profile_text="${1}"
  local key_name="${2}"

  printf '%s\n' "${profile_text}" \
    | sed -n "s/^[[:space:]]*${key_name}[[:space:]]*=[[:space:]]*//Ip" \
    | head -n 1 \
    | tr -d '\r'
}

warp_import_profile() {
  local profile_text="${1}"
  local address_line=""
  local address_entry=""
  local address_v4=""
  local address_v6=""
  local private_key=""
  local peer_public_key=""
  local endpoint=""
  local mtu=""
  local reserved=""

  private_key="$(warp_profile_value "${profile_text}" 'PrivateKey')"
  [[ -n "${private_key}" ]] || {
    warn "导入的 WARP profile 缺少 PrivateKey。"
    return 1
  }

  address_line="$(warp_profile_value "${profile_text}" 'Address')"
  while IFS= read -r address_entry; do
    [[ -n "${address_entry}" ]] || continue
    if [[ "${address_entry}" == *:* ]]; then
      address_v6="${address_entry%%/*}"
    else
      address_v4="${address_entry%%/*}"
    fi
  done < <(printf '%s\n' "${address_line}" | tr ',' '\n' | tr -d ' ')

  [[ -n "${address_v4}" || -n "${address_v6}" ]] || {
    warn "导入的 WARP profile 缺少 Address。"
    return 1
  }

  peer_public_key="$(warp_profile_value "${profile_text}" 'PublicKey')"
  endpoint="$(warp_profile_value "${profile_text}" 'Endpoint')"
  mtu="$(warp_profile_value "${profile_text}" 'MTU')"
  reserved="$(warp_profile_value "${profile_text}" 'Reserved')"

  WARP_PRIVATE_KEY="${private_key}"
  WARP_ADDRESS_V4="${address_v4}"
  WARP_ADDRESS_V6="${address_v6}"
  WARP_PEER_PUBLIC_KEY="${peer_public_key:-${DEFAULT_WARP_PEER_PUBLIC_KEY}}"
  WARP_ENDPOINT="${endpoint:-${DEFAULT_WARP_ENDPOINT}}"
  WARP_MTU="${mtu:-${DEFAULT_WARP_MTU}}"
  if [[ -n "${reserved}" ]]; then
    WARP_RESERVED="$(normalize_warp_reserved_value "${reserved}")"
  fi

  log_success "已从 WARP profile 导入 WireGuard 凭据。"
}

warp_credentials_ready() {
  [[ -n "${WARP_PRIVATE_KEY}" ]] || return 1
  [[ -n "${WARP_ADDRESS_V4}" || -n "${WARP_ADDRESS_V6}" ]] || return 1
  [[ -n "${WARP_PEER_PUBLIC_KEY:-${DEFAULT_WARP_PEER_PUBLIC_KEY}}" ]] || return 1
  return 0
}

ensure_warp_credentials() {
  local profile_text=""

  [[ "${ENABLE_WARP}" == "yes" ]] || return 0

  if ! warp_credentials_ready; then
    if [[ -n "${WARP_PROFILE_SOURCE}" ]]; then
      profile_text="${WARP_PROFILE_SOURCE}"
      WARP_PROFILE_SOURCE=""
      warp_import_profile "${profile_text}" || die "导入 WARP profile 失败。"
    else
      if warp_legacy_team_detected; then
        log "检测到旧版 WARP Team（warp-svc + SOCKS5）配置，正在迁移到 Xray 原生 wireguard 出站。"
      fi
      warp_register_free_device \
        || die "无法取得 WARP WireGuard 凭据；请用 --warp-profile @文件路径 导入 wgcf profile.conf，或用 --disable-warp 关闭 WARP 分流。"
    fi
    warp_credentials_ready || die "WARP WireGuard 凭据不完整，无法启用 WARP 出站。"
  fi

  ensure_warp_outbound_format
}

legacy_warp_paths() {
  printf '%s\n' \
    "/var/lib/cloudflare-warp/mdm.xml" \
    "/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg" \
    "/etc/apt/sources.list.d/cloudflare-client.list" \
    "/usr/local/sbin/xtun-warp-health.sh" \
    "/etc/systemd/system/xtun-warp-health.service" \
    "/etc/systemd/system/xtun-warp-health.timer"
}

warp_legacy_team_detected() {
  local path=""

  [[ "$(config_jq_read '.outbounds[] | select(.tag=="WARP") | .protocol')" == "socks" ]] && return 0
  service_exists "warp-svc.service" && return 0
  while IFS= read -r path; do
    [[ -e "${path}" ]] && return 0
  done < <(legacy_warp_paths)

  return 1
}

warp_teardown_legacy() {
  local paths=()
  local path=""
  local had_legacy="no"

  if service_exists "xtun-warp-health.timer" || service_exists "warp-svc.service"; then
    had_legacy="yes"
  fi
  stop_and_disable_service_if_present "xtun-warp-health.timer"
  stop_and_disable_service_if_present "xtun-warp-health.service"
  stop_and_disable_service_if_present "warp-svc.service"

  while IFS= read -r path; do
    if [[ -e "${path}" || -L "${path}" ]]; then
      paths+=("${path}")
      had_legacy="yes"
    fi
  done < <(legacy_warp_paths)

  [[ "${had_legacy}" == "yes" ]] || return 0

  log_step "清理旧版 WARP Team 托管文件。"
  if [[ "${#paths[@]}" -gt 0 ]]; then
    remove_managed_paths "${paths[@]}"
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  log "已停用 warp-svc；若要彻底移除守护进程请执行：apt-get purge -y cloudflare-warp && rm -rf /var/lib/cloudflare-warp"
}
