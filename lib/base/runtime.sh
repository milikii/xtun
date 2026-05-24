# shellcheck shell=bash

# ------------------------------
# 运行时编排层
# 负责服务、托管文件与重启流程
# ------------------------------

write_xray_service() {
  local tmp_file=""

  tmp_file="$(mktemp)"
  cat > "${tmp_file}" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=xray
Group=xray
Environment=XRAY_LOCATION_ASSET=${XRAY_ASSET_DIR}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStartPre=${XRAY_BIN} run -test -config ${XRAY_CONFIG_FILE}
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG_FILE}
Restart=always
RestartSec=3s
TimeoutStartSec=30s
TimeoutStopSec=15s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  backup_path "${XRAY_SERVICE_FILE}"
  install -m 0644 "${tmp_file}" "${XRAY_SERVICE_FILE}"
  rm -f "${tmp_file}"
}

write_xray_logrotate_config() {
  local tmp_file=""

  tmp_file="$(mktemp)"
  cat > "${tmp_file}" <<'EOF'
/var/log/xray/access.log /var/log/xray/error.log /var/log/xtun/operations.log {
  daily
  rotate 7
  missingok
  notifempty
  compress
  delaycompress
  copytruncate
  create 0640 xray xray
}
EOF

  backup_path "${XRAY_LOGROTATE_FILE}"
  install -m 0644 "${tmp_file}" "${XRAY_LOGROTATE_FILE}"
  rm -f "${tmp_file}"
}

write_core_health_helper() {
  local tmp_file=""

  tmp_file="$(mktemp)"
  cat > "${tmp_file}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

health_state_file='${HEALTH_STATE_FILE}'
health_history_file='${HEALTH_HISTORY_FILE}'

check_port() {
  local port="\${1}"
  ss -ltnH "( sport = :\${port} )" 2>/dev/null | grep -q .
}

write_health_state() {
  local action="\${1}"
  local reason="\${2}"
  local tmp_file=""

  mkdir -p "\$(dirname "\${health_state_file}")"
  tmp_file="\$(mktemp "\$(dirname "\${health_state_file}")/.health-state.tmp.XXXXXX")"
  if [[ -f "\${health_state_file}" ]]; then
    grep -v '^CORE_HEALTH_' "\${health_state_file}" > "\${tmp_file}" 2>/dev/null || true
  fi
  {
    printf 'CORE_HEALTH_LAST_CHECK_AT=%q\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'CORE_HEALTH_LAST_ACTION=%q\n' "\${action}"
    printf 'CORE_HEALTH_LAST_REASON=%q\n' "\${reason}"
  } >> "\${tmp_file}"
  mv -f "\${tmp_file}" "\${health_state_file}"
  chmod 0640 "\${health_state_file}" 2>/dev/null || true
}

append_health_history() {
  local action="\${1}"
  local reason="\${2}"
  local tmp_file=""

  mkdir -p "\$(dirname "\${health_history_file}")"
  tmp_file="\$(mktemp "\$(dirname "\${health_history_file}")/.health-history.tmp.XXXXXX")"
  if [[ -f "\${health_history_file}" ]]; then
    tail -n 49 "\${health_history_file}" > "\${tmp_file}" 2>/dev/null || true
  fi
  printf '%s | core | %s | %s\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "\${action}" "\${reason}" >> "\${tmp_file}"
  mv -f "\${tmp_file}" "\${health_history_file}"
  chmod 0640 "\${health_history_file}" 2>/dev/null || true
}

restart_all() {
  systemctl restart xray >/dev/null 2>&1 || true
  systemctl restart haproxy >/dev/null 2>&1 || true
  systemctl restart nginx >/dev/null 2>&1 || true
}

if ! systemctl is-active --quiet xray || ! systemctl is-active --quiet haproxy || ! systemctl is-active --quiet nginx; then
  restart_all
  sleep 3
  write_health_state "restarted" "service inactive"
  append_health_history "restarted" "service inactive"
  exit 0
fi

if ! check_port 443 || ! check_port 2443 || ! check_port 8001 || ! check_port ${NGINX_TLS_PORT}; then
  restart_all
  write_health_state "restarted" "required listening port missing"
  append_health_history "restarted" "required listening port missing"
  exit 0
fi

write_health_state "ok" "services and listening ports healthy"
append_health_history "ok" "services and listening ports healthy"
EOF

  backup_path "${CORE_HEALTH_HELPER}"
  install -m 0755 "${tmp_file}" "${CORE_HEALTH_HELPER}"
  rm -f "${tmp_file}"
}

write_core_health_service() {
  local tmp_file=""

  tmp_file="$(mktemp)"
  cat > "${tmp_file}" <<EOF
[Unit]
Description=Check and recover Xray shared-ingress core services
After=network-online.target xray.service haproxy.service nginx.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CORE_HEALTH_HELPER}
EOF

  backup_path "${CORE_HEALTH_SERVICE_FILE}"
  install -m 0644 "${tmp_file}" "${CORE_HEALTH_SERVICE_FILE}"
  rm -f "${tmp_file}"
}

