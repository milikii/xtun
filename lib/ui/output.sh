# shellcheck shell=bash

# ------------------------------
# 节点输出层
# 负责链接导出、客户端片段与输出文件落盘
# ------------------------------

xhttp_vless_status_text() {
  if [[ "${XHTTP_VLESS_ENCRYPTION_ENABLED}" == "yes" ]]; then
    printf '已启用'
    return
  fi

  printf '未启用'
}

xhttp_vless_enabled_text() {
  if [[ "${XHTTP_VLESS_ENCRYPTION_ENABLED}" == "yes" ]]; then
    printf '是'
    return
  fi

  printf '否'
}

xhttp_ech_status_text() {
  if [[ -n "${XHTTP_ECH_CONFIG_LIST}" ]]; then
    printf '是'
    return
  fi

  printf '否'
}

xhttp_xpadding_status_text() {
  if [[ "${XHTTP_XPADDING_ENABLED:-no}" == "yes" ]]; then
    printf '是'
    return
  fi

  printf '否'
}

effective_tls_alpn() {
  printf '%s' "${TLS_ALPN:-${DEFAULT_TLS_ALPN}}"
}

effective_fingerprint() {
  printf '%s' "${FINGERPRINT:-${DEFAULT_FINGERPRINT}}"
}

xhttp_uri_encryption_value() {
  local encoded_encryption="${1}"

  if [[ "${XHTTP_VLESS_ENCRYPTION_ENABLED}" == "yes" && -n "${XHTTP_VLESS_ENCRYPTION}" ]]; then
    printf '%s' "${encoded_encryption}"
    return
  fi

  printf 'none'
}

build_xmux_json() {
  jq -cn \
    --arg max_concurrency "${DEFAULT_XHTTP_XMUX_MAX_CONCURRENCY}" \
    --argjson c_max_reuse_times "${DEFAULT_XHTTP_XMUX_C_MAX_REUSE_TIMES}" \
    --arg h_max_reusable_secs "${DEFAULT_XHTTP_XMUX_H_MAX_REUSABLE_SECS}" \
    --argjson h_keep_alive_period "${DEFAULT_XHTTP_XMUX_H_KEEP_ALIVE_PERIOD}" \
    '{
      maxConcurrency: $max_concurrency,
      cMaxReuseTimes: $c_max_reuse_times,
      hMaxReusableSecs: $h_max_reusable_secs,
      hKeepAlivePeriod: $h_keep_alive_period
    }'
}

build_xhttp_uri() {
  local label="${1}"
  local path_component="${2}"
  local encoded_encryption="${3}"
  local ech_component="${4:-}"
  local extra_component="${5:-}"
  local address="${6:-}"
  local ech_query=""
  local extra_query=""
  local encryption_value=""

  address="${address:-${XHTTP_DOMAIN}}"
  encryption_value="$(xhttp_uri_encryption_value "${encoded_encryption}")"
  [[ -n "${ech_component}" ]] && ech_query="&ech=${ech_component}"
  [[ -n "${extra_component}" ]] && extra_query="&extra=${extra_component}"

  printf 'vless://%s@%s:443?mode=auto&path=%s&security=tls&alpn=%s&encryption=%s&insecure=0&host=%s&fp=%s&fingerprint=%s&type=xhttp&allowInsecure=0&sni=%s%s%s#%s' \
    "${XHTTP_UUID}" \
    "${address}" \
    "${path_component}" \
    "$(effective_tls_alpn)" \
    "${encryption_value}" \
    "${XHTTP_DOMAIN}" \
    "$(effective_fingerprint)" \
    "$(effective_fingerprint)" \
    "${XHTTP_DOMAIN}" \
    "${ech_query}" \
    "${extra_query}" \
    "${label}"
}

# H3 直连节点：地址是 SERVER_IP，SNI/Host 用 CDN 域名（证书是它），alpn=h3。
build_xhttp_h3_uri() {
  local label="${1}"
  local path_component="${2}"
  local encoded_encryption="${3}"
  local address="${4}"
  local encryption_value=""

  encryption_value="$(xhttp_uri_encryption_value "${encoded_encryption}")"

  printf 'vless://%s@%s:443?mode=auto&path=%s&security=tls&alpn=h3&encryption=%s&insecure=0&host=%s&fp=%s&fingerprint=%s&type=xhttp&allowInsecure=0&sni=%s#%s' \
    "${XHTTP_UUID}" \
    "${address}" \
    "${path_component}" \
    "${encryption_value}" \
    "${XHTTP_DOMAIN}" \
    "$(effective_fingerprint)" \
    "$(effective_fingerprint)" \
    "${XHTTP_DOMAIN}" \
    "${label}"
}

