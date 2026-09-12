#!/usr/bin/env bash

run_xray_version_selection_case() {
  local releases_jsonl=""
  local selected_tag=""
  local output=""

  load_functions

  [[ "$(xray_version_rank "v26.9.9")" < "$(xray_version_rank "v26.10.1")" ]]
  [[ "$(xray_highest_release_tag v26.3.27 v26.9.9)" == "v26.9.9" ]]
  [[ "$(xray_highest_release_tag v26.3.27 v26.9.9 v26.10.1)" == "v26.10.1" ]]

  releases_jsonl=$'{"tag_name":"v1.6.6-2","prerelease":false}\n{"tag_name":"v26.3.27","prerelease":false}\n{"tag_name":"v26.9.9","prerelease":true}\n{"tag_name":"v26.10.1","prerelease":false}'
  selected_tag="$(xray_select_latest_release_json <<<"${releases_jsonl}" | jq -r '.tag_name')"
  [[ "${selected_tag}" == "v26.10.1" ]]

  if output="$(xray_select_latest_release_json <<<'{"tag_name":"v26.9.9","prerelease":true}
{"tag_name":"v26.10.1-rc.1","prerelease":true}' 2>&1)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q '可能更新的无法识别'
}

run_xray_latest_pagination_case() {
  load_functions

  xray_fetch_json() {
    case "${1}" in
      *page=1*)
        printf '%s' '[{"tag_name":"v26.3.27","draft":false},{"tag_name":"v26.9.9","draft":false,"prerelease":true},{"tag_name":"v26.99.0","draft":true}]'
        ;;
      *page=2*)
        printf '%s' '[{"tag_name":"v26.10.1","draft":false}]'
        ;;
      *)
        return 1
        ;;
    esac
  }

  XRAY_RELEASES_PER_PAGE=3
  [[ "$(xray_resolve_latest_release_json | jq -r '.tag_name')" == "v26.10.1" ]]
}

run_xray_explicit_release_context_case() {
  local release_metadata_json=""

  load_functions

  release_metadata_json='{"tag_name":"v26.9.9","draft":false,"prerelease":true,"assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://example.invalid/v26.9.9/Xray-linux-64.zip","digest":"sha256:1eb9175d0f0a8f8149c9230a7fc5ae66ce332ed20a53155ce61fe62e3f58b7df"},{"name":"Xray-linux-64.zip.dgst","browser_download_url":"https://example.invalid/v26.9.9/Xray-linux-64.zip.dgst"}]}'
  xray_fetch_json() {
    case "${1}" in
      *releases/tags/v26.9.9)
        printf '%s' "${release_metadata_json}"
        ;;
      *git/ref/tags/v26.9.9)
        printf '%s' '{"object":{"sha":"1111111111111111111111111111111111111111","type":"tag"}}'
        ;;
      *git/tags/1111111111111111111111111111111111111111)
        printf '%s' '{"object":{"sha":"52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120","type":"commit"}}'
        ;;
      *)
        return 1
        ;;
    esac
  }

  xray_prepare_release_context "v26.9.9" "64"
  [[ "${XRAY_SELECTED_TAG}" == "v26.9.9" ]]
  [[ "${XRAY_SELECTED_COMMIT}" == "52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120" ]]
  [[ "${XRAY_SELECTED_PRERELEASE}" == "true" ]]
  [[ "${XRAY_SELECTED_ARCHIVE_NAME}" == "Xray-linux-64.zip" ]]
  [[ "${XRAY_SELECTED_EXPECTED_SHA256}" == "1eb9175d0f0a8f8149c9230a7fc5ae66ce332ed20a53155ce61fe62e3f58b7df" ]]
}

run_xray_release_metadata_failure_case() {
  local release_metadata_json=""
  local output=""

  load_functions
  release_metadata_json='{"tag_name":"v26.9.9","draft":false,"prerelease":true,"assets":[]}'
  xray_fetch_json() {
    case "${1}" in
      *releases/tags/v26.9.9)
        printf '%s' "${release_metadata_json}"
        ;;
      *git/ref/tags/v26.9.9)
        printf '%s' '{"object":{"sha":"52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120","type":"commit"}}'
        ;;
      *)
        return 1
        ;;
    esac
  }

  if output="$(xray_prepare_release_context "v26.9.9" "64" 2>&1)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q '缺少当前架构资产'
}

