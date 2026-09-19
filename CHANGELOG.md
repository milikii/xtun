# 变更日志

本文件记录各版本的面向用户变更。版本号在正式验收时确定（见[决策 D18](docs/DECISIONS-UX-RELIABILITY.md#d18)）：`main` 上的提交是**测试候选**，不是正式发布；正式发布必须满足 [PLAN](docs/PLAN.md) 的 G1–G5 闸门。

## [未发布] 1.2.0 候选

> 候选身份与就绪状态见[发布就绪清单](docs/RELEASE-READINESS-1.2.0.md)。以下为相对 `v1.1.0` 的变更。

### 安装与追新

- 核心默认追踪官方**最新已发布版本（含预发布）**，单次操作固定 tag、tag 指向的提交、资产 URL 与 SHA256；`--xray-version` 可复现指定版本。
- 安装身份回执：bundle 记录完整运行清单与来源、入口摘要、归档摘要；核心记录 tag/commit/架构/归档摘要以及二进制、两份 geo、属主/模式/capability。可信相同产物为 noop，身份未知或漂移要求显式 `--reinstall`。
- 公开引导先解析固定提交，再校验同一提交的入口与归档；自定义远程包必须给 SHA256。

### 交互与恢复

- 主菜单按六组任务组织；`0` 返回、`:back` 编辑、`:cancel` 取消、EOF 结束会话；动作在独立子进程中隔离上下文。
- 安装草稿与续装、`recover [--yes]` 同代恢复、操作前服务/权限持久快照；确认前只读，确认后才进锁与写入。
- 卸载结果分别列出删除、保留与未能确认项。

### 节点与导出

- 节点 1–9 共用同一份规范对象，生成 URI、PNG 与原生 JSON（`current` / `plain` / `ech`）。
- `export-client --node N --variant … --format uri|json|png --output PATH`：持锁、当前代检查、默认拒绝覆盖、0600/0700 权限。
- `rebuild-qr`：逐字核对规范 URI 与已提交文档后重建，不一致时要求显式迁移。
- 参数迁移：读取旧 `clients`、输出 `users`，保留旧身份/flow/Encryption 与可识别的旧客户端调优（xmux、scMinPostsIntervalMs）；参数修订升为 `2`，state schema 保持 `2`。
- ECH 只作用于 CDN TLS 层；旧 `force` 选项废弃后显式忽略并告警。

### 证书生命周期

- 人工换证/续期与自动回调共享锁、staging、成对提升与失败恢复；验证私钥匹配、SAN、有效期、完整链与信任用途，并核对 nginx **实际供出的叶证书**。
- 同域名换证只 reload nginx，保留 Xray 配置与 URI/PNG，不要求重新导入。
- 已核对 acme.sh 3.1.1 的 `_installcert`：reload 失败可能只记日志而外层仍成功，因此人工调用以本次确认与候选摘要为准；新增 `acme-deploy` 回调命令。

### 卸载与接管还原（本轮新增）

- **安装前告知**：只读检查的「端口与资源归属」列出安装前已存在、会被接管的托管路径（unit 附 enabled/active 状态），安装摘要给出接管说明；不再静默覆盖。
- **首次接管登记与还原**：宿主已有的 `/etc/systemd/system/xray.service`、`/usr/local/bin/xray`、`/var/log/xray`、`/var/lib/xray`、`/usr/local/share/xray`、`/usr/local/etc/xray` 会被登记，卸载按登记**还原**（含 unit 的启用/运行状态）；只有确认是 xtun 自建的（`existed=0`）才删除。
- 接管机制支持目录：`record_takeover_original` 对目录用 `mktemp -d`，`restore_takeover_original` 先拷临时目录校验再移除目标改名。
- **共享 haproxy/nginx 按安装前实际运行状态判定**：包是宿主装的但服务从未启用/运行的，视为 xtun 引入，卸载时停用并清理；安装前就在跑的才按共享服务保留并 reload。卸载不再残留 443/80，也不再恒返回 1。

### 预检与观察

- `check-sni` 为 5 个探针、13 项有界预检，公布等待上界；区分 PASS / WARN / 未验证，证书签发者只说明链来源、不冒充 CDN 前置证据。
- 新增「后量子就绪度」**观察项**：协商到后量子混合组且证书链严格大于 3500 字节才 PASS，其余已测得情况一律 WARN；不产生 FAIL、不改变退出码、不阻断安装。

### 验证与 CI

- canonical smoke **258 组**；安装/任务菜单 PTY **68 / 9** 个场景；原生传输 **17** 场景（含 6 组 64 MiB 双向与逐腿阻断负例）；历史迁移 **3** 组。
- CI 安装矩阵：Debian 12 / Debian 13 / Ubuntu 24.04 容器真机冒烟，另有官方客户端容器、latest 发现与语义/传输任务。
- 另有 systemd / 文件系统 / 归属 / 部署故障注入套件，以及真机全新安装、卸载与宿主还原的验证报告。

### 文档

- 当前入口 [PLAN](docs/PLAN.md)、行为决策 D01–D42、字段契约 [PARAMETERS](docs/PARAMETERS.md)、架构说明 [ARCHITECTURE](docs/ARCHITECTURE.md)、测试与三端手册 [TEST-VPS-RUNBOOK](docs/TEST-VPS-RUNBOOK.md)。
- 批次报告与多份复核/验证报告保留原始证据边界；历史施工图归档在 `docs/archive/`。

## [1.1.0] - 2026-09-10

- 删除订阅托管与 mihomo 输出：不再提供 `/sub/<token>/`，也不生成 mihomo yaml；客户端改用分享链接或扫码导入。已添加的旧订阅会 404，需手动删除。
- 新增节点二维码 PNG（`/root/xtun-qr`，0700/0600，随链接重建）；H3 两条节点（8/9）补进输出文件；`node_link_entries` 成为链接清单单一来源。
- `qrencode` 进入安装依赖与 purge 清单。
- 收录 Xray 官方文档/源码知识库技能并裁剪体积；Cloudflare 缓存绕过表达式恢复为两项。

## [1.0.0] - 2026-09-09

- README 重写为自用手册（节点一览 + 命令表），原理内容移至 `docs/ARCHITECTURE.md`。
- CI 新增 Debian 13 systemd 容器真机冒烟；修复 nginx 先于 haproxy 启动的启动顺序问题。
- 安装补上 `--manage-nginx-main` / `--no-manage-nginx-main` 开关。

## [0.15.0] / [0.14.0] / [0.13.0] / [0.12.0] - 2026-09-09

- **0.15.0**：XHTTP H3 直连下行（nginx QUIC 443 + Alt-Svc + H3 节点）。
- **0.14.0**：IPv6 双栈（节点 6/7、`SERVER_IP6`、haproxy `v4v6`）。
- **0.13.0**：服务器调优补全（接管 `/etc/nginx/nginx.conf`、http2 兼容、sysctl、`NET_BBR_KERNEL` 开关）。
- **0.12.0**：路由卫生（private 拦截、`--block-cn`）、订阅经 nginx 托管、单客户端瘦身。
