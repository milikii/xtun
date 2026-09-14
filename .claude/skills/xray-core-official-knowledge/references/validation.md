# 更新验证（2026-09-14）

| 二进制 | 配置检查 | 原始结果 |
|---|---|---|
| v26.3.27，d2758a0，本机现有稳定版 | 17/17 通过 | [JSON](../source/validation/v26.3.27.json) |
| v26.9.9，52a412d9，官方临时测试二进制 | 17/17 通过 | [JSON](../source/validation/v26.9.9.json) |

收尾复验已重新运行上述两组检查。两份报告均记录 `example_config_sha256`，
将验证结果绑定到当前示例的服务端与客户端配置；`snapshot.py verify` 已确认匹配。

预发布资产为官方 Xray-linux-arm64-v8a.zip，下载后核对 GitHub release API 的 SHA-256：
`3e38d72dfc5eb65c91df0e5583e9b6676c32232041da47de6ae73946b526d66c`。
只在临时目录中运行，未替换系统 Xray。

检查覆盖：TLS allowInsecure true/false、TLS 原生指纹、REALITY 对原生指纹的拒绝与空指纹默认、
旧 HTTP/QUIC 拒绝、gRPC/WS 与 REALITY 的兼容边界、XHTTP 范围格式、XMUX 冲突、host 头限制、
extra 覆盖行为、proxySettings 的稳定/预发布差别，以及两版示例的客户端和服务端。

每个配置均使用 `xray run -test`，临时生成测试密钥并替换占位符，没有启动监听。
这些结果只证明解析与构建，不证明真实 target 适用性、TLS/REALITY 握手、路由效果或性能。
可使用 [check_configs.py](../scripts/check_configs.py) 对相同版本重新检查。

源码/文档来自固定 Git blob，完整性由 [snapshot-manifest.json](../source/snapshot-manifest.json)
记录；发布与历史证据由 [history-manifest.json](../source/history-manifest.json) 记录。
维护者原文另有 [证据清单](../citations/evidence-manifest.json)。

完整性检查通过：739 个官方快照文件、67 份证据文件、6 个 YAML 文件，以及示例和维护的本地链接。
skill 结构检查通过。使用本次审计保存的官方克隆和 API JSON 运行同步预览，
快照新增/变更及过期文件均为 0；版本与提交匹配，历史脚本预览生成 61 份发布/历史文件。
这些核对使用已保存的输入，不代表再次实时查询上游。
