---
name: xray-core
description: >-
  Official-source knowledge and operational guidance for Xray-core: current
  releases, design direction, version-correct parameters, VLESS/REALITY/XHTTP
  decisions, CDN TLS and certificate lifecycle. Helps coding harnesses reason,
  implement and verify; bundled generators are optional helpers, not capability limits.
license: MIT
metadata:
  snapshot_policy: versioned
  current_stable: v26.3.27
  current_beta: v26.9.30
  last_sync: "2026-10-01"
  revision: "2026-10-02.1"
  repository: https://github.com/XTLS/Xray-core
---

# Xray-core：官方知识与实践指导

本技能给 harness 提供**版本证据、配置原理、前沿方向和可靠工作流程**，帮助它按需求
编写、审查、验证配置及实施方案。不是固定模板库，也不要求所有任务都经过内置生成器。
先读 [sources.yaml](sources.yaml)；只加载当前任务所需资料，不把整个知识库塞入上下文。

## 1. 先查版本，再下结论

- 要求“最新”时用 `python3 scripts/upstream.py check` 查询官方渠道，再锁定完整 tag/commit。
  同时说明最新稳定、预发布、最新发布和 main。用户追求前沿时评估最新发布（可能是预发布），
  不静默改成旧稳定版；main 不是正式发布，实验使用需明确选择。
- 现有来源观察为 **2026-10-01**，不是实时保证。离线保留时间并说明新鲜度未知。
  文档更新日期不能替代源码同步/运行验证日期。
- 本地缺少新版本、字段或拓扑：进入 [知识查证流程](references/knowledge-workflow.md)，
  查询官方 tag 的构建、运行代码及实际锁定依赖。**辅助脚本不支持，不等于技能无法指导。**
  证据不足时给出待核实项；不能仅改版本标签沿用旧结论。
- 默认值必须追踪构建、规范化及运行路径；Go 字段存在、protobuf 零值、旧文章都不足以证明行为。
  参数不是越新越多越好：说明为何启用、在哪端生效、要求怎样的对端/中间层，以及验证方法。

### 本地证据地图

- 稳定基线：`source/stable/v26.3.27/`。
- 收录的预发布基线：`source/versions/v26.9.30/`。
- 历史 v26.9.9：`source/config/`、`source/transport/`、`source/runtime/`。
- 依赖：`source/dependencies/reality/<version>/`，以对应 Core 的 go.mod 为准。
- `source/dev/` 只是历史 main 片段；这些快照都不是完整可构建仓库。
- `docs/stable/` 是 **2026-09-14 滚动官网快照**，不是稳定版专属文档。

`references/`、`extracted/`、`changelog/`、`citations/` 的解读是索引/摘要，回查原文后才能引用。
维护者观点需保留日期、上下文及后续实现状态，区分提案、合入、发布与建议。
冲突写入 [冲突记录](references/source-conflicts.md)，不改官方正文。

## 2. 按任务进入工作流程

| 任务 | 入口 |
|---|---|
| 查参数、组合、默认值或本地尚未覆盖的能力 | [知识查证](references/knowledge-workflow.md)、[参数索引](references/parameter-index.md) |
| 跟进发布、设计思路和新特性 | [持续更新](references/update-workflow.md)、[版本指南](references/version-guide.md)、[v26.9.30 差异](references/v26.9.30-delta.md) |
| REALITY 配置决策及目标域名检测 | [REALITY 场景](references/reality-workflow.md) |
| XHTTP 经 CDN，客户端到源站 TLS 拓扑 | [XHTTP CDN TLS 场景](references/xhttp-cdn-workflow.md) |
| 证书签发、部署、自动续期和生效验证 | [证书生命周期](references/certificate-lifecycle.md) |
| 真实节点不进入模型上下文 | [私密产物规范](references/private-artifacts.md) |
| 采用已有生成/链接/验证工具 | [可选工具契约](references/generation.md) |
| 维护快照、引用及测试 | [维护方法](references/maintenance.md) |

## 3. 从需求到正确实现

1. 确定任务是解释、设计、配置审查，还是已授权的实际操作；仅询问会改变方案的条件。
2. 明确客户端能力、两端版本、直连/CDN/反代拓扑、TLS 终止位置及证书责任。需求不同不强套一份模板。
3. 查证相关字段，标注作用端、默认值、配对/互斥条件与来源；已发布能力也可能依赖新客户端。
4. 形成不含真实凭据的结构和实施步骤。多节点可按需求设计多入站，不受单节点辅助脚本限制。
5. 由本地程序生成/注入凭据、写入最终文件并验证。不要让模型生成后又展示真实密钥或节点正文。
6. 分层报告完成、失败、跳过和外部前提；附产物位置和必要维护说明，不回传节点内容。

生成器 `generation.yaml` 的白名单只约束该脚本；不能为通过它而删除正确的新字段、换协议，
也不能直接修改白名单冒充已适配。脚本之外的配置应由 harness 按官方证据编写并独立验证。
`check_configs.py` 仅审查本工具 bundle 子集，不是任意配置的完整 schema 审计器。

## 4. 操作、隐私与验证边界

- 可以指导安装、域名检测、CDN 配置、ACME 及续期，但加载技能不授予执行权限。
  安装、DNS/CDN 修改、签发、服务变更与定时任务都需具体授权；不自动改全局 harness 设置。
- 私钥/decryption 只留服务端；UUID、REALITY password、客户端配置、分享链接、DNS API 凭据
  同样不进入模型上下文、工具输出、公开报告或 Git。仅文件落盘；同 UID/root 下不能承诺硬隔离。
- 不以关闭 TLS 验证解决证书问题。不能无损表达的链接退回原生 JSON，不静默丢字段。
- 参数/结构与配对审查、对应二进制 `run -test`、真实隔离握手、外部链路分别记录。
  TLS 探测不是 REALITY 认证握手；源站通过不是 CDN 通过；续期成功不是进程已加载新证书。
- 内置新生成器真实内核矩阵与握手仍未完成，见 [验证记录](references/validation.md)。
  既有源码审阅、单元测试和历史报告不能当作新部署或第三方客户端兼容保证。
