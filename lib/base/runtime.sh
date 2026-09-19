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

  # 首次遇到已存在的 xray.service 时按「接管别人的 unit」登记原件与当时状态；
  # 不登记的话卸载会直接把用户自己的服务定义删掉（复核 H31）。只认第一次：
  # xtun 自己创建的 unit 记为 existed=0，卸载仍按删除处理。
  record_takeover_original "${XRAY_SERVICE_FILE}" || return 1
  record_takeover_original_service_state "xray.service" || return 1

  backup_path "${XRAY_SERVICE_FILE}" || return 1
  install -m 0644 "${tmp_file}" "${XRAY_SERVICE_FILE}" || return 1
  rm -f "${tmp_file}"
}

write_xray_logrotate_config() {
  local tmp_file=""

  tmp_file="$(mktemp)"
  cat > "${tmp_file}" <<EOF
${XRAY_LOG_DIR}/access.log ${XRAY_LOG_DIR}/error.log /var/log/xtun/operations.log {
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

  backup_path "${XRAY_LOGROTATE_FILE}" || return 1
  install -m 0644 "${tmp_file}" "${XRAY_LOGROTATE_FILE}" || return 1
  rm -f "${tmp_file}"
}

service_exists() {
  local unit_name="${1}"
  local unit_dir=""
  local path=""

  # systemctl 认「haproxy」这种简写（等价于 haproxy.service），这里必须一致：
  # 拿简写去查 /lib/systemd/system/haproxy 一定查不到，会把装着的服务
  # 判成 not-installed，重启核对跟着报「未达到 active」（实机安装时就是这么挂的）。
  [[ "${unit_name}" == *.* ]] || unit_name="${unit_name}.service"

  for unit_dir in "${SYSTEMD_UNIT_DIRS[@]}"; do
    path="${unit_dir}/${unit_name}"
    [[ -f "${path}" || -L "${path}" ]] && return 0
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
      backup_path "${path}" || return 1
      rm -rf "${path}" || return 1
      UNINSTALL_REMOVED+=("${path}")
    fi
  done
}

# 0.11 及更早版本写盘、现在已废弃的路径。
# 统一从这里列出来，升级 / 卸载 / 重装时兜底清一遍。
# LEGACY_PATH_ROOT 供测试沙箱改写；生产环境留空，路径就是字面的绝对路径。
legacy_managed_paths() {
  local prefix="${LEGACY_PATH_ROOT:-}"

  printf '%s\n' \
    "${prefix}/usr/local/sbin/xtun-core-health.sh" \
    "${prefix}/etc/systemd/system/xtun-core-health.service" \
    "${prefix}/etc/systemd/system/xtun-core-health.timer" \
    "${prefix}/usr/local/etc/xray/health-state.env" \
    "${prefix}/usr/local/etc/xray/health-history.log" \
    "${prefix}/root/xtun-subscriptions" \
    "${prefix}/var/www/xtun-sub" \
    "${prefix}/var/lib/cloudflare-warp/mdm.xml" \
    "${prefix}/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg" \
    "${prefix}/etc/apt/sources.list.d/cloudflare-client.list" \
    "${prefix}/usr/local/sbin/xtun-warp-health.sh" \
    "${prefix}/etc/systemd/system/xtun-warp-health.service" \
    "${prefix}/etc/systemd/system/xtun-warp-health.timer"
}

# 下面这几个「校验 / 重启」函数都是在 `if ! xxx; then 回滚; fi` 里被调用的，
# 而 `if !` 会把整条调用链上的 set -e 关掉。所以每一步都得显式 `|| return 1`：
# 少写一个，前一步失败后函数会接着往下跑，最终返回最后一条命令（多半是
# log_success）的 0，调用方看到成功，回滚一次都不会触发。
validate_xray_config() {
  log_step "校验 Xray 配置。"
  "${XRAY_BIN}" run -test -config "${XRAY_CONFIG_FILE}" || return 1
  log_success "Xray 配置校验通过。"
}

validate_configs() {
  validate_xray_config || return 1

  log_step "校验 Nginx 配置。"
  nginx -t || return 1
  log_success "Nginx 配置校验通过。"

  log_step "校验 HAProxy 配置。"
  haproxy -c -f "${HAPROXY_CONFIG}" || return 1
  log_success "HAProxy 配置校验通过。"
}

# 旧接口保留给「可选组件」这一条路径：它少了服务停用那一步，同代回退覆盖不到。
# 文件回退本身走同代层的证据规则：有快照才还原，清单写明原本不存在才删除，
# 其余保留并告警——缺快照不等于「以前没有这份文件」（H13/D11）。
rollback_managed_paths() {
  local path=""
  local result=""

  for path in "$@"; do
    result="$(restore_generation_path "${path}" 2>/dev/null)" || true
    case "${result}" in
      restored)
        warn "回滚文件：${path}"
        ;;
      deleted)
        warn "移除本次新增文件：${path}"
        ;;
      *)
        warn "缺少可信原件或快照，保留现状不改：${path}"
        ;;
    esac
  done
}

