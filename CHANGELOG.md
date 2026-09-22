# 变更日志

本文件记录各版本的面向用户变更。版本号在正式验收时确定（见[决策 D18](docs/DECISIONS-UX-RELIABILITY.md#d18)）：`main` 上的提交是**测试候选**，不是正式发布；正式发布必须满足 [PLAN](docs/PLAN.md) 的 G1–G5 闸门。

## [1.1.1] - 2026-09-20

补丁版：修复主菜单 `check-sni` 交互死循环与 IPv6 双栈入口，并新增主菜单一级「升级脚本」。详见[修复记录](docs/REPORT-2026-09-20-MENU-UX-FIX.md)。

### 交互与恢复

- `check-sni` 没有已保存域名时交互询问要检查的域名（菜单「检查 REALITY SNI」同一条路径），不再直接报错把用户困在「选 3 → 报错 → 回车 → 再选 3」的循环；非交互入口仍然直接失败。菜单入口把「预检不通过」（退出码 2）当作检查结论正常返回，不再提示「菜单操作失败，请运行 xtun recover」。
- `check-sni` 报告文案更直白：头部点明「伪装 SNI」与「回落目标」并给出一行 PASS/WARN/未验证/FAIL 判定说明；跨主机跳转的 FAIL 说明为什么要主机名一致、应改成哪个域名；后量子项标注「观察项，不阻断安装」；结论给出可执行的下一步。
- 新装基础问答直接询问是否启用 IPv6 直连双栈：默认关闭，回车不会多出节点 6/7；选择启用后地址留空会当场重问，不再要求用户先知道确认页的 `advanced` 关键词。
- 安装高级项补上「是什么、有什么用」：xpadding（随机长度填充）、ECH（隐藏真实 SNI）、H3 直连（XHTTP 下行走 QUIC/UDP 443）各一句说明；网络优化写明**当前内核即可开 BBR+fq 与 sysctl/qdisc，第三方内核可选、不装也保留优化**；确认页提示改为「输入 advanced 进入高级选项；输入 back 改地址/域名/证书」。
- 启用 XHTTP xpadding 后不再追问 key/Header/placement/method 四个参数：脚本直接套用默认值并打印生效参数，要自定义仍走 `--xhttp-xpadding-*`。
- 修复 `prompt_yes_no` / `prompt_with_default` / `prompt_secret` 在调用方变量名为 `answer` 时的写入遮蔽：高级项 H3 回答 `n` 曾被误判成「H3 只能是 yes 或 no」。
- `acme-http` 的 `socat` 依赖进入确认前的只读检查与最小依赖准备，不再等到深预检才失败（此前会先装完其它包再停在预检，留下草稿）。
- 修复已开 WARP 时的「是否导入 wgcf profile」问答：选自动注册（默认）现在明确返回成功，不再让恢复草稿/重建的安装在这句话之后静默失败；取消与 EOF 仍然失败。
- 主菜单新增一级「升级脚本」（未安装菜单第 5 项、已安装菜单第 7 项），复用 `update-script`：下载 GitHub `main` 的最新 bundle、校验并在确认后安装；已安装菜单的「升级与维护 → 更新脚本」保留。
- 菜单内「升级脚本」成功后自动用新入口重开菜单：以前升级只换了磁盘文件，当前菜单进程仍在跑旧函数，用户接着安装/恢复草稿用的还是升级前的代码（实测 2026-09-20：连升级两次仍复现同一个缺陷）。找不到新入口时明确提示并退出菜单。
- ACME 账户邮箱在交互问答里改为必填（非空且形如 `local@domain`），`validate_install_inputs` 在拿锁前再挡一次：以前允许留空，安装会走到写入托管配置才报错，依赖已装完、只能整体回退（实测 2026-09-21）。
- 失败回退不再把「操作前不存在的服务」永远记为未恢复：软件包（apt）不在回滚范围内，`haproxy` / `nginx` 这类由本次安装带来的 unit 只要已停止并禁用就算恢复到位，pending 操作可以正常清理；以前这种情况会让 `recover` 一直报未恢复、`install` 被 pending 挡死。
- 外来进程占用 TCP 443 时在确认页之前就停下：只读检查早已算出「被 nginx 占用（外来，不会停止或接管）」，但以前只是打印一行，用户填完高级项、按下 y 才在深预检失败并留下草稿（实测 2026-09-21：另一台测试机上 nginx 监听 0.0.0.0:443）。现在交互模式提示占用者与 `systemctl stop …` 命令，释放端口后回车复检；非交互直接失败。深预检沿用同一判定函数，文案不变。
- ECH、xpadding、网络优化、拦截回国进入基础问答：证书模式之后各问一次（默认关；网络优化答 `y` 后追问是否装第三方内核），不再只能在确认页 `advanced` 里逐个找；命令行显式给过的不再问，非交互不变。修复 ECH 答 `y` 后摘要仍显示 `ECH=关`（开关值没有规范化写回）。
- 安装摘要列出本次会生成的节点：1–5 固定，6/7 随 IPv6，8/9 随 H3，开 ECH 时注明作用于 3/4/5 的 CDN TLS 层。
- 装完那一屏直接印出每个节点可复制的链接（`show-links --summary --with-links`），并打印 Cloudflare 缓存绕过表达式与 Bypass cache 提示；菜单里的普通摘要仍不带链接。

### 脚本版本

- `SCRIPT_VERSION` 由 `1.1.0` 提升为 `1.1.1`；state schema `2`、参数修订 `2` 不变，从 `1.1.0` 升级无需迁移。

### 验证与 CI

- canonical smoke **272 组**全绿，新增 ACME 邮箱必填、失败回退服务状态、菜单升级重载、高级项行为、WARP 问答、prompt 写入目标、依赖阶段与 SNI/双栈/菜单用例，以及确认页前 443 闸门、基础问答组合项与装完链接/缓存提示用例；smoke 默认把 `ss` 桩成「端口全空闲」，宿主机上装着 xtun 时向导用例不再被真实 443 监听拦下。测试里近 190 处 `printf '%s' "$var" | grep -q` 断言改为 here-string：grep 命中即退出会让 printf 吃 SIGPIPE，`pipefail` 下整条用例以 141 挂掉（1 vCPU 真机三次复现，每次不同用例）。

## [未发布] 1.2.0 候选

> 候选身份与就绪状态见[发布就绪清单](docs/RELEASE-READINESS-1.2.0.md)。以下为相对 `v1.1.0` 的变更；交互修复已在 1.1.1 单独发布。

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
- 新增 `acme-http` 证书模式：用 `acme.sh` 的 HTTP-01 自动申请公有证书，**不需要 DNS 令牌**，要求域名解析到本机；签发与续期时让 nginx 短暂让出 80 端口并在成功或失败后都恢复。

### 卸载与接管还原（本轮新增）

- **安装前告知**：只读检查的「端口与资源归属」列出安装前已存在、会被接管的托管路径（unit 附 enabled/active 状态），安装摘要给出接管说明；不再静默覆盖。
- **首次接管登记与还原**：宿主已有的 `/etc/systemd/system/xray.service`、`/usr/local/bin/xray`、`/var/log/xray`、`/var/lib/xray`、`/usr/local/share/xray`、`/usr/local/etc/xray` 会被登记，卸载按登记**还原**（含 unit 的启用/运行状态）；只有确认是 xtun 自建的（`existed=0`）才删除。
- 接管机制支持目录：`record_takeover_original` 对目录用 `mktemp -d`，`restore_takeover_original` 先拷临时目录校验再移除目标改名。
- **共享 haproxy/nginx 按安装前实际运行状态判定**：包是宿主装的但服务从未启用/运行的，视为 xtun 引入，卸载时停用并清理；安装前就在跑的才按共享服务保留并 reload。卸载不再残留 443/80，也不再恒返回 1。

### 预检与观察

- `check-sni` 为 5 个探针、13 项有界预检，公布等待上界；区分 PASS / WARN / 未验证，证书签发者只说明链来源、不冒充 CDN 前置证据。
- 新增「后量子就绪度」**观察项**：协商到后量子混合组且证书链严格大于 3500 字节才 PASS，其余已测得情况一律 WARN；不产生 FAIL、不改变退出码、不阻断安装。

### 验证与 CI

- 安装/任务菜单 PTY **68 / 9** 个场景；原生传输 **17** 场景（含 6 组 64 MiB 双向与逐腿阻断负例）；历史迁移 **3** 组。
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
