# 批次 C/D/E 实现与验证报告

> 实施与测试日期：2026-09-14 至 2026-09-15；接手核验：2026-09-17。
> 本报告在接手时补齐，依据实际文件、原始测试日志和归档，不能把补写日期当成重新执行测试的日期。

## 1. 接手结论与候选身份

`any.config.toml` 对应 `anyrouter`。有实际项目进度的最近会话为 `01a09e41-c538-7e61-bc60-264008bc8895`，创建于 9 月 14 日；最后工具执行在北京时间 9 月 15 日 09:33。之后的“继续”和 9 月 16 日新会话没有产生后续实现。旧会话摘要中的“最终测试仍在运行”“README/参数/手册尚未更新”已经过时：这些工作和私有 VPS 证据归档实际已完成。本报告、提交、push 和新 CI 是接手时真正缺失的交付。

| 对象 | 核验结果 |
| --- | --- |
| 接手 HEAD / 远端 main | `ae8c3b3ccd7870ecd6826e862cea2e79662f1dbd`；9 月 17 日通过 `git ls-remote` 核对远端 |
| 工作区 | C/D/E 与 W13 改动尚未提交；保留已有实现，没有从 main 覆盖 |
| 声明版本 | 脚本 `1.1.0`，state schema `2`，参数修订 `2`；未创建新 tag/release |
| 核心依据 | `v26.9.9 / 52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120` |
| 运行清单 | `xtun.sh`、`lib/`、`static/` 共 37 个文件 |
| 运行清单 SHA256 | `72fb6447ff42433222997b67db1c5898cd5221f1b7028de00612f965ab14b306` |
| 清单算法 | 相对路径排序，逐文件 `sha256sum`，再对完整清单（保留末尾换行）计算 SHA256 |

9 月 17 日重新计算的清单逐字等于 9 月 15 日保存的 `runtime-manifest.txt`。这证明运行文件与当时最终记录一致，不把旧日志解释成新提交的 CI。

## 2. 实现及用户行为

### C：W08.2/8.3 安装身份与同版本操作

- 引导入口解析固定提交，检查归档根目录、成员类型、完整运行清单，并与同提交的独立入口下载核对。自定义远端归档要求显式摘要。
- 核心回执绑定核心、geo 文件、官方归档、tag/commit、架构及二进制权限/能力；bundle 回执绑定完整文件清单和来源。这是本机校验记录，不是上游数字签名。
- 可信相同产物返回无变更；相同版本缺少有效回执或发生漂移时，要求 `upgrade --reinstall` / `update-script --reinstall`。
- 核心升级、脚本更新和 `apply-config` 参数迁移保持独立；候选获取失败不会静默使用旧 bundle 执行写操作。

### D：W09/W10/W11 参数、节点与导出

- 节点 1–9 共用规范对象生成 URI、PNG 和原生 JSON。节点 7 保留 CDN 上行、IPv6 REALITY 下行；节点 9 的 H3 ALPN 位于下行 TLS。
- 新核心输出 `users`，读取旧 `clients` 并保留身份、flow、Encryption 和可识别的旧客户端调优。旧配置丢失配对 Encryption 时明确失败，避免无意轮换。
- 新安装省略核心默认 xmux 块；旧自定义或来源不明的值保留。参数修订升为 2，state schema 保持 2。
- `export-client --node N --variant current|plain|ech --format uri|json|png --output PATH` 实际执行持锁、当前代检查、目标保护和原子发布。文件为 0600，新建父目录为 0700；默认拒绝覆盖。
- `rebuild-qr` 只重建二维码，并逐字比较规范 URI 与已提交节点文档。旧定义不一致时要求显式迁移，不能生成与文档不同的二维码。
- ECH 只作用于 CDN TLS 层；新启用默认使用 AliDNS DoH 和实际 serverName，旧显式来源保持。原生 JSON 默认 SOCKS 监听 `127.0.0.1:10808`，不包含服务端私钥。

