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

selected_output_client_name() {
  printf '%s' "${OUTPUT_CLIENT_NAME:-$(default_node_client_name)}"
}

current_link_client_name() {
  printf '%s' "${LINK_CLIENT_NAME:-$(default_node_client_name)}"
}

current_link_reality_uuid() {
  printf '%s' "${LINK_REALITY_UUID:-${REALITY_UUID}}"
}

current_link_xhttp_uuid() {
  printf '%s' "${LINK_XHTTP_UUID:-${XHTTP_UUID}}"
}

client_scoped_node_label() {
  local client_name="${1}"
  local suffix="${2}"

  if [[ "${client_name}" == "$(default_node_client_name)" ]]; then
    prefixed_node_label "${suffix}"
    return
  fi

  printf '%s-%s-%s' "$(normalize_node_label_prefix "${NODE_LABEL_PREFIX}")" "${client_name}" "${suffix}"
}

output_client_detail_line() {
  local client_name=""

  client_name="$(current_link_client_name)"
  if [[ "${client_name}" != "$(default_node_client_name)" ]]; then
    printf '%s\n' "- 客户端: ${client_name}"
  fi
}

output_client_summary_block() {
  local client_name=""
  local client_count=""

  client_name="$(current_link_client_name)"
  client_count="$(node_client_count)"
  if [[ "${client_name}" == "$(default_node_client_name)" && "${client_count}" -le 1 ]]; then
    return
  fi

  cat <<EOF
## 客户端
- 当前导出: ${client_name}
- 可用客户端: $(node_client_names_csv)
EOF
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
  local ech_query=""
  local extra_query=""
  local encryption_value=""

  encryption_value="$(xhttp_uri_encryption_value "${encoded_encryption}")"
  [[ -n "${ech_component}" ]] && ech_query="&ech=${ech_component}"
  [[ -n "${extra_component}" ]] && extra_query="&extra=${extra_component}"

  printf 'vless://%s@%s:443?mode=auto&path=%s&security=tls&alpn=%s&encryption=%s&insecure=0&host=%s&fp=%s&fingerprint=%s&type=xhttp&allowInsecure=0&sni=%s%s%s#%s' \
    "$(current_link_xhttp_uuid)" \
    "${XHTTP_DOMAIN}" \
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
    "$(current_link_xhttp_uuid)" \
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

build_xhttp_split_extra_json() {
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
    --arg address "${SERVER_IP}" \
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
  local requested_client_name="${1:-$(selected_output_client_name)}"
  local client_record=""
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

  client_record="$(node_client_record_for_name "${requested_client_name}")" || die "找不到客户端：${requested_client_name}"
  IFS='|' read -r LINK_CLIENT_NAME LINK_REALITY_UUID LINK_XHTTP_UUID <<< "${client_record}"

  xhttp_path_component="$(path_to_uri_component "${XHTTP_PATH}")"
  xhttp_ech_component="$(uri_encode "${XHTTP_ECH_CONFIG_LIST}")"
  xhttp_vlessenc_component="$(uri_encode "${XHTTP_VLESS_ENCRYPTION}")"
  reality_label="$(client_scoped_node_label "${LINK_CLIENT_NAME}" "REALITY")"
  xhttp_label="$(client_scoped_node_label "${LINK_CLIENT_NAME}" "XHTTP-CDN")"
  xhttp_split_label="$(client_scoped_node_label "${LINK_CLIENT_NAME}" "XHTTP-SPLIT-CDN-REALITY")"
  xhttp_reality_label="$(client_scoped_node_label "${LINK_CLIENT_NAME}" "XHTTP-REALITY")"
  xhttp_reverse_split_label="$(client_scoped_node_label "${LINK_CLIENT_NAME}" "XHTTP-SPLIT-REALITY-CDN")"

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
}

subscription_raw_text() {
  build_link_context "$(selected_output_client_name)"
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "${REALITY_URI}" \
    "${XHTTP_REALITY_URI}" \
    "${XHTTP_URI}" \
    "${XHTTP_SPLIT_URI}" \
    "${XHTTP_REVERSE_SPLIT_URI}"
}

subscription_base64_text() {
  subscription_raw_text | base64 | tr -d '\n'
  printf '\n'
}

subscription_qr_status_text() {
  if [[ -f "${SUBSCRIPTION_RAW_QR_FILE}" || -f "${SUBSCRIPTION_BASE64_QR_FILE}" ]]; then
    printf '已生成'
    return
  fi

  printf '未生成'
}

subscription_manifest_text() {
  cat <<EOF
# Xray WARP Team 订阅文件

Raw VLESS:
${SUBSCRIPTION_RAW_FILE}

Base64 VLESS:
${SUBSCRIPTION_BASE64_FILE}

Raw QR PNG:
$(if [[ -f "${SUBSCRIPTION_RAW_QR_FILE}" ]]; then printf '%s' "${SUBSCRIPTION_RAW_QR_FILE}"; else printf '未生成'; fi)

Base64 QR PNG:
$(if [[ -f "${SUBSCRIPTION_BASE64_QR_FILE}" ]]; then printf '%s' "${SUBSCRIPTION_BASE64_QR_FILE}"; else printf '未生成'; fi)
EOF
}

write_subscription_qr_png() {
  local content_file="${1}"
  local output_file="${2}"
  local tmp_file=""

  command -v qrencode >/dev/null 2>&1 || return 2
  [[ -f "${content_file}" ]] || return 1
  mkdir -p "$(dirname "${output_file}")"
  tmp_file="$(mktemp "$(dirname "${output_file}")/.$(basename "${output_file}").tmp.XXXXXX")"
  if ! qrencode -o "${tmp_file}" -s 8 -m 2 "$(<"${content_file}")"; then
    rm -f "${tmp_file}"
    return 1
  fi
  mv -f "${tmp_file}" "${output_file}"
}

write_subscription_files() {
  mkdir -p "${SUBSCRIPTION_DIR}" "${SUBSCRIPTION_QR_DIR}"
  write_generated_file_atomically "${SUBSCRIPTION_RAW_FILE}" subscription_raw_text
  chmod 0644 "${SUBSCRIPTION_RAW_FILE}"
  write_generated_file_atomically "${SUBSCRIPTION_BASE64_FILE}" subscription_base64_text
  chmod 0644 "${SUBSCRIPTION_BASE64_FILE}"

  if command -v qrencode >/dev/null 2>&1; then
    write_subscription_qr_png "${SUBSCRIPTION_RAW_FILE}" "${SUBSCRIPTION_RAW_QR_FILE}" || warn "生成 Raw VLESS 订阅二维码失败，已跳过。"
    write_subscription_qr_png "${SUBSCRIPTION_BASE64_FILE}" "${SUBSCRIPTION_BASE64_QR_FILE}" || warn "生成 Base64 VLESS 订阅二维码失败，已跳过。"
  else
    rm -f "${SUBSCRIPTION_RAW_QR_FILE}" "${SUBSCRIPTION_BASE64_QR_FILE}"
    warn "系统中未找到 qrencode，已跳过订阅二维码 PNG。"
  fi

  write_generated_file_atomically "${SUBSCRIPTION_MANIFEST_FILE}" subscription_manifest_text
  chmod 0644 "${SUBSCRIPTION_MANIFEST_FILE}"
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

  printf 'vless://%s@%s:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=%s&fingerprint=%s&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
    "$(current_link_reality_uuid)" \
    "${SERVER_IP}" \
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
$(output_client_detail_line)
- 地址: ${SERVER_IP}
- 端口: 443
- UUID: $(current_link_reality_uuid)
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
- UUID: $(current_link_xhttp_uuid)
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
$(output_client_detail_line)
- 地址: ${SERVER_IP}
- 端口: 443
- UUID: $(current_link_xhttp_uuid)
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
$(output_client_detail_line)
- 上行地址: ${SERVER_IP}（Reality）
- 下行地址: ${XHTTP_DOMAIN}（CDN+TLS）
- UUID: $(current_link_xhttp_uuid)
- 上行 SNI: ${REALITY_SNI}
- 公钥: ${REALITY_PUBLIC_KEY}
- 短 ID: ${REALITY_SHORT_ID}
- 指纹: $(effective_fingerprint)
$(output_xhttp_shared_details)

链接:
${uri}
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
- Raw VLESS 订阅: ${SUBSCRIPTION_RAW_FILE}
- Base64 VLESS 订阅: ${SUBSCRIPTION_BASE64_FILE}
- 订阅文件清单: ${SUBSCRIPTION_MANIFEST_FILE}
- Raw VLESS 订阅二维码: $(if [[ -f "${SUBSCRIPTION_RAW_QR_FILE}" ]]; then printf '%s' "${SUBSCRIPTION_RAW_QR_FILE}"; else printf '未生成'; fi)
- Base64 VLESS 订阅二维码: $(if [[ -f "${SUBSCRIPTION_BASE64_QR_FILE}" ]]; then printf '%s' "${SUBSCRIPTION_BASE64_QR_FILE}"; else printf '未生成'; fi)

## WARP
- 已启用: ${ENABLE_WARP}
- 本地 SOCKS5 端口: ${WARP_PROXY_PORT}

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

  build_link_context "$(selected_output_client_name)"
  cf_ssl_mode="$(cloudflare_ssl_mode_text)"

  cat <<EOF
# Xray WARP Team 部署信息

$(output_client_summary_block)

$(output_reality_block "${REALITY_URI}")

$(output_xhttp_reality_block "${XHTTP_REALITY_URI}")

$(output_xhttp_cdn_block "${XHTTP_URI}")

$(output_xhttp_split_block "${XHTTP_SPLIT_URI}")

$(output_xhttp_reverse_split_block "${XHTTP_REVERSE_SPLIT_URI}")

$(output_runtime_summary_block "${cf_ssl_mode}")

$(output_xhttp_cache_rules_block)
EOF
}

write_output_file() {
  OUTPUT_CLIENT_NAME="${1:-$(selected_output_client_name)}"
  write_subscription_files
  write_generated_file_atomically "${OUTPUT_FILE}" output_file_text
  chmod 0644 "${OUTPUT_FILE}"
}
