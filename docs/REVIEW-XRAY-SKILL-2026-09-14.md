# Xray 官方知识技能审计（2026-09-14）

更新验收状态（2026-09-14）：本次审计对应的更新已完成。稳定版与预发布版各 17 项配置检查重新通过，
验证报告已绑定当前示例哈希；快照完整性、维护链接与 skill 结构检查均通过。
详见 [更新验证记录](../.claude/skills/xray-core-official-knowledge/references/validation.md)。
下文保留更新前的审计发现与当时的验证范围。

结论：需要更新。优先修正会误导配置生成的事实错误、明确版本边界，再补齐官网修订、逐版变更和维护者说明。当前技能记录的最新发布版本号正确，已收录的配置与传输源码也没有落后；问题主要在知识提取、证据覆盖与版本组织。

审计对象：`.claude/skills/xray-core-official-knowledge/`。`/root/.agents/skills/xray-core-official-knowledge` 是指向该目录的符号链接。

## 核对范围与上游状态

读取 GitHub 最新 30 条发布记录、`releases/latest`、官方源码完整 Git 历史、官网文档仓库及部署页面，并查阅维护者的公开讨论。逐 tag 核对 `v26.3.27` 至 `v26.9.9` 的 241 个提交，针对字段改名与传输移除追溯较早版本。此范围不等于已经完成所有历史版本、所有配置字段的逐项审计。

| 对象 | 本次核实结果 | 对技能的影响 |
|---|---|---|
| 最新稳定发布 | `v26.3.27`，`d2758a023cd7f4174a5a5fa4ff66e487d4342ba0` | 现有版本号正确 |
| 最新预发布 | `v26.9.9`，`52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120` | 现有版本号正确 |
| Core main | `c412e77a9b712082ac9ebf27fa793951cb5a7d85` | 发布后多两个修复，尚未进入新发布 |
| 官网文档 main | `46c680b71b18b48b9cc6e55e596405bd0442ab8a` | 本地已收录文件中有 12 个发生变化 |
| 技能最后同步 | `2026-09-09T14:40:00Z` | 需要另记本次核查时间，不能冒充已同步 |
| 本机 Xray | `26.3.27`，`d2758a0` | 回答本机配置问题时尤其需要稳定版依据 |

本地 `source/config/` 的 38 个文件、`source/transport/internet/` 的 206 个文件与上游当前对应文件逐字节一致。这只证明已收录文件的正确性，不代表源码覆盖完整。

