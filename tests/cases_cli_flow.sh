# shellcheck shell=bash

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
  show_links() {
    dispatched="show-links"
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
  sni_check_cmd() {
    dispatched="check-sni"
    dispatched_args="$*"
  }
  change_cert_mode_cmd() {
    dispatched="change-cert-mode"
    dispatched_args="$*"
  }
  repair_perms_cmd() {
    dispatched="repair-perms"
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

  run_cli_command show-links --summary
  [[ "${dispatched}" == "show-links" ]]
  [[ "${dispatched_args}" == "--summary" ]]

  run_cli_command apply-net-opt
  [[ "${dispatched}" == "apply-net-opt" ]]

  run_cli_command apply-config
  [[ "${dispatched}" == "apply-config" ]]

  run_cli_command
  [[ "${dispatched}" == "menu" ]]

  run_menu_choice recovery 3
  [[ "${dispatched}" == "uninstall" ]]

  run_menu_choice maintenance 6
  [[ "${dispatched}" == "renew-cert" ]]

  run_menu_choice network 2
  [[ "${dispatched}" == "change-warp-rules" ]]

  run_menu_choice status 2
  [[ "${dispatched}" == "diagnose" ]]

  run_menu_choice nodes s
  [[ "${dispatched}" == "show-links" ]]
  [[ "${dispatched_args}" == "--summary" ]]

  run_menu_choice maintenance 2
  [[ "${dispatched}" == "update-script" ]]

  run_menu_choice status 3
  [[ "${dispatched}" == "check-sni" ]]

  run_menu_choice network 5
  [[ "${dispatched}" == "apply-net-opt" ]]

  run_menu_choice maintenance 5
  [[ "${dispatched}" == "apply-config" ]]

  run_menu_choice maintenance 4
  [[ "${dispatched}" == "repair-perms" ]]

  local version_output=""
  version_output="$(run_cli_command version)"
  [[ "${version_output}" == "xtun.sh v${SCRIPT_VERSION}" ]]
  version_output="$(run_cli_command --version)"
  [[ "${version_output}" == "xtun.sh v${SCRIPT_VERSION}" ]]
  version_output="$(run_cli_command -v)"
  [[ "${version_output}" == "xtun.sh v${SCRIPT_VERSION}" ]]
}

run_readonly_and_error_boundary_case() {
  local workdir=""
  local output=""

  load_functions
  stub_side_effects
  workdir="$(mktemp -d)"

  OP_LOG_DIR="${workdir}/logs"
  OP_LOG_FILE="${OP_LOG_DIR}/operations.log"
  BACKUP_ROOT="${workdir}/backups"
  INSTALL_DRAFT_FILE="${workdir}/install-draft.env"
  SCRIPT_LOCK_FILE="${workdir}/xtun.lock"

  load_dashboard_context() { printf 'restart-context-executed\n'; }
  restart_service_if_present() { printf 'restart-service-executed\n'; }
  need_root() { printf 'root-check-executed\n'; }

  output="$(run_cli_command restart --help)"
  [[ "${output}" == *'用法:'* ]]
  [[ "${output}" != *'restart-context-executed'* ]]

  output="$(run_cli_command repair-perms --help)"
  [[ "${output}" == *'用法:'* ]]

  output="$(run_cli_command update-script --help)"
  [[ "${output}" == *'用法:'* ]]
  [[ "${output}" != *'root-check-executed'* ]]

  # install --help 走真实的 install_cmd：解析发生在 root 检查、备份和草稿之前
  output="$(run_cli_command install --help)"
  [[ "${output}" == *'用法:'* ]]
  [[ "${output}" != *'root-check-executed'* ]]

  if output="$(run_cli_command install --bogus 2>&1)"; then
    return 1
  fi
  [[ "${output}" == *'未知的 install 参数：--bogus'* ]]

  if output="$(run_cli_command install --server-ip 2>&1)"; then
    return 1
  fi
  [[ "${output}" == *'参数 --server-ip 需要值。'* ]]

  if output="$(run_cli_command status --bogus 2>&1)"; then
    return 1
  fi
  [[ "${output}" == *'未知的 status 参数：--bogus'* ]]

  assert_absent_path "${OP_LOG_DIR}" '帮助/参数错误不应创建操作日志'
  assert_absent_path "${BACKUP_ROOT}" '帮助/参数错误不应创建备份'
  assert_absent_path "${INSTALL_DRAFT_FILE}" '帮助/参数错误不应创建安装草稿'
  assert_absent_path "${SCRIPT_LOCK_FILE}" '帮助/参数错误不应创建锁文件'
}

run_input_eof_cancel_case() {
  local workdir=""
  local output=""
  local answer="sentinel"
  local secret="sentinel"
  local multiline="sentinel"

  load_functions
  stub_side_effects
  workdir="$(mktemp -d)"
  OP_LOG_DIR="${workdir}/logs"
  OP_LOG_FILE="${OP_LOG_DIR}/operations.log"

  if output="$(prompt_yes_no answer '确认继续' 'yes' </dev/null 2>&1)"; then
    return 1
  fi
  [[ "${output}" == *'输入已结束，已取消当前操作。'* ]]
  [[ "${answer}" == 'sentinel' ]]

  if output="$(prompt_with_default answer '必填输入' 'default' </dev/null 2>&1)"; then
    return 1
  fi
  [[ "${output}" == *'输入已结束，已取消当前操作。'* ]]
  [[ "${answer}" == 'sentinel' ]]

  if output="$(prompt_secret secret '密钥' </dev/null 2>&1)"; then
    return 1
  fi
  [[ "${output}" == *'输入已结束，已取消当前操作。'* ]]
  [[ "${secret}" == 'sentinel' ]]

  if output="$(prompt_multiline_value multiline '多行内容' </dev/null 2>&1)"; then
    return 1
  fi
  [[ "${output}" == *'输入已结束，已取消当前操作。'* ]]
  [[ "${multiline}" == 'sentinel' ]]
}

run_main_menu_eof_case() {
  local output=""
  local menu_count=""

  load_functions
  stub_side_effects
  show_dashboard_brief() { :; }
  show_main_menu() { printf 'MENU\n'; }

  output="$(run_cli_command menu </dev/null)"
  [[ "${output}" == 'MENU' ]]

  output="$(printf 'bad\n\n0\n' | run_cli_command menu 2>&1)"
  [[ "${output}" == *'未知的菜单项：bad'* ]]
  [[ "${output}" == *'菜单操作失败，返回可用菜单'* ]]
  menu_count="$(grep -c '^MENU$' <<< "${output}")"
  [[ "${menu_count}" == '2' ]]
}

run_menu_pty_case() {
  local workdir=""
  local script_file=""
  local output=""

  # PTY 路径只有在有 script(1) 的环境里才谈得上；没有就跳过，不假装验证过。
  command -v script >/dev/null 2>&1 || return 0

  load_functions
  stub_side_effects
  workdir="$(mktemp -d)"
  script_file="${workdir}/menu.sh"

  OP_LOG_DIR="${workdir}/logs"
  OP_LOG_FILE="${OP_LOG_DIR}/operations.log"
  BACKUP_ROOT="${workdir}/backups"
  INSTALL_DRAFT_FILE="${workdir}/install-draft.env"
  SCRIPT_LOCK_FILE="${workdir}/xtun.lock"

  cat > "${script_file}" <<EOF
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
OP_LOG_DIR="${workdir}/logs"
OP_LOG_FILE="${OP_LOG_DIR}/operations.log"
BACKUP_ROOT="${workdir}/backups"
INSTALL_DRAFT_FILE="${workdir}/install-draft.env"
SCRIPT_LOCK_FILE="${workdir}/xtun.lock"
show_dashboard_brief() { :; }
show_main_menu() { printf 'MENU\n'; }
pause_after_menu_action() { printf 'PAUSED\n'; }
main_menu
EOF

  output="$(printf 'bad\n0\n' | script -qec "bash ${script_file}" /dev/null 2>&1)" || return 1
  [[ "${output}" == *'MENU'* ]]
  [[ "${output}" == *'未知的菜单项：bad'* ]]
  # 看菜单再退出：不抢锁、不建备份、不写操作日志、不留草稿
  assert_absent_path "${SCRIPT_LOCK_FILE}" 'PTY 菜单不应创建锁文件'
  assert_absent_path "${OP_LOG_DIR}" 'PTY 菜单不应创建操作日志'
  assert_absent_path "${BACKUP_ROOT}" 'PTY 菜单不应创建备份目录'
  assert_absent_path "${INSTALL_DRAFT_FILE}" 'PTY 菜单不应创建安装草稿'
}

run_bootstrap_readonly_no_persist_case() {
  local workdir=""
  local single_file=""
  local self_install_dir=""
  local self_command_path=""
  local output=""

  workdir="$(mktemp -d)"
  single_file="${workdir}/xtun.sh"
  self_install_dir="${workdir}/self-install"
  self_command_path="${workdir}/bin/xtun"
  cp "${ROOT_DIR}/xtun.sh" "${single_file}"

  output="$(XTUN_SELF_INSTALL_DIR="${self_install_dir}" XTUN_SELF_COMMAND_PATH="${self_command_path}" bash "${single_file}" help)"
  [[ "${output}" == *'常用命令:'* ]]
  [[ "${output}" == *'install'* ]]

  output="$(XTUN_SELF_INSTALL_DIR="${self_install_dir}" XTUN_SELF_COMMAND_PATH="${self_command_path}" XTUN_BOOTSTRAP_ROOT="${ROOT_DIR}" bash "${single_file}" install --help)"
  [[ "${output}" == *'用法:'* ]]
  [[ "${output}" == *'--server-ip VALUE'* ]]

  if output="$(XTUN_SELF_INSTALL_DIR="${self_install_dir}" XTUN_SELF_COMMAND_PATH="${self_command_path}" bash "${single_file}" definitely-not-a-command 2>&1)"; then
    return 1
  fi
  [[ "${output}" == *'未知命令：definitely-not-a-command'* ]]

  assert_absent_path "${self_install_dir}" '只读入口不应持久安装 bundle'
  assert_absent_path "${self_command_path}" '只读入口不应创建管理命令'
}

dispatch_matrix_commands() {
  printf '%s\n' \
    install update-script upgrade check-sni change-uuid change-sni change-path change-h3 \
    change-warp change-warp-rules change-cert-mode renew-cert uninstall \
    show-links diagnose status restart repair-perms apply-config apply-net-opt
}

run_dispatch_help_matrix_case() {
  local workdir=""
  local command_name=""
  local output=""

  load_functions
  stub_side_effects
  workdir="$(mktemp -d)"

  OP_LOG_DIR="${workdir}/logs"
  OP_LOG_FILE="${OP_LOG_DIR}/operations.log"
  BACKUP_ROOT="${workdir}/backups"
  INSTALL_DRAFT_FILE="${workdir}/install-draft.env"
  SCRIPT_LOCK_FILE="${workdir}/xtun.lock"
  SCRIPT_LOCK_HELD=0
  SCRIPT_LOCK_DIR=""

  # 帮助和参数错误必须停在解析阶段：这些桩一旦被调到就说明命令已经往动作里走了。
  need_root() { printf 'TRIPWIRE:need_root\n'; }
  start_backup_session() { printf 'TRIPWIRE:start_backup_session\n'; }
  begin_managed_change() { printf 'TRIPWIRE:begin_managed_change\n'; return 1; }
  load_dashboard_context() { printf 'TRIPWIRE:load_dashboard_context\n'; }
  install_draft_session_begin() { printf 'TRIPWIRE:install_draft_session_begin\n'; }
  write_install_draft_file() { printf 'TRIPWIRE:write_install_draft_file\n'; return 0; }

  for command_name in $(dispatch_matrix_commands); do
    if ! output="$(run_cli_command "${command_name}" --help 2>&1)"; then
      printf '[fail] %s --help 应当成功退出，实际输出：%s\n' "${command_name}" "${output}" >&2
      return 1
    fi
    [[ "${output}" == *'用法:'* ]] || { printf '[fail] %s --help 没有输出用法\n' "${command_name}" >&2; return 1; }
    [[ "${output}" != *'TRIPWIRE'* ]] || { printf '[fail] %s --help 进入了执行路径\n' "${command_name}" >&2; return 1; }
  done

  for command_name in help --help -h version --version -v; do
    output="$(run_cli_command "${command_name}" 2>&1)" || return 1
    [[ "${output}" != *'TRIPWIRE'* ]]
  done

  for command_name in $(dispatch_matrix_commands); do
    if output="$(run_cli_command "${command_name}" --definitely-not-an-option 2>&1)"; then
      printf '[fail] %s 的未知参数应当失败\n' "${command_name}" >&2
      return 1
    fi
    [[ "${output}" == *'未知'* ]] || { printf '[fail] %s 的未知参数报错信息不明确：%s\n' "${command_name}" "${output}" >&2; return 1; }
    [[ "${output}" != *'TRIPWIRE'* ]] || { printf '[fail] %s 的未知参数进入了执行路径\n' "${command_name}" >&2; return 1; }
  done

  # 缺值：解析必须报「需要值」，不能把下一个开关当成值吞掉
  if output="$(run_cli_command install --server-ip 2>&1)"; then
    return 1
  fi
  [[ "${output}" == *'参数 --server-ip 需要值。'* ]]

  if output="$(run_cli_command upgrade --xray-version 2>&1)"; then
    return 1
  fi
  [[ "${output}" == *'参数 --xray-version 需要值。'* ]]

  if output="$(run_cli_command check-sni --target 2>&1)"; then
    return 1
  fi
  [[ "${output}" == *'参数 --target 需要值。'* ]]

  if output="$(run_cli_command change-sni --reality-sni 2>&1)"; then
    return 1
  fi
  [[ "${output}" == *'需要值'* ]]

  assert_absent_path "${OP_LOG_DIR}" '帮助/参数错误不应创建操作日志'
  assert_absent_path "${BACKUP_ROOT}" '帮助/参数错误不应创建备份'
  assert_absent_path "${INSTALL_DRAFT_FILE}" '帮助/参数错误不应创建安装草稿'
  assert_absent_path "${SCRIPT_LOCK_FILE}" '帮助/参数错误不应创建锁文件'
  [[ "${SCRIPT_LOCK_HELD}" -eq 0 ]]
}

run_bootstrap_temp_and_installed_entry_case() {
  local workdir=""
  local tmp_root=""
  local stage=""
  local archive=""
  local single_file=""
  local bundle_copy=""
  local installed=""
  local self_install_dir=""
  local self_command_path=""
  local output=""

  workdir="$(mktemp -d)"
  tmp_root="${workdir}/tmp"
  stage="${workdir}/stage"
  archive="${workdir}/xtun.tar.gz"
  single_file="${workdir}/xtun.sh"
  bundle_copy="${workdir}/bundle"
  installed="${workdir}/installed"
  self_install_dir="${workdir}/self-install"
  self_command_path="${workdir}/bin/xtun"
  mkdir -p "${tmp_root}" "${stage}" "${bundle_copy}"
  cp "${ROOT_DIR}/xtun.sh" "${single_file}"
  # 归档按 GitHub codeload 的形态压：包里有一层顶层目录
  mkdir -p "${stage}/xtun-main"
  cp -a "${ROOT_DIR}/xtun.sh" "${ROOT_DIR}/lib" "${ROOT_DIR}/static" "${stage}/xtun-main/"
  cp -a "${ROOT_DIR}/xtun.sh" "${ROOT_DIR}/lib" "${ROOT_DIR}/static" "${bundle_copy}/"
  tar -czf "${archive}" -C "${stage}" xtun-main

  # 公开单文件入口 + 本地没有 lib/：拉取到的包只在临时目录里跑
  output="$(TMPDIR="${tmp_root}" XTUN_BOOTSTRAP_ARCHIVE_URL="file://${archive}" XTUN_SELF_INSTALL_DIR="${self_install_dir}" XTUN_SELF_COMMAND_PATH="${self_command_path}" bash "${single_file}" status --help 2>&1)"
  [[ "${output}" == *'用法:'* ]]
  [[ "${output}" == *'status'* ]]
  [[ -z "$(find "${tmp_root}" -mindepth 1 -maxdepth 1 -print -quit)" ]]
  assert_absent_path "${self_install_dir}" '临时入口不应持久安装 bundle'
  assert_absent_path "${self_command_path}" '临时入口不应创建管理命令'

  # 拉取失败时退回到已安装入口，而不是把用户丢在错误里
  mkdir -p "${installed}/lib/base" "${installed}/static/fallback"
  printf '#!/usr/bin/env bash\nprintf "INSTALLED-BUNDLE-RAN\\n"\n' > "${installed}/xtun.sh"
  printf '# helper\n' > "${installed}/lib/base/helpers.sh"
  printf '<!doctype html>\n' > "${installed}/static/fallback/index.html"
  output="$(TMPDIR="${tmp_root}" XTUN_BOOTSTRAP_ARCHIVE_URL="file://${workdir}/missing.tar.gz" XTUN_SELF_INSTALL_DIR="${installed}" bash "${single_file}" install 2>&1)" || true
  [[ "${output}" == *'INSTALLED-BUNDLE-RAN'* ]]

  # 无 root 也能求助：单文件本地入口不该碰 root 检查，也不该装任何东西
  chmod -R a+rX "${workdir}"
  chmod 0755 "${workdir}"
  if [[ "${EUID}" -eq 0 ]] && command -v setpriv >/dev/null 2>&1; then
    output="$(setpriv --reuid=65534 --regid=65534 --clear-groups env HOME="${workdir}" XTUN_SELF_INSTALL_DIR="${self_install_dir}" XTUN_SELF_COMMAND_PATH="${self_command_path}" bash "${single_file}" help 2>&1)"
    [[ "${output}" == *'常用命令:'* ]]

    output="$(setpriv --reuid=65534 --regid=65534 --clear-groups env HOME="${workdir}" XTUN_BOOTSTRAP_ROOT="${bundle_copy}" bash "${single_file}" install --help 2>&1)"
    [[ "${output}" == *'用法:'* ]]
    [[ "${output}" == *'--server-ip VALUE'* ]]
  fi

  assert_absent_path "${self_install_dir}" '只读入口不应持久安装 bundle'
  assert_absent_path "${self_command_path}" '只读入口不应创建管理命令'

  # 临时包必须原样传回子进程结果。0/1/2 是常规退出，23 是业务错误，
  # 130/143 分别来自 INT/TERM；不能被 if ! 的反转值吞掉。
  mkdir -p "${stage}/xtun-status"
  cp -a "${ROOT_DIR}/lib" "${ROOT_DIR}/static" "${stage}/xtun-status/"
  cat > "${stage}/xtun-status/xtun.sh" <<'EOF'
#!/usr/bin/env bash
case "${XTUN_TEST_STATUS:-0}" in
  130) kill -INT $$; sleep 5 ;;
  143) kill -TERM $$; sleep 5 ;;
  *) exit "${XTUN_TEST_STATUS:-0}" ;;
