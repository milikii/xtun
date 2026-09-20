# shellcheck shell=bash

# ------------------------------
# 安装与副作用层
# 负责安装依赖、证书处理、WARP、网络优化
# 以及安装前输入准备
# ------------------------------

install_packages() {
  local package_name=""
  local -a packages=()

  log_step "安装依赖包。"
  apt-get update || return 1
  for package_name in ca-certificates curl gnupg haproxy nginx iproute2 jq kmod openssl unzip uuid-runtime libcap2-bin qrencode socat; do
    # 已有服务可能来自自编译或第三方源；安装发行版同名包会替换其二进制，
    # 即使配置快照恢复成功，旧配置也可能再也启动不了。
    case "${package_name}" in
      nginx|haproxy)
        if command -v "${package_name}" >/dev/null 2>&1; then
          log "保留已有 ${package_name} 可执行文件，本次不安装或更新同名系统包。"
          continue
        fi
        ;;
      socat)
        # 只有 HTTP-01（acme.sh standalone）用得上；其它证书模式不装。
        [[ "${CERT_MODE:-}" == "acme-http" ]] || continue
        ;;
    esac
    packages+=("${package_name}")
    record_package_origin "${package_name}" || return 1
  done
  apt-get install -y -o Dpkg::Options::=--force-confold "${packages[@]}" || return 1
  log_success "依赖包安装完成。"
}

# 确认后的两段：先准备已展示过的最小依赖，再做深预检（D07）。
# 确认前只报告缺什么，这里才真的装；装失败时软件包可能已落地，
# 但托管配置、state 和服务都还没动，报告要把这两件事分开说（W05 第 5 条）。
install_prepare_and_preflight() {
  local missing_packages=""
  local missing_list=""
  local package_name=""

  install_record_stage "准备最小依赖" || return 1
  missing_packages="$(install_missing_dependency_packages)" || return 1
  if [[ -n "${missing_packages}" ]]; then
    missing_list="${missing_packages//$'\n'/ }"
    while IFS= read -r package_name; do
      record_package_origin "${package_name}" || return 1
    done <<< "${missing_packages}"
    log_step "准备缺失的最小依赖。"
    log "将安装: ${missing_list}"
    if ! apt-get update; then
      warn "依赖准备失败：已装好的软件包保留；托管配置、state 与服务均未改动。"
      return 1
    fi
    # shellcheck disable=SC2086
    if ! apt-get install -y -o Dpkg::Options::=--force-confold ${missing_list}; then
      warn "依赖准备失败：已装好的软件包保留；托管配置、state 与服务均未改动。"
      return 1
    fi
    log_success "最小依赖准备完成。"
  fi

  missing_packages="$(install_missing_dependency_packages)" || return 1
  if [[ -n "${missing_packages}" ]]; then
    warn "依赖准备后仍缺少必要命令（软件包：${missing_packages//$'\n'/、}），停止于托管配置应用前。"
    return 1
  fi
  install_record_stage "依赖准备后的深预检" || return 1
  run_install_preflight_checks
}

# 阶段与包清单只是中断后的说明，不参与 generation 的提交判定。
install_record_stage() {
  local temporary=""

  INSTALL_EXECUTION_STAGE="${1}"
  [[ -n "${BACKUP_DIR:-}" && -d "${BACKUP_DIR}" ]] || return 0
  temporary="$(mktemp "${BACKUP_DIR}/install-stage.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "${INSTALL_EXECUTION_STAGE}" > "${temporary}" || ! durable_replace_file "${temporary}" "${BACKUP_DIR}/install-stage.txt"; then
    rm -f "${temporary}"
    return 1
  fi
}

install_package_inventory() {
  dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${Version}\n' \
    | awk -F'\t' '$2 != "not-installed" && $2 != "config-files" {print $1 "\t" $3 "\t" $2}' | LC_ALL=C sort
}

