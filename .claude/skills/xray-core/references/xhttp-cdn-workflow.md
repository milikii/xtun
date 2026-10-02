# XHTTP 经 CDN 的 TLS 场景

本流程是拓扑与参数决策指导，不是固定 CDN 模板。先读 [sources.yaml](../sources.yaml)，
核对用户实际 CDN、套餐、客户端内核和目标 Xray tag；不同 CDN 的功能不能相互套用。

## 证据入口

- [官网 XHTTP](../docs/stable/config/transports/xhttp.md) 指向官方
  [discussion #4113](https://github.com/XTLS/Xray-core/discussions/4113)；本地
  [原文快照](../citations/raw/xhttp-4113.txt) 供回查，旧文章的默认值需用源码复核。
- v26.9.30：[SplitHTTPConfig.Build 所在文件](../source/versions/v26.9.30/infra/conf/transport_method.go)、
  [客户端 dialer](../source/versions/v26.9.30/transport/internet/splithttp/dialer.go)、
  [服务端](../source/versions/v26.9.30/transport/internet/splithttp/hub.go)、
  [规范化配置](../source/versions/v26.9.30/transport/internet/splithttp/config.go)。
- [TLS 文档](../docs/stable/config/transports/tls.md) 与 [TLS 运行实现](../source/versions/v26.9.30/transport/internet/tls/config.go)。
- CDN/ACME 官方入口与核查范围见 [运维来源](operations-sources.yaml)。它们不是 Xray 配置语义的权威替代。

## 1. 先画清数据经过的每一跳

常见方案之一：

```text
客户端 ─ TLS ─ CDN 边缘 ─ TLS ─ 源站反代 ─ 受控本机连接 ─ Xray XHTTP
```

另一种是 CDN 直接通过 TLS 回源到 Xray。两者都需要明确证书在哪里加载、哪个进程负责端口，
不要给不终止 TLS 的 Xray 入站机械添加证书，也不要把跨公网无保护的连接称为安全“回源”。

填写非秘密的场景表：

| 项目 | 要确定的事实 |
|---|---|
| 客户端目的地址 | CDN 域名或明确选择的边缘地址，不应误指向未计划暴露的源站 |
| 客户端 TLS 名称 | CDN 边缘证书覆盖的名称，不能因为改连接 IP 就丢掉名称验证 |
| HTTP Host / path | CDN 路由、反代和 XHTTP 服务端接受的值及转发后是否保持 |
| CDN 源站设置 | 源站地址、端口、回源 Host/SNI、TLS 校验策略 |
| 源站证书 | 哪个名称、哪种信任链、哪个进程持有、谁负责续期 |
| 本机上游 | 监听范围、端口、HTTP 版本/转发方式；不无意开放公网明文入站 |
| 多节点共存 | REALITY 与源站 HTTPS 是否争用同一地址端口，已有服务是否需要保留 |

边缘证书由 CDN 管理不代表源站证书也由 CDN 自动维护。部分源站专用 CA 仅被该 CDN 信任，
不能直接当作普通客户端的公网可信证书。

## 2. 根据中间层能力选择 XHTTP 参数

- `mode` 不是装饰。v26.9.30 的客户端 `auto` 会根据 TLS/REALITY、协商路径等选模式，
  因此“省略 mode”不等于固定走某一种。阅读 `dialer.go` 与实际服务端接收路径。
- 若中间层不支持流式上行，按官方讨论评估 `packet-up`；它仍要满足请求体、超时等约束，
  不能保证所有 CDN 都兼容。支持流式上行时再核对 `stream-up` 与相关 HTTP/gRPC 条件。
- H2/H3 是逐跳协商。客户端到 CDN 使用 H3，不等于 CDN 到源站也是 H3，
  也不要求为此给源站强制只开 H3。不要把 HTTP3 承载与已移除的独立 QUIC transport 混为一谈。
- Host、SNI、连接地址有不同职责；不要用关闭证书校验掩盖不匹配。
- 路径重写、响应缓冲、压缩/内容改写、缓存、重定向和认证挑战都可能改变流量行为。
  按供应商规则为受控节点路径配置必要例外，不笼统关闭整个站点的安全功能。
- 请求大小、XMUX、padding、超时等从当前内核默认值及 CDN 限额出发，只修改有证据支持的项目。
  `extra` 与外层字段的覆盖语义也需要版本复核。
- 上下行分离必须最终到达同一会话接收端；负载均衡、多个源站或不一致路径可能使会话分离。
  不因为两个域名都能打开就认定配对正确。

Cloudflare 只是可选供应商例子：Full (strict) 文档要求验证源站证书有效期、受认可签发者和名称。
实际端口、gRPC、HTTP3、回源配置与规则能力仍需查其相应文档及账户条件。
**本流程不预置“某套餐永远支持某个 XHTTP 模式”的承诺。**

## 3. 证书与配置实施顺序

1. 检查域名控制权、DNS、现有端口/反代和实际变更授权，先保存可恢复的非公开备份。
2. 按 [证书生命周期](certificate-lifecycle.md) 决定签发方式和加载进程，建立续期责任。
3. 先完成源站证书及 TLS 校验，再设置 CDN 的严格回源；不要以永久关闭验证作为排错结果。
4. harness 按官方证据编写源站反代/Xray 与客户端结构，在本地程序中注入凭据。
5. 做配置检查后按授权生效；每一步保留明确回退点，不覆盖外来服务或不可读的已有配置。

内置生成器可用于覆盖的简单配置，但不能表达完整 CDN/反代拓扑时，不应强行把所有跳压成
客户端/服务端相同设置。直接依据证据设计原生配置并另行审查，工具限制不是技能限制。

## 4. 由内到外验收

| 层次 | 要验证的内容 |
|---|---|
| 配置 | 所用字段在目标版本生效，身份/路径/协议职责一致，未知字段未被默默忽略 |
| 本机 | XHTTP 本机端点/反代连接符合设计，无不必要公网暴露 |
| 源站 TLS | 正确 SNI 下的证书链、有效期、名称、实际监听进程 |
| CDN | 边缘证书、真实回源、Host/path、缓存/缓冲/超时及选用的 HTTP 行为 |
| 代理链路 | 真实客户端上传下载、错误凭据拒绝、持续/重连等本场景必要测试 |
| 后续维护 | 续期后源站实际呈现新证书，CDN 回源和代理链路仍成功 |

源站测试绕开 CDN 只能说明源站；首页 200、TLS 成功、`run -test` 均不能证明 XHTTP 节点可用。
验证输出只交付脱敏状态，节点 JSON/分享链接直接落盘，见 [私密产物](private-artifacts.md)。