rollback_optional_component_state() {
  local paths=()

  if [[ "${ENABLE_NET_OPT:-no}" == "yes" ]]; then
    stop_and_disable_service_if_present "${NET_SERVICE_NAME}"
    paths+=(
      "${NET_SYSCTL_CONF}"
      "${NET_HELPER_PATH}"
      "${NET_SERVICE_FILE}"
    )
  fi

  [[ "${#paths[@]}" -gt 0 ]] || return 0

  warn "检测到可选组件应用失败，正在回滚网络优化托管文件。"
  rollback_managed_paths "${paths[@]}"
  systemctl daemon-reload >/dev/null 2>&1 || true

  if [[ "${ENABLE_NET_OPT:-no}" == "yes" ]]; then
    sysctl --system >/dev/null 2>&1 || true
  fi
}

# nginx 和 haproxy 都能热重载，而且这三类改动（改 SNI / 改路径 / 换证书）没有一个
# 需要断连接：nginx 收到 SIGHUP 会重读配置和证书，老 worker 把在飞的请求做完再退；
# haproxy 先自检配置再给 master 发 USR2，老进程继续伺候已建立的连接。
# restart 则是把这台机上所有在跑的代理连接一次性掐断。没在跑时才退回 restart。
reload_or_restart_service() {
  local unit="${1}"
  local before=""

  before="$(service_active_state "${unit}")"

  if systemctl is-active --quiet "${unit}"; then
    systemctl reload "${unit}" || return 1
    # reload 返回 0 不等于老进程还活着：配置热重载失败时服务可能已经掉下去，
    # 这种情况必须报失败，不能留下「已重载」的成功提示。
    if ! service_reaches_active_state "${unit}"; then
      SERVICE_ACTION_RESULTS+=("${unit}:重载后不是 active（${before} → $(service_active_state "${unit}")）")
      warn "${unit} 重载后不是 active，请检查配置与服务日志。"
      return 1
    fi
    SERVICE_ACTION_RESULTS+=("${unit}:reloaded")
    log_success "${unit} 已重载。"
    return 0
  fi

  restart_service_verified "${unit}" || return 1
  log_success "${unit} 已启动。"
}

# 刚写下的 systemd drop-in 改的是进程 rlimit，reload 套不上，这一次得走重启。
apply_nginx_service_change() {
  if [[ "${NGINX_RESTART_REQUIRED:-no}" != "yes" ]]; then
    reload_or_restart_service nginx || return 1
    return 0
  fi

  systemctl daemon-reload || return 1
  restart_service_verified nginx.service || return 1
  log_success "nginx 已重启（套用新的 fd 限额）。"
  NGINX_RESTART_REQUIRED="no"
}

restart_services() {
  log_step "重载 systemd 并重启核心服务。"
  ensure_xray_user lookup || return 1
  systemctl daemon-reload || return 1
  # enable 只负责开机自启。原来写的是 `enable --now` 之后紧跟一次 restart，
  # 等于把三个服务各起两遍；启动统一交给下面一段。
  systemctl enable xray haproxy nginx || return 1
  restart_service_verified xray.service || return 1
  log_success "xray 已启动。"
  # nginx 必须先于 haproxy：haproxy 起跑时对 127.0.0.1:8443 做健康检查，
  # nginx 还没起来就把 be_xhttp_cdn 判 DOWN（Connection refused），
  # 要等下一轮 check（默认 2s）才恢复——这个窗口内的 TLS 探测全部撞墙。
  apply_nginx_service_change || return 1
  reload_or_restart_service haproxy || return 1
}

