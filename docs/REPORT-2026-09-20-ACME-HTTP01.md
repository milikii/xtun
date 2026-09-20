# acme-http（HTTP-01）实现与真机验证报告（2026-09-20）

> 环境：测试 VPS `172.239.117.239`（Debian 12 amd64），域名 `li.miliki.us.ci`（Cloudflare 代理，解析到 `172.67.223.4`）。
> 候选：`e5d69c4`（实现）、`d0e759c`（预检放宽）；运行代码经 `xtun update-script` 更新到该候选后在真机执行。
> 目的：给 G3 补上"不依赖 DNS 令牌"的公共 ACME 真实签发与续期证据。

## 1. 结论

新增 `acme-http` 证书模式（HTTP-01，不需要任何 API 令牌）后，真机上由 **xtun 自己**完成了：向 Let's Encrypt 真实签发、`acme.sh` 定时续期触发、`acme-deploy` 回调部署、以及"核对 nginx 实际供出证书"。失败路径也验证过一次：严格预检拒绝时完整回退，服务与旧证书不受影响。

## 2. 实现

- **证书家族判断收敛**：新增 `cert_mode_is_acme`（`acme-dns-cf|acme-http`），替换散落在签发、诊断、卸载、generation、面板等处的 `== acme-dns-cf`。
- **签发**：`issue_acme_http_cert` 用 `acme.sh --standalone`，与 DNS 模式共用暂存、回调回执校验、成对提升与实际供证验证，不放宽任何一步。
- **端口让位**：`--pre-hook "systemctl stop nginx"` / `--post-hook "systemctl start nginx"`。已核对 acme.sh 3.1.1 的 `_on_issue_success` 与 `_on_issue_err` 都会执行 post-hook，不会把 nginx 停在关闭状态。
- **预检**：安装前检查域名能否解析、`socat` 是否存在；**完全解析不到**直接拒绝，解析到别的地址（可能是 Cloudflare 等代理）只告警并继续。签发时再复核一次。
- **依赖**：`acme-http` 模式按需安装 `socat`，并纳入包归属登记（`--purge` 只删 xtun 装的）。
- **入口**：菜单第 4 项、CLI `--cert-mode acme-http`（历史数字别名 `5`）；帮助、摘要、诊断面板同步。

## 3. 验证

### 3.1 自动

- 新增 `run_acme_http_issue_case`：模式识别与别名规范化、解析失败拒绝/解析到别处放行、签发参数含 `--issue --standalone` 与 pre/post hook 且不含 `dns_cf`、不导出 `CF_Token`。
- 契约用例 `run_cert_mode_roundtrip_case` 补 `acme-http` 往返与菜单第 4 项断言。
- canonical smoke **259 组通过**；ShellCheck 干净。

### 3.2 真机

| 步骤 | 结果 |
| --- | --- |
| `change-cert-mode --cert-mode acme-http --acme-email …` | exit 0；模式切到 `acme-http`；acme.sh 认为现有证书未到期（`RENEW_SKIP`），走"重新校验并部署现有证书"分支，完成供证校验 |
| `renew-cert`（先移走 acme.sh 证书目录以强制真签发） | exit 0；经 HTTP-01（挑战由 Cloudflare 转发到源站）签出**新序列号 `069FB97109AA427D5087E8BDCB8ED81EBF50`**，Let's Encrypt，post-hook 恢复 nginx |
| `acme.sh --cron --force`（模拟定时续期） | exit 0；pre-hook 停 nginx → standalone 签发**新序列号 `0676D1001FD098394E69051DA9668A0811B3`** → `reloadcmd` 调 `xtun acme-deploy` → 事件记录 `acme-callback success / 已验证 nginx 实际提供的证书` → post-hook 启 nginx |
| 失败回退（改动前的严格预检） | exit 1；域名解析到代理被拒，`/etc/ssl/xtun`、`node-meta.env`、输出与二维码、acme.sh 证书目录**全部还原**，旧证书继续供出，服务未中断 |

三种情况下 `nginx`/`haproxy`/`xray` 均保持 active，443/80 正常监听，节点链接未变。

## 4. 边界与残留

- **代理场景**：HTTP-01 经 Cloudflare 代理时，依赖代理把 `/.well-known/acme-challenge/` 转发到源站 80；本轮实测可行。预检只对"完全解析不到"硬拦，解析到别处按代理处理。
- **自然到期续期**：本轮用 `--cron --force` 走同一条代码路径，未等到 ARI 窗口（2026-11-18）自然触发；计时本身不由测试改变。
- **回调失败/重试的实机注入**：未做；自动用例 `run_acme_deferred_callback_case` 覆盖回调失败不冒充成功的逻辑。
- **DNS-01**：`acme-dns-cf` 的公共签发仍未做（需要 Cloudflare 令牌）；本报告只覆盖 HTTP-01。

## 5. 对 G3 的推进

G3 原先卡在"公共 ACME 真实签发/续期需要受控域名 + DNS 令牌"。`acme-http` 落地后，**只要域名能解析并让挑战到达本机，就不再需要任何令牌**。本轮已完成真实签发、续期回调与实际供证；剩余的外部项是自然时间的到期续期和实机回调故障注入。
