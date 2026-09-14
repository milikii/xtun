# 版本变化索引

核查日期：2026-09-14。以下各版摘要来自官方发布正文与 Git 提交；不是自动推断出的参数说明。
稳定版 v26.3.27 至最新预发布 v26.9.9 共 241 个提交。原始发布 API 记录保存了最近 30 个版本，
较早字段改名和移除另见 [迁移时间线](../extracted/deprecations/timeline.md)。

| 版本 | 状态 | 主要主题 |
|---|---|---|
| [v26.3.27](v26.3.27.md) | 稳定 | 稳定基线：完整发布说明包含 Finalmask、mKCP、Hysteria、XHTTP、REALITY、TLS ECH、WireGuard 和 VLESS Reverse 的更新。 |
| [v26.4.13](v26.4.13.md) | 预发布 | Geodata 重构、sniffing 域名/IP 排除扩展及 TUN 的系统路由/接口支持改进。 |
| [v26.4.15](v26.4.15.md) | 预发布 | Freedom 增加 ipsBlocked 与默认策略；后续版本还会演进成 finalRules，不能直接把旧入口写入新版示例。 |
| [v26.4.17](v26.4.17.md) | 预发布 | Freedom 对来自 ipsBlocked 的 UDP 响应也进行过滤。 |
| [v26.4.25](v26.4.25.md) | 预发布 | Geodata 支持自动更新和热重载；DNS 出站增加按 qtype/domain 匹配的规则。 |
| [v26.5.3](v26.5.3.md) | 预发布 | Freedom 增加 finalRules 与 blockDelay，包含默认策略；具体触发条件应查运行实现。 |
| [v26.5.9](v26.5.9.md) | 预发布 | 入站 users 兼容旧 clients/accounts；Tunnel 入站和 DNS 出站的字段也有兼容改名。 |
| [v26.6.1](v26.6.1.md) | 预发布 | DNS 出站以 return 取代 reject；Finalmask 增加 Realm、mkcp-legacy 等变化。 |
| [v26.6.22](v26.6.22.md) | 预发布 | XHTTP 增加 sessionIDTable、sessionIDLength，并将 session* 命名调整为 sessionID*。 |
| [v26.6.27](v26.6.27.md) | 预发布 | 空 XMUX 的默认连接控制由 maxConcurrency=1 改为 maxConnections=6；其它整组默认值的触发条件仍是 XMUX 全零。 |
| [v26.7.11](v26.7.11.md) | 预发布 | 传输 method 兼容旧 network；root 增加 env；Finalmask 增加 XMC。 |
| [v26.7.28](v26.7.28.md) | 预发布 | 空 XMUX 的 maxConnections 从 6 改为 3；这不是 v26.9.9 首次加入的默认值。 |
| [v26.9.8](v26.9.8.md) | 预发布 | Freedom 将旧域名解析策略兼容迁移到 sockopt.domainStrategy，并拒绝旧 outbound.proxySettings。 |
| [v26.9.9](v26.9.9.md) | 预发布 | Finalmask 将 udpHop 提取为独立 UDP mask；旧 quicParams 字段的兼容逻辑需按此版构建代码核对。 |

发布之后的两项 main 修复单列在 [dev 提交索引](../source/commits/dev-after-v26.9.9.md)，不能作为已发布修复使用。
