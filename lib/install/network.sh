# shellcheck shell=bash

# ------------------------------
# 网络优化层
# 负责 BBR/FQ/RPS/XPS 的探测与部署
# ------------------------------

available_cc() {
  if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
    cat /proc/sys/net/ipv4/tcp_available_congestion_control
  else
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true
  fi
}

supports_default_qdisc() {
  sysctl -a 2>/dev/null | grep -q '^net.core.default_qdisc ='
}

bbr_module_version() {
  modinfo tcp_bbr 2>/dev/null | awk '/^version:[[:space:]]*/ { print $2; exit }'
}

bbr_v3_active() {
  [[ "$(bbr_module_version)" == "3" ]]
}

# bbr1 是单独编出来的 BBRv1 模块；只有 bbr1 没有 bbr 的内核同样算支持。
cc_has_bbr() {
  printf ' %s ' "${1}" | grep -qE ' (bbr|bbr1) '
}

# 有些内核（含自编译的 BBRv3 内核）会把 BBRv1 单独编成 tcp_bbr1 模块。
# 它在丢包路径上不像 BBRv3 那样按 loss_thresh 锁窗口，跨境链路上通常更能顶住。
# 有就用，没有就还是 bbr——探测失败不影响安装。
preferred_congestion_control() {
  local cc=""

  cc="$(available_cc)"
  if ! printf ' %s ' "${cc}" | grep -q ' bbr1 '; then
    modprobe tcp_bbr1 >/dev/null 2>&1 || true
    cc="$(available_cc)"
  fi

  if printf ' %s ' "${cc}" | grep -q ' bbr1 '; then
    printf '%s' "bbr1"
    return
  fi

  printf '%s' "bbr"
}

# tcp_mem 三档按 MemTotal 的 1/8、1/6、1/4 给，单位是 4KB 页：
# 页数 = 字节数 / 4096 = (MemTotal_kB * 1024) / 4096 = MemTotal_kB / 4，
# 所以 1/8 档是 MemTotal_kB / 32，依此类推。
# 读不到 MemTotal 或内存太小（< 256MB）就不写，让内核用自己的估值。
net_tcp_mem_values() {
  local mem_kb=""

  mem_kb="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
  [[ "${mem_kb}" =~ ^[0-9]+$ ]] || return 1
  [[ "${mem_kb}" -ge 262144 ]] || return 1

  printf '%s %s %s' "$((mem_kb / 32))" "$((mem_kb / 24))" "$((mem_kb / 16))"
}

# xray.service 里写的是 LimitNOFILE=1048576，但 fs.file-max 的内核自估值只有
# 大约 MemTotal/10 页——也就是说单进程限额多半够不着，先撞上的是系统天花板。
# 这是 xtun 自己前后矛盾，跟负载无关，所以按 struct file 约 1KB 估算，
# 最多让它吃到内存的 1/4；撑不到 LimitNOFILE 的小内存机就不写，让内核自己估。
NET_FILE_MAX_CEILING="2097152"
net_file_max_value() {
  local mem_kb="${1:-}"
  local value=""

  [[ -n "${mem_kb}" ]] || mem_kb="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
  [[ "${mem_kb}" =~ ^[0-9]+$ ]] || return 1

  value="$((mem_kb / 4))"
  [[ "${value}" -ge 1048576 ]] || return 1
  [[ "${value}" -le "${NET_FILE_MAX_CEILING}" ]] || value="${NET_FILE_MAX_CEILING}"

  printf '%s' "${value}"
}

joey_bbr_repo() {
  printf '%s' "${JOEY_BBR_REPO:-byJoey/Actions-bbr-v3}"
}

joey_bbr_release_api_url() {
  printf 'https://api.github.com/repos/%s/releases?per_page=%s' \
    "$(joey_bbr_repo)" \
    "${JOEY_BBR_RELEASES_PER_PAGE:-100}"
}

joey_bbr_release_arch_filter() {
  local machine="${1:-$(uname -m)}"

  case "${machine}" in
    x86_64 | amd64)
      printf '%s' "x86_64"
      ;;
    aarch64 | arm64)
      printf '%s' "arm64"
      ;;
    *)
      return 1
      ;;
  esac
}

fetch_joey_bbr_release_metadata_json() {
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

  if [[ -n "${token}" ]]; then
    curl -fsSL \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/vnd.github+json" \
      "$(joey_bbr_release_api_url)"
  else
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      "$(joey_bbr_release_api_url)"
  fi
}

