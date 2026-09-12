# xtun 后续计划：以 Xray v26.9.9 为起点持续追新

> 核验日期：2026-09-12。实施基线：本地 `main` 的 `f219480`。
> 本文只规划后续实施；本次仅更新计划文档，没有修代码、发布版本或升级生产节点。
> 核心要求：当前接入 `v26.9.9`；后续默认新装和显式升级跟踪最新官方发布，包含预发布。
> 实施路线：目标核心与追新机制、CI/P0 修复 → 新装/导出/参数迁移 → 生命周期与真实客户端验收 → PQ 观察及签名调查。

详细工单、官方版本证据、参数迁移及新 VPS 验收以 [生产就绪实施计划](PLAN-PRODUCTION-READINESS.md) 为准。本文保留 CI 和 SNI 的具体设计；历史计划中与新版核心策略冲突的决策不再沿用。

已补齐 [REALITY/XHTTP/ECH 参数契约](PARAMETERS.md) 与 [测试 VPS、三端交互验收手册](TEST-VPS-RUNBOOK.md)。前者确定参数和社区证据的适用边界，后者给出实施完成后在 Android v2rayNG、Windows v2rayN、Debian NAS Docker 上的实际验收步骤。

## 1. 已完成的工作与真实待办

已阅读 pi 最新会话 `2026-09-10T02-31-43-326Z_01a08928-1fde-70ad-9858-98250718f903.jsonl`，并对照本地代码、远端 refs 和 GitHub Actions 重新核验。

| 项目 | 2026-09-12 核验结果 | 后续处理 |
| --- | --- | --- |
| 1.1.0 仓库卫生、去订阅、PNG/H3 导出、文档版本 | `342ee62`、`1919587`、`4316782`、`4340759` 已完成 | 不重复实施 |
| 旧计划 §7 的三项代码清理 | `f219480` 已完成，含 bundle 签名回归用例 | 随修复一起发布 |
| 发布状态 | 远端 `main` 与 `v1.1.0` 均为 `4340759`；本地领先一个代码提交 | 尚不能把 `f219480` 当成用户已经下载到的代码 |
| 本地 smoke | 既有核验记录 **113 条通过，`smoke ok`**；本次 v26.9.9 计划修订未重跑全套 | 旧记录不能替代目标核心验收 |
| 本地 ShellCheck | 本次实测 `tests/cases_output.sh:819` 触发 **SC2012** | P0 修复，不沿用旧会话“零发现”的结论 |
| 远端 CI | 最近两次失败；最新一次 smoke 成功，但 ShellCheck 和 install-smoke 失败 | P0 修复并重新验证两个 job |
| 本机已安装 bundle | 只读检查仍为 **0.11.14**，不是旧施工图附录 F 所写的 1.0.0 | 生产升级继续暂缓 |
| 本机 Xray | 只读记录为 **26.3.27、linux/arm64** | 保留历史现场，本轮只更新文档 |
| 本轮核心目标 | 官方 **v26.9.9**，提交 `52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120`，标记 pre-release | 按用户选择采用，当前尚未完成该版本二进制/新装验收 |

