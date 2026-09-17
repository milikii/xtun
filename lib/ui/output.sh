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

build_link_context() {
  local objects="" number="" node="" uri=""
  objects="$(node_objects_current)" || return 1
  REALITY_URI="" XHTTP_REALITY_URI="" XHTTP_URI="" XHTTP_SPLIT_URI="" XHTTP_REVERSE_SPLIT_URI=""
  REALITY_V6_URI="" XHTTP_SPLIT_CDN_REALITY_V6_URI="" XHTTP_H3_URI="" XHTTP_SPLIT_CDN_H3_URI=""
  while IFS= read -r node; do
    number="$(jq -r '.number' <<< "${node}")" || return 1
    uri="$(node_object_uri <<< "${node}")" || return 1
    case "${number}" in
      1) REALITY_URI="${uri}" ;; 2) XHTTP_REALITY_URI="${uri}" ;; 3) XHTTP_URI="${uri}" ;;
      4) XHTTP_SPLIT_URI="${uri}" ;; 5) XHTTP_REVERSE_SPLIT_URI="${uri}" ;;
      6) REALITY_V6_URI="${uri}" ;; 7) XHTTP_SPLIT_CDN_REALITY_V6_URI="${uri}" ;;
      8) XHTTP_H3_URI="${uri}" ;; 9) XHTTP_SPLIT_CDN_H3_URI="${uri}" ;;
      *) return 1 ;;
    esac
  done < <(jq -c '.[]' <<< "${objects}")
}

# 位次固定；所有输出格式消费相同的节点对象。
node_link_entries() {
  local objects="" node="" uri=""
  objects="$(node_objects_current)" || return 1
  while IFS= read -r node; do
    uri="$(node_object_uri <<< "${node}")" || return 1
    jq -r --arg uri "${uri}" '[.number,.label,$uri] | @tsv' <<< "${node}" || return 1
  done < <(jq -c '.[]' <<< "${objects}")
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

## XHTTP H3
- 选择: $(h3_intent_text)
- 本地检查: ${H3_REASON:-未验证}
- 公网 UDP / 客户端路径: 未验证，需使用真实客户端检查。

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
- 说明: ECH 只用于相应 CDN TLS 层；连接失败不会自动回退普通 TLS。可独立导出 plain / ech 变体。

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

  build_link_context || return 1
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
  local NODE_SNAPSHOT_JSON=""
  if ! have_qrencode; then warn "缺少 qrencode，未生成新一代节点产物。"; return 1; fi
  NODE_SNAPSHOT_JSON="$(build_node_objects)" || return 1
  write_generated_file_atomically "${OUTPUT_FILE}" output_file_text || return 1
  chmod 0600 "${OUTPUT_FILE}" || return 1
  write_link_qr_pngs
}

# 二维码 PNG 是这一代的交付物：先在 staging 目录里整批画完，全部成功才换上去。
# 半套新二维码、或者「跑着新配置却留着上一代二维码」都是不能提交的状态（D12/H14）。
# 目录整体重建：链接变了（换 UUID / SNI / 路径 / 域名、IPv6 或 H3 开关变化）旧图必须消失。
write_link_qr_pngs() {
  local stage_dir=""

  if ! have_qrencode; then
    warn "缺少 qrencode，本次产物生成失败，旧二维码保留；安装依赖后可运行 xtun rebuild-qr。"
    return 1
  fi

  mkdir -p "$(dirname "${QR_OUTPUT_DIR}")" || return 1
  stage_dir="$(mktemp -d "${QR_OUTPUT_DIR}.staging.XXXXXX")" || {
    warn "无法创建二维码暂存目录：${QR_OUTPUT_DIR}.staging.*"
    return 1
  }
  if ! render_link_qr_pngs_into "${stage_dir}"; then
    rm -rf "${stage_dir}"
    warn "二维码 PNG 生成失败，本次变更不提交。"
    return 1
  fi
  if ! write_node_artifact_manifest "${stage_dir}"; then rm -rf "${stage_dir}"; return 1; fi
  if ! backup_path "${QR_OUTPUT_DIR}"; then
    rm -rf "${stage_dir}"
    return 1
  fi
  if ! rm -rf "${QR_OUTPUT_DIR}"; then
    rm -rf "${stage_dir}"
    return 1
  fi
  if ! mv "${stage_dir}" "${QR_OUTPUT_DIR}"; then
    rm -rf "${stage_dir}"
    return 1
  fi
  chmod 0700 "${QR_OUTPUT_DIR}" || return 1
}

render_link_qr_pngs_into() {
  local target_dir="${1}"
  local idx="" label="" uri="" target="" tmp_file=""
  local entries=""

  chmod 0700 "${target_dir}" || return 1
  entries="$(node_link_entries)" || return 1
  [[ -n "${entries}" ]] || return 1
  while IFS=$'\t' read -r idx label uri; do
    [[ -n "${label}" ]] || continue
    target="${target_dir}/$(printf '%02d-%s.png' "${idx}" "${label}")"
    tmp_file="$(mktemp "${target_dir}/.qr.XXXXXX")" || return 1
    if ! qrencode -o "${tmp_file}" -l L -s 6 -m 2 "${uri}" 2>/dev/null || ! node_png_valid "${tmp_file}"; then
      rm -f "${tmp_file}"
      warn "二维码 PNG 生成失败：${label}"
      return 1
    fi
    if ! mv -f "${tmp_file}" "${target}"; then
      rm -f "${tmp_file}"
      return 1
    fi
    chmod 0600 "${target}" || return 1
  done <<< "${entries}"

  return 0
}
