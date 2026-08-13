#!/usr/bin/env bash

set -Eeuo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cases_output.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cases_state_runtime.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cases_change.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cases_cli_and_install.sh"

run_smoke_case() {
  local case_name="${1}"

  printf '[case] %s\n' "${case_name}"
  (
    "${case_name}"
  )
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
    run_managed_apply_case
    run_managed_rollback_case
    run_optional_component_rollback_case
    run_install_rollback_helper_case
    run_tls_stage_failure_case
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
    run_apply_net_opt_command_case
    run_apply_config_command_case
    run_warp_credential_helper_case
    run_warp_credential_ensure_failure_case
    run_warp_legacy_teardown_case
    run_cert_mode_input_case
    run_change_command_case
    run_change_warp_enable_rollback_case
    run_renew_cert_command_case
    run_upgrade_command_case
    run_diagnose_command_case
    run_missing_option_value_case
    run_dispatch_case
    run_script_lock_scope_case
    run_script_lock_stale_dir_case
    run_client_cli_case
    run_install_flow_case
  )

  load_functions
  stub_side_effects
  canary_before="$(canary_snapshot | LC_ALL=C sort)"
  trap cleanup_test_sandbox EXIT

  for case_name in "${cases[@]}"; do
    run_smoke_case "${case_name}"
  done

  assert_canary_intact "${canary_before}"
  printf 'smoke ok\n'
}

main "$@"