# 旧版本把原件混在事务备份里，路径是 <备份目录>/etc/nginx/nginx.conf。
# 找不到首次接管原件时，只能从这些历史备份里挑最早的一份当原件。
find_legacy_nginx_original() {
  local entry_path=""
  local best_path=""

  # 按备份目录名排序：旧布局就是 BACKUP_ROOT/YYYYmmdd-HHMMSS/…，
  # 目录名就是那次操作的时间，用它比文件 mtime 稳（复制出来的备份 mtime 会变）。
  # 另外全量读进来自己挑，不用 `| head -n 1`：那会让 find 吃 SIGPIPE，
  # 在 set -o pipefail 下把整条命令判成 141，恢复流程会莫名其妙挂掉。
  while IFS= read -r entry_path; do
    [[ -n "${entry_path}" ]] || continue
    # 只认「不是 xtun 写的」那一份：备份目录的深度新旧布局相同，
    # 要是把 xtun 自己生成的主配置当原件还原，就会在报告里说「已还原」
    # 而磁盘上还是我们的文件——比找不到更糟。
    if grep -qF '# Generated by xtun.sh' "${entry_path}" 2>/dev/null; then
      continue
    fi
    if [[ -z "${best_path}" || "${entry_path}" < "${best_path}" ]]; then
      best_path="${entry_path}"
    fi
  done < <(find "${BACKUP_ROOT:-/root/xtun-backups}" -mindepth 4 -maxdepth 4 \
    -path '*/etc/nginx/nginx.conf' -type f -printf '%p\n' 2>/dev/null || true)

  printf '%s' "${best_path}"
}

# 接管过的节点卸载时把 nginx 主配置还回去。
# 这里最贵的错误是「没找到原件就自己编一份」：发行版默认模板和用户原来的配置
# 是两回事，写下去等于把一台还在跑别的站点的 nginx 换掉主配置。
# 所以顺序是：首次接管原件 → 旧备份里最早的一份 → 什么都找不到就保留并报告。
# 结果写在 NGINX_MAIN_RESTORE_RESULT，调用方据此决定状态能不能翻转：
# not-managed / missing / restored / deleted / legacy-restored / unconfirmed。
NGINX_MAIN_RESTORE_RESULT=""
restore_nginx_main_config() {
  local original=""
  local legacy=""
  local existed=""

  NGINX_MAIN_RESTORE_RESULT=""
  if [[ "${NGINX_MAIN_MANAGED:-no}" != "yes" ]]; then
    NGINX_MAIN_RESTORE_RESULT="not-managed"
    log "未接管 ${NGINX_MAIN_CONFIG}（NGINX_MAIN_MANAGED=no），保留当前文件不动。"
    return 0
  fi

  if [[ ! -f "${NGINX_MAIN_CONFIG}" ]]; then
    NGINX_MAIN_RESTORE_RESULT="missing"
    return 0
  fi

  if [[ -e "$(takeover_original_record_file)" || -L "$(takeover_original_record_file)" ]]; then
    takeover_manifest_validate || { warn "nginx 首次原件登记损坏，保留当前文件。"; return 1; }
    existed="$(takeover_original_existed "${NGINX_MAIN_CONFIG}" 2>/dev/null || true)"
    if [[ "${existed}" == 1 ]] && ! takeover_original_verify "${NGINX_MAIN_CONFIG}"; then
      warn "nginx 首次原件缺失或摘要不符，保留当前文件。"
      return 1
    fi
  fi
  original="$(takeover_original_path "${NGINX_MAIN_CONFIG}")"
  if [[ -e "${original}" || -L "${original}" ]]; then
    restore_takeover_original "${NGINX_MAIN_CONFIG}" || { warn "nginx 首次原件或登记校验失败，保留当前文件。"; return 1; }
    NGINX_MAIN_RESTORE_RESULT="restored"
    log "已还原接管前的 ${NGINX_MAIN_CONFIG}（原件：${original}）。"
    return 0
  fi

  existed="$(takeover_original_existed "${NGINX_MAIN_CONFIG}" 2>/dev/null || true)"
  if [[ "${existed}" == "0" ]]; then
    rm -f "${NGINX_MAIN_CONFIG}"
    NGINX_MAIN_RESTORE_RESULT="deleted"
    log "已删除由 xtun 创建、接管前并不存在的 ${NGINX_MAIN_CONFIG}。"
    return 0
  fi

  legacy="$(find_legacy_nginx_original)"
  if [[ -n "${legacy}" ]]; then
    mkdir -p "$(dirname "${NGINX_MAIN_CONFIG}")"
    cp -a "${legacy}" "${NGINX_MAIN_CONFIG}" || return 1
    NGINX_MAIN_RESTORE_RESULT="legacy-restored"
    log "已从旧备份还原 ${NGINX_MAIN_CONFIG}（${legacy}）。"
    return 0
  fi

  NGINX_MAIN_RESTORE_RESULT="unconfirmed"
  warn "找不到 ${NGINX_MAIN_CONFIG} 的可信原件，保留当前文件不做替换；"
  warn "如需恢复，请从 ${BACKUP_ROOT:-/root/xtun-backups} 或系统备份里自行确认后再动。"
  UNINSTALL_UNCONFIRMED+=("${NGINX_MAIN_CONFIG}")
  return 0
}

