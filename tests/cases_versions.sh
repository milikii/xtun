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
    # 真核心会拒绝非法 JSON；恒返回 0 的假核心过不了坏配置对照（H16）。
    if grep -q 'this-is-not-json' "${4}"; then
      exit 1
    fi
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
  version_output="$("${TEST_HOST_XRAY_BIN}" version)"
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

# ------------------------------
# W08.1：候选取信任与版本上下文
# 候选校验在 install / upgrade / 菜单三条路径里都跑在「errexit 被豁免」的
# 调用上下文里（`if !` / `||`），每一步只能靠显式的失败传递；这里的假核心
# 刻意在 version 上装得很像，专挑字段结构、恒返回 0 和跨动作复用上下文的漏洞。
# ------------------------------

# 造一个假核心。mode：
#   ok          字段合法，且会拒绝坏配置；
#   bad_keys    version 合法但 x25519 出空值；
#   bad_vlessenc version 合法但 vlessenc 不是 ML-KEM 对；
#   bad_version version 与期望不符；
#   always_zero 一切照做、但 run -test 恒返回 0；
#   reject_all  run -test 一律失败。
write_candidate_fake_core() {
  local path="${1}"
  local mode="${2}"

  cat >"${path}" <<SCRIPT
#!/usr/bin/env bash
case "\${1}" in
  version)
    if [[ "${mode}" == "bad_version" ]]; then
      printf 'Xray 26.9.8 (Xray, Penetrates Everything.) test\n'
    else
      printf 'Xray 26.9.9 (Xray, Penetrates Everything.) test\n'
    fi
    exit 0
    ;;
  x25519)
    if [[ "${mode}" == "bad_keys" ]]; then
      printf 'PrivateKey: \nPassword (PublicKey): public\nHash32: hash\n'
    else
      printf 'PrivateKey: 0OjsApa85B53hcgUPdnI4PlI49DPaKyjGIzn6aUcbnM\nPassword (PublicKey): gEuHBqtdzHqgKNH50lr3_23ssg-i8E6wdnNbi79hGkI\nHash32: vegSXabtOSzM6Zxogg6nvAS9BbxJsmyL3nOAKHGph1Y\n'
    fi
    exit 0
    ;;
  vlessenc)
    if [[ "${mode}" == "bad_vlessenc" ]]; then
      printf 'Authentication: X25519, not Post-Quantum\n"decryption": "plain"\n"encryption": "plain"\n'
    else
      printf 'Authentication: X25519, not Post-Quantum\n"decryption": "mlkem768x25519plus.native.600s.dec"\n"encryption": "mlkem768x25519plus.native.0rtt.enc"\n'
    fi
    exit 0
    ;;
  run)
    if [[ -n "\${CANDIDATE_CONFIG_RECORD:-}" ]]; then
      printf '%s\n' "\${4}" >>"\${CANDIDATE_CONFIG_RECORD}"
    fi
    case "${mode}" in
      always_zero) exit 0 ;;
      reject_all) exit 1 ;;
    esac
    # 真核心会拒绝非法 JSON；假核心也一样，否则「-test 恒返回 0」的候选会混过去。
    if grep -q 'this-is-not-json' "\${4}"; then
      exit 1
    fi
    exit 0
    ;;
esac
exit 2
SCRIPT
  chmod 0755 "${path}"
}

# CLI dispatch 的 `... || status=$?` 会把整条动态调用链的 errexit 关掉。
# 坏候选在那个环境里必须仍然返回非零，否则调用方会把「拒绝」当成「通过」。
assert_candidate_rejected_in_exempt_context() {
  local label="${1}"
  local binary="${2}"
  local status=0

  ( set +e; xray_validate_candidate_commands "${binary}" "v26.9.9"; exit $? ) || status=$?
  if [[ "${status}" -eq 0 ]]; then
    printf '[fail] %s：errexit 被关掉后坏候选被接受（H16）\n' "${label}" >&2
    return 1
  fi

  if xray_validate_candidate_commands "${binary}" "v26.9.9"; then
    printf '[fail] %s：if 条件里坏候选被接受（H16）\n' "${label}" >&2
    return 1
  fi
  return 0
}

