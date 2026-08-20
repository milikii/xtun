run_missing_option_value_case() {
  local output=""

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
parse_install_args --server-ip
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q '参数 --server-ip 需要值。'

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
change_uuid_cmd --reality-uuid
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q '参数 --reality-uuid 需要值。'

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
change_warp_cmd --bogus
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q '未知的 change-warp 参数：--bogus'

  if output="$(bash <<EOF 2>&1
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
change_cert_mode_cmd --bogus
EOF
)"; then
    return 1
  fi
  printf '%s' "${output}" | grep -q '未知的 change-cert-mode 参数：--bogus'
}

run_dispatch_case() {
  local dispatched=""
  local dispatched_args=""

  install_cmd() {
    dispatched="install"
    dispatched_args="$*"
  }
  update_script_cmd() {
    dispatched="update-script"
    dispatched_args="$*"
  }
  status_cmd() {
    dispatched="status"
    dispatched_args="$*"
  }
  diagnose_cmd() {
    dispatched="diagnose"
    dispatched_args="$*"
  }
  uninstall_cmd() {
    dispatched="uninstall"
    dispatched_args="$*"
  }
  change_warp_rules_cmd() {
    dispatched="change-warp-rules"
    dispatched_args="$*"
  }
  add_client_cmd() {
    dispatched="add-client"
    dispatched_args="$*"
  }
  list_clients_cmd() {
    dispatched="list-clients"
    dispatched_args="$*"
  }
  apply_net_opt_cmd() {
    dispatched="apply-net-opt"
    dispatched_args="$*"
  }
  apply_config_cmd() {
    dispatched="apply-config"
    dispatched_args="$*"
  }
  main_menu() {
    dispatched="menu"
    dispatched_args="$*"
  }
  renew_cert_cmd() {
    dispatched="renew-cert"
    dispatched_args="$*"
  }

  run_cli_command install --non-interactive --disable-warp
  [[ "${dispatched}" == "install" ]]
  [[ "${dispatched_args}" == "--non-interactive --disable-warp" ]]

  run_cli_command update-script
  [[ "${dispatched}" == "update-script" ]]

  run_cli_command status --raw
  [[ "${dispatched}" == "status" ]]
  [[ "${dispatched_args}" == "--raw" ]]

  run_cli_command diagnose
  [[ "${dispatched}" == "diagnose" ]]

  run_cli_command add-client phone
  [[ "${dispatched}" == "add-client" ]]
  [[ "${dispatched_args}" == "phone" ]]

  run_cli_command list-clients
  [[ "${dispatched}" == "list-clients" ]]

  run_cli_command apply-net-opt
  [[ "${dispatched}" == "apply-net-opt" ]]

  run_cli_command apply-config
  [[ "${dispatched}" == "apply-config" ]]

  run_cli_command
  [[ "${dispatched}" == "menu" ]]

  run_menu_choice 17
  [[ "${dispatched}" == "uninstall" ]]

  run_menu_choice 18
  [[ "${dispatched}" == "uninstall" ]]
  [[ "${dispatched_args}" == "--purge" ]]

  run_menu_choice 19
  [[ "${dispatched}" == "status" ]]
  [[ "${dispatched_args}" == "--raw" ]]

  run_menu_choice 15
  [[ "${dispatched}" == "renew-cert" ]]

  run_menu_choice 13
  [[ "${dispatched}" == "change-warp-rules" ]]

  run_menu_choice 3
  [[ "${dispatched}" == "diagnose" ]]

  run_menu_choice 6
  [[ "${dispatched}" == "update-script" ]]

  run_menu_choice 21
  [[ "${dispatched}" == "add-client" ]]

  run_menu_choice 22
  [[ "${dispatched}" == "list-clients" ]]

  run_menu_choice 23
  [[ "${dispatched}" == "apply-net-opt" ]]

  run_menu_choice 24
  [[ "${dispatched}" == "apply-config" ]]
  local version_output=""
  version_output="$(run_cli_command version)"
  [[ "${version_output}" == "xtun.sh v${SCRIPT_VERSION}" ]]
  version_output="$(run_cli_command --version)"
  [[ "${version_output}" == "xtun.sh v${SCRIPT_VERSION}" ]]
  version_output="$(run_cli_command -v)"
  [[ "${version_output}" == "xtun.sh v${SCRIPT_VERSION}" ]]
}

