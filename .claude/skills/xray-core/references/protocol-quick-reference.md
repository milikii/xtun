# 协议索引

按用户现有协议和部署需求定位；本表只用于查阅，不代替配置构建和实际运行逻辑。
核查版本为 v26.9.9，稳定版差异见 [版本指南](version-guide.md)。

| 协议/功能 | 官方配置入口 | 要点 |
|---|---|---|
| VLESS | [入站](../docs/stable/config/inbounds/vless.md)、[出站](../docs/stable/config/outbounds/vless.md) | decryption/encryption 可选 none 或有效 VLESS Encryption 格式，必须显式填写 |
| VMess | [入站](../docs/stable/config/inbounds/vmess.md)、[出站](../docs/stable/config/outbounds/vmess.md) | 当前无加密选项的移除与协议整体支持是不同问题 |
| Trojan | [入站](../docs/stable/config/inbounds/trojan.md)、[出站](../docs/stable/config/outbounds/trojan.md) | 当前公网出站安全要求见 config/xray.go |
| Shadowsocks | [出站](../docs/stable/config/outbounds/shadowsocks.md) | 不再把 none/zero/plain 列为当前可用算法；具体 AEAD/2022 能力按配置核对 |
| Socks / HTTP | [Socks](../docs/stable/config/inbounds/socks.md)、[HTTP](../docs/stable/config/inbounds/http.md) | 代理入口，勿与 HTTP transport 混淆 |
| Tunnel / Dokodemo | [Tunnel](../docs/stable/config/inbounds/tunnel.md) | 透明代理入口及旧名兼容需按版本 |
| Freedom / Direct | [Freedom](../docs/stable/config/outbounds/freedom.md) | 解析策略和 finalRules 有重要版本差异 |
| DNS / Loopback / Blackhole | [DNS](../docs/stable/config/outbounds/dns.md)、[Loopback](../docs/stable/config/outbounds/loopback.md)、[Blackhole](../docs/stable/config/outbounds/blackhole.md) | DNS 规则、环路与响应行为查运行层 |
| Hysteria / WireGuard / TUN | [配置总览](../docs/stable/config/index.md) | 已收录官方配置与部分实现，尚无完整参数摘要 |

VLESS Encryption、TLS、REALITY、XTLS Vision 处于不同配置层次；不要简单归并为一个 security 选项。
需要加密格式和约束时阅读 [VLESS 参数](../extracted/parameters/vless-outbound.yaml) 及其源码链接。
