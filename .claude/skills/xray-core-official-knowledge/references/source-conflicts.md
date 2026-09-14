# 已知文档与实现冲突

核查版本：v26.3.27、v26.9.9；官网快照见 [来源索引](../sources.yaml)。
官方正文保持原样，下面的判定属于已核查的人工说明。

| 项目 | 文档/旧摘要问题 | 应采用的行为与证据 |
|---|---|---|
| TLS allowInsecure | 官网仍描述 true 跳过验证并称其弃用；旧 SKILL.md 据此说“未移除” | 两个版本均在 true 时返回移除错误；false 仍能解析。[预发布源码](../source/config/transport_security.go)、[稳定版源码](../source/stable/v26.3.27/infra/conf/transport_internet.go)、[移除提交](../source/commits/patches/2c92339f.patch) |
| XHTTP XMUX | 作者早期文章写 maxConcurrency = 16–32；后续有 maxConcurrency = 1、maxConnections = 6/3 | 指定目标版本并检查全零条件；见 [默认值表](../extracted/defaults/versioned.md) |
| REALITY fingerprint | 官网要求显式填写；旧 YAML 据此标为解析必填 | GetFingerprint 空字符串默认 Chrome；建议显式填写与构建必填不同。[函数](../source/transport/internet/tls/tls.go) |
| REALITY password | 旧 YAML 和示例将改名方向写反 | 当前名称 password，旧名 publicKey；非空 password 优先。[源码](../source/config/transport_security.go) |
| TLS unsafe | 旧 YAML 混淆 TLS 与 REALITY 限制 | TLS 可选原生 Go TLS；REALITY 拒绝 unsafe/hellogolang。[源码](../source/config/transport_security.go) |
| 独立 HTTP/QUIC | 旧传输表把已移除 transport 写成 Stable | 构建明确拒绝；不影响 XHTTP 的 H2/H3。[源码](../source/config/transport_internet.go) |
| gRPC + REALITY | 旧传输表写不兼容 | 构建允许 RAW、XHTTP、gRPC；gRPC 本身仍有弃用警告。[源码](../source/config/transport_internet.go) |

后续出现冲突时保留：具体版本、原文链接/快照、对应实现、结论及验证范围。
证据没有覆盖时写明未知，不能把某一次文档修正或维护者发言扩展为所有版本的结论。
配置回归记录见 [验证说明](validation.md)。