# 上行 CDN h2（同节点 3 的 extra），下行 H3 直连。
build_xhttp_split_h3_extra_json() {
  local xmux_json=""
  local xpadding_prefix='.'

  xmux_json="$(build_xmux_json)"

  if [[ "${XHTTP_XPADDING_ENABLED:-no}" == "yes" ]]; then
    xpadding_prefix='{
      xPaddingObfsMode: true,
      xPaddingMethod: $xhttp_xpadding_method,
      xPaddingPlacement: $xhttp_xpadding_placement,
      xPaddingHeader: $xhttp_xpadding_header,
      xPaddingKey: $xhttp_xpadding_key
    } + .'
  fi

  jq -cn \
    --argjson xmux "${xmux_json}" \
    --argjson sc_min_posts_interval_ms "${DEFAULT_XHTTP_SC_MIN_POSTS_INTERVAL_MS}" \
    --arg address "${SERVER_IP}" \
    --arg server_name "${XHTTP_DOMAIN}" \
    --arg alpn "$(effective_tls_alpn)" \
    --arg fingerprint "$(effective_fingerprint)" \
    --arg path "${XHTTP_PATH}" \
    --arg xhttp_xpadding_key "${XHTTP_XPADDING_KEY:-${DEFAULT_XHTTP_XPADDING_KEY}}" \
    --arg xhttp_xpadding_header "${XHTTP_XPADDING_HEADER:-${DEFAULT_XHTTP_XPADDING_HEADER}}" \
    --arg xhttp_xpadding_placement "${XHTTP_XPADDING_PLACEMENT:-${DEFAULT_XHTTP_XPADDING_PLACEMENT}}" \
    --arg xhttp_xpadding_method "${XHTTP_XPADDING_METHOD:-${DEFAULT_XHTTP_XPADDING_METHOD}}" \
    '{
      scMinPostsIntervalMs: $sc_min_posts_interval_ms,
      xmux: $xmux,
      downloadSettings: {
        address: $address,
        port: 443,
        network: "xhttp",
        security: "tls",
        alpn: ["h3"],
        tlsSettings: {
          serverName: $server_name,
          allowInsecure: false,
          fingerprint: $fingerprint
        },
        xhttpSettings: {
          host: "",
          path: $path,
          mode: "auto"
        }
      }
    } | '"${xpadding_prefix}"
}

build_xhttp_reality_uri() {
  local label="${1}"
  local path_component="${2}"
  local encoded_encryption="${3}"
  local extra_component="${4:-}"
  local extra_query=""
  local encryption_value=""

  encryption_value="$(xhttp_uri_encryption_value "${encoded_encryption}")"
  [[ -n "${extra_component}" ]] && extra_query="&extra=${extra_component}"

  printf 'vless://%s@%s:443?encryption=%s&security=reality&sni=%s&fp=%s&fingerprint=%s&pbk=%s&sid=%s&type=xhttp&path=%s&mode=auto%s#%s' \
    "${XHTTP_UUID}" \
    "${SERVER_IP}" \
    "${encryption_value}" \
    "${REALITY_SNI}" \
    "$(effective_fingerprint)" \
    "$(effective_fingerprint)" \
    "${REALITY_PUBLIC_KEY}" \
    "${REALITY_SHORT_ID}" \
    "${path_component}" \
    "${extra_query}" \
    "${label}"
}

build_download_xhttp_extra_json() {
  local xmux_json=""
  local xpadding_filter='.'

  xmux_json="$(build_xmux_json)"

  if [[ "${XHTTP_XPADDING_ENABLED:-no}" == "yes" ]]; then
    xpadding_filter='{
      xPaddingObfsMode: true,
      xPaddingMethod: $xhttp_xpadding_method,
      xPaddingPlacement: $xhttp_xpadding_placement,
      xPaddingHeader: $xhttp_xpadding_header,
      xPaddingKey: $xhttp_xpadding_key
    } + .'
  fi

  jq -cn \
    --argjson xmux "${xmux_json}" \
    --arg xhttp_xpadding_key "${XHTTP_XPADDING_KEY:-${DEFAULT_XHTTP_XPADDING_KEY}}" \
    --arg xhttp_xpadding_header "${XHTTP_XPADDING_HEADER:-${DEFAULT_XHTTP_XPADDING_HEADER}}" \
    --arg xhttp_xpadding_placement "${XHTTP_XPADDING_PLACEMENT:-${DEFAULT_XHTTP_XPADDING_PLACEMENT}}" \
    --arg xhttp_xpadding_method "${XHTTP_XPADDING_METHOD:-${DEFAULT_XHTTP_XPADDING_METHOD}}" \
    '{xmux: $xmux} | '"${xpadding_filter}"
}