main 上新增的两项修复为 Windows `WSARecv` 阻塞/关闭问题（[#6743](https://github.com/XTLS/Xray-core/pull/6743)）和 TUN 开启流量统计时保留 UDP 目标地址（[#6747](https://github.com/XTLS/Xray-core/pull/6747)）。文件分别位于 `common/buf/`、`proxy/tun/`，均不在技能现有源码提取范围内，应记录到 dev 轨道。

发布依据：[稳定版](https://github.com/XTLS/Xray-core/releases/tag/v26.3.27)、[最新预发布](https://github.com/XTLS/Xray-core/releases/tag/v26.9.9)、[稳定版至最新预发布的差异](https://github.com/XTLS/Xray-core/compare/v26.3.27...v26.9.9)。

## 必须优先修正的事实错误

| 位置 | 现有问题 | 核实结果 |
|---|---|---|
| `SKILL.md:59`、`changelog/v26.9.9.md` | 指示将 TLS `allowInsecure` 视为“仅弃用，仍可解析” | 当前配置构建在 `allowInsecure=true` 时返回移除错误；仅保留字段以识别旧配置不能证明功能仍可用。`tls-settings.yaml` 对这一点反而是正确的 |
| `extracted/parameters/reality-settings.yaml:107` | 将改名方向写成 `password` → `publicKey` | 当前推荐名称为 `password`，旧名称为 `publicKey`；两者均可识别，同时填写时 `password` 覆盖 `publicKey` |
| `extracted/parameters/splithttp-xhttp.yaml:50` | 将 `xPaddingBytes` 默认值写为 `1–1` | 运行层归一化默认范围为 `100–1000`，见 `source/transport/internet/splithttp/xpadding.go:179` |
| 同一 XHTTP YAML 的 `scMaxEachPostBytes`、`scMinPostsIntervalMs` | 误归为 stream-up 参数 | 用于 packet-up 分包上行；前者默认 `1000000`，后者仅客户端、默认 `30 ms`，不能泛写为双方均生效 |
| `references/transport-comparison.md:11` | 将旧独立 HTTP/H2、QUIC transport 列为 Stable | 两者均已移除；XHTTP 使用 H2/H3 是另一回事 |
| `references/transport-comparison.md:24` | 将 gRPC 与 REALITY 列为不兼容 | 当前源码允许 REALITY 与 RAW、XHTTP、gRPC 组合；gRPC 另有弃用警告，不等于不能搭配 REALITY |
| `extracted/parameters/tls-settings.yaml:67` | 声称 TLS 指纹不能使用 `unsafe` | TLS 接受 `unsafe`，用于原生 Go TLS；REALITY 的限制需要单独说明 |

关键源码依据：

- [`transport_security.go`，v26.9.9](https://github.com/XTLS/Xray-core/blob/v26.9.9/infra/conf/transport_security.go)：`AllowInsecure` 的构建错误、TLS 指纹校验、REALITY 字段兼容。
- [`transport_internet.go`，v26.9.9](https://github.com/XTLS/Xray-core/blob/v26.9.9/infra/conf/transport_internet.go)：旧 HTTP/QUIC 的移除、REALITY 可用传输。
- [`xpadding.go`，v26.9.9](https://github.com/XTLS/Xray-core/blob/v26.9.9/transport/internet/splithttp/xpadding.go)：padding 的实际默认值。
- [`config.go`，v26.9.9](https://github.com/XTLS/Xray-core/blob/v26.9.9/transport/internet/splithttp/config.go) 与 [XHTTP 原始说明](https://github.com/XTLS/Xray-core/discussions/4113)：分包参数默认值、用途与客户端/服务端职责。

历史边界已由提交与 tag 包含关系核实：`allowInsecure=true` 的拒绝逻辑首先进入 `v26.1.31` 预发布，并在 `v26.2.6` 稳定发布说明中明确宣布；旧 QUIC transport 的移除进入 `v24.9.7`，旧 HTTP transport 的移除进入 `v24.12.15`。`target` 别名进入 `v24.10.16`，`password` 别名进入 `v25.3.6`。

官网 TLS 页面目前仍将 `allowInsecure` 描述为弃用，并保留旧行为介绍。这是需要显式记录的文档与实现冲突。应保留原始文档快照，在单独的冲突记录中写明目标版本、源码行为与验证结果，不能仅凭“官网这样写”覆盖指定版本的实际行为。

## 版本记录缺口

现有 `source/releases/` 只有 10 个发布文件：9 个正文主要是跳转到下一版本，`v26.9.9` 的发布正文主要为赞助、捐赠和相关链接。它们不是完整的逐版技术更新日志。`changelog/` 只有一个实际版本摘要；`source/commits/` 没有实际记录。连作为稳定基线的 `v26.3.27` 发布说明也未收录。

以下为本次核对中应该补入技能的主要版本变化，表格为审计索引，不替代逐项源码验证。

| 版本 | 应补充的重点 |
|---|---|
| `v26.3.27` 稳定版 | 收录完整发布说明；Finalmask 扩展、完整 Hysteria 2 入站与传输、XHTTP/3 默认 BBR、REALITY target 警告、TLS ECH、WireGuard、VLESS reverse 等 |
| `v26.4.13` | Geodata 重构、sniffing 扩展、mKCP 参数、TUN Windows/FreeBSD、Finalmask `bbrProfile` |
| `v26.4.15` | Freedom `ipsBlocked` 与默认策略、header-custom 扩展 |
| `v26.4.17` | Freedom UDP 响应过滤、Geodata 反向 CIDR |
| `v26.4.25` | Geodata 自动更新与热重载、DNS 出站规则 |
| `v26.5.3` | Freedom `finalRules`、`blockDelay`；移除 `echForceQuery`，配置 ECH 后强制使用 |
| `v26.5.9` | 入站 `clients/accounts` → `users` 的兼容改名、Tunnel/DNS 字段改名、XHTTP stream-up/one 内存修复 |
| `v26.6.1` | DNS 出站 `reject` → `return`、Finalmask Realm/mKCP 改动、XHTTP 计数与保活修复 |
| `v26.6.22` | XHTTP `sessionID*` 参数、`trustedXForwardedFor` 要求、TLS 旧字段清理、XHTTP/3 关闭逻辑 |
| `v26.6.27` | 空 XMUX 的连接控制改为 `maxConnections: 6` |
| `v26.7.11` | `network` → `method`、限制公网无加密出站、REALITY 默认 `minClientVer: 26.3.27`、root `env`、Finalmask XMC |
| `v26.7.28` | 空 XMUX 的 `maxConnections` 从 6 改为 3，REALITY 警告调整 |
| `v26.9.8` | Freedom 兼容迁移、移除 `proxySettings`、REALITY 依赖与握手检查更新、XHTTP 并发修复 |
| `v26.9.9` | `udpHop` 成为独立 UDP mask、Freedom 使用 `dialerProxy` 时跳过解析及 `finalRules`、VLESS 安全校验修复 |

`v26.4.13` 至 `v26.9.9` 在本次查询中均标记为 prerelease。新增/别名兼容/弃用警告/构建拒绝应分别记录，不应都写成“改名”或“移除”。

两个特别容易误用的版本变化：

1. **XHTTP XMUX 默认值随版本改变。** 早期作者文章中的 `maxConcurrency: 16–32`、后来的 `maxConcurrency: 1`、`v26.6.27` 的 `maxConnections: 6`、`v26.7.28` 起的 `maxConnections: 3`，属于不同版本。空 XMUX 才触发整组默认值，不应把这些值直接混为通用建议。当前摘要中的 3 本身正确，但不能当成 `v26.9.9` 首次引入。依据：[6 的提交](https://github.com/XTLS/Xray-core/commit/18b85adb)、[3 的提交](https://github.com/XTLS/Xray-core/commit/18e28390)。
2. **REALITY 的版本号限制与握手检查需要区分。** `v26.7.11` 加入默认最低客户端版本；`v26.9.8` 注释掉默认版本限制，同时升级 REALITY 库，要求 ClientHello 中存在符合长度和顺序要求的 `X25519MLKEM768` key share。因此，不能从“默认版本限制取消”推导为“任意旧客户端恢复兼容”。依据：[Core 依赖与配置调整](https://github.com/XTLS/Xray-core/commit/47cfe9994a6b39b1f673ba35e62b091bcce15a71)、[REALITY 握手源码](https://github.com/XTLS/REALITY/commit/8cdf7bf9c7f09cb9814bf08c3eb877f68b85fba8)。

## 官网增量与源码覆盖

相对于本地快照，上游 12 个已收录文件发生变化，其中 8 个属于配置参考，4 个属于教程：

```text
config/outbound.md
config/dns.md
config/routing.md
config/outbounds/freedom.md
config/outbounds/wireguard.md
config/outbounds/loopback.md
config/transports/grpc.md
config/transports/sockopt.md
document/level-1/routing-with-dns.md
document/level-2/tproxy.md
document/level-2/redirect.md
document/level-2/tproxy_ipv4_and_ipv6.md
```

主要涉及 Freedom 解析策略迁移到 `sockopt.domainStrategy`、`proxySettings` 移除、路由 DNS 触发时机与目标地址的区别，以及 gRPC 反代传递客户端地址的头从错误的 `X-Real-IP` 修正为 `X-Forwarded-For`。相关实现已经在技能源码中，但旧文档尚未同步。

依据：[官网文档增量](https://github.com/XTLS/Xray-docs-next/compare/9125d3237c2f1717425dc94f1b54d2743ec1797a...46c680b71b18b48b9cc6e55e596405bd0442ab8a)、[当前 Freedom 官网页面](https://xtls.github.io/config/outbounds/freedom.html)。

`source/` 还应按需求补充 `proxy/`、`app/dns/`、`app/router/`、`app/policy/` 等实际执行逻辑，以及 `go.mod` 锁定的官方 REALITY 依赖。仅保留 `infra/conf` 和传输文件，不能完整回答默认值、DNS/路由行为或握手兼容性。无需因此复制所有源码和生成文件，可按主题保存关键实现及准确来源。

## 维护者公开思路的收录方式

当前 `citations/` 只有模板。XHTTP 两个官方文档入口各只有标题和指向 Discussion #4113 的链接，本地没有保存讨论正文；离线使用时缺少主要设计说明。

| 原始来源 | 可收录的内容 | 必须保留的边界 |
|---|---|---|
| RPRX：[XHTTP: Beyond REALITY](https://github.com/XTLS/Xray-core/discussions/4113) | 穿透 HTTP 中间盒、上下行分离、packet-up/stream-up/stream-one、XMUX 与 header padding 的设计原因 | 文章中的旧默认值必须与目标 tag 的源码核对；文章不能直接充当最新参数表 |
| RPRX：[PR #5414 的兼容性说明](https://github.com/XTLS/Xray-core/pull/5414#issuecomment-3649096826) | 修改默认头名称会破坏新旧兼容，应该通过配置选项开放变体 | 不应推导为“换头名称就能稳定避免检测” |
| RPRX：[上下行分离说明](https://github.com/XTLS/Xray-core/pull/5414#issuecomment-3823861456) | 上下行配置相互独立，可以经过不同 CDN、采用不同变体 | 不能在生成配置时擅自要求上下行使用同一套变体参数 |
| RPRX：[BBS #19](https://github.com/XTLS/BBS/issues/19) | 区分宏观原理、认证与加解密、反识别；按问题性质与场景安排优先级，权衡实现和维护成本 | 属于维护者公开观点；地区性观察及尚在开发的方向不能写成普遍保证或已发布功能 |
| RPRX：[Chrome 指纹与连接数讨论](https://github.com/XTLS/Xray-core/pull/6181#issuecomment-4567373533) | 2026 年 5 月针对特定网络环境提出 XHTTP 连接数 6 的建议，反对随意剥除新版指纹中的后量子特征 | 包含维护者转引的外部测试反馈；后续默认值已改为 3，应记录日期、发言者、引用层次与后续提交 |

每条引用应保存永久链接、作者、发表/更新/抓取时间、适用版本，以及 `official-statement`、`maintainer-suggestion`、`source-confirmed` 等性质。公开讨论中的引用和其他参与者反馈不能全部归为作者本人的实验结论。

## 建议的更新顺序与验收条件

1. **先修正事实与检索指引。** 修复上表错误，同时修订 `SKILL.md` 中错误的 `allowInsecure` 指令。查默认值与弃用状态时优先检查指定版本的构建与运行实现；将 `references/` 一并标记为需要核对的摘要，建立文档与实现冲突记录。
2. **明确快照版本。** `docs/stable/` 实际来自滚动更新的官网 main，不能声称与稳定版一一对应。现有唯一源码快照对应预发布版；`docs/beta/`、`docs/archived/` 没有内容。可保留现有目录避免破坏引用，但必须如实标注，并添加稳定版关键行为索引或对应源码。`sources.yaml` 应记录文档完整 SHA、源码完整 SHA、依赖版本与文件映射。
3. **同步官网并补充版本链。** 导入上述 12 个文件，补入稳定基线及缺少的发布记录；对只有跳转链接的 release 使用相邻 tag 的提交差异生成可追溯摘要，把 main 尚未发布的两项修复单独记录。
4. **补齐设计依据与运行逻辑。** 收录上述维护者说明及关键依赖源码，优先覆盖 xtun 使用的 VLESS、XHTTP、REALITY、TLS、Freedom、DNS、routing，再扩展 Hysteria、TUN、WireGuard、Finalmask。
5. **实现可复查的同步与校验。** 现有 `scripts/extract-config.example.sh` 只是示例，实际提取命令全部被注释。应提供真正的版本检查、差异提取、来源校验与失效链接检查；只更新日期不算同步完成。高风险配置结论使用目标版本 `xray run -test` 验证，运行期结论另需对应实现或专项测试。

## 已完成的验证

在本机稳定版 `v26.3.27` 上，以 `/tmp` 中的最小配置运行 `xray run -test`，未启动监听或修改服务。结果与源码结论一致：

| 配置检查 | 结果 |
|---|---|
| TLS `allowInsecure: false` | 通过 |
| TLS `allowInsecure: true` | 退出码 23，明确报告已移除 |
| TLS `fingerprint: unsafe` | 通过 |
| 旧独立 `network: http` | 退出码 23，明确报告已移除 |
| 旧独立 `network: quic` | 退出码 23，明确报告已移除 |
| `network: grpc` + REALITY | 通过 |

这些检查仅证明配置接受/拒绝行为；不代表进行了真实 TLS/REALITY 握手、吞吐量或特定网络环境的连接测试。预发布版行为依据对应 tag 源码与官方依赖，未运行预发布二进制。
