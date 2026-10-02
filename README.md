# Xray-core 官方知识与实践技能

为 Codex、Claude、pi 等 coding harness 提供 **Xray-core 的官方文档、版本变化、设计思路、前沿方向、正确参数与场景工作流程**，帮助它们根据真实需求高效、正确地创建和维护节点。

**这不是节点生成器，也不是一键安装器。** 核心产品是知识与指导；仓库内脚本是可选的查询、生成和验证辅助，不构成 harness 可以处理的版本、字段或拓扑上限。本项目非 Xray 官方项目。

## 你可以怎样使用

把完整的 [技能目录](.claude/skills/xray-core/) 放到所用 harness 支持的技能位置，或让它从
[SKILL.md](.claude/skills/xray-core/SKILL.md) 开始按链接查阅。不要只复制入口文件。
不同 harness 的技能发现位置和权限机制需按各自版本确认，本项目不自动修改全局设置，也未声称全部宿主均已实测。

示例任务：

> 核验 Xray-core 当前最新发布，说明与已收录版本的差异。我要前沿能力，但请区分稳定、预发布和 main，不凭旧资料猜配置。

> 在我的 VPS 上规划两个节点：REALITY 与 XHTTP CDN TLS。先检查版本和外部条件，说明参数选择及两端配对，再按我授权的范围操作。凭据在本地生成，最终节点只输出成私有文件，不读回对话。

> 按我使用的 CDN 与证书工具给出源站 TLS、证书签发、部署、续期和生效验证流程。不要把边缘证书与源站证书混在一起。

> 这个新字段不在技能的生成脚本里。请查目标 tag 的官方实现，解释其职责、默认值和兼容条件，不要因为脚本不支持就认定内核不支持。

## 知识与场景入口

| 需要解决的问题 | 指南 |
|---|---|
| 如何查证字段、默认值、两端职责和组合 | [知识查证流程](.claude/skills/xray-core/references/knowledge-workflow.md)、[参数索引](.claude/skills/xray-core/references/parameter-index.md) |
| 最新特性、维护者思路、版本迁移与长期更新 | [持续更新](.claude/skills/xray-core/references/update-workflow.md)、[版本指南](.claude/skills/xray-core/references/version-guide.md) |
| REALITY 目标选择、检测及认证验证 | [REALITY 场景](.claude/skills/xray-core/references/reality-workflow.md) |
| XHTTP、CDN、Host/SNI、回源与 TLS 终止 | [XHTTP CDN TLS](.claude/skills/xray-core/references/xhttp-cdn-workflow.md) |
| ACME、证书权限、自动续期与实际生效 | [证书生命周期](.claude/skills/xray-core/references/certificate-lifecycle.md) |
| 不把真实节点、密钥和链接送进模型 | [私密产物规范](.claude/skills/xray-core/references/private-artifacts.md) |
| 自选使用现有脚本及其限制 | [可选工具契约](.claude/skills/xray-core/references/generation.md) |

技能可以指导实施，不代表一经加载就可以改机器。软件安装、域名探测、DNS/CDN 更改、证书签发、
服务变更和续期定时任务，应在明确目标及相应授权后执行。本仓库的维护测试不部署服务、不修改目标 VPS。

## 如何保证知识正确

1. 要求“最新”时实时查询官方发布渠道，锁定 tag/commit；不能把本地快照当作实时上游。
2. 文档解释意图，对应版本的构建、运行代码与锁定依赖确认行为；维护者原文说明背景。
3. 本地资料不够就补查官方版本，不让生成器白名单限制知识查证。
4. 分别报告字段/配对审查、配置构建、真实握手和外部条件，不用一项通过替代另一项。
5. 最新不等于全开：新参数需要有场景理由、对端能力及可验证的效果。

### 已收录资料，不是实时最新保证

[sources.yaml](.claude/skills/xray-core/sources.yaml) 的上游观察时间为 **2026-10-01 12:16:28 UTC**：

| 资料 | 固定身份 |
|---|---|
| 当时最新稳定版 | `v26.3.27` / `d2758a023cd7f4174a5a5fa4ff66e487d4342ba0` |
| 当时最新预发布、最新发布 | `v26.9.30` / `b26a91de4f3294e26a0ad0a970b81a386a41f789` |
| 历史预发布 | `v26.9.9` / `52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120` |
| 滚动官网快照 | 2026-09-14 / `46c680b71b18b48b9cc6e55e596405bd0442ab8a` |

`source/dev/` 是历史 main 片段。源码快照是选取的文件，不是完整可构建 checkout。
本次知识入口更新没有把这些来源时间改写成新的上游核验时间。

## 私密产物

由本地程序生成凭据、注入配置、写入私有目录并验证。harness 只接收脱敏状态和产物位置，
不再读取真实配置、链接、私钥或 API Token。不用真实节点充当对话示例。

**只写文件不等于权限隔离。** 同 UID 或 root harness 通常仍能读文件；若要求其无权读取，
必须建立独立账户/受限执行环境等实际安全边界，不能靠提示词或 `0600` 作保证。

## 可选维护与验证工具

仅阅读知识无需 Python。运行辅助脚本需 Python 3.10+、PyYAML；网络和外部程序执行遵守宿主权限。

```bash
SKILL=.claude/skills/xray-core
python3 -m venv .venv
.venv/bin/python -m pip install -r "$SKILL/scripts/requirements.txt"
.venv/bin/python "$SKILL/scripts/upstream.py" check
.venv/bin/python "$SKILL/scripts/snapshot.py" verify
.venv/bin/python -m unittest discover -s "$SKILL/tests"
.venv/bin/python "$SKILL/tests/check_distribution.py"
```

`upstream.py` 观察变化，不自动发布新结论。`snapshot.py` 校验来源、依赖和引用；不能代替语义复核。
`generate.py`、`check_configs.py`、`check_handshake.py` 仍可用于各自已覆盖的子集，详见工具契约。

[验证记录](.claude/skills/xray-core/references/validation.md) 明确区分离线测试与真实内核验证。
现有新生成器真实内核构建/握手矩阵尚未完成；知识文档检查也不能证明某个 CDN 或新 VPS 已工作。

## 长期维护与许可

[维护方法](.claude/skills/xray-core/references/maintenance.md) 说明固定快照、审查差异、更新知识、验证及分发。
上游工作流只输出元数据观察，不自动改规则、提交、签发证书或发布节点。

技能自有部分的许可声明见 SKILL.md；官方资料保留各自许可，见
[source/licenses/](.claude/skills/xray-core/source/licenses/) 与来源清单。摘要和操作建议不代表上游官方保证。