字段依据已回到固定版本官方源码复核：[VLESS 构建](../.claude/skills/xray-core-official-knowledge/source/config/vless.go)中非 nil `clients` 优先于 `users`；[XHTTP 构建](../.claude/skills/xray-core-official-knowledge/source/config/transport_method.go)定义整组 xmux 默认；[XHTTP 拨号](../.claude/skills/xray-core-official-knowledge/source/transport/internet/splithttp/dialer.go)从 TLS ALPN 选择 H3；[ECH 实现](../.claude/skills/xray-core-official-knowledge/source/transport/internet/tls/ech.go)定义配置来源与失败处理。更多适用范围见[参数契约](PARAMETERS.md)。

### E：W12 证书生命周期

- 人工操作与自动回调共锁。候选证书/密钥成对验证，持久 staging 后在 generation 中提升；局部替换、元数据或服务验证失败时恢复。
- 通过真实链验证 Cloudflare Origin CA，检查自签签名、密钥、SAN、有效期和用途。ACME 模式要求公共信任。
- 上游 acme.sh 3.1.1 `_installcert` 会记录 reload 命令失败，但不能只依赖其最终退出码。人工调用用操作 nonce、继承锁与候选摘要确认回调完成；自动回调独立取锁并核对域名/模式。
- 同域名续证/切换证书来源只更新证书相关内容并 reload nginx，验证实际供出的叶证书指纹，保持 Xray 配置与 URI/PNG。独立证书进程补齐 Xray UID/GID 查询。
- `.xtun-certificate.json` 与证书事件记录保存结果；恢复后实际供证不匹配时保留 pending。

Cloudflare 根证书来自官方 `https://developers.cloudflare.com/ssl/static/origin_ca_rsa_root.pem` 与 `https://developers.cloudflare.com/ssl/static/origin_ca_ecc_root.pem`。证书 SHA256 指纹分别为：

```text
RSA D3:C7:E8:5C:91:70:7F:C0:A1:2A:BC:5D:88:26:67:47:AA:4F:A8:E7:B1:62:F6:33:FF:B3:C9:D9:89:94:76:20
ECC AA:63:69:7A:22:76:4B:67:B2:13:4C:E1:4C:B5:69:0E:A3:36:94:0B:93:98:61:13:F4:95:45:91:78:32:D8:0D
```

## 3. 已执行验证与证明范围

私有原始证据在 `/root/xtun-evidence/20260914-remaining/`；VPS 下载归档为 `vps-evidence-final.tar.gz`，展开目录为 `xtun-cde-evidence/`。公开仓库只记录去秘密的结果。

| 验证 | 实际结果 | 原始证据及边界 |
| --- | --- | --- |
| 本机 arm64 canonical smoke | 252 组，末尾 `smoke ok` | `smoke-final.log`，包括最终证书 UID/GID 修复 |
| VPS amd64 canonical smoke | 252 组，退出 0 | `xtun-cde-evidence/smoke-verified.log` 与 `.status` |
| 安装 / 任务菜单 PTY | 两端各 68 / 9 个 PASS | 两端 `pty-install.log` / `pty-menu.log`；不代替真人任务 |
| 原生传输 | 两端各 17 场景 | 本机 `native-64m/summary.json`、VPS `native-final/summary.json` 与状态 0 |
| 历史迁移 | 两端各 3 组通过 | `migration-second.log`、VPS `migration-final.log` 与状态 0 |
| latest 发现及验证 | 当时解析至 v26.9.9，252 smoke 与 17 原生场景通过 | `latest-final.log`；在最后 UID/GID 修复前运行，修复后 canonical smoke 已通过；不代表 9 月 17 日重新发现 latest |
| 已安装 VPS 实际维护 | 26 项全部 `passed: true` | `acceptance-results.json`；故障注入项目预期退出非零，不能只数退出 0 |
| ShellCheck / 语法 | 9 月 17 日重新执行全部通过，ShellCheck 退出 0 | 62 个 Shell 文件通过 ShellCheck 与 `bash -n`，3 个 Python 文件通过 AST 解析；不依赖历史空 lint 日志推断退出码 |
| 官方 Docker 客户端 | 脚本已接线，接手时未执行 | 本机无 Docker，必须等待新候选 CI |
| Debian 12/13、Ubuntu 24.04 安装矩阵 | workflow 已接线，接手时未执行新矩阵 | 旧批次 B CI 不证明 C/D/E 通过 |

