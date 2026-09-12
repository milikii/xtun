# xtun 1.1.0 施工图：去订阅、只出链接与二维码

> **归档说明（2026-09-12）：** 阶段 0–3 已完成，§7 的三项代码清理已在 `f219480` 完成。
> 本文保留当时的设计与验收要求，不代表当前待办；后续工作见 [当前计划](../PLAN.md)。
> 附录 F 的生产升级暂缓：用户在 2026-09-10 的 pi 会话中明确要求“本机的生产节点暂时别动”。
> 当时的本机版本描述及测试结论以当前计划的重新核验结果为准。

> 本文是交给实施者（人或 AI）的施工图。它假定读者没有看过本仓库任何一行代码，
> 所以每一处改动都点到文件、函数、变量名；每个阶段都有可机械核对的验收标准。
> 文中「必须 / 不得 / 一律」是硬约束；「建议」可由实施者裁量。
>
> 基线：`main` 分支 `4cba157`，`SCRIPT_VERSION="1.0.0"`，`STATE_VERSION_CURRENT="2"`。
> 文中行号以 `4cba157` 为准；其后的 `9772802`（裁 skill）与本文所在的 docs 提交只动了 `skills/` 与 `docs/`，shell 代码行号不变。
> 基线状态：`shellcheck` 零发现；`bash tests/smoke.sh` 108 条用例全绿（2026-09-09 在本机实测）。
>
> 上一版施工图（0.11.14 → 1.0.0）已全部完成，归档在 `docs/archive/PLAN-1.0.0.md`。
> 它的 §1「决策清单」与 §2「实施者必读：仓库约定与陷阱」继续有效，本文不重复，只写增量。

---

## 0. 目标与非目标

### 0.1 这一版做什么

1. **删掉订阅托管与 mihomo 输出。** 1.0.0 把节点导出做成了三样东西：`/root/xtun-output.md`
   里的分享链接、经 CDN 域名 HTTPS 托管的 `/sub/<token>/{vless.txt,vless-raw.txt,mihomo.yaml}`、
   以及 `show-links --qr` 的终端二维码。单人节点不需要订阅：一台机器、一个人、几部设备，
   链接和二维码扫一次就进客户端了。订阅托管带来的东西全部删除：`SUB_TOKEN` 状态键、
   `/var/www/xtun-sub` 目录、nginx 的 `/sub/` location、`change-sub-token` 命令与菜单项、
   `diagnose` 的「订阅自检」、Cloudflare 缓存绕过表达式里的 `/sub/` 子句、mihomo yaml 生成器。
2. **节点导出只剩两种形态：链接与二维码。** 链接仍写在 `/root/xtun-output.md`（`show-links` 原样打印）；
   二维码有两种载体：终端 ANSI 二维码（`show-links --qr`，现有）与 **PNG 图片文件**
   （新增，每条节点一张，落在 `/root/xtun-qr/`，随链接一起重新生成）。
3. **补一个 1.0.0 的缺口：H3 两条链接从来没进过输出文件。** `vless_links_text` 会在 H3 可用时
   追加 `XHTTP-TLS-H3` / `XHTTP-SPLIT-CDN-H3`，但 `output_file_text` 只渲染节点 1–7 的块，
   H3 链接只出现在订阅文件里。订阅一删它们就没地方看了，所以本版把节点 8 / 9 的块补进输出文件。
4. **`qrencode` 变成硬依赖。** 1.0.0 的 `install_packages` 不装 `qrencode`，
   README 却写「`--qr` 需要 `qrencode`」，CI 真机冒烟是手工 `apt-get install qrencode` 才跑通的；
   本机（生产节点）就没装，`show-links --qr` 目前只会打一行警告。二维码既然成了唯一的「非文本」导出形态，
   依赖必须由安装器负责。

### 0.2 最终形态（1.1.0）

节点集合不变（5 条默认 + IPv6 两条 + H3 两条），服务端配置不变（xray / haproxy 一字不改，
nginx 只是少一个 location）。变化全部在「导出层」：

```
/root/xtun-output.md          人类可读输出：节点 1–9 的参数块 + 链接 + 「## 二维码」段 + 其它段落不变
/root/xtun-qr/NN-<节点名>.png  每条节点一张 PNG（NN 为固定位次 01–09，见 §5.2），0700 目录 / 0600 文件
xtun show-links               打印输出文件
xtun show-links --qr          追加打印每条链接的终端二维码（现在也覆盖 H3 两条）
```

### 0.3 明确不做

- 不做任何订阅格式（Base64 / raw / Clash / sing-box / mihomo），也不做 HTTP 托管的二维码页面。
- 不改节点集合，不改 xray / haproxy 配置生成器。
- 不升 `STATE_VERSION`（去掉一个键不改变其它键语义，未知键在加载时本来就会被跳过，见 §4.2）。
- 不裁剪 `/root/xtun-output.md` 里 Cloudflare DNS / WARP / ECH / xpadding / 网络优化这些说明段。
  想裁可以另开一版，本版只删订阅段、加二维码段与 H3 段。
- 不把 xray 二进制的版本策略从 `releases/latest`（= 最新非 pre-release）改成追 pre-release（§8 有说明）。

### 0.4 驱动本方案的审查结论（2026-09-09）

实施前先知道这些，很多改动的理由都在这里：

| # | 发现 | 位置 | 处理 |
| --- | --- | --- | --- |
| 1 | `uninstall` 的 `remove_managed_paths` 清单里没有 `/var/www/xtun-sub`：卸载后 0644 的 `vless.txt`（含 UUID、公钥、路径）留在盘上 | `lib/cli/core.sh:417-440` | §4.7 把它加进 `legacy_managed_paths`，升级 / 卸载 / 重装都会清 |
| 2 | H3 链接不进输出文件（只进订阅） | `lib/ui/output.sh:1079-1103` 没有 H3 块 | §5.4 |
| 3 | `qrencode` 不在 `install_packages` 里 | `lib/install.sh:12` | §5.1 |
| 4 | `subscription_base_url` 在 `lib/ui/core.sh:554` 与 `lib/ui/output.sh:489` 各定义一次 | 后加载的赢，行为一致，纯冗余 | 随订阅一起删 |
| 5 | `tests/common.sh::prepare_workspace` 还在给七个已删除的 `SUBSCRIPTION_*` 变量赋值；`tests/cases_state_runtime.sh::errexit_guarded_step_names` 还登记着 `write_core_health_*`、`write_subscription_files`、`select_output_client_if_requested` 这些早已不存在的函数名；`tests/cases_output.sh:81-86` 断言「输出文件里没有 Clash Meta / sing-box 片段」——那两段 0.12 就没了 | 死代码，不影响结果 | §4.9 顺手清 |
| 6 | `update-script` 的「当前已经是最新脚本 bundle」永远不会命中：`bundle_script_signature` 对下载的 bundle 根目录哈希全部文件（含 README、tests、docs、skills），对已安装目录只有 xtun.sh / lib / static，两边永远不等，每次都重装一遍 | `lib/install/self.sh:52-62, 73-81` | §7 顺手修 |
| 7 | 仓库 `skills/` 目录在 `4cba157` 时 27 MB（746 个文件，151 张图 22 MB），而 `bash xtun.sh` 单文件引导与 `update-script` 下载的是整个分支的 codeload tar.gz：归档从 0.18 MB 涨到 22.6 MB（125 倍）。同时 `skills/` 不是 Claude Code 的技能发现路径（要放 `.claude/skills/`），所以它现在对任何 AI 会话都是不可见的 | 上一次提交 `4cba157`；`9772802` 已删掉 ru / en 镜像与 level-0 教程，目录 3.5 MB、归档 1.15 MB，仍是 1.0.0 前的 6 倍 | §3 |
| 8 | skill 的手写层有几处与它自己收录的官方文档 / 源码相反（`target`/`dest`、`password`/`publicKey` 方向写反；`allowInsecure` 写成「已移除、填 true 会报错」，文档原文是「已弃用」），且把 pre-release `v26.9.9` 标成 stable | `skills/.../changelog/v26.9.9.md`、`extracted/parameters/reality-settings.yaml`、`sources.yaml` | 附录 E |

