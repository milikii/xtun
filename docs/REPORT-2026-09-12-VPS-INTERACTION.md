# 2026-09-12 独立 VPS 实机推进与交互验收记录

> 记录日期：2026-09-12。本文只记录事实、修复落地状态和后续施工项，不把本轮结果扩大为生产就绪结论。测试 VPS 的登录凭据未写入仓库；真实 GUI 客户端、Cloudflare 橙云和 H3 传输路径仍未验收。

## 1. 结论

本轮完成了三件事：

1. **核心追新与 CI 基线落地**：默认安装与显式升级可解析 latest-published（包含 pre-release），并锁定 tag、commit、资产和 SHA256；`v26.9.9` 在本地、Actions 容器和独立 VPS 上均完成安装验证。
2. **真实交互缺陷修复**：修复 SNI HTTP 误报、无参数 `check-sni` 失败、必填项过晚校验、菜单长输出、QUIC 归属误判和公开入口摘要命令名错误。
3. **维护路径验证**：`change-path`、`apply-config`、指定版本 `upgrade`、诊断、二维码、非法输入和参数冲突均完成实机验证。

最终公开入口在卸载后重新安装成功：Xray `v26.9.9`、服务 active、7 条节点、7 张 PNG、无参数 SNI 复检 12 项 PASS。**但这仍不是生产就绪声明**：真实客户端传输、Cloudflare、H3、持续运行和完整人工交互复测仍未完成。

## 2. 代码与 CI 落地记录

| 提交 | 类型 | 实际内容 | Actions |
| --- | --- | --- | --- |
| `32ac9ea` | 代码 | 接入 Xray latest-published 解析、显式 tag、双来源摘要校验、共享版本模块和安装冒烟脚本 | run `34703713056` 成功 |
| `eb3cd42` | 文档 | 记录 T01 代码、CI 和容器验证结果 | run `34703836903` 成功 |
| `96e6c67` | 代码 | 修复 SNI target 探测、无参数入口、输入早期校验、链接摘要、QUIC 归属和交互输出 | run `34705375835` 成功 |
| `d104f6f` | 代码 | 公开入口安装后的摘要改用固定命令 `xtun`，避免显示临时脚本名 | run `34705621691` 成功 |
| `9e1458f` | 文档 | 在生产就绪计划中记录 T02/T03 部分实施与 VPS 验收 | run `34705773172` 成功 |

本地验证：40 个 `.sh` 文件全部通过 `bash -n` 与 ShellCheck；`tests/smoke.sh` 完整通过并输出 `smoke ok`。本文档提交后的 Actions 结果以 GitHub Actions 为准，不在正文预写 run ID。

## 3. 测试环境与证据边界

| 项目 | 记录 |
| --- | --- |
| 系统 | Debian 12 bookworm，x86_64 |
| 规格 | 1 vCPU、约 2GB RAM、50GB 磁盘 |
| 既有服务 | 非托管 `hysteria` 已占用 UDP/443；TCP/443 初始空闲 |
| 初始状态 | 无 xtun/xray/haproxy/nginx 托管配置；systemd 正常 |
| 测试阶段 | 先交互安装，随后部署修复稿复测，最后从公开 `main` 卸载重装 |
| 未覆盖 | Android/Windows/NAS 客户端、真实 Cloudflare 橙云、H3 UDP 路径、证书链语义、72 小时持续运行 |

交互复测分三层，不能混在一起：

1. **初始交互安装**：基于当时已推送基线，暴露原始问题。
2. **修复稿定向复测**：将当前工作区的 `xtun.sh`、`lib`、`static` 部署到测试 VPS 后验证单项行为，不代表公开入口已重装。
3. **最终公开入口验收**：Actions 成功后从 `raw.githubusercontent.com/milikii/xtun/main` 下载脚本，先 `uninstall --yes` 再非交互全新安装。

最终公开入口安装没有重新走一遍完整人工交互输入；人工交互结论来自初始实机操作与修复后的菜单/命令复测。发布前必须再做一次公开入口的完整交互复测。

## 4. 实际操作时间线

### 4.1 初始菜单与交互安装

只运行管理入口并选择退出时，bootstrap 已经把 `/usr/local/sbin/xtun` 和 bundle 持久化到系统。用户未选择“安装或重装”，却发生了系统修改，形成隐性副作用。

随后按菜单 1 交互安装，实际输入：

| 输入项 | 实际操作 |
| --- | --- |
| Server IP | 接受探测默认值 |
| IPv6 | 提示显示探测默认值，按回车；结果生成 IPv6 节点 |
| 节点前缀 / UUID / short ID / path | 接受默认 |
| REALITY SNI | `www.stanford.edu` |
| REALITY target | 默认 `www.stanford.edu:443` |
| XHTTP domain | `cdn.example.test` |
| VLESS Encryption / ECH / xpadding | 默认 yes / no / no |
| 证书模式 | 菜单 `1`，即 self-signed |
| 网络优化 / nginx 主配置 / Block CN / WARP | 均选择 no |