原生正向覆盖节点 1–5 和节点 3 ECH，各自上下行 64 MiB 内容校验；负向覆盖错误 UUID、REALITY key/shortId、path、无效/不可达 ECH 及分别阻断 split 两条路径。测试运行在独立网络 namespace，使用私有 CA 和 TLS/H2 适配器，保留生产模板 private 路由防护。它不经过真实 Cloudflare，不证明 GUI、NAS、公网 ECH 或 H3 可用。

迁移组合是准确旧 bundle `b6eb98b49d01c9b524aa0a679cc951d5b72c9db7` 的 `0.11.14 / state 1 / core 26.3.27`、同 bundle/core 配合合成 state 2，以及 `434075910feb1ce6c93873be7a550a5a7591230e` 的 `1.1.0 / state 2 / core 26.9.9`。state 2 合成用例对应生产版本组合，不复制生产凭据，也不解释生产 state 2 的历史来源。用例验证凭据/调优保持、QR 失败后文件及模式恢复，再验证成功迁移。

VPS 26 项覆盖真实 bundle 更新与可信 noop、未知核心身份拒绝、显式重装、核心/bundle 写回执失败恢复、参数迁移、三变体三格式导出、二维码重建、续证、nginx reload 后失败恢复、证书来源切换与 noop、自动回调锁排斥和最终诊断。仅换证时 Xray/HAProxy PID 及 URI/PNG 保持。

调试阶段的失败日志一并保留。原生 VPS nginx 夹具修正私有实例运行用户，迁移夹具修正 `SCRIPT_ROOT` 及旧订阅路径隔离；最终对应重测通过。产品修复包括独立证书进程 UID/GID 查询及重建 QR 的文档一致性检查，没有用夹具绕过产品失败。

## 4. 现场状态与接手限制

- **本机生产：** 9 月 17 日只读快照与 9 月 15 日最终快照的文件摘要、权限、归属、链接及服务 PID/状态完全一致；无 pending。生产保持 bundle `0.11.14`、实际 state `2`、核心 `26.3.27`，本轮没有迁移。
- **VPS 历史状态：** 9 月 15 日验收后服务 active、无 pending，证书模式恢复 self-signed，安装来源为诚实的 local archive。SSH 文件及 root 密码指纹比较均一致；只公布比较结果，不公布正文或指纹值。
- **VPS 当前状态：** 9 月 17 日旧 ControlMaster 已失效，批处理 SSH 返回认证失败；因此尚未重新读取服务、pending 或安装摘要。历史“无 pending”不能表述为当前现场已核实。
- **既有 nginx 差异：** VPS 实际二进制 `1.30.1`，dpkg `1.22.1-9+deb12u9`；保留该差异，不据此宣称系统包一致。

## 5. 交付与下一步

接手时尚无 C/D/E 提交或 CI run。本地运行内容与历史最终证据一致；新候选提交与 CI 的真实结果另行补充，不虚构 SHA 或 run。

先完成报告、静态/链接检查、提交和 push，再核对该候选 CI，重点是首次执行的官方 Docker 客户端及三系统安装矩阵。测试 VPS 恢复连接后先读取 pending 与服务状态，再安排后续验收。

仍待完成：公共 ACME 实际签发与自动续期、强制断电后重入、W14 两轮真人交互、W15 三端和真实 Cloudflare/ECH/IPv6/H3/NAS 路径，以及固定组合的 72 小时/7 天观察。G1/G2/G3/G4/G5 不提前关闭；不创建或移动 tag，不发布 release，生产迁移另排。详见[当前计划](PLAN.md)与[验收手册](TEST-VPS-RUNBOOK.md)。