install_record_package_baseline() {
  local temporary=""

  [[ -n "${BACKUP_DIR:-}" && -d "${BACKUP_DIR}" ]] || return 0
  temporary="$(mktemp "${BACKUP_DIR}/install-packages.tmp.XXXXXX")" || return 1
  if ! install_package_inventory > "${temporary}" || ! durable_replace_file "${temporary}" "${BACKUP_DIR}/install-packages-before.tsv"; then
    rm -f "${temporary}"
    return 1
  fi
}

install_report_failure_context() {
  local stage="${INSTALL_EXECUTION_STAGE:-未记录}"
  local current=""
  local retained=""
  local baseline="${BACKUP_DIR:-}/install-packages-before.tsv"

  if [[ -f "${BACKUP_DIR:-}/install-stage.txt" ]]; then
    IFS= read -r stage < "${BACKUP_DIR}/install-stage.txt" || true
  fi
  warn "安装停在：${stage}。"
  if [[ -f "${baseline}" ]]; then
    if current="$(install_package_inventory)"; then
      retained="$(awk -F'\t' '
        NR == FNR {before[$1]=$2 "\t" ($3 == "" ? "installed" : $3); next}
        !($1 in before) || before[$1] != $2 "\t" $3 {print $1 "=" $2 ($3 == "installed" ? "" : "（" $3 "）")}
      ' "${baseline}" <(printf '%s\n' "${current}"))"
      if [[ -n "${retained}" ]]; then
        warn "本次新增或更新的软件包已保留（未回滚）：${retained//$'\n'/、}"
      else
        warn "包清单核对：未发现本次新增或更新的软件包。"
      fi
    else
      warn "无法核对软件包清单；软件包不自动回滚，基线保留在 ${baseline}。"
    fi
  fi
  if install_draft_present; then
    warn "已保留安装草稿：${INSTALL_DRAFT_FILE}；处理未完成操作后可用 xtun install --task resume 重试。"
  else
    warn "没有可用的安装草稿，重试时需要重新提供输入。"
  fi
  if [[ "${GENERATION_LABEL:-}" == "安装/重建" ]]; then
    warn "系统用户与运行日志保留，不随托管配置恢复删除。"
  fi
}

# 装之前先记每个包是不是本来就装过：以后 --purge 只能卸我们自己装进来的，
# 用户为了别的站点早就装好的 nginx / haproxy 不能被我们连锅端走。
record_package_origin() {
  local package_name="${1}"
  local record=""
  local existed="0"
  local inventory=""

  record="$(takeover_original_record_file)"

  if [[ -e "${record}" || -L "${record}" ]]; then
    takeover_manifest_validate "${record}" || return 1
    if takeover_manifest_field "${package_name}" 2 >/dev/null; then return 0; fi
  fi
  # 查完整包表区分「包不存在」和「dpkg 查询失败」；已有残留包也按外来资源保留。
  inventory="$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n')" || return 1
  if awk -F'\t' -v package="${package_name}" '($1 == package || index($1, package ":") == 1) && $2 != "not-installed" {found=1} END {exit !found}' <<< "${inventory}"; then existed="1"; fi
  takeover_manifest_record "${package_name}" "${existed}" -
}

# 返回 0 表示这个包是 xtun 自己装的，允许在 --purge 时卸载；
# 返回 1 表示用户原本就有，保留。
package_installed_by_xtun() {
  local package_name="${1}"
  local record=""
  local existed=""

  record="$(takeover_original_record_file)"

  [[ -f "${record}" ]] || return 1
  existed="$(takeover_manifest_field "${package_name}" 2)" || return 1
  [[ "${existed}" == "0" ]]
}

managed_package_names() {
  printf '%s\n' \
    "haproxy" \
    "nginx" \
    "nginx-common" \
    "jq" \
    "uuid-runtime" \
    "qrencode" \
    "socat"
}

normalize_xray_sha256_value() {
  xray_normalize_sha256 "${1:-}"
}

parse_xray_dgst_sha256() {
  xray_parse_dgst_sha256 "${1}" "${2}"
}