---

## 1. 决策清单（已定，实施时不要再议）

- **A. 订阅相关一律删除，不留开关。** 包括状态键、目录、nginx location、命令、菜单项、诊断项、缓存表达式子句、测试用例、README / ARCHITECTURE 段落。
- **B. 二维码 = 终端 ANSI + PNG 文件，两者都保留。** 终端二维码给 SSH 现场扫；PNG 给 `scp` 回本地后用大屏扫——
  上下行分离节点的链接有 1100–1700 字符（附录 D 实测），终端里画出来是 137×137 个字符块，手机对着终端扫成功率很低，PNG 是这几条节点的实际可用路径。
- **C. `qrencode` 进 `install_packages`，同时进 `managed_package_names`（`--purge` 会卸）。** 已装节点跑 `apply-config` 时缺 `qrencode` 只 `warn` 不失败：PNG 是输出文件的派生物，不该让一次托管变更因它回滚。
- **D. `/var/www/xtun-sub` 进 `legacy_managed_paths`。** 顺手修掉 §0.4 第 1 项。
- **E. `SUB_TOKEN` 从 `state_file_key_allowed` 里去掉即可，不进 `state_file_legacy_key`，不加迁移提示，不升 `STATE_VERSION`。** 加载器对未知键是 `continue`（`lib/state.sh:190`），旧状态文件照常加载，下一次 `write_state_file` 自然不再写它。
- **F. H3 节点以「节点 8 / 节点 9」进输出文件；PNG 文件名用固定位次。** 节点 6/7 是 IPv6，8/9 是 H3，缺席就跳号，文件名和文档编号在不同机器上稳定。
- **G. 版本 `1.1.0`，tag `v1.1.0`。** 客户端里已添加的订阅地址会失效，需要改用链接 / 二维码重新导入；README 与升级附录都要写明。
- **H. skill 迁到 `.claude/skills/xray-core-official-knowledge/`，`.gitattributes` 用 `export-ignore` 把它和 tests / docs / .github 排除出源码归档。** 裁掉 ru / en 双语镜像与 level-0 教程这一步已在 `9772802` 完成（27 MB → 3.5 MB）。见 §3。skill 本身对 1.1.0 的改动没有帮助（本版不碰 xray 配置字段），修好它是为了 §8 的后续项。

---

## 2. 实施者必读：本版新增的约定与陷阱

先读 `docs/archive/PLAN-1.0.0.md` 的 §2（目录与加载顺序、errexit 在命令层失效、测试怎么跑、提交约定），这里只列增量：

- **全局变量总表在 `xtun.sh` 顶部。** 本版删 `SUB_WEB_ROOT`、`SUB_TOKEN`（`xtun.sh:202-203`），新增 `QR_OUTPUT_DIR="/root/xtun-qr"`。
  每加 / 删一个落盘路径变量，`tests/common.sh::sandbox_managed_paths` 与 `tests/smoke.sh::REAL_MANAGED_CANARY` 要同步，
  否则用例会写到真机、或者 canary 守卫会因为路径永远不存在而形同虚设。
- **`write_generated_file_atomically PATH PRODUCER_FN`（`lib/generators.sh:9-26`）只适合往 stdout 吐文本的生成器。**
  PNG 由 `qrencode -o` 直接写文件，要自己走「临时文件 + `mv -f`」，并在整个目录级别先 `backup_path`（回滚清单要用）。
- **errexit lint 的规则**（`tests/cases_state_runtime.sh::errexit_returning_step_names`）：函数体里出现字面的 `return 1`–`return 9`，
  该函数的所有调用点就必须带 `|| return 1` 之类守卫。§5.3 的 `write_link_qr_pngs` 被设计成只 `warn` + `return 0`，
  所以它的调用点不需要守卫，也不要给它加 `return 1`——加了就得同时给三个调用点补守卫，而失败回滚正是我们不想要的。
- **`show-links` 是纯查看命令**（不加锁、不读状态文件、只 `cat` 输出文件，`tests/cases_cli_core.sh::run_show_links_without_state_case` 钉着这一点）。
  终端二维码继续从输出文件里的 `vless://` 行取，不要改成读状态。
- **测试宿主机可能没有 `qrencode`**（本机就没有）。凡是走 PNG 的用例都通过覆盖 `have_qrencode` 与同名 `qrencode` 函数来跑，不得依赖真实二进制；
  用例末尾按仓库惯例 `load_functions` 还原被覆盖的函数。
- **节点名只含 `[A-Z0-9._-]`**（`lib/base/env.sh:195-208 normalize_node_label_prefix` 保证，后缀是固定常量），
  所以「`序号-节点名.png`」不需要再做文件名转义；TAB 也不可能出现在节点名或链接里，§5.2 用 TAB 分列是安全的。
- **不要在这台生产节点上跑 `install` / `uninstall` / `apply-config`「试一下」。** 只跑 `tests/smoke.sh`、`shellcheck` 与只读命令。升级生产节点走附录 F，由用户执行。

---

## 3. 阶段 0：仓库卫生（skill 与源码归档体积）

目标：让 `bash xtun.sh` / `update-script` 的下载量回到 1.0.0 之前的水平；让 skill 真正能被 AI 会话加载；修掉 skill 里会把实施者带偏的错误说法。
这一阶段不碰任何 shell 代码，可以单独提交、先合并。

### 3.1 `.gitattributes`（新文件）

```gitattributes
# GitHub 的源码归档（codeload tar.gz —— bash xtun.sh 单文件引导与 update-script 下载的就是它）
# 遵守 export-ignore。装进 /usr/local/lib/xtun 的只有 xtun.sh / lib / static，其余目录不进归档。
.claude/        export-ignore
skills/         export-ignore
tests/          export-ignore
docs/           export-ignore
.github/        export-ignore
.gitattributes  export-ignore
.shellcheckrc   export-ignore
```

- `bundle_root_ready`（`xtun.sh:34-40`）只要求 `xtun.sh`、`lib/base/helpers.sh`、`static/fallback/index.html` 三个文件，以上排除项都不影响它。
- 本地验证：`git archive --worktree-attributes HEAD | tar t | grep -c '^[^/]*/skills/'` 必须是 `0`；
  `git archive --worktree-attributes HEAD | gzip -9 | wc -c` 应回到 ~100–200 KB（2026-09-09 实测：`4cba157` 不排除是 22 631 774 字节；`9772802` 裁掉镜像与教程后不排除是 1 149 474；只排除 `skills/` 是 182 013，全部排除是 101 051）。
- 推送后再验证一次线上归档：`curl -fsSL https://codeload.github.com/milikii/xtun/tar.gz/main | tar tz | grep -c skills` 应为 `0`。

