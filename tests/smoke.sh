#!/usr/bin/env bash

set -Eeuo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cases_output.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cases_state_runtime.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cases_change.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cases_cli_and_install.sh"

# 失败现场：哪条命令、在哪个函数的哪一行挂的。用例跑在子 shell 里，变量传不回来，
# 所以走一个临时文件。
SMOKE_DIAG_FILE=""
# 用例自己的 stderr。ERR trap 抓不到 die——die 是 exit，exit 不触发 ERR，
# 于是栈上只剩下外层那个 `( "${case_name}" )`，等于什么都没说。
# die 的话都在 stderr 上，所以另外接一份。
SMOKE_ERR_FILE=""

# set -E 让 ERR trap 被函数、命令替换和子 shell 继承，于是用例里最深处那条失败命令
# 会先触发一次。栈往上抛的时候还会再触发几次，那些是同一次失败的回声，只留第一条。
smoke_record_err() {
  local status=$?
  local depth=1

  [[ -n "${SMOKE_DIAG_FILE}" ]] || return 0
  [[ ! -s "${SMOKE_DIAG_FILE}" ]] || return 0

  {
    printf '失败命令：%s（退出码 %s）\n' "${BASH_COMMAND}" "${status}"
    while [[ "${depth}" -lt "${#FUNCNAME[@]}" ]]; do
      printf '  在 %s（%s:%s）\n' \
        "${FUNCNAME[depth]}" "${BASH_SOURCE[depth]}" "${BASH_LINENO[depth - 1]}"
      depth=$((depth + 1))
    done
  } >> "${SMOKE_DIAG_FILE}" 2>/dev/null || true

  return 0
}

# 当前正在跑的用例名，失败时由 EXIT trap 报出来。
# 注意不能改成 `( "${case_name}" ) || status=$?` 去直接捕获退出码：那样子 shell 就成了
# AND-OR 列表的非末项，errexit 在整个子 shell 里失效，用例中间所有裸 [[ ]] 断言当场
# 变成空转——这套测试要防的正是这一类静默通过。所以退出码只能从 EXIT trap 的 $? 拿。
CURRENT_CASE=""

run_smoke_case() {
  local case_name="${1}"

  CURRENT_CASE="${case_name}"
  : > "${SMOKE_DIAG_FILE}"
  : > "${SMOKE_ERR_FILE}"
  printf '[case] %s\n' "${case_name}"
  (
    "${case_name}"
  ) 2> "${SMOKE_ERR_FILE}"
  # 用例过了才回放它的 stderr；挂了的话由 EXIT trap 连着现场一起报。
  cat "${SMOKE_ERR_FILE}" >&2
  CURRENT_CASE=""
}

# ------------------------------
# 真实部署路径的存在性快照
# 测试以 root 在生产机上跑时，任何用例都不该删掉这些
# ------------------------------
REAL_MANAGED_CANARY=(
  /usr/local/etc/xray
  /usr/local/lib/xtun
  /usr/local/sbin/xtun
  /usr/local/bin/xray
  /usr/local/share/xray
  /usr/local/sbin/xtun-core-health.sh
  /usr/local/sbin/xtun-net-optimize.sh
  /etc/systemd/system/xray.service
  /etc/haproxy/haproxy.cfg
  /etc/nginx/conf.d/xtun.conf
  /etc/ssl/xtun
  /etc/logrotate.d/xtun
  /var/www/xtun-fallback
  /var/log/xtun
  /root/xtun-output.md
  /root/xtun-subscriptions
)

canary_snapshot() {
  local path=""

  for path in "${REAL_MANAGED_CANARY[@]}"; do
    if [[ -e "${path}" ]]; then
      printf '%s\n' "${path}"
    fi
  done

  return 0
}

assert_canary_intact() {
  local before="${1}"
  local missing=""

  [[ -n "${before}" ]] || return 0

  missing="$(comm -23 <(printf '%s\n' "${before}") <(canary_snapshot | LC_ALL=C sort) || true)"
  if [[ -n "${missing}" ]]; then
    printf '[fail] 测试删除了真实部署文件：\n%s\n' "${missing}" >&2
    printf '[fail] 说明某个用例逃出了 TEST_SANDBOX_ROOT，请检查 sandbox_managed_paths。\n' >&2
    return 1
  fi
}

cleanup_test_sandbox() {
  case "${TEST_SANDBOX_ROOT:-}" in
    */xtun-test-sandbox.*) rm -rf "${TEST_SANDBOX_ROOT}" ;;
  esac
}