run_xray_release_digest_conflict_case() {
  local workdir=""
  local output=""
  local archive_sha256=""

  load_functions
  workdir="$(mktemp -d)"
  printf 'archive' >"${workdir}/archive"
  archive_sha256="$(sha256sum "${workdir}/archive" | awk '{print $1}')"
  XRAY_SELECTED_TAG="v26.9.9"
  XRAY_SELECTED_COMMIT="52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120"
  XRAY_SELECTED_ARCHIVE_NAME="Xray-linux-64.zip"
  XRAY_SELECTED_ARCHIVE_URL="https://example.invalid/Xray-linux-64.zip"
  XRAY_SELECTED_DGST_URL="https://example.invalid/Xray-linux-64.zip.dgst"
  XRAY_SELECTED_EXPECTED_SHA256="${archive_sha256}"
  curl() {
    case "${*}" in
      *Xray-linux-64.zip.dgst*)
        printf 'SHA256 (Xray-linux-64.zip) = 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n' >"${@: -1}"
        ;;
      *)
        printf 'archive' >"${@: -1}"
        ;;
    esac
  }

  if output="$(xray_download_release "${workdir}" 2>&1)"; then
    rm -rf "${workdir}"
    return 1
  fi
  rm -rf "${workdir}"
  printf '%s' "${output}" | grep -q '摘要冲突'
}

run_xray_candidate_commands_case() {
  local workdir=""
  local fake_xray=""
  local pair=""

  load_functions
  workdir="$(mktemp -d)"
  fake_xray="${workdir}/xray"
  cat >"${fake_xray}" <<'SCRIPT'
#!/usr/bin/env bash
case "${1}" in
  version)
    printf 'Xray 26.9.9 (Xray, Penetrates Everything.) test\n'
    ;;
  x25519)
    printf 'PrivateKey: private\nPassword (PublicKey): public\nHash32: hash\n'
    ;;
  vlessenc)
    printf 'Authentication: X25519, not Post-Quantum\n"decryption": "mlkem768x25519plus.native.600s.same-group-decryption"\n"encryption": "mlkem768x25519plus.native.0rtt.same-group-encryption"\nAuthentication: ML-KEM-768\n"decryption": "other-decryption"\n"encryption": "other-encryption"\n'
    ;;
  run)
    exit 0
    ;;
esac
SCRIPT
  chmod 0755 "${fake_xray}"

  pair="$(parse_xhttp_vless_encryption_pair "$("${fake_xray}" vlessenc)")"
  [[ "${pair}" == $'mlkem768x25519plus.native.600s.same-group-decryption\tmlkem768x25519plus.native.0rtt.same-group-encryption' ]]
  xray_validate_candidate_commands "${fake_xray}" "v26.9.9"

  rm -rf "${workdir}"
}

run_xray_host_candidate_case() {
  local version_output=""
  local tag=""

  load_functions
  version_output="$("${TEST_HOST_XRAY_BIN}" version | head -n 1)"
  [[ "${version_output}" =~ ^Xray\ ([0-9]+\.[0-9]+\.[0-9]+) ]]
  tag="v${BASH_REMATCH[1]}"
  xray_validate_candidate_commands "${TEST_HOST_XRAY_BIN}" "${tag}"
}

run_xray_version_argument_case() {
  load_functions

  XRAY_VERSION_REQUEST="latest-published"
  parse_install_args --xray-version v26.9.9 --non-interactive
  [[ "${XRAY_VERSION_REQUEST}" == "v26.9.9" ]]

  XRAY_VERSION_REQUEST="latest-published"
  parse_upgrade_args --xray-version v26.3.27
  [[ "${XRAY_VERSION_REQUEST}" == "v26.3.27" ]]

}
