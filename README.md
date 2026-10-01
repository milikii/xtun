# Xray-core 专用技能

以**固定版本的官方源码、官网文档与发布证据**为依据，解释 Xray-core 参数、跟踪内核变化，并生成和分层验证 VLESS 服务端/客户端配置。

本项目不是 Xray 官方项目，也不是 VPS 安装器。**不安装服务、不修改目标机器、不管理证书、不接管 Nginx/CDN、不修改全局技能设置。** 原有一键部署产品不再是本仓库的交付物。

## 能做什么

- **查参数与兼容性**：先锁定 tag/commit，再核对该版本构建代码与运行实现，区分作用端、默认值、别名、弃用和移除。
- **跟进上游**：分别观察最新稳定版、最新预发布、最新发布及 main；发现新版本不等于旧生成规则已适用。
- **创建 VLESS 配置**：输出同一节点模型派生的服务端、各用户客户端及可无损表达的分享链接；复杂配置保留原生 JSON。
- **验证与排障**：分别报告结构/配对约束、对应二进制配置构建、隔离链路及外部条件。配置解析成功不代表真实握手成功。

生成器是有明确边界的已审阅子集，不是全部 Xray JSON 的通用编辑器。RAW、XHTTP、WS、gRPC、HTTPUpgrade、mKCP、Hysteria transport 等按版本和组合规则处理；`v26.9.30` 的 MASQUE 有生成规则但真实运行未验证，XDRIVE 存储拓扑尚未覆盖。Reverse、fallback、多前置/CDN 拓扑、Finalmask 与平台 sockopt 不自动生成。**“工具尚未覆盖”不等于“内核不支持”。**

## 版本与证据状态

以下是 **2026-10-01 12:16:28 UTC 的上游观测**，不是阅读本文时的实时最新状态：

| 渠道/资料 | 固定基线 | 范围 |
|---|---|---|
| 当时最新稳定版 | `v26.3.27` / `d2758a023cd7f4174a5a5fa4ff66e487d4342ba0` | 版本化源码与生成规则 |
| 当时最新预发布、最新发布 | `v26.9.30` / `b26a91de4f3294e26a0ad0a970b81a386a41f789` | 官方来源及源码审阅；不等于运行验证 |
| 历史预发布 | `v26.9.9` / `52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120` | 保留原始快照和历史回归证据 |
| 官网文档快照 | `46c680b71b18b48b9cc6e55e596405bd0442ab8a` | 2026-09-14 的滚动文档，不与稳定版自动对应 |

准确身份、观测时间和每份资料范围见 [sources.yaml](.claude/skills/xray-core/sources.yaml)。`source/dev/` 保留的是历史 main 快照，不能称为当前 main。源码快照是选取的文件，**不是可直接编译的完整仓库**。

当前新工具已有离线单元测试通过记录；新生成器的真实内核构建矩阵和真实 Xray 隔离握手仍未执行，不能据此宣称所有生成组合可用。历史示例报告仅适用于其中记录的版本、配置哈希和测试层。

## 使用技能

在本仓库打开支持项目技能的环境，使用 `xray-core` 技能。需要复制到其他项目时，完整复制 `.claude/skills/xray-core/` 到目标项目同名目录；不要只复制 `SKILL.md`，也不要遗漏隐藏目录、规则、测试、证据与许可。无需改仓库名或全局设置。

示例任务：

> 使用 xray-core 技能，核验当前最新稳定版，为我的地址生成 RAW + TLS + Vision 配置；列出证书前提，不部署服务。

> 对照 v26.9.9 与 v26.9.30 的官方实现，解释 XHTTP/Finalmask 的变动，区分已发布行为与维护者建议。

> 审查我的 VLESS 配置是否混用了客户端/服务端字段；对未覆盖字段回到对应源码，不静默删除。

## 命令行快速开始

需要 Python 3.10+；Python 依赖见技能内的 requirements 文件。真实本地 TLS 链路测试还需要 OpenSSL 和两端对应版本的 Xray 二进制。只做结构检查不需要 Xray。