verify_file_sha256() {
  local file_path="${1}"
  local expected_sha256="${2}"
  local label="${3}"
  local actual_sha256=""

  [[ -n "${expected_sha256}" ]] || die "${label} 缺少 SHA256 校验值。"
  actual_sha256="$(sha256sum "${file_path}" | awk '{print tolower($1)}')"
  [[ "${actual_sha256}" == "${expected_sha256}" ]] || die "${label} SHA256 校验失败。"
}

install_xray() {
  local arch=""
  local tmp_dir=""

  arch="$(detect_xray_arch)" || return 1
  tmp_dir="$(mktemp -d)" || return 1

  # 版本上下文按动作隔离：换了请求就重新解析，同一次动作内解析一次即锁定（H15）。
  log_step "解析 Xray-core 版本。"
  if ! xray_ensure_release_context "${XRAY_VERSION_REQUEST}" "${arch}"; then
    rm -rf "${tmp_dir}"
    return 1
  fi

  log_step "下载并校验 Xray-core ${XRAY_SELECTED_TAG}。"
  log "资源文件：${XRAY_SELECTED_ARCHIVE_NAME}"
  log "tag 指向提交：${XRAY_SELECTED_COMMIT}"
  if ! (
    trap 'rm -rf "${tmp_dir}"' EXIT
    xray_download_release "${tmp_dir}" || exit 1
    unzip -qo "${tmp_dir}/${XRAY_SELECTED_ARCHIVE_NAME}" -d "${tmp_dir}/xray" || exit 1
    xray_validate_candidate_archive "${tmp_dir}" || exit 1
    [[ -s "${tmp_dir}/xray/geoip.dat" && -s "${tmp_dir}/xray/geosite.dat" ]] || {
      warn "候选核心归档缺少 geoip.dat 或 geosite.dat。"; exit 1;
    }

    mkdir -p "$(dirname "${XRAY_BIN}")" "${XRAY_ASSET_DIR}" || exit 1
    install -m 0755 "${tmp_dir}/xray/xray" "${XRAY_BIN}" || exit 1
    install -m 0644 "${tmp_dir}/xray/geoip.dat" "${XRAY_ASSET_DIR}/geoip.dat" || exit 1
    install -m 0644 "${tmp_dir}/xray/geosite.dat" "${XRAY_ASSET_DIR}/geosite.dat" || exit 1
    ensure_xray_bind_capability || exit 1
    write_xray_install_identity "${tmp_dir}/${XRAY_SELECTED_ARCHIVE_NAME}" || exit 1
  ); then
    rm -rf "${tmp_dir}"
    return 1
  fi

  rm -rf "${tmp_dir}"
  log "校验来源：${XRAY_SELECTED_CHECKSUM_SOURCE}"
  log_success "Xray-core ${XRAY_SELECTED_TAG} 已安装到 ${XRAY_BIN}。"
}

ensure_xray_bind_capability() {
  [[ -f "${XRAY_BIN}" && ! -L "${XRAY_BIN}" ]] || return 1
  if command -v setcap >/dev/null 2>&1; then
    setcap cap_net_bind_service=+ep "${XRAY_BIN}" || { warn "为 Xray 二进制设置 CAP_NET_BIND_SERVICE 失败。"; return 1; }
    [[ "$(xray_binary_capabilities)" == cap_net_bind_service=ep ]] || {
      warn "Xray CAP_NET_BIND_SERVICE 写入后核验失败。"; return 1;
    }
  else
    warn "系统中未找到 setcap，无法确认 Xray 绑定 443 的能力。"
    return 1
  fi
}

