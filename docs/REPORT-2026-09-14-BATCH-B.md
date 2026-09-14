# 批次 B 实施报告：任务菜单、单节点取用与 H3 意图

> 日期：2026-09-14。范围：W07 的实现与自动验证、W11.1、W09.1，以及直接相关的回归修复。用户已授权继续实施、提交和 push。正式 tag/release、生产迁移与完整人机/网络验收不在本次完成结论内。
> 当前入口：[PLAN](PLAN.md)；目标与遗留：[详细工单](PLAN-UX-RELIABILITY.md)；行为契约：[D27–D31](DECISIONS-UX-RELIABILITY.md#d27)。前序报告保持原样，不把本次结果回写成旧时已通过。

## 1. 结论与候选身份

批次 B 已完成六组任务菜单、返回/取消、维护影响预览、单节点链接/二维码取用和 H3 持久意图。两架构完整 smoke、安装/菜单 PTY 通过；测试 VPS 的真实 bundle 更新、路径变更和输出失败恢复通过。下一独立代码批次为 C：W08.2/8.3 安装身份与可信同版本行为。

| 对象 | 准确记录 |
| --- | --- |
| 接手 Git 基线 | `main / c1fabf74bbfa8a9132c40b65ccb4678424bb5111`；开工 fetch 后与 origin/main 一致，保留累积工作区 |
| 提交范围 | `a1da4c71005617e2a6eba5c1264de76c7ddde00c` 已 push，包含前序 W01–W06/W08.1、A 批累积实现与 B 批。其后的 CI 修复仅改测试、工作流和文档，见 §4.1 |
| 脚本 / state | `1.1.0` / schema `2`；没有因中间候选另升发布版本 |
| 最终运行内容摘要 | `31574b9dbd302342dad45461ab9c435ece6e3e158c3666ba394601e17e56fd67`；由 `bundle_script_signature` 对 `xtun.sh/lib/static` 计算 |
| push 前验收归档 | `candidate-acceptance.tar.gz`；SHA256 `e481b18c081d007eaefc576460c3847f67d7f7d656d5692ba9ed4117a1d3e26e`；包含当时运行文件、tests、`.shellcheckrc`。后续测试修复以 Git 内容为准，不声称该归档已含修复 |
| 目标 Xray | `v26.9.9 / 52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120`；本机使用独立 arm64 核心，VPS 使用 amd64 核心 |
| 本机验证 | arm64，Bash 5.2.37；本机已安装的生产 bundle/core 保持原状 |
| VPS 验证 | `194.195.251.247`，Debian 12 amd64，Bash 5.2.15；实际 nginx 1.30.1 包含 http_v3；测试自签证书 |
| CI 边界 | 首次 push 的 [34842326929](https://github.com/milikii/xtun/actions/runs/34842326929) 失败；已定位并修正测试输入、执行身份及旧输出断言，见 §4.1。后续公开结果仍须核对修复提交的准确 SHA |
| 发布状态 | 本次只提交/push 测试候选；不创建或移动 tag，不创建正式 release，不迁移本机生产 |

运行摘要只覆盖安装内容，Git 提交还包括测试与文档。两者分别保留，不能用版本字符串 `1.1.0` 推断是同一包。W08.2 将继续补齐持久安装身份。

## 2. 本次实现

### W07：按任务组织菜单与维护动作

- 未安装入口提供安装/恢复草稿、环境端口、SNI 和帮助；已安装入口为获取节点、状态诊断、修改节点、升级维护、网络可选功能、恢复卸载六组。配置存在但 state 缺失时仍显示维护/恢复入口。
- 获取节点在两级内完成，保留 CLI 名称及节点 1–9 编号。没有实现的 NAS 原生导出或独立二维码重建不出现在菜单中。
- `:back` 返回已登记字段，保留其它有效输入并重新校验；`:cancel` 取消当前动作。菜单 EOF 结束会话，输入失败不循环读取空 stdin。秘密字段不回显历史内容。
- 每个菜单动作隔离请求、版本、跳过检查、非交互选择和输入历史。失败、取消或 Ctrl-C 后菜单可继续执行不同动作。TERM 发送到菜单父进程时转交动作，等待清理/恢复完成后以 143 退出。
- 修改前显示非敏感旧值→新值、需重导入节点、文件、服务及连接中断范围；确认后取锁并复核现场。UUID/path/H3 等同值结果不创建备份、不应用服务，返回编辑撤销变化后再判一次 noop。
- 更新脚本、升级、重启、权限修复、配置/网络重建和换证提供相应预览。自动化维护显式使用 `--non-interactive` 或 `--yes`，关闭 stdin 不能代替同意。
- 首屏缩短长域名、监听与恢复路径；80×24 自动测试覆盖长字段及 pending。证书 UI 统一 1=自签、2=已有、3=ACME；历史 CLI 数字 3=existing、4=ACME 保留。

预览中的 Xray restart 会影响经过 Xray 的连接；nginx/HAProxy reload 失败仍可能回退到 restart。此次没有持续业务连接测量，不能据此给出实际中断时长或无损维护承诺。W07 的真人可理解性继续归 W14 验收。

### W11.1：只读取已提交产物

| 命令 | 当前行为 |
| --- | --- |
| `xtun show-links` | 原样读取完整部署文档 |
| `xtun show-links --summary` | 节点清单、文档和各 PNG 位置，不打印 URI 正文 |
| `xtun show-links --node 3` | 直接显示节点 3 的名称、链接和 PNG 位置 |
| `xtun show-links --qr --node 3` | 直接显示所选二维码；不先输出完整文档 |

`--node=N` 同样支持；只接受当前存在的标准编号 1–9，禁用/不存在节点、无效编号和 summary/qr 冲突返回非零。读取保留文档中的节点编号；旧文档没有标题时兼容顺序编号。

二维码先编码再测量 UTF8 行数/宽度，超过当前终端尺寸时指向已有 PNG，默认尺寸 80×24。缺 qrencode 但已有 PNG 时可以取用路径；编码器与 PNG 都不可用或编码失败则非零。查看不生成文件、不改 state、不重启服务。规范节点对象、独立导出、真实 PNG 解码和 NAS JSON 仍为 W11.2/11.3。

### W09.1：H3 选择、能力与实际传输分开

1. `H3_INTENT=off/on/legacy-on/unknown` 写入 state 和草稿；新装 off。安装开关 `--enable-h3` / `--disable-h3`、高级设置和 `change-h3` 使用同一选择。
2. 旧 state 缺字段时，只在完整托管 nginx server 内同时核对域名、证书引用、QUIC 和 Alt-Svc 才识别 legacy-on；清晰未开启配置识别 off，残缺/不明证据为 unknown。忽略注释与用户保留块，查看不写迁移结果。
3. 本次能力检查验证实际 nginx 模块、证书/密钥匹配、DNS SAN、有效期、服务器用途、完整链到发行版 Mozilla 公共根，并检查 UDP 443 全部监听归属。管理员自行导入的私有 CA 不当作公共信任。
4. Origin CA、自签、缺中间链、域名不符、过期、未知工具/信任均不能放行直连 H3。existing/ACME 仍只表示来源。检查不联网补中间链、不写临时证书。
5. UDP 空闲或由已有托管 H3 的 nginx.service 进程占用才允许开启；同名 nginx 还要核对精确 cgroup 或后代。外来或无法证明的进程不接管、不停止。
6. `H3_DECISION` 与能力原因只代表本次检查，不持久化为永久能力。生成前、局部 Xray 更新和证书提升前复核；nginx QUIC、Alt-Svc、节点 8/9 与说明消费同一结果。条件失效时失败并保留或恢复旧配置。
7. 节点 9 的 H3 ALPN 从下载流根部移到 `downloadSettings.tlsSettings.alpn=["h3"]`，外层 CDN 保持 H2。没有夹带节点 7、users/xmux 或 ECH 迁移。

ALPN 依据为仓库官方快照的 `source/config/transport_internet.go`（StreamConfig 的 TLSSettings）、`source/config/transport_security.go`（TLSConfig.ALPN）和 `source/transport/internet/splithttp/dialer.go`（`decideHTTPVersion`）。均对应上述 v26.9.9 固定提交；`docs/stable/config/` 用于配置解释，滚动文档不冒充版本绑定。没有用 `changelog/` 或 `extracted/` 的人工摘要代替源码。

## 3. 复验中发现并修复的问题

| 反例 | 修复与证据 |
| --- | --- |
| 新增确认使旧 WARP 回归停在 EOF，没进入原本要测试的失败路径 | 测试桩显式非交互，并新增“实际应用被调用一次”断言；保留失败码和禁止旧可选组件回退的断言 |
| 二维码桩不消费 stdin，amd64 上上游 printf 偶发 SIGPIPE | 桩按真实编码器读取输入；没有关闭 pipefail 或放宽生产失败判断 |
| 只给菜单父进程 TERM，动作可能仍在读取 | 父菜单转交 TERM 并等待子进程恢复；专门 PTY 场景只向父 PID 发信号 |
| Debian 12 Bash 5.2.15 在 `read -p` 提示刚出现时收到信号，继续等输入 | 独立最小复现 15/15 卡住；提示与 read 分开后 15/15 返回 143。实际安装/菜单 INT、TERM 场景重新通过，未靠延长超时或延迟发信号掩盖 |
| 证书 UI 的第 3 项仍显示已有证书，但新映射已是 ACME | 展示与默认编号统一为 1/2/3；测试穿过实际输入映射，并独立保留旧 CLI 数字兼容 |
| 新的提示输出失败返回值可能被菜单吞掉 | 菜单处理暂停失败、恢复原 trap 并返回非零；既有 errexit lint 继续生效 |

原始失败日志与最小反例保留在私有证据目录。没有把完整测试函数放进 `if`/`||`，以免使内部裸断言失效；修改测试桩时增加实际执行断言，没有只改期望让结果变绿。

## 4. 自动验证结果

| 检查 | 结果 | 证明范围 |
| --- | --- | --- |
| Bash 语法 / ShellCheck | 54/54 文件通过；逐文件 `bash -n` | 运行和测试 Shell；Python 测试文件也通过语法解析 |
| canonical smoke，arm64 | 220/220 | 前序契约、归属、generation、版本、安装、SNI 等回归加 B 的 10 项 |
| canonical smoke，Debian 12 amd64 | 220/220 | 相同归档，原生目标核心；含真实证书夹具与输出检查 |
| 安装 PTY，arm64 / amd64 | 各 68/68 | fresh/resume/rebuild/rotate × CLI/安装任务菜单，取消/EOF/返回/确认/INT/TERM/exit，草稿与恢复 |
| 任务菜单 PTY，arm64 / amd64 | 各 9/9 | 取节点、取消、EOF、输入 INT、非法输入/返回/noop、连续 WARP 开关、执行失败/INT/仅父进程 TERM |
| H3 判定矩阵 | 400 个组合通过，包含于 smoke | 4 种意图 × 2 种模块 × 10 种证书状态 × 5 种 UDP 状态；能力使用受控桩 |
| 真实 OpenSSL 夹具 | 通过，包含于 smoke | 完整链、缺中间链、错密钥/SAN、过期/未来、错误用途、自签、Origin CA、无根/缺文件；正向使用明确替换的测试根 |
| 80×24 / 只读查看 | 通过，包含于 smoke | 长域名/监听/pending 首屏，纯读取前后文件一致；不代替真人扫码 |

证书正向夹具使用自建根，仅证明验证逻辑与分类，不是生产公网证书实证。PTY 执行部分使用隔离目录与服务桩，不当作 systemd 或真实传输通过；真实 VPS 维护另列如下。

### 4.1 首次公开 CI 失败与修复

首次 push `a1da4c7` 的 CI `34842326929` 中，ShellCheck 通过，smoke、两套 PTY 与 Debian 13 安装容器步骤失败。此前双架构回归均以 root 在已部署主机运行，未覆盖干净 runner 的证书输入和执行身份差异。保留该失败，不把 push 前通过结果改写为 CI 已通过。

| 发现 | 复现与修复 |
| --- | --- |
| 安装 CLI/菜单一致性测试把 existing 证书指向 `/etc/ssl/xtun` | 在 `/tmp` 的独立候选副本以普通用户复现缺证书失败；state 夹具改为生成自己的证书/私钥并引用隔离路径，保留真实只读检查，失败 stderr 不再丢弃 |
| PTY 在真实 root 检查处退出，未进入问答；完整 smoke 随后也在 `recover --yes` 处遇到相同问题 | 普通用户下保留两类失败证据；CI 的三套测试使用 sudo，保留真实 root 检查；完整套件误以非 root 启动时提前返回 2。原有无 root 帮助场景仍用 `setpriv` 降权执行 |
| 容器 suite 仍要求已删除的 `二维码 (` 标题 | 在已安装候选的 VPS 上复现旧断言失败；新断言检查五个节点、五张真实 PNG 文件头、对应输出路径及文档。没有从匿名不可读的容器日志推断首次失败的精确行，完整容器结果以后续 CI 为准 |
| PTY/容器失败只有笼统退出码 | PTY 增加失败用例 annotation；安装 smoke 增加行号、命令和退出码 annotation，Docker 显式传递 `GITHUB_ACTIONS`，保留原失败码 |

修复后本机 arm64 的 54 个 Shell 文件静态检查、220/220 smoke、68/68 安装 PTY、9/9 菜单 PTY 通过。普通用户下安装 CLI/菜单一致性用例返回 0；完整三套测试的权限前置检查分别返回 2。VPS 只读复验五节点/PNG 新断言通过，SSH 仍为 PID 524、active/enabled。Debian 13 干净容器的完整结果须由新提交的 CI 补齐，不能用这次已有部署上的 QR 检查代替。

后续提交 `c7bc47329edc2bb969175e502ddf942b96b1f48c` 的 [CI 34844671940](https://github.com/milikii/xtun/actions/runs/34844671940) 中，两套 PTY 与 ShellCheck 已通过，smoke 继续暴露缺少 geo 数据的问题，容器确认在完整安装命令内失败、早于 QR 检查：

- CI 的核心准备步骤只安装二进制，真实 `run -test` 在加载 `geoip:private` 时失败。Xray v26.9.9 的 `common/platform/others.go:GetAssetLocation` 会在指定目录缺文件时继续查系统目录，因此本机/VPS 的已部署数据遮住了缺项。原用例在私有挂载空间屏蔽系统 geo 目录后，明确报 `failed to open geoip.dat`；没有移动或删除宿主文件。
- 核心准备改为从同一份已校验归档安装两份数据；测试入口显式检查资源目录并设置 `XRAY_LOCATION_ASSET`。二维码恢复用例增加“编码器确实被调用”的断言，避免把更早的配置失败误当成预期故障。
- 容器安装/诊断保留独立日志，失败 annotation 附末尾 30 行并保持 pipeline 的真实退出码，以便继续定位干净系统安装失败。

上述源码按固定提交 `52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120` 核对；仓库滚动官网 `docs/stable/config/env.md` 用于环境变量解释。该源文件不在原选定快照范围内，固定版本原文保存在私有证据的 `official-source/`，未改写技能快照。

补充修复后，在私有挂载空间隐藏宿主证书和系统 geo 目录，使用独立归档中的核心/数据运行 220/220 smoke 通过；54 个 Shell 静态检查及 68/68、9/9 两套 PTY 再次通过。显式缺 geo 目录会在用例开始前失败；安装日志管道的注入失败保留退出码 7 并产生含错误末尾的 annotation。

修复没有改动 `xtun.sh/lib/static`，运行摘要与 VPS 已安装候选保持一致。新增私有证据放在本报告证据根的 `ci-followup/`，包括原始失败、普通用户复现、修复后回归和后续公开 CI 查询；它与 push 前归档分开保留。发布门槛、真人/真实传输和下一批 C 的范围不变。

## 5. 测试 VPS 的实际维护

实际执行 20 个命令并核对退出码、文件摘要/权限、state、链接、PNG、备份集合和服务状态：

| 组别 | 结果 |
| --- | --- |
| 查看 / 负向 / 同值，共 10 项 | status、摘要、单节点和 QR 成功；节点 8 不存在返回 1；自签证书显式开启 H3 返回 1；H3 off/path/UUID 同值成功；真实临时外来 UDP 443 监听被识别为 foreign 且保持存活。整组前后托管文件、备份与服务 PID 完全一致 |
| 更新 bundle，共 2 项 | 使用本地候选归档 URL 执行真实 update-script；安装摘要与候选一致，不重启三个服务。已安装入口再次更新相同内容为 noop，文件/备份/PID 不变 |
| 路径变更与还原，共 2 项 | 已安装 CLI 修改到 `/batch-b-20260914` 再还原；state 持久写入 H3 off，实际提交完成且无 pending；UUID、密钥、shortId、Encryption 和原链接保持 |
| 输出故障，共 1 项 | 在真实 state/输出/PNG 已写后注入失败，命令返回 1；通过同代恢复还原文件/权限/URI 与操作前服务状态，无 pending。故障通过候选函数派发注入，不称为原生 CLI 自带故障开关 |
| 最终校验，共 5 项 | 实际 Xray、nginx、HAProxy 配置检查以及已安装 CLI diagnose/status 全部返回 0 |

最终 state 为 H3 off，nginx 没有 QUIC/Alt-Svc，保留 5 条节点及 5 张 PNG。输出/PNG 为 0600、PNG 目录 0700。三服务 active/enabled；`2026-09-14 12:04:04 UTC` 的 PID 分别为 Xray 987684、nginx 987737、HAProxy 987710。路径应用/恢复允许这些业务服务重启，未声称业务 PID 保持不变。

SSH 主进程始终为 524，active/enabled；root 密码哈希指纹与开测前相同，sshd 主配置摘要核对通过。未修改 SSH 密码或配置。

本次复用批次 A 的测试机现场：nginx 实际二进制 1.30.1，dpkg 记录仍为 `1.22.1-9+deb12u9`。这是一项已知前序人工修复后的差异，详见[前序报告 §4](REPORT-2026-09-14-W04R-W05R.md)。本次未重新安装 nginx 包，也不把该机器称为干净安装或字节级完整恢复的环境。

## 6. 本机保护与证据位置

本机生产仍为 bundle 0.11.14、实际 state 2、Xray 26.3.27/arm64。批次 B 单独选定的 62 个文件/目录/链接，其内容、类型、权限、UID/GID 与链接目标前后相同；Xray/nginx/HAProxy 的 PID 709/701/648、active/enabled 状态不变。该范围与 A 报告的 63 条各自按独立基线比较，数量差异不表示删除了一个文件。

- 本机私有目录：`/root/xtun-evidence/20260914-batch-b/`。包含开工工作区归档、最终候选身份、`static-verified.log`、`smoke-verified.log`、`install-boundary-verified/`、`task-menu-verified/`、生产前后快照与比较。
- VPS 私有目录：`/root/xtun-batch-b-evidence/`。包含同一候选、双 PTY、原生 smoke、`vps-acceptance.py`、20 项日志、前后快照、信号最小反例与 SSH 核对。
- VPS 证据已取回为 `xtun-batch-b-verified-evidence.tar.gz`；SHA256 `04aa5e331ad74968bda51c744e7725a0346b719d6ca2a4cb2dc7dccc75d48b0d`。私有配置、凭据/URI 和原始证据不提交仓库。

前序 systemd 13/13、文件系统 5/5、归属 5/5、极简依赖 5/5 与安装/升级恢复报告继续有效；此次没有把它们改写成本批新执行的结果。

## 7. 遗留与下一次施工

| 下一项 | 具体要求 |
| --- | --- |
| C：W08.2/8.3 | 保存入口/bundle/core/geo 的准确身份与摘要；写入口下载/校验失败不静默回用旧包；可信同版本 noop；实现显式 reinstall，失败覆盖核心、geo、权限能力、state 与 bundle |
| G1 补证 | 隔离 VM 强制断电和持久恢复；SIGKILL、trap 或文件系统故障不代签 |
| D：W09 余项、W10、W11.2/11.3 | 节点 7 CDN/IPv6 路径、users/xmux/ECH 迁移、同源 URI/PNG/JSON、独立二维码重建与 NAS 产品入口；节点 9 已修 ALPN 仍需真实路径验证 |
| E：W12 | 人工/自动续证共锁、成对提升/恢复、实际供证核对；共用能力检查不等于生命周期完成 |
| W13–W16 | 公开候选 CI、系统/迁移矩阵、五节点原生双向传输、两轮真人和 Android/Windows/NAS、CF/ECH/H3、公网 UDP、72 小时及同组合 7 天观察 |

接手先核对公开提交、运行摘要、VPS 安装身份和 pending，不重做已通过的 A/B 实现；按 C 的验收拆分施工。保持完整范围统一发布，用户设备到位后补齐真人/三端；本机生产与测试 VPS 的 SSH 约束持续有效。