### 3.2 skill 搬家与瘦身

1. `git mv skills/xray-core-official-knowledge .claude/skills/xray-core-official-knowledge`；删掉空的 `skills/`。
   Claude Code 只在 `.claude/skills/<name>/SKILL.md`（项目级）与 `~/.claude/skills/`（用户级）发现技能；仓库根下的 `skills/` 是插件布局，但仓库没有 `.claude-plugin/plugin.json`，所以现在两头都不算。
   给别的 agent（Codex 等）留一句指路：在仓库根新建 `AGENTS.md`，一行「Xray 官方文档 / 源码快照在 `.claude/skills/xray-core-official-knowledge/`，涉及 xray 配置字段时以它的 `docs/stable/config/` 与 `source/` 为准」。
2. 裁剪——**已完成**（提交 `9772802`，2026-09-09）：删掉了 `docs/stable/ru/`（156 个文件，俄文镜像）、`docs/stable/en/`（156 个文件，英文镜像；中文是 Xray-docs-next 的主语言，字段说明以中文为准）、`docs/stable/document/level-0/`（52 个文件的新手教程，含全部 gif / png 截图）。
   结果：746 → 382 个文件，27 MB → 3.5 MB，gif 为 0，剩 11 张图共约 0.6 MB。`sources.yaml` 的 `gaps` 里记了一条 `removed`。
   两点后续：
   - 剩下的 6 个文档（`about/news.md`、`document/config.md`、`document/index.md`、`level-1/fallbacks-lv1.md`、`level-2/nginx_or_haproxy_tls_tunnel.md`、`level-2/tproxy_ipv4_and_ipv6.md`）里指向 `level-0/` 的链接已悬空，不必修，实施者知道即可。
   - 可选再删：`docs/stable/public/`（两张 project 图 0.35 MB + 两个 logo svg）、`docs/stable/about/`（news / sponsor）。不强求。
   保留：`docs/stable/config/`（65 个文件，字段参考）、`docs/stable/document/level-1/`（`fallbacks-with-sni.md`）与 `level-2/`（`nginx_or_haproxy_tls_tunnel.md` 与 xtun 架构直接相关）、`docs/stable/development/protocols/`、`source/`（254 个文件，`infra/conf` 与 `transport/internet` 快照）、`extracted/`、`examples/`、`references/`、`changelog/`、`citations/`。
3. 按附录 E 逐条修正错误说法与元数据。
4. `.gitignore` 里 `.health-state.tmp.*` / `.health-history.tmp.*` 是 0.12 删掉的核心巡检残留，顺手删掉这两行。

### 3.3 验收

- `git archive --worktree-attributes HEAD | tar t` 不含 `skills/`、`.claude/`、`tests/`、`docs/`、`.github/`。
- `.claude/skills/xray-core-official-knowledge/SKILL.md` 存在；`du -sh` 约 3.5 MB（`9772802` 实测，再删 `public/` 与 `about/` 约 3.1 MB）；`find … -name '*.gif' | wc -l` 为 0。
- 附录 E 的每一条在对应文件里都改掉了（`grep -n '现已由 dest 统一替代' -r .claude/skills` 无结果等）。
- 单独提交，信息建议：`chore: skill 迁到 .claude/skills；.gitattributes 把非运行文件排除出源码归档（bootstrap 下载 1.15MB→0.1MB）`。

---

## 4. 阶段 1：删订阅托管与 mihomo 输出（1.1.0 第一部分）

目标：删掉 §0.1 第 1 条列出的全部东西，节点链接与终端二维码行为零变化。做完这一阶段单独提交。

### 4.1 `xtun.sh`

- 删除 `SUB_WEB_ROOT="/var/www/xtun-sub"`、`SUB_TOKEN=""`（第 202–203 行）。
- 新增 `QR_OUTPUT_DIR="/root/xtun-qr"`（放在 `OUTPUT_FILE` 之后；阶段 2 才用，先占位以便 sandbox 与 canary 一次改齐）。
- `SCRIPT_VERSION` 留到阶段 3 再改。

### 4.2 `lib/state.sh`

- `state_file_key_allowed`（第 32 行的大 `case`）去掉 `SUB_TOKEN`。**不要**把它加进 `state_file_legacy_key`（第 43 行）：那张表只给需要迁移提示的键用。
- `reset_loaded_runtime_context` 删掉 `SUB_TOKEN=""`（第 243 行）。
- `state_file_text` 删掉 `write_state_kv "SUB_TOKEN" "${SUB_TOKEN}"`（第 519 行）。
- 其它不动。`load_existing_state`（第 297–306 行）对未知键的处理已经是跳过。

### 4.3 `lib/ui/output.sh`

删除以下函数（行号按基线）：

| 函数 | 行 |
| --- | --- |
| `yaml_quote` | 480–487 |
| `subscription_base_url` | 489–491 |
| `subscription_base64_text` | 493–496 |
| `mihomo_xpadding_lines` / `mihomo_reuse_settings_lines` / `mihomo_ech_lines` / `mihomo_xhttp_base_lines` | 498–545 |
| `mihomo_nodes_yaml_text` | 547–781 |
| `write_subscription_web_files` | 783–799 |
| `ensure_sub_token` | 1105–1110 |

改动：

- `cloudflare_xhttp_cache_bypass_expression`（815–819）去掉尾部的 ` or (http.request.uri.path contains "/sub/")`，恢复为两项。
- `output_runtime_summary_block`（988–1040）删掉「## 订阅地址（经 CDN 域名 HTTPS）」整段（997–1001，含前后空行处理，确保段与段之间仍是一个空行）。
- `write_output_file`（1112–1118）改为：

```bash
write_output_file() {
  write_generated_file_atomically "${OUTPUT_FILE}" output_file_text || return 1
  chmod 0644 "${OUTPUT_FILE}"
}
```

  阶段 2 会在这里追加 PNG 生成。
- `vless_links_text`（464–478）**保留**：阶段 2 的二维码要用它（并会被改成 `node_link_entries | cut -f3`）。

### 4.4 `lib/ui/core.sh`

删除 `subscription_base_url`（554–556，重复定义）、`subscription_self_check_state`（558–588）、`subscription_self_check_text`（590–592）。

### 4.5 `lib/generators.sh`

`nginx_server_config` 里删掉整个 `location ^~ /sub/ { … }` 块（565–574）及其前后多出的空行。
`nginx_fallback_location_config` 与 `nginx_xhttp_location_config` 不动。

### 4.6 `lib/cli/core.sh`

- `show_links`（23–50）删掉第 48 行 `render_subscription_qr`。
- 删除 `render_subscription_qr`（239–256）、`change_sub_token_cmd`（258–277）。
- `diagnose_cmd`：删掉第 171 行 `printf '%s\n' "订阅自检: $(subscription_self_check_text)"` 与第 196 行 `[[ "$(subscription_self_check_state)" != "fail" ]] || config_failures+=("订阅自检失败")`。
- `dispatch_cli_command` 删掉 `change-sub-token)` 分支（594–596）。
- `show_main_menu`（463–487）与 `run_menu_choice`（636–663）改为附录 A 的表：第 2 项文案改成「查看节点链接与二维码」，删掉第 16 项「轮换订阅地址」，原 17–20 顺次变为 16–19。
- `uninstall_cmd` 的 `remove_managed_paths` 清单不必加 `/var/www/xtun-sub`：§4.7 的 `remove_legacy_managed_paths` 已经在第 441 行被调用。