# $1 = downloadSettings.address（默认 SERVER_IP；IPv6 split 节点传 [v6]）
build_xhttp_split_extra_json() {
  local download_address="${1:-}"
  local xmux_json=""
  local download_extra_json=""
  local xpadding_root_prefix='.'

  xmux_json="$(build_xmux_json)"
  download_extra_json="$(build_download_xhttp_extra_json)"

  if [[ "${XHTTP_XPADDING_ENABLED:-no}" == "yes" ]]; then
    xpadding_root_prefix='{
      xPaddingObfsMode: true,
      xPaddingMethod: $xhttp_xpadding_method,
      xPaddingPlacement: $xhttp_xpadding_placement,
      xPaddingHeader: $xhttp_xpadding_header,
      xPaddingKey: $xhttp_xpadding_key
    } + .'
  fi

  jq -cn \
    --argjson xmux "${xmux_json}" \
    --argjson download_extra "${download_extra_json}" \
    --argjson sc_min_posts_interval_ms "${DEFAULT_XHTTP_SC_MIN_POSTS_INTERVAL_MS}" \
    --arg address "${download_address:-${SERVER_IP}}" \
    --arg server_name "${REALITY_SNI}" \
    --arg fingerprint "$(effective_fingerprint)" \
    --arg short_id "${REALITY_SHORT_ID}" \
    --arg public_key "${REALITY_PUBLIC_KEY}" \
    --arg path "${XHTTP_PATH}" \
    --arg xhttp_xpadding_key "${XHTTP_XPADDING_KEY:-${DEFAULT_XHTTP_XPADDING_KEY}}" \
    --arg xhttp_xpadding_header "${XHTTP_XPADDING_HEADER:-${DEFAULT_XHTTP_XPADDING_HEADER}}" \
    --arg xhttp_xpadding_placement "${XHTTP_XPADDING_PLACEMENT:-${DEFAULT_XHTTP_XPADDING_PLACEMENT}}" \
    --arg xhttp_xpadding_method "${XHTTP_XPADDING_METHOD:-${DEFAULT_XHTTP_XPADDING_METHOD}}" \
    '{
      scMinPostsIntervalMs: $sc_min_posts_interval_ms,
      xmux: $xmux,
      downloadSettings: {
        address: $address,
        port: 443,
        network: "xhttp",
        security: "reality",
        realitySettings: {
          show: false,
          serverName: $server_name,
          fingerprint: $fingerprint,
          shortId: $short_id,
          publicKey: $public_key
        },
        xhttpSettings: {
          host: "",
          path: $path,
          mode: "auto",
          extra: $download_extra
        }
      }
    } | '"${xpadding_root_prefix}"
}


build_xhttp_extra_json() {
  local xmux_json=""
  local xpadding_prefix='.'

  xmux_json="$(build_xmux_json)"

  if [[ "${XHTTP_XPADDING_ENABLED:-no}" == "yes" ]]; then
    xpadding_prefix='{
      xPaddingObfsMode: true,
      xPaddingMethod: $xhttp_xpadding_method,
      xPaddingPlacement: $xhttp_xpadding_placement,
      xPaddingHeader: $xhttp_xpadding_header,
      xPaddingKey: $xhttp_xpadding_key
    } + .'
  fi

  jq -cn \
    --argjson xmux "${xmux_json}" \
    --argjson sc_min_posts_interval_ms "${DEFAULT_XHTTP_SC_MIN_POSTS_INTERVAL_MS}" \
    --arg xhttp_xpadding_key "${XHTTP_XPADDING_KEY:-${DEFAULT_XHTTP_XPADDING_KEY}}" \
    --arg xhttp_xpadding_header "${XHTTP_XPADDING_HEADER:-${DEFAULT_XHTTP_XPADDING_HEADER}}" \
    --arg xhttp_xpadding_placement "${XHTTP_XPADDING_PLACEMENT:-${DEFAULT_XHTTP_XPADDING_PLACEMENT}}" \
    --arg xhttp_xpadding_method "${XHTTP_XPADDING_METHOD:-${DEFAULT_XHTTP_XPADDING_METHOD}}" \
    '{
      scMinPostsIntervalMs: $sc_min_posts_interval_ms,
      xmux: $xmux
    } | '"${xpadding_prefix}"
}

build_xhttp_reality_extra_json() {
  local xmux_json=""
  local xpadding_prefix='.'

  xmux_json="$(build_xmux_json)"

  if [[ "${XHTTP_XPADDING_ENABLED:-no}" == "yes" ]]; then
    xpadding_prefix='{
      xPaddingObfsMode: true,
      xPaddingMethod: $xhttp_xpadding_method,
      xPaddingPlacement: $xhttp_xpadding_placement,
      xPaddingHeader: $xhttp_xpadding_header,
      xPaddingKey: $xhttp_xpadding_key
    } + .'
  fi

  jq -cn \
    --argjson xmux "${xmux_json}" \
    --arg xhttp_xpadding_key "${XHTTP_XPADDING_KEY:-${DEFAULT_XHTTP_XPADDING_KEY}}" \
    --arg xhttp_xpadding_header "${XHTTP_XPADDING_HEADER:-${DEFAULT_XHTTP_XPADDING_HEADER}}" \
    --arg xhttp_xpadding_placement "${XHTTP_XPADDING_PLACEMENT:-${DEFAULT_XHTTP_XPADDING_PLACEMENT}}" \
    --arg xhttp_xpadding_method "${XHTTP_XPADDING_METHOD:-${DEFAULT_XHTTP_XPADDING_METHOD}}" \
    '{xmux: $xmux} | '"${xpadding_prefix}"
}

