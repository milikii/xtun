# 关键组合约束

以下摘要以 v26.9.9 为准；跨版本先查 [版本指南](../../references/version-guide.md)。

| 组合 | 实际约束 | 源码 |
|---|---|---|
| REALITY + 传输 | 允许 RAW/TCP、XHTTP、gRPC；不允许直接搭配 WS/HTTPUpgrade | [StreamConfig.Build](../../source/config/transport_internet.go) |
| REALITY 指纹 | 拒绝 unsafe、hellogolang；可解析的指纹还需满足服务端握手条件 | [配置](../../source/config/transport_security.go)、[依赖](../../source/dependencies/reality/v26.9.9/tls.go) |
| VLESS decryption + fallbacks | 非 none 的有效加密格式不能与 fallbacks 一起配置 | [VLESS](../../source/config/vless.go) |
| VLESS encryption = none | 面向公网的出站还需通过传输安全检查，不等于可以任意明文直连 | [出站校验](../../source/config/xray.go) |
| XMUX | maxConcurrency 与 maxConnections 不能同时为正 | [构建](../../source/config/transport_method.go) |
| XHTTP headers | 不允许 host，大小写不敏感；使用独立 host 字段 | [构建](../../source/config/transport_method.go) |
| XHTTP extra | 重新解析一份配置，只保留外层 host/path/mode；不是与外层所有字段逐项合并 | [构建](../../source/config/transport_method.go) |
| XHTTP GET / header、cookie 上行数据 | 要求显式 packet-up | [构建](../../source/config/transport_method.go) |
| XHTTP 分包大小 | 服务端允许的 scMaxEachPostBytes 上限至少覆盖客户端上传大小 | [服务端检查](../../source/transport/internet/splithttp/hub.go) |
| Freedom + dialerProxy | v26.9.9 跳过自身域名解析与 finalRules，将连接交给链式出站 | [Freedom](../../source/runtime/proxy/freedom/freedom.go) |
| gRPC/HTTP 类真实源地址 | 使用受信任的 X-Forwarded-For，按 trustedXForwardedFor 配置校验 | [Sockopt](../../docs/stable/config/transports/sockopt.md)、[gRPC](../../docs/stable/config/transports/grpc.md) |

“允许配置”不等于该组合更适合用户网络；也不能用构建通过代替真实握手验证。
