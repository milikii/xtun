# shellcheck shell=bash

# 节点的唯一连接定义。URI、PNG、原生 JSON 都消费同一对象；服务端秘密不进入对象。
node_objects_current() {
  if [[ -n "${NODE_SNAPSHOT_JSON:-}" ]]; then
    printf '%s' "${NODE_SNAPSHOT_JSON}"
    return 0
  fi
  build_node_objects || return 1
}

build_node_objects() {
  local h3=false tuning="${CLIENT_TUNING_JSON:-}" flow=""
  [[ -n "${tuning}" ]] || tuning='{}'
  xhttp_ech_value_valid "${XHTTP_ECH_CONFIG_LIST:-}" || { warn "ECH 配置格式无效，未生成节点。"; return 1; }
  if [[ "${XHTTP_VLESS_ENCRYPTION_ENABLED:-no}" == yes && -z "${XHTTP_VLESS_ENCRYPTION:-}" ]]; then
    warn "缺少配对客户端 Encryption，未生成不完整节点；请恢复 state 或旧节点文档。"; return 1
  fi
  client_tuning_valid "${tuning}" || { warn "客户端参数记录无效，未生成节点。"; return 1; }
  flow="$(config_user_template reality-vision | jq -r '.flow // "xtls-rprx-vision"')" || return 1
  if h3_enabled; then h3=true; fi
  jq -cn --arg ip "${SERVER_IP}" --arg ip6 "${SERVER_IP6:-}" --arg cdn "${XHTTP_DOMAIN}" \
    --arg path "${XHTTP_PATH}" --arg sni "${REALITY_SNI}" --arg password "${REALITY_PUBLIC_KEY}" \
    --arg sid "${REALITY_SHORT_ID}" --arg fingerprint "$(effective_fingerprint)" \
    --arg real_id "${REALITY_UUID}" --arg xhttp_id "${XHTTP_UUID}" --arg flow "${flow}" \
    --arg encryption "$(if [[ "${XHTTP_VLESS_ENCRYPTION_ENABLED}" == yes ]]; then printf '%s' "${XHTTP_VLESS_ENCRYPTION}"; else printf none; fi)" \
    --arg ech "${XHTTP_ECH_CONFIG_LIST:-}" --arg alpn "$(effective_tls_alpn)" \
    --arg prefix "$(normalize_node_label_prefix "${NODE_LABEL_PREFIX}")" --argjson h3 "${h3}" \
    --arg padding "${XHTTP_XPADDING_ENABLED:-no}" --arg pkey "${XHTTP_XPADDING_KEY:-${DEFAULT_XHTTP_XPADDING_KEY}}" \
    --arg pheader "${XHTTP_XPADDING_HEADER:-${DEFAULT_XHTTP_XPADDING_HEADER}}" \
    --arg pplacement "${XHTTP_XPADDING_PLACEMENT:-${DEFAULT_XHTTP_XPADDING_PLACEMENT}}" \
    --arg pmethod "${XHTTP_XPADDING_METHOD:-${DEFAULT_XHTTP_XPADDING_METHOD}}" --argjson tuning "${tuning}" '
    def reality: {serverName:$sni,password:$password,shortId:$sid,fingerprint:$fingerprint};
    def tls($protocol;$cdn_layer): {serverName:$cdn,alpn:[$protocol],fingerprint:$fingerprint}
      + if $cdn_layer and $ech != "" then {echConfigList:$ech} else {} end;
    def padding: if $padding == "yes" then {xPaddingObfsMode:true,xPaddingKey:$pkey,
      xPaddingHeader:$pheader,xPaddingPlacement:$pplacement,xPaddingMethod:$pmethod} else {} end;
    def xhttp($n;$direction;$host): {host:$host,path:$path,mode:"auto"}
      + ($tuning[($n|tostring)][$direction] // {}) + padding;
    def stream($n;$direction;$security;$cdn_layer;$protocol;$raw):
      {network:(if $raw then "raw" else "xhttp" end),security:$security}
      + (if $security == "reality" then {realitySettings:reality} else {tlsSettings:tls($protocol;$cdn_layer)} end)
      + (if $raw then {} else {xhttpSettings:xhttp($n;$direction;if $cdn_layer or $security == "tls" then $cdn else "" end)} end);
    [
      {n:1,name:"REALITY",address:$ip,security:"reality",raw:true},
      {n:2,name:"XHTTP-REALITY",address:$ip,security:"reality"},
      {n:3,name:"XHTTP-CDN",address:$cdn,security:"tls",cdn:true},
      {n:4,name:"XHTTP-SPLIT-CDN-REALITY",address:$cdn,security:"tls",cdn:true,down:$ip,down_security:"reality"},
      {n:5,name:"XHTTP-SPLIT-REALITY-CDN",address:$ip,security:"reality",down:$cdn,down_security:"tls",down_cdn:true},
      (if $ip6 != "" then
        {n:6,name:"REALITY-V6",address:$ip6,security:"reality",raw:true},
        {n:7,name:"XHTTP-SPLIT-CDN-REALITY-V6",address:$cdn,security:"tls",cdn:true,down:$ip6,down_security:"reality"}
        else empty end),
      (if $h3 then
        {n:8,name:"XHTTP-TLS-H3",address:$ip,security:"tls",h3:true},
        {n:9,name:"XHTTP-SPLIT-CDN-H3",address:$cdn,security:"tls",cdn:true,down:$ip,down_security:"tls",down_h3:true}
        else empty end)
    ] | map(. as $d | {
      number:$d.n,label:($prefix+"-"+$d.name),variant:"current",
      cdn_layer:(if $d.cdn then "uplink" elif $d.down_cdn then "downlink" else "" end),
      outbound:{tag:"proxy",protocol:"vless",settings:{vnext:[{address:$d.address,port:443,
        users:[(if $d.raw then {id:$real_id,encryption:"none"} + (if $flow != "" then {flow:$flow} else {} end)
                else {id:$xhttp_id,encryption:$encryption} end)]}]},
        streamSettings:(stream($d.n;"uplink";$d.security;$d.cdn; if $d.h3 then "h3" else $alpn end;$d.raw)
          | if $d.down then .xhttpSettings.downloadSettings =
            ({address:$d.down,port:443} + stream($d.n;"downlink";$d.down_security;$d.down_cdn;
              if $d.down_h3 then "h3" else $alpn end;false)) else . end)
      }
    })'
}

node_object_variant() {
  local node="${1}" variant="${2:-current}" ech="${3:-${XHTTP_ECH_CONFIG_LIST:-https://dns.alidns.com/dns-query}}"
  case "${variant}" in current|plain|ech) ;; *) return 1 ;; esac
  if [[ "${variant}" == ech ]] && ! xhttp_ech_value_valid "${ech}"; then
    warn "ECH 配置格式无效，未导出。"; return 1
  fi
  if [[ "${variant}" == ech ]] && ! jq -e '.cdn_layer != ""' <<< "${node}" >/dev/null; then
    warn "节点没有 CDN TLS 层，不能导出 ECH 变体。"; return 1
  fi
  jq -c --arg variant "${variant}" --arg ech "${ech}" '
    if $variant == "current" then . else
      .variant = $variant | .label += ("-"+($variant|ascii_upcase)) |
      del(.outbound.streamSettings.tlsSettings.echConfigList,
          .outbound.streamSettings.xhttpSettings.downloadSettings.tlsSettings.echConfigList) |
      if $variant == "ech" then
        if .cdn_layer == "uplink" then .outbound.streamSettings.tlsSettings.echConfigList = $ech
        else .outbound.streamSettings.xhttpSettings.downloadSettings.tlsSettings.echConfigList = $ech end
      else . end
    end' <<< "${node}"
}