build_xhttp_reverse_split_extra_json() {
  local xmux_json=""
  local download_extra_json=""
  local xpadding_root_prefix='.'
  local ech_settings_filter='.'

  xmux_json="$(build_xmux_json)"
  download_extra_json="$(build_download_xhttp_extra_json)"

  if [[ "${XHTTP_XPADDING_ENABLED:-no}" == "yes" ]]; then
    xpadding_root_prefix='{
      xPaddingObfsMode: true,
      xPaddingMethod: $xhttp_xpadding_method,
      xPaddingPlacement: $xhttp_xpadding_placement,
      xPaddingHeader: $xhttp_xpadding_header,
      xPaddingKey: $xhttp_xpadding_key
    } + .'
  fi

  if [[ -n "${XHTTP_ECH_CONFIG_LIST}" ]]; then
    ech_settings_filter='.downloadSettings.tlsSettings.echConfigList = $ech_config_list'
  fi

  jq -cn \
    --argjson xmux "${xmux_json}" \
    --argjson download_extra "${download_extra_json}" \
    --arg cdn_domain "${XHTTP_DOMAIN}" \
    --arg alpn "$(effective_tls_alpn)" \
    --arg fingerprint "$(effective_fingerprint)" \
    --arg path "${XHTTP_PATH}" \
    --arg ech_config_list "${XHTTP_ECH_CONFIG_LIST}" \
    --arg xhttp_xpadding_key "${XHTTP_XPADDING_KEY:-${DEFAULT_XHTTP_XPADDING_KEY}}" \
    --arg xhttp_xpadding_header "${XHTTP_XPADDING_HEADER:-${DEFAULT_XHTTP_XPADDING_HEADER}}" \
    --arg xhttp_xpadding_placement "${XHTTP_XPADDING_PLACEMENT:-${DEFAULT_XHTTP_XPADDING_PLACEMENT}}" \
    --arg xhttp_xpadding_method "${XHTTP_XPADDING_METHOD:-${DEFAULT_XHTTP_XPADDING_METHOD}}" \
    '{
      xmux: $xmux,
      downloadSettings: {
        address: $cdn_domain,
        port: 443,
        network: "xhttp",
        security: "tls",
        tlsSettings: {
          serverName: $cdn_domain,
          allowInsecure: false,
          alpn: [$alpn],
          fingerprint: $fingerprint
        },
        xhttpSettings: {
          host: $cdn_domain,
          path: $path,
          mode: "auto",
          extra: $download_extra
        }
      }
    } | '"${ech_settings_filter}"' | '"${xpadding_root_prefix}"
}