ensure_managed_permissions() {
  local scope="${1:-all}"
  local path=""
  local -a files=()

  [[ -n "${XRAY_UID}" && -n "${XRAY_GID}" ]] || die "尚未解析 xray 用户的 UID/GID。"
  case "${scope}" in
    config) files=("${XRAY_CONFIG_FILE}") ;;
    rules) files=("${WARP_RULES_FILE}") ;;
    tls) files=("${TLS_CERT_FILE}" "${TLS_KEY_FILE}") ;;
    runtime|all) files=("${XRAY_CONFIG_FILE}" "${WARP_RULES_FILE}" "${TLS_CERT_FILE}" "${TLS_KEY_FILE}") ;;
    *) return 1 ;;
  esac
  for path in "${files[@]}"; do
    [[ -f "${path}" ]] || continue
    [[ ! -L "${path}" ]] || { warn "托管权限目标是软链接，未修改其指向的文件：${path}"; return 1; }
    chown 0:"${XRAY_GID}" "${path}" || return 1
    chmod 0640 "${path}" || return 1
  done
  if [[ "${scope}" == tls || "${scope}" == runtime || "${scope}" == all ]] && [[ -d "${SSL_DIR}" ]]; then
    [[ ! -L "${SSL_DIR}" ]] || return 1
    chown 0:"${XRAY_GID}" "${SSL_DIR}" || return 1
    chmod 0750 "${SSL_DIR}" || return 1
  fi

  # 普通配置变更不碰日志；安装为已有日志保留权限快照，repair-perms 显式修复。
  if [[ "${scope}" == all && -d "${XRAY_LOG_DIR}" ]]; then
    [[ ! -L "${XRAY_LOG_DIR}" ]] || return 1
    chown "${XRAY_UID}:${XRAY_GID}" "${XRAY_LOG_DIR}" || return 1
    chmod 0750 "${XRAY_LOG_DIR}" || return 1
    if [[ -f "${XRAY_LOG_DIR}/access.log" ]]; then
      [[ ! -L "${XRAY_LOG_DIR}/access.log" ]] || return 1
      chown "${XRAY_UID}:${XRAY_GID}" "${XRAY_LOG_DIR}/access.log" || return 1
      chmod 0640 "${XRAY_LOG_DIR}/access.log" || return 1
    fi
    if [[ -f "${XRAY_LOG_DIR}/error.log" ]]; then
      [[ ! -L "${XRAY_LOG_DIR}/error.log" ]] || return 1
      chown "${XRAY_UID}:${XRAY_GID}" "${XRAY_LOG_DIR}/error.log" || return 1
      chmod 0640 "${XRAY_LOG_DIR}/error.log" || return 1
    fi
  fi
  return 0
}

ensure_xray_user() {
  local mode="${1:-create}"

  if ! id -u xray >/dev/null 2>&1; then
    [[ "${mode}" != lookup ]] || { warn "找不到 xray 运行用户，请先完成安装或运行 xtun repair-perms。"; return 1; }
    useradd --system --home "${XRAY_STATE_DIR}" --create-home --shell /usr/sbin/nologin xray || return 1
  fi

  XRAY_UID="$(id -u xray)" || return 1
  XRAY_GID="$(id -g xray)" || return 1
  [[ -n "${XRAY_UID}" && -n "${XRAY_GID}" ]] || die "无法解析 xray 用户的 UID/GID。"
  [[ "${mode}" != lookup ]] || return 0

  mkdir -p "${XRAY_CONFIG_DIR}" "${XRAY_ASSET_DIR}" || return 1
  if [[ ! -d "${XRAY_LOG_DIR}" ]]; then
    install -d -o "${XRAY_UID}" -g "${XRAY_GID}" -m 0750 "${XRAY_LOG_DIR}" || return 1
  fi
  [[ ! -L "${SSL_DIR}" ]] || return 1
  install -d -o 0 -g "${XRAY_GID}" -m 0750 "${SSL_DIR}" || return 1
  ensure_managed_permissions
}

generate_reality_keys_if_needed() {
  local key_output=""

  if [[ -n "${REALITY_PRIVATE_KEY}" && -n "${REALITY_PUBLIC_KEY}" ]]; then
    return
  fi

  if [[ -n "${REALITY_PRIVATE_KEY}" && -z "${REALITY_PUBLIC_KEY}" ]]; then
    key_output="$("${XRAY_BIN}" x25519 -i "${REALITY_PRIVATE_KEY}")"
    REALITY_PUBLIC_KEY="$(printf '%s\n' "${key_output}" | awk '
      /^(Password \(PublicKey\)|Public key|PublicKey):/ {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        print
        exit
      }
    ')"
    [[ -n "${REALITY_PUBLIC_KEY}" ]] || die "无法从提供的 REALITY 私钥推导公钥。"
    return
  fi

  key_output="$("${XRAY_BIN}" x25519)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "${key_output}" | awk '
    /^(Private key|PrivateKey):/ {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      print
      exit
    }
  ')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "${key_output}" | awk '
    /^(Password \(PublicKey\)|Public key|PublicKey):/ {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      print
      exit
    }
  ')"

  [[ -n "${REALITY_PRIVATE_KEY}" ]] || die "生成 REALITY 私钥失败。"
  [[ -n "${REALITY_PUBLIC_KEY}" ]] || die "生成 REALITY 公钥失败。"
}