node_object_uri() {
  jq -er '
    . as $n | .outbound as $o | $o.settings.vnext[0] as $v | $v.users[0] as $u |
    $o.streamSettings as $s | ($s.xhttpSettings // {}) as $x |
    ($s.realitySettings // $s.tlsSettings) as $t |
    ({encryption:$u.encryption,security:$s.security,sni:$t.serverName,fp:$t.fingerprint,fingerprint:$t.fingerprint}
      + (if $s.security == "reality" then {pbk:$t.password,sid:$t.shortId} else {alpn:($t.alpn|join(",")),insecure:"0",allowInsecure:"0"} end)
      + (if $u.flow then {flow:$u.flow} else {} end)
      + (if $s.network == "raw" then {type:"tcp",headerType:"none"} else
          {type:"xhttp",mode:$x.mode,path:$x.path}
          + (if $x.host != "" then {host:$x.host} else {} end)
          + (($x|del(.host,.path,.mode)) as $extra | if $extra == {} then {} else {extra:($extra|tojson)} end) end)
      + (if $t.echConfigList then {ech:$t.echConfigList} else {} end)) |
    to_entries | map(.key+"="+(.value|tostring|@uri)) | join("&") as $query |
    "vless://"+$u.id+"@"+(if $v.address|contains(":") then "["+$v.address+"]" else $v.address end)
      +":"+($v.port|tostring)+"?"+$query+"#"+$n.label'
}

node_object_client_json() {
  jq -e '{log:{loglevel:"warning"},inbounds:[{tag:"socks",listen:"127.0.0.1",port:10808,
    protocol:"socks",settings:{udp:true}}],outbounds:[.outbound,{tag:"direct",protocol:"freedom"},{tag:"block",protocol:"blackhole"}]}'
}

