# shellcheck shell=bash

# ------------------------------
# 配置生成层
# 只负责把当前全局状态展开成托管配置文本
# 不处理安装流程，也不直接编排服务生命周期
# ------------------------------

write_generated_file_atomically() {
  local target_path="${1}"
  local producer_fn="${2}"
  local tmp_file=""
  local target_dir=""

  target_dir="$(dirname "${target_path}")"
  mkdir -p "${target_dir}"
  tmp_file="$(mktemp "${target_dir}/.$(basename "${target_path}").tmp.XXXXXX")"

  if ! "${producer_fn}" > "${tmp_file}"; then
    rm -f "${tmp_file}"
    return 1
  fi

  backup_path "${target_path}"
  mv -f "${tmp_file}" "${target_path}"
}

xray_log_json() {
  jq -cn '{
    loglevel: "warning",
    access: "/var/log/xray/access.log",
    error: "/var/log/xray/error.log"
  }'
}

xray_sniffing_json() {
  jq -cn '{
    enabled: true,
    destOverride: ["http", "tls", "quic"],
    metadataOnly: false,
    routeOnly: true
  }'
}

xray_clients_json() {
  local client_kind="${1}"

  node_clients_text | jq -Rn \
    --arg client_kind "${client_kind}" \
    --arg default_client_name "$(default_node_client_name)" \
    '[
      inputs
      | select(length > 0)
      | split("|")
      | {
          name: .[0],
          reality_uuid: .[1],
          xhttp_uuid: .[2]
        }
      | if $client_kind == "reality" then
          {
            id: .reality_uuid,
            flow: "xtls-rprx-vision",
            email: (if .name == $default_client_name then "reality-vision" else (.name + "-reality-vision") end)
          }
        else
          {
            id: .xhttp_uuid,
            email: (if .name == $default_client_name then "xhttp-cdn" else (.name + "-xhttp-cdn") end)
          }
        end
    ]'
}

xray_reality_clients_json() {
  xray_clients_json "reality"
}

xray_xhttp_clients_json() {
  xray_clients_json "xhttp"
}

xray_reality_inbound_json() {
  jq -cn \
    --argjson clients "$(xray_reality_clients_json)" \
    --arg xhttp_local_port "${XHTTP_LOCAL_PORT}" \
    --arg reality_target "${REALITY_TARGET}" \
    --arg reality_sni "${REALITY_SNI}" \
    --arg reality_private_key "${REALITY_PRIVATE_KEY}" \
    --arg reality_short_id "${REALITY_SHORT_ID}" \
    'def sniffing: {
      enabled: true,
      destOverride: ["http", "tls", "quic"],
      metadataOnly: false,
      routeOnly: true
    };
    {
      tag: "reality-vision",
      listen: "127.0.0.1",
      port: 2443,
      protocol: "vless",
      settings: {
        clients: $clients,
        decryption: "none",
        fallbacks: [
          {
            dest: ($xhttp_local_port | tonumber),
            xver: 0
          }
        ]
      },
      streamSettings: {
        network: "raw",
        security: "reality",
        realitySettings: {
          show: false,
          target: $reality_target,
          xver: 0,
          serverNames: [$reality_sni],
          privateKey: $reality_private_key,
          shortIds: [$reality_short_id]
        }
      },
      sniffing: sniffing
    }'
}

xray_xhttp_inbound_json() {
  local xpadding_filter='.'

  if [[ "${XHTTP_XPADDING_ENABLED:-no}" == "yes" ]]; then
    xpadding_filter='.streamSettings.xhttpSettings += {
      xPaddingObfsMode: true,
      xPaddingKey: $xhttp_xpadding_key,
      xPaddingHeader: $xhttp_xpadding_header,
      xPaddingPlacement: $xhttp_xpadding_placement,
      xPaddingMethod: $xhttp_xpadding_method
    }'
  fi

  jq -cn \
    --arg xhttp_local_port "${XHTTP_LOCAL_PORT}" \
    --argjson clients "$(xray_xhttp_clients_json)" \
    --arg xhttp_decryption "${XHTTP_VLESS_DECRYPTION:-none}" \
    --arg xhttp_path "${XHTTP_PATH}" \
    --arg xhttp_xpadding_key "${XHTTP_XPADDING_KEY:-${DEFAULT_XHTTP_XPADDING_KEY}}" \
    --arg xhttp_xpadding_header "${XHTTP_XPADDING_HEADER:-${DEFAULT_XHTTP_XPADDING_HEADER}}" \
    --arg xhttp_xpadding_placement "${XHTTP_XPADDING_PLACEMENT:-${DEFAULT_XHTTP_XPADDING_PLACEMENT}}" \
    --arg xhttp_xpadding_method "${XHTTP_XPADDING_METHOD:-${DEFAULT_XHTTP_XPADDING_METHOD}}" \
    'def sniffing: {
      enabled: true,
      destOverride: ["http", "tls", "quic"],
      metadataOnly: false,
      routeOnly: true
    };
    {
      tag: "xhttp-cdn",
      listen: "127.0.0.1",
      port: ($xhttp_local_port | tonumber),
      protocol: "vless",
      settings: {
        clients: $clients,
        decryption: $xhttp_decryption
      },
      streamSettings: {
        network: "xhttp",
        xhttpSettings: {
          host: "",
          path: $xhttp_path,
          mode: "auto"
        }
      },
      sniffing: sniffing
    } | '"${xpadding_filter}"
}

xray_inbounds_json() {
  jq -cn \
    --argjson reality_inbound "$(xray_reality_inbound_json)" \
    --argjson xhttp_inbound "$(xray_xhttp_inbound_json)" \
    '[$reality_inbound, $xhttp_inbound]'
}