generate_xhttp_vless_encryption_if_needed() {
  local enc_output=""
  local encryption_pair=""

  if [[ "${XHTTP_VLESS_ENCRYPTION_ENABLED}" != "yes" ]]; then
    XHTTP_VLESS_DECRYPTION=""
    XHTTP_VLESS_ENCRYPTION=""
    return
  fi

  if [[ -n "${XHTTP_VLESS_DECRYPTION}" && -n "${XHTTP_VLESS_ENCRYPTION}" ]]; then
    return
  fi
  if [[ -n "${XHTTP_VLESS_DECRYPTION}" && "${XHTTP_VLESS_DECRYPTION}" != none ]]; then
    warn "已有 VLESS 解密身份缺少配对客户端记录；请恢复 state/节点文档，或明确选择轮换身份。"
    return 1
  fi

  enc_output="$("${XRAY_BIN}" vlessenc)"
  encryption_pair="$(parse_xhttp_vless_encryption_pair "${enc_output}")" || die "无法解析 XHTTP 的 VLESS Encryption 认证方案。"
  XHTTP_VLESS_DECRYPTION="$(printf '%s' "${encryption_pair}" | cut -f1)"
  XHTTP_VLESS_ENCRYPTION="$(printf '%s' "${encryption_pair}" | cut -f2)"

  [[ -n "${XHTTP_VLESS_DECRYPTION}" ]] || die "生成 XHTTP 的 VLESS decryption 失败。"
  [[ -n "${XHTTP_VLESS_ENCRYPTION}" ]] || die "生成 XHTTP 的 VLESS encryption 失败。"
}

