---
name: xray-core-official-knowledge
description: >-
  Ground Xray-core configuration, defaults, compatibility, migrations and
  troubleshooting in versioned official source, documentation, release history
  and maintainer statements. Use for Xray protocols, transports, routing and DNS,
  or when generating server/client configurations.
license: MIT
metadata:
  snapshot_policy: versioned
  current_stable: v26.3.27
  current_beta: v26.9.9
  last_sync: "2026-09-14"
  revision: "2026-09-14.1"
  repository: https://github.com/XTLS/Xray-core
---

# Xray Core Official Knowledge

先确认目标版本，再解释配置。读取 [sources.yaml](sources.yaml) 获取覆盖范围与固定提交；
快照不是实时查询。“最新稳定版”“最新预发布”和 main 必须分开。

## 版本与证据

- `source/stable/v26.3.27/`：稳定版的配置、传输与关键运行实现，保持上游路径。
- `source/config/`、`source/transport/`、`source/runtime/`：`v26.9.9` 预发布源码。
- `source/dependencies/reality/<version>/`：该版本 go.mod 锁定的官方 REALITY 依赖。
- `source/dev/`：发布之后的少量 main 修复，不能当成已发布功能。
- `docs/stable/`：为兼容已有引用保留的目录名，内容实际是**滚动官网文档**，
  并不保证与稳定版一致。

详细边界见 [版本指南](references/version-guide.md)。默认值、配置接受/拒绝、
握手与运行行为以**对应版本的构建和运行源码**为准；官网用于解释概念与配置意图。
仅看到 Go struct 中存在字段不能证明功能仍可用，也不能从 protobuf 零值推断最终默认值。

`extracted/`、`changelog/`、`references/`、`citations/` 中的解读都是摘要；
使用前核对相应原文/源码。[已知冲突](references/source-conflicts.md) 记录官网、旧文章
与实现不一致的地方。不要修改官方快照正文来掩盖冲突。

## 按问题查阅

| 问题 | 入口 | 继续核对 |
|---|---|---|
| 当前字段、默认值、客户端/服务端职责 | [参数索引](references/parameter-index.md) | 目标版本的 config、runtime、transport |
| 稳定版与预发布的区别 | [版本指南](references/version-guide.md) | [逐版索引](changelog/index.md)、`source/commits/` |
| 弃用、移除、别名与迁移 | [迁移时间线](extracted/deprecations/timeline.md) | 构建函数、对应 tag 的提交差异 |
| XHTTP 默认值与组合限制 | [默认值](extracted/defaults/versioned.md)、[兼容关系](extracted/compatibility/core.md) | `SplitHTTPConfig.Build` 与 `GetNormalized*` |
| 协议/传输选择 | [协议索引](references/protocol-quick-reference.md)、[传输表](references/transport-comparison.md) | 指定版本的支持和校验逻辑 |
| 为什么这样设计 | [维护者说明](citations/maintainer-intent.md) | `citations/raw/` 原文及后续实现 |
| 生成 XHTTP + REALITY 配置 | [示例说明](references/examples.md) | 对应版本示例与源码；按实际网络选择 target |
| 检查/维护技能 | [维护流程](references/maintenance.md) | `scripts/snapshot.py`、来源清单 |

## 容易误用的边界

- TLS `allowInsecure=true` 在覆盖的两个版本均被拒绝；`false` 仍能解析。
  `fingerprint: "unsafe"` 是原生 Go TLS 的选择，但不能用于 REALITY。
- REALITY 当前名称为 `target`、`password`；`dest`、`publicKey` 是兼容旧名。
  `password` 虽由服务端私钥导出，仍属于 REALITY 客户端凭据，不因旧名含 public 而应公开。
- 旧独立 HTTP/H2、QUIC transport 已移除；XHTTP 的 H2/H3 仍受支持。
  gRPC + REALITY 可被接受，gRPC 的弃用警告与“不兼容”是两回事。
- 空 XMUX 的连接控制：稳定版是 `maxConcurrency: 1`，当前预发布版是
  `maxConnections: 3`。整组默认值只在 XMUX 全零/未填写时注入。
- REALITY 在 `v26.7.11` 加过默认最低客户端版本，`v26.9.8` 又取消该默认值并
  引入依赖库的 ClientHello 检查；取消版本号限制不代表所有旧客户端均可连接。

## 回答与配置

按用户问题给出必要的含义、适用版本、实际默认值、作用端、兼容条件及出处，
无需每次输出固定模板。对尚未收录的实现明确说明缺口，必要时查对应官方 tag/commit。

生成配置时说明目标版本、客户端/服务端需要匹配的内容和非默认选择的原因。
保留用户指定的协议与部署约束；参数越多不意味着越合适。示例是有占位符的配置对，
不是经过真实链路验证的部署方案。`xray run -test` 只证明配置可接受，不证明握手、
吞吐量或某地区的可用性。

维护者公开发言需要附日期、来源与适用背景，区分本人判断、转引测试、建议、提案和
已合入行为。用对应版本源码复核发言中的默认值；不把地区性观察概括成普遍保证。