build_link_context() {
  local xhttp_path_component=""
  local xhttp_ech_component=""
  local xhttp_vlessenc_component=""
  local reality_label=""
  local xhttp_label=""
  local xhttp_split_label=""
  local xhttp_reality_label=""
  local xhttp_reverse_split_label=""
  local xhttp_extra_json=""
  local xhttp_extra_component=""
  local split_extra_json=""
  local split_extra_component=""
  local reality_extra_json=""
  local reality_extra_component=""
  local reverse_split_extra_json=""
  local reverse_split_extra_component=""

  xhttp_path_component="$(path_to_uri_component "${XHTTP_PATH}")"
  xhttp_ech_component="$(uri_encode "${XHTTP_ECH_CONFIG_LIST}")"
  xhttp_vlessenc_component="$(uri_encode "${XHTTP_VLESS_ENCRYPTION}")"
  reality_label="$(prefixed_node_label "REALITY")"
  xhttp_label="$(prefixed_node_label "XHTTP-CDN")"
  xhttp_split_label="$(prefixed_node_label "XHTTP-SPLIT-CDN-REALITY")"
  xhttp_reality_label="$(prefixed_node_label "XHTTP-REALITY")"
  xhttp_reverse_split_label="$(prefixed_node_label "XHTTP-SPLIT-REALITY-CDN")"

  REALITY_URI="$(build_reality_uri "${reality_label}")"
  reality_extra_json="$(build_xhttp_reality_extra_json)"
  reality_extra_component="$(uri_encode "${reality_extra_json}")"
  XHTTP_REALITY_URI="$(build_xhttp_reality_uri "${xhttp_reality_label}" "${xhttp_path_component}" "${xhttp_vlessenc_component}" "${reality_extra_component}")"
  xhttp_extra_json="$(build_xhttp_extra_json)"
  xhttp_extra_component="$(uri_encode "${xhttp_extra_json}")"
  XHTTP_URI="$(build_xhttp_uri "${xhttp_label}" "${xhttp_path_component}" "${xhttp_vlessenc_component}" "${xhttp_ech_component}" "${xhttp_extra_component}")"
  split_extra_json="$(build_xhttp_split_extra_json)"
  split_extra_component="$(uri_encode "${split_extra_json}")"
  XHTTP_SPLIT_URI="$(build_xhttp_uri "${xhttp_split_label}" "${xhttp_path_component}" "${xhttp_vlessenc_component}" "${xhttp_ech_component}" "${split_extra_component}")"
  reverse_split_extra_json="$(build_xhttp_reverse_split_extra_json)"
  reverse_split_extra_component="$(uri_encode "${reverse_split_extra_json}")"
  XHTTP_REVERSE_SPLIT_URI="$(build_xhttp_reality_uri "${xhttp_reverse_split_label}" "${xhttp_path_component}" "${xhttp_vlessenc_component}" "${reverse_split_extra_component}")"

  REALITY_V6_URI=""
  XHTTP_SPLIT_CDN_REALITY_V6_URI=""
  XHTTP_H3_URI=""
  XHTTP_SPLIT_CDN_H3_URI=""
  if h3_enabled; then
    # XHTTP-TLS-H3：H3 直连（地址 SERVER_IP，TLS 由本机 nginx 终结）
    XHTTP_H3_URI="$(build_xhttp_h3_uri "$(prefixed_node_label "XHTTP-TLS-H3")" "${xhttp_path_component}" "${xhttp_vlessenc_component}" "${SERVER_IP}")"
    # XHTTP-SPLIT-CDN-H3：上行走 CDN h2，下行 H3 直连
    XHTTP_SPLIT_CDN_H3_URI="$(build_xhttp_uri "$(prefixed_node_label "XHTTP-SPLIT-CDN-H3")" "${xhttp_path_component}" "${xhttp_vlessenc_component}" "${xhttp_ech_component}" "$(uri_encode "$(build_xhttp_split_h3_extra_json)")")"
  fi
  if [[ -n "${SERVER_IP6:-}" ]]; then
    REALITY_V6_URI="$(build_reality_uri "$(prefixed_node_label "REALITY-V6")" "[${SERVER_IP6}]")"
    local split_v6_component=""
    split_v6_component="$(uri_encode "$(build_xhttp_split_extra_json "[${SERVER_IP6}]")")"
    XHTTP_SPLIT_CDN_REALITY_V6_URI="$(build_xhttp_uri "$(prefixed_node_label "XHTTP-SPLIT-CDN-REALITY-V6")" "${xhttp_path_component}" "${xhttp_vlessenc_component}" "${xhttp_ech_component}" "${split_v6_component}" "[${SERVER_IP6}]")"
  fi
}

# 每行：位次<TAB>节点名<TAB>链接。位次固定：1–5 默认，6/7 IPv6，8/9 H3，缺席跳号，
# 这样 PNG 文件名与输出文件里的「节点 N」在任何机器上都对得上。
node_link_entries() {
  build_link_context
  printf '%s\t%s\t%s\n' \
    1 "$(prefixed_node_label "REALITY")" "${REALITY_URI}" \
    2 "$(prefixed_node_label "XHTTP-REALITY")" "${XHTTP_REALITY_URI}" \
    3 "$(prefixed_node_label "XHTTP-CDN")" "${XHTTP_URI}" \
    4 "$(prefixed_node_label "XHTTP-SPLIT-CDN-REALITY")" "${XHTTP_SPLIT_URI}" \
    5 "$(prefixed_node_label "XHTTP-SPLIT-REALITY-CDN")" "${XHTTP_REVERSE_SPLIT_URI}"
  if [[ -n "${SERVER_IP6:-}" ]]; then
    printf '%s\t%s\t%s\n' \
      6 "$(prefixed_node_label "REALITY-V6")" "${REALITY_V6_URI}" \
      7 "$(prefixed_node_label "XHTTP-SPLIT-CDN-REALITY-V6")" "${XHTTP_SPLIT_CDN_REALITY_V6_URI}"
  fi
  if h3_enabled; then
    printf '%s\t%s\t%s\n' \
      8 "$(prefixed_node_label "XHTTP-TLS-H3")" "${XHTTP_H3_URI}" \
      9 "$(prefixed_node_label "XHTTP-SPLIT-CDN-H3")" "${XHTTP_SPLIT_CDN_H3_URI}"
  fi
}

vless_links_text() {
  node_link_entries | cut -f3
}