### 4.7 `lib/base/runtime.sh`

- `legacy_managed_paths`（101–117）追加一行 `"${prefix}/var/www/xtun-sub"`（放在 `/root/xtun-subscriptions` 之后）。
  三个调用点（`install` → `write_install_managed_files`、`apply-config`、`uninstall`）已经存在，不必新增。
- `remove_legacy_managed_paths` 第 350 行的日志文案改为「旧版本遗留的巡检、WARP Team、本地订阅目录与 nginx 订阅目录文件已清理。」
- `finalize_installation`（353–369）删掉第 366 行 `ensure_sub_token || return 1`；`apply_managed_files`（401–431）删掉第 428 行同名调用。

### 4.8 `lib/base/input.sh::usage`

- 第 29 行 `show-links [--qr]` 保留；第 176 行 `--qr` 的说明改为「额外输出每条分享链接的终端二维码（qrencode 由安装器安装）。」
- `usage` 里本来就没有 `change-sub-token`，无需删。

### 4.9 测试

删除用例（同时从 `tests/smoke.sh` 的 `cases` 数组第 248–251 行移除）：
`run_subscription_web_files_case`、`run_change_sub_token_case`、`run_nginx_sub_location_case`、`run_mihomo_yaml_case`（`tests/cases_output.sh:631-819`）。

改用例：

- `tests/cases_output.sh::run_output_helper_case`：第 189 行的缓存表达式期望值去掉 `/sub/` 子句；顺手删掉第 81–86 行两个「Clash Meta / sing-box 片段不存在」的死断言。
- `tests/cases_nginx_net.sh::run_ipv6_links_case`：删掉第 226–230 行与第 235 行的 mihomo 断言；第 22、72、290 行的 `SUB_WEB_ROOT="/var/www/xtun-sub"` 赋值删掉。
- `tests/cases_state_runtime.sh::run_runtime_context_reset_case`：删掉第 225 行 `SUB_TOKEN="stale-token"` 与第 232 行 `[[ -z "${SUB_TOKEN}" ]]`。
- `tests/cases_state_runtime.sh::errexit_guarded_step_names`（451–470）：删掉 `write_core_health_monitor write_core_health_helper write_core_health_service write_core_health_timer`、`write_subscription_files`、`select_output_client_if_requested`。
- `tests/cases_cli_flow.sh::run_dispatch_case`：删掉 `change_sub_token_cmd` 桩（99–101）与断言（136–137）；`run_menu_choice` 的编号按附录 A 改：`20`→`19`（uninstall）、`17`→`16`（apply-net-opt）、`18`→`17`（apply-config），并补一条 `run_menu_choice 18` → `repair-perms`（要像其它命令一样先给 `repair_perms_cmd` 加记录桩）。
- `tests/common.sh`：`sandbox_managed_paths` 第 100 行 `SUB_WEB_ROOT=` 改为 `QR_OUTPUT_DIR="${root}/root/xtun-qr"`；`prepare_workspace` 删掉第 120–126 行七个 `SUBSCRIPTION_*` 死变量。
- `tests/smoke.sh::REAL_MANAGED_CANARY`：`/var/www/xtun-sub` 改为 `/root/xtun-qr`（本机升级后才会出现，出现之前 canary 对它是空操作，这是预期行为）。

新增用例（放 `tests/cases_output.sh` 或 `tests/cases_state_runtime.sh`，并登记进 `cases` 数组）：

- `run_nginx_no_sub_location_case`：`write_nginx_config` 后 `assert_absent '/sub/'`、`assert_absent 'xtun-sub'`。
- `run_state_sub_token_dropped_case`：写一个含 `SUB_TOKEN='abc…'`（32 位 hex）与其它合法键的 v2 状态文件，`load_existing_state` 不报错、不 warn；`write_state_file` 之后 `assert_absent 'SUB_TOKEN' "${STATE_FILE}"`。
- `tests/cases_cli_core.sh` 现有的遗留清理用例（第 1555–1580 行，放 `/root/xtun-subscriptions` 的那一个）追加：沙箱里放 `var/www/xtun-sub/<token>/vless.txt`，`remove_legacy_managed_paths` 后目录消失。

### 4.10 README / ARCHITECTURE（本阶段只删，重写留到阶段 3）

- README：删「### 订阅地址」（251–267）、「### mihomo 导入」（292–298）；命令表删 `change-sub-token` 行（200）；第 276 行去掉「，mihomo yaml 同步追加」；第 474 行「不会出现在输出文件或订阅里」改「不会出现在输出文件里」。
- `docs/ARCHITECTURE.md`：删「## 订阅为什么要走 nginx 托管」（54–56）。阶段 3 会在同一位置写决策记录。

### 4.11 验收

- `shellcheck` 零发现；`smoke ok`。
- `grep -rn 'SUB_TOKEN\|SUB_WEB_ROOT\|mihomo\|/sub/\|订阅\|subscription' xtun.sh lib tests` 只剩：`legacy_managed_paths` 里的 `/root/xtun-subscriptions` 与 `/var/www/xtun-sub` 两行、`remove_legacy_managed_paths` 的一句日志、以及测试里对应的遗留清理 / `SUB_TOKEN` 丢弃断言。
- 用 1.0.0 的状态文件（含 `SUB_TOKEN`）跑 `load_existing_state` 无告警，写回后不含该键。
- 默认安装态生成的 `config.json`、`haproxy.cfg` 与 1.0.0 逐字节一致；`xtun.conf` 只少了 `/sub/` 那一个 location。
- 提交信息建议：`refactor: 删除订阅托管与 mihomo 输出——去 /sub/ location、SUB_TOKEN、change-sub-token、订阅自检；/var/www/xtun-sub 进遗留清理（顺手修 uninstall 漏删）`。

---

## 5. 阶段 2：二维码 PNG、H3 节点进输出文件、qrencode 硬依赖（1.1.0 第二部分）

### 5.1 依赖

- `lib/install.sh::install_packages`（第 12 行）的 `apt-get install -y …` 列表加 `qrencode`。
- `lib/install.sh::managed_package_names`（24–31）加 `"qrencode"`。
- 新函数（`lib/ui/core.sh`，放在 `quic_port_listening` 附近）：

```bash
have_qrencode() {
  command -v qrencode >/dev/null 2>&1
}
```

- `lib/cli/core.sh::render_output_file_qr`（8–21）第 9 行改用 `have_qrencode`；第 10 行的告警文案改为「系统中未找到 qrencode，无法输出二维码；apt-get install -y qrencode 后重试。」
  顺手在每个二维码前打出节点名：`printf '%s\n' "二维码 (${link##*#}):"`（链接的 `#` 之后就是节点名）。

### 5.2 链接清单的单一来源：`node_link_entries`

`lib/ui/output.sh` 新增（放在 `build_link_context` 之后，替代原 `vless_links_text` 的主体）：