install_draft_file_text() {
  # 草稿不是「上一次输入」的模糊副本：schema、来源和任务类型一起写下来，
  # 恢复时才知道这份选择属于哪次动作（D06/H06）。
  write_state_kv "INSTALL_DRAFT_SCHEMA" "${INSTALL_DRAFT_SCHEMA:-1}"
  write_state_kv "INSTALL_DRAFT_TASK" "${INSTALL_TASK-}"
  write_state_kv "INSTALL_DRAFT_SOURCE" "${INSTALL_TASK_SOURCE-}"
  write_state_kv "INSTALL_DRAFT_UPDATED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_state_kv "XRAY_VERSION_REQUEST" "${XRAY_VERSION_REQUEST-}"
  write_state_kv "SERVER_IP" "${SERVER_IP-}"
  write_state_kv "SERVER_IP6" "${SERVER_IP6-}"
  write_state_kv "SERVER_IP_PRESENCE" "${SERVER_IP_PRESENCE:-absent}"
  write_state_kv "SERVER_IP6_PRESENCE" "${SERVER_IP6_PRESENCE:-absent}"
  write_state_kv "NODE_LABEL_PREFIX" "${NODE_LABEL_PREFIX-}"
  write_state_kv "REALITY_UUID" "${REALITY_UUID-}"
  write_state_kv "REALITY_SNI" "${REALITY_SNI-}"
  write_state_kv "REALITY_TARGET" "${REALITY_TARGET-}"
  write_state_kv "REALITY_SHORT_ID" "${REALITY_SHORT_ID-}"
  write_state_kv "REALITY_PRIVATE_KEY" "${REALITY_PRIVATE_KEY-}"
  write_state_kv "XHTTP_UUID" "${XHTTP_UUID-}"
  write_state_kv "XHTTP_DOMAIN" "${XHTTP_DOMAIN-}"
  write_state_kv "XHTTP_PATH" "${XHTTP_PATH-}"
  write_state_kv "XHTTP_VLESS_ENCRYPTION_ENABLED" "${XHTTP_VLESS_ENCRYPTION_ENABLED-}"
  write_state_kv "XHTTP_VLESS_DECRYPTION" "${XHTTP_VLESS_DECRYPTION-}"
  write_state_kv "XHTTP_VLESS_ENCRYPTION" "${XHTTP_VLESS_ENCRYPTION-}"
  write_state_kv "XHTTP_ECH_CONFIG_LIST" "${XHTTP_ECH_CONFIG_LIST-}"
  write_state_kv "XHTTP_ECH_FORCE_QUERY" "${XHTTP_ECH_FORCE_QUERY-}"
  write_state_kv "XHTTP_XPADDING_ENABLED" "${XHTTP_XPADDING_ENABLED-}"
  write_state_kv "XHTTP_XPADDING_KEY" "${XHTTP_XPADDING_KEY-}"
  write_state_kv "XHTTP_XPADDING_HEADER" "${XHTTP_XPADDING_HEADER-}"
  write_state_kv "XHTTP_XPADDING_PLACEMENT" "${XHTTP_XPADDING_PLACEMENT-}"
  write_state_kv "XHTTP_XPADDING_METHOD" "${XHTTP_XPADDING_METHOD-}"
  write_state_kv "CERT_MODE" "${CERT_MODE-}"
  write_state_kv "CERT_SOURCE_FILE" "${CERT_SOURCE_FILE-}"
  write_state_kv "KEY_SOURCE_FILE" "${KEY_SOURCE_FILE-}"
  # 敏感输入只留间接引用：@路径 原样写回，正文不落草稿（D06）。
  write_state_kv "CERT_SOURCE_PEM" "${CERT_SOURCE_PEM_REF:-${CERT_SOURCE_PEM-}}"
  write_state_kv "KEY_SOURCE_PEM" "${KEY_SOURCE_PEM_REF:-${KEY_SOURCE_PEM-}}"
  write_state_kv "ACME_EMAIL" "${ACME_EMAIL-}"
  write_state_kv "ACME_CA" "${ACME_CA-}"
  write_state_kv "CF_DNS_TOKEN" "${CF_DNS_TOKEN_REF:-${CF_DNS_TOKEN-}}"
  write_state_kv "CF_DNS_ACCOUNT_ID" "${CF_DNS_ACCOUNT_ID-}"
  write_state_kv "CF_DNS_ZONE_ID" "${CF_DNS_ZONE_ID-}"
  write_state_kv "ENABLE_WARP" "${ENABLE_WARP-}"
  write_state_kv "ENABLE_NET_OPT" "${ENABLE_NET_OPT-}"
  write_state_kv "H3_INTENT" "${H3_INTENT:-off}"
  write_state_kv "NET_BBR_KERNEL" "${NET_BBR_KERNEL-}"
  write_state_kv "NGINX_MAIN_MANAGED" "${NGINX_MAIN_MANAGED-}"
  write_state_kv "ROUTE_BLOCK_CN" "${ROUTE_BLOCK_CN-}"
  write_state_kv "WARP_PRIVATE_KEY" "${WARP_PRIVATE_KEY_REF:-${WARP_PRIVATE_KEY-}}"
  write_state_kv "WARP_PROFILE_SOURCE" "${WARP_PROFILE_SOURCE_REF:-${WARP_PROFILE_SOURCE-}}"
  write_state_kv "WARP_ADDRESS_V4" "${WARP_ADDRESS_V4-}"
  write_state_kv "WARP_ADDRESS_V6" "${WARP_ADDRESS_V6-}"
  write_state_kv "WARP_PEER_PUBLIC_KEY" "${WARP_PEER_PUBLIC_KEY-}"
  write_state_kv "WARP_ENDPOINT" "${WARP_ENDPOINT-}"
  write_state_kv "WARP_RESERVED" "${WARP_RESERVED-}"
  write_state_kv "WARP_MTU" "${WARP_MTU-}"
}

