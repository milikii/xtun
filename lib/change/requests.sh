# shellcheck shell=bash

# ------------------------------
# 变更请求层
# 负责请求模型、规格解析与覆盖应用
# ------------------------------

request_value_presence_key() {
  printf '%s__set' "${1}"
}

apply_optional_override() {
  local var_name="${1}"
  local value="${2-}"
  local overridden="${3:-0}"

  if [[ "${overridden}" != "1" && -z "${value}" ]]; then
    return 0
  fi
  printf -v "${var_name}" '%s' "${value}"
}

resolve_change_value() {
  local var_name="${1}"
  local prompt_text="${2}"
  local default_value="${3}"
  local overridden="${4}"
  local explicit_value="${5:-}"

  if [[ "${overridden}" -eq 1 ]]; then
    printf -v "${var_name}" '%s' "${explicit_value}"
    return
  fi

  printf -v "${var_name}" '%s' ""
  prompt_with_default "${var_name}" "${prompt_text}" "${default_value}"
}

resolve_cert_mode_change_targets() {
  local old_cert_mode="${1}"
  local old_xhttp_domain="${2}"
  local cert_mode_overridden="${3}"
  local xhttp_domain_overridden="${4}"
  local new_cert_mode="${5:-}"
  local new_xhttp_domain="${6:-}"

  if [[ "${cert_mode_overridden}" -eq 1 ]]; then
    CERT_MODE="${new_cert_mode}"
    CERT_MODE="$(validate_cert_mode_value "${CERT_MODE}")"
  else
    CERT_MODE=""
    prompt_cert_mode_selection "新的证书模式序号" "${old_cert_mode}"
  fi
  resolve_change_value XHTTP_DOMAIN "XHTTP CDN 域名" "${old_xhttp_domain}" "${xhttp_domain_overridden}" "${new_xhttp_domain}"
}

apply_request_literal_spec() {
  local -n request_ref="${1}"
  local option="${2}"
  local spec="${3}"
  local spec_option=""
  local request_key=""
  local request_value=""

  IFS=':' read -r spec_option request_key request_value <<< "${spec}"
  [[ "${option}" == "${spec_option}" ]] || return 1
  request_ref["${request_key}"]="${request_value}"
  return 0
}

apply_request_value_spec() {
  local -n request_ref="${1}"
  local option="${2}"
  local spec="${3}"
  local spec_option=""
  local request_key=""
  local override_key=""

  shift 3
  IFS=':' read -r spec_option request_key override_key <<< "${spec}"
  [[ "${option}" == "${spec_option}" ]] || return 1
  require_option_value "${option}" "$@"
  enforce_indirect_option_value "${option}" "${1}"
  request_ref["${request_key}"]="${1}"
  if [[ -z "${override_key}" ]]; then
    override_key="$(request_value_presence_key "${request_key}")"
  fi
  request_ref["${override_key}"]="1"
  return 0
}