uri_component_decode() {
  local value="${1}" result="" char="" hex=""
  while [[ -n "${value}" ]]; do
    char="${value:0:1}"
    if [[ "${char}" == % ]]; then
      hex="${value:1:2}"
      [[ "${hex}" =~ ^[0-9A-Fa-f]{2}$ && "${hex}" != 00 ]] || return 1
      printf -v char '%b' "\\x${hex}"
      value="${value:3}"
    else value="${value:1}"; fi
    result+="${char}"
  done
  printf '%s' "${result}"
}

node_uri_query_value() {
  local uri="${1}" key="${2}" query="" part=""
  query="${uri#*\?}"; query="${query%%#*}"
  local -a fields=()
  IFS='&' read -r -a fields <<< "${query}"
  for part in "${fields[@]}"; do
    if [[ "${part%%=*}" == "${key}" ]]; then uri_component_decode "${part#*=}"; return $?; fi
  done
}

client_tuning_valid() {
  jq -e '
    def integer: type == "number" and floor == .;
    def range: if type == "number" then integer and . >= -2147483648 and . <= 2147483647
      elif type == "string" then test("^(-?[0-9]+(-[-]?[0-9]+)?)?$") else false end;
    def xmux: type == "object" and all(to_entries[]; .key as $key |
      if .key == "hKeepAlivePeriod" then .value | integer
      elif (["maxConcurrency","maxConnections","cMaxReuseTimes","hMaxRequestTimes","hMaxReusableSecs"] | index($key)) then .value | range
      else false end);
    def direction: type == "object" and all(to_entries[];
      if .key == "xmux" then .value | xmux
      elif .key == "scMinPostsIntervalMs" then .value | range else false end);
    type == "object" and all(to_entries[];
      (.key | test("^[2345789]$")) and (.value | type == "object" and all(to_entries[];
        (.key == "uplink" or .key == "downlink") and (.value | direction))))
  ' <<< "${1}" >/dev/null 2>&1
}

