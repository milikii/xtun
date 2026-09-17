# shellcheck shell=bash

# 安装回执是本机已校验产物的清单，不是上游签名。每次使用均核对当前字节和元数据。
PARAMETER_REVISION_CURRENT="2"

identity_file_sha256() {
  [[ -f "${1}" && ! -L "${1}" ]] || return 1
  sha256sum -- "${1}" | awk '{print $1}'
}

xray_identity_file() { printf '%s/.xtun-core.json' "${XRAY_ASSET_DIR}"; }

xray_binary_capabilities() {
  command -v getcap >/dev/null 2>&1 || return 1
  local result=""
  result="$(getcap "${XRAY_BIN}")" || return 1
  [[ -z "${result}" ]] || result="${result#"${XRAY_BIN} "}"
  printf '%s' "${result}"
}

write_xray_install_identity() {
  local archive="${1}" temporary="" binary="" geoip="" geosite="" caps="" metadata=""
  binary="$(identity_file_sha256 "${XRAY_BIN}")" || return 1
  geoip="$(identity_file_sha256 "${XRAY_ASSET_DIR}/geoip.dat")" || return 1
  geosite="$(identity_file_sha256 "${XRAY_ASSET_DIR}/geosite.dat")" || return 1
  caps="$(xray_binary_capabilities)" || return 1
  metadata="$(stat -c '%a:%u:%g' "${XRAY_BIN}")" || return 1
  temporary="$(mktemp "${XRAY_ASSET_DIR}/.identity.XXXXXX")" || return 1
  if ! jq -n --arg tag "${XRAY_SELECTED_TAG}" --arg commit "${XRAY_SELECTED_COMMIT}" \
    --arg arch "${XRAY_CONTEXT_ARCH}" --arg archive "${XRAY_SELECTED_ARCHIVE_NAME}" \
    --arg url "${XRAY_SELECTED_ARCHIVE_URL}" --arg archive_sha256 "$(identity_file_sha256 "${archive}")" \
    --arg checksum_source "${XRAY_SELECTED_CHECKSUM_SOURCE}" \
    --arg binary "${binary}" --arg geoip "${geoip}" --arg geosite "${geosite}" \
    --arg metadata "${metadata}" --arg capabilities "${caps}" \
    --arg state_schema "${STATE_VERSION_CURRENT}" --arg parameter_revision "${PARAMETER_REVISION_CURRENT}" \
    '{schema:1,tag:$tag,commit:$commit,arch:$arch,archive:$archive,url:$url,
      archive_sha256:$archive_sha256,checksum_source:$checksum_source,
      binary_sha256:$binary,geoip_sha256:$geoip,geosite_sha256:$geosite,
      binary_metadata:$metadata,capabilities:$capabilities,
      state_schema:$state_schema,parameter_revision:$parameter_revision}' > "${temporary}" \
    || ! chmod 0600 "${temporary}" || ! durable_replace_file "${temporary}" "$(xray_identity_file)"; then
    rm -f "${temporary}"; return 1
  fi
}

xray_installed_identity_valid() {
  local record="" binary="" geoip="" geosite="" caps="" metadata=""
  record="$(xray_identity_file)"
  [[ -f "${record}" && ! -L "${record}" ]] || return 1
  binary="$(identity_file_sha256 "${XRAY_BIN}")" || return 1
  geoip="$(identity_file_sha256 "${XRAY_ASSET_DIR}/geoip.dat")" || return 1
  geosite="$(identity_file_sha256 "${XRAY_ASSET_DIR}/geosite.dat")" || return 1
  caps="$(xray_binary_capabilities)" || return 1
  metadata="$(stat -c '%a:%u:%g' "${XRAY_BIN}")" || return 1
  jq -e --arg binary "${binary}" --arg geoip "${geoip}" --arg geosite "${geosite}" \
    --arg metadata "${metadata}" --arg capabilities "${caps}" \
    '.schema == 1 and (.tag | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
      and (.commit | test("^[0-9a-f]{40}$")) and (.archive_sha256 | test("^[0-9a-f]{64}$"))
      and .binary_sha256 == $binary and .geoip_sha256 == $geoip and .geosite_sha256 == $geosite
      and .binary_metadata == $metadata and .capabilities == $capabilities
      and .capabilities == "cap_net_bind_service=ep"' "${record}" >/dev/null 2>&1
}

