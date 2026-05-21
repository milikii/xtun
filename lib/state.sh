# shellcheck shell=bash

# ------------------------------
# 状态与配置读取层
# 负责状态文件、托管输出、配置回填
# ------------------------------

config_jq_read() {
  local filter="${1}"

  [[ -f "${XRAY_CONFIG_FILE}" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    if [[ "${STATE_JQ_MISSING_WARNED:-0}" != "1" ]]; then
      warn "当前系统缺少 jq，无法读取托管配置：${XRAY_CONFIG_FILE}"
      STATE_JQ_MISSING_WARNED="1"
    fi
    return 0
  fi

  jq -r "${filter} // empty" "${XRAY_CONFIG_FILE}" 2>/dev/null || true
}

output_field_value() {
  local field_name="${1}"

  [[ -f "${OUTPUT_FILE}" ]] || return 0
  sed -n "s/^- ${field_name}: //p" "${OUTPUT_FILE}" | head -n 1
}

warp_mdm_value() {
  local key_name="${1}"

  [[ -f "${WARP_MDM_FILE}" ]] || return 0

  awk -v key_name="${key_name}" '
    $0 ~ "<key>" key_name "</key>" {
      getline
      line=$0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line ~ /^<string>/) {
        sub(/^<string>/, "", line)
        sub(/<\/string>$/, "", line)
        print line
        exit
      }
      if (line ~ /^<integer>/) {
        sub(/^<integer>/, "", line)
        sub(/<\/integer>$/, "", line)
        print line
        exit
      }
    }
  ' "${WARP_MDM_FILE}" 2>/dev/null || true
}

load_warp_mdm_context() {
  WARP_TEAM_NAME="${WARP_TEAM_NAME:-$(warp_mdm_value 'organization')}"
  WARP_CLIENT_ID="${WARP_CLIENT_ID:-$(warp_mdm_value 'auth_client_id')}"
  WARP_CLIENT_SECRET="${WARP_CLIENT_SECRET:-$(warp_mdm_value 'auth_client_secret')}"
  WARP_PROXY_PORT="${WARP_PROXY_PORT:-$(warp_mdm_value 'proxy_port')}"
}

state_file_key_allowed() {
  case "${1}" in
    STATE_VERSION|SERVER_IP|NODE_LABEL_PREFIX|REALITY_UUID|REALITY_SNI|REALITY_TARGET|REALITY_SHORT_ID|REALITY_PRIVATE_KEY|REALITY_PUBLIC_KEY|XHTTP_UUID|XHTTP_DOMAIN|XHTTP_PATH|XHTTP_VLESS_ENCRYPTION_ENABLED|XHTTP_VLESS_DECRYPTION|XHTTP_VLESS_ENCRYPTION|TLS_ALPN|FINGERPRINT|ENABLE_WARP|ENABLE_NET_OPT|WARP_PROXY_PORT|WARP_TEAM_NAME|WARP_CLIENT_ID|WARP_CLIENT_SECRET|WARP_RULES_TEXT|CERT_MODE|CERT_SOURCE_FILE|KEY_SOURCE_FILE|CERT_SOURCE_PEM|KEY_SOURCE_PEM|CF_ZONE_ID|CF_API_TOKEN|CF_CERT_VALIDITY|ACME_EMAIL|ACME_CA|CF_DNS_TOKEN|CF_DNS_ACCOUNT_ID|CF_DNS_ZONE_ID|XHTTP_ECH_CONFIG_LIST|XHTTP_ECH_FORCE_QUERY|XHTTP_XPADDING_ENABLED|XHTTP_XPADDING_KEY|XHTTP_XPADDING_HEADER|XHTTP_XPADDING_PLACEMENT|XHTTP_XPADDING_METHOD|NODE_CLIENTS_TEXT|CORE_HEALTH_LAST_CHECK_AT|CORE_HEALTH_LAST_ACTION|CORE_HEALTH_LAST_REASON|WARP_HEALTH_LAST_CHECK_AT|WARP_HEALTH_LAST_ACTION|WARP_HEALTH_LAST_REASON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

decode_simple_shell_word() {
  local raw="${1-}"
  local decoded=""
  local char=""
  local index=0

  while [[ "${index}" -lt "${#raw}" ]]; do
    char="${raw:index:1}"
    if [[ "${char}" == '\' && $((index + 1)) -lt "${#raw}" ]]; then
      decoded+="${raw:index+1:1}"
      index=$((index + 2))
      continue
    fi

    decoded+="${char}"
    index=$((index + 1))
  done

  printf '%s' "${decoded}"
}

decode_ansi_c_shell_word() {
  local raw="${1}"
  local content="${raw:2:${#raw}-3}"
  local decoded=""
  local char=""
  local next_char=""
  local seq=""
  local decoded_char=""
  local index=0
  local max_index=0
  local hex=""
  local octal=""

  max_index="${#content}"
  while [[ "${index}" -lt "${max_index}" ]]; do
    char="${content:index:1}"
    if [[ "${char}" != '\' || $((index + 1)) -ge "${max_index}" ]]; then
      decoded+="${char}"
      index=$((index + 1))
      continue
    fi

    next_char="${content:index+1:1}"
    case "${next_char}" in
      a) decoded+=$'\a'; index=$((index + 2)) ;;
      b) decoded+=$'\b'; index=$((index + 2)) ;;
      e|E) decoded+=$'\033'; index=$((index + 2)) ;;
      f) decoded+=$'\f'; index=$((index + 2)) ;;
      n) decoded+=$'\n'; index=$((index + 2)) ;;
      r) decoded+=$'\r'; index=$((index + 2)) ;;
      t) decoded+=$'\t'; index=$((index + 2)) ;;
      v) decoded+=$'\v'; index=$((index + 2)) ;;
      \\) decoded+='\'; index=$((index + 2)) ;;
      \') decoded+="'"; index=$((index + 2)) ;;
      \") decoded+='"'; index=$((index + 2)) ;;
      x)
        hex=""
        if [[ $((index + 2)) -lt "${max_index}" && "${content:index+2:1}" =~ [[:xdigit:]] ]]; then
          hex+="${content:index+2:1}"
        fi
        if [[ $((index + 3)) -lt "${max_index}" && "${content:index+3:1}" =~ [[:xdigit:]] ]]; then
          hex+="${content:index+3:1}"
        fi
        if [[ -n "${hex}" ]]; then
          printf -v decoded_char '%b' "\\x${hex}"
          decoded+="${decoded_char}"
          index=$((index + 2 + ${#hex}))
        else
          decoded+='x'
          index=$((index + 2))
        fi
        ;;
      [0-7])
        octal="${next_char}"
        if [[ $((index + 2)) -lt "${max_index}" && "${content:index+2:1}" =~ [0-7] ]]; then
          octal+="${content:index+2:1}"
        fi
        if [[ $((index + 3)) -lt "${max_index}" && "${content:index+3:1}" =~ [0-7] ]]; then
          octal+="${content:index+3:1}"
        fi
        printf -v decoded_char '%b' "\\${octal}"
        decoded+="${decoded_char}"
        index=$((index + 1 + ${#octal}))
        ;;
      *)
        decoded+="${next_char}"
        index=$((index + 2))
        ;;
    esac
  done

  printf '%s' "${decoded}"
}

decode_state_value() {
  local raw="${1-}"

  if [[ "${raw}" == "''" ]]; then
    printf '%s' ""
    return
  fi

  if [[ "${raw}" == \'*\' ]]; then
    printf '%s' "${raw:1:${#raw}-2}"
    return
  fi

  if [[ "${raw}" == \$\'*\' ]]; then
    decode_ansi_c_shell_word "${raw}"
    return
  fi

  decode_simple_shell_word "${raw}"
}

load_shell_kv_file() {
  local file_path="${1}"
  local line=""
  local key=""
  local raw_value=""
  local decoded_value=""

  [[ -f "${file_path}" ]] || return 0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" != \#* ]] || continue
    [[ "${line}" == *=* ]] || continue

    key="${line%%=*}"
    raw_value="${line#*=}"
    state_file_key_allowed "${key}" || continue
    decoded_value="$(decode_state_value "${raw_value}")"
    printf -v "${key}" '%s' "${decoded_value}"
  done < "${file_path}"
}

reset_loaded_runtime_context() {
  REALITY_UUID=""
  REALITY_SNI=""
  REALITY_TARGET=""
  REALITY_SHORT_ID=""
  REALITY_PRIVATE_KEY=""
  REALITY_PUBLIC_KEY=""
  XHTTP_UUID=""
  XHTTP_DOMAIN=""
  XHTTP_PATH=""
  XHTTP_VLESS_ENCRYPTION_ENABLED=""
  XHTTP_VLESS_DECRYPTION=""
  XHTTP_VLESS_ENCRYPTION=""
  TLS_ALPN=""
  SERVER_IP=""
  NODE_LABEL_PREFIX=""
  FINGERPRINT=""
  ENABLE_WARP=""
  ENABLE_NET_OPT=""
  WARP_PROXY_PORT=""
  WARP_TEAM_NAME=""
  WARP_CLIENT_ID=""
  WARP_CLIENT_SECRET=""
  WARP_RULES_TEXT=""
  CERT_MODE=""
  CERT_SOURCE_FILE=""
  KEY_SOURCE_FILE=""
  CERT_SOURCE_PEM=""
  KEY_SOURCE_PEM=""
  CF_ZONE_ID=""
  CF_API_TOKEN=""
  CF_CERT_VALIDITY=""
  ACME_EMAIL=""
  ACME_CA=""
  CF_DNS_TOKEN=""
  CF_DNS_ACCOUNT_ID=""
  CF_DNS_ZONE_ID=""
  XHTTP_ECH_CONFIG_LIST=""
  XHTTP_ECH_FORCE_QUERY=""
  XHTTP_XPADDING_ENABLED=""
  XHTTP_XPADDING_KEY=""
  XHTTP_XPADDING_HEADER=""
  XHTTP_XPADDING_PLACEMENT=""
  XHTTP_XPADDING_METHOD=""
  NODE_CLIENTS_TEXT=""
  OUTPUT_CLIENT_NAME=""
  LINK_CLIENT_NAME=""
  LINK_REALITY_UUID=""
  LINK_XHTTP_UUID=""
  CORE_HEALTH_LAST_CHECK_AT=""
  CORE_HEALTH_LAST_ACTION=""
  CORE_HEALTH_LAST_REASON=""
  WARP_HEALTH_LAST_CHECK_AT=""
  WARP_HEALTH_LAST_ACTION=""
  WARP_HEALTH_LAST_REASON=""
  STATE_JQ_MISSING_WARNED=""
}

nginx_server_name() {
  local path_hint="${1}"

  [[ -f "${NGINX_CONFIG_FILE}" ]] || return 0
  awk -v path_hint="${path_hint}" '
    function brace_delta(line, opens, closes, tmp) {
      tmp = line
      opens = gsub(/\{/, "{", tmp)
      closes = gsub(/\}/, "}", tmp)
      return opens - closes
    }

    /^[[:space:]]*server[[:space:]]*\{/ {
      in_server = 1
      depth = brace_delta($0)
      current = ""
      wanted = 0
      next
    }

    in_server {
      if ($0 ~ /^[[:space:]]*server_name[[:space:]]+/) {
        line = $0
        sub(/^[[:space:]]*server_name[[:space:]]+/, "", line)
        sub(/;.*/, "", line)
        current = line
      }

      if ($0 ~ /^[[:space:]]*location[[:space:]]+\// && index($0, path_hint)) {
        wanted = 1
      }

      if (wanted && current != "") {
        print current
        exit
      }

      depth += brace_delta($0)
      if (depth <= 0) {
        in_server = 0
        current = ""
        wanted = 0
      }
    }
  ' "${NGINX_CONFIG_FILE}" 2>/dev/null | head -n 1
}

load_existing_state() {
  reset_loaded_runtime_context

  if [[ -f "${STATE_FILE}" ]]; then
    load_shell_kv_file "${STATE_FILE}"
    if [[ "${STATE_VERSION:-0}" != "${STATE_VERSION_CURRENT}" ]]; then
      warn "检测到旧版本状态文件（${STATE_VERSION:-0} -> ${STATE_VERSION_CURRENT}），将按当前脚本默认值补全缺失字段。"
    fi
  fi
  if [[ "${XHTTP_ECH_CONFIG_LIST:-}" == "https://1.1.1.1/dns-query" && "${XHTTP_ECH_FORCE_QUERY:-}" == "none" ]]; then
    XHTTP_ECH_CONFIG_LIST=""
    XHTTP_ECH_FORCE_QUERY=""
  fi
  if [[ -f "${HEALTH_STATE_FILE}" ]]; then
    load_shell_kv_file "${HEALTH_STATE_FILE}"
  fi
  load_warp_mdm_context
}

config_has_warp_outbound() {
  [[ "$(config_jq_read '.outbounds[] | select(.tag=="WARP") | .tag')" == "WARP" ]]
}

load_config_runtime_context() {
  REALITY_UUID="${REALITY_UUID:-$(config_jq_read '.inbounds[] | select(.tag=="reality-vision") | .settings.clients[0].id')}"
  REALITY_SNI="${REALITY_SNI:-$(config_jq_read '.inbounds[] | select(.tag=="reality-vision") | .streamSettings.realitySettings.serverNames[0]')}"
  REALITY_TARGET="${REALITY_TARGET:-$(config_jq_read '.inbounds[] | select(.tag=="reality-vision") | .streamSettings.realitySettings.target')}"
  REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(config_jq_read '.inbounds[] | select(.tag=="reality-vision") | .streamSettings.realitySettings.shortIds[0]')}"
  REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-$(config_jq_read '.inbounds[] | select(.tag=="reality-vision") | .streamSettings.realitySettings.privateKey')}"
  XHTTP_UUID="${XHTTP_UUID:-$(config_jq_read '.inbounds[] | select(.tag=="xhttp-cdn") | .settings.clients[0].id')}"
  XHTTP_PATH="${XHTTP_PATH:-$(config_jq_read '.inbounds[] | select(.tag=="xhttp-cdn") | .streamSettings.xhttpSettings.path')}"
  XHTTP_VLESS_DECRYPTION="${XHTTP_VLESS_DECRYPTION:-$(config_jq_read '.inbounds[] | select(.tag=="xhttp-cdn") | .settings.decryption')}"
  TLS_ALPN="${TLS_ALPN:-$(config_jq_read '.inbounds[] | select(.tag=="xhttp-cdn") | .streamSettings.tlsSettings.alpn[0]')}"
  XHTTP_DOMAIN="${XHTTP_DOMAIN:-$(nginx_server_name "${XHTTP_PATH:-/}")}"
  if [[ -z "${ENABLE_WARP:-}" ]]; then
    if config_has_warp_outbound; then
      ENABLE_WARP="yes"
    else
      ENABLE_WARP="no"
    fi
  fi
  WARP_PROXY_PORT="${WARP_PROXY_PORT:-$(config_jq_read '.outbounds[] | select(.tag=="WARP") | .settings.servers[0].port')}"
}

load_output_runtime_context() {
  SERVER_IP="${SERVER_IP:-$(output_field_value '地址')}"
  NODE_LABEL_PREFIX="${NODE_LABEL_PREFIX:-$(output_field_value '节点名前缀')}"
  REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-$(output_field_value '公钥')}"
  FINGERPRINT="${FINGERPRINT:-$(output_field_value '指纹')}"
}

normalize_runtime_defaults() {
  SERVER_IP="${SERVER_IP:-$(guess_server_ip)}"
  NODE_LABEL_PREFIX="${NODE_LABEL_PREFIX:-$(default_node_label_prefix)}"
  TLS_ALPN="${TLS_ALPN:-${DEFAULT_TLS_ALPN}}"
  FINGERPRINT="${FINGERPRINT:-${DEFAULT_FINGERPRINT}}"
  CERT_MODE="${CERT_MODE:-existing}"
  ACME_CA="${ACME_CA:-${DEFAULT_ACME_CA}}"
  XHTTP_ECH_CONFIG_LIST="${XHTTP_ECH_CONFIG_LIST:-${DEFAULT_XHTTP_ECH_CONFIG_LIST}}"
  XHTTP_ECH_FORCE_QUERY="${XHTTP_ECH_FORCE_QUERY:-${DEFAULT_XHTTP_ECH_FORCE_QUERY}}"
  XHTTP_XPADDING_ENABLED="${XHTTP_XPADDING_ENABLED:-${DEFAULT_XHTTP_XPADDING_ENABLED}}"
  XHTTP_XPADDING_KEY="${XHTTP_XPADDING_KEY:-${DEFAULT_XHTTP_XPADDING_KEY}}"
  XHTTP_XPADDING_HEADER="${XHTTP_XPADDING_HEADER:-${DEFAULT_XHTTP_XPADDING_HEADER}}"
  XHTTP_XPADDING_PLACEMENT="${XHTTP_XPADDING_PLACEMENT:-${DEFAULT_XHTTP_XPADDING_PLACEMENT}}"
  XHTTP_XPADDING_METHOD="${XHTTP_XPADDING_METHOD:-${DEFAULT_XHTTP_XPADDING_METHOD}}"
  ENABLE_NET_OPT="${ENABLE_NET_OPT:-$(if [[ -f "${NET_SERVICE_FILE}" || -f "${NET_SYSCTL_CONF}" ]]; then printf 'yes'; else printf 'no'; fi)}"
  WARP_PROXY_PORT="${WARP_PROXY_PORT:-${DEFAULT_WARP_PROXY_PORT}}"
}

sync_xhttp_vless_encryption_state() {
  if [[ "${XHTTP_VLESS_DECRYPTION:-}" == "none" || -z "${XHTTP_VLESS_DECRYPTION:-}" ]]; then
    XHTTP_VLESS_ENCRYPTION_ENABLED="${XHTTP_VLESS_ENCRYPTION_ENABLED:-no}"
  else
    XHTTP_VLESS_ENCRYPTION_ENABLED="${XHTTP_VLESS_ENCRYPTION_ENABLED:-yes}"
  fi
}

load_managed_runtime_context() {
  # ------------------------------
  # 托管上下文只在这里回填一次
  # UI 与 change-* 共用同一份事实来源
  # ------------------------------
  load_config_runtime_context
  load_output_runtime_context
  normalize_runtime_defaults
  sync_xhttp_vless_encryption_state
}

load_dashboard_context() {
  load_existing_state

  [[ -f "${XRAY_CONFIG_FILE}" ]] || return 0
  load_managed_runtime_context
}

require_current_install_context() {
  [[ -n "${REALITY_UUID}" ]] || die "无法从当前安装中识别 REALITY UUID。"
  [[ -n "${REALITY_SNI}" ]] || die "无法从当前安装中识别 REALITY SNI。"
  [[ -n "${REALITY_TARGET}" ]] || die "无法从当前安装中识别 REALITY 目标地址。"
  [[ -n "${REALITY_SHORT_ID}" ]] || die "无法从当前安装中识别 REALITY 短 ID。"
  [[ -n "${REALITY_PRIVATE_KEY}" ]] || die "无法从当前安装中识别 REALITY 私钥。"
  [[ -n "${XHTTP_UUID}" ]] || die "无法从当前安装中识别 XHTTP UUID。"
  [[ -n "${XHTTP_DOMAIN}" ]] || die "无法从当前安装中识别 XHTTP 域名。"
  [[ -n "${XHTTP_PATH}" ]] || die "无法从当前安装中识别 XHTTP 路径。"
}

load_current_install_context() {
  load_existing_state

  [[ -f "${XRAY_CONFIG_FILE}" ]] || die "找不到当前 Xray 配置：${XRAY_CONFIG_FILE}"
  load_managed_runtime_context
  require_current_install_context
}

uri_encode() {
  local input="${1}"

  if command -v jq >/dev/null 2>&1; then
    jq -rn --arg v "${input}" '$v|@uri'
    return
  fi

  printf '%s' "${input}" \
    | sed \
      -e 's/%/%25/g' \
      -e 's/:/%3A/g' \
      -e 's/\//%2F/g' \
      -e 's/+/%2B/g' \
      -e 's/=/%3D/g' \
      -e 's/?/%3F/g' \
      -e 's/&/%26/g'
}

path_to_uri_component() {
  uri_encode "${1}"
}

default_node_client_name() {
  printf 'default'
}

ensure_node_client_name_format() {
  local client_name="${1:-}"

  [[ -n "${client_name}" ]] || die "客户端名称不能为空。"
  [[ "${client_name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "客户端名称只能包含字母、数字、点、下划线或横线。"
}

ensure_new_node_client_name_format() {
  local client_name="${1:-}"

  ensure_node_client_name_format "${client_name}"
  [[ "${client_name}" != "$(default_node_client_name)" ]] || die "default 是内置客户端名称，不能重复添加。"
}

ensure_node_client_uuid_format() {
  local label="${1}"
  local uuid="${2:-}"

  [[ "${uuid}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || die "${label} 不是合法 UUID。"
}

node_client_record_line() {
  local client_name="${1}"
  local reality_uuid="${2}"
  local xhttp_uuid="${3}"

  printf '%s|%s|%s\n' "${client_name}" "${reality_uuid}" "${xhttp_uuid}"
}

node_extra_clients_text() {
  local line=""
  local client_name=""
  local reality_uuid=""
  local xhttp_uuid=""
  local _extra=""

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    IFS='|' read -r client_name reality_uuid xhttp_uuid _extra <<< "${line}"
    [[ -n "${client_name}" && -n "${reality_uuid}" && -n "${xhttp_uuid}" ]] || continue
    [[ "${client_name}" != "$(default_node_client_name)" ]] || continue
    node_client_record_line "${client_name}" "${reality_uuid}" "${xhttp_uuid}"
  done <<< "${NODE_CLIENTS_TEXT:-}"
}

node_clients_text() {
  if [[ -n "${REALITY_UUID:-}" && -n "${XHTTP_UUID:-}" ]]; then
    node_client_record_line "$(default_node_client_name)" "${REALITY_UUID}" "${XHTTP_UUID}"
  fi

  node_extra_clients_text
}

node_client_record_for_name() {
  local wanted_name="${1}"
  local client_name=""
  local reality_uuid=""
  local xhttp_uuid=""
  local records=""

  ensure_node_client_name_format "${wanted_name}"
  records="$(node_clients_text)"
  while IFS='|' read -r client_name reality_uuid xhttp_uuid; do
    [[ -n "${client_name}" ]] || continue
    if [[ "${client_name}" == "${wanted_name}" ]]; then
      node_client_record_line "${client_name}" "${reality_uuid}" "${xhttp_uuid}"
      return 0
    fi
  done <<< "${records}"

  return 1
}

node_client_exists() {
  node_client_record_for_name "${1}" >/dev/null
}

node_client_count() {
  local count=0
  local line=""

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    count=$((count + 1))
  done < <(node_clients_text)

  printf '%s' "${count}"
}

node_client_names_text() {
  local client_name=""
  local _reality_uuid=""
  local _xhttp_uuid=""

  while IFS='|' read -r client_name _reality_uuid _xhttp_uuid; do
    [[ -n "${client_name}" ]] || continue
    printf '%s\n' "${client_name}"
  done < <(node_clients_text)
}

node_client_names_csv() {
  local joined=""
  local client_name=""

  while IFS= read -r client_name; do
    [[ -n "${client_name}" ]] || continue
    if [[ -n "${joined}" ]]; then
      joined+=", "
    fi
    joined+="${client_name}"
  done < <(node_client_names_text)

  printf '%s' "${joined}"
}

append_node_client_record() {
  local client_name="${1}"
  local reality_uuid="${2}"
  local xhttp_uuid="${3}"
  local existing_clients=""
  local existing_client_name=""
  local existing_reality_uuid=""
  local existing_xhttp_uuid=""

  ensure_new_node_client_name_format "${client_name}"
  ensure_node_client_uuid_format "REALITY UUID" "${reality_uuid}"
  ensure_node_client_uuid_format "XHTTP UUID" "${xhttp_uuid}"
  if node_client_exists "${client_name}"; then
    die "客户端已存在：${client_name}"
  fi
  while IFS='|' read -r existing_client_name existing_reality_uuid existing_xhttp_uuid; do
    [[ -n "${existing_client_name}" ]] || continue
    if [[ "${existing_reality_uuid}" == "${reality_uuid}" ]]; then
      die "REALITY UUID 已被客户端 ${existing_client_name} 使用。"
    fi
    if [[ "${existing_xhttp_uuid}" == "${xhttp_uuid}" ]]; then
      die "XHTTP UUID 已被客户端 ${existing_client_name} 使用。"
    fi
  done < <(node_clients_text)

  existing_clients="$(node_extra_clients_text)"
  if [[ -n "${existing_clients}" ]]; then
    NODE_CLIENTS_TEXT="${existing_clients}"$'\n'"$(node_client_record_line "${client_name}" "${reality_uuid}" "${xhttp_uuid}")"
  else
    NODE_CLIENTS_TEXT="$(node_client_record_line "${client_name}" "${reality_uuid}" "${xhttp_uuid}")"
  fi
}

write_state_kv() {
  local key="${1}"
  local value="${2-}"

  printf '%s=%q\n' "${key}" "${value}"
}

state_file_text() {
  # ------------------------------
  # 状态文件统一走 shell 转义
  # 避免密钥或路径里的特殊字符污染 source
  # ------------------------------
  write_state_kv "STATE_VERSION" "${STATE_VERSION_CURRENT}"
  write_state_kv "SERVER_IP" "${SERVER_IP}"
  write_state_kv "NODE_LABEL_PREFIX" "${NODE_LABEL_PREFIX}"
  write_state_kv "REALITY_UUID" "${REALITY_UUID}"
  write_state_kv "REALITY_SNI" "${REALITY_SNI}"
  write_state_kv "REALITY_TARGET" "${REALITY_TARGET}"
  write_state_kv "REALITY_SHORT_ID" "${REALITY_SHORT_ID}"
  write_state_kv "REALITY_PRIVATE_KEY" "${REALITY_PRIVATE_KEY}"
  write_state_kv "REALITY_PUBLIC_KEY" "${REALITY_PUBLIC_KEY}"
  write_state_kv "XHTTP_UUID" "${XHTTP_UUID}"
  write_state_kv "XHTTP_DOMAIN" "${XHTTP_DOMAIN}"
  write_state_kv "XHTTP_PATH" "${XHTTP_PATH}"
  write_state_kv "XHTTP_VLESS_ENCRYPTION_ENABLED" "${XHTTP_VLESS_ENCRYPTION_ENABLED}"
  write_state_kv "XHTTP_VLESS_DECRYPTION" "${XHTTP_VLESS_DECRYPTION}"
  write_state_kv "XHTTP_VLESS_ENCRYPTION" "${XHTTP_VLESS_ENCRYPTION}"
  write_state_kv "TLS_ALPN" "${TLS_ALPN:-${DEFAULT_TLS_ALPN}}"
  write_state_kv "FINGERPRINT" "${FINGERPRINT:-${DEFAULT_FINGERPRINT}}"
  write_state_kv "ENABLE_WARP" "${ENABLE_WARP}"
  write_state_kv "ENABLE_NET_OPT" "${ENABLE_NET_OPT}"
  write_state_kv "WARP_PROXY_PORT" "${WARP_PROXY_PORT}"
  write_state_kv "WARP_TEAM_NAME" "${WARP_TEAM_NAME}"
  write_state_kv "WARP_CLIENT_ID" "${WARP_CLIENT_ID}"
  write_state_kv "WARP_CLIENT_SECRET" "${WARP_CLIENT_SECRET}"
  write_state_kv "WARP_RULES_TEXT" "${WARP_RULES_TEXT}"
  write_state_kv "CERT_MODE" "${CERT_MODE}"
  write_state_kv "CF_ZONE_ID" "${CF_ZONE_ID}"
  write_state_kv "CF_CERT_VALIDITY" "${CF_CERT_VALIDITY}"
  write_state_kv "ACME_EMAIL" "${ACME_EMAIL}"
  write_state_kv "ACME_CA" "${ACME_CA}"
  write_state_kv "CF_DNS_ACCOUNT_ID" "${CF_DNS_ACCOUNT_ID}"
  write_state_kv "CF_DNS_ZONE_ID" "${CF_DNS_ZONE_ID}"
  write_state_kv "XHTTP_ECH_CONFIG_LIST" "${XHTTP_ECH_CONFIG_LIST}"
  write_state_kv "XHTTP_ECH_FORCE_QUERY" "${XHTTP_ECH_FORCE_QUERY}"
  write_state_kv "XHTTP_XPADDING_ENABLED" "${XHTTP_XPADDING_ENABLED}"
  write_state_kv "XHTTP_XPADDING_KEY" "${XHTTP_XPADDING_KEY}"
  write_state_kv "XHTTP_XPADDING_HEADER" "${XHTTP_XPADDING_HEADER}"
  write_state_kv "XHTTP_XPADDING_PLACEMENT" "${XHTTP_XPADDING_PLACEMENT}"
  write_state_kv "XHTTP_XPADDING_METHOD" "${XHTTP_XPADDING_METHOD}"
  write_state_kv "NODE_CLIENTS_TEXT" "$(node_extra_clients_text)"
}

write_state_file() {
  write_generated_file_atomically "${STATE_FILE}" state_file_text
  chmod 0600 "${STATE_FILE}"
}
