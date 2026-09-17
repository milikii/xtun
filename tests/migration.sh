#!/usr/bin/env bash
# Exact historical generators -> candidate parameter migration, in private sandboxes.
# Core replacement/recovery is tested separately by cases_identity.sh. This suite
# starts the parameter operation after selection of the target core, as the CLI does.
set -Eeuo pipefail
umask 077
trap 'printf "migration failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

MIGRATION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

migration_setup() {
  local workdir="${1}" bundle="${2}"
  export TEST_SANDBOX_ROOT="${workdir}/xtun-test-sandbox.fixture"
  # The old 0.11.14 generator also writes subscriptions; confine those explicitly.
  export XTUN_SUBSCRIPTION_DIR="${workdir}/historical-subscriptions"
  # shellcheck source=tests/common.sh
  . "${MIGRATION_ROOT}/tests/common.sh"
  # shellcheck source=tests/cases_generation.sh
  . "${MIGRATION_ROOT}/tests/cases_generation.sh"
  ROOT_DIR="${bundle}"
  load_functions
  generation_case_setup "${workdir}"
  ensure_managed_permissions() { :; }
  ensure_xray_user() { :; }
  # Historical releases hard-coded the log paths; this changes only fixture paths.
  xray_log_json() {
    jq -cn --arg access "${XRAY_LOG_DIR}/access.log" --arg error "${XRAY_LOG_DIR}/error.log" \
      '{loglevel:"warning",access:$access,error:$error}'
  }
  mkdir -p "${XRAY_LOG_DIR}"
}

migration_identity() {
  local field=""
  for field in REALITY_UUID XHTTP_UUID REALITY_SNI REALITY_TARGET REALITY_SHORT_ID \
    REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY XHTTP_DOMAIN XHTTP_PATH \
    XHTTP_VLESS_ENCRYPTION_ENABLED XHTTP_VLESS_DECRYPTION XHTTP_VLESS_ENCRYPTION \
    XHTTP_ECH_CONFIG_LIST XHTTP_XPADDING_ENABLED XHTTP_XPADDING_KEY; do
    printf '%s=%s\n' "${field}" "${!field:-}"
  done
}

