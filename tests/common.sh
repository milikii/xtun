#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TEST_WARP_PRIVATE_KEY="eHR1bi10ZXN0LXdhcnAtcHJpdmF0ZS1rZXktMzJieXQ="
TEST_WARP_PEER_PUBLIC_KEY="eHR1bi10ZXN0LXdhcnAtcGVlci1wdWJsaWMta2V5LTM="

load_functions() {
  # ------------------------------
  # 只加载函数定义，不执行 main
  # 这样 smoke test 可以直接调用内部生成器
  # ------------------------------
  # shellcheck disable=SC1090
  source <(sed '$d' "${ROOT_DIR}/xtun.sh")
}

prepare_workspace() {
  local workdir="${1}"

  XRAY_CONFIG_DIR="${workdir}/xray"
  XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
  STATE_FILE="${XRAY_CONFIG_DIR}/node-meta.env"
  OUTPUT_FILE="${workdir}/output.md"
  SUBSCRIPTION_DIR="${workdir}/subscriptions"
  SUBSCRIPTION_RAW_FILE="${SUBSCRIPTION_DIR}/vless-raw.txt"
  SUBSCRIPTION_BASE64_FILE="${SUBSCRIPTION_DIR}/vless-base64.txt"
  SUBSCRIPTION_MANIFEST_FILE="${SUBSCRIPTION_DIR}/manifest.txt"
  SUBSCRIPTION_QR_DIR="${SUBSCRIPTION_DIR}/qr"
  SUBSCRIPTION_RAW_QR_FILE="${SUBSCRIPTION_QR_DIR}/vless-raw.png"
  SUBSCRIPTION_BASE64_QR_FILE="${SUBSCRIPTION_QR_DIR}/vless-base64.png"
  mkdir -p "${XRAY_CONFIG_DIR}"
}

reset_feature_defaults() {
  XHTTP_ECH_CONFIG_LIST="${DEFAULT_XHTTP_ECH_CONFIG_LIST}"
  XHTTP_ECH_FORCE_QUERY="${DEFAULT_XHTTP_ECH_FORCE_QUERY}"
  XHTTP_ECH_ENABLED=""
  XHTTP_XPADDING_ENABLED="${DEFAULT_XHTTP_XPADDING_ENABLED}"
  XHTTP_XPADDING_KEY="${DEFAULT_XHTTP_XPADDING_KEY}"
  XHTTP_XPADDING_HEADER="${DEFAULT_XHTTP_XPADDING_HEADER}"
  XHTTP_XPADDING_PLACEMENT="${DEFAULT_XHTTP_XPADDING_PLACEMENT}"
  XHTTP_XPADDING_METHOD="${DEFAULT_XHTTP_XPADDING_METHOD}"
  REALITY_URI=""
  XHTTP_URI=""
  XHTTP_SPLIT_URI=""
  XHTTP_REALITY_URI=""
  XHTTP_REVERSE_SPLIT_URI=""
  NODE_CLIENTS_TEXT=""
  OUTPUT_CLIENT_NAME=""
  LINK_CLIENT_NAME=""
  LINK_REALITY_UUID=""
  LINK_XHTTP_UUID=""
}

stub_side_effects() {
  ensure_managed_permissions() { :; }
  backup_path() { :; }
}

set_test_warp_credentials() {
  WARP_PRIVATE_KEY="${TEST_WARP_PRIVATE_KEY}"
  WARP_ADDRESS_V4="172.16.0.2"
  WARP_ADDRESS_V6="2606:4700:110:8a1b:cafe:1:2:3"
  WARP_PEER_PUBLIC_KEY="${TEST_WARP_PEER_PUBLIC_KEY}"
  WARP_ENDPOINT="${DEFAULT_WARP_ENDPOINT}"
  WARP_RESERVED="3,4,5"
  WARP_MTU="${DEFAULT_WARP_MTU}"
  WARP_PROFILE_SOURCE=""
}

clear_test_warp_credentials() {
  WARP_PRIVATE_KEY=""
  WARP_ADDRESS_V4=""
  WARP_ADDRESS_V6=""
  WARP_PEER_PUBLIC_KEY="${DEFAULT_WARP_PEER_PUBLIC_KEY}"
  WARP_ENDPOINT="${DEFAULT_WARP_ENDPOINT}"
  WARP_RESERVED=""
  WARP_MTU="${DEFAULT_WARP_MTU}"
  WARP_PROFILE_SOURCE=""
}

capture_function_definition() {
  local fn_name="${1}"

  declare -f "${fn_name}" 2>/dev/null || true
}

restore_function_definition() {
  local definition="${1:-}"

  [[ -n "${definition}" ]] || return 0
  eval "${definition}"
}

assert_contains() {
  local pattern="${1}"
  local path="${2}"

  grep -q -- "${pattern}" "${path}"
}
