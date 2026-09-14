# 已核查默认值

| 参数 | v26.3.27 | v26.9.9 | 适用条件 |
|---|---|---|---|
| XHTTP mode | auto | auto | 配置为空时；运行层再决定模式 |
| xPaddingBytes | 100–1000 | 100–1000 | 运行归一化；不是 protobuf 零值 |
| scMaxEachPostBytes | 1000000 | 1000000 | packet-up；客户端取值、服务端上限 |
| scMinPostsIntervalMs | 30 | 30 | packet-up 客户端 |
| scMaxBufferedPosts | 30 | 30 | 服务端会话上传队列 |
| scStreamUpServerSecs | 20–80 | 20–80 | stream-up 服务端 |
| serverMaxHeaderBytes | 8192 | 8192 | 服务端，未填或 0 时归一化 |
| XMUX 连接控制 | maxConcurrency = 1 | maxConnections = 3 | 整个 XMUX 为零/未填时 |
| hMaxRequestTimes | 600–900 | 600–900 | 同上 |
| hMaxReusableSecs | 1800–3000 | 1800–3000 | 同上 |
| TLS / REALITY fingerprint | Chrome | Chrome | 空值由 GetFingerprint 处理；显式指纹另校验 |
| REALITY minClientVer | 未指定 | 未指定 | 中间版本曾有默认值，见版本指南 |

任一 XMUX 项非零会使整组全零注入条件不成立，不能把表中的各项默认值分别假设为总会补齐。
`maxConnections` 和 `maxConcurrency` 不能同时为正。范围在 JSON 中使用数字或字符串
（例如 `"100-1000"`），不是 `{ "from": 100, "to": 1000 }`。

源码入口：

- 稳定版：[配置构建](../../source/stable/v26.3.27/infra/conf/transport_internet.go)、
  [运行归一化](../../source/stable/v26.3.27/transport/internet/splithttp/config.go)、
  [padding](../../source/stable/v26.3.27/transport/internet/splithttp/xpadding.go)。
- 预发布：[配置构建](../../source/config/transport_method.go)、
  [运行归一化](../../source/transport/internet/splithttp/config.go)、
  [padding](../../source/transport/internet/splithttp/xpadding.go)。

历史变化：`v25.10.15` 将空 XMUX 的 maxConcurrency 改为 1；
[v26.6.27](../../source/commits/patches/18b85adb.patch) 改为 maxConnections = 6；
[v26.7.28](../../source/commits/patches/18e28390.patch) 改为 3。
作者早期文章是理解设计的依据，当前默认值仍需用源码定位。