# 失败时先把是哪条用例说清楚。以前一条用例挂了，脚本就直接死在那儿，
# 只能靠「最后一行 [case] 是谁」去猜，而 CI 的日志要 admin 权限才读得到。
on_smoke_exit() {
  local status=$?
  local diag=""

  if [[ "${status}" -ne 0 && -n "${CURRENT_CASE}" ]]; then
    [[ ! -s "${SMOKE_DIAG_FILE}" ]] || diag="$(<"${SMOKE_DIAG_FILE}")"
    # annotation 有长度上限，用例的 stderr 只取末尾几十行——die 的那句在最后。
    if [[ -s "${SMOKE_ERR_FILE}" ]]; then
      diag+="${diag:+$'\n'}用例 stderr（末尾 40 行）："$'\n'"$(tail -n 40 "${SMOKE_ERR_FILE}")"
    fi
    printf '[fail] 用例 %s 失败（退出码 %s）\n' "${CURRENT_CASE}" "${status}" >&2
    [[ -z "${diag}" ]] || printf '%s\n' "${diag}" >&2
    # GitHub Actions 上再发一条 workflow command：失败用例名会变成 run 页面上的
    # annotation。annotation 匿名就能读，日志不行，所以这条是 CI 上唯一
    # 不需要仓库管理员权限也能看到「挂在哪」的途径。
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      # workflow command 的 message 是单行的，换行要转义成 %0A（% 本身先转）。
      diag="${diag//\%/%25}"
      diag="${diag//$'\r'/%0D}"
      diag="${diag//$'\n'/%0A}"
      printf '::error title=smoke 用例失败::%s（退出码 %s）%s\n' \
        "${CURRENT_CASE}" "${status}" "${diag:+%0A${diag}}"
    fi
  fi

  rm -f "${SMOKE_DIAG_FILE:-}" "${SMOKE_ERR_FILE:-}"
  cleanup_test_sandbox
}

main() {
  local case_name=""
  local canary_before=""
  local -a cases=(
    run_warp_enabled_case
    run_multi_client_config_output_case
    run_warp_disabled_case
    run_warp_rules_file_case
    run_warp_outbound_json_shape_case
    run_warp_config_json_valid_case
    run_output_helper_case
    run_output_default_transport_fields_case
    run_xray_config_escape_case
    run_generated_file_atomic_failure_case
    run_subscription_qr_success_case
    run_state_context_case
    run_state_version_case
    run_health_history_count_without_python_case
    run_state_file_decode_case
    run_node_client_state_case
    run_runtime_context_reset_case
    run_backup_path_without_session_case
    run_begin_managed_change_resolves_xray_user_case
    run_usage_case
    run_show_links_without_state_case
    run_single_file_bootstrap_case
    run_bootstrap_archive_resolve_case
    run_install_self_command_case
    run_update_script_command_case
    run_logging_case
    run_value_source_case
    run_prompt_reuse_case
    run_install_validation_case
    run_xray_digest_parse_case
    run_install_xray_checksum_failure_case
    run_install_packages_failure_case
    run_install_draft_case
    run_service_config_helper_case
    run_fallback_site_deploy_case
    run_user_block_preserve_case
    run_user_block_marker_whitespace_case
    run_managed_apply_case
    run_service_failure_propagation_case
    run_install_step_failure_propagation_case
    run_errexit_guard_lint_case
    run_dead_global_lint_case
    run_ifs_scope_lint_case
    run_return_trap_lint_case
    run_die_in_subshell_lint_case
    run_pipefail_sigpipe_lint_case
    run_hostname_validation_case
    run_invalid_value_exit_status_case
    run_warp_rules_corrupt_file_case
    run_qdisc_probe_case
    run_service_reload_preference_case
    run_managed_rollback_case
    run_optional_component_rollback_case
    run_install_rollback_helper_case
    run_tls_stage_failure_case
    run_tls_issue_failure_not_reported_ok_case
    run_tls_stage_trap_scope_case
    run_xray_only_update_write_failure_case
    run_restart_optional_service_case
    run_change_helper_case
    run_install_parse_case
    run_install_prepare_preserves_ech_flag_case
    run_sensitive_option_reject_case
    run_preflight_token_verify_case
    run_preflight_domain_resolution_warning_case
    run_warp_rule_normalize_case
    run_warp_rules_editor_case
    run_optional_component_skip_case
    run_joey_bbr_release_parse_case
    run_joey_bbr_pending_reboot_case
    run_install_network_joey_reboot_case
    run_net_sysctl_content_case
    run_apply_net_opt_command_case
    run_apply_config_command_case
    run_warp_credential_helper_case
    run_warp_credential_ensure_failure_case
    run_warp_legacy_teardown_case
    run_cert_mode_input_case
    run_acme_reload_helper_case
    run_nginx_limits_dropin_case
    run_nginx_worker_connections_case
    run_change_command_case
    run_change_warp_enable_rollback_case
    run_renew_cert_command_case
    run_renew_cert_failure_case
    run_change_cert_mode_failure_case
    run_upgrade_command_case
    run_diagnose_command_case
    run_missing_option_value_case
    run_dispatch_case
    run_script_lock_scope_case
    run_script_lock_stale_dir_case
    run_client_cli_case
    run_show_links_stale_output_case
    run_install_flow_case
  )

  load_functions
  stub_side_effects
  canary_before="$(canary_snapshot | LC_ALL=C sort)"
  SMOKE_DIAG_FILE="$(mktemp)"
  SMOKE_ERR_FILE="$(mktemp)"
  trap on_smoke_exit EXIT
  trap smoke_record_err ERR

  for case_name in "${cases[@]}"; do
    run_smoke_case "${case_name}"
  done

  assert_canary_intact "${canary_before}"
  printf 'smoke ok\n'
}

main "$@"