parse_request_args_by_specs() {
  local request_name="${1}"
  local -n request_ref="${request_name}"
  local -n literal_specs_ref="${2}"
  local -n value_specs_ref="${3}"
  local unknown_arg_message="${4}"
  local consumed=0
  local spec=""

  shift 4
  while [[ $# -gt 0 ]]; do
    if handle_change_common_arg "${1}"; then
      shift
      continue
    fi

    consumed=0
    for spec in "${literal_specs_ref[@]}"; do
      if apply_request_literal_spec "${request_name}" "${1}" "${spec}"; then
        consumed=1
        break
      fi
    done

    if [[ "${consumed}" -eq 0 ]]; then
      for spec in "${value_specs_ref[@]}"; do
        if apply_request_value_spec "${request_name}" "${1}" "${spec}" "${@:2}"; then
          consumed=2
          break
        fi
      done
    fi

    [[ "${consumed}" -gt 0 ]] || die "${unknown_arg_message}${1}"
    shift "${consumed}"
  done
}

apply_request_overrides() {
  local -n request_ref="${1}"
  local spec=""
  local request_key=""
  local target_var=""
  local override_key=""

  shift
  for spec in "$@"; do
    IFS=':' read -r request_key target_var override_key <<< "${spec}"
    if [[ -z "${override_key}" ]]; then
      override_key="$(request_value_presence_key "${request_key}")"
    fi
    apply_optional_override "${target_var}" "${request_ref[${request_key}]-}" "${request_ref[${override_key}]-0}"
  done
}

init_change_warp_request() {
  local -n request_ref="${1}"

  request_ref=(
    [target_mode]=""
    [warp_private_key]=""
    [warp_profile_source]=""
    [warp_address_v4]=""
    [warp_address_v6]=""
    [warp_peer_public_key]=""
    [warp_endpoint]=""
    [warp_reserved]=""
    [warp_mtu]=""
  )
}

parse_change_warp_args() {
  local request_name="${1}"
  local literal_specs=(
    "--enable-warp:target_mode:enable"
    "--disable-warp:target_mode:disable"
  )
  local value_specs=(
    "--warp-private-key:warp_private_key"
    "--warp-profile:warp_profile_source"
    "--warp-address-v4:warp_address_v4"
    "--warp-address-v6:warp_address_v6"
    "--warp-peer-public-key:warp_peer_public_key"
    "--warp-endpoint:warp_endpoint"
    "--warp-reserved:warp_reserved"
    "--warp-mtu:warp_mtu"
  )

  parse_request_args_by_specs "${request_name}" literal_specs value_specs "未知的 change-warp 参数：" "${@:2}"
}

apply_warp_change_request() {
  local request_name="${1}"

  apply_request_overrides "${request_name}" \
    "warp_private_key:WARP_PRIVATE_KEY" \
    "warp_profile_source:WARP_PROFILE_SOURCE" \
    "warp_address_v4:WARP_ADDRESS_V4" \
    "warp_address_v6:WARP_ADDRESS_V6" \
    "warp_peer_public_key:WARP_PEER_PUBLIC_KEY" \
    "warp_endpoint:WARP_ENDPOINT" \
    "warp_reserved:WARP_RESERVED" \
    "warp_mtu:WARP_MTU"
}

init_change_uuid_request() {
  local -n request_ref="${1}"

  request_ref=(
    [rotate_reality]="1"
    [rotate_xhttp]="1"
    [reality_uuid]=""
    [xhttp_uuid]=""
  )
}

parse_change_uuid_args() {
  local request_name="${1}"
  local literal_specs=(
    "--reality-only:rotate_xhttp:0"
    "--xhttp-only:rotate_reality:0"
  )
  local value_specs=(
    "--reality-uuid:reality_uuid"
    "--xhttp-uuid:xhttp_uuid"
  )

  parse_request_args_by_specs "${request_name}" literal_specs value_specs "未知的 change-uuid 参数：" "${@:2}"
}

resolve_change_warp_target_mode() {
  local requested_mode="${1:-}"

  if [[ -z "${requested_mode}" ]]; then
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      die "change-warp 在非交互模式下必须显式传入 --enable-warp 或 --disable-warp。"
    fi

    read -r -p "请选择 WARP 操作 [enable/disable] [${ENABLE_WARP:-yes}]: " requested_mode
    requested_mode="${requested_mode:-${ENABLE_WARP:-yes}}"
  fi

  normalize_warp_target_mode "${requested_mode}"
}

init_change_cert_mode_request() {
  local -n request_ref="${1}"

  request_ref=(
    [cert_mode_overridden]="0"
    [xhttp_domain_overridden]="0"
    [cert_mode]=""
    [xhttp_domain]=""
    [cert_source_file]=""
    [key_source_file]=""
    [cert_source_pem]=""
    [key_source_pem]=""
    [cf_zone_id]=""
    [cf_api_token]=""
    [cf_cert_validity]=""
    [acme_email]=""
    [acme_ca]=""
    [cf_dns_token]=""
    [cf_dns_account_id]=""
    [cf_dns_zone_id]=""
  )
}

parse_change_cert_mode_args() {
  local request_name="${1}"
  local literal_specs=()
  local value_specs=(
    "--cert-mode:cert_mode:cert_mode_overridden"
    "--xhttp-domain:xhttp_domain:xhttp_domain_overridden"
    "--cert-file:cert_source_file"
    "--key-file:key_source_file"
    "--cert-pem:cert_source_pem"
    "--key-pem:key_source_pem"
    "--cf-zone-id:cf_zone_id"
    "--cf-api-token:cf_api_token"
    "--cf-cert-validity:cf_cert_validity"
    "--acme-email:acme_email"
    "--acme-ca:acme_ca"
    "--cf-dns-token:cf_dns_token"
    "--cf-dns-account-id:cf_dns_account_id"
    "--cf-dns-zone-id:cf_dns_zone_id"
  )

  parse_request_args_by_specs "${request_name}" literal_specs value_specs "未知的 change-cert-mode 参数：" "${@:2}"
}

apply_cert_mode_change_request() {
  local request_name="${1}"
  local -n request_ref="${request_name}"
  local old_cert_mode="${2}"
  local old_xhttp_domain="${3}"

  resolve_cert_mode_change_targets \
    "${old_cert_mode}" \
    "${old_xhttp_domain}" \
    "${request_ref[cert_mode_overridden]}" \
    "${request_ref[xhttp_domain_overridden]}" \
    "${request_ref[cert_mode]}" \
    "${request_ref[xhttp_domain]}"
  apply_request_overrides "${request_name}" \
    "cert_source_file:CERT_SOURCE_FILE" \
    "key_source_file:KEY_SOURCE_FILE" \
    "cert_source_pem:CERT_SOURCE_PEM" \
    "key_source_pem:KEY_SOURCE_PEM" \
    "cf_zone_id:CF_ZONE_ID" \
    "cf_api_token:CF_API_TOKEN" \
    "cf_cert_validity:CF_CERT_VALIDITY" \
    "acme_email:ACME_EMAIL" \
    "acme_ca:ACME_CA" \
    "cf_dns_token:CF_DNS_TOKEN" \
    "cf_dns_account_id:CF_DNS_ACCOUNT_ID" \
    "cf_dns_zone_id:CF_DNS_ZONE_ID"
}