prefixed_node_label() {
  local suffix="${1}"
  printf '%s-%s' "$(normalize_node_label_prefix "${NODE_LABEL_PREFIX}")" "${suffix}"
}

cloudflare_ssl_mode_text() {
  if [[ "${CERT_MODE}" == "self-signed" ]]; then
    printf 'Full'
    return
  fi

  printf 'Full (strict)'
}

cloudflare_xhttp_cache_bypass_expression() {
  printf '(http.host eq "%s") or (http.request.uri.path contains "%s")' \
    "${XHTTP_DOMAIN}" \
    "${XHTTP_PATH}"
}

build_reality_uri() {
  local label="${1}"
  local address="${2:-}"

  address="${address:-${SERVER_IP}}"
  printf 'vless://%s@%s:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=%s&fingerprint=%s&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
    "${REALITY_UUID}" \
    "${address}" \
    "${REALITY_SNI}" \
    "$(effective_fingerprint)" \
    "$(effective_fingerprint)" \
    "${REALITY_PUBLIC_KEY}" \
    "${REALITY_SHORT_ID}" \
    "${label}"
}

output_reality_block() {
  local reality_uri="${1}"

  cat <<EOF
## 节点 1
- 类型: VLESS + REALITY + Vision
- 节点名前缀: ${NODE_LABEL_PREFIX}
- 地址: ${SERVER_IP}
- 端口: 443
- UUID: ${REALITY_UUID}
- SNI: ${REALITY_SNI}
- 公钥: ${REALITY_PUBLIC_KEY}
- 短 ID: ${REALITY_SHORT_ID}
- 流控: xtls-rprx-vision
- 指纹: $(effective_fingerprint)

链接:
${reality_uri}
EOF
}

output_xhttp_block() {
  local title="${1}"

  cat <<EOF
## ${title}
- 地址: ${XHTTP_DOMAIN}
- 端口: 443
- UUID: ${XHTTP_UUID}
EOF
}

output_xhttp_shared_details() {
  cat <<EOF
- 路径: ${XHTTP_PATH}
- VLESS Encryption: $(xhttp_vless_status_text)
- ECH: $(xhttp_ech_status_text)
- xpadding: $(xhttp_xpadding_status_text)
EOF
}

output_xhttp_cdn_block() {
  local uri="${1}"

  cat <<EOF
$(output_xhttp_block "节点 3")
- 类型: VLESS + XHTTP + TLS + CDN
- SNI: ${XHTTP_DOMAIN}
- 主机名: ${XHTTP_DOMAIN}
- ALPN: $(effective_tls_alpn)
- 模式: auto
- 指纹: $(effective_fingerprint)
$(output_xhttp_shared_details)

链接:
${uri}
EOF
}

output_xhttp_split_block() {
  local uri="${1}"

  cat <<EOF
$(output_xhttp_block "节点 4")
- 类型: 上行 XHTTP + TLS + CDN ｜ 下行 XHTTP + Reality
- 上行: XHTTP + TLS + CDN
- 下行: XHTTP + Reality
$(output_xhttp_shared_details)

链接:
${uri}
EOF
}

output_xhttp_reality_block() {
  local uri="${1}"

  cat <<EOF
## 节点 2
- 类型: VLESS + XHTTP + Reality（上下行不分离）
- 节点名前缀: ${NODE_LABEL_PREFIX}
- 地址: ${SERVER_IP}
- 端口: 443
- UUID: ${XHTTP_UUID}
- SNI: ${REALITY_SNI}
- 公钥: ${REALITY_PUBLIC_KEY}
- 短 ID: ${REALITY_SHORT_ID}
- 指纹: $(effective_fingerprint)
$(output_xhttp_shared_details)

链接:
${uri}
EOF
}

output_xhttp_reverse_split_block() {
  local uri="${1}"

  cat <<EOF
## 节点 5
- 类型: 上行 XHTTP + Reality ｜ 下行 XHTTP + TLS + CDN
- 节点名前缀: ${NODE_LABEL_PREFIX}
- 上行地址: ${SERVER_IP}（Reality）
- 下行地址: ${XHTTP_DOMAIN}（CDN+TLS）
- UUID: ${XHTTP_UUID}
- 上行 SNI: ${REALITY_SNI}
- 公钥: ${REALITY_PUBLIC_KEY}
- 短 ID: ${REALITY_SHORT_ID}
- 指纹: $(effective_fingerprint)
$(output_xhttp_shared_details)

链接:
${uri}
EOF
}