xray_installed_matches_selected() {
  xray_installed_identity_valid || return 1
  [[ "${XRAY_SELECTED_EXPECTED_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
  jq -e --arg tag "${XRAY_SELECTED_TAG}" --arg commit "${XRAY_SELECTED_COMMIT}" \
    --arg arch "${XRAY_CONTEXT_ARCH}" --arg digest "${XRAY_SELECTED_EXPECTED_SHA256}" \
    '.tag == $tag and .commit == $commit and .arch == $arch and .archive_sha256 == $digest' \
    "$(xray_identity_file)" >/dev/null 2>&1
}

bundle_identity_valid() {
  local root="${1}" signature="" manifest=""
  bundle_root_ready "${root}" || return 1
  [[ -f "${root}/.xtun-bundle.json" && ! -L "${root}/.xtun-bundle.json" ]] || return 1
  signature="$(bundle_content_signature "${root}")" || return 1
  manifest="$(bundle_content_manifest "${root}")" || return 1
  jq -e --arg signature "${signature}" --arg manifest "${manifest}" \
    '.schema == 1 and .content_sha256 == $signature and .files == $manifest' \
    "${root}/.xtun-bundle.json" >/dev/null 2>&1
}

write_bundle_install_identity() {
  local source_root="${1}" target_root="${2}" signature="" manifest="" entry="" commit="" ref="" source="local-content" archive="" tmp=""
  signature="$(bundle_content_signature "${target_root}")" || return 1
  manifest="$(bundle_content_manifest "${target_root}")" || return 1
  entry="$(identity_file_sha256 "${target_root}/xtun.sh")" || return 1
  if [[ -f "${source_root}/.xtun-source.tsv" && ! -L "${source_root}/.xtun-source.tsv" ]]; then
    [[ "$(awk -F'\t' '$1=="content_sha256" {print $2}' "${source_root}/.xtun-source.tsv")" == "${signature}" ]] || return 1
    [[ "$(awk -F'\t' '$1=="entry_sha256" {print $2}' "${source_root}/.xtun-source.tsv")" == "${entry}" ]] || return 1
    source="$(awk -F'\t' '$1=="source" {print $2}' "${source_root}/.xtun-source.tsv")"
    ref="$(awk -F'\t' '$1=="ref" {print $2}' "${source_root}/.xtun-source.tsv")"
    commit="$(awk -F'\t' '$1=="commit" {print $2}' "${source_root}/.xtun-source.tsv")"
    archive="$(awk -F'\t' '$1=="archive_sha256" {print $2}' "${source_root}/.xtun-source.tsv")"
  elif bundle_identity_valid "${source_root}"; then
    source="$(jq -r '.source' "${source_root}/.xtun-bundle.json")"
    ref="$(jq -r '.ref' "${source_root}/.xtun-bundle.json")"
    commit="$(jq -r '.commit' "${source_root}/.xtun-bundle.json")"
    archive="$(jq -r '.archive_sha256' "${source_root}/.xtun-bundle.json")"
  elif command -v git >/dev/null 2>&1 && [[ -d "${source_root}/.git" ]] \
    && [[ -z "$(git -C "${source_root}" status --porcelain -- xtun.sh lib static 2>/dev/null)" ]]; then
    commit="$(git -C "${source_root}" rev-parse HEAD)" || return 1
    ref="$(git -C "${source_root}" symbolic-ref --short -q HEAD || printf 'detached')"
    source="git-checkout"
  fi
  tmp="$(mktemp "${target_root}/.identity.XXXXXX")" || return 1
  if ! jq -n --arg version "$(bundle_script_version "${target_root}")" --arg ref "${ref}" --arg commit "${commit}" \
    --arg source "${source}" --arg archive "${archive}" --arg entry "${entry}" \
    --arg signature "${signature}" --arg manifest "${manifest}" \
    --arg state "${STATE_VERSION_CURRENT}" --arg params "${PARAMETER_REVISION_CURRENT}" \
    '{schema:1,version:$version,ref:$ref,commit:$commit,source:$source,archive_sha256:$archive,
      entry_sha256:$entry,content_sha256:$signature,files:$manifest,state_schema:$state,parameter_revision:$params}' \
    > "${tmp}" || ! chmod 0644 "${tmp}" || ! durable_replace_file "${tmp}" "${target_root}/.xtun-bundle.json"; then
    rm -f "${tmp}"; return 1
  fi
}