远端证据：[1.1.0 CI 运行](https://github.com/milikii/xtun/actions/runs/34382309011)、[前一次失败运行](https://github.com/milikii/xtun/actions/runs/34381670972)。CI 日志下载接口返回 403；job/step 结果可以读取。下文将本地复现与远端结果区分，不假称读到了完整日志。

历史设计归档在 [1.1.0 施工图](archive/PLAN-1.1.0.md) 与 [1.0.0 施工图](archive/PLAN-1.0.0.md)。旧计划的历史决策不整体继承；与新版本冲突时，以当前代码及本文为准。

**持续约束：** 用户已明确要求“本机的生产节点暂时别动”。实施期间允许仓库修改、沙箱测试和 CI 容器验证；不在宿主机运行安装、更新 bundle、apply-config、服务重启、包安装或配置迁移。生产升级须另行明确安排，不是发布后的自动步骤。

## 2. P0：v26.9.9 接入、追新机制与 1.1.1 修复收口

目标：把已经完成的 1.1.0 功能和 `f219480` 修复，连同目标核心接入及已确认的默认安装 P0 修复，交付到经过 CI 验证的候选修复版。`v26.9.9` 是这一阶段的必做项。

### 改动

1. **接入 v26.9.9 和统一版本解析。** 安装器与 CI 共用版本模块、架构资产映射和摘要验证。默认使用官方 releases 列表，选择最高数值版本的非 draft 发布，包含 pre-release；显式 tag 供复现和回退。一次操作只解析一次，不能用 `/releases/latest` 或 `/latest/download` 继续获得旧正式版。解析、分页、版本锁定及资产规则详见 [详细计划 §7/C1](PLAN-PRODUCTION-READINESS.md#c1-版本解析下载与运行时产物)。
2. **修复二维码测试的 SC2012。** `run_link_qr_png_case` 的 `ls … | wc -l` 改成对目录第一层普通 PNG 文件计数，例如 `find … -maxdepth 1 -type f -name '*.png' -printf '.' | wc -c`。保留“恰好 5 张”、权限与过期文件清理断言；不屏蔽诊断、不降低 lint 等级。
3. **移出 CI 内嵌的安装脚本。** `.github/workflows/ci.yml` 的 `Run install smoke` 使用 `docker exec smoke bash -eux /src/tests/install-smoke.sh`，把原有容器内部步骤迁入新脚本，再接入共享的核心选择。脚本继续在一次性 Debian 容器内安装依赖、复制 `/src` 到 `/root/xtun`、安装、diagnose 和校验导出文件，工作流保留容器启动、调试与清理步骤。
4. **保留完整安装验收。** 新脚本保留 PNG 数量、订阅目录/location 已删除、二维码段与终端二维码断言；计数同样不用 `ls`。先将 `xtun show-links --qr` 的完整输出写入容器临时文件，再 grep，避免只消费前半段输出。`qrencode` 仍由 xtun 安装器负责安装；后续极简镜像验收不得预装工具掩盖引导依赖缺口。
5. **一并修复默认安装 P0。** 完成 HTTP SNI 探测将域名误传 curl `--resolve` 的修复，以及 `--no-ipv6` 吞掉后续开关的问题。具体为详细计划 T02/T03；CI 恢复绿色后也必须完成这些修复才能正式打 tag。
6. **版本收口。** 上述改动与 `f219480` 一并形成 `1.1.1` 候选，同步 `SCRIPT_VERSION` 和 README，说明最新版核心策略、CI 与安装修复。状态版本按实际兼容语义决定，纯 CI 改动不调整 `STATE_VERSION_CURRENT`；现有 `v1.1.0` tag 不移动。

install-smoke 的语法错误已通过对工作流该 `run` 块执行 `bash -n` 复现：外层 `bash -euxc '…'` 被内部 `grep -q '二维码 ('` 的单引号截断，报 `syntax error near unexpected token '('`。迁出脚本后，它也会被现有“扫描 lib/tests 中所有 shell 文件”的 ShellCheck 步骤覆盖。

### 验收与交付顺序

- 新安装脚本 `bash -n` 通过；ShellCheck 全量零发现；现有 113 条 smoke 全部通过。
- 在 GitHub Actions 的一次性容器里使用 **v26.9.9** 完整安装；`shellcheck-and-smoke` 和 `install-smoke` **两个 job 均成功**，且使用同一核心解析结果。旧核心上的本地 smoke 成功不能替代这一条。
- 验证默认策略选中最新预发布、显式 tag 可复现、两架构资产与摘要正确；在临时目录核对 `xray version/x25519/vlessenc/run -test`。每日/手动 latest 任务采用同一实现，后续补齐实际传输矩阵。
- F02/F04 默认路径修复完成：至少一次安装不跳过 SNI；`--no-ipv6` 不取值、不吞位且禁用有效。
- 检查运行归档仍含 `xtun.sh/lib/static`，不含 `tests/docs/.claude/.github`；测试脚本从 checkout 的 `/src` 运行，不依赖源码下载归档包含 tests。
- 后续执行发布时，先提交修复及版本变更，再推送并核对 CI 的 `head_sha`，最后在通过验证的提交上创建 `v1.1.1`。本次规划不执行 commit、push 或 tag。

**退出条件：** 远端可下载的代码包含 bundle 签名修复、目标核心/追新机制和默认安装 P0 修复，最终 SHA 的两个 CI job 均绿。随后按详细计划完成其余 B–F 阶段，目标是 `1.2.0` 生产就绪版本；修复版 CI 全绿不等于已证明新 VPS 长期稳定。

## 3. SNI 施工细则：入口修复提前，PQ 观察后置

本节分两组执行：§3.1 的入口、目标与超时修复属于详细计划 B/T03；§3.2 的第 13 项“后量子就绪度”属于 G/T12，安排在基础可靠性验收之后。`1.2.0` 优先交付新装、导出、参数迁移和维护可靠性，不再仅围绕 PQ 观察安排版本。

### 3.1 先修入口与目标一致性

实施集中在 `lib/cli/sni.sh`，沿用“探测函数 + 纯判定函数 + 聚合输出”的分层。

- **无参数入口：** 当前 `sni_check_cmd` 在加载状态前就因空 target 报错，本次用桩复现。调整为先解析 CLI，再按需读取已有状态/config，最后确定 SNI 和 target。显式域名优先；省略域名时使用已安装的 `REALITY_SNI`。显式 `--target` 优先；省略域名且省略 target 时使用已保存的真实 `REALITY_TARGET`，缺失才回退 `SNI:443`；显式域名且省略 target 时直接使用该域名的默认目标，不沿用其它节点的 target。显式 `--server-ip` 不被状态覆盖。无安装状态又未给域名时仍报错。
- **超时必须大于零：** 当前 `--timeout 0` 可以进入探测，而 GNU timeout 的零值会禁用超时。拒绝非数字及全零输入，规范化前导零，保持默认 10 秒和原有参数错误退出码 `1`。它仍表示每次探测预算，不改成整条命令的总预算。
- **所有探测使用同一 target：** 当前 HTTP 探测固定连接 443，会忽略 `--target` 的非默认端口。将其接口改为 `sni_probe_http SNI TARGET TIMEOUT`，使用 curl `--connect-to` 将逻辑请求 `https://<SNI>/` 连到实际 target host/port，保留 SNI/Host。TLS、证书、HTTP、新增 PQ 探测都必须遵循相同的 target；不在本版扩展 target 的地址格式支持范围。

### 3.2 第 13 项的实现约定

新增 `sni_probe_pq TARGET SNI TIMEOUT RESOLVED_IP` 和 `sni_judge_pq PROBE_OUTPUT`，在 `run_sni_checks` 里追加一行 `PASS|后量子就绪度|…` 或 `WARN|后量子就绪度|…`。不新增 CLI 开关、状态键或后台巡检。

**探测：** 使用已有 `${XRAY_BIN}` 的 `tls ping`，由外层 `timeout` 限制执行时间。以 `SNI:目标端口` 为命令位置参数、`-ip` 为 target 的实际 IP，避免把 target 主机名误当 SNI。`RESOLVED_IP` 由聚合层提供：目标为域名时复用本轮 DNS 探测的第一条有效 A 记录，目标本身是 IP 时直接使用，不重复 DNS 查询。

- Xray 缺失、子命令不支持、目标无法解析、超时、握手失败或未知输出格式，统一返回可解释的“未能检测”信息，由判定层输出 WARN。
- 首次安装的预检发生在安装 Xray 前，因此“未安装 Xray，跳过后量子检测”是正常兼容分支。不得为了这一项下载核心、移动安装阶段或使安装失败。
- `tls ping` 先输出无 SNI 探测，再输出有 SNI 探测。**只解析 `Pinging with SNI` 段**，要求该段握手成功；不能把无 SNI 的好结果用于实际 SNI。
- 官方命令即使某次握手失败也可能返回 0，因此不能只凭进程退出码判定成功；非零退出或不完整结果也不得给 PASS。
- 探测函数将输出归一化为内部文本记录：`STATUS=ok|unavailable`、`PQ=true|false`、`CHAIN_BYTES=<非负整数>`、`REASON=<单行原因>`。只有完整成功结果带 PQ/CHAIN_BYTES，失败时只带状态与原因。判定层不运行外部探测；容忍上游 tab/空格及 CRLF 差异，缺字段和非数字长度一律 WARN，不伪称目标不支持。

**判定：** 有 SNI 握手成功、协商到 `X25519MLKEM768`，且证书链总长度 **严格大于 3500 字节**时输出 PASS；其它已测得的情况输出 WARN，并分别说明密钥交换能力与长度。3500 本身不通过。这个阈值用于将来的签名配置准备度，不是现有 Reality 节点可用性的硬门槛，也不代表已启用后量子签名。

所有 WARN 只增加告警计数：原先没有 FAIL 的结果仍退出 `0`；原先有 FAIL 仍退出 `2`。保留原来的 X25519/TLS 探测，不用 PQ 探测替换前 12 项。`--skip-sni-check` 仍跳过整组预检。

**版本和证据：** CI 本轮使用 `v26.9.9` 基线，另设 latest 跟踪任务并包含预发布。2026-09-12 官方最新发布为 [v26.9.9](https://github.com/XTLS/Xray-core/releases/tag/v26.9.9)；GitHub `/releases/latest` 的正式版选择语义不符合本项目要求，不用于发现最新核心。

- 配置含义以本地官方快照 [reality.md](../.claude/skills/xray-core-official-knowledge/docs/stable/config/transports/reality.md) 为依据；其中 `mldsa65Seed` 段给出长度与密钥交换要求。
- 实际解析字段来自 v26.9.9 固定提交的 [tls/ping.go](https://github.com/XTLS/Xray-core/blob/52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120/main/commands/all/tls/ping.go)：`TLS Post-Quantum key exchange` 和 `Certificate chain's total length`。长度是各证书 DER 字节数之和，不是叶证书长度或 PEM 文本长度。该文件与此前核对的旧版本文件相同；本轮仍未执行新二进制探测。
- `sources.yaml` 的源码提交与 v26.9.9 tag 一致，本轮比对的关键文件也一致；配置以官方 docs/source 和准确目标版本为准。后续新版继续检查字段、默认值和命令格式，不按目录名或人工摘要推断。

### 3.3 测试与验收

测试放在现有 SNI 用例文件并登记到 smoke；入口/目标用例随 T03 交付，PQ 用例随 T12 交付。所有网络探测使用桩，正常测试不得向真实 SNI 站点发请求。

| 场景 | 必须验证的结果 |
| --- | --- |
| 无参数 + 已安装状态；只有 config 可回读；无状态 | 前两者探测当前节点，最后一种清晰报错 |
| 显式域名/target/server-ip 与已有状态冲突 | CLI 优先，传给各探测函数的目标一致 |
| `--target other.example:8443` | HTTP 与 PQ 均连目标 8443，同时保留指定 SNI |
| timeout 为 0、全零、负数、文字、正整数、带前导零正整数 | 无效值在探测前退出 1；合法值传递为正数秒 |
| PQ true + 长度 3501；true + 3500/3499；false + 4000 | 第一种 PASS，其余 WARN，展示两个维度 |
| 无 SNI 段 PASS、有 SNI 段失败或不同结果 | 只采用有 SNI 段；不能误判 PASS |
| Xray 缺失、旧版命令、超时、非零退出、退出 0 但握手失败、乱码/缺字段 | WARN，不中断安装，不伪称已检测成功 |
| 原 12 项全通过 + 新项 WARN；原检查含 FAIL | 退出码分别仍为 0、2，计数准确 |
| `--skip-sni-check`；新装时没有 Xray | 前者不调用任何探测；后者只产生 PQ 告警 |

验收还包括：ShellCheck 全绿、全量 smoke 全绿、两个 CI job 全绿。真实目标 TLS 探测只作为隔离环境中的补充记录，不作为依赖外网稳定性的 CI 门槛。

T03 完成后同步无参数行为与超时帮助；T12 的 PQ 观察实现后，再将 README 命令表和架构文档改为 13 项。PQ 观察本身不新增状态键，版本号按最终交付范围确定，不占用生产就绪版本的验收门槛。

## 4. 后续能力：后量子签名与客户端兼容性

普通五类节点的客户端兼容性是详细计划 C/E 的必做项，应提前交付应用版本、内核版本、链接/PNG 导入、实际路径和验证日期。下述额外签名属于 G 阶段调查，不能因为核心已升级就直接开启。

1. **客户端集合已确定。** Android v2rayNG、Windows v2rayN、Debian NAS 的 Xray-core Docker。实施时读取实际应用/核心版本与镜像 digest，不再要求用户重选。v26.9.9 锁定的 REALITY 依赖要求初始 ClientHello 携带特定次序的 X25519MLKEM768 key_share，须提前纳入三端验证；目标站 PQ 与签名条件分别判断。
2. **签名能力完整验证。** 服务端 `mldsa65Seed`、客户端 `mldsa65Verify` 必须在所有 Reality 链路一起验证，包括普通直连、XHTTP Reality、split 的内外层与 IPv6 变体；普通 TLS/H3 链路不强塞 Reality 字段。先调查分享链接是否能无损携带验证公钥，并实测 PNG 是否还能编码及被客户端扫码导入。T07 还将补齐 NAS 原生 JSON；有 JSON 不能免除 GUI 链接/二维码的签名兼容门槛。
3. **客户端字段更名单独验证。** v26.9.9 同时解析 `password` 与 `publicKey`，前者有值时优先。原生参照配置采用 password，URI 的 `pbk=` 保留；嵌套 extra 按目标客户端实测决定别名。VLESS users 回读、xmux 默认和无效 ECH 选项的迁移已经进入详细计划 T07，不推迟到签名立项。[源码快照](../.claude/skills/xray-core-official-knowledge/source/config/transport_security.go)
4. **核心追新已确定。** v26.9.9 接入及后续预发布追踪从第一阶段执行，无需再以签名需求论证版本选择。兼容性报告明确列出尚未适配的客户端，服务端继续以最新版为目标；可复现 tag、摘要校验、候选验证和完整回滚共同支持追新。

签名报告若不能证明目标客户端的导入与联通能力，结论就是“暂不启用签名”。确认可用后另写包含状态迁移、密钥生命周期、链接变更和回滚方案的施工图；这不影响已经确定的最新版核心策略。

**ECH 决策已落实到参数与验收文档。** 新装普通 CDN 保留，另提供显式 ECH 变体；先认证节点 3，再认证 split ECH。AliDNS HTTPS 是可替换的首轮候选，真实域名的 HTTPS/ECH 查询优先，共享名 `cloudflare-ech.com` 为显式备选。已配置 ECH 的连接失败不能静默改成普通 TLS。当前环境的 DNS 探测与社区成功案例不足以证明用户节点已可用，也不足以断言 Cloudflare ECH 在大陆被统一屏蔽或攻破；须完成真实三端的正负用例、缓存/轮换、切网和人工操作验收。

## 5. 执行清单与完成定义

- [x] 核对 pi 最新会话、当前代码、远端版本和 CI 状态。
- [x] 归档已完成的 1.1.0 计划，保留生产节点暂缓约束。
- [x] 将当前核心目标改为 v26.9.9，核对官方 tag/源码/资产元数据，更新追新与实施计划；尚未实施代码和新核心验收。
- [x] 补查官方仓库讨论与客户端源码，完成 REALITY/XHTTP/ECH 参数契约、AliDNS 决策与测试 VPS/三端交互步骤；实测通过项仍待实施。
- [ ] **下一项 T01：v26.9.9 接入、包含预发布的版本解析/下载、ShellCheck 与 CI 安装脚本修复。**
- [ ] T02/T03：默认安装与 SNI P0 修复，最终 SHA 重跑 CI，完成 1.1.1 修复版收口。
- [ ] T04–T07：H3/IPv6 导出、证书能力、分发身份、users/xmux 迁移、REALITY 新兼容要求、ECH 变体与 NAS JSON。
- [ ] T08–T10：核心/资源/配置/state 恢复、自动续证、baseline/latest/migration CI 与五类节点传输。
- [ ] T11：独立新 VPS、v2rayNG/v2rayN/NAS Docker、真实 Cloudflare/ECH、人工交互与首次持续运行，完成正式验收。
- [ ] T12：WARN 级 PQ 观察及签名兼容性调查，按证据决定额外能力。
- [ ] 生产升级：等待用户另行确定时机，届时按真实已安装版本重新规划；不得照抄旧附录 F。

每阶段结束时记录提交 SHA、准确 Xray tag/摘要、参数修订、测试结果与 CI 链接，再勾选完成；代码已提交、远端已发布、本机已升级分别记录。下一位实施者从详细计划 T01 开始，不重做已完成的订阅删除或二维码功能。
