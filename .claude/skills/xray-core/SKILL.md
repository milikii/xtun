---
name: xray-core
description: >-
  Generate and validate version-pinned Xray-core VLESS server/client configurations,
  explain parameters and compatibility, and follow upstream releases and design
  direction using official source, documentation and maintainer evidence.
license: MIT
metadata:
  snapshot_policy: versioned
  current_stable: v26.3.27
  current_beta: v26.9.30
  last_sync: "2026-10-01"
  revision: "2026-10-01.1"
  repository: https://github.com/XTLS/Xray-core
---

# Xray-core：取证、生成与验证

本技能只生成和验证配置，不安装服务、不修改目标机器、不设置全局技能。
先读 [sources.yaml](sources.yaml)，锁定目标 tag/commit，再回答参数或生成配置。
“最新稳定版”“最新预发布”“最新发布”和 main 是四个不同概念，不能混用。

## 1. 锁定版本与证据

- 用户要求“最新”时，运行 `python3 scripts/upstream.py check` 联网观察渠道，再选择明确 tag。
  通常优先已核验稳定版；使用预发布必须明确标注。命令路径相对技能根目录。
- 离线只能使用已有固定资料；保留观测时间并声明新鲜度未知。当前来源观测为
  **2026-10-01**，不是实时保证。发现新发布不意味着该版本可直接沿用旧规则。
- `source/stable/v26.3.27/` 保存稳定基线；`source/versions/v26.9.30/` 保存当前收录的
  预发布基线。`source/config/`、`source/transport/`、`source/runtime/` 是历史 `v26.9.9`。
- `source/dev/` 是历史 main 片段，不是当前 main；main 只用于有明确提交的开发研究。
- `source/dependencies/reality/<version>/` 对应目标 Core 的 go.mod 锁定依赖。
- `docs/stable/` 实为 **2026-09-14 的滚动官网快照**，不保证与稳定版或后续发布一致。
  观测到新 docs SHA 不等于已更新正文。源码快照不是完整可构建 checkout。

字段接受、默认值和运行条件以**同一目标版本的构建与运行源码**为准；官网解释概念。
仅有 Go 字段或 protobuf 零值不证明功能和最终默认值。`references/`、`extracted/`、
`changelog/`、`citations/` 的解读都不是独立权威来源，引用前回查原文。
不要修改官方快照正文掩盖冲突，见 [冲突记录](references/source-conflicts.md)。

## 2. 按任务加载资料

| 任务 | 入口 | 必须进一步核对 |
|---|---|---|
| 查字段、默认值、两端职责 | [参数索引](references/parameter-index.md)、[版本默认值](extracted/defaults/versioned.md) | 目标版本配置 builder 与运行代码 |
| 版本/趋势/迁移 | [版本指南](references/version-guide.md)、[v26.9.30 差异](references/v26.9.30-delta.md)、[逐版索引](changelog/index.md) | 对应官方 release、提交及固定 SHA |
| 传输与安全组合 | [生成规则](extracted/compatibility/generation.yaml)、[兼容说明](extracted/compatibility/core.md) | 两端实现、依赖版本及运行前提 |
| 创建配置/分享链接 | [生成契约](references/generation.md) | 输入角色、有效组合、各验证层结果 |
| 审查现有配置 | [冲突记录](references/source-conflicts.md)、[迁移时间线](extracted/deprecations/timeline.md) | 旧版与目标版官方源码；通用 JSON 不能冒充生成 bundle |
| 维护者意图 | [维护者说明](citations/maintainer-intent.md) | 原文日期、背景和后续实现 |
| 更新/完整性检查 | [维护流程](references/maintenance.md)、`scripts/snapshot.py`、`scripts/upstream.py` | 来源清单、哈希和渠道观察 |

旧摘要中的“当前”必须按其记录日期解释，不能自动转移到 `v26.9.30`。MASQUE、XDRIVE、
Finalmask 等新变化先看版本差异和官方实现，不能只根据名称拼接旧模板。

## 3. 生成流程

1. 明确两端版本、地址端口、客户端能力、传输/安全要求，以及证书、CDN/反代等外部条件。
   只询问影响输出的必要信息，不偷偷改变用户指定协议或部署约束。
2. 使用 `generation.yaml` 已审阅的生成子集；未知字段明确拒绝，不静默丢弃。
   未覆盖的 reverse/fallback、XDRIVE 存储、多前置、Finalmask/sockopt 拓扑回到源码分析，
   不宣称内核不支持，也不伪装成已完整生成。
3. 按 [请求契约](references/generation.md) 创建私有请求文件，调用
   `scripts/generate.py --request REQUEST.json --output NEW_DIR`。
   `version` 必须明确，生成器不自动解析 `latest`。
4. REALITY 密钥与 VLESS Encryption 优先使用目标官方内核命令生成；
   `--binary` 会执行程序，必须已获授权且核验来源。不要编造密钥或复用公开示例凭据。
5. 输出服务端、每位用户客户端、可无损表达的 URI、清单和前提说明。
   ECH、复杂 XHTTP、downloadSettings 等无法无损表示时保留原生 JSON，明确说明链接遗漏原因。

TLS 证书和 ECH 材料由用户提供，不申请证书、不修改系统信任。裸 VLESS 必须符合工具的
显式可信私网条件；不要为测试通过关闭 TLS 验证。私钥/decryption 只留服务端；
UUID、REALITY password、Encryption 客户端材料及分享链接也都是凭据，不能写入日志、
公开报告或版本控制。输出默认目录 `0700`、文件 `0600`，不覆盖已有目录或报告。

## 4. 分层验证与诚实交付

- **结构/约束/配对**：`scripts/check_configs.py --bundle DIR` 检查生成器子集、来源与配置哈希、
  两端角色和配对条件。不是完整 Xray schema 审计，也不能证明 Encryption 密钥实际握手成立。
- **对应二进制构建**：显式提供 `--server-binary`、`--client-binary`，需要时加
  `--require-build`。先核对版本/提交，再执行 `xray run -test`；未提供二进制应记录 skipped。
- **隔离链路**：显式调用 `scripts/check_handshake.py`，在私有临时环境中测试回环传输、
  上传/下载哈希与错误身份拒绝；记录适配过的地址、端口、证书等范围。未覆盖组合必须 skipped。
- **外部条件**：公共 REALITY target、CDN、第三方 GUI、地区连通性和性能另行验证，默认未验证。

新生成器真实内核矩阵及真实 Xray 握手尚未完成，不把离线测试、源码审阅或历史示例报告
写成新组合已可用。只对实际执行过的版本、配置哈希和层次报告通过。

回答按问题提供含义、适用版本、作用端、实际默认值、配对要求和出处，无需机械重复全表。
解释趋势时区分“已发布”“已合入未发布”“提案”“维护者建议”，注明日期与上下文；
地区性观察不能推广成通用保证。最终明确哪些已经生成、哪些测试通过/失败/跳过、哪些仍依赖外部条件。