migration_snapshot() {
  python3 - "${XRAY_CONFIG_DIR}" "${OUTPUT_FILE}" "${QR_OUTPUT_DIR}" "${XTUN_SUBSCRIPTION_DIR}" <<'PY'
import hashlib,json,os,stat,sys
from pathlib import Path
result={}
for value in sys.argv[1:]:
    root=Path(value)
    for p in [root]+(sorted(root.rglob('*')) if root.is_dir() else []):
        if not p.exists(): result[str(p)]={'missing':True}; continue
        s=p.lstat(); row={'mode':stat.S_IMODE(s.st_mode),'uid':s.st_uid,'gid':s.st_gid}
        if p.is_file(): row['sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
        elif p.is_symlink(): row['link']=os.readlink(p)
        result[str(p)]=row
print(json.dumps(result,sort_keys=True))
PY
}

migration_historical() {
  local workdir="${1}" bundle="${2}" schema="${3}"
  migration_setup "${workdir}" "${bundle}"
  # shellcheck disable=SC2034
  SERVER_IP=198.51.100.30
  NODE_LABEL_PREFIX=MIGRATION
  REALITY_UUID=11111111-1111-4111-8111-111111111111
  XHTTP_UUID=22222222-2222-4222-8222-222222222222
  REALITY_SNI=www.example.com
  REALITY_TARGET=www.example.com:443
  REALITY_SHORT_ID=0123456789abcdef
  XHTTP_DOMAIN=cdn.example.com
  XHTTP_PATH=/migration-path
  CERT_MODE=self-signed
  ENABLE_WARP=no
  ENABLE_NET_OPT=no
  XHTTP_VLESS_ENCRYPTION_ENABLED=yes
  XHTTP_ECH_CONFIG_LIST=cloudflare-ech.com+https://223.5.5.5/dns-query
  XHTTP_XPADDING_ENABLED=yes
  backup_path() { :; }
  h3_enabled() { return 1; }
  generate_reality_keys_if_needed
  generate_xhttp_vless_encryption_if_needed
  write_xray_config
  write_nginx_config
  "${XRAY_BIN}" run -test -config "${XRAY_CONFIG_FILE}" > "${workdir}/old-config-test.log" 2>&1
  write_state_file
  write_output_file
  # Separate fixture for the observed production combination; not a claim that
  # schema 2 was emitted by this schema-1 historical generator.
  if [[ "${schema}" == 2 && "${STATE_VERSION_CURRENT}" == 1 ]]; then
    sed -i 's/^STATE_VERSION=.*/STATE_VERSION=2/' "${STATE_FILE}"
  fi
  grep -Eq "^STATE_VERSION=['\"]?${schema}['\"]?$" "${STATE_FILE}"
  migration_identity > "${workdir}/identity-before.txt"
  migration_snapshot > "${workdir}/files-before.json"
  printf 'historical_script=%s state=%s core=%s\n' "${SCRIPT_VERSION}" "${schema}" "$("${XRAY_BIN}" version | head -n 1)"
}

migration_candidate() {
  local workdir="${1}" tuning="" identity="" status=0 number="" label="" uri=""
  migration_setup "${workdir}" "${MIGRATION_ROOT}"
  # Only the sandbox's binary symlink changes. No installed binary is modified.
  ln -sfn "${TEST_HOST_XRAY_BIN}" "${XRAY_BIN}"
  GENERATION_TEST_INSTALLED[xray.service]=yes
  GENERATION_TEST_ACTIVE[xray.service]=active
  GENERATION_TEST_ENABLED[xray.service]=enabled
  load_current_install_context
  identity="$(migration_identity)"
  [[ "${identity}" == "$(cat "${workdir}/identity-before.txt")" ]]
  tuning="${CLIENT_TUNING_JSON}"
  [[ "${CLIENT_TUNING_SOURCE}" == preserved-output && "${tuning}" != '{}' ]]
  jq -e '.["3"].uplink.xmux.maxConcurrency == "16-32"' <<< "${tuning}" >/dev/null
  qrencode() {
    jq -e '.inbounds[] | select(.tag=="reality-vision") | .settings.users != null and .settings.clients == null' \
      "${XRAY_CONFIG_FILE}" >/dev/null || return 2
    touch "${workdir}/reached-qr-failure"
    return 1
  }
  start_backup_session
  apply_xray_only_managed_update || status=$?
  [[ "${status}" -eq 1 && -e "${workdir}/reached-qr-failure" ]]
  [[ "${GENERATION_RECOVERY_RESULT}" == restored-verified && ! -e "${PENDING_OP_FILE}" ]]
  [[ "$(migration_snapshot)" == "$(cat "${workdir}/files-before.json")" ]]
  unset -f qrencode
  start_backup_session
  apply_xray_only_managed_update
  [[ ! -e "${PENDING_OP_FILE}" ]]
  [[ "$(migration_identity)" == "${identity}" && "${CLIENT_TUNING_JSON}" == "${tuning}" ]]
  jq -e 'all(.inbounds[] | select(.protocol=="vless"); .settings.users != null and .settings.clients == null)' \
    "${XRAY_CONFIG_FILE}" >/dev/null
  [[ "${SYSTEMCTL_CALLS}" != *'restart nginx'* && "${SYSTEMCTL_CALLS}" != *'restart haproxy'* ]]
  grep -q '^STATE_VERSION=2$' "${STATE_FILE}"
  grep -q '^PARAMETER_REVISION=2$' "${STATE_FILE}"
  while IFS=$'\t' read -r number label uri; do
    [[ "$(zbarimg -q --raw "$(output_node_png_path "${number}" "${label}")" 2>/dev/null)" == "${uri}" ]]
  done < <(node_link_entries)
  printf 'PASS migration: identities/tuning retained; QR failure restored exact files; users/revision 2 and decoded PNGs committed\n'
}

migration_main() {
  local evidence="${1:-}" temporary=no old_core="${TEST_OLD_XRAY_BIN:-}" old_assets="${TEST_OLD_XRAY_ASSET_DIR:-}"
  local name="" bundle_commit="" schema="" source_core="" source_assets="" arch=""
  local target_core="${TEST_HOST_XRAY_BIN:-/usr/local/bin/xray}" target_assets="${TEST_HOST_XRAY_ASSET_DIR:-/usr/local/share/xray}"
  [[ "${EUID}" -eq 0 ]] || { printf 'Run with sudo; all managed paths remain sandboxed.\n' >&2; return 2; }
  if [[ -z "${evidence}" ]]; then evidence="$(mktemp -d -t xtun-migration.XXXXXX)"; temporary=yes; fi
  mkdir -p "${evidence}"
  evidence="$(cd "${evidence}" && pwd)"
  chmod 0700 "${evidence}"
  if [[ -z "${old_core}" ]]; then
    SCRIPT_ROOT="${MIGRATION_ROOT}"
    # Official archived release uses the same metadata/digest verifier as installs.
    # shellcheck source=lib/base/helpers.sh
    . "${MIGRATION_ROOT}/lib/base/helpers.sh"
    # shellcheck source=lib/base/versions.sh
    . "${MIGRATION_ROOT}/lib/base/versions.sh"
    arch="$(detect_xray_arch)"
    mkdir -p "${evidence}/old-core"
    xray_prepare_release_context v26.3.27 "${arch}"
    xray_download_release "${evidence}/old-core"
    unzip -qo "${evidence}/old-core/${XRAY_SELECTED_ARCHIVE_NAME}" -d "${evidence}/old-core/bin"
    old_core="${evidence}/old-core/bin/xray"
    old_assets="${evidence}/old-core/bin"
    xray_validate_candidate_commands "${old_core}" v26.3.27 "${XRAY_SELECTED_COMMIT}"
  fi
  [[ -x "${old_core}" && -r "${old_assets}/geoip.dat" ]]
  [[ "$("${old_core}" version | head -n 1)" == 'Xray 26.3.27 '* ]]
  for name in 0.11.14-state1 0.11.14-state2 1.1.0-state2; do
    case "${name}" in
      0.11.14-*) bundle_commit=b6eb98b49d01c9b524aa0a679cc951d5b72c9db7; source_core="${old_core}"; source_assets="${old_assets}" ;;
      *) bundle_commit=434075910feb1ce6c93873be7a550a5a7591230e; source_core="${target_core}"; source_assets="${target_assets}" ;;
    esac
    schema="${name##*state}"
    mkdir -p "${evidence}/${name}/bundle" "${evidence}/${name}/work"
    git -C "${MIGRATION_ROOT}" archive "${bundle_commit}" xtun.sh lib static | tar -x -C "${evidence}/${name}/bundle"
    printf 'CASE %s bundle_commit=%s\n' "${name}" "${bundle_commit}"
    TEST_HOST_XRAY_BIN="${source_core}" TEST_HOST_XRAY_ASSET_DIR="${source_assets}" \
      bash "${BASH_SOURCE[0]}" historical "${evidence}/${name}/work" "${evidence}/${name}/bundle" "${schema}"
    TEST_HOST_XRAY_BIN="${target_core}" TEST_HOST_XRAY_ASSET_DIR="${target_assets}" \
      bash "${BASH_SOURCE[0]}" candidate "${evidence}/${name}/work"
  done
  if [[ "${temporary}" == yes ]]; then rm -rf "${evidence}"; fi
}

case "${1:-}" in
  historical) shift; migration_historical "$@" ;;
  candidate) shift; migration_candidate "$@" ;;
  *) migration_main "$@" ;;
esac
