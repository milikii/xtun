# 1.2.0 发布就绪清单（2026-09-19）

> 目的：把"第一版可发布"所需的东西一次说清——已经就绪什么、还缺什么、缺的东西由谁提供。
> 当前入口：[PLAN](PLAN.md)；行为决策：[DECISIONS](DECISIONS-UX-RELIABILITY.md)；变更：[CHANGELOG](../CHANGELOG.md)。
> 按[决策 D18](DECISIONS-UX-RELIABILITY.md#d18)，`main` 上是测试候选，正式发布要等 G1–G5 全部满足；本清单不创建 tag、不发布 release。

## 1. 结论

**代码与自动验证已经就绪，卡点全部在需要外部资源的验收闸门上。**

- 内部工作（W01–W13、批次 A–E）已交付；W17 的后量子观察已实现，其余（ML-DSA 调查、性能、静态站）仍后置。
- 公开入口的全新安装、维护、卸载与宿主还原在本轮测试 VPS 上端到端通过，卸载已能干净退出。
- 三项外部验收各自只缺一类输入：**受控域名 + DNS API 令牌**（G3）、**操作者与三端设备**（G2/G4）、**云控制台/电源控制 + 自然时间**（G1/G5）。

## 2. 候选身份

| 项目 | 值 |
| --- | --- |
| 候选代码提交 | `ad407b2`（`feat: check-sni 增加后量子就绪度观察项`） |
| 入口摘要（`xtun.sh`） | `1d8cf6e25d151892f56ad840d8ab990f93bc6c9ee36c38064ee3339f35de5c14` |
| bundle 内容签名 | `3d15caa585032a19ba3cf2404770aaa2188f894c4ea9988cce3ac4c1133d0727` |
| 声明版本 | `1.1.0`（**未提升**；按 D18 在验收通过后定版并随发布提交提升） |
| state schema / 参数修订 | `2` / `2` |
| 核心基线 | `v26.9.9 / 52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120`；默认策略仍为最新非 draft 发布（含预发布） |

> 本清单及随后的纯文档提交不改变运行代码，bundle 内容签名保持不变。打 tag 时应以"通过全部闸门的那次精确候选提交"为准。

## 3. 1.2.0 范围（已实现）

安装与追新、交互与恢复、节点 1–9 与 URI/PNG/JSON 导出、参数迁移（users/clients、旧调优保留、修订 2）、证书生命周期（共锁/staging/实际供证/ACME 回调）、路由与网络优化、WARP 出站、卸载与接管还原、有界 SNI 预检（含后量子观察）。逐条见 [CHANGELOG](../CHANGELOG.md)。

## 4. 证据

| 层级 | 内容 | 结论 |
| --- | --- | --- |
| 静态 | 62 个 Shell 文件 `bash -n`；ShellCheck（含 CI 门禁） | 通过 |
| 回归 | canonical smoke **258 组** | 通过（`smoke ok`） |
| PTY | 安装边界 68 场景、任务菜单 9 场景 | 通过 |
| 原生传输 | 17 场景：6 组 64 MiB 双向 + 11 负例（凭据/路径/ECH/split 逐腿阻断） | 通过 |
| 迁移 | 3 组历史组合（含 `0.11.14/state1/core26.3.27`、`state2` 夹具、`1.1.0/state2/core26.9.9`） | 通过 |
| 恢复故障注入 | systemd / 文件系统 / 归属 / 部署（upgrade、update-script、install-output-failure） | 通过 |
| 真机全新安装 | `172.239.117.239`（Debian 12 amd64）走公开入口安装候选：三配置校验、三服务 active、5 节点、`diagnose` 无关键问题 | 通过，退出 0 |
| 真机维护 | `recover` 无操作、同值 `change-path`/`change-uuid` noop、同版本 `upgrade` 可信 noop、前后快照一致 | 通过 |
| 真机卸载 | 停机、清理配置、退出 **0**、443/80 空闲；宿主原有 `xray.service`/核心/运行目录/资源配置目录按登记逐字节还原，还原后直接 `systemctl start xray` 即占住 443 | 通过 |
| CI | `shellcheck-and-smoke` + Debian 12/13、Ubuntu 24.04 三个 baseline 安装冒烟 | 全绿 |

原始日志与宿主备份保留在测试机 `/root/xtun-evidence/` 与本机 `/root/xtun-vps-backups/`（私有，不入库）；过程见[新 VPS 验证报告](REPORT-2026-09-19-VPS-VERIFICATION.md)与[接管还原复核](REVIEW-2026-09-19-TAKEOVER-RESTORE.md)。

## 5. 支持矩阵

| 环境 | 状态 |
| --- | --- |
| Debian 12 amd64 | 真实机器全新安装、维护、卸载、宿主还原均验证 |
| Debian 13 / Ubuntu 24.04 | CI 容器安装冒烟通过（含 systemd 容器） |
| Debian 12（共享包环境） | 真实机器验证：宿主已装 nginx/haproxy、已有自己的 xray 服务时的接管与还原 |
| arm64 | 迁移夹具覆盖历史组合；未做原地升级验收 |
| 客户端 | 官方固定镜像容器验证导出 JSON 与 SOCKS 启动；真实 Android/Windows/NAS 仍待 G2/G4 |

## 6. 闸门状态

| 闸门 | 状态 | 还缺什么 | 需要谁提供 |
| --- | --- | --- | --- |
| G0 文档基线 | ✅ | — | — |
| G1 P0 约束 | ⏳ | 强制断电演练：持久 pending 后 / 文件替换中 / 提交决定后各一次，重启后先只读核对再显式恢复（SIGKILL 与 guest reboot 不算） | 云平台控制台 + 电源控制 + 可恢复镜像 |
| G2 第一轮真人 | ❌ | W14.1 真人交互 + W15.1 基础节点 1/3 真实传输（任务见 [TEST-VPS-RUNBOOK](TEST-VPS-RUNBOOK.md) J01–J16） | 操作者 1 名 + 一次可用时段 |
| G3 语义与生命周期 | ⏳ | 公共 ACME 真实签发、定时到期续期、回调失败/重试与公网实际供证 | 受控公网域名（可解析到测试机）+ DNS API 令牌（Cloudflare） |
| G4 实际使用 | ❌ | W14.2/W15 全矩阵：五节点、split、ECH、IPv6/H3、NAS、WARP；需先修完首轮问题 | Android v2rayNG、Windows v2rayN、Debian NAS 设备 |
| G5 正式交付 | ❌ | 同组合 72 小时 + 7 天观察；发布资料与准确产物表；定版本号并打 tag；生产迁移窗口 | 自然时间 + 一次发布授权 |

## 7. 发布步骤（闸门通过后执行）

1. 确认候选提交与 bundle 内容签名，跑完 G1–G5 并归档证据。
2. 定版本号（暂定 `1.2.0`），提升 `SCRIPT_VERSION`，更新 README 版本声明与 [CHANGELOG](../CHANGELOG.md)。
3. 在该精确提交上打 tag（不移动既有 `v1.0.0` / `v1.1.0`），用 CHANGELOG 生成 release notes，附入口摘要与 bundle 内容签名。
4. 生产迁移单独排窗口：按实际安装基线准备隔离兼容测试、备份与恢复材料；发布本身不触发迁移。

## 8. 已知限制

- 容器与自签环境不等于真实 Cloudflare/CDN、GUI 或 NAS 网络；`check-sni` 的「CDN 前置」保持未验证。
- 共享 `haproxy`/`nginx` 若安装前**确在运行**，卸载按共享服务保留并还原原配置；只有"确在运行但原本没有配置"的罕见矛盾仍保守保留并报告未确认。
- 宿主 `/usr/local/etc/xray/config.json` 不是合法 Xray JSON 时，安装在写配置阶段回滚（拒绝覆盖），但日志只给出 jq 错误，提示不够直白。
- W17 其余部分（ML-DSA 签名调查、性能测量、静态站研究）未做，不影响本版既定范围。