初始 SNI 预检的 HTTP 项失败，交互三选一选择 `i` 继续后部署完成。该失败后来确认是 `curl --resolve` 误用 target 主机名导致，不是目标站不可用。

安装完成时输出 7 条节点，包括 IPv6 节点 6/7。这个结果与“IPv6 留空跳过”的用户预期不一致，是本轮最重要的人体工程学发现之一。

### 4.2 初始状态、诊断和输出

已执行：

```text
xtun status
xtun diagnose
xtun show-links
xtun show-links --qr
```

观察：

- xray、nginx、haproxy 均 active，Xray/Nginx/HAProxy 配置与本地 TLS 探测通过。
- 生成 `/root/xtun-output.md` 和 `/root/xtun-qr`，PNG 数量为 7。
- 菜单 2 原本输出完整部署文档，内容超过一屏，用户需要回滚查找链接。
- 诊断原本把既有 hysteria 的 UDP/443 显示为 `QUIC (UDP 443): 运行中`，但 XHTTP H3 实际未启用。
- 未接管 nginx 主配置时，诊断提示 `worker_connections=768` 并给出 `apply-config --manage-nginx-main`，这是符合用户选择的 actionable 提示。

### 4.3 修复后的维护操作

| 操作 | 结果 |
| --- | --- |
| `xtun check-sni` | 无参数回读已保存 SNI/target/server IP；最终 12 项 PASS |
| `xtun change-path --xhttp-path /content/live2` | 配置、服务、输出文件和 PNG 同步更新 |
| 改回 `/content/live` | 变更成功，摘要仍为 7 条节点 |
| `xtun apply-config` | 按当前状态重建配置并重载服务成功 |
| `xtun upgrade --xray-version v26.9.9` | 可复现指定版本，但相同版本仍重新下载并重启服务 |
| `xtun show-links --qr` | 7 个终端二维码块，PNG 目录 7 张 |
| `show-links --summary --qr` | 正确拒绝互斥参数 |
| `change-path --xhttp-path "bad path"` | 正确拒绝不以 `/` 开头的路径 |
| 交互安装空 SNI | 在第 5 个输入处立即失败，不再继续后续问题 |

### 4.4 最终公开入口重装

在最终代码提交 Actions 成功后执行：

1. `xtun uninstall --yes`，确认托管文件删除、软件包保留。
2. 从 `raw.githubusercontent.com/milikii/xtun/main` 下载脚本。
3. 使用非交互参数全新安装，指定 `www.stanford.edu`、`cdn.example.test`、self-signed，禁用网络优化、nginx 主配置接管和 WARP。

结果：

- 安装时 SNI 预检通过：11 PASS、1 WARN，唯一 WARN 为握手耗时 `0.303120s`。
- 安装后无参数 `check-sni`：12 PASS、0 WARN。
- Xray 选择并安装 `v26.9.9`，tag 指向 `52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120`。
- 摘要来源为 `baseline and GitHub Release API`。
- Xray/Nginx/HAProxy 配置和本地 TLS 探测通过。
- 三个服务 active，输出 7 条节点和 7 张 PNG。
- 安装完成摘要显示正确的后续命令：`xtun show-links` 与 `xtun show-links --qr`。

## 5. 真实交互人体工程学问题清单