# show-links --client B 重新生成失败时，如果不停下来，下面那句 cat 会把磁盘上
# 上一次留下的输出文件原样打出来——用户点名要 B，拿到的是 A 的 UUID 和链接，
# 而且从输出上完全看不出哪里不对。
run_show_links_stale_output_case() {
  local status=0
  local output=""
  local workdir=""

  workdir="$(mktemp -d)"
  OUTPUT_FILE="${workdir}/node-links.txt"
  printf 'client=laptop\nuuid=11111111-1111-1111-1111-111111111111\n' > "${OUTPUT_FILE}"

  load_current_install_context() { :; }
  node_client_exists() { :; }
  write_output_file() { return 1; }
  render_output_file_qr() { :; }
  log() { :; }
  log_step() { :; }
  log_success() { :; }

  set +e
  output="$(show_links --client phone 2>/dev/null)"
  status=$?
  set -e

  [[ "${status}" -ne 0 ]]
  # 关键断言：上一个客户端的凭据一个字都不能漏出去。
  [[ "${output}" != *"laptop"* ]]
  [[ "${output}" != *"11111111-1111-1111-1111-111111111111"* ]]

  rm -rf "${workdir}"
  load_functions
}

run_client_cli_case() {
  local applied=0
  local backup_marker=""
  local shown_args=""
  local output=""
  local workdir=""
  local write_marker=""
  local original_show_links_fn=""
  local selection=""
  local stderr_file=""
  local write_backup_marker=""

  workdir="$(mktemp -d)"
  backup_marker="${workdir}/backup-sessions.txt"
  write_marker="${workdir}/write-client.txt"
  write_backup_marker="${workdir}/write-backup-count.txt"
  stderr_file="${workdir}/client-select.stderr"
  prepare_workspace "${workdir}"
  printf '0' > "${backup_marker}"
  original_show_links_fn="$(capture_function_definition show_links)"

  need_root() { :; }
  start_backup_session() {
    local backup_sessions=""

    backup_sessions="$(cat "${backup_marker}")"
    backup_sessions=$((backup_sessions + 1))
    printf '%s' "${backup_sessions}" > "${backup_marker}"
    BACKUP_DIR="${workdir}/backup-${backup_sessions}"
  }
  log_step() { :; }
  log_success() { :; }
  log() { :; }
  load_current_install_context() {
    REALITY_UUID="11111111-1111-1111-1111-111111111111"
    XHTTP_UUID="22222222-2222-2222-2222-222222222222"
    NODE_CLIENTS_TEXT=""
  }
  ensure_xray_user() { :; }
  apply_xray_only_managed_update() {
    applied=$((applied + 1))
  }
  show_links() {
    shown_args="$*"
  }

  add_client_cmd phone \
    --reality-uuid 33333333-3333-3333-3333-333333333333 \
    --xhttp-uuid 44444444-4444-4444-4444-444444444444

  [[ "${applied}" -eq 1 ]]
  [[ "${OUTPUT_CLIENT_NAME}" == "phone" ]]
  [[ "${NODE_CLIENTS_TEXT}" == "phone|33333333-3333-3333-3333-333333333333|44444444-4444-4444-4444-444444444444" ]]
  [[ "${shown_args}" == "--client phone" ]]
  [[ "$(cat "${backup_marker}")" == "1" ]]
  selection="$(printf '2\n' | prompt_node_client_selection "选择客户端" 2>"${stderr_file}")"
  [[ "${selection}" == "phone" ]]
  grep -q '可用客户端:' "${stderr_file}"

  restore_function_definition "${original_show_links_fn}"
  load_current_install_context() {
    REALITY_UUID="11111111-1111-1111-1111-111111111111"
    XHTTP_UUID="22222222-2222-2222-2222-222222222222"
    NODE_CLIENTS_TEXT="phone|33333333-3333-3333-3333-333333333333|44444444-4444-4444-4444-444444444444"
  }
  write_output_file() {
    printf '%s' "$(cat "${backup_marker}")" > "${write_backup_marker}"
    printf '%s' "${1}" > "${write_marker}"
    printf 'client=%s\n' "${1}" > "${OUTPUT_FILE}"
  }

  output="$(show_links --client phone)"
  [[ "$(cat "${write_marker}")" == "phone" ]]
  [[ "${output}" == "client=phone" ]]
  # show-links 只是按状态重新生成输出文件，不该再开一次备份会话挤掉真正的变更备份
  [[ "$(cat "${write_backup_marker}")" == "1" ]]
  [[ "$(cat "${backup_marker}")" == "1" ]]
}

