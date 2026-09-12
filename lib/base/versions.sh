# shellcheck shell=bash

# ------------------------------
# Xray 版本解析与下载层
# 负责 latest-published 选择、显式 tag、摘要校验和候选命令验证
# ------------------------------

XRAY_CORE_REPO="XTLS/Xray-core"
XRAY_BASELINE_TAG="v26.9.9"
XRAY_BASELINE_COMMIT="52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120"
XRAY_RELEASES_PER_PAGE="${XRAY_RELEASES_PER_PAGE:-100}"
XRAY_RELEASES_MAX_PAGES="${XRAY_RELEASES_MAX_PAGES:-20}"
XRAY_GITHUB_TIMEOUT_SECONDS="${XRAY_GITHUB_TIMEOUT_SECONDS:-30}"
XRAY_RELEASES_TOTAL_TIMEOUT_SECONDS="${XRAY_RELEASES_TOTAL_TIMEOUT_SECONDS:-180}"

xray_baseline_archive_sha256() {
  case "${1}" in
    Xray-linux-64.zip)
      printf '%s' "1eb9175d0f0a8f8149c9230a7fc5ae66ce332ed20a53155ce61fe62e3f58b7df"
      ;;
    Xray-linux-arm64-v8a.zip)
      printf '%s' "3e38d72dfc5eb65c91df0e5583e9b6676c32232041da47de6ae73946b526d66c"
      ;;
    *)
      return 1
      ;;
  esac
}

xray_archive_name_for_arch() {
  local arch="${1}"

  case "${arch}" in
    64)
      printf '%s' "Xray-linux-64.zip"
      ;;
    arm64-v8a)
      printf '%s' "Xray-linux-arm64-v8a.zip"
      ;;
    *)
      printf '%s\n' "不支持的 Xray 架构：${arch}" >&2
      return 1
      ;;
  esac
}

xray_normalize_sha256() {
  local value="${1:-}"

  value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]*sha256:[[:space:]]*//; s/^[[:space:]]+|[[:space:]]+$//g')"
  [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "${value}"
}

xray_parse_dgst_sha256() {
  local dgst_file="${1}"
  local asset_name="${2}"
  local value=""

  value="$(grep -Fi "${asset_name}" "${dgst_file}" 2>/dev/null | grep -Eo '[0-9a-fA-F]{64}' | head -n 1 || true)"
  [[ -n "${value}" ]] || value="$(grep -Ei 'sha(2-)?256' "${dgst_file}" 2>/dev/null | grep -Eo '[0-9a-fA-F]{64}' | head -n 1 || true)"
  [[ -n "${value}" ]] || return 1
  xray_normalize_sha256 "${value}"
}