| 编号 | 真实交互现象 | 影响 | 当前状态 / 后续 |
| --- | --- | --- | --- |
| E01 | 只打开菜单并退出，bootstrap 已持久化管理命令和 bundle | 用户未确认安装却修改系统，违背最小惊讶原则 | 待修复；应延迟到明确安装动作或显式确认 |
| E02 | IPv6 提示写着“留空跳过”，但显示默认值时按回车会接受默认值，最终生成节点 6/7 | 用户以为跳过 IPv6，实际导出额外节点；`--no-ipv6` 又存在吞参缺陷，缺少可靠跳过方式 | 待修复；需明确空输入语义并修复 CLI 开关 |
| E03 | 网络优化默认 yes，继续后 Joey BBRv3 内核默认 yes，WARP 也默认 yes | 新手一路回车可能安装第三方内核、需要重启，并向 Cloudflare 注册 WARP 设备 | 待修复；高影响可选项应默认 no 或要求显式确认 |
| E04 | UUID、short ID、path 等自动值在必填 SNI/domain 之前询问 | 用户先处理不必要问题，失败后才回到关键输入 | 部分修复：SNI/target/domain 已早校验；输入顺序仍待重排 |
| E05 | 菜单 2 原本输出完整部署文档 | 超长输出淹没真正需要的链接和二维码入口 | 已由 `96e6c67` 改为摘要 |
| E06 | 公开入口保存为临时脚本名时，摘要提示 `xtun-final-install.sh show-links` | 安装后用户应使用 `xtun`，临时文件可能被删除 | 已由 `d104f6f` 修复 |
| E07 | 菜单 10 无参数调用 `check-sni`，原始实现直接要求指定域名 | 已安装节点的便捷入口失效 | 已修复：回读 state/config |
| E08 | HTTP 探测把 target 主机名放入 `--resolve` 的 IP 位置 | 合法目标被误报失败，诱导用户选择 `i` 忽略 | 已修复：改用 `--connect-to` |
| E09 | UDP/443 有 hysteria 时，诊断显示 QUIC 运行中 | 把非 xtun 服务误归属为 XHTTP H3 | 已修复：H3 未启用不检查；启用时确认 nginx 归属 |
| E10 | 证书菜单数字默认为 `1`，帮助/语义默认写 `self-signed` | 可用但需要用户自己做数字与模式映射 | 待优化：提示直接显示 `1（self-signed）` |
| E11 | `show-links --qr` 仍先输出完整部署文档，再输出二维码 | 用户只要扫码时被迫滚动大量文本 | 待优化：提供 `--qr-only` 或让 `--qr` 默认摘要 + 二维码 |
| E12 | `upgrade --xray-version v26.9.9` 在当前已是同版本时仍下载、替换并重启 | “升级”与“重装”语义混淆，浪费时间和连接 | 待定义：已是最新应跳过，重装需显式参数 |
| E13 | 状态面板写“监听 :443”，实际检查 TCP | 在 UDP/443 被其它服务占用时，用户可能误解为任意 443 | 待优化：显示 `TCP :443`，UDP 单独说明 |
| E14 | 最终公开入口验收是非交互安装 | 未证明修复后的完整人工输入路径 | 发布前必须重做公开入口交互安装 |
| E15 | H3 因 Debian nginx 无 http_v3 且 UDP/443 已被占用而不可用 | 无法验证 H3 真实路径；未来启用前必须检查冲突 | 待 T05/T11 |

正面交互模式也应保留：

- 安装失败草稿 `/root/.xtun-install-draft.env` 能保留 UUID、路径等输入，重试体验好。
- SNI 预检失败后的 `r/i/q` 三选一能明确重填、忽略或退出；选择 `i` 会留下警告。
- 非法路径、互斥参数和空 SNI 都能及时拒绝。
- `worker_connections` 警告说明了当前值、影响和修复命令。
- 修复后的菜单 2 只显示文件、节点清单和下一步命令，符合“先概览、再深入”的逻辑。

## 6. 产物与恢复记录

测试中产生的关键位置：

| 类型 | 位置 |
| --- | --- |
| 链接文档 | `/root/xtun-output.md` |
| PNG 二维码 | `/root/xtun-qr` |
| 状态文件 | `/usr/local/etc/xray/node-meta.env` |
| Xray 配置 | `/usr/local/etc/xray/config.json` |
| Nginx 配置 | `/etc/nginx/conf.d/xtun.conf` |
| 备份 | `/root/xtun-backups/<timestamp>` |
| 操作日志 | `/var/log/xtun/operations.log` |

代表性备份时间：

- 初始安装：`20260912-160509`
- 路径变更：`20260912-162131`、`20260912-162334`
- 重建配置：`20260912-162344`
- 指定版本升级：`20260912-162400`
- 卸载：`20260912-163107`、`20260912-163508`
- 最终公开重装：`20260912-163515`

## 7. 后续施工要求

1. **先修交互阻断项**：E01、E02、E03、E04 与 F04 `--no-ipv6` 属于同一安装体验工单，不应分散修补。
2. **公开入口复测**：修复后必须从公开入口做完整交互安装，记录每一步输入、默认值、实际结果和用户预期是否一致。
3. **命令语义收敛**：定义 `upgrade` 的同版本行为；如需重装，增加显式 reinstall 参数。
4. **输出分层**：完整文档、摘要、二维码和原生 JSON 应有清晰入口；`--qr` 不应强制附带全文。
5. **端口显示分层**：TCP/UDP、功能启用、进程归属和外部可达性分开显示。
6. **继续真实端到端验收**：v2rayNG、v2rayN、NAS Docker、Cloudflare、ECH、H3 和持续运行按主计划 T11 执行。

## 8. 状态判定

| 范围 | 当前判定 |
| --- | --- |
| 公开入口非交互安装 | 通过 |
| Xray `v26.9.9` 选择与校验 | 通过 |
| 服务配置与本地诊断 | 通过 |
| 链接/PNG 数量与摘要 | 通过 |
| 维护命令 | 基本通过；同版本升级语义待定义 |
| 完整人工交互 | 未通过，存在 E01–E04、E10–E13 |
| 真实客户端传输 | 未执行 |
| Cloudflare / ECH / H3 | 未执行或环境不可用 |
| 生产就绪 | 不能宣称 |