esac
EOF
  chmod 0755 "${stage}/xtun-status/xtun.sh"
  tar -czf "${workdir}/status.tar.gz" -C "${stage}" xtun-status
  local expected_status
  local status
  for expected_status in 0 1 2 23 130 143; do
    status=0
    TMPDIR="${tmp_root}" \
      XTUN_TEST_STATUS="${expected_status}" \
      XTUN_BOOTSTRAP_ARCHIVE_URL="file://${workdir}/status.tar.gz" \
      XTUN_SELF_INSTALL_DIR="${self_install_dir}" \
      XTUN_SELF_COMMAND_PATH="${self_command_path}" \
      bash "${single_file}" status >/dev/null 2>&1 || status=$?
    [[ "${status}" -eq "${expected_status}" ]] \
      || { printf '[fail] 临时入口应返回 %s，实际 %s\n' "${expected_status}" "${status}" >&2; return 1; }
    [[ -z "$(find "${tmp_root}" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
      || { printf '[fail] 临时入口返回 %s 后未清理临时目录\n' "${expected_status}" >&2; return 1; }
  done

  rm -rf "${workdir}"
}

run_interrupt_signal_case() {
  local workdir=""

  load_functions
  stub_side_effects
  workdir="$(mktemp -d)"

  # 后台作业默认继承被忽略的 SIGINT，直接 kill -INT 打不进去。
  # 开一个作业控制子 shell，让向导单独一个进程组，再把信号发给整组。
  (
    set -m

    local marker=""
    local script_file=""
    local child_pid=""
    local status=0
    local signal_name=""
    local expected_status=""
    local wait_step=""

    for signal_name in TERM INT; do
      case "${signal_name}" in
        TERM) expected_status=143 ;;
        INT) expected_status=130 ;;
      esac

      marker="${workdir}/draft-${signal_name}"
      script_file="${workdir}/wizard-${signal_name}.sh"
      cat > "${script_file}" <<EOF
set -Eeuo pipefail
ROOT_DIR="${ROOT_DIR}"
source <(sed '\$d' "${ROOT_DIR}/xtun.sh")
write_install_draft_file() { printf 'draft\n' >> "${marker}"; return 0; }
install_draft_session_begin
# 这个桩脚本模拟的是「已经过了最终确认、正在落盘」的阶段：确认前的中断不留草稿（D06）。
INSTALL_CONFIRMED=1
printf 'ready\n'
while true; do sleep 1; done
EOF

      bash "${script_file}" > "${workdir}/out-${signal_name}.txt" 2>&1 &
      child_pid=$!
      for wait_step in $(seq 1 100); do
        grep -q 'ready' "${workdir}/out-${signal_name}.txt" 2>/dev/null && break
        sleep 0.1
      done
      kill -s "${signal_name}" -"${child_pid}"

      status=0
      wait "${child_pid}" || status=$?
      [[ "${status}" -eq "${expected_status}" ]] \
        || { printf '[fail] %s 中断后退出码应为 %s，实际 %s\n' "${signal_name}" "${expected_status}" "${status}" >&2; return 1; }
      [[ -s "${marker}" ]] || { printf '[fail] %s 中断后没有留下草稿\n' "${signal_name}" >&2; return 1; }
    done
  )

  rm -rf "${workdir}"
}
run_install_flow_case() {
  local steps=()
  local logged=""
  local shown=0
  local shown_links_args=""
  local rolled_optional=0
  local draft_writes=0
  local draft_clears=0
  local workdir=""

  load_functions
  workdir="$(mktemp -d)"
  generation_case_setup "${workdir}"

  prepare_install_command() {
    start_backup_session
    # 真实路径里确认页在草稿写入之前；这里桩掉问答，就直接进「已确认」阶段。
    INSTALL_CONFIRMED=1
    install_draft_session_begin
    INSTALL_CONFIRMED=1
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
  rollback_optional_component_state() {
    rolled_optional=$((rolled_optional + 1))
  }
  finalize_installation() {
    steps+=("finalize")
    generation_commit
  }
  log() {
    logged+="${1}"$'\n'
  }
  log_step() {
    logged+="STEP:${1}"$'\n'
  }
  warn() {
    logged+="WARN:${1}"$'\n'
  }
  write_install_draft_file() {
    draft_writes=$((draft_writes + 1))
  }
  clear_install_draft_file() {
    draft_clears=$((draft_clears + 1))
  }
  show_links() {
    shown=1
    shown_links_args="$*"
  }

  install_cmd --non-interactive --disable-warp

  [[ "${steps[*]}" == "prepare:--non-interactive --disable-warp runtime files optional finalize" ]]
  [[ "${shown}" -eq 1 ]]
  [[ "${shown_links_args}" == "--summary" ]]
  [[ "${draft_writes}" -eq 0 ]]
  [[ "${draft_clears}" -eq 1 ]]
  printf '%s' "${logged}" | grep -q 'STEP:准备安装参数与运行环境。'
  printf '%s' "${logged}" | grep -q 'STEP:校验并启动托管服务。'
  printf '%s' "${logged}" | grep -q '部署完成。'
  printf '%s' "${logged}" | grep -q '管理命令：'

  # 跳过 / 忽略 SNI 预检：装完要再把这条事实说一遍，并给出公开的复检入口（D09）
  steps=()
  logged=""
  shown=0
  draft_writes=0
  draft_clears=0
  SNI_PREFLIGHT_IGNORED=1
  install_cmd --non-interactive --disable-warp
  printf '%s' "${logged}" | grep -q 'WARN:未通过：REALITY 目标域名预检失败后选择忽略'
  printf '%s' "${logged}" | grep -q 'xtun check-sni'
  SNI_PREFLIGHT_IGNORED=0

  steps=()
  logged=""
  shown=0
  draft_writes=0
  draft_clears=0
  SNI_PREFLIGHT_SKIPPED=1
  install_cmd --non-interactive --disable-warp
  printf '%s' "${logged}" | grep -q 'WARN:未验证：REALITY 目标域名预检已跳过'
  SNI_PREFLIGHT_SKIPPED=0

  # 没有跳过 / 忽略时不多说一句
  steps=()
  logged=""
  shown=0
  draft_writes=0
  draft_clears=0
  install_cmd --non-interactive --disable-warp
  if printf '%s' "${logged}" | grep -q 'REALITY 目标域名预检'; then
    return 1
  fi

  steps=()
  logged=""
  shown=0
  rolled_optional=0
  draft_writes=0
  draft_clears=0
  install_optional_components() {
    return 1
  }

  if install_cmd --non-interactive; then
    return 1
  fi
  # 可选组件和其它托管文件使用同一代快照，不能再由旧 helper 提前覆盖服务状态。
  [[ "${rolled_optional}" -eq 0 ]]
  [[ "${GENERATION_ACTIVE}" == "no" ]]
  [[ " ${GENERATION_PATHS[*]} " == *" ${STATE_FILE} "* ]]
  [[ " ${GENERATION_PATHS[*]} " == *" ${QR_OUTPUT_DIR} "* ]]
  printf '%s' "${logged}" | grep -q '安装可选组件失败：已回退到操作前的文件'
  printf '%s' "${logged}" | grep -q '部署完成。' && return 1
  # 失败的动作不留未完成操作标记，也不消耗备份保留名额。
  [[ ! -e "${PENDING_OP_FILE}" ]]
  [[ ! -e "${BACKUP_DIR}/completed" ]]
  [[ "${draft_writes}" -eq 1 ]]
  [[ "${draft_clears}" -eq 0 ]]

  rm -rf "${workdir}"
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

  # 只查看时的消息不能落盘：帮助、诊断、警告都不该在 /var/log/xtun 里留痕
  output="$(log "查看测试")"
  [[ "${output}" == *"[信息] 查看测试"* ]]
  [[ ! -e "${OP_LOG_FILE}" ]]

  # 真正开始改动之后才写操作日志（全局日志 + 会话日志）
  acquire_script_lock() { SCRIPT_LOCK_HELD=1; }
  begin_mutation
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
  show_links() { :; }
  change_sni_cmd() { :; }
  main_menu() { :; }

  SCRIPT_LOCK_HELD=0
  SCRIPT_LOCK_DIR=""

  # 只读命令不抢锁：菜单停在提示符上时，另一个 xtun 仍能改配置
  run_cli_command status
  run_cli_command diagnose
  run_cli_command show-links
  run_cli_command version >/dev/null
  run_cli_command help >/dev/null
  run_cli_command
  [[ "${acquired}" -eq 0 ]]

  # 变更命令必须成对加锁 / 解锁：锁在真正开始改动的那一刻才拿
  # （begin_mutation → start_backup_session），不是进命令就抢。
  change_sni_cmd() { begin_mutation; }
  run_cli_command change-sni --reality-sni a.example.com
  [[ "${acquired}" -eq 1 ]]
  [[ "${released}" -eq 1 ]]
  [[ "${SCRIPT_LOCK_HELD}" -eq 0 ]]

  # 命令失败也要解锁，否则同一进程内的后续命令拿不到锁
  change_sni_cmd() { begin_mutation; return 3; }
  if run_cli_command change-sni; then
    return 1
  fi
  [[ "${acquired}" -eq 2 ]]
  [[ "${released}" -eq 2 ]]
  [[ "${SCRIPT_LOCK_HELD}" -eq 0 ]]

  # 帮助/参数错误停在解析阶段，连锁都不该碰：真正实现由
  # run_dispatch_help_matrix_case 用真实命令端到端钉住。
  change_sni_cmd() { return 0; }
  run_cli_command change-sni --help >/dev/null
  [[ "${acquired}" -eq 2 ]]
}

run_script_lock_stderr_case() {
  local workdir=""

  workdir="$(mktemp -d)"
  (
    load_functions
    SCRIPT_LOCK_FILE="${workdir}/lock"
    acquire_script_lock
    release_script_lock
    [[ "${SCRIPT_LOCK_HELD}" -eq 0 ]]
    printf 'first-release-visible\n' >&2
    acquire_script_lock
    release_script_lock
    printf 'second-release-visible\n' >&2
  ) 2> "${workdir}/stderr.log"
  assert_contains 'first-release-visible' "${workdir}/stderr.log"
  assert_contains 'second-release-visible' "${workdir}/stderr.log"
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