```bash
# 每行：位次<TAB>节点名<TAB>链接。位次固定：1–5 默认，6/7 IPv6，8/9 H3，缺席跳号，
# 这样 PNG 文件名与输出文件里的「节点 N」在任何机器上都对得上。
node_link_entries() {
  build_link_context
  printf '%s\t%s\t%s\n' \
    1 "$(prefixed_node_label "REALITY")" "${REALITY_URI}" \
    2 "$(prefixed_node_label "XHTTP-REALITY")" "${XHTTP_REALITY_URI}" \
    3 "$(prefixed_node_label "XHTTP-CDN")" "${XHTTP_URI}" \
    4 "$(prefixed_node_label "XHTTP-SPLIT-CDN-REALITY")" "${XHTTP_SPLIT_URI}" \
    5 "$(prefixed_node_label "XHTTP-SPLIT-REALITY-CDN")" "${XHTTP_REVERSE_SPLIT_URI}"
  if [[ -n "${SERVER_IP6:-}" ]]; then
    printf '%s\t%s\t%s\n' \
      6 "$(prefixed_node_label "REALITY-V6")" "${REALITY_V6_URI}" \
      7 "$(prefixed_node_label "XHTTP-SPLIT-CDN-REALITY-V6")" "${XHTTP_SPLIT_CDN_REALITY_V6_URI}"
  fi
  if h3_enabled; then
    printf '%s\t%s\t%s\n' \
      8 "$(prefixed_node_label "XHTTP-TLS-H3")" "${XHTTP_H3_URI}" \
      9 "$(prefixed_node_label "XHTTP-SPLIT-CDN-H3")" "${XHTTP_SPLIT_CDN_H3_URI}"
  fi
}

vless_links_text() {
  node_link_entries | cut -f3
}
```

`build_link_context` 里已经用 `prefixed_node_label` 算过一遍标签；实施者可以把那些标签提升为 `LINK_*_LABEL` 全局变量给两边共用，也可以像上面这样再算一次（纯字符串函数，无副作用）。二选一，不要各写一套字面量。

### 5.3 PNG 生成：`write_link_qr_pngs`

`lib/ui/output.sh` 新增，并由 `write_output_file` 在写完 `OUTPUT_FILE` 之后调用（**不加守卫**，见 §2）：

```bash
# 二维码 PNG 是输出文件的派生物：任何一步失败只 warn，不让 install / apply-config 回滚。
# 目录整体重建：链接变了（换 UUID / SNI / 路径 / 域名、IPv6 或 H3 开关变化）旧图必须消失。
write_link_qr_pngs() {
  local idx="" label="" uri="" target="" tmp_file=""

  if ! have_qrencode; then
    warn "未安装 qrencode，跳过二维码 PNG；apt-get install -y qrencode 后运行 xtun apply-config 即可补齐。"
    return 0
  fi
  if ! backup_path "${QR_OUTPUT_DIR}"; then
    warn "二维码目录备份失败，本次跳过 PNG 生成：${QR_OUTPUT_DIR}"
    return 0
  fi
  rm -rf "${QR_OUTPUT_DIR}"
  if ! install -d -m 0700 "${QR_OUTPUT_DIR}"; then
    warn "无法创建二维码目录，已跳过：${QR_OUTPUT_DIR}"
    return 0
  fi

  while IFS=$'\t' read -r idx label uri; do
    target="${QR_OUTPUT_DIR}/$(printf '%02d-%s.png' "${idx}" "${label}")"
    tmp_file="$(mktemp "${QR_OUTPUT_DIR}/.qr.XXXXXX")"
    if qrencode -o "${tmp_file}" -l L -s 6 -m 2 "${uri}" 2>/dev/null; then
      mv -f "${tmp_file}" "${target}"
      chmod 0600 "${target}"
    else
      rm -f "${tmp_file}"
      warn "二维码 PNG 生成失败，已跳过：${label}"
    fi
  done < <(node_link_entries)
}

write_output_file() {
  write_generated_file_atomically "${OUTPUT_FILE}" output_file_text || return 1
  chmod 0644 "${OUTPUT_FILE}"
  write_link_qr_pngs
}
```

参数说明：`-l L` 是容错等级 L，字节模式容量 2953 字节，附录 D 的最长链接 1713 字符在版本 30 就装得下；
`Q` / `H` 等级容量只有 1663 / 1273，装不下全开时的分离节点，**不得**用。`-s 6` 每个模块 6 像素，`-m 2` 两个模块的静区，
最大的图约 850×850 像素（(137 + 4) × 6），手机隔着显示器扫没有问题。

### 5.4 输出文件：H3 块与二维码段

`lib/ui/output.sh`：

- 新增 `output_h3_blocks`，格式对齐 `output_ipv6_blocks`（953–986），`XHTTP_H3_URI` 为空时输出空（`build_link_context` 在 H3 不可用时把它置空，用它判断比再调一次 `h3_enabled` 更一致）：

```
## 节点 8
- 类型: VLESS + XHTTP + TLS（H3 直连，UDP 443）
- 地址: ${SERVER_IP}
- 端口: 443（UDP / QUIC，防火墙需放行）
- UUID: ${XHTTP_UUID}
- SNI: ${XHTTP_DOMAIN}
- 主机名: ${XHTTP_DOMAIN}
- ALPN: h3
- 指纹: $(effective_fingerprint)
$(output_xhttp_shared_details)

链接:
${XHTTP_H3_URI}

## 节点 9
- 类型: 上行 XHTTP + TLS + CDN ｜ 下行 XHTTP + TLS H3 直连
- 上行地址: ${XHTTP_DOMAIN}（CDN+TLS）
- 下行地址: ${SERVER_IP}（H3，UDP 443）
- UUID: ${XHTTP_UUID}
$(output_xhttp_shared_details)

链接:
${XHTTP_SPLIT_CDN_H3_URI}
```

- 新增 `output_qr_block`：

```
## 二维码
- 终端扫码: xtun show-links --qr
- PNG 目录: ${QR_OUTPUT_DIR}（每条节点一张，文件名「位次-节点名.png」，随链接一起重新生成）
- 取回本地: scp root@${SERVER_IP}:${QR_OUTPUT_DIR}/'*.png' .
```

- `output_file_text`（1079–1103）在 `$(output_ipv6_blocks)` 之后依次加 `$(output_h3_blocks)`、空行、`$(output_qr_block)`；
  `output_runtime_summary_block` 的「## 本地文件」段加一行 `- 二维码目录: ${QR_OUTPUT_DIR}`。
- 输出文件里的 `vless://` 行现在包含 H3 两条，`show-links --qr` 自然也会画它们，不需要额外改动。

### 5.5 卸载、回滚、面板

- `lib/cli/core.sh::uninstall_cmd` 的 `remove_managed_paths` 清单在 `"${OUTPUT_FILE}"` 之后加 `"${QR_OUTPUT_DIR}"`。
- `lib/base/runtime.sh::rollback_xray_only_managed_state`（210–220）的 `paths` 加 `"${QR_OUTPUT_DIR}"`（§5.3 先 `backup_path` 就是为了这里能还原）。
- `lib/ui/dashboard.sh::show_dashboard` 第 82 行「链接文件」下加 `panel_row "二维码目录" "${QR_OUTPUT_DIR}"`。

### 5.6 测试

`tests/common.sh::sandbox_managed_paths` 与 `REAL_MANAGED_CANARY` 在阶段 1 已改。新增用例（`tests/cases_output.sh`，登记进 `cases`）：