run_candidate_validation_call_context_case() {
  local workdir=""
  local fake=""
  local status=0

  load_functions
  workdir="$(mktemp -d)"
  fake="${workdir}/xray"

  write_candidate_fake_core "${fake}" "ok"
  ( set +e; xray_validate_candidate_commands "${fake}" "v26.9.9"; exit $? ) || status=$?
  if [[ "${status}" -ne 0 ]]; then
    printf '[fail] 合法候选在 errexit 被关掉时被拒（退出码 %s）\n' "${status}" >&2
    rm -rf "${workdir}"
    return 1
  fi

  write_candidate_fake_core "${fake}" "bad_keys"
  assert_candidate_rejected_in_exempt_context "x25519 有字段没有值" "${fake}"
  write_candidate_fake_core "${fake}" "bad_vlessenc"
  assert_candidate_rejected_in_exempt_context "vlessenc 不是 ML-KEM 对" "${fake}"
  write_candidate_fake_core "${fake}" "bad_version"
  assert_candidate_rejected_in_exempt_context "version 与期望不符" "${fake}"
  write_candidate_fake_core "${fake}" "always_zero"
  assert_candidate_rejected_in_exempt_context "配置测试恒返回 0" "${fake}"

  rm -rf "${workdir}"
}

run_candidate_work_dir_case() {
  local workdir=""
  local scratch=""
  local fake=""
  local record=""
  local first=""
  local second=""

  load_functions
  workdir="$(mktemp -d)"
  scratch="${workdir}/candidate-tmp"
  mkdir -p "${scratch}"
  record="${workdir}/configs"
  fake="${workdir}/xray"
  : >"${record}"

  write_candidate_fake_core "${fake}" "ok"
  export CANDIDATE_CONFIG_RECORD="${record}"
  TMPDIR="${scratch}" xray_validate_candidate_commands "${fake}" "v26.9.9"
  TMPDIR="${scratch}" xray_validate_candidate_commands "${fake}" "v26.9.9"
  unset CANDIDATE_CONFIG_RECORD

  # 每次校验 3 条（两个好配置 + 一个坏配置对照）。
  [[ "$(wc -l <"${record}")" == "6" ]]
  first="$(sed -n 1p "${record}")"
  second="$(sed -n 4p "${record}")"
  # 候选配置放在本次操作自己的目录里，不是固定 /tmp 名字，也不能两次撞车。
  [[ "$(dirname "${first}")" == "${scratch}"/xtun-xray-candidate.* ]]
  [[ "$(dirname "${first}")" != "$(dirname "${second}")" ]]
  [[ ! -e "$(dirname "${first}")" ]]
  [[ -z "$(find "${scratch}" -mindepth 1 -print -quit)" ]]

  # 校验失败（这里卡在配置测试）同样要清干净，不留半份临时配置。
  write_candidate_fake_core "${fake}" "reject_all"
  if TMPDIR="${scratch}" xray_validate_candidate_commands "${fake}" "v26.9.9"; then
    printf '[fail] 配置测试不通过的候选被接受\n' >&2
    rm -rf "${workdir}"
    return 1
  fi
  [[ -z "$(find "${scratch}" -mindepth 1 -print -quit)" ]]

  rm -rf "${workdir}"
}