# SERVER_IP6 非空时追加节点 6 / 节点 7。
output_ipv6_blocks() {
  if [[ -z "${SERVER_IP6:-}" ]]; then
    return 0
  fi

  cat <<EOF
## 节点 6
- 类型: VLESS + REALITY + Vision（IPv6）
- 地址: [${SERVER_IP6}]
- 端口: 443
- UUID: ${REALITY_UUID}
- SNI: ${REALITY_SNI}
- 公钥: ${REALITY_PUBLIC_KEY}
- 短 ID: ${REALITY_SHORT_ID}
- 指纹: $(effective_fingerprint)

链接:
${REALITY_V6_URI}

## 节点 7
- 类型: 上行 XHTTP + TLS + CDN ｜ 下行 XHTTP + Reality（IPv6）
- 上行地址: ${XHTTP_DOMAIN}（CDN+TLS）
- 下行地址: [${SERVER_IP6}]（Reality）
- UUID: ${XHTTP_UUID}
- 下行 SNI: ${REALITY_SNI}
- 公钥: ${REALITY_PUBLIC_KEY}
- 短 ID: ${REALITY_SHORT_ID}
$(output_xhttp_shared_details)

链接:
${XHTTP_SPLIT_CDN_REALITY_V6_URI}
EOF
}

output_h3_blocks() {
  if [[ -z "${XHTTP_H3_URI}" ]]; then
    return 0
  fi

  cat <<EOF
## 节点 8
- 类型: VLESS + XHTTP + TLS（H3 直连，UDP 443）
- 地址: ${SERVER_IP}
- 端口: 443（UDP / QUIC，防火墙需放行）
- UUID: ${XHTTP_UUID}
- SNI: ${XHTTP_DOMAIN}
- 主机名: ${XHTTP_DOMAIN}
- ALPN: h3
- 指纹: $(effective_fingerprint)
$(output_xhttp_shared_details)

链接:
${XHTTP_H3_URI}

## 节点 9
- 类型: 上行 XHTTP + TLS + CDN ｜ 下行 XHTTP + TLS H3 直连
- 上行地址: ${XHTTP_DOMAIN}（CDN+TLS）
- 下行地址: ${SERVER_IP}（H3，UDP 443）
- UUID: ${XHTTP_UUID}
$(output_xhttp_shared_details)

链接:
${XHTTP_SPLIT_CDN_H3_URI}
EOF
}

output_qr_block() {
  cat <<EOF
## 二维码
- 终端扫码: xtun show-links --qr
- PNG 目录: ${QR_OUTPUT_DIR}（每条节点一张，文件名「位次-节点名.png」，随链接一起重新生成）
- 取回本地: scp root@${SERVER_IP}:${QR_OUTPUT_DIR}/'*.png' .
EOF
}

output_runtime_summary_block() {
  local cf_ssl_mode="${1}"

  cat <<EOF
## Cloudflare DNS 设置
- 请将 ${XHTTP_DOMAIN} 解析到此服务器 IP。
- 请为 ${XHTTP_DOMAIN} 打开橙云代理。
- 请将 Cloudflare SSL/TLS 模式设置为 ${cf_ssl_mode}。

## 本地文件
- Xray 配置: ${XRAY_CONFIG_FILE}
- Nginx 配置: ${NGINX_CONFIG_FILE}
- 安装状态文件: ${STATE_FILE}
- 链接输出文件: ${OUTPUT_FILE}
- 二维码目录: ${QR_OUTPUT_DIR}

## WARP
- 已启用: ${ENABLE_WARP}
- 出站模式: wireguard（Xray 内置，无守护进程）
- 出口: Cloudflare WARP
- Endpoint: ${WARP_ENDPOINT:-${DEFAULT_WARP_ENDPOINT}}
- 内网地址: $(warp_output_addresses_text)
- reserved: ${WARP_RESERVED:-未设置}

## XHTTP ECH
- 已启用: $(xhttp_ech_status_text)
- DoH / ECH 查询: ${XHTTP_ECH_CONFIG_LIST:-未设置}
- 强制查询模式: ${XHTTP_ECH_FORCE_QUERY:-未设置}
- 说明: 默认不启用 ECH，导出的两个 XHTTP 节点分享链接也不会带 ech= 参数，避免额外的 DNS / DoH 查询。

## XHTTP xpadding
- 已启用: $(xhttp_xpadding_status_text)
- Header: ${XHTTP_XPADDING_HEADER:-${DEFAULT_XHTTP_XPADDING_HEADER}}
- 参数名: ${XHTTP_XPADDING_KEY:-${DEFAULT_XHTTP_XPADDING_KEY}}
- Placement: ${XHTTP_XPADDING_PLACEMENT:-${DEFAULT_XHTTP_XPADDING_PLACEMENT}}
- Method: ${XHTTP_XPADDING_METHOD:-${DEFAULT_XHTTP_XPADDING_METHOD}}
- 说明: 默认不启用；启用后会写入 Xray xhttpSettings，并在 XHTTP 分享链接 extra= 中携带客户端侧配置。

## XHTTP VLESS Encryption
- 已启用: $(xhttp_vless_enabled_text)
- 说明: 默认开启，用于给 XHTTP 相关节点增加一层 VLESS 端到端加密。

## 网络优化
- 已启用: ${ENABLE_NET_OPT}
- Sysctl 文件: ${NET_SYSCTL_CONF}
- 服务名: ${NET_SERVICE_NAME}
EOF
}

