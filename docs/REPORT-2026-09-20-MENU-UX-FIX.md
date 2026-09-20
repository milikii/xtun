# 2026-09-20 菜单交互修复记录（SNI 检查死循环 / 双栈入口 / 脚本自升级）

> 记录日期：2026-09-20。问题由操作者在实机操作中报告，本文只记录复现路径、根因、修复与自动化验证；**没有**在真实设备上复测修复后的交互，复测仍待进行。相关：[设备首轮报告](REPORT-2026-09-20-DEVICE-FIRST-ROUND.md)、[决策 D05/D06](DECISIONS-UX-RELIABILITY.md#d05)。

## 1. 操作者报告

两份原始反馈（已去掉与本问题无关的面板输出）：

1. 在**未安装**的机器上选主菜单 `3. 检查 REALITY SNI`，没有出现域名输入，只得到：

   ```text
   [错误] 请指定要检查的域名。
   [警告] 菜单操作失败，返回可用菜单；如有未完成动作，请运行 xtun recover。

   按回车继续...
   ```

   回车继续后回到同一菜单；在 `请选择:` 处输入域名又得到「未知的菜单项」。用户被困在「选 3 → 报错 → 回车 → 再选 3」的循环里。

2. 全新安装基础问答只打印一句：

   ```text
   [信息] IPv6 直连：新装默认关闭；需要双栈时在确认页输入 advanced（选项 1）。
   ```

   需要双栈的操作者找不到「直接开启」的入口，只能记住一个隐藏关键词 `advanced`。

3. 维护者追加需求：主菜单要有可直接选择的「升级脚本」入口，通过交互把脚本自身升级到最新版；并把声明版本从 `1.1.0` 提升到 `1.1.1`。

## 2. 根因

1. `lib/cli/sni.sh` 的 `sni_check_cmd` 只用已保存的 `REALITY_SNI` 兜底；没有 state（或 state 里没有 SNI）时直接 `die "请指定要检查的域名。"`。菜单入口 `run_menu_choice fresh:3|status:3` 走的是无参数调用，于是必然走到这条 die；而「按回车继续」只吞掉一行输入，并不接收域名。

2. IPv6 双栈按 D05 默认关闭，启用入口只在确认页的 `advanced` 高级项（选项 1）。日志把启用方式写成「输入 advanced」，对不熟悉该关键词的用户等于没有入口。

3. 脚本自升级逻辑（`update-script`：下载最新 bundle、校验、确认、失败恢复）已经存在，但只挂在已安装菜单的「4 升级与维护 → 2」，未安装菜单完全没有入口，主菜单也没有一级可见项。

## 3. 修复

| 位置 | 改动 |
| --- | --- |
| `lib/cli/sni.sh` | 没有已保存域名时交互询问「要检查的域名」，空输入继续追问；现场输入的域名按显式域名使用自己的 `域名:443` 目标（D09）。`NON_INTERACTIVE=1` 仍然直接失败，不把「缺域名」变成挂起等待输入。 |
| `lib/cli/sni.sh` | 报告文案更直白：头部点明「伪装 SNI」与「回落目标」并给出一行 PASS/WARN/未验证/FAIL 判定说明；跨主机跳转的 FAIL 说清为什么要主机名一致、应改成哪个域名；后量子项标注「观察项，不阻断安装」；结论给出可执行的下一步命令。 |
| `lib/cli/core.sh` | 菜单入口 `fresh:3` / `status:3` 改走 `menu_check_sni`：`check-sni` 的退出码 2（预检不通过）是检查结论，不再被渲染成「菜单操作失败……请运行 xtun recover」；die=1 与取消=130 照常透传。CLI 的退出码语义不变。 |
| `lib/install/input.sh` | 新增 `install_prompt_dual_stack`：基础问答里直接问「是否启用 IPv6 直连双栈（生成节点 6/7）？」。默认关闭（回车不会多出节点 6/7）；选 `y` 才追问地址，地址留空或非法会当场重问（`ensure_server_ip6_required`），不会静默退回关闭；已有地址作为默认值沿用。`--server-ip6` / `--no-ipv6` / state / 草稿的显式选择仍然优先。 |
| `lib/install/input.sh` | `normalize_yes_no_value` 补齐 `on/off/1/0/true/false`：这些拼写本来就是 `prompt_yes_no` 接受的输入，之前走到规范化反而会被判非法并终止安装。 |
| `lib/install/input.sh` | 高级项菜单与逐项问答补上「是什么、有什么用」：xpadding、ECH、H3 直连各一句；网络优化写明当前内核即可开 BBR+fq 与 sysctl/qdisc、第三方内核是可选项；确认页提示改为「输入 advanced 进入高级选项；输入 back 改地址/域名/证书」，非法输入的回告同步改写。 |
| `lib/cli/core.sh` | 主菜单新增一级「升级脚本」：已安装菜单 `7`、未安装菜单 `5`，都落到 `run_menu_choice fresh:5` → 现有 `xtun update-script`（下载 GitHub `main` 最新 bundle、校验、确认后安装，失败走同代恢复）。已安装的「升级与维护 → 更新脚本」保留。 |
| `lib/install/input.sh` | 高级项 3：启用 xpadding 后不再追问 key/Header/placement/method，直接套用默认值并打印生效参数（要自定义走 `--xhttp-xpadding-*`）；`prompt_xhttp_xpadding_settings` 随之删除。 |
| `lib/base/input.sh` | `prompt_yes_no` / `prompt_with_default` / `prompt_secret` 的读取目标改成带前缀的内部变量：调用方变量名恰好是 `answer` 时不再被函数内同名局部变量遮蔽（高级项 H3 回答 `n` 曾因此报「H3 只能是 yes 或 no」）。 |
| `lib/install/input.sh` | `install_dependency_probe_specs` 在 `CERT_MODE=acme-http` 时追加 `socat`：确认前的只读检查会列出它，最小依赖阶段随缺包一起安装，不再等到深预检才失败。 |
| `lib/install/input.sh` | `prompt_warp_settings` 选「自动注册」时改为 `return 0`，调用方 `|| return 1` 显式传播：以前无参 `return` 会把 `[[ … == yes ]]` 的假值当状态返回 1，恢复草稿/重建时已开 WARP 的安装在这句问答后静默失败。 |
| `xtun.sh` | `SCRIPT_VERSION` 由 `1.1.0` 提升为 `1.1.1`；state schema 与参数修订不变。 |

`advanced` 入口与其中的 IPv6 选项继续保留，作为另一条等价路径。

## 4. 决策与预算影响

- **D05**：IPv6 仍然「默认关闭」，只是启用方式从「高级项」改为「基础问答直接询问」。回车行为不变（不会自动生成节点 6/7）。
- **D06**：干净环境 + 已有证书路径的必要输入由 8 次变为 9 次（多出的一次就是双栈开关）。这偏离 W05 记录的 8 次目标；D06 已同步并注明日期与原因，不修改历史报告。
- `README.md`、`CHANGELOG.md`、`install --help` 文本同步更新，不再把 IPv6 说成「基础问答不再询问」，并记录主菜单自升级入口。
- **版本**：`SCRIPT_VERSION` 提升为 `1.1.1`；`docs/PLAN.md` 与 D18 一节的「不提前发布 1.1.1」按维护者决定改为「已切出 1.1.1 补丁，`1.2.0` 仍为暂定候选」。

## 5. 自动化验证

新增/更新的用例：

| 用例 | 覆盖 |
| --- | --- |
| `run_sni_check_prompt_domain_case` | 无 state：空回车后追问、输入域名后按 `域名:443` 探测、头部同时给出「伪装 SNI」「回落目标」与判定说明、stderr 出现「域名不能为空」；`NON_INTERACTIVE=1` 仍退出 1。 |
| `run_menu_check_sni_status_case` | 菜单入口把 `check-sni` 的退出码 2 归一为 0，1/130 原样透传。 |
| `run_install_dual_stack_prompt_case` | 选 `y` 追问并写入地址；回车默认关且不追问地址；选 `n` 关掉已有地址；选 `y` 但地址留空后重问；已有地址时回车沿用。 |
| `run_install_wizard_input_budget_case` | 基础路径问答次数 8 → 9，新增双栈提示的顺序断言；确认页提示必须含「输入 advanced 进入高级选项」与「输入 back 改地址/域名/证书」。 |
| `run_install_advanced_menu_wording_case` | 高级项菜单每项带说明，xpadding/H3 写清作用与条件，网络优化写明当前内核即可、第三方内核可选；逐项问答文案同步。 |
| `run_install_advanced_item_answer_case` | 高级项 9 回答 `n` 是正常关闭、`y` 才打开且不报「H3 只能是 yes 或 no」；高级项 3 选 `y` 只读一次输入，四个 xpadding 参数取默认值。 |
| `run_prompt_write_target_case` | 调用方变量名为 `answer` 时，`prompt_yes_no` / `prompt_with_default` / `prompt_secret` 都必须真正写进该变量。 |
| `run_install_dependency_stage_case`（扩展） | `CERT_MODE=acme-http` 时 `socat` 进探测表、进只读报告，并在最小依赖阶段随 apt 一起安装。 |
| `run_install_warp_prompt_status_case` | 已开 WARP、无凭据时回车/选 `n`/已有凭据三条成功路径都返回 0；`:cancel` 仍然失败（130）。 |
| `run_main_menu_script_update_case` | 未安装菜单第 5 项、已安装菜单第 7 项都派发 `update-script`；两种菜单文案各自带出对应编号。 |
| `tests/install-boundary.py` | PTY 提示白名单加入双栈开关，避免把新提示误报为「unexpected prompt」。 |

本地 `bash tests/smoke.sh` 通过（含上述用例；本机沙箱不允许创建伪终端，`run_menu_pty_case` 按脚本自身的 `script` 探测跳过）。本机沙箱下若干既有的 `printf … | grep -q` 断言会偶发 SIGPIPE 141（`set -o pipefail`），换一个用例失败、重跑即绿，与本改动无关；以 CI 结果为准。ShellCheck 对改动文件无告警。另用桩探测跑通两条真实入口路径：未安装菜单选 `3` → 输入域名 → 输出 13 项预检并正常返回菜单；基础向导选 `y` → 摘要出现 `连接地址: …；IPv6 …`。

## 6. 仍待验证

- 真实终端上重走：未安装机器选 `3` → 现场输入域名 → 看到 13 项预检；全新安装选 `y` → 自动带出本机 IPv6 → 摘要出现 `IPv6 <地址>` 与节点 6/7。
- 真实终端上确认 `--non-interactive` 路径没有多问，且 `--server-ip6`/`--no-ipv6` 行为不变。
- 真实终端上选主菜单「升级脚本」：能看到下载/版本对比/确认，升级后入口重新打开显示新版本；离线或 GitHub 不可达时有明确失败信息且不留半装状态。
- 8→9 次输入只在本机已有证书路径上计数，其它证书分支的必要字段数未重新盘点。
