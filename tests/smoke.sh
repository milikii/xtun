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

main() {
  local case_name=""
  local -a cases=(
    run_warp_enabled_case
    run_multi_client_config_output_case
    run_warp_disabled_case
    run_warp_rules_file_case
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
    run_managed_apply_case
    run_managed_rollback_case
    run_optional_component_rollback_case
    run_install_rollback_helper_case
    run_tls_stage_failure_case
    run_warp_xml_escape_case
    run_warp_health_monitor_case
    run_restart_optional_service_case
    run_change_helper_case
    run_install_parse_case
    run_install_prepare_preserves_ech_flag_case
    run_sensitive_option_reject_case
    run_preflight_token_verify_case
    run_preflight_domain_resolution_warning_case
    run_warp_rule_normalize_case
    run_optional_component_skip_case
    run_warp_repo_file_mode_case
    run_install_warp_failure_case
    run_install_warp_retry_daemon_ready_case
    run_install_warp_retry_exhausted_case
    run_cert_mode_input_case
    run_change_command_case
    run_change_warp_enable_rollback_case
    run_renew_cert_command_case
    run_upgrade_command_case
    run_diagnose_command_case
    run_missing_option_value_case
    run_dispatch_case
    run_client_cli_case
    run_install_flow_case
  )

  load_functions
  stub_side_effects

  for case_name in "${cases[@]}"; do
    run_smoke_case "${case_name}"
  done

  printf 'smoke ok\n'
}

main "$@"
