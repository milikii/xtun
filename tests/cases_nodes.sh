# shellcheck shell=bash
# shellcheck disable=SC2034

nodes_fixture() {
  local workdir="${1}"
  generation_case_setup "${workdir}"
  reset_feature_defaults
  SERVER_IP=198.51.100.20
  SERVER_IP6=2001:db8::20
  NODE_LABEL_PREFIX=TEST
  REALITY_UUID=11111111-1111-4111-8111-111111111111
  XHTTP_UUID=22222222-2222-4222-8222-222222222222
  REALITY_SNI=www.example.com
  REALITY_TARGET=www.example.com:443
  REALITY_SHORT_ID=0123456789abcdef
  REALITY_PRIVATE_KEY=""
  REALITY_PUBLIC_KEY=""
  XHTTP_DOMAIN=cdn.example.com
  XHTTP_PATH=/test-path
  CERT_MODE=self-signed
  ENABLE_WARP=no
  ENABLE_NET_OPT=no
  NET_BBR_KERNEL=none
  XHTTP_VLESS_ENCRYPTION_ENABLED=yes
  XHTTP_VLESS_DECRYPTION=""
  XHTTP_VLESS_ENCRYPTION=""
  generate_reality_keys_if_needed
  generate_xhttp_vless_encryption_if_needed
  ensure_managed_permissions() { :; }
  mkdir -p "${XRAY_LOG_DIR}"
  write_xray_config
  write_state_file
  write_output_file
}

run_node_object_matrix_case() {
  local workdir="" objects="" node="" number="" variant="" transformed=""
  load_functions
  workdir="$(mktemp -d)"
  nodes_fixture "${workdir}"
  h3_enabled() { return 0; }
  XHTTP_XPADDING_ENABLED=yes
  XHTTP_ECH_CONFIG_LIST=https://dns.alidns.com/dns-query
  objects="$(build_node_objects)"
  jq -e 'length == 9 and (.[6].outbound.settings.vnext[0].address == "cdn.example.com")
    and (.[6].outbound.streamSettings.xhttpSettings.downloadSettings.address == "2001:db8::20")
    and (.[8].outbound.streamSettings.xhttpSettings.downloadSettings.tlsSettings.alpn == ["h3"])
    and all(.[]; if .outbound.streamSettings.network == "xhttp" then
      .outbound.streamSettings.xhttpSettings.xPaddingObfsMode == true else true end)
    and all(.[] | select(.outbound.streamSettings.xhttpSettings.downloadSettings); 
      .outbound.streamSettings.xhttpSettings.downloadSettings.xhttpSettings.xPaddingObfsMode == true)' \
    <<< "${objects}" >/dev/null
  while IFS= read -r node; do
    number="$(jq -r .number <<< "${node}")"
    for variant in current plain ech; do
      if [[ "${variant}" == ech && " 1 2 6 8 " == *" ${number} "* ]]; then
        assert_false node_object_variant "${node}" ech >/dev/null 2>&1
        continue
      fi
      transformed="$(node_object_variant "${node}" "${variant}")"
      node_object_client_json <<< "${transformed}" > "${workdir}/client-${number}-${variant}.json"
      "${XRAY_BIN}" run -test -config "${workdir}/client-${number}-${variant}.json" >/dev/null 2>&1
      node_object_uri <<< "${transformed}" > "${workdir}/uri-${number}-${variant}.txt"
      printf '%s\n' "${transformed}" > "${workdir}/object-${number}-${variant}.json"
      if [[ "${variant}" == plain ]]; then
        jq -e '[.. | objects | select(has("echConfigList"))] | length == 0' <<< "${transformed}" >/dev/null
      elif [[ " 3 4 7 9 " == *" ${number} "* ]]; then
        jq -e '.outbound.streamSettings.tlsSettings.echConfigList != null
          and .outbound.streamSettings.xhttpSettings.downloadSettings.tlsSettings.echConfigList == null' <<< "${transformed}" >/dev/null
      elif [[ "${number}" == 5 ]]; then
        jq -e '.outbound.streamSettings.realitySettings.echConfigList == null
          and .outbound.streamSettings.xhttpSettings.downloadSettings.tlsSettings.echConfigList != null' <<< "${transformed}" >/dev/null
      fi
    done
  done < <(jq -c '.[]' <<< "${objects}")
  python3 - "${workdir}" <<'PY'
from pathlib import Path
from urllib.parse import urlsplit,parse_qs
import json,sys
root=Path(sys.argv[1])
for file in root.glob('object-*.json'):
    node=json.loads(file.read_text());o=node['outbound'];v=o['settings']['vnext'][0];u=v['users'][0];s=o['streamSettings']
    uri=urlsplit((root/file.name.replace('object-','uri-').replace('.json','.txt')).read_text().strip());q=parse_qs(uri.query)
    assert uri.hostname == v['address'] and uri.username == u['id'] and uri.port == v['port']
    assert q['security'][0] == s['security'] and q['encryption'][0] == u['encryption']
    if s['security']=='reality': assert q['pbk'][0] == s['realitySettings']['password']
    if s['network']=='xhttp':
        x=s['xhttpSettings'];assert q['path'][0] == x['path'] and q['mode'][0] == x['mode']
        assert json.loads(q.get('extra',['{}'])[0]) == {k:v for k,v in x.items() if k not in ('host','path','mode')}
    assert not any(secret in json.dumps(node) for secret in ('privateKey','secretKey','decryption','CF_DNS_TOKEN'))
print('node URI/JSON matrix agrees')
PY
  rm -rf "${workdir}"
}