# 版本上下文只属于一次动作：同请求同架构解析一次后锁定，换了请求或架构就重新
# 解析，动作结束即释放——上一次动作的选择不许被下一次沿用（H15）。
run_release_version_context_scope_case() {
  local workdir=""
  local fetches=""
  local count_before=""
  local count_after=""
  local page_body=""
  local v2699_json='{"tag_name":"v26.9.9","draft":false,"prerelease":true,"assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://example.invalid/v26.9.9/Xray-linux-64.zip","digest":"sha256:1eb9175d0f0a8f8149c9230a7fc5ae66ce332ed20a53155ce61fe62e3f58b7df"},{"name":"Xray-linux-64.zip.dgst","browser_download_url":"https://example.invalid/v26.9.9/Xray-linux-64.zip.dgst"}]}'
  local v26110_json='{"tag_name":"v26.11.0","draft":false,"prerelease":false,"assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://example.invalid/v26.11.0/Xray-linux-64.zip","digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},{"name":"Xray-linux-64.zip.dgst","browser_download_url":"https://example.invalid/v26.11.0/Xray-linux-64.zip.dgst"}]}'
  local v26101_json='{"tag_name":"v26.10.1","draft":false,"prerelease":false,"assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://example.invalid/v26.10.1/Xray-linux-64.zip","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"name":"Xray-linux-64.zip.dgst","browser_download_url":"https://example.invalid/v26.10.1/Xray-linux-64.zip.dgst"},{"name":"Xray-linux-arm64-v8a.zip","browser_download_url":"https://example.invalid/v26.10.1/Xray-linux-arm64-v8a.zip","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},{"name":"Xray-linux-arm64-v8a.zip.dgst","browser_download_url":"https://example.invalid/v26.10.1/Xray-linux-arm64-v8a.zip.dgst"}]}'

  load_functions
  workdir="$(mktemp -d)"
  fetches="${workdir}/fetches"
  : >"${fetches}"
  page_body="${v2699_json}"

  xray_fetch_json() {
    printf '%s\n' "${1}" >>"${fetches}"
    case "${1}" in
      *per_page=*)
        printf '[%s]' "${page_body}"
        ;;
      *releases/tags/v26.10.1)
        printf '%s' "${v26101_json}"
        ;;
      *git/ref/tags/v26.9.9)
        printf '%s' '{"object":{"sha":"52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120","type":"commit"}}'
        ;;
      *git/ref/tags/v26.10.1)
        printf '%s' '{"object":{"sha":"2222222222222222222222222222222222222222","type":"commit"}}'
        ;;
      *git/ref/tags/v26.11.0)
        printf '%s' '{"object":{"sha":"3333333333333333333333333333333333333333","type":"commit"}}'
        ;;
      *)
        return 1
        ;;
    esac
  }

  xray_ensure_release_context "latest-published" "64"
  [[ "${XRAY_SELECTED_TAG}" == "v26.9.9" ]]
  count_before="$(wc -l <"${fetches}")"
  [[ "${count_before}" -gt 0 ]]

  # 同请求同架构：复用已锁定的上下文，不再打一次网络。
  xray_ensure_release_context "latest-published" "64"
  count_after="$(wc -l <"${fetches}")"
  [[ "${count_after}" == "${count_before}" ]]

  # 换了请求：重新解析，用的是这一次的 tag。
  xray_ensure_release_context "v26.10.1" "64"
  [[ "${XRAY_SELECTED_TAG}" == "v26.10.1" ]]
  [[ "${XRAY_SELECTED_COMMIT}" == "2222222222222222222222222222222222222222" ]]

  # 换了架构：也要重新解析。
  xray_ensure_release_context "v26.10.1" "arm64-v8a"
  [[ "${XRAY_SELECTED_ARCHIVE_NAME}" == "Xray-linux-arm64-v8a.zip" ]]

  # 同一次操作里上游发了新版：回到 latest 必须重新解析，不能沿用之前的 selected。
  page_body="${v26110_json}"
  xray_ensure_release_context "latest-published" "64"
  [[ "${XRAY_SELECTED_TAG}" == "v26.11.0" ]]
  [[ "${XRAY_SELECTED_COMMIT}" == "3333333333333333333333333333333333333333" ]]

  xray_release_version_context
  if xray_release_context_ready; then
    printf '[fail] 动作结束没有释放版本上下文（H15）\n' >&2
    rm -rf "${workdir}"
    return 1
  fi

  xray_ensure_release_context "v26.10.1" "64"
  [[ "${XRAY_SELECTED_TAG}" == "v26.10.1" ]]

  rm -rf "${workdir}"
}