run_install_flow_case() {
  local steps=()
  local logged=""
  local shown=0
  local rolled_runtime=0
  local rolled_optional=0
  local rolled_install_runtime=0
  local draft_writes=0
  local draft_clears=0

  load_functions
  stub_side_effects

  prepare_install_command() {
    BACKUP_DIR="/tmp/install-backup"
    install_draft_session_begin
    steps+=("prepare:$*")
  }
  install_xray_runtime() {
    steps+=("runtime")
  }
  write_install_managed_files() {
    steps+=("files")
  }
  install_optional_components() {
    steps+=("optional")
  }
  rollback_managed_runtime_state() {
    rolled_runtime=$((rolled_runtime + 1))
  }
  rollback_install_runtime_state() {
    rolled_install_runtime=$((rolled_install_runtime + 1))
  }
  rollback_optional_component_state() {
    rolled_optional=$((rolled_optional + 1))
  }
  finalize_installation() {
    steps+=("finalize")
  }
  log() {
    logged+="${1}"$'\n'
  }
  log_step() {
    logged+="STEP:${1}"$'\n'
  }
  write_install_draft_file() {
    draft_writes=$((draft_writes + 1))
  }
  clear_install_draft_file() {
    draft_clears=$((draft_clears + 1))
  }
  show_links() {
    shown=1
  }

  install_cmd --non-interactive --disable-warp

  [[ "${steps[*]}" == "prepare:--non-interactive --disable-warp runtime files optional finalize" ]]
  [[ "${shown}" -eq 1 ]]
  [[ "${draft_writes}" -eq 0 ]]
  [[ "${draft_clears}" -eq 1 ]]
  printf '%s' "${logged}" | grep -q 'STEP:准备安装参数与运行环境。'
  printf '%s' "${logged}" | grep -q 'STEP:校验并启动托管服务。'
  printf '%s' "${logged}" | grep -q '部署完成。'
  printf '%s' "${logged}" | grep -q '管理命令：'

  steps=()
  logged=""
  shown=0
  rolled_runtime=0
  rolled_optional=0
  rolled_install_runtime=0
  draft_writes=0
  draft_clears=0
  install_optional_components() {
    return 1
  }

  if install_cmd --non-interactive; then
    return 1
  fi
  [[ "${rolled_runtime}" -eq 1 ]]
  [[ "${rolled_optional}" -eq 1 ]]
  [[ "${rolled_install_runtime}" -eq 1 ]]
  [[ "${draft_writes}" -eq 1 ]]
  [[ "${draft_clears}" -eq 0 ]]
}