# 草稿的键集合 = state 的键 + 草稿自己的元数据/存在性标记。
install_draft_key_allowed() {
  case "${1}" in
    INSTALL_DRAFT_SCHEMA|INSTALL_DRAFT_TASK|INSTALL_DRAFT_SOURCE|INSTALL_DRAFT_UPDATED_AT|SERVER_IP_PRESENCE|SERVER_IP6_PRESENCE|WARP_PROFILE_SOURCE)
      return 0
      ;;
  esac
  state_file_key_allowed "${1}"
}

load_install_draft_file() {
  [[ -f "${INSTALL_DRAFT_FILE}" ]] || return 0
  load_shell_kv_file "${INSTALL_DRAFT_FILE}" install_draft_key_allowed
}

write_install_draft_file() {
  local temporary=""

  # 草稿是失败后保留的重试输入，不随托管 generation 回退，也不能被路径守卫挡住更新。
  mkdir -p "$(dirname "${INSTALL_DRAFT_FILE}")" || return 1
  temporary="$(mktemp "${INSTALL_DRAFT_FILE}.tmp.XXXXXX")" || return 1
  if ! install_draft_file_text > "${temporary}" || ! durable_replace_file "${temporary}" "${INSTALL_DRAFT_FILE}"; then
    rm -f "${temporary}"
    return 1
  fi
  INSTALL_DRAFT_SAVED=1
}

# 「本次动作显式给出的 CLI 值」快照与回填（D03）：草稿和 state 都只提供默认值，
# 不能覆盖本次动作的显式输入。实现方式是把显式值先存起来、来源文件整份加载完再
# 放回去——比逐键判断少一处漏网，两条来源（草稿、state）也共用同一份实现。
install_snapshot_provided_values() {
  local -n names_ref="${1}"
  local -n values_ref="${2}"
  local var_name=""

  names_ref=()
  values_ref=()
  while IFS= read -r var_name; do
    [[ -n "${var_name}" ]] || continue
    names_ref+=("${var_name}")
    values_ref+=("${!var_name-}")
  done < <(install_provided_var_names)
}

install_restore_provided_values() {
  local -n names_ref="${1}"
  local -n values_ref="${2}"
  local index=0

  while [[ "${index}" -lt "${#names_ref[@]}" ]]; do
    printf -v "${names_ref[index]}" '%s' "${values_ref[index]}"
    index=$((index + 1))
  done
}

# 显式恢复：草稿提供默认值，本次动作显式给出的 CLI 值优先（D03）。
apply_install_draft_file() {
  local -a names=()
  local -a values=()

  install_snapshot_provided_values names values
  load_install_draft_file
  install_restore_provided_values names values
}

# 重建/轮换：state 提供默认值，本次动作显式给出的 CLI 值优先（D03/D09）。
# 少了这一步，`install --task rebuild --reality-target …` 会被 state 里的旧值
# 静默覆盖（实测 2026-09-14 测试 VPS：显式 target 与证书模式全部没生效）。
install_load_existing_state_preserving_provided() {
  local -a names=()
  local -a values=()

  install_snapshot_provided_values names values
  load_existing_state
  install_restore_provided_values names values
}

clear_install_draft_file() {
  [[ -e "${INSTALL_DRAFT_FILE}" || -L "${INSTALL_DRAFT_FILE}" ]] || return 0
  rm -f "${INSTALL_DRAFT_FILE}" || return 1
  sync_required_path "$(dirname "${INSTALL_DRAFT_FILE}")"
}