joey_bbr_latest_tag_from_metadata() {
  local metadata_json="${1}"
  local arch_filter="${2}"

  jq -r \
    --arg filter "${arch_filter}" \
    'if type == "array" then
       map(select(.tag_name? | test("^" + $filter + "-"; "i")))
       | sort_by(.published_at // "")
       | .[-1].tag_name // empty
     else
       empty
     end' \
    <<< "${metadata_json}" 2>/dev/null
}

joey_bbr_release_asset_rows_from_metadata() {
  local metadata_json="${1}"
  local tag_name="${2}"

  jq -r \
    --arg tag "${tag_name}" \
    'if type == "array" then
       .[]
       | select(.tag_name? == $tag)
       | .assets[]?
       | select(.name? | test("\\.deb$"; "i"))
       | select((.name? | test("(-dbg_|-dbgsym_)"; "i")) | not)
       | [.name, (.digest // ""), .browser_download_url]
       | @tsv
     else
       empty
     end' \
    <<< "${metadata_json}" 2>/dev/null
}

joey_bbr_latest_core_version_from_tag() {
  local tag_name="${1}"

  printf '%s' "${tag_name}" | sed -E 's/^(x86_64|arm64)-//'
}

joey_bbr_installed_kernel_version() {
  dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\n' 2>/dev/null \
    | awk '$1 ~ /^ii/ && $2 ~ /^linux-image-.*-joeyblog-bbrv3$/ { print $3; exit }'
}

validate_joey_bbr_asset_rows() {
  local asset_rows="${1}"

  [[ -n "${asset_rows}" ]] || die "未找到 Joey BBRv3 内核安装包。"
  printf '%s\n' "${asset_rows}" \
    | awk -F '\t' '$1 ~ /^linux-image-.*joeyblog-bbrv3.*\.deb$/ { found = 1 } END { exit !found }' \
    || die "Joey BBRv3 release 中缺少 linux-image 内核包。"
}

download_joey_bbrv3_asset() {
  local asset_url="${1}"
  local target_path="${2}"

  curl -fL "${asset_url}" -o "${target_path}"
}

download_joey_bbrv3_assets() {
  local asset_rows="${1}"
  local tmp_dir="${2}"
  local asset_name=""
  local asset_digest=""
  local asset_url=""
  local target_path=""
  local expected_sha256=""

  while IFS=$'\t' read -r asset_name asset_digest asset_url; do
    [[ -n "${asset_name}" ]] || continue
    [[ "${asset_name}" != */* && "${asset_name}" == linux-*.deb ]] || die "Joey BBRv3 资源文件名异常：${asset_name}"
    [[ -n "${asset_url}" ]] || die "Joey BBRv3 资源缺少下载地址：${asset_name}"

    target_path="${tmp_dir}/${asset_name}"
    expected_sha256="$(normalize_xray_sha256_value "${asset_digest}")"
    [[ -n "${expected_sha256}" ]] || die "Joey BBRv3 内核包 ${asset_name} 缺少 SHA256 校验值。"

    log "下载 BBRv3 内核包：${asset_name}"
    download_joey_bbrv3_asset "${asset_url}" "${target_path}"
    verify_file_sha256 "${target_path}" "${expected_sha256}" "Joey BBRv3 内核包 ${asset_name}"
  done <<< "${asset_rows}"
}

joey_bbrv3_deb_files() {
  local tmp_dir="${1}"

  find "${tmp_dir}" -maxdepth 1 -type f -name 'linux-*.deb' | sort
}

inspect_joey_bbrv3_package() {
  local deb_file="${1}"

  dpkg-deb -I "${deb_file}" >/dev/null 2>&1
}

update_joey_bbr_bootloader() {
  if command -v update-grub >/dev/null 2>&1; then
    update-grub
    return
  fi

  warn "未找到 update-grub；如果该 VPS 使用非 GRUB 引导，请确认新内核已加入引导配置。"
  return 0
}

install_joey_bbrv3_deb_files() {
  local tmp_dir="${1}"
  local deb_file=""
  local -a deb_files=()

  mapfile -t deb_files < <(joey_bbrv3_deb_files "${tmp_dir}")
  [[ "${#deb_files[@]}" -gt 0 ]] || die "未下载到 Joey BBRv3 deb 安装包。"

  for deb_file in "${deb_files[@]}"; do
    inspect_joey_bbrv3_package "${deb_file}" || die "当前系统无法读取安装包：${deb_file}"
  done

  log_step "安装 Joey BBRv3 内核包。"
  dpkg -i "${deb_files[@]}" || return 1
  update_joey_bbr_bootloader || return 1
  NET_BBRV3_REBOOT_REQUIRED="yes"
  log_success "Joey BBRv3 内核包安装完成。"
}

install_joey_bbrv3_kernel_if_needed() {
  local arch_filter=""
  local metadata_json=""
  local tag_name=""
  local latest_core_version=""
  local installed_version=""
  local asset_rows=""
  local tmp_dir=""

  NET_BBRV3_REBOOT_REQUIRED="${NET_BBRV3_REBOOT_REQUIRED:-no}"

  if bbr_v3_active; then
    log_success "当前内核已加载 BBRv3。"
    return 0
  fi

  if ! arch_filter="$(joey_bbr_release_arch_filter)"; then
    warn "Actions-bbr-v3 仅支持 x86_64 / arm64，当前架构不支持。"
    return 1
  fi

  command -v jq >/dev/null 2>&1 || die "缺少 jq，无法解析 Actions-bbr-v3 release 信息。"
  metadata_json="$(fetch_joey_bbr_release_metadata_json)" || die "无法获取 Actions-bbr-v3 release 信息。"
  tag_name="$(joey_bbr_latest_tag_from_metadata "${metadata_json}" "${arch_filter}")"
  [[ -n "${tag_name}" ]] || die "未找到适合当前架构 (${arch_filter}) 的 Actions-bbr-v3 release。"

  latest_core_version="$(joey_bbr_latest_core_version_from_tag "${tag_name}")"
  installed_version="$(joey_bbr_installed_kernel_version)"
  if [[ -n "${installed_version}" && "${installed_version}" == "${latest_core_version}"* ]]; then
    NET_BBRV3_REBOOT_REQUIRED="yes"
    warn "Joey BBRv3 内核 ${tag_name} 已安装，但当前尚未运行；请重启后生效。"
    return 0
  fi

  asset_rows="$(joey_bbr_release_asset_rows_from_metadata "${metadata_json}" "${tag_name}")"
  validate_joey_bbr_asset_rows "${asset_rows}"

  tmp_dir="$(mktemp -d)"
  if ! download_joey_bbrv3_assets "${asset_rows}" "${tmp_dir}"; then
    rm -rf "${tmp_dir}"
    return 1
  fi
  if ! install_joey_bbrv3_deb_files "${tmp_dir}"; then
    rm -rf "${tmp_dir}"
    return 1
  fi
  rm -rf "${tmp_dir}"
  warn "已安装 Joey BBRv3 内核 ${tag_name}，需要重启 VPS 后加载新内核。"
}

write_net_sysctl_conf() {
  local tmp_file=""
  local tcp_mem=""
  local file_max=""

  tmp_file="$(mktemp)"
  tcp_mem="$(net_tcp_mem_values || true)"
  file_max="$(net_file_max_value || true)"
  {
    cat <<'EOF'
# Generated by xtun.sh
# Safe baseline for proxy workloads and long-lived TCP sessions.

EOF
    if supports_default_qdisc || [[ "${NET_BBRV3_REBOOT_REQUIRED:-no}" == "yes" ]] || bbr_v3_active; then
      printf '%s\n' 'net.core.default_qdisc = fq'
    fi
    printf 'net.ipv4.tcp_congestion_control = %s\n\n' "$(preferred_congestion_control)"
    if [[ -n "${tcp_mem}" ]]; then
      cat <<'EOF'
# TCP 全局内存池，单位是 4KB 页。不写的话内核按很保守的估值给，
# 一旦越过中间那档进入内存压力态，内核会塌缩所有 socket 缓冲区，
# 下面调大的 rmem/wmem 会全部作废。按 MemTotal 的 1/8、1/6、1/4 给。
EOF
      printf 'net.ipv4.tcp_mem = %s\n\n' "${tcp_mem}"
    fi
    cat <<'EOF'
# rmem_default / wmem_default 对 TCP 不起作用（TCP 用 tcp_rmem[1]），
# 只影响 UDP。WARP 出站是 Xray 用户态 WireGuard，全走 UDP socket，
# 给小了 UdpRcvbufErrors 会飙上去。
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.optmem_max = 4194304
net.core.somaxconn = 65535

# 默认 netdev_max_backlog=1000 是纯内核默认值，单 RX 队列跑到 Gbps 级必丢包。
net.core.netdev_max_backlog = 32768
net.core.netdev_budget = 1200
net.core.netdev_budget_usecs = 8000

net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_max_tw_buckets = 262144
# 出站方向复用 TIME-WAIT socket。内核默认值是 2，只对 loopback 生效，
# 而代理机真正在烧本地端口的是出网那一侧。依赖 tcp_timestamps（内核默认已开）。
net.ipv4.tcp_tw_reuse = 1
# FIN-WAIT-2 默认要挂满 60s。代理机的连接建了就拆，缩到 15s 能早四倍回收。
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 524288 33554432
net.ipv4.tcp_slow_start_after_idle = 0
# 置 0 时内核会把烂路径上算出的极低 ssthresh 按目的 IP 缓存，
# 同一个客户端之后每条新连接一上来就是残废窗口。
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

net.ipv4.udp_rmem_min = 262144
net.ipv4.udp_wmem_min = 262144
EOF
    if [[ -n "${file_max}" ]]; then
      cat <<'EOF'

# 抬到能兜住 xray.service 里的 LimitNOFILE=1048576。
# 内核自估值大约只有 MemTotal/10 页，那个单进程限额多半永远够不着。
EOF
      printf 'fs.file-max = %s\n' "${file_max}"
    fi
  } > "${tmp_file}"

  backup_path "${NET_SYSCTL_CONF}"
  install -m 0644 "${tmp_file}" "${NET_SYSCTL_CONF}"
  rm -f "${tmp_file}"
}

write_net_helper_script() {
  local tmp_file=""

  tmp_file="$(mktemp)"
  cat > "${tmp_file}" <<'EOF'
#!/bin/sh
set -eu

iface="${1:-${IFACE:-$(ip -o -4 route show to default | awk '{print $5; exit}')}}"
[ -n "$iface" ] || exit 0
[ -d "/sys/class/net/$iface" ] || exit 0

cpus="$(nproc 2>/dev/null || echo 1)"
if [ "$cpus" -le 1 ]; then
    mask="1"
else
    mask="$(printf '%x' "$(( (1 << cpus) - 1 ))")"
fi

rx_queues="$(find "/sys/class/net/$iface/queues" -maxdepth 1 -type d -name 'rx-*' | wc -l)"
[ "$rx_queues" -ge 1 ] || rx_queues=1

global_entries=32768
per_queue=$((global_entries / rx_queues))
[ "$per_queue" -ge 4096 ] || per_queue=4096

modprobe sch_fq >/dev/null 2>&1 || true
# fq 默认 limit 10000p / flow_limit 100p，跨境高 BDP 链路上一条大流很容易顶到
# flow_limit 被丢包。放宽后由 pacing 控节奏，不再靠丢包反压。
# 老内核的 fq 不认这两个参数，退回不带参数的写法。
tc qdisc replace dev "$iface" root fq limit 100000 flow_limit 1000 >/dev/null 2>&1 \
    || tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 \
    || true

if [ -w /proc/sys/net/core/rps_sock_flow_entries ]; then
    printf '%s' "$global_entries" > /proc/sys/net/core/rps_sock_flow_entries
fi

for f in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
    [ -w "$f" ] || continue
    printf '%s' "$mask" > "$f"
done

for f in /sys/class/net/"$iface"/queues/rx-*/rps_flow_cnt; do
    [ -w "$f" ] || continue
    printf '%s' "$per_queue" > "$f"
done

for f in /sys/class/net/"$iface"/queues/tx-*/xps_rxqs; do
    [ -w "$f" ] || continue
    printf '%s' 1 > "$f"
done
EOF

  backup_path "${NET_HELPER_PATH}"
  install -m 0755 "${tmp_file}" "${NET_HELPER_PATH}"
  rm -f "${tmp_file}"
}

write_net_service() {
  local tmp_file=""

  tmp_file="$(mktemp)"
  cat > "${tmp_file}" <<EOF
[Unit]
Description=Apply Xray network optimizations
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${NET_HELPER_PATH}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  backup_path "${NET_SERVICE_FILE}"
  install -m 0644 "${tmp_file}" "${NET_SERVICE_FILE}"
  rm -f "${tmp_file}"
}

install_network_optimization() {
  local cc=""

  [[ "${ENABLE_NET_OPT}" == "yes" ]] || return 0

  install_joey_bbrv3_kernel_if_needed || return 1

  cc="$(available_cc)"
  if ! cc_has_bbr "${cc}"; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
    modprobe sch_fq >/dev/null 2>&1 || true
    cc="$(available_cc)"
  fi

  if ! cc_has_bbr "${cc}"; then
    if [[ "${NET_BBRV3_REBOOT_REQUIRED:-no}" == "yes" ]]; then
      warn "当前内核尚未暴露 BBR，已写入配置；重启进入 Joey BBRv3 内核后生效。"
    else
      warn "当前内核未暴露 BBR 支持，已跳过网络优化。"
      ENABLE_NET_OPT="skipped"
      return
    fi
  fi

  write_net_sysctl_conf
  write_net_helper_script
  write_net_service
  if ! sysctl --system >/dev/null; then
    if [[ "${NET_BBRV3_REBOOT_REQUIRED:-no}" == "yes" ]]; then
      warn "当前内核暂不能完整应用网络 sysctl；重启进入 Joey BBRv3 内核后会自动生效。"
    else
      return 1
    fi
  fi
  systemctl daemon-reload
  systemctl enable --now "${NET_SERVICE_NAME}" >/dev/null

  if [[ "${NET_BBRV3_REBOOT_REQUIRED:-no}" == "yes" ]]; then
    log_success "网络优化配置已写入；重启后加载 Joey BBRv3 内核。"
  fi
}