run_logging_case() {
  local workdir=""
  local output=""

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  OP_LOG_DIR="${workdir}/logs"
  OP_LOG_FILE="${OP_LOG_DIR}/operations.log"
  SESSION_LOG_FILE="${workdir}/session.log"

  output="$(log "日志测试")"
  [[ "${output}" == *"[信息] 日志测试"* ]]
  grep -q '日志测试' "${OP_LOG_FILE}"
  grep -q '日志测试' "${SESSION_LOG_FILE}"
}

run_script_lock_scope_case() {
  local acquired=0
  local released=0

  load_functions
  stub_side_effects

  acquire_script_lock() {
    acquired=$((acquired + 1))
    SCRIPT_LOCK_HELD=1
  }
  release_script_lock() {
    released=$((released + 1))
    SCRIPT_LOCK_HELD=0
  }

  status_cmd() { :; }
  diagnose_cmd() { :; }
  list_clients_cmd() { :; }
  show_links() { :; }
  change_sni_cmd() { :; }
  main_menu() { :; }

  SCRIPT_LOCK_HELD=0
  SCRIPT_LOCK_DIR=""

  # 只读命令不抢锁：菜单停在提示符上时，另一个 xtun 仍能改配置
  run_cli_command status
  run_cli_command diagnose
  run_cli_command list-clients
  run_cli_command show-links
  run_cli_command version >/dev/null
  run_cli_command help >/dev/null
  run_cli_command
  [[ "${acquired}" -eq 0 ]]

  # 写命令必须成对加锁 / 解锁
  run_cli_command change-sni --reality-sni a.example.com
  [[ "${acquired}" -eq 1 ]]
  [[ "${released}" -eq 1 ]]
  [[ "${SCRIPT_LOCK_HELD}" -eq 0 ]]

  # show-links --client 会重写输出与订阅文件，算写命令
  run_cli_command show-links --client phone
  [[ "${acquired}" -eq 2 ]]
  run_cli_command show-links --client=phone
  [[ "${acquired}" -eq 3 ]]

  # 命令失败也要解锁，否则同一进程内的后续命令拿不到锁
  change_sni_cmd() { return 3; }
  if run_cli_command change-sni; then
    return 1
  fi
  [[ "${acquired}" -eq 4 ]]
  [[ "${released}" -eq 4 ]]
  [[ "${SCRIPT_LOCK_HELD}" -eq 0 ]]
}

run_script_lock_stale_dir_case() {
  local workdir=""
  local lock_dir=""
  local dead_pid=""

  load_functions
  stub_side_effects

  workdir="$(mktemp -d)"
  lock_dir="${workdir}/xtun.lock.d"
  dead_pid="$(bash -c 'echo $$')"
  while kill -0 "${dead_pid}" 2>/dev/null; do
    dead_pid="$(bash -c 'echo $$')"
  done

  SCRIPT_LOCK_HELD=0
  SCRIPT_LOCK_DIR=""

  # 陈旧锁：目录还在但持有者已经消失（EXIT trap 被 install 流程覆盖时就是这样）
  mkdir "${lock_dir}"
  printf '%s\n' "${dead_pid}" > "${lock_dir}/pid"
  acquire_script_lock_dir "${lock_dir}"
  [[ "${SCRIPT_LOCK_HELD}" -eq 1 ]]
  [[ "${SCRIPT_LOCK_DIR}" == "${lock_dir}" ]]
  [[ "$(cat "${lock_dir}/pid")" == "$$" ]]

  release_script_lock
  [[ "${SCRIPT_LOCK_HELD}" -eq 0 ]]
  [[ ! -d "${lock_dir}" ]]

  # 持有者还活着时不能抢锁
  mkdir "${lock_dir}"
  printf '%s\n' "$$" > "${lock_dir}/pid"
  if acquire_script_lock_dir "${lock_dir}"; then
    return 1
  fi
  [[ "${SCRIPT_LOCK_HELD}" -eq 0 ]]

  rm -rf "${workdir}"
}