purge_managed_packages() {
  local package_name=""
  local -a packages=()
  local -a kept=()
  local -a unconfirmed=()

  if [[ ! -f "$(takeover_original_record_file)" ]]; then
    # 旧安装没有包归属记录：分不清哪些是用户原本就装的，保守起见一个都不卸。
    while IFS= read -r package_name; do
      [[ -n "${package_name}" ]] || continue
      unconfirmed+=("${package_name}")
    done < <(managed_package_names)
    UNINSTALL_KEPT+=("软件包未卸载（旧安装没有归属记录）：${unconfirmed[*]}")
    UNINSTALL_UNCONFIRMED+=("命令行手动处理：apt-get purge -y ${unconfirmed[*]}")
    return 0
  fi

  while IFS= read -r package_name; do
    [[ -n "${package_name}" ]] || continue
    if package_installed_by_xtun "${package_name}"; then
      packages+=("${package_name}")
    else
      kept+=("${package_name}")
    fi
  done < <(managed_package_names)

  if [[ "${#packages[@]}" -gt 0 ]]; then
    apt-get purge -y "${packages[@]}" >/dev/null 2>&1 || warn "部分软件包卸载失败，请手动检查 apt 输出。"
    apt-get autoremove -y >/dev/null 2>&1 || true
  fi
  [[ "${#kept[@]}" -eq 0 ]] || UNINSTALL_KEPT+=("软件包安装前就存在，已保留：${kept[*]}")
}

install_draft_session_begin() {
  INSTALL_DRAFT_SESSION_ACTIVE="1"
  trap 'install_draft_session_handle_exit "$?"' EXIT
  trap 'install_draft_session_handle_signal 130' INT
  trap 'install_draft_session_handle_signal 143' TERM
}

install_draft_session_disarm() {
  trap - EXIT INT TERM
  INSTALL_DRAFT_SESSION_ACTIVE="0"
  install_mutation_traps
}

# 确认之前不落草稿：没走完的问答不是「已确认的选择」，静默留下它会让下一次
# 动作继承一份用户从没同意过的输入（D06）。
install_draft_session_persist() {
  if [[ "${INSTALL_CONFIRMED:-0}" != "1" && "${INSTALL_DRAFT_SAVED:-0}" != "1" ]]; then
    return 0
  fi

  if ! write_install_draft_file; then
    warn "安装草稿保存失败：${INSTALL_DRAFT_FILE}；已有草稿可能不含最后的选择。"
    return 1
  fi
}

install_draft_reset_session_state() {
  INSTALL_CONFIRMED=0
  INSTALL_DRAFT_SAVED=0
  INSTALL_EXECUTION_STAGE=""
}

install_draft_session_handle_exit() {
  local exit_status="${1:-0}"

  if [[ "${INSTALL_DRAFT_SESSION_ACTIVE:-0}" == "1" && "${exit_status}" -ne 0 ]]; then
    install_draft_session_persist || true
    install_report_failure_context
  fi

  INSTALL_DRAFT_SESSION_ACTIVE="0"
  mutation_exit_handler "${exit_status}"
}

install_draft_session_handle_signal() {
  local exit_status="${1}"

  trap - INT TERM
  if [[ "${INSTALL_DRAFT_SESSION_ACTIVE:-0}" == "1" ]]; then
    install_draft_session_persist || true
    install_report_failure_context
  fi

  # 安装中途被打断时，草稿只管下次重跑；磁盘上的半成品必须按同代边界回退，
  # 否则重跑会踩在「新配置 + 旧 state + 旧二维码」上面（D12）。
  generation_recover_on_interrupt

  install_draft_session_disarm
  release_script_lock
  exit "${exit_status}"
}

install_draft_session_abort() {
  local status=0

  if [[ "${INSTALL_DRAFT_SESSION_ACTIVE:-0}" == "1" ]]; then
    install_draft_session_persist || status=1
    install_report_failure_context
  fi

  install_draft_session_disarm
  return "${status}"
}

install_draft_session_finish() {
  local status=0

  if ! clear_install_draft_file; then
    warn "安装已提交，但安装草稿清理失败：${INSTALL_DRAFT_FILE}；请检查目录权限后显式丢弃草稿。"
    status=1
  fi
  install_draft_session_disarm
  return "${status}"
}
. "${SCRIPT_ROOT}/lib/install/input.sh"
. "${SCRIPT_ROOT}/lib/install/self.sh"
. "${SCRIPT_ROOT}/lib/install/certs.sh"
. "${SCRIPT_ROOT}/lib/install/network.sh"
. "${SCRIPT_ROOT}/lib/install/warp.sh"