write_core_health_timer() {
  local tmp_file=""

  tmp_file="$(mktemp)"
  cat > "${tmp_file}" <<EOF
[Unit]
Description=Run Xray shared-ingress core health check periodically

[Timer]
OnBootSec=90s
OnUnitActiveSec=3min
Unit=${CORE_HEALTH_SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF

  backup_path "${CORE_HEALTH_TIMER_FILE}"
  install -m 0644 "${tmp_file}" "${CORE_HEALTH_TIMER_FILE}"
  rm -f "${tmp_file}"
}

write_core_health_monitor() {
  write_core_health_helper
  write_core_health_service
  write_core_health_timer
}

service_exists() {
  local unit_name="${1}"
  local path=""

  for path in /etc/systemd/system/"${unit_name}" /lib/systemd/system/"${unit_name}" /usr/lib/systemd/system/"${unit_name}"; do
    if [[ -f "${path}" || -L "${path}" ]]; then
      return 0
    fi
  done

  return 1
}

stop_and_disable_service_if_present() {
  local unit_name="${1}"

  if service_exists "${unit_name}"; then
    systemctl disable --now "${unit_name}" >/dev/null 2>&1 || systemctl stop "${unit_name}" >/dev/null 2>&1 || true
  fi
}

remove_managed_paths() {
  local path=""

  for path in "$@"; do
    if [[ -e "${path}" || -L "${path}" ]]; then
      backup_path "${path}"
      rm -rf "${path}"
    fi
  done
}

validate_xray_config() {
  log_step "校验 Xray 配置。"
  "${XRAY_BIN}" run -test -config "${XRAY_CONFIG_FILE}"
  log_success "Xray 配置校验通过。"
}

validate_configs() {
  validate_xray_config
  log_step "校验 Nginx 配置。"
  nginx -t
  log_success "Nginx 配置校验通过。"

  log_step "校验 HAProxy 配置。"
  haproxy -c -f "${HAPROXY_CONFIG}"
  log_success "HAProxy 配置校验通过。"
}

rollback_managed_paths() {
  local path=""

  for path in "$@"; do
    if [[ -n "${BACKUP_DIR:-}" && ( -e "${BACKUP_DIR}${path}" || -L "${BACKUP_DIR}${path}" ) ]]; then
      warn "回滚文件：${path}"
    else
      warn "移除本次新增文件：${path}"
    fi
    restore_backup_path "${path}" || true
  done
}

attempt_runtime_service_recovery() {
  ensure_xray_user
  ensure_managed_permissions
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart xray >/dev/null 2>&1 || true
  systemctl restart haproxy >/dev/null 2>&1 || true
  systemctl restart nginx >/dev/null 2>&1 || true
}

attempt_xray_service_recovery() {
  ensure_xray_user
  ensure_managed_permissions
  systemctl restart xray >/dev/null 2>&1 || true
}

rollback_managed_runtime_state() {
  local include_tls_assets="${1:-no}"
  local include_service_file="${2:-no}"
  local paths=(
    "${XRAY_CONFIG_FILE}"
    "${HAPROXY_CONFIG}"
    "${NGINX_CONFIG_FILE}"
    "${WARP_RULES_FILE}"
    "${HEALTH_STATE_FILE}"
    "${HEALTH_HISTORY_FILE}"
    "${CORE_HEALTH_HELPER}"
    "${CORE_HEALTH_SERVICE_FILE}"
    "${CORE_HEALTH_TIMER_FILE}"
    "${XRAY_LOGROTATE_FILE}"
    "${OP_LOG_DIR}"
    "${FALLBACK_SITE_DIR}"
  )

  if [[ "${include_tls_assets}" == "yes" ]]; then
    paths+=("${TLS_CERT_FILE}" "${TLS_KEY_FILE}" "${ACME_RELOAD_HELPER}")
  fi

  if [[ "${include_service_file}" == "yes" ]]; then
    paths+=("${XRAY_SERVICE_FILE}")
  fi

  warn "检测到托管配置应用失败，正在回滚最近一次变更。"
  rollback_managed_paths "${paths[@]}"
  attempt_runtime_service_recovery
}

rollback_xray_config_state() {
  warn "检测到 Xray 配置应用失败，正在回滚最近一次 Xray 配置变更。"
  rollback_managed_paths "${XRAY_CONFIG_FILE}"
  attempt_xray_service_recovery
}

rollback_xray_only_managed_state() {
  local paths=(
    "${XRAY_CONFIG_FILE}"
    "${STATE_FILE}"
    "${OUTPUT_FILE}"
    "${SUBSCRIPTION_RAW_FILE}"
    "${SUBSCRIPTION_BASE64_FILE}"
    "${SUBSCRIPTION_MANIFEST_FILE}"
    "${SUBSCRIPTION_RAW_QR_FILE}"
    "${SUBSCRIPTION_BASE64_QR_FILE}"
  )

  warn "检测到 Xray-only 变更应用失败，正在回滚最近一次变更。"
  rollback_managed_paths "${paths[@]}"
  attempt_xray_service_recovery
}

rollback_install_runtime_state() {
  local paths=(
    "${SELF_COMMAND_PATH}"
    "${SELF_INSTALL_DIR}"
    "${XRAY_BIN}"
    "${XRAY_ASSET_DIR}"
    "${FALLBACK_SITE_DIR}"
  )

  warn "检测到安装运行时应用失败，正在回滚管理命令与 Xray 核心文件。"
  rollback_managed_paths "${paths[@]}"
}

rollback_optional_component_state() {
  local paths=()

  if [[ "${ENABLE_WARP:-no}" == "yes" ]]; then
    stop_and_disable_service_if_present "${WARP_HEALTH_TIMER_NAME}"
    stop_and_disable_service_if_present "${WARP_HEALTH_SERVICE_NAME}"
    stop_and_disable_service_if_present "warp-svc.service"
    paths+=(
      "${WARP_APT_KEYRING}"
      "${WARP_APT_SOURCE_LIST}"
      "${WARP_MDM_FILE}"
      "${WARP_HEALTH_HELPER}"
      "${WARP_HEALTH_SERVICE_FILE}"
      "${WARP_HEALTH_TIMER_FILE}"
    )
  fi

  if [[ "${ENABLE_NET_OPT:-no}" == "yes" ]]; then
    stop_and_disable_service_if_present "${NET_SERVICE_NAME}"
    paths+=(
      "${NET_SYSCTL_CONF}"
      "${NET_HELPER_PATH}"
      "${NET_SERVICE_FILE}"
    )
  fi

  [[ "${#paths[@]}" -gt 0 ]] || return 0

  warn "检测到可选组件应用失败，正在回滚 WARP / 网络优化托管文件。"
  rollback_managed_paths "${paths[@]}"
  systemctl daemon-reload >/dev/null 2>&1 || true

  if [[ "${ENABLE_NET_OPT:-no}" == "yes" ]]; then
    sysctl --system >/dev/null 2>&1 || true
  fi
}

restart_services() {
  log_step "重载 systemd 并重启核心服务。"
  ensure_xray_user
  ensure_managed_permissions
  systemctl daemon-reload
  systemctl enable --now xray
  log_success "xray 已启动。"
  systemctl enable --now haproxy
  log_success "haproxy 已启动。"
  systemctl enable --now nginx
  log_success "nginx 已启动。"
  systemctl restart xray
  systemctl restart haproxy
  systemctl restart nginx
  systemctl enable --now "${CORE_HEALTH_TIMER_NAME}"
  log_success "${CORE_HEALTH_TIMER_NAME} 已启动。"

  if [[ "${ENABLE_WARP}" == "yes" ]]; then
    systemctl enable --now warp-svc
    log_success "warp-svc 已启动。"
  fi
}

finalize_installation() {
  if ! validate_configs; then
    rollback_managed_runtime_state "yes" "yes"
    rollback_optional_component_state
    return 1
  fi

  if ! restart_services; then
    rollback_managed_runtime_state "yes" "yes"
    rollback_optional_component_state
    return 1
  fi

  write_state_file
  write_output_file
}

restart_core_services() {
  log_step "重启托管服务。"
  ensure_xray_user
  ensure_managed_permissions
  systemctl restart xray
  log_success "xray 已重启。"
  systemctl restart haproxy
  log_success "haproxy 已重启。"
  systemctl restart nginx
  log_success "nginx 已重启。"
}

restart_xray_service() {
  log_step "重启 Xray 服务。"
  ensure_xray_user
  ensure_managed_permissions
  systemctl restart xray
  log_success "xray 已重启。"
}

write_runtime_managed_files() {
  deploy_fallback_site
  write_warp_rules_file
  write_xray_config
  write_haproxy_config
  write_nginx_config
}

apply_managed_files() {
  local include_tls_assets="${1:-no}"

  if [[ "${include_tls_assets}" == "yes" ]]; then
    write_tls_assets
  fi

  write_runtime_managed_files
  if ! validate_configs; then
    rollback_managed_runtime_state "${include_tls_assets}" "no"
    return 1
  fi

  if ! restart_core_services; then
    rollback_managed_runtime_state "${include_tls_assets}" "no"
    return 1
  fi

  write_state_file
  write_output_file
}

apply_xray_only_managed_update() {
  write_xray_config
  if ! validate_xray_config; then
    rollback_xray_config_state
    return 1
  fi

  write_state_file
  write_output_file

  log "客户端配置、状态文件和输出文件已写入；接下来只重启 Xray。"
  if ! restart_xray_service; then
    rollback_xray_only_managed_state
    return 1
  fi
}