- `run_node_link_entries_case`：默认态 5 行且位次为 `1 2 3 4 5`；`SERVER_IP6` 非空 7 行含 `6`、`7`；覆盖 `h3_enabled() { return 0; }` 后含 `8`、`9`；两者都开 9 行；每行三列（`awk -F'\t' 'NF!=3{exit 1}'`）；`node_link_entries | cut -f3` 与 `vless_links_text` 逐字节相同；第 2 列等于第 3 列 `#` 之后的片段。
- `run_link_qr_png_case`：
  - 覆盖 `have_qrencode() { return 0; }` 与
    `qrencode() { local out=""; while [[ $# -gt 0 ]]; do case "${1}" in -o) out="${2}"; shift ;; esac; shift; done; printf 'PNG' > "${out}"; }`；
    `write_output_file` 后 `QR_OUTPUT_DIR` 模式 `700`，文件数等于 `node_link_entries` 行数，存在 `01-HKG-REALITY.png` 与 `05-HKG-XHTTP-SPLIT-REALITY-CDN.png`，文件模式 `600`；
  - 目录里预先放一个 `stale.png`，再次 `write_output_file` 后它消失；
  - 覆盖 `have_qrencode() { return 1; }`：`write_output_file` 返回 0、`OUTPUT_FILE` 照常写出、目录不被创建、stderr 含 `qrencode`；
  - 覆盖 `qrencode() { return 1; }`：返回 0，目录存在但为空，stderr 含「生成失败」；
  - 末尾 `load_functions`。
- `run_h3_output_blocks_case`：覆盖 `nginx_v3_capable() { return 0; }`、`h3_enabled() { [[ -z "$(h3_disabled_reason)" ]]; }`、`CERT_MODE="existing"`，`write_output_file` 后 `assert_contains '## 节点 8'`、`'## 节点 9'`、`'alpn=h3'`；`h3_enabled() { return 1; }` 时 `assert_absent '## 节点 8'`。
- `run_output_qr_block_case`：输出文件含 `## 二维码`、`${QR_OUTPUT_DIR}`、`show-links --qr`。
- `run_render_output_file_qr_case`（`tests/cases_cli_core.sh`）：输出文件放两条 `vless://…#HKG-A`、`vless://…#HKG-B`，覆盖 `have_qrencode` 与 `qrencode` 为记录参数的桩，`render_output_file_qr` 输出含 `二维码 (HKG-A):`、`二维码 (HKG-B):`，桩被调用两次。
- 现有 `run_uninstall_*` / `run_managed_rollback_case` 若断言了路径清单，补上 `QR_OUTPUT_DIR`。

### 5.7 CI（`.github/workflows/ci.yml`）

- `install-smoke` 第 91 行的 `apt-get install … qrencode procps` 去掉 `qrencode`——让真机冒烟证明 `install_packages` 自己装上了它。
- 第 103 行 `bash xtun.sh diagnose` 之后追加：

```bash
            test -d /root/xtun-qr
            test "$(ls /root/xtun-qr/*.png | wc -l)" -ge 5
            test ! -e /var/www/xtun-sub
            ! grep -q '/sub/' /etc/nginx/conf.d/xtun.conf
            xtun show-links --qr | grep -q '二维码 ('
            grep -q '^## 二维码' /root/xtun-output.md
```

- Xray 的钉版本保持 `v26.3.27`：2026-09-09 核对 GitHub Releases，`v26.4.13` 起到 `v26.9.9` 全部是 pre-release，`v26.3.27` 仍是唯一的正式版，
  也就是 `xtun install` / `upgrade` 通过 `releases/latest/download` 实际拿到的版本。不要为了 skill 里的 `v26.9.9` 去升它。

### 5.8 验收

- `shellcheck` 零发现；`smoke ok`。
- 在沙箱里（`bash -c '. tests/common.sh; load_functions; stub_side_effects; …'`）对一组默认参数调 `write_output_file`：输出文件含 `## 节点 1` … `## 节点 5`、`## 二维码`；开 `SERVER_IP6` 与 H3 后含 `## 节点 6` … `## 节点 9`。
- 提交信息建议：`feat: 节点二维码 PNG（/root/xtun-qr，随链接重建）+ H3 两条节点补进输出文件 + qrencode 进安装依赖`。

---

## 6. 阶段 3：文档与版本

### 6.1 README

按下表逐项改（行号按基线）：

| 位置 | 改动 |
| --- | --- |
| 第 5 行 | `当前版本：1.1.0` |
| 「命令表」200–201 | 删 `change-sub-token` 行；`show-links [--qr]` 说明改「查看节点链接；`--qr` 追加每条链接的终端二维码」 |
| 「安装会写入哪些文件」209–227 | 加一行 `/root/xtun-qr/` — 「节点二维码 PNG（每条节点一张，随链接重建）」 |
| 「订阅地址」251–267、「mihomo 导入」292–298 | 阶段 1 已删；确认无残留 |
| 「查看和导出节点」317–324 | 重写：链接文件、`show-links --qr` 终端扫码（提示分离节点链接很长，建议用 PNG）、`/root/xtun-qr/` 与 `scp` 取回命令、qrencode 由安装器安装、已装节点缺它时 `apt-get install -y qrencode && xtun apply-config` |
| 「IPv6 双栈」276 | 阶段 1 已去 mihomo 字样 |
| 「XHTTP H3 直连下行」290 | 末尾补一句「这两条链接对应输出文件的节点 8 / 9」 |
| 「一次性诊断」306–315 | 列表与实际输出对齐：现有列表少了 2444 端口、路由拦截、H3 / QUIC 与 IPv6 监听；照改完后的 `diagnose_cmd` 逐行写 |
| 「nginx 的连接与 fd 限额」421–437 | 这段还在说「`worker_connections` 只能写在 nginx.conf，xtun 够不着它，低于 4096 时提示手工调整」，与 703–711「nginx 主配置接管」矛盾。改成：drop-in 抬 fd 限额；`worker_connections` 由接管的主配置写 65535，未接管的旧节点 `diagnose` 才提示 `apply-config --manage-nginx-main` |
| WARP「开关」512–516 | 「第一次执行 `change-warp` 会顺手停用并清理 warp-svc …」已不成立（`run_change_warp_action` 没有这个逻辑）；改为「旧版 `warp-svc` / `xtun-warp-health.timer` / APT 源 / keyring 由 `install`、`apply-config`、`uninstall` 的遗留清理统一处理」 |
| 「分流规则」529 | 「走菜单 12」→「走菜单 13」 |
| 「卸载」453 | 遗留清理的列举里加「1.0.0 的 `/var/www/xtun-sub` 订阅目录」 |
| 「升级注意」（新增小节，放「服务维护」之后） | 1.1.0 起不再提供订阅地址与 mihomo yaml；客户端里已添加的 `https://<域名>/sub/<token>/…` 会 404，请删掉订阅、改用链接或二维码重新导入；Cloudflare 缓存绕过规则里的 `/sub/` 子句可以删也可以留 |

### 6.2 `docs/ARCHITECTURE.md`

在原「订阅为什么要走 nginx 托管」的位置写「## 为什么 1.1.0 不再提供订阅与 mihomo 输出」，要点：

- 单人节点，导入是一次性的动作，链接 + 二维码是所有客户端的公共分母；
- 订阅是一个匿名可拉取的 HTTPS 路径，token 再长也是一个常驻的攻击面，而它换来的「多设备自动同步」在单人场景里用不上；
- mihomo 的 xhttp 字段随版本漂移，仓库里没有本地校验器（`mihomo -t` 需要另下二进制），生成器只能靠人肉对照 wiki，维护成本高于收益；
- 分离节点的链接 1100–1700 字符，终端二维码不实用，所以 PNG 成为唯一的图形化导出，放在 `/root/xtun-qr/`（0700），随链接重建。