run_vless_users_migration_case() {
  local workdir="" saved="" before=""
  load_functions
  workdir="$(mktemp -d)"
  nodes_fixture "${workdir}"
  jq -e 'all(.inbounds[] | select(.protocol == "vless"); .settings.users != null and .settings.clients == null)' "${XRAY_CONFIG_FILE}" >/dev/null
  saved="$(config_user_template reality-vision)"
  jq '.inbounds |= map(if .tag == "reality-vision" then
    .settings.clients = [.settings.users[0] + {email:"kept@example.test",level:3}] |
    .settings.users[0].id = "33333333-3333-4333-8333-333333333333" else . end)' \
    "${XRAY_CONFIG_FILE}" > "${workdir}/candidate.json"
  mv "${workdir}/candidate.json" "${XRAY_CONFIG_FILE}"
  REALITY_UUID=""
  load_config_runtime_context
  [[ "${REALITY_UUID}" == 11111111-1111-4111-8111-111111111111 ]]
  write_xray_config
  jq -e '.inbounds[] | select(.tag=="reality-vision") |
    .settings.clients == null and .settings.users[0].email == "kept@example.test" and .settings.users[0].level == 3
    and .settings.users[0].flow == "xtls-rprx-vision"' "${XRAY_CONFIG_FILE}" >/dev/null
  "${XRAY_BIN}" run -test -config "${XRAY_CONFIG_FILE}" >/dev/null 2>&1
  jq '.inbounds |= map(if .tag == "reality-vision" then .settings.clients=[] else . end)' \
    "${XRAY_CONFIG_FILE}" > "${workdir}/empty.json"
  mv "${workdir}/empty.json" "${XRAY_CONFIG_FILE}"
  before="$(identity_file_sha256 "${XRAY_CONFIG_FILE}")"
  assert_false load_config_runtime_context >/dev/null 2>&1
  [[ "$(identity_file_sha256 "${XRAY_CONFIG_FILE}")" == "${before}" ]]
  rm -rf "${workdir}"
}

run_client_tuning_preservation_case() {
  local workdir="" objects="" preserved=""
  load_functions
  workdir="$(mktemp -d)"
  nodes_fixture "${workdir}"
  objects="$(build_node_objects)"
  jq -e '[.. | objects | select(has("xmux") or has("scMinPostsIntervalMs"))] | length == 0' <<< "${objects}" >/dev/null
  CLIENT_TUNING_JSON='{"3":{"uplink":{"xmux":{"maxConnections":7,"hMaxRequestTimes":"100-120"}}},"5":{"downlink":{"xmux":{"maxConcurrency":"5-9"}}}}'
  write_output_file
  CLIENT_TUNING_JSON=""
  load_client_tuning_context
  preserved="${CLIENT_TUNING_JSON}"
  [[ "${CLIENT_TUNING_SOURCE}" == preserved-output ]]
  jq -e '.["3"].uplink.xmux.maxConnections == 7 and .["5"].downlink.xmux.maxConcurrency == "5-9"' <<< "${preserved}" >/dev/null
  write_state_file
  CLIENT_TUNING_JSON=""
  load_existing_state
  [[ "${CLIENT_TUNING_JSON}" == "${preserved}" ]]
  objects="$(build_node_objects)"
  jq -e '.[2].outbound.streamSettings.xhttpSettings.xmux.maxConnections == 7
    and .[4].outbound.streamSettings.xhttpSettings.downloadSettings.xhttpSettings.xmux.maxConcurrency == "5-9"' <<< "${objects}" >/dev/null
  rm -rf "${workdir}"
}