remove_legacy_managed_paths() {
  local path=""
  local had_legacy="no"
  local -a paths=()
  local unit=""

  # 只停我们自己命名的旧 unit。warp-svc 可能是用户自己装的 Cloudflare WARP
  # 客户端在跑，名字里没有我们的标记，停它就是「停止他人服务」。
  for unit in xtun-core-health.timer xtun-core-health.service xtun-warp-health.timer xtun-warp-health.service; do
    if service_exists "${unit}"; then
      systemctl disable --now "${unit}" >/dev/null 2>&1 || return 1
    fi
  done

  while IFS= read -r path; do
    if [[ -e "${path}" || -L "${path}" ]]; then
      paths+=("${path}")
      had_legacy="yes"
    fi
  done < <(legacy_managed_paths | grep -vE 'cloudflare|warp-svc' || true)

  while IFS= read -r path; do
    [[ -e "${path}" || -L "${path}" ]] || continue
    UNINSTALL_KEPT+=("${path}（Cloudflare WARP 客户端文件，可能是外部安装）")
  done < <(legacy_managed_paths | grep -E 'cloudflare-warp|cloudflare-client' || true)

  [[ "${had_legacy}" == "yes" ]] || return 0

  log_step "清理旧版本遗留的托管文件。"
  if [[ "${#paths[@]}" -gt 0 ]]; then
    remove_managed_paths "${paths[@]}" || return 1
  fi
  systemctl daemon-reload >/dev/null 2>&1 || return 1
  log "旧版本遗留的巡检、WARP Team、本地订阅目录与 nginx 订阅目录文件已清理。"
}

# 安装和 apply-config 会清理旧托管资源；在第一次删除/停用之前收齐证据。
generation_legacy_scope() {
  local -n paths_ref="${1}"
  local -n units_ref="${2}"
  local path=""
  local unit=""

  while IFS= read -r path; do
    [[ "${path}" != *cloudflare* && "${path}" != *warp-svc* ]] || continue
    [[ -e "${path}" || -L "${path}" ]] && paths_ref+=("${path}")
  done < <(legacy_managed_paths)
  for unit in xtun-core-health.timer xtun-core-health.service xtun-warp-health.timer xtun-warp-health.service; do
    service_exists "${unit}" && units_ref+=("${unit}")
  done
  return 0
}

begin_install_generation() {
  local -a paths=(
    "${SELF_COMMAND_PATH}" "${SELF_INSTALL_DIR}" "${XRAY_BIN}" "${XRAY_ASSET_DIR}"
    "${XRAY_CONFIG_DIR}" "${XRAY_SERVICE_FILE}" "${XRAY_LOGROTATE_FILE}"
  )
  local -a units=(xray.service haproxy.service nginx.service)

  if [[ "${ENABLE_NET_OPT:-no}" == "yes" ]]; then
    paths+=("${NET_SYSCTL_CONF}" "${NET_HELPER_PATH}" "${NET_SERVICE_FILE}")
    units+=("${NET_SERVICE_NAME}")
  fi
  generation_legacy_scope paths units || return 1
  begin_generation "安装/重建" yes "${units[@]}" -- "${paths[@]}" || return 1
  generation_add_permissions "${XRAY_LOG_DIR}" "${XRAY_LOG_DIR}/access.log" "${XRAY_LOG_DIR}/error.log"
}