同文「请求流图」与「本机端口一览」不变（nginx 少一个 location 不影响端口）。

### 6.3 版本

- `xtun.sh`：`SCRIPT_VERSION="1.1.0"`。
- `git tag v1.1.0`，与上一版一样打在阶段 3 的提交上。
- 提交信息建议：`docs: 1.1.0 —— README 去订阅/mihomo、补二维码 PNG 与升级注意、修三处陈旧说明；ARCHITECTURE 记录不做订阅的决策`。

---

## 7. 顺手清理（可选，各自独立提交，不影响主线）

- `lib/install/self.sh::bundle_script_signature`（52–62）只对 `xtun.sh`、`lib`、`static` 三个路径哈希（`find xtun.sh lib static -type f`），
  否则 `installed_script_matches_bundle` 永远为假、`update-script` 每次都重装并多留一份备份。加用例：把已安装目录与一份带 README 的 bundle 副本喂进去，期望相等。
- `lib/ui/output.sh::build_link_context` 第 439 行 `split_extra_v6_json=…` 没有 `local`，且在 `SERVER_IP6` 为空时也白算一次 jq；挪进 `if [[ -n "${SERVER_IP6:-}" ]]` 块并声明 `local`。
- `lib/generators.sh::nginx_server_config` 里 `quic_block=""` 没有 `local`。
- `.gitignore` 的核心巡检残留两行（§3.2 第 4 条，若阶段 0 没做）。

---

## 8. 后续 backlog（不在 1.1.0；这里才是 skill 派上用场的地方）

按价值排序，每一项都要先在 `.claude/skills/xray-core-official-knowledge/docs/stable/config/` 与 `source/` 里核对字段，再动手：

1. **`check-sni` 第 13 项：后量子就绪度。** 官方 `reality.md` 明说可以用 `xray tls ping <target>` 看目标是否支持 `X25519MLKEM768`、以及证书长度；
   若将来要开 `mldsa65Seed`，目标返回的证书必须大于 3500 字节。加一项 WARN 级检查，为第 2 条铺路。
2. **Reality 后量子签名（`mldsa65Seed` / `mldsa65Verify`）。** `xray mldsa65` 生成密钥对，服务端写 `realitySettings.mldsa65Seed`，客户端 `downloadSettings.realitySettings.mldsa65Verify`；
   分享链接里客户端字段的参数名要查各客户端（v2rayN / Happ）实际支持情况，源码在 `source/config/transport_security.go`。
3. **客户端字段名跟进。** 官方文档已把 Reality 客户端的 `publicKey` 改名为 `password`（旧名仍是别名）。xtun 生成的 `downloadSettings.realitySettings.publicKey` 与链接里的 `pbk=` 都还有效，
   但下次改这一块时应以 `password` 为主、`publicKey` 为兼容。**不要**反过来改（skill 的 changelog 写反了，附录 E 有说明）。
4. **Xray 版本策略。** `releases/latest` 半年停在 `v26.3.27`，pre-release 已滚了 13 个版本（`v26.4.13` … `v26.9.9`）。
   若要跟进 pre-release，`lib/install.sh::xray_release_base_url` 与 CI 钉版本要一起改，并在 README 写明风险；本版不做。

---

## 附录 A：1.1.0 的命令与菜单

CLI（`dispatch_cli_command`）：

```
install [参数]            update-script          upgrade
check-sni [域名] [--target host:port] [--timeout N]
change-uuid [参数]        change-sni [参数]      change-path [参数]
change-warp [参数]        change-warp-rules [参数]
change-cert-mode [参数]   renew-cert [参数]
show-links [--qr]         diagnose [--warp-probe] [--net]
status [--raw]            restart                repair-perms
apply-config [--manage-nginx-main]   apply-net-opt [--bbr-kernel joey|none]
uninstall [--yes] [--purge]          version      help
```

删除：`change-sub-token`。

菜单（`show_main_menu` / `run_menu_choice`）：

```
  1. 安装或重装
  2. 查看节点链接与二维码
  3. 运行诊断
  4. 刷新状态面板
  5. 重启服务
  6. 更新脚本本身
  7. 升级 Xray 核心
  8. 轮换节点 UUID
  9. 修改 REALITY SNI
 10. 检查 REALITY SNI 域名
 11. 修改 XHTTP 路径
 12. 开关 WARP 分流
 13. 查看 WARP 分流规则
 14. 修改证书模式 / CDN 域名
 15. 续期 / 刷新证书
 16. 重新应用网络优化
 17. 重新生成托管配置
 18. 抢修文件权限
 19. 卸载
  0. 退出
```

## 附录 B：状态文件 v2 键表（1.1.0）

与 `docs/archive/PLAN-1.0.0.md` 附录 B 相同，去掉 `SUB_TOKEN`。旧文件里的 `SUB_TOKEN` 加载时按未知键跳过，写回时消失。

## 附录 C：托管文件清单（1.1.0）

```
/usr/local/sbin/xtun                          管理命令 wrapper
/usr/local/lib/xtun/                          脚本 bundle（xtun.sh / lib / static）
/usr/local/bin/xray  /usr/local/share/xray/   核心与 geo 资源
/usr/local/etc/xray/config.json               0640 root:xray
    本机端口：2443 Reality 入站 / 2444 dokodemo 回落过滤 / 8001 XHTTP 入站 / 8443 nginx TLS
/usr/local/etc/xray/node-meta.env             0600
/usr/local/etc/xray/warp-domains.list
/etc/systemd/system/xray.service
/etc/systemd/system/nginx.service.d/xtun-limits.conf   LimitNOFILE + Restart
/etc/haproxy/haproxy.cfg
/etc/nginx/nginx.conf                         仅 NGINX_MAIN_MANAGED=yes
/etc/nginx/conf.d/xtun.conf                   （不再有 /sub/ location）
/etc/ssl/xtun/{cert,key}.pem
/etc/sysctl.d/98-xtun-net.conf
/usr/local/sbin/xtun-net-optimize.sh  +  xtun-net-optimize.service
/usr/local/sbin/xtun-cert-reload.sh           acme 模式
/etc/logrotate.d/xtun
/var/www/xtun-fallback/                       伪装站
/root/xtun-output.md                          人类可读输出（节点 1–9 + 二维码段）
/root/xtun-qr/NN-<节点名>.png                  节点二维码 PNG，0700 / 0600
/root/xtun-backups/                           变更备份
/var/log/xtun/operations.log
```

删除：`/var/www/xtun-sub/`（进 `legacy_managed_paths`）。

## 附录 D：分享链接长度实测与二维码容量

2026-09-09 用本仓库生成器实测（前缀 `HKG`，路径 `/assets/v3`，VLESS Encryption 开，字符数）：

| 节点 | 默认（ECH 关、xpadding 关） | 全开（ECH + xpadding） |
| --- | --- | --- |
| 1 REALITY | 264 | 264 |
| 2 XHTTP-REALITY | 531 | 728 |
| 3 XHTTP-CDN | 554 | 812 |
| 4 XHTTP-SPLIT-CDN-REALITY | 1238 | 1693 |
| 5 XHTTP-SPLIT-REALITY-CDN | 1156 | 1637 |
| 6 REALITY-V6 | 272 | 272 |
| 7 XHTTP-SPLIT-CDN-REALITY-V6 | 1258 | 1713 |
| 8 XHTTP-TLS-H3 | 355 | 355 |
| 9 XHTTP-SPLIT-CDN-H3 | 985 | 1243 |