run_node_png_decode_case() {
  local workdir="" number="" label="" uri="" decoded=""
  load_functions
  workdir="$(mktemp -d)"
  nodes_fixture "${workdir}"
  while IFS=$'\t' read -r number label uri; do
    decoded="$(zbarimg -q --raw "$(output_node_png_path "${number}" "${label}")" 2>/dev/null)"
    [[ "${decoded}" == "${uri}" ]]
  done < <(node_link_entries)
  jq -e '.schema==1 and (.nodes|length)==7 and (.pngs|length)==7' "${QR_OUTPUT_DIR}/manifest.json" >/dev/null
  rm -rf "${workdir}"
}

run_export_client_independent_case() {
  local workdir="" before="" format="" file="" status=0
  load_functions
  workdir="$(mktemp -d)"
  nodes_fixture "${workdir}"
  before="$(backup_file_digest "${XRAY_CONFIG_DIR}"):$(backup_file_digest "${QR_OUTPUT_DIR}"):$(identity_file_sha256 "${OUTPUT_FILE}")"
  for format in uri json png; do
    run_cli_command export-client --node 3 --variant current --format "${format}" --output "${workdir}/export/current.${format}"
    [[ "$(stat -c %a "${workdir}/export/current.${format}")" == 600 ]]
  done
  [[ "$(zbarimg -q --raw "${workdir}/export/current.png" 2>/dev/null)" == "$(cat "${workdir}/export/current.uri")" ]]
  [[ "$(stat -c %a "${workdir}/export")" == 700 ]]
  run_cli_command export-client --node 5 --variant ech --format json --output "${workdir}/export/ech.json"
  jq -e '.outbounds[0].streamSettings.xhttpSettings.downloadSettings.tlsSettings.echConfigList == "https://dns.alidns.com/dns-query"' "${workdir}/export/ech.json" >/dev/null
  for file in "${STATE_FILE}" "${XRAY_CONFIG_FILE}" "${OUTPUT_FILE}" "${QR_OUTPUT_DIR}/manifest.json"; do
    status=0
    (run_cli_command export-client --node 3 --format uri --output "${file}" --overwrite) >/dev/null 2>&1 || status=$?
    [[ "${status}" -eq 1 ]]
  done
  status=0
  (run_cli_command export-client --node 3 --format json --output "${workdir}/export/current.json") >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 1 ]]
  run_cli_command export-client --node 3 --format json --output "${workdir}/export/current.json" --overwrite
  [[ "$(backup_file_digest "${XRAY_CONFIG_DIR}"):$(backup_file_digest "${QR_OUTPUT_DIR}"):$(identity_file_sha256 "${OUTPUT_FILE}")" == "${before}" ]]
  [[ "${SYSTEMCTL_CALLS}" != *restart* && "${SYSTEMCTL_CALLS}" != *reload* && ! -d "${BACKUP_ROOT}" ]]
  rm -rf "${workdir}"
}

run_export_failure_preserves_target_case() {
  local workdir="" before="" status=0
  load_functions
  workdir="$(mktemp -d)"
  nodes_fixture "${workdir}"
  printf 'old-export\n' > "${workdir}/client.json"
  node_object_client_json() { printf 'invalid-json\n'; }
  run_cli_command export-client --node 3 --format json --output "${workdir}/client.json" --overwrite || status=$?
  [[ "${status}" -eq 1 && "$(cat "${workdir}/client.json")" == old-export ]]
  [[ -z "$(find "${workdir}" -maxdepth 1 -name '.xtun-export.*' -print -quit)" ]]
  status=0
  durable_replace_file() { return 1; }
  run_cli_command export-client --node 3 --format uri --output "${workdir}/client.json" --overwrite || status=$?
  [[ "${status}" -eq 1 && "$(cat "${workdir}/client.json")" == old-export ]]
  rm -rf "${workdir}"
}