load_client_tuning_context() {
  local number="" label="" uri="" extra="" item="" tuning='{}'
  if [[ -n "${CLIENT_TUNING_JSON:-}" ]]; then
    client_tuning_valid "${CLIENT_TUNING_JSON}" || {
      warn "客户端参数记录格式无效，未采用新默认覆盖。"; return 1;
    }
    return 0
  fi
  if [[ -f "${OUTPUT_FILE}" ]]; then
    while IFS=$'\t' read -r number label uri; do
      [[ "${number}" =~ ^[1-9]$ ]] || continue
      extra="$(node_uri_query_value "${uri}" extra)" || return 1
      [[ -n "${extra}" ]] || continue
      item="$(jq -ce 'def tuning: with_entries(select(.key == "xmux" or .key == "scMinPostsIntervalMs"));
        {uplink:tuning,downlink:((.downloadSettings.xhttpSettings // {}) | (.extra // .) | tuning)}' <<< "${extra}")" || return 1
      tuning="$(jq -cn --argjson old "${tuning}" --arg key "${number}" --argjson item "${item}" '$old+{($key):$item}')" || return 1
    done < <(output_node_link_entries)
    CLIENT_TUNING_SOURCE=preserved-output
  elif [[ -f "${XRAY_CONFIG_FILE}" && "${PARAMETER_REVISION:-}" != "${PARAMETER_REVISION_CURRENT}" ]]; then
    # 旧文档丢失时无法证明用户采用核心新默认；保留旧生成器的兼容参数并说明来源不明。
    tuning='{"xmux":{"maxConcurrency":"16-32","cMaxReuseTimes":0,"hMaxReusableSecs":"1800-3000","hKeepAlivePeriod":0}}'
    tuning="$(jq -cn --argjson old "${tuning}" '[2,3,4,5,7,8,9] | map({key:tostring,value:{uplink:$old,downlink:$old}}) | from_entries')" || return 1
    CLIENT_TUNING_SOURCE=legacy-unverified
    warn "缺少旧客户端参数清单，保留兼容 xmux；来源未核验，不自动采用新默认。"
  else CLIENT_TUNING_SOURCE=core-default; fi
  client_tuning_valid "${tuning}" || { warn "旧客户端参数不能安全识别，未自动替换。"; return 1; }
  CLIENT_TUNING_JSON="${tuning}"
}

node_png_valid() {
  [[ "$(od -An -tx1 -N8 "${1}" | tr -d ' \n')" == 89504e470d0a1a0a ]]
}

write_node_artifact_manifest() {
  local directory="${1}" objects="" rows='[]' file="" name="" digest="" state_digest="" output_digest="" config_digest=""
  objects="$(node_objects_current)" || return 1
  if [[ -f "${STATE_FILE}" ]]; then state_digest="$(identity_file_sha256 "${STATE_FILE}")" || return 1; fi
  if [[ -f "${OUTPUT_FILE}" ]]; then output_digest="$(identity_file_sha256 "${OUTPUT_FILE}")" || return 1; fi
  if [[ -f "${XRAY_CONFIG_FILE}" ]]; then config_digest="$(identity_file_sha256 "${XRAY_CONFIG_FILE}")" || return 1; fi
  for file in "${directory}"/*.png; do
    [[ -f "${file}" ]] || return 1
    name="${file##*/}"
    digest="$(identity_file_sha256 "${file}")" || return 1
    rows="$(jq -cn --argjson rows "${rows}" --arg name "${name}" --arg sha "${digest}" '$rows+[{name:$name,sha256:$sha}]')" || return 1
  done
  jq -n --arg revision "${PARAMETER_REVISION_CURRENT}" --arg state "${state_digest}" --arg output "${output_digest}" \
    --arg config "${config_digest}" \
    --argjson nodes "${objects}" --argjson pngs "${rows}" \
    '{schema:1,parameter_revision:$revision,state_sha256:$state,output_sha256:$output,config_sha256:$config,nodes:$nodes,pngs:$pngs}' \
    > "${directory}/manifest.json" || return 1
  chmod 0600 "${directory}/manifest.json" || return 1
}

load_export_node_objects() {
  local manifest="${QR_OUTPUT_DIR}/manifest.json" state_digest="" output_digest="" config_digest=""
  # state 与生效配置冲突时，不导出一份看似可用但认证身份错误的文件。
  [[ "$(config_user_template reality-vision | jq -r '.id // empty')" == "${REALITY_UUID}" ]] || {
    warn "REALITY 的 state 与配置身份不一致，请先诊断或恢复。"; return 1;
  }
  [[ "$(config_user_template xhttp-cdn | jq -r '.id // empty')" == "${XHTTP_UUID}" ]] || {
    warn "XHTTP 的 state 与配置身份不一致，请先诊断或恢复。"; return 1;
  }
  if [[ -f "${manifest}" && ! -L "${manifest}" ]]; then
    state_digest="$(identity_file_sha256 "${STATE_FILE}")" || return 1
    output_digest="$(identity_file_sha256 "${OUTPUT_FILE}")" || return 1
    config_digest="$(identity_file_sha256 "${XRAY_CONFIG_FILE}")" || return 1
    if ! jq -e --arg state "${state_digest}" --arg output "${output_digest}" --arg config "${config_digest}" \
      '.schema == 1 and .state_sha256 == $state and .output_sha256 == $output and .config_sha256 == $config and (.nodes|type == "array")' \
      "${manifest}" >/dev/null; then
      warn "节点清单与当前 state/文档不属于同一代，未导出；请检查最近的恢复结果。"; return 1
    fi
    jq -c '.nodes' "${manifest}"
    return
  fi
  # 旧安装没有节点对象清单：从已核对的当前状态重建，不把新文件冒充旧生成器产物。
  build_node_objects || return 1
}

export_target_allowed() {
  local target="${1}" protected="" canonical=""
  [[ ! -L "${target}" && ! -d "${target}" ]] || return 1
  [[ ! -e "${target}" || -f "${target}" ]] || return 1
  canonical="$(readlink -m -- "${target}")" || return 1
  for protected in "${SELF_INSTALL_DIR}" "${SELF_COMMAND_PATH}" "${XRAY_BIN}" "${XRAY_CONFIG_DIR}" \
    "${XRAY_ASSET_DIR}" "${XRAY_SERVICE_FILE}" "${XRAY_LOG_DIR}" "${STATE_FILE}" \
    "${SSL_DIR}" "${HAPROXY_CONFIG}" "${NGINX_MAIN_CONFIG}" "${NGINX_CONF_DIR}" \
    "${OUTPUT_FILE}" "${QR_OUTPUT_DIR}" "${BACKUP_ROOT}" "${ORIGINALS_ROOT}" "${PENDING_OP_FILE}"; do
    protected="$(readlink -m -- "${protected}")" || return 1
    [[ "${canonical}" != "${protected}" && "${canonical}" != "${protected}/"* ]] || return 1
  done
}

export_client_cmd() {
  local number="" variant=current format="" output="" ech="" overwrite=0
  local objects="" node="" uri="" parent="" temporary=""
  local -A seen=()
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --node|--node=*|--variant|--variant=*|--format|--format=*|--output|--output=*|--ech-config-list|--ech-config-list=*)
        local option="${1%%=*}"
        option_take_value "${option}" "${1}" "${@:2}"
        [[ ! -v 'seen[${option}]' || "${seen[${option}]}" == "${OPTION_VALUE}" ]] || die "${option} 的重复参数冲突。"
        seen[${option}]="${OPTION_VALUE}"
        case "${option}" in
          --node) number="${OPTION_VALUE}" ;; --variant) variant="${OPTION_VALUE}" ;;
          --format) format="${OPTION_VALUE}" ;; --output) output="${OPTION_VALUE}" ;;
          --ech-config-list) ech="${OPTION_VALUE}" ;;
        esac
        shift "${OPTION_ARGS_CONSUMED}" ;;
      --overwrite) overwrite=1; shift ;;
      --help|-h|help) usage; return 0 ;;
      *) die "未知的 export-client 参数：${1}" ;;
    esac
  done
  [[ "${number}" =~ ^[1-9]$ && -n "${output}" ]] || die "export-client 需要 --node 1..9、--format 和 --output。"
  case "${variant}" in current|plain|ech) ;; *) die "无效的客户端变体：${variant}" ;; esac
  case "${format}" in uri|json|png) ;; *) die "无效的导出格式：${format}" ;; esac
  [[ -z "${ech}" || "${variant}" == ech ]] || die "--ech-config-list 只用于 ech 变体。"
  [[ "${ech}" != *$'\n'* && "${ech}" != *$'\r'* ]] || die "ECH 配置不能包含换行。"
  need_root
  export_target_allowed "${output}" || die "导出目标不能覆盖托管文件、目录或符号链接；二维码重建请用 xtun rebuild-qr。"
  [[ ! -e "${output}" || "${overwrite}" -eq 1 ]] || die "目标已存在；确认覆盖请加 --overwrite。"
  acquire_script_lock || return 1
  export_target_allowed "${output}" || return 1
  if pending_operation_present; then warn "存在未完成变更，请先运行 xtun recover。"; return 1; fi
  load_current_install_context || return 1
  h3_refresh_decision
  objects="$(load_export_node_objects)" || return 1
  node="$(jq -ce --argjson n "${number}" '.[] | select(.number == $n)' <<< "${objects}")" || {
    warn "节点 ${number} 不存在或未启用。"; return 1;
  }
  # 历史启用过 H3 不能覆盖当前已失效的证书/UDP 条件。
  if [[ "${number}" == 8 || "${number}" == 9 ]] && ! h3_enabled; then
    warn "H3 当前本地条件不满足，未导出。"; return 1
  fi
  node="$(node_object_variant "${node}" "${variant}" "${ech}")" || return 1
  uri="$(node_object_uri <<< "${node}")" || return 1
  parent="$(dirname -- "${output}")"
  if [[ ! -d "${parent}" ]]; then (umask 077; mkdir -p -- "${parent}") || return 1; fi
  temporary="$(mktemp "${parent}/.xtun-export.XXXXXX")" || return 1
  case "${format}" in
    uri) printf '%s\n' "${uri}" > "${temporary}" || { rm -f "${temporary}"; return 1; } ;;
    json)
      if ! node_object_client_json <<< "${node}" > "${temporary}" \
        || ! "${XRAY_BIN}" run -test -format json -config "${temporary}" >/dev/null 2>&1; then
        rm -f "${temporary}"; warn "客户端 JSON 未通过当前核心校验，目标文件保留。"; return 1
      fi ;;
    png)
      if ! have_qrencode || ! qrencode -o "${temporary}" -l L -s 6 -m 2 "${uri}" \
        || ! node_png_valid "${temporary}"; then
        rm -f "${temporary}"; warn "PNG 编码失败，目标文件保留。"; return 1
      fi ;;
  esac
  if ! chmod 0600 "${temporary}" || ! export_target_allowed "${output}"; then
    rm -f "${temporary}"; return 1
  fi
  if [[ "${overwrite}" -eq 1 ]]; then
    durable_replace_file "${temporary}" "${output}" || { rm -f "${temporary}"; return 1; }
  else
    # 同目录 hard link 的创建是原子的；检查以后出现的新文件也不能被覆盖。
    if ! sync_required_path "${temporary}" || ! ln -T -- "${temporary}" "${output}"; then
      rm -f "${temporary}"; warn "导出目标已出现或写入失败，现有文件保留。"; return 1
    fi
    rm -f "${temporary}" || return 1
    sync_required_path "${parent}" || return 1
  fi
  log_success "节点 ${number}（${variant}）已导出为 ${format}：${output}"
}