QR 码字节模式最大容量（版本 40）：L 2953、M 2331、Q 1663、H 1273。最长的 1713 字符在 L 级落在版本 30（137×137 模块）；
Q / H 级装不下节点 4 / 5 / 7 的全开形态，所以 §5.3 钉死 `-l L`。链接长度若将来超过 2953，`qrencode` 会失败，`write_link_qr_pngs` 只 warn 该条并继续。

## 附录 E：skill 修正清单（`.claude/skills/xray-core-official-knowledge/`）

先说结论：**skill 的两个「原材料层」是真的、也是新的**——`docs/stable/` 与 `source/` 分别是 `XTLS/Xray-docs-next` 与 `XTLS/Xray-core` 的 `main` 快照，
2026-09-09 抽查 `infra/conf/transport_security.go`、`transport/internet/splithttp/config.go`、`docs/config/transports/reality.md` 三个文件与上游逐字节一致，
记录的提交 `52a412d9…` 就是当天 Xray-core `main` 的 HEAD。**手写的「加工层」不可靠**：`changelog/`、`extracted/` 里有几处结论与它自己收录的文档 / 源码相反。
实施者用 skill 时：**只信 `docs/stable/config/` 与 `source/`，`changelog/` 与 `extracted/` 的每一句话都要回到前两者核对。** 下面逐条修：

| # | 文件 | 现状 | 错在哪 / 证据 | 改法 |
| --- | --- | --- | --- | --- |
| 1 | `changelog/v26.9.9.md`「Known Field Changes」表 `target` 行 | 「`target` (REALITY server) Renamed → Use `dest` instead. `target` is still accepted as alias」 | 方向反了。`docs/stable/config/transports/reality.md:74-78`：「`target` … **旧称 dest**, 当前版本两个字段互为alias」；`source/config/transport_security.go:30-31` 同时有 `Target` 与 `Dest` | 改为「`dest` 是旧名，`target` 是现名，互为别名」 |
| 2 | 同表 `password` 行 | 「`password` (REALITY client) Renamed → Use `publicKey` instead」 | 方向反了。`reality.md:195-197`：「`password` … **旧称 publicKey**, 为防止误解更名」 | 改为「`publicKey` 是旧名，`password` 是现名，互为别名」 |
| 3 | 同表 `allowInsecure` 行 + 「Security: TLS」段 + 「Deprecations」表 | 「Removed v25.x+ — Setting to `true` now errors」 | 过度断言。`tls.md:91-100`：「该选项**已被弃用**，使用 `pinnedPeerCertSha256`」；`transport_security.go:301` 仍有 `AllowInsecure bool` 字段。文档没有说填 true 会报错 | 改为「已弃用（deprecated），仍可解析；官方建议改用 `pinnedPeerCertSha256` / `verifyPeerCertByName`」 |
| 4 | 同文件「Highlights」 | 「Latest stable release covered by this knowledge base」 | `v26.9.9` 是 pre-release（GitHub Releases `prerelease=true`，2026-09-08 发布）；`v26.4.13` 到 `v26.9.9` 全是 pre-release，最新正式版是 `v26.3.27` | 改为「最新 pre-release；最新 stable 为 v26.3.27」 |
| 5 | 同文件其余行（`spiderX` 默认值、`.ru/.ir/.cn/apple/icloud/microsoft` 域名告警、`xPaddingBytes` 不可关闭等） | 无出处 | 未逐条核对，也没有引用 | 每行补 `source/` 或 `docs/` 的文件:行号；补不出来的删掉 |
| 6 | `extracted/parameters/reality-settings.yaml` `dest / target` 字段 | 「旧字段名为 target，现已由 dest 统一替代」 | 与第 1 条同一错误 | 改为「旧名 dest，现名 target，互为别名」 |
| 7 | `extracted/parameters/splithttp-xhttp.yaml` | `version_introduced: v1.8.0 (SplitHTTP…)` | REALITY 在 1.8.0，SplitHTTP 是 2024 年中（1.8.16 附近）才加入，`v1.8.0` 是错把两者混了 | 查 `source/releases` 之外的 GitHub Releases 后填准确版本，查不到就写 `unknown` |
| 8 | `sources.yaml` | `last_sync` 与所有 `*_snapshot_date` 是 `2025-09-09` | 年份错一年（Xray 版本号 `v26.x` 即 2026 年） | 改 `2026-09-09T14:40:00Z` |
| 9 | `sources.yaml::covered_versions.stable` | `v26.9.9` | 见第 4 条 | `stable: v26.3.27`（commit 按 tag 填），`beta: v26.9.9` |
| 10 | `SKILL.md` frontmatter `metadata` | `current_stable` / `current_beta` / `last_sync` 全空 | 与 `sources.yaml` 不一致，agent 会先看这里 | 填 `v26.3.27` / `v26.9.9` / `2026-09-09` |
| 11 | `SKILL.md`「Knowledge Base Architecture」与「Quick Reference」 | 把 `changelog/`、`extracted/`、`citations/` 与 `docs/`、`source/` 并列为可信来源 | `citations/` 只有模板；`extracted/` 与 `changelog/` 有上述错误 | 加一段「置信度说明」：`docs/` 与 `source/` 为一手来源；`extracted/` 与 `changelog/` 是人工摘要，引用前必须回到一手来源核对 |
| 12 | `source/releases/*.md` | 10 个 pre-release 的正文基本只有赞助商与「See …」指向 | 内容量极低，且都不是 stable | 保留即可，但 `SKILL.md` 不要再声称它能回答「When was X added」 |
| 13 | `scripts/extract-config.sh` | 全是注释掉的示例命令，运行后什么都不产出 | 名不副实 | 要么写成真的（`git clone` + 复制 `infra/conf` / `transport/internet` + 更新 `sources.yaml`），要么改名 `extract-config.example.sh` |

## 附录 F：把本机（生产节点）升到 1.1.0 的操作

本机现状：`xtun 1.0.0`、`ENABLE_WARP=yes`、H3 未启用（证书模式决定）、没有安装 `qrencode`、`/var/www/xtun-sub/<token>/` 存在。

1. `xtun update-script`。
2. `apt-get install -y qrencode`（`apply-config` 不跑 `install_packages`，缺它 PNG 会被跳过并告警）。
3. `xtun apply-config`：
   - 「清理旧版本遗留的托管文件」一步会删掉 `/var/www/xtun-sub`；
   - `xtun.conf` 重新生成（少了 `/sub/` location），nginx 走 reload；xray 照常重启一次（会掐断在跑的连接，选个空闲时段）；
   - 输出文件重写，`/root/xtun-qr/` 出现 5 张 PNG（`01-…` 到 `05-…`；本机无 IPv6 直连、H3 未启用）。
4. `xtun show-links --qr` 看一眼；`ls -l /root/xtun-qr`。
5. 把 PNG 拿回本地：`scp root@<本机 IP>:/root/xtun-qr/'*.png' .`，客户端删掉旧订阅、按需扫码重导。
6. `xtun diagnose` 应不再出现「订阅自检」行；`xtun status` 面板多一行「二维码目录」。
7. Cloudflare 缓存绕过规则里的 `/sub/` 子句可以留着，不影响任何东西。