xray_direct_domains_json() {
  jq -cn '[
    "domain:telegram.org",
    "domain:api.telegram.org",
    "domain:t.me",
    "domain:telegram.me",
    "domain:core.telegram.org"
  ]'
}

xray_warp_domains_json() {
  local rules=()
  local line=""

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    rules+=("${line}")
  done < <(current_warp_rules_text)

  jq -cn '$ARGS.positional' --args "${rules[@]}"
}

xray_routing_rules_json() {
  if [[ "${ENABLE_WARP}" != "yes" ]]; then
    jq -cn '[]'
    return
  fi

  jq -cn \
    --argjson direct_domains "$(xray_direct_domains_json)" \
    --argjson warp_domains "$(xray_warp_domains_json)" \
    '[
      {
        type: "field",
        outboundTag: "direct",
        domain: $direct_domains
      },
      {
        type: "field",
        outboundTag: "WARP",
        domain: $warp_domains
      }
    ]'
}

xray_direct_outbound_json() {
  jq -cn '{
    tag: "direct",
    protocol: "freedom"
  }'
}

xray_block_outbound_json() {
  jq -cn '{
    tag: "block",
    protocol: "blackhole"
  }'
}

xray_warp_outbound_json() {
  jq -cn \
    --arg warp_proxy_port "${WARP_PROXY_PORT}" \
    '{
      tag: "WARP",
      protocol: "socks",
      settings: {
        servers: [
          {
            address: "127.0.0.1",
            port: ($warp_proxy_port | tonumber),
            users: []
          }
        ]
      }
    }'
}

xray_outbounds_json() {
  if [[ "${ENABLE_WARP}" != "yes" ]]; then
    jq -cn \
      --argjson direct_outbound "$(xray_direct_outbound_json)" \
      --argjson block_outbound "$(xray_block_outbound_json)" \
      '[$direct_outbound, $block_outbound]'
    return
  fi

  jq -cn \
    --argjson direct_outbound "$(xray_direct_outbound_json)" \
    --argjson warp_outbound "$(xray_warp_outbound_json)" \
    --argjson block_outbound "$(xray_block_outbound_json)" \
    '[$direct_outbound, $warp_outbound, $block_outbound]'
}

write_xray_config() {
  generate_xhttp_vless_encryption_if_needed
  write_generated_file_atomically "${XRAY_CONFIG_FILE}" xray_config_text

  ensure_managed_permissions
}

xray_config_text() {
  jq -cn \
    --argjson log_json "$(xray_log_json)" \
    --argjson inbounds "$(xray_inbounds_json)" \
    --argjson routing_rules "$(xray_routing_rules_json)" \
    --argjson outbounds "$(xray_outbounds_json)" \
    '{
      log: $log_json,
      inbounds: $inbounds,
      routing: {
        domainStrategy: "AsIs",
        rules: $routing_rules
      },
      outbounds: $outbounds
    }'
}

nginx_proxy_headers_config() {
  cat <<'EOF'
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
EOF
}

nginx_fallback_location_config() {
  local proxy_headers=""

  proxy_headers="$(nginx_proxy_headers_config)"
  cat <<EOF
    location / {
        proxy_pass https://www.harvard.edu;
        proxy_set_header Host www.harvard.edu;
${proxy_headers}
    }
EOF
}

nginx_xhttp_location_config() {
  cat <<EOF
    location ${XHTTP_PATH} {
        grpc_pass 127.0.0.1:${XHTTP_LOCAL_PORT};
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto \$scheme;
        grpc_set_header X-Forwarded-Host \$host;
    }
EOF
}

nginx_server_config() {
  local fallback_location=""
  local xhttp_location=""

  fallback_location="$(nginx_fallback_location_config)"
  xhttp_location="$(nginx_xhttp_location_config)"
  cat <<EOF
server {
    listen 127.0.0.1:${NGINX_TLS_PORT} ssl;
    http2 on;
    server_name ${XHTTP_DOMAIN};

    ssl_certificate ${TLS_CERT_FILE};
    ssl_certificate_key ${TLS_KEY_FILE};

${fallback_location}

${xhttp_location}
}
EOF
}

write_nginx_config() {
  write_generated_file_atomically "${NGINX_CONFIG_FILE}" nginx_server_config
}

haproxy_global_config() {
  cat <<'EOF'
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    user haproxy
    group haproxy
    maxconn 20000
EOF
}

haproxy_defaults_config() {
  cat <<'EOF'
defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 2m
    timeout server 2m
EOF
}

haproxy_frontend_config() {
  cat <<EOF
frontend fe_tls_shared_443
    bind :443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }

    use_backend be_xhttp_cdn if { req.ssl_sni -i ${XHTTP_DOMAIN} }
    default_backend be_reality_vision
EOF
}

haproxy_xhttp_backend_config() {
  cat <<EOF
backend be_xhttp_cdn
    mode tcp
    server nginx_cdn 127.0.0.1:${NGINX_TLS_PORT} check
EOF
}

haproxy_reality_backend_config() {
  cat <<'EOF'
backend be_reality_vision
    mode tcp
    server reality_vision 127.0.0.1:2443 check
EOF
}

haproxy_config_text() {
  cat <<EOF
$(haproxy_global_config)

$(haproxy_defaults_config)

$(haproxy_frontend_config)

$(haproxy_xhttp_backend_config)

$(haproxy_reality_backend_config)
EOF
}

write_haproxy_config() {
  write_generated_file_atomically "${HAPROXY_CONFIG}" haproxy_config_text
}