rebuild_qr_cmd() {
  local NODE_SNAPSHOT_JSON=""
  local published="" rebuilt=""
  parse_command_without_options rebuild-qr "$@"
  need_root
  have_qrencode || { warn "缺少 qrencode，不能重建 PNG。"; return 1; }
  confirm_maintenance_action "重建当前节点二维码" "${QR_OUTPUT_DIR}" \
    "不应用服务配置，不中断连接" "编码失败保留原产物" || return 1
  begin_mutation || return 1
  load_current_install_context || return 1
  h3_refresh_decision
  NODE_SNAPSHOT_JSON="$(load_export_node_objects)" || return 1
  published="$(output_node_link_entries)" || return 1
  rebuilt="$(node_link_entries)" || return 1
  if [[ -z "${published}" || "${published}" != "${rebuilt}" ]]; then
    warn "当前文档与节点定义不一致，未重建二维码。请先检查状态；旧安装需显式 apply-config 完成参数迁移（会重启 Xray），再重建二维码。"
    return 1
  fi
  start_backup_session || return 1
  begin_generation_paths "重建二维码" -- "${QR_OUTPUT_DIR}" || return 1
  if ! write_link_qr_pngs; then generation_failed "二维码重建失败"; return 1; fi
  generation_commit || return 1
  log_success "已重建二维码：${QR_OUTPUT_DIR}"
}