```bash
SKILL=.claude/skills/xray-core
python3 -m venv .venv
.venv/bin/python -m pip install -r "$SKILL/scripts/requirements.txt"

# 官方来源完整性与离线工具测试
.venv/bin/python "$SKILL/scripts/snapshot.py" verify
.venv/bin/python -m unittest discover -s "$SKILL/tests"

# 联网观察版本渠道；不会自动更新生成规则
.venv/bin/python "$SKILL/scripts/upstream.py" check
```

将下列内容保存为 `request.json`。域名与证书文件是**需要替换的示例输入**，工具不会申请或验证实际部署证书：

```json
{
  "version": "v26.3.27",
  "server": {"address": "proxy.example.com", "port": 8443},
  "transport": {"type": "raw"},
  "security": {
    "type": "tls",
    "server_name": "proxy.example.com",
    "certificate_file": "server.pem",
    "key_file": "server.key"
  },
  "flow": "xtls-rprx-vision"
}
```

```bash
# output 必须不存在，父目录必须存在；缺省随机生成用户 UUID
.venv/bin/python "$SKILL/scripts/generate.py" \
  --request request.json --output output

# 仅结构、受支持规则与两端一致性；二进制层明确 skipped
.venv/bin/python "$SKILL/scripts/check_configs.py" \
  --bundle output --report structure-report.json
```

生成 `server.json`、`client.json`、适用时的 `links.txt`，以及 `manifest.json`、`README.md`。目录权限为 `0700`，文件为 `0600`，不覆盖已有输出。**配置和链接包含凭据，不要提交、公开或粘贴到日志。**

得到用户授权并具备可信二进制后，可单独执行配置构建检查：

```bash
.venv/bin/python "$SKILL/scripts/check_configs.py" --bundle output \
  --server-binary /path/to/server-xray --client-binary /path/to/client-xray \
  --require-build --report build-report.json
```

这一步会执行指定程序；不会启动监听。证书路径必须可读，版本及短提交身份必须匹配。用户提供二进制的自报版本检查不等于供应链签名验证。可选 `fetch_core.py` 仅在明确授权后从官方发布获取并校验摘要，且会运行版本命令；它不是系统安装器。

完整请求契约、REALITY/Encryption、多用户、分享链接和隔离握手入口见 [生成与验证](.claude/skills/xray-core/references/generation.md)。

## 验证层次

| 层次 | 能说明什么 | 不能说明什么 |
|---|---|---|
| 结构与配对 | 生成器已实现的版本/字段/角色/配对规则符合 | 全量 Xray schema、密码学握手已成立 |
| 对应二进制构建 | 指定版本接受测试配置，负对照有效 | 监听、实际握手或 CDN 已工作 |
| 显式隔离链路 | 报告中具体组合的回环上传/下载及错误身份拒绝 | 原部署地址、公共 target、外部服务可用 |
| 外部条件 | 仅另外实测后才能报告结果 | GUI 客户端、地区网络、性能或 CDN 的普遍保证 |

任何一层失败、跳过或未运行都必须保留，不把 `xray run -test` 写成“节点已验证可用”。

## 目录与维护

核心产品位于 [`.claude/skills/xray-core/`](.claude/skills/xray-core/)：

- `SKILL.md`：任务入口、取证流程与安全边界。
- `sources.yaml`、`source/`、`docs/`：固定来源、官方快照与清单。
- `references/`、`extracted/`、`changelog/`、`citations/`：索引与解读；引用结论前回查原文/源码。
- `scripts/`、`tests/`、`examples/`：生成、更新、校验与回归用例。

[snapshot.py](.claude/skills/xray-core/scripts/snapshot.py) 负责快照/哈希核验，[upstream.py](.claude/skills/xray-core/scripts/upstream.py) 负责渠道观测。离线缓存保留采集时间并标明新鲜度未知；新版本必须经过源码复核和对应验证，不能自动重贴旧规则。上游工作流只报告变化，不自动提交或发布配置。

## 许可与归属

技能自有部分的许可声明见 [SKILL.md](.claude/skills/xray-core/SKILL.md)。官方资料和源码保留各自许可，见 [source/licenses/](.claude/skills/xray-core/source/licenses/) 及来源清单。Xray-core、官网与 REALITY 归各自上游贡献者所有；本项目的摘要、工具限制与测试结果不代表官方保证。