output_xhttp_cache_rules_block() {
  # 正文里的 “…” 是照抄 Cloudflare 界面上的中文标题，不是打错的 ASCII 引号
  # shellcheck disable=SC1111
  cat <<EOF
## XHTTP 缓存绕过（重要）

为避免 ${XHTTP_DOMAIN} 上的 XHTTP 请求被 Cloudflare 边缘缓存，建议手动创建一条 Cache Rule，把这类请求设为 Bypass cache。

建议表达式：

$(cloudflare_xhttp_cache_bypass_expression)

推荐操作步骤：

1. 登录 Cloudflare 控制台，进入站点 ${XHTTP_DOMAIN} 所在的 Zone。
2. 左侧菜单进入 缓存。
3. 打开 Cache Rules。
4. 点击 创建缓存规则。
5. 规则名称可随意填写，例如 xhttp-bypass-cache。
6. 在“如果传入请求匹配...”里选择 自定义筛选表达式。
7. 点击右侧的“编辑表达式”。
8. 粘贴上面的表达式：
   作用：
   - http.host eq "${XHTTP_DOMAIN}"：按整个 XHTTP 域名匹配。
   - http.request.uri.path contains "${XHTTP_PATH}"：按 XHTTP 路径匹配。
9. 在规则动作里找到 Cache eligibility。
10. 将 Cache eligibility 设置为 Bypass cache。
11. 保存并点击 部署。

补充建议：

- 如果 ${XHTTP_DOMAIN} 是专门给 XHTTP 使用的独立子域名，按整个 Host 绕过缓存通常最省事。
- 如果这个域名还承载了别的静态资源，建议保留上面的路径条件，避免把整站缓存一起关掉。
- 修改完成后，建议用新的 XHTTP 链接重新测试，避免客户端还在复用旧连接。
EOF
}

output_file_text() {
  local cf_ssl_mode=""

  build_link_context
  cf_ssl_mode="$(cloudflare_ssl_mode_text)"

  cat <<EOF
# Xray 部署信息

$(output_reality_block "${REALITY_URI}")

$(output_xhttp_reality_block "${XHTTP_REALITY_URI}")

$(output_xhttp_cdn_block "${XHTTP_URI}")

$(output_xhttp_split_block "${XHTTP_SPLIT_URI}")

$(output_xhttp_reverse_split_block "${XHTTP_REVERSE_SPLIT_URI}")
$(output_ipv6_blocks)
$(output_h3_blocks)

$(output_qr_block)

$(output_runtime_summary_block "${cf_ssl_mode}")

$(output_xhttp_cache_rules_block)
EOF
}

write_output_file() {
  write_generated_file_atomically "${OUTPUT_FILE}" output_file_text || return 1
  chmod 0644 "${OUTPUT_FILE}"
  write_link_qr_pngs
}

# 二维码 PNG 是输出文件的派生物：任何一步失败只 warn，不让 install / apply-config 回滚。
# 目录整体重建：链接变了（换 UUID / SNI / 路径 / 域名、IPv6 或 H3 开关变化）旧图必须消失。
write_link_qr_pngs() {
  local idx="" label="" uri="" target="" tmp_file=""

  if ! have_qrencode; then
    warn "未安装 qrencode，跳过二维码 PNG；apt-get install -y qrencode 后运行 xtun apply-config 即可补齐。"
    return 0
  fi
  if ! backup_path "${QR_OUTPUT_DIR}"; then
    warn "二维码目录备份失败，本次跳过 PNG 生成：${QR_OUTPUT_DIR}"
    return 0
  fi
  rm -rf "${QR_OUTPUT_DIR}"
  if ! install -d -m 0700 "${QR_OUTPUT_DIR}"; then
    warn "无法创建二维码目录，已跳过：${QR_OUTPUT_DIR}"
    return 0
  fi

  while IFS=$'\t' read -r idx label uri; do
    target="${QR_OUTPUT_DIR}/$(printf '%02d-%s.png' "${idx}" "${label}")"
    tmp_file="$(mktemp "${QR_OUTPUT_DIR}/.qr.XXXXXX")"
    if qrencode -o "${tmp_file}" -l L -s 6 -m 2 "${uri}" 2>/dev/null; then
      mv -f "${tmp_file}" "${target}"
      chmod 0600 "${target}"
    else
      rm -f "${tmp_file}"
      warn "二维码 PNG 生成失败，已跳过：${label}"
    fi
  done < <(node_link_entries)
}