finalize_installation() {
  # 独立调用时自己开一代；install_cmd 那条路已经开着同代上下文，就沿用，
  # 否则安装阶段备份过的 SELF/XRAY 路径会被清出回退清单。
  if [[ "${GENERATION_ACTIVE:-no}" != "yes" ]]; then
    begin_install_generation || return 1
  fi

  if ! validate_configs; then
    generation_failed "托管配置校验失败"
    return 1
  fi

  # root 的首次 run -test 会创建 0600 日志。确认日志归 xray 用户所有后
  # 才启动低权限服务；原有日志的权限已由 begin_install_generation 保存。
  if ! ensure_xray_user lookup || ! ensure_managed_permissions all; then
    generation_failed "安装运行文件权限准备失败"
    return 1
  fi

  if ! restart_services; then
    generation_failed "核心服务未能达到 active"
    return 1
  fi

  if ! verify_served_tls_assets || ! write_certificate_receipt; then
    generation_failed "安装后实际供证校验失败"
    return 1
  fi

  if ! write_state_file; then
    generation_failed "写入状态文件失败"
    return 1
  fi

  if ! write_output_file; then
    generation_failed "写入节点输出与二维码失败"
    return 1
  fi

  generation_commit || return 1
}

restart_core_services() {
  log_step "应用托管服务变更。"
  ensure_xray_user lookup || return 1
  # xray 没有配置热重载，只能重启。
  # 同 restart_services：nginx 在前，别让 haproxy 的初始健康检查把后端判死。
  restart_service_verified xray.service || return 1
  log_success "xray 已重启。"
  apply_nginx_service_change || return 1
  reload_or_restart_service haproxy || return 1
}

restart_xray_service() {
  log_step "重启 Xray 服务。"
  ensure_xray_user lookup || return 1
  restart_service_verified xray.service || return 1
  log_success "xray 已重启。"
}

write_runtime_managed_files() {
  h3_prepare_generation || return 1
  deploy_fallback_site || return 1
  write_warp_rules_file || return 1
  write_xray_config || return 1
  write_haproxy_config || return 1
  write_nginx_config || return 1
  write_nginx_main_config || return 1
  write_nginx_limits_dropin || return 1
}

apply_managed_files() {
  local include_tls_assets="${1:-no}"

  if [[ "${GENERATION_ACTIVE:-no}" != "yes" ]]; then
    begin_generation "托管配置变更" "${include_tls_assets}" xray.service haproxy.service nginx.service || return 1
  fi
  if ! ensure_xray_user lookup; then
    generation_failed "准备 Xray 运行用户失败"
    return 1
  fi

  if [[ "${include_tls_assets}" == "yes" ]]; then
    if ! write_tls_assets; then
      generation_failed "写入 TLS 证书/密钥失败"
      return 1
    fi
  fi

  # 写到一半失败也要回滚：几个托管文件是分别落盘的，
  # 半份新配置 + 半份旧配置比整份旧配置更难查。
  if ! write_runtime_managed_files; then
    generation_failed "写入托管配置文件失败"
    return 1
  fi

  if ! validate_configs; then
    generation_failed "托管配置校验失败"
    return 1
  fi

  if ! restart_core_services; then
    generation_failed "核心服务未能达到 active"
    return 1
  fi

  if [[ "${include_tls_assets}" == yes ]] && { ! verify_served_tls_assets || ! write_certificate_receipt; }; then
    generation_failed "换证后实际供证校验失败"
    return 1
  fi

  if ! write_state_file; then
    generation_failed "写入状态文件失败"
    return 1
  fi

  if ! write_output_file; then
    generation_failed "写入节点输出与二维码失败"
    return 1
  fi

  generation_commit || return 1
}

apply_xray_only_managed_update() {
  h3_prepare_generation || return 1
  begin_generation_xray_only "Xray-only 配置变更" || return 1
  if ! ensure_xray_user lookup; then
    generation_failed "准备 Xray 运行用户失败"
    return 1
  fi

  if ! write_xray_config; then
    generation_failed "写入 Xray 配置失败"
    return 1
  fi

  if ! validate_xray_config; then
    generation_failed "Xray 配置校验失败"
    return 1
  fi

  log "候选配置已写入；Xray 重启通过后再提交状态文件与节点输出。"
  if ! restart_xray_service; then
    generation_failed "重启 xray 失败"
    return 1
  fi

  if ! write_state_file; then
    generation_failed "写入状态文件失败"
    return 1
  fi

  if ! write_output_file; then
    generation_failed "写入节点输出与二维码失败"
    return 1
  fi

  generation_commit || return 1
}