run_rebuild_qr_independent_case() {
  local workdir="" before="" uri=""
  load_functions
  workdir="$(mktemp -d)"
  nodes_fixture "${workdir}"
  before="$(backup_file_digest "${XRAY_CONFIG_DIR}"):$(identity_file_sha256 "${OUTPUT_FILE}")"
  rm "${QR_OUTPUT_DIR}/03-TEST-XHTTP-CDN.png"
  run_cli_command rebuild-qr --yes
  uri="$(awk '/^## 节点 3$/ {node=1;next} /^## 节点/ {node=0} node && /^vless:/ {print;exit}' "${OUTPUT_FILE}")"
  [[ "$(zbarimg -q --raw "${QR_OUTPUT_DIR}/03-TEST-XHTTP-CDN.png" 2>/dev/null)" == "${uri}" ]]
  [[ "$(backup_file_digest "${XRAY_CONFIG_DIR}"):$(identity_file_sha256 "${OUTPUT_FILE}")" == "${before}" ]]
  [[ "${SYSTEMCTL_CALLS}" != *restart* && "${SYSTEMCTL_CALLS}" != *reload* && ! -e "${PENDING_OP_FILE}" ]]
  rm -rf "${workdir}"
}

run_parameter_generation_rollback_case() {
  local workdir="" before="" status=0
  load_functions
  workdir="$(mktemp -d)"
  xray_inbound_user_key() { printf clients; }
  nodes_fixture "${workdir}"
  sed -i 's/^STATE_VERSION=.*/STATE_VERSION=1/' "${STATE_FILE}"
  before="$(backup_file_digest "${XRAY_CONFIG_DIR}"):$(backup_file_digest "${QR_OUTPUT_DIR}"):$(identity_file_sha256 "${OUTPUT_FILE}")"
  unset -f xray_inbound_user_key
  eval "$(sed -n '/^xray_inbound_user_key() {/,/^}/p' "${ROOT_DIR}/lib/state.sh")"
  GENERATION_TEST_INSTALLED['xray.service']=yes
  GENERATION_TEST_ACTIVE['xray.service']=active
  GENERATION_TEST_ENABLED['xray.service']=enabled
  qrencode() {
    jq -e '.inbounds[] | select(.tag == "reality-vision") | .settings.users != null' "${XRAY_CONFIG_FILE}" >/dev/null || return 2
    touch "${workdir}/reached-output-stage"
    return 1
  }
  start_backup_session
  apply_xray_only_managed_update || status=$?
  [[ "${status}" -eq 1 && -f "${workdir}/reached-output-stage" ]]
  [[ "${GENERATION_RECOVERY_RESULT}" == restored-verified && ! -e "${PENDING_OP_FILE}" ]]
  [[ "$(backup_file_digest "${XRAY_CONFIG_DIR}"):$(backup_file_digest "${QR_OUTPUT_DIR}"):$(identity_file_sha256 "${OUTPUT_FILE}")" == "${before}" ]]
  release_script_lock
  rm -rf "${workdir}"
}

run_export_argument_boundary_case() {
  local workdir="" before="" mode=""
  load_functions
  workdir="$(mktemp -d)"
  nodes_fixture "${workdir}"
  before="$(backup_file_digest "${XRAY_CONFIG_DIR}"):$(backup_file_digest "${QR_OUTPUT_DIR}"):$(identity_file_sha256 "${OUTPUT_FILE}")"
  # 每次都穿过真实派发器；拒绝输入不得创建导出父目录。
  for mode in missing-node bad-node bad-format bad-variant conflict disabled no-ech missing-value ech-option; do
    (
      case "${mode}" in
        missing-node) run_cli_command export-client --format json --output "${workdir}/new/client.json" ;;
        bad-node) run_cli_command export-client --node 10 --format json --output "${workdir}/new/client.json" ;;
        bad-format) run_cli_command export-client --node 3 --format yaml --output "${workdir}/new/client.json" ;;
        bad-variant) run_cli_command export-client --node 3 --variant typo --format json --output "${workdir}/new/client.json" ;;
        conflict) run_cli_command export-client --node 3 --node=4 --format json --output "${workdir}/new/client.json" ;;
        disabled) run_cli_command export-client --node 8 --format json --output "${workdir}/new/client.json" ;;
        no-ech) run_cli_command export-client --node 1 --variant ech --format json --output "${workdir}/new/client.json" ;;
        missing-value) run_cli_command export-client --node 3 --format json --output ;;
        ech-option) run_cli_command export-client --node 3 --format json --output "${workdir}/new/client.json" --ech-config-list AQEEBQQF ;;
      esac
    ) > "${workdir}/reject.log" 2>&1 && return 1
    [[ ! -e "${workdir}/new" ]]
  done
  (run_cli_command install --xhttp-ech-force-query none) > "${workdir}/reject.log" 2>&1 && return 1
  grep -q '未知' "${workdir}/reject.log"
  [[ "$(backup_file_digest "${XRAY_CONFIG_DIR}"):$(backup_file_digest "${QR_OUTPUT_DIR}"):$(identity_file_sha256 "${OUTPUT_FILE}")" == "${before}" ]]
  [[ "${SYSTEMCTL_CALLS}" != *restart* && "${SYSTEMCTL_CALLS}" != *reload* && ! -d "${BACKUP_ROOT}" ]]
  rm -rf "${workdir}"
}