# H15 的端到端缝：同一个进程里连续两次动作，第二次必须按新的请求重新解析，
# 不能沿用上一次已经 ready 的 selected。
run_install_xray_requested_version_case() {
  local workdir=""
  local downloads=""
  local status=0
  local v2699_json='{"tag_name":"v26.9.9","draft":false,"prerelease":true,"assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://example.invalid/v26.9.9/Xray-linux-64.zip","digest":"sha256:1eb9175d0f0a8f8149c9230a7fc5ae66ce332ed20a53155ce61fe62e3f58b7df"},{"name":"Xray-linux-64.zip.dgst","browser_download_url":"https://example.invalid/v26.9.9/Xray-linux-64.zip.dgst"}]}'
  local v26101_json='{"tag_name":"v26.10.1","draft":false,"prerelease":false,"assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://example.invalid/v26.10.1/Xray-linux-64.zip","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"name":"Xray-linux-64.zip.dgst","browser_download_url":"https://example.invalid/v26.10.1/Xray-linux-64.zip.dgst"}]}'

  load_functions
  workdir="$(mktemp -d)"
  downloads="${workdir}/downloads"
  : >"${downloads}"

  xray_fetch_json() {
    case "${1}" in
      *per_page=*)
        printf '[%s]' "${v2699_json}"
        ;;
      *releases/tags/v26.10.1)
        printf '%s' "${v26101_json}"
        ;;
      *git/ref/tags/v26.9.9)
        printf '%s' '{"object":{"sha":"52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120","type":"commit"}}'
        ;;
      *git/ref/tags/v26.10.1)
        printf '%s' '{"object":{"sha":"2222222222222222222222222222222222222222","type":"commit"}}'
        ;;
      *)
        return 1
        ;;
    esac
  }
  detect_xray_arch() { printf '64'; }
  xray_download_release() {
    printf '%s\n' "${XRAY_SELECTED_ARCHIVE_URL}" >>"${downloads}"
    return 1
  }

  XRAY_VERSION_REQUEST="latest-published"
  install_xray || status=$?
  [[ "${status}" -ne 0 ]]

  XRAY_VERSION_REQUEST="v26.10.1"
  status=0
  install_xray || status=$?
  [[ "${status}" -ne 0 ]]

  [[ "$(wc -l <"${downloads}")" == "2" ]]
  assert_contains 'v26.9.9' <(sed -n 1p "${downloads}")
  assert_contains 'v26.10.1' <(sed -n 2p "${downloads}")

  rm -rf "${workdir}"
}

# 释放边界挂在命令入口上：一次动作结束后，上下文不能留给下一次。
run_version_context_action_boundary_case() {
  load_functions

  XRAY_SELECTED_TAG="v26.9.9"
  XRAY_SELECTED_COMMIT="52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120"
  XRAY_SELECTED_ARCHIVE_URL="https://example.invalid/v26.9.9/Xray-linux-64.zip"

  dispatch_cli_command() {
    XRAY_SELECTED_TAG="v26.10.1"
    XRAY_SELECTED_COMMIT="2222222222222222222222222222222222222222"
    XRAY_SELECTED_ARCHIVE_URL="https://example.invalid/v26.10.1/Xray-linux-64.zip"
  }
  finish_backup_session() { :; }
  release_script_lock() { :; }

  run_cli_command status

  if xray_release_context_ready; then
    printf '[fail] 一次动作结束后版本上下文没有释放（H15）\n' >&2
    return 1
  fi
}
