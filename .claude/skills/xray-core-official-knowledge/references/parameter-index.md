# 参数索引

下列 YAML 为 **v26.9.9 已核查字段摘要**，不是完整 JSON Schema，也不代表每项都在稳定版可用。
每个记录给出固定 SHA 与本地源码路径；稳定版请切换到 [对应源码](../source/stable/v26.3.27/)。

| 内容 | 摘要 | 关键运行实现 |
|---|---|---|
| VLESS 入站 | [vless-inbound.yaml](../extracted/parameters/vless-inbound.yaml) | [inbound.go](../source/runtime/proxy/vless/inbound/inbound.go) |
| VLESS 出站 | [vless-outbound.yaml](../extracted/parameters/vless-outbound.yaml) | [outbound.go](../source/runtime/proxy/vless/outbound/outbound.go) |
| TLS | [tls-settings.yaml](../extracted/parameters/tls-settings.yaml) | [TLS](../source/transport/internet/tls/) |
| REALITY | [reality-settings.yaml](../extracted/parameters/reality-settings.yaml) | [集成](../source/transport/internet/reality/)、[锁定依赖](../source/dependencies/reality/v26.9.9/) |
| XHTTP | [splithttp-xhttp.yaml](../extracted/parameters/splithttp-xhttp.yaml) | [SplitHTTP](../source/transport/internet/splithttp/) |
| Freedom、DNS、路由、policy | [官方配置参考](../docs/stable/config/) | [运行逻辑](../source/runtime/)、[配置构建](../source/config/) |
| Hysteria、WireGuard、TUN、Finalmask | [官方文档](../docs/stable/config/) | config/transport 已收录；尚无完整逐字段摘要 |

[默认值](../extracted/defaults/versioned.md)、[组合约束](../extracted/compatibility/core.md)、
[迁移状态](../extracted/deprecations/timeline.md) 均需与目标版本源码一起使用。