run_export_concurrent_target_case() {
  local workdir="" status=0
  load_functions
  workdir="$(mktemp -d)"
  nodes_fixture "${workdir}"
  # 在最初的存在性检查以后、发布之前模拟另一个程序创建目标。
  ln() {
    printf 'concurrent-owner\n' > "${workdir}/client.uri"
    command ln "$@"
  }
  run_cli_command export-client --node 3 --format uri --output "${workdir}/client.uri" >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 1 && "$(cat "${workdir}/client.uri")" == concurrent-owner ]]
  [[ -z "$(find "${workdir}" -maxdepth 1 -name '.xtun-export.*' -print -quit)" ]]
  rm -rf "${workdir}"
}

run_ech_and_tuning_validation_case() {
  local workdir="" ech="" value=""
  load_functions
  workdir="$(mktemp -d)"
  nodes_fixture "${workdir}"
  ech="$("${XRAY_BIN}" tls ech -serverName cdn.example.com | sed -n '2p')"
  xhttp_ech_value_valid "${ech}"
  for value in '' https://dns.alidns.com/dns-query cloudflare-ech.com+https://223.5.5.5/dns-query \
    udp://1.1.1.1:53 h2c://127.0.0.1:8053/dns-query; do
    xhttp_ech_value_valid "${value}"
  done
  for value in AQEEBQQF "${ech%?}" '!!!=' 'https://' 'https://user:secret@dns.example/dns-query' \
    'https://dns.example:0/dns-query' 'udp://1.1.1.1:65536' 'https://dns.example/a b' 'file:///etc/passwd'; do
    assert_false xhttp_ech_value_valid "${value}" >/dev/null 2>&1
  done
  # 原生生成的完整配置可导出，截断的 Base64 在创建目标之前失败。
  run_cli_command export-client --node 3 --variant ech --ech-config-list "${ech}" --format json --output "${workdir}/valid.json"
  jq -e --arg ech "${ech}" '.outbounds[0].streamSettings.tlsSettings.echConfigList == $ech' "${workdir}/valid.json" >/dev/null
  (run_cli_command export-client --node 3 --variant ech --ech-config-list "${ech%?}" --format json --output "${workdir}/invalid.json") >/dev/null 2>&1 && return 1
  [[ ! -e "${workdir}/invalid.json" ]]
  for value in '{"3":{"uplink":{"path":"/unexpected"}}}' '{"3":{"uplink":{"xmux":{"maxConnections":true}}}}' \
    '{"3":{"uplink":{"xmux":{"unknown":1}}}}' '{"1":{"uplink":{}}}' '[]'; do
    assert_false client_tuning_valid "${value}"
  done
  XHTTP_VLESS_ENCRYPTION=""
  assert_false build_node_objects >/dev/null 2>&1
  rm -rf "${workdir}"
}

run_rebuild_qr_document_consistency_case() {
  local workdir="" before="" backup_count="" status=0
  load_functions
  workdir="$(mktemp -d)"
  nodes_fixture "${workdir}"
  # 丢失整个目录仍可恢复，前提是当前定义能逐字复现已交付的 URI。
  rm -rf "${QR_OUTPUT_DIR}"
  run_cli_command rebuild-qr --yes
  [[ -f "${QR_OUTPUT_DIR}/manifest.json" ]]
  rm "${QR_OUTPUT_DIR}/manifest.json"
  sed -i 's/fingerprint=chrome/fingerprint=firefox/g' "${OUTPUT_FILE}"
  before="$(backup_file_digest "${QR_OUTPUT_DIR}"):$(identity_file_sha256 "${OUTPUT_FILE}")"
  backup_count="$(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 | wc -l)"
  run_cli_command rebuild-qr --yes >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 1 && "${LOGGED}" == *未重建二维码* ]]
  [[ "$(backup_file_digest "${QR_OUTPUT_DIR}"):$(identity_file_sha256 "${OUTPUT_FILE}")" == "${before}" ]]
  [[ "$(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 | wc -l)" == "${backup_count}" ]]
  [[ "${SYSTEMCTL_CALLS}" != *restart* && "${SYSTEMCTL_CALLS}" != *reload* ]]
  rm -rf "${workdir}"
}