xray_valid_release_tag() {
  [[ "${1}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

xray_version_rank() {
  local tag="${1}"

  xray_valid_release_tag "${tag}" || return 1
  [[ "${tag}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]
  printf '%012d%012d%012d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

xray_tag_base_rank() {
  local tag="${1}"

  [[ "${tag}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)([-+].*)?$ ]] || return 1
  printf '%012d%012d%012d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

xray_highest_release_tag() {
  local tag=""
  local highest=""
  local highest_rank=""
  local unknown_rank=""

  for tag in "$@"; do
    xray_valid_release_tag "${tag}" || continue
    if [[ -z "${highest}" ]] || [[ "$(xray_version_rank "${tag}")" > "$(xray_version_rank "${highest}")" ]]; then
      highest="${tag}"
    fi
  done

  [[ -n "${highest}" ]] || {
    printf 'Xray 发布列表中没有可识别的非 draft 版本 tag。\n' >&2
    return 1
  }
  highest_rank="$(xray_version_rank "${highest}")"

  for tag in "$@"; do
    xray_valid_release_tag "${tag}" && continue
    unknown_rank="$(xray_tag_base_rank "${tag}")" || {
      printf '无法识别的非 draft Xray 版本命名：%s\n' "${tag}" >&2
      return 1
    }
    if [[ "${unknown_rank}" > "${highest_rank}" ]]; then
      printf '存在可能更新的无法识别 Xray 版本命名：%s\n' "${tag}" >&2
      return 1
    fi
  done

  printf '%s' "${highest}"
}

xray_releases_page_url() {
  printf 'https://api.github.com/repos/%s/releases?per_page=%s&page=%s' \
    "${XRAY_CORE_REPO}" "${XRAY_RELEASES_PER_PAGE}" "${1}"
}

xray_release_tag_url() {
  printf 'https://api.github.com/repos/%s/releases/tags/%s' "${XRAY_CORE_REPO}" "${1}"
}

xray_git_ref_url() {
  printf 'https://api.github.com/repos/%s/git/ref/tags/%s' "${XRAY_CORE_REPO}" "${1}"
}

xray_git_tag_url() {
  printf 'https://api.github.com/repos/%s/git/tags/%s' "${XRAY_CORE_REPO}" "${1}"
}

xray_fetch_json() {
  curl -fsSL \
    --connect-timeout 10 \
    --max-time "${XRAY_GITHUB_TIMEOUT_SECONDS}" \
    --retry 2 \
    --retry-all-errors \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${1}"
}

xray_fetch_latest_release_json() {
  local page=""
  local page_json=""
  local release_count=""
  local started_at="${SECONDS}"

  for ((page = 1; page <= XRAY_RELEASES_MAX_PAGES; page++)); do
    if ((SECONDS - started_at >= XRAY_RELEASES_TOTAL_TIMEOUT_SECONDS)); then
      printf 'Xray 发布列表解析超过 %s 秒总预算。\n' "${XRAY_RELEASES_TOTAL_TIMEOUT_SECONDS}" >&2
      return 1
    fi

    page_json="$(xray_fetch_json "$(xray_releases_page_url "${page}")")" || return 1
    release_count="$(jq 'length' <<<"${page_json}" 2>/dev/null)" || return 1
    [[ "${release_count}" =~ ^[0-9]+$ ]] || return 1
    jq -c '.[] | select(.draft != true)' <<<"${page_json}" || return 1
    if ((release_count < XRAY_RELEASES_PER_PAGE)); then
      return 0
    fi
  done

  printf 'Xray 发布列表超过 %s 页，无法证明 latest 解析完整。\n' "${XRAY_RELEASES_MAX_PAGES}" >&2
  return 1
}

xray_select_latest_release_json() {
  local releases_jsonl=""
  local tag=""
  local highest_tag=""
  local selected=""
  local -a tags=()

  releases_jsonl="$(cat)"
  [[ -n "${releases_jsonl}" ]] || return 1

  mapfile -t tags < <(jq -r '.tag_name // empty' <<<"${releases_jsonl}" 2>/dev/null)
  highest_tag="$(xray_highest_release_tag "${tags[@]}")" || return 1
  selected="$(jq -c --arg tag "${highest_tag}" 'select(.tag_name == $tag)' <<<"${releases_jsonl}" 2>/dev/null | head -n 1)"
  [[ -n "${selected}" ]] || return 1
  printf '%s' "${selected}"
}

xray_resolve_latest_release_json() {
  local releases_jsonl=""

  releases_jsonl="$(xray_fetch_latest_release_json)" || return 1
  xray_select_latest_release_json <<<"${releases_jsonl}"
}

xray_fetch_release_by_tag() {
  local tag="${1}"

  xray_valid_release_tag "${tag}" || {
    printf '无效的 Xray 版本 tag：%s\n' "${tag}" >&2
    return 1
  }
  xray_fetch_json "$(xray_release_tag_url "${tag}")"
}

xray_validate_release_metadata() {
  local metadata_json="${1}"
  local expected_tag="${2}"
  local actual_tag=""

  actual_tag="$(jq -er '.tag_name | strings' <<<"${metadata_json}" 2>/dev/null)" || return 1
  [[ "${actual_tag}" == "${expected_tag}" ]] || return 1
  jq -er '.draft == false' <<<"${metadata_json}" >/dev/null 2>&1 || return 1
  jq -er '.prerelease == true or .prerelease == false' <<<"${metadata_json}" >/dev/null 2>&1 || return 1
  jq -er '.assets | type == "array"' <<<"${metadata_json}" >/dev/null 2>&1 || return 1
}

xray_release_asset_field() {
  local metadata_json="${1}"
  local asset_name="${2}"
  local field_name="${3}"
  local value=""

  value="$(jq -r \
    --arg asset_name "${asset_name}" \
    --arg field_name "${field_name}" \
    '.assets[]? | select(.name == $asset_name) | .[$field_name] // empty' \
    <<<"${metadata_json}" 2>/dev/null | head -n 1)"
  [[ -n "${value}" ]] || return 1
  printf '%s' "${value}"
}

xray_resolve_tag_commit() {
  local tag="${1}"
  local ref_json=""
  local object_sha=""
  local object_type=""
  local tag_json=""

  ref_json="$(xray_fetch_json "$(xray_git_ref_url "${tag}")")" || return 1
  object_sha="$(jq -er '.object.sha | select(test("^[0-9a-f]{40}$"))' <<<"${ref_json}" 2>/dev/null)" || return 1
  object_type="$(jq -er '.object.type | strings' <<<"${ref_json}" 2>/dev/null)" || return 1

  if [[ "${object_type}" == "tag" ]]; then
    tag_json="$(xray_fetch_json "$(xray_git_tag_url "${object_sha}")")" || return 1
    object_type="$(jq -er '.object.type | strings' <<<"${tag_json}" 2>/dev/null)" || return 1
    object_sha="$(jq -er '.object.sha | select(test("^[0-9a-f]{40}$"))' <<<"${tag_json}" 2>/dev/null)" || return 1
  fi

  [[ "${object_type}" == "commit" ]] || return 1
  printf '%s' "${object_sha}"
}

xray_reset_release_context() {
  XRAY_SELECTED_TAG=""
  XRAY_SELECTED_COMMIT=""
  XRAY_SELECTED_PRERELEASE=""
  XRAY_SELECTED_ARCHIVE_NAME=""
  XRAY_SELECTED_ARCHIVE_URL=""
  XRAY_SELECTED_DGST_URL=""
  XRAY_SELECTED_EXPECTED_SHA256=""
  XRAY_SELECTED_CHECKSUM_SOURCE=""
  XRAY_SELECTED_RESOLVED_AT=""
}

xray_release_context_ready() {
  [[ -n "${XRAY_SELECTED_TAG:-}" && -n "${XRAY_SELECTED_COMMIT:-}" && -n "${XRAY_SELECTED_ARCHIVE_URL:-}" ]]
}

xray_prepare_release_context() {
  local request="${1:-${XRAY_VERSION_REQUEST:-latest-published}}"
  local arch="${2:-}"
  local metadata_json=""
  local tag=""
  local commit=""
  local archive_name=""
  local archive_url=""
  local digest_url=""
  local api_sha256=""
  local expected_sha256=""

  xray_reset_release_context

  if [[ -z "${arch}" ]]; then
    arch="$(detect_xray_arch)" || return 1
  fi

  if [[ "${request}" == "latest-published" ]]; then
    metadata_json="$(xray_resolve_latest_release_json)" || return 1
    tag="$(jq -er '.tag_name | strings' <<<"${metadata_json}" 2>/dev/null)" || return 1
  else
    tag="${request}"
    metadata_json="$(xray_fetch_release_by_tag "${tag}")" || return 1
  fi

  xray_validate_release_metadata "${metadata_json}" "${tag}" || {
    printf 'Xray 发布元数据无效：%s\n' "${tag}" >&2
    return 1
  }
  commit="$(xray_resolve_tag_commit "${tag}")" || {
    printf '无法固定 Xray tag 指向的提交：%s\n' "${tag}" >&2
    return 1
  }

  archive_name="$(xray_archive_name_for_arch "${arch}")" || return 1
  archive_url="$(xray_release_asset_field "${metadata_json}" "${archive_name}" "browser_download_url")" || {
    printf 'Xray 发布 %s 缺少当前架构资产：%s\n' "${tag}" "${archive_name}" >&2
    return 1
  }
  digest_url="$(xray_release_asset_field "${metadata_json}" "${archive_name}.dgst" "browser_download_url" || true)"
  api_sha256="$(xray_normalize_sha256 "$(xray_release_asset_field "${metadata_json}" "${archive_name}" "digest" || true)" || true)"

  if [[ "${tag}" == "${XRAY_BASELINE_TAG}" ]]; then
    [[ "${commit}" == "${XRAY_BASELINE_COMMIT}" ]] || {
      printf 'Xray %s 的提交摘要与基线记录不一致。\n' "${tag}" >&2
      return 1
    }
    expected_sha256="$(xray_baseline_archive_sha256 "${archive_name}")" || return 1
    if [[ -n "${api_sha256}" && "${api_sha256}" != "${expected_sha256}" ]]; then
      printf 'Xray %s 的 API 摘要与基线记录冲突。\n' "${tag}" >&2
      return 1
    fi
    XRAY_SELECTED_CHECKSUM_SOURCE="baseline and GitHub Release API"
  else
    expected_sha256="${api_sha256}"
    if [[ -n "${expected_sha256}" ]]; then
      XRAY_SELECTED_CHECKSUM_SOURCE="GitHub Release API digest"
    else
      XRAY_SELECTED_CHECKSUM_SOURCE="${archive_name}.dgst"
    fi
  fi

  XRAY_SELECTED_TAG="${tag}"
  XRAY_SELECTED_COMMIT="${commit}"
  XRAY_SELECTED_PRERELEASE="$(jq -r '.prerelease' <<<"${metadata_json}")"
  XRAY_SELECTED_ARCHIVE_NAME="${archive_name}"
  XRAY_SELECTED_ARCHIVE_URL="${archive_url}"
  XRAY_SELECTED_DGST_URL="${digest_url}"
  XRAY_SELECTED_EXPECTED_SHA256="${expected_sha256}"
  XRAY_SELECTED_RESOLVED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

xray_download_release() {
  local target_dir="${1}"
  local archive_path=""
  local digest_path=""
  local expected_sha256=""
  local dgst_sha256=""
  local actual_sha256=""

  xray_release_context_ready || return 1
  archive_path="${target_dir}/${XRAY_SELECTED_ARCHIVE_NAME}"
  expected_sha256="${XRAY_SELECTED_EXPECTED_SHA256}"

  curl -fsSL \
    --connect-timeout 10 \
    --max-time "${XRAY_GITHUB_TIMEOUT_SECONDS}" \
    --retry 2 \
    --retry-all-errors \
    "${XRAY_SELECTED_ARCHIVE_URL}" \
    -o "${archive_path}" || return 1

  if [[ -n "${XRAY_SELECTED_DGST_URL}" ]]; then
    digest_path="${target_dir}/${XRAY_SELECTED_ARCHIVE_NAME}.dgst"
    curl -fsSL \
      --connect-timeout 10 \
      --max-time "${XRAY_GITHUB_TIMEOUT_SECONDS}" \
      --retry 2 \
      --retry-all-errors \
      "${XRAY_SELECTED_DGST_URL}" \
      -o "${digest_path}" || return 1
    dgst_sha256="$(xray_parse_dgst_sha256 "${digest_path}" "${XRAY_SELECTED_ARCHIVE_NAME}")" || return 1
    if [[ -n "${expected_sha256}" && "${dgst_sha256}" != "${expected_sha256}" ]]; then
      printf 'Xray 发布 API 摘要与 .dgst 摘要冲突。\n' >&2
      return 1
    fi
    expected_sha256="${dgst_sha256}"
    XRAY_SELECTED_CHECKSUM_SOURCE="${XRAY_SELECTED_ARCHIVE_NAME}.dgst"
  fi

  [[ -n "${expected_sha256}" ]] || {
    printf 'Xray 安装包缺少 SHA256 校验值。\n' >&2
    return 1
  }
  actual_sha256="$(sha256sum "${archive_path}" | awk '{print tolower($1)}')"
  [[ "${actual_sha256}" == "${expected_sha256}" ]] || {
    printf 'Xray 安装包 SHA256 校验失败。\n' >&2
    return 1
  }
}

parse_xhttp_vless_encryption_pair() {
  local output="${1}"

  awk '
    /^Authentication: X25519/ { selected = 1; next }
    /^Authentication: / && selected { exit }
    selected && /^"decryption": / && !decryption {
      gsub(/^"decryption": "/, ""); gsub(/"$/, ""); decryption = $0
    }
    selected && /^"encryption": / && !encryption {
      gsub(/^"encryption": "/, ""); gsub(/"$/, ""); encryption = $0
    }
    END {
      if (decryption != "" && encryption != "") {
        printf "%s\t%s\n", decryption, encryption
        exit 0
      }
      exit 1
    }
  ' <<<"${output}"
}

xray_validate_candidate_commands() {
  local binary_path="${1}"
  local expected_tag="${2}"
  local expected_version="${expected_tag#v}"
  local version_output=""
  local version_line=""
  local key_output=""
  local enc_output=""
  local encryption_pair=""
  local server_config="${TMPDIR:-/tmp}/xtun-xray-server.json"
  local client_config="${TMPDIR:-/tmp}/xtun-xray-client.json"

  [[ -x "${binary_path}" ]] || return 1
  version_output="$("${binary_path}" version 2>&1)" || return 1
  version_line="$(printf '%s\n' "${version_output}" | head -n 1)"
  [[ "${version_line}" == "Xray ${expected_version} "* ]] || return 1

  key_output="$("${binary_path}" x25519 2>&1)" || return 1
  printf '%s\n' "${key_output}" | grep -q '^PrivateKey:'
  printf '%s\n' "${key_output}" | grep -q '^Password (PublicKey):'
  printf '%s\n' "${key_output}" | grep -q '^Hash32:'

  enc_output="$("${binary_path}" vlessenc 2>&1)" || return 1
  encryption_pair="$(parse_xhttp_vless_encryption_pair "${enc_output}")" || return 1
  [[ "$(printf '%s' "${encryption_pair}" | cut -f1)" == mlkem768x25519plus.* ]]
  [[ "$(printf '%s' "${encryption_pair}" | cut -f2)" == mlkem768x25519plus.* ]]

  printf '%s\n' '{"inbounds":[{"listen":"127.0.0.1","port":18443,"protocol":"dokodemo-door","settings":{"address":"127.0.0.1","port":80}}],"outbounds":[{"protocol":"freedom"}]}' >"${server_config}"
  printf '%s\n' '{"inbounds":[{"listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"udp":true}}],"outbounds":[{"protocol":"freedom"}]}' >"${client_config}"
  "${binary_path}" run -test -config "${server_config}" >/dev/null 2>&1 || return 1
  "${binary_path}" run -test -config "${client_config}" >/dev/null 2>&1 || return 1
  rm -f "${server_config}" "${client_config}" || return 1
}

xray_validate_candidate_archive() {
  local target_dir="${1}"
  local binary_path="${target_dir}/xray/xray"

  [[ -x "${binary_path}" ]] || return 1
  xray_validate_candidate_commands "${binary_path}" "${XRAY_SELECTED_TAG}"
}
