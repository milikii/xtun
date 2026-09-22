# xtun

`xtun` 是一个面向 Debian / Ubuntu VPS 的一键部署与维护脚本。它把 `xray`、`haproxy`、`nginx`、Cloudflare CDN、可选 WARP 出站、证书和网络优化组合成一套可重复安装、可回滚、可维护的代理节点栈。

| 项目 | 当前值 |
| --- | --- |
| 代码声明版本 | `1.1.1`（`1.2.0` 候选已在 `main`） |
| 发布就绪 | 代码与自动验证已就绪；正式发布待 G1/G2/G4/G5 的外部证据，见[发布就绪清单](docs/RELEASE-READINESS-1.2.0.md) |
| 支持环境 | Debian 12 / Debian 13 / Ubuntu 24.04（amd64）；CI 容器安装矩阵 + 真机全新安装验收 |
| 核心基线 | Xray `v26.9.9`；默认追踪官方最新已发布版本（含预发布） |
| state / 参数 | schema `2` / 参数修订 `2`（从 1.1.0 升级无需迁移） |

**文档地图**：[CHANGELOG](CHANGELOG.md)（逐版本变更）、[发布就绪清单](docs/RELEASE-READINESS-1.2.0.md)（证据与闸门）、[当前计划](docs/PLAN.md)、[架构说明](docs/ARCHITECTURE.md)、[参数契约](docs/PARAMETERS.md)、[行为决策 D01–D43](docs/DECISIONS-UX-RELIABILITY.md)、[测试与三端手册](docs/TEST-VPS-RUNBOOK.md)。

提交到 `main` 是**测试候选**：安装、维护、恢复、卸载与证书生命周期都在真机验证过；正式发布仍需强制断电、真人与三端（含 Windows/NAS）、真实观察期等验收，见[发布就绪清单](docs/RELEASE-READINESS-1.2.0.md)第 6 节。

## 能安装什么

默认安装完成后，同一台 VPS 会复用 `443` 端口导出 5 条 VLESS 链接：

| 节点 | 用途 |
| --- | --- |
| `REALITY + Vision` | 直连 Reality 节点 |
| `XHTTP + Reality` | XHTTP 下行直连 Reality |
| `XHTTP + TLS + CDN` | 经过 Cloudflare CDN 的 XHTTP 节点 |
| `上行 XHTTP + TLS + CDN / 下行 XHTTP + Reality` | 上下行分离节点 |
| `上行 XHTTP + Reality / 下行 XHTTP + TLS + CDN` | 反向上下行分离节点 |

脚本还会处理：

- `haproxy + nginx + xray` 的混合前置与 `443` 端口复用
- `Cloudflare WARP` 选择性出站（Xray 原生 WireGuard，无守护进程）
- 现有证书（含 Cloudflare Origin CA）、自签证书、`acme.sh` 的 DNS-01（Cloudflare）与 **HTTP-01**（不需要令牌）证书模式
- `Joey BBRv3 + qdisc + RPS/XPS` 网络优化
- 安装、变更、升级、卸载过程中的备份、校验、回滚和操作日志

## 适用场景

适合：

- 一台 Debian / Ubuntu VPS 同时提供 Reality、XHTTP CDN 和 XHTTP split 节点
- 希望 Cloudflare CDN 只承载 XHTTP，Reality 走直连或灰云域名
- 需要让部分目标域名走 Cloudflare WARP，其它流量保持直连
- 需要后续通过 `xtun` 修改 SNI、路径、UUID、证书和 WARP

不适合：

- 非 Debian / Ubuntu 系统
- 无 root 权限环境
- 已经有复杂 nginx 站点，并且不希望脚本接管 nginx/haproxy/xray 配置

## 快速开始

在 VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/milikii/xtun/main/xtun.sh -o xtun.sh
bash xtun.sh
```

不带参数时会进入菜单。第一次安装通常选择：

```text
1. 安装 / 恢复草稿（先选任务）
```

菜单和 CLI 走同一条路径：已经装过（或上次安装失败留下草稿）时，先明确这次的动作——
`全新安装`、`恢复一次失败的安装`、`按当前状态重建`、`轮换凭据`——再进入问答。

安装完成后会生成管理命令：

```bash
xtun
```

### Xray 核心版本策略

新安装和 `xtun upgrade` 默认解析 Xray-core 最新已发布版本，包含 pre-release；单次操作会固定 tag、tag 指向的提交、资产 URL 和 SHA256。需要复现指定版本时使用：

```bash
xtun upgrade --xray-version vX.Y.Z
```

仓库 CI 用 `v26.9.9` 作为可复现基线，覆盖配置、五类节点的隔离原生双向传输、历史迁移和导出容器启动。定时/手动运行的 `latest-check` 对一次解析并校验的候选运行完整 smoke 与原生传输，安装矩阵另测 baseline/latest。原生夹具不经过 Cloudflare，不能据此认定真实 CDN、GUI 或 NAS 网络已兼容。

后续维护都可以直接运行 `xtun`，不用再进入仓库目录。

安装后的主菜单按六组组织：`1 获取节点`、`2 查看状态与诊断`、`3 修改节点`、`4 升级与维护`、`5 网络与可选功能`、`6 恢复与卸载`，另有 `7 升级脚本`（未安装时是同一动作的 `5`）。安装任务位于 `4 → 7`。菜单里升级脚本成功后会自动用新版本重新打开菜单，不会拿升级前的旧代码继续执行后续动作。菜单顶部只显示精简状态，不执行配置自检或 TLS 握手；完整体检使用 `2`、`xtun status` 或 `xtun diagnose`。

任务菜单输入 `0` 返回主菜单；填写字段时用 `:back` 返回编辑、`:cancel` 取消本次动作。输入错误就地重填；动作失败或 Ctrl-C 后可以继续使用菜单，EOF 结束会话。TERM 会等待当前动作清理或恢复后退出。

主菜单和安装/卸载的最终确认前只读取、预览，不开启持久锁、日志或备份，不隐式保存草稿。确认后取得锁并重新检查现场；期间发生变化时原确认失效，需要重新查看预览。

## 安装前准备

最低需要：

- Debian / Ubuntu VPS
- root 权限
- 一个用于 `XHTTP CDN` 的 Cloudflare 橙云域名，例如 `cdn.example.com`
- 一个用于 Reality SNI 的域名，例如 `reality.example.com`
- 覆盖 XHTTP CDN 域名的证书，或准备让脚本生成/申请证书

推荐 DNS 形态：

| 域名 | Cloudflare 状态 | 用途 |
| --- | --- | --- |
| `cdn.example.com` | 橙云 | XHTTP CDN |
| `reality.example.com` | 灰云 / DNS only | Reality SNI |

如果启用 WARP，默认会自动向 Cloudflare 注册一台免费 WARP 设备，不需要任何账号或密钥。
只有在机房 IP 被拒绝注册，或你想用自己的 WARP+ 账号时，才需要准备一份 `wgcf` 生成的 `profile.conf`。

## 非交互安装示例

推荐把敏感值放进文件或环境变量，不要直接写进 shell history。

非交互模式同样要先确定任务：全新安装 `--task fresh`，恢复草稿 `--task resume`
（等价 `--resume-draft`），按当前状态重建 `--task rebuild`（等价 `--rebuild-current`），
轮换凭据 `--task rotate`（等价 `--rotate-credentials`）。有未完成的安装草稿时，
非交互入口必须显式选任务，不会静默加载上次输入；想丢掉草稿重新开始用
`--discard-draft`。全新安装的可选高影响项（IPv6、WARP、网络优化、第三方内核、
接管 nginx 主配置、回国拦截、H3、ECH、xpadding）默认全部关闭；IPv6 双栈、ECH、
xpadding 在基础问答里直接询问，其余需要在确认页的 `advanced` 入口或命令行显式打开；
VLESS Encryption 默认开启。确认页会列出本次生成的节点编号与含义；装完的节点摘要
直接给出 Cloudflare 缓存绕过表达式。

使用已有证书并启用 WARP（默认自动注册免费 WARP，无需任何密钥）：

```bash
bash xtun.sh install --non-interactive \
  --server-ip 203.0.113.10 \
  --node-label-prefix HKG \
  --reality-sni reality.example.com \
  --xhttp-domain cdn.example.com \
  --xhttp-path /assets/v3 \
  --cert-mode existing \
  --cert-file /etc/ssl/cloudflare/cert.pem \
  --key-file /etc/ssl/cloudflare/key.pem \
  --enable-warp
```

机房 IP 被 Cloudflare 拒绝注册，或想用自己的 WARP+ 账号时，导入 `wgcf` 生成的 profile：

```bash
bash xtun.sh install --non-interactive \
  --server-ip 203.0.113.10 \
  --node-label-prefix HKG \
  --reality-sni reality.example.com \
  --xhttp-domain cdn.example.com \
  --xhttp-path /assets/v3 \
  --cert-mode existing \
  --cert-file /etc/ssl/cloudflare/cert.pem \
  --key-file /etc/ssl/cloudflare/key.pem \
  --enable-warp \
  --warp-profile @/root/wgcf-profile.conf
```

不启用 WARP：

```bash
bash xtun.sh install --non-interactive \
  --server-ip 203.0.113.10 \
  --node-label-prefix HKG \
  --reality-sni reality.example.com \
  --xhttp-domain cdn.example.com \
  --xhttp-path /assets/v3 \
  --cert-mode self-signed \
  --disable-warp
```

启用网络优化：

```bash
bash xtun.sh install --non-interactive \
  ... \
  --enable-net-opt
```

队列算法固定为 `fq`（BBR 系列拥塞控制的配套要求），无需也无法指定；
拥塞控制算法由脚本按内核实际暴露的模块自动选（优先 `bbr1`，没有就 `bbr`）。

## 敏感参数输入规则

下面这些参数不接受命令行明文值，只支持 `@文件路径` 或对应环境变量：

| 参数 | 环境变量 |
| --- | --- |
| `--warp-private-key` | `WARP_PRIVATE_KEY` |
| `--warp-profile` | `WARP_PROFILE` |
| `--cf-dns-token` | `CF_DNS_TOKEN` |
| `--reality-private-key` | `REALITY_PRIVATE_KEY` |

下面这些 PEM 参数只支持 `@文件路径`；交互模式可以粘贴 PEM：

- `--cert-pem`
- `--key-pem`

示例：

```bash
CF_DNS_TOKEN=xxxxxxxx xtun renew-cert --non-interactive
xtun change-cert-mode --cert-mode existing --cert-pem @/root/cf-origin.pem --key-pem @/root/cf-origin.key
```

## 架构说明

`xtun` 在同一台 Debian / Ubuntu VPS 的 `443` 端口导出 5（+IPv6/H3 各 +2）条节点，请求流图、为什么有 haproxy、为什么 Reality 目标不用自己的域名等原理性内容见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

### 节点一览

| # | 节点 | 用途 |
| --- | --- | --- |
| 1 | VLESS + REALITY + Vision（直连） | 主力直连 |
| 2 | VLESS + XHTTP + REALITY（上下行不分离） | 直连备用 |
| 3 | VLESS + XHTTP + TLS + CDN | 日常用，走 Cloudflare |
| 4 | 上行 XHTTP + TLS + CDN ｜ 下行 XHTTP + REALITY | 上下行分离，备用 |
| 5 | 上行 XHTTP + REALITY ｜ 下行 XHTTP + TLS + CDN | 反向分离，备用 |
| 6 | REALITY-V6（有 IPv6 时） | 节点 1 的 IPv6 版 |
| 7 | XHTTP-SPLIT-CDN-REALITY-V6（有 IPv6 时） | 节点 4 的 IPv6 下行 |
| 8 / 9 | XHTTP-TLS-H3 / XHTTP-SPLIT-CDN-H3（显式启用且本地条件通过） | H3 直连 / CDN 上行与 H3 直连下行 |

### 命令表

| 命令 | 作用 |
| --- | --- |
| `install [参数]` | 安装或重装 |
| `update-script [--reinstall]` | 更新脚本 bundle；可显式重装相同版本 |
| `upgrade [--xray-version vX.Y.Z] [--reinstall]` | 升级核心及配套 geo；可显式重装身份未知或漂移的相同版本 |
| `recover [--yes]` | 按持久清单恢复未完成操作；已提交的操作只完成清理 |
| `check-sni [域名] [--target host:port] [--timeout N]` | Reality 目标域名预检；默认探测已保存的 `REALITY_TARGET`（显式域名时用该域名:443），没有已保存域名时交互询问（菜单「检查 REALITY SNI」同一条路径）；有公布出来的等待上界；含不阻断的「后量子就绪度」观察项 |
| `change-uuid` / `change-sni` / `change-path` | 轮换 UUID / 改 SNI（含预检）/ 改路径 |
| `change-warp` / `change-warp-rules` | WARP 开关 / 分流规则 |
| `change-h3 [--enable-h3\|--disable-h3]` | 显式选择 H3；启用前校验证书、模块和 UDP 归属 |
| `change-cert-mode` / `renew-cert` | 换证书模式 / 续期证书 |
| `acme-deploy --domain DOMAIN` | ACME 回调/重试暂存证书部署；使用共享锁并核对 nginx 实际供证，通常由 acme.sh 的 reload 钩子调用 |
| `show-links [--node N] [--qr\|--summary]` | 全文、单节点、摘要或二维码；查看不重写产物 |
| `export-client --node N --variant current\|plain\|ech --format uri\|json\|png --output PATH [--overwrite]` | 独立导出节点，不改服务或 state |
| `rebuild-qr [--yes]` | 按已提交的节点定义重建 PNG，不重启服务 |
| `diagnose [--warp-probe] [--net]` | 一次性诊断 / 网络栈体检 |
| `status [--raw]` | 状态面板 / 原始 systemctl 输出 |
| `restart` / `repair-perms` | 重启服务 / 抢修文件权限 |
| `apply-config [--manage-nginx-main]` | 按当前状态重渲染托管配置 |
| `apply-net-opt [--bbr-kernel joey\|none]` | 重新应用网络优化 |
| `uninstall [--yes] [--purge]` | 卸载 |

## 安装会写入哪些文件

主要路径：

| 路径 | 说明 |
| --- | --- |
| `/usr/local/sbin/xtun` | 安装后的管理命令 |
| `/usr/local/lib/xtun` | 脚本 bundle |
| `/usr/local/lib/xtun/.xtun-bundle.json` | bundle 来源、完整运行文件摘要与安装回执 |
| `/usr/local/share/xray/.xtun-core.json` | 核心/geo/官方归档摘要、权限和 capability 回执 |
| `/usr/local/etc/xray/config.json` | Xray 配置 |
| `/etc/nginx/conf.d/xtun.conf` | nginx 托管配置 |
| `/etc/nginx/nginx.conf` | 仅 `--manage-nginx-main` 接管时由 xtun 整体重写 |
| `/etc/systemd/system/nginx.service.d/xtun-limits.conf` | nginx 的 fd 限额 drop-in |
| `/etc/haproxy/haproxy.cfg` | haproxy 托管配置 |
| `/etc/systemd/system/xray.service` | Xray systemd unit |
| `/usr/local/etc/xray/node-meta.env` | xtun 状态文件 |
| `/root/xtun-output.md` | 人类可读节点输出（节点 1–9 + 二维码段） |
| `/root/xtun-qr/` | 节点二维码 PNG（每条节点一张，随链接重建） |
| `/root/xtun-qr/manifest.json` | 绑定配置、state、文档、节点对象和 PNG 的当前代清单 |
| `/etc/ssl/xtun/.xtun-certificate.json` | 证书元数据及实际供证核验回执 |
| `/root/xtun-backups/` | 变更备份目录 |
| `/var/log/xtun/operations.log` | 全局操作日志 |
| `/var/log/xtun/certificate.json` | 最近证书事件、结果与续期信息 |
| `/var/www/xtun-fallback` | 本地静态伪装站 |

> 安装前如果这些路径里已经有你自己的东西（例如已有的 `/etc/systemd/system/xray.service`、`/usr/local/bin/xray`，或它依赖的 `/var/log/xray`、`/var/lib/xray`），xtun 会先登记原件与当时的启用/运行状态，卸载时按登记**还原**；只有确认是 xtun 自己创建的才删除。安装前的只读检查会把将要接管的路径列在「待接管」里。`haproxy`/`nginx` 是否按共享服务保留，看的是**安装前有没有真的在跑**，与包是谁装的无关。

## 日常命令

### 查看状态

```bash
xtun status
```

状态面板会显示服务状态、监听端口、证书到期时间、核心和 bundle 身份、WARP 出站模式、WARP 规则数量和最近备份。版本相同但没有可信回执时，身份显示未知，不冒充已核验。

查看原始 systemd 输出：

```bash
xtun status --raw
```

### 路由拦截

出站路由固定带两条卫生规则：`geoip:private` 与 `geosite:private` 一律 blackhole，防止来自代理的流量访问内网/回环地址。回国流量（`geoip:cn` / `geosite:cn`）默认不拦截，安装时加 `--block-cn` 或交互里选择开启即可；已装节点改状态文件里的 `ROUTE_BLOCK_CN` 后跑 `xtun apply-config` 生效。

`xtun diagnose` 会报当前拦截状态（`private` / `private+cn`）。

### IPv6 双栈

新装默认关闭 IPv6。基础问答里会直接问一次「是否启用 IPv6 直连双栈？」：回车即关闭，选 `y` 才追问地址（默认填自动探测到的本机全局单播地址，只认 `2000::/3`），不会再因为看不见 `advanced` 关键词而找不到开启入口。也可以在确认页 `advanced` 的选项 1 或命令行 `--server-ip6` 指定。已保存的选择（state、草稿、`--server-ip6`）照旧保留，重建不会因为改了默认值自动关掉已开的双栈。

有 IPv6 时：

- haproxy 监听改为 `bind :::443 v4v6`（无 IPv6 的机器同样合法，IPv4 走 mapped 地址）
- 追加两条链接：`REALITY-V6`（节点 1 的 IPv6 版）与 `XHTTP-SPLIT-CDN-REALITY-V6`（节点 4 的 IPv6 下行）
- `xtun status` 面板与 `xtun diagnose` 会显示 IPv6 状态

也可以显式指定：`--server-ip6 2408:8120::xxx`。

### XHTTP H3 直连下行

H3 直连指 XHTTP 的**下行**从 TCP/TLS 换成 QUIC（HTTP/3，UDP 443）直达 VPS，减少下行队头阻塞；上行仍按 XHTTP/CDN 或 REALITY 走 TCP。它需要公共信任证书和可用的 UDP 443，所以新装默认关闭。安装时通过 `--enable-h3` 或高级设置显式开启；已安装环境使用：

```bash
xtun change-h3 --enable-h3
xtun change-h3 --disable-h3
```

开启需要同时通过三项本地检查：

1. 实际 nginx 二进制包含 `http_v3` 模块。
2. 证书与私钥匹配，DNS SAN 覆盖 XHTTP 域名，有效期和服务器用途正确，完整链通过发行版 Mozilla 公共根验证。Origin CA、自签、私有 CA、缺中间链或未知信任不能放行。
3. UDP 443 空闲，或全部监听属于已有托管 H3 配置及 `nginx.service` 的进程；外来或无法确认的监听会阻止开启。

证书模式只表示来源，不代替上述检查。缺依赖或条件不满足时明确失败，不停止外来 UDP 服务。旧 state 没有 H3 字段时，从完整的托管配置识别 `legacy-on` 或 `off`；证据不完整则标为 `unknown`，要求显式选择，不能用新默认删除旧配置。查看状态不写回迁移结果。

nginx 的 QUIC 监听、`Alt-Svc`、节点 8/9 和输出说明使用同一次判定。节点 9 的下行 ALPN 已置于 `downloadSettings.tlsSettings.alpn=["h3"]`，外层 CDN 仍走 H2。节点 7 保持 CDN 上行，仅 REALITY 下行使用 VPS IPv6。本地检查通过不代表公网 UDP、客户端信任库或真实 H3 传输通过；字段与兼容边界见 [参数契约](docs/PARAMETERS.md)。

### 一次性诊断

```bash
xtun diagnose
```

`diagnose` 会检查：

- `xray / haproxy / nginx` 服务状态
- `443 / 2443 / 2444 / 8001 / 8443` 监听
- XHTTP H3 是否启用、QUIC（UDP 443）是否监听、`[::]:443` IPv6 监听
- Xray / nginx / haproxy 配置自检
- nginx 的 `worker_connections`（低于阈值会给出建议，不算失败）
- 本地 TLS 握手
- 路由拦截状态
- 证书到期
- WARP 出站配置与 Endpoint 解析（`--warp-probe` 额外探测出口 IP，`--net` 额外检查网络栈）

关键项失败时会以非 0 退出，适合接入外部监控。

### 查看和导出节点

```bash
xtun show-links
xtun show-links --summary
xtun show-links --node 3
xtun show-links --qr --node 3
```

`show-links` 只读取已提交的输出文件；无参数打印全文，`--node N` 直接显示该节点链接和 PNG 位置。`--summary` 显示节点清单与文件位置。`--qr` 直接显示节点名称和 UTF8 二维码，不先输出全文；不能与 `--summary` 同用。编号只能是存在且启用的 1–9。

二维码超过当前终端尺寸时只提示取用已有 PNG；默认尺寸为 80×24。缺 qrencode 时也可取用已有 PNG；编码器和 PNG 都不可用则返回非零。查看不会生成文件或重启服务。

- PNG 目录在 `/root/xtun-qr/`（`0700`），每条节点一张，文件名「位次-节点名.png」（`01-…` 到 `09-…`），随链接一起重新生成
- 取回本地：`scp root@<本机 IP>:/root/xtun-qr/'*.png' .`
- `qrencode` 由安装器安装；补齐丢失的二维码使用 `xtun rebuild-qr --yes`。当前文档与节点定义不一致时会停止，旧安装需先检查并显式执行参数迁移

独立导出示例：

```bash
xtun export-client --node 3 --variant current --format uri --output /root/xtun-clients/node3.uri
xtun export-client --node 3 --variant plain --format json --output /root/xtun-clients/node3.json
xtun export-client --node 3 --variant ech --format png --output /root/xtun-clients/node3-ech.png \
  --ech-config-list https://dns.alidns.com/dns-query
```

`current` 保留当前 ECH 选择；`plain` 省略 ECH，保留原有 VLESS Encryption；`ech` 只作用于节点 3/4/5/7/9 的 CDN TLS 层。未单独指定 ECH 来源时，优先保留已配置值，否则使用 AliDNS 查询真实 CDN 域名；这不表示已验证该域名或客户端网络支持 ECH。

导出文件权限为 `0600`，新建父目录为 `0700`；目标存在时需显式 `--overwrite`。托管文件、符号链接、不支持组合、pending 或代次不一致会阻止导出。JSON 先经当前核心校验，再发布；导出不改 state、不重启服务。节点菜单 `j N` 可导出原生 JSON，适配官方固定镜像的 NAS 启动命令见 [验收手册](docs/TEST-VPS-RUNBOOK.md#43-debian-nas-的-xray-core-docker)。

### 常用变更

```bash
xtun change-sni --reality-sni reality.example.com
xtun change-path --xhttp-path /assets/v3
xtun change-uuid
xtun change-uuid --reality-only
xtun change-uuid --xhttp-only
```

这些命令先展示字段差异、受影响节点、文件、服务动作与连接中断范围，再确认应用。UUID/path 等同值修改不创建备份、不重启服务。自动化脚本可显式添加 `--non-interactive`（或 `--yes`）；安装、恢复和卸载各自的确认参数见 `xtun help`。

应用失败时按同代清单恢复文件、state、节点产物、权限和服务状态；恢复不完整会保留 pending，并提示 `xtun recover`。已提交的操作只补收尾，不反向回滚。日志内容、软件包、系统用户、实时网络参数、内核与外部注册分别保留或报告，不宣称已自动还原。

取值参数支持 `--opt value` 和 `--opt=value` 两种写法，例如 `xtun change-sni --reality-sni=reality.example.com`。无值开关（如 `--no-ipv6`）不接受 `= 值`；缺值、空值和未知项都会在动作开始前失败；方向相反的开关（`--enable-warp` / `--disable-warp`）同时给出会报冲突，不按“最后一个覆盖前一个”处理。敏感值（私钥、Token、profile）仍然只接受 `@文件路径` 或对应环境变量。

### 服务维护

```bash
xtun restart
xtun repair-perms
xtun upgrade
xtun update-script
xtun apply-net-opt
xtun apply-config
xtun version
```

命令说明：

| 命令 | 作用 |
| --- | --- |
| `restart` | 重启 xray、haproxy、nginx |
| `repair-perms` | 修复托管配置、证书、日志权限并尝试重启 |
| `upgrade [--xray-version vX.Y.Z] [--reinstall]` | 校验官方核心/geo 与安装身份，仅应用 Xray 服务 |
| `update-script [--reinstall]` | 更新 `/usr/local/lib/xtun` bundle、安装回执和管理入口，不应用服务 |
| `apply-net-opt` | 重新应用 Joey BBRv3 网络优化和 qdisc/sysctl 配置 |
| `apply-config` | 按当前状态重新生成 xray / haproxy / nginx 托管配置 |
| `version` | 打印脚本版本（也支持 `--version` / `-v`） |

核心、脚本和参数是三个独立维护范围。`update-script` 只换 bundle；`upgrade` 只换核心和配套 geo。让新版模板生效需显式执行 `apply-config`，该步骤会重启 Xray。旧核心迁移到本轮参数基线的顺序为：

```bash
xtun update-script
xtun upgrade --xray-version v26.9.9
xtun apply-config
```

每一步有各自的预览、备份和恢复边界，三步不是一个整体事务。相同且可信的产物为 noop；同版本核心身份未知或字节/权限漂移时，先检查原因，再显式运行 `xtun upgrade --xray-version v26.9.9 --reinstall`。需要重装脚本时使用 `xtun update-script --reinstall`。

`apply-config` 保留既有 UUID、REALITY 密钥、配对 Encryption、路径和已识别的客户端调优，同时重新生成托管配置、state、文档、PNG 与清单。目标核心支持时写出 `users` 和参数修订 `2`；旧核心保留兼容 `clients`。旧安装缺配对凭据或有效用户时停止，不靠重新生成身份补齐。导出到其它位置或已导入客户端的副本不会自动更新；参数或凭据变化后需要重新导出/导入。

默认公开引导将 ref 解析为固定 commit，校验同一 commit 的完整归档和入口。自定义远程包须提供 SHA256；本地包记录本地来源。安装回执用于核对产物，不等同于上游签名。

### 从 1.1.0 升级到 1.1.1 的注意点

**不需要迁移**：state schema 与参数修订都保持在 `2`，节点编号、链接与导出产物不变。这一版是交互修复：主菜单 `3 检查 REALITY SNI` 在没有已保存域名时会直接问域名，不再空转报错；全新安装的基础问答会直接问是否启用 IPv6 双栈（默认关）；主菜单新增 `7 升级脚本`（未安装时是 `5`），等同于 `xtun update-script`，确认后从 GitHub `main` 拉取并安装最新 bundle。

### 从 1.1.0 升级到 1.2.0 的注意点

**不需要迁移**：state schema 与参数修订都保持在 `2`，节点编号、链接与导出产物不变，升级后无需重新导入客户端。行为上有三处变化值得知道：

- **安装前会列出将被接管的路径**：只读检查的「端口与资源归属」多一段「待接管」，列出安装前已存在的 `/etc/systemd/system/xray.service`、`/usr/local/bin/xray` 及运行/资源配置目录；安装摘要也会提示。
- **卸载会还原宿主原来的东西**：这些路径会先登记，卸载时按登记还原（含 unit 的启用/运行状态）。`haproxy`/`nginx` 是否按共享服务保留，看的是**安装前有没有真的在跑**——只是装了包、从未启用的会被停用并清理，不再残留 443/80。
- **`check-sni` 多一项不阻断的观察**：第 13 项「后量子就绪度」在协商到后量子混合组且证书链 >3500 字节时 PASS，其余情况 WARN；不影响退出码，也不阻断安装。

### 从 1.0.x 升级到 1.1.0 的注意点

1.1.0 起不再提供订阅地址与 mihomo yaml：客户端里已添加的 `https://<域名>/sub/<token>/…` 订阅会 404。请删掉客户端里的旧订阅，改用分享链接或扫码重新导入（`xtun show-links` / `/root/xtun-qr/` 里的 PNG）。

- Cloudflare 缓存绕过规则里的 `/sub/` 子句可以删也可以留，不影响任何东西
- 旧的 `/var/www/xtun-sub` 订阅目录会在 `install` / `apply-config` / `uninstall` 的遗留清理里自动删掉
- 客户端不支持的旧字段（如订阅式导入）不再生成；mihomo 用户请改用链接手工导

### 托管配置里的自定义片段

`haproxy.cfg` 和 `/etc/nginx/conf.d/xtun.conf` 在完整配置应用（如 `apply-config`）时按当前状态重新生成；标记之外的手工参数会丢失。同域名续证或更换证书来源只更新证书及相关元数据，不重写这两份配置。

要让手工调优活下来，把它写进生成器留出的标记之间：

```text
    # >>> xtun-user:haproxy-defaults >>>
    timeout client 5m
    # <<< xtun-user:haproxy-defaults <<<
```

三个可用的块：

| 块名 | 位置 | 适合放什么 |
| --- | --- | --- |
| `haproxy-defaults` | `haproxy.cfg` 的 `defaults` 段内 | 超时、`option` 之类的默认值 |
| `haproxy-extra` | `haproxy.cfg` 末尾 | 额外的 frontend / backend / listen |
| `nginx-server` | `xtun.conf` 的 `server` 段内 | 额外的 `location`、`client_max_body_size` 等 |

重写时标记之间的内容会被原样搬到新文件里。标记之外的手工改动仍然会丢。

内置的调优参数（不需要自己加）：

- `timeout tunnel 1h`：握手完成后走的是 tunnel 超时，默认继承 `timeout server 2m` 会把空闲但没断的代理连接掐掉
- `option splice-request` / `option splice-response`：纯 TCP 转发让内核直接 splice
- `option tcp-smart-accept` / `option tcp-smart-connect`：省掉 accept/connect 之后的空 ACK，握手少一个 RTT
- `grpc_read_timeout 1h` / `grpc_send_timeout 1h` / `grpc_buffer_size 64k`：XHTTP 下行是长连接，nginx 默认 60s 读超时会周期性断流
- `upstream xtun_xhttp` + `keepalive 64`：nginx 对上游默认一请求一连接，XHTTP 上行那串短 POST 会让 nginx→xray 这一跳持续新建并关闭连接、堆积 TIME-WAIT；放进 upstream 块复用连接后，同样 40 次请求只新建 1 条

不写 `nbthread`：HAProxy 2.5 起默认按可用 CPU 数开线程，手工钉一个小值只会把线程数改少。

### 变更时的重启与重载

完整配置应用（如 `apply-config`）的服务动作如下；局部变更按操作预览列出的范围执行：

| 服务 | 动作 | 原因 |
| --- | --- | --- |
| `xray` | 重启 | 没有配置热重载，只能重启；会掐断在跑的连接 |
| `haproxy` | 重载 | 先自检配置再给 master 发 `USR2`，老进程继续伺候已建立的连接 |
| `nginx` | 重载 | 收到 `SIGHUP` 会重读配置和证书，老 worker 把在飞的请求做完再退 |

服务当前没在跑时才退回 `restart`。唯一例外是 fd 限额 drop-in 有变化时：`LimitNOFILE` 是进程 rlimit，reload 套不上，这一次会走 `daemon-reload` + `restart nginx`。

同域名 `renew-cert`、`change-cert-mode` 及自动 ACME 部署只 reload nginx，保留 Xray/HAProxy、节点 URI 和 PNG。候选证书先校验密钥、SAN、有效期、用途和信任链，再成对提升；重载后检查本地 TLS 监听实际提供的证书指纹。失败时恢复旧文件并核对旧证书重新供出，恢复不完整则保留 pending。

人工续证和自动 `acme-deploy` 使用同一维护锁。已核对的 acme.sh 3.1.1 可能记录 reload 错误却返回成功，因此人工调用还必须收到本次候选摘要与 nonce 对应的回调确认；不能只凭 acme.sh 的退出码认定已部署。证书来源与结果记录在证书回执和事件文件，公共 ACME 的真实签发/自动续期仍需单独验收。

### nginx 的连接与 fd 限额

发行版打包的 `nginx.service` 一个 `LimitNOFILE` 都没写，worker 拿到的就是 systemd 的默认软限额 1024。而 nginx 在这套架构里是纯反代：一条客户端连接要占两个 fd（下游一个、到 xray 的上游一个）。所以 xtun 会写一个 drop-in 把它对齐到 `xray.service`：

```text
/etc/systemd/system/nginx.service.d/xtun-limits.conf
[Service]
LimitNOFILE=1048576
```

`worker_connections` 只能写在 `/etc/nginx/nginx.conf` 的 `events` 块里。新装默认不接管；明确选择接管或运行 `xtun apply-config --manage-nginx-main` 后，模板写入 `worker_connections 65535` + `multi_accept`。未接管时，`diagnose` 会报告当前值并给出接管或手工调整的建议；旧安装保留已保存的选择。

### 卸载

只删除 xtun 托管文件，不卸载软件包：

```bash
xtun uninstall --yes
```

删除托管文件并尝试卸载主要软件包：

```bash
xtun uninstall --purge --yes
```

`--purge` 按安装归属记录尝试卸载脚本安装的软件包，预先存在或归属不明的共享包保留。ACME 流程移除本节点域名的证书，保留共享 `acme.sh` 本体和其它域名；旧 WARP 等资源按归属处理。结果分别列出删除、保留和未能确认项。

不带 `--yes` 时先回答 `y` 确认卸载；同时指定 `--purge` 时，再输入 `purge` 确认软件包清理。

`haproxy`/`nginx` 是否按共享服务保留，看的是**服务在安装前有没有真的在用**，不是包是谁装的：安装前已经 active 或 enabled 的按共享服务保留运行，还原并 reload 它原来的配置；只是装了包、从没启用的视为 xtun 引入，卸载时停用并清掉 xtun 的配置——否则 443/80 会一直被占着，自己原来的服务起不来。同理，安装前已存在的 `/etc/systemd/system/xray.service`、`/usr/local/bin/xray` 及其运行目录（`/var/log/xray`、`/var/lib/xray`）和资源/配置目录（`/usr/local/share/xray`、`/usr/local/etc/xray`）都会先登记后接管，卸载时按登记还原；这些路径在安装前的只读检查里会以「待接管」列出。

## WARP 出站

`xtun` 的 WARP 不是整机全局代理，也不再依赖 `warp-svc` 守护进程。它把 Cloudflare WARP 配成 Xray 原生的 `wireguard` 出站，只让规则命中的目标域名走 WARP，本地其它流量仍按原规则直连。

相比旧的 WARP Team 模式，现在没有额外守护进程、没有 APT 源、没有机密文件、没有健康巡检 timer、也不占用本地端口。

默认走 WARP 的目标只有 4 条，聚焦在对出口 IP 敏感的 AI 站点：

- `geosite:openai`
- `chatgpt.com`
- `claude.ai`
- `anthropic.com`

其它流量（含 Telegram、Google、YouTube、GitHub）默认直连。想扩就用下面的 `change-warp-rules` 自己加。

### 凭据来源

安装时加 `--enable-warp` 就够了，脚本会自动向 Cloudflare 注册一台免费 WARP 设备（生成 X25519 密钥对 + 一次 API 调用），私钥写进 `node-meta.env`（`0600`）和 `config.json`（`0640 root:xray`），不会出现在输出文件里。

```bash
xtun change-warp --enable-warp
```

机房 IP 常被拒绝注册，或你已经有 WARP+ 账号时，用 `wgcf` 在别处生成 `profile.conf` 再导入：

```bash
xtun change-warp --enable-warp --warp-profile @/root/wgcf-profile.conf
```

也可以手工指定全部字段（私钥只接受 `@文件路径` 或环境变量 `WARP_PRIVATE_KEY`）：

```bash
xtun change-warp --enable-warp \
  --warp-private-key @/root/warp-private-key.txt \
  --warp-address-v4 172.16.0.2 \
  --warp-address-v6 2606:4700:110::2 \
  --warp-reserved 1,2,3
```

| 参数 | 默认值 |
| --- | --- |
| `--warp-peer-public-key` | Cloudflare 公开对端公钥 |
| `--warp-endpoint` | `engage.cloudflareclient.com:2408` |
| `--warp-mtu` | `1420` |
| `--warp-reserved` | 注册时从 `client_id` 推导 |

`wgcf` 的标准 profile 不含 `Reserved`，导入后如需要可用 `--warp-reserved` 补上。

### 开关

```bash
xtun change-warp --disable-warp
xtun change-warp --enable-warp
```

旧版 `warp-svc` / `xtun-warp-health.timer` / MDM XML / APT 源 / keyring 由 `install`、`apply-config`、`uninstall` 的遗留清理统一处理；彻底删包需要自己跑一次：

```bash
apt-get purge -y cloudflare-warp && rm -rf /var/lib/cloudflare-warp
```

### 分流规则

```bash
xtun change-warp-rules --list
xtun change-warp-rules --add-domain chatgpt.com
xtun change-warp-rules --del-domain github.com
xtun change-warp-rules --reset-defaults
```

说明：

- 在交互终端里不带任何修改参数直接跑 `xtun change-warp-rules`（或走菜单 13），只打印当前规则和 CLI 用法，不做任何修改
- 规则和改动前完全一致时直接返回，不会重启服务。分流规则变更要重启 xray/haproxy/nginx，会掐断所有在跑的连接，所以「点进去看一眼」不该付这个代价
- 备份会话也推迟到确认真有变更之后才开，看一眼不会挤掉真正的变更备份
- 改完只打印新规则，不再输出整份部署文档：WARP 出站和分流规则都在服务端侧，客户端链接一个字都不会变
- 裸域名会自动转成 `domain:` 规则
- 也可以直接传 `geosite:xxx`
- 规则写入 `/usr/local/etc/xray/warp-domains.list`
- 更新后会自动重写 Xray 配置并走校验、重启、回滚流程
- 不建议加 `geosite:netflix`，`fast.com` 会被它命中并被判成 Netflix 流量

### 验证出口

`status` 和 `diagnose` 会显示出站模式、内网地址、endpoint 和规则数。想实测出口 IP，用显式探测（临时起一个第二 xray 进程，跑完即退）：

```bash
xtun diagnose --warp-probe
```

## 证书模式

| 模式 | 适合场景 | Cloudflare SSL/TLS |
| --- | --- | --- |
| `self-signed` | 快速测试 | `Full` |
| `existing` | 已有证书，包括 Let's Encrypt 或 Cloudflare Origin CA 证书 | `Full (strict)` |
| `acme-dns-cf` | 用 `acme.sh + Cloudflare DNS API`（DNS-01）自动申请公有证书 | `Full (strict)` |
| `acme-http` | 用 `acme.sh` 的 HTTP-01 自动申请公有证书，**不需要 DNS 令牌** | `Full (strict)` |

`acme-http` 用 80 端口证明域名所有权，因此要求 **域名能解析、且挑战请求能到达本机**；可以是 DNS 直接解析到本机，也可以是 Cloudflare 等代理把 `/.well-known/acme-challenge/` 转发到源站 80。签发与续期时 `acme.sh` 的 standalone 会短暂占用 80，xtun 用 pre/post hook 让 nginx 在挑战窗口内让位（失败路径也会恢复 nginx）。它不需要任何 API 令牌，但 `--acme-email` 是必填：交互问答里留空会当场重问，非交互或草稿缺邮箱会在拿锁前失败，不会等到签发阶段才报错。安装时会在确认前的只读检查里列出 `socat`（HTTP-01 standalone 需要），并在最小依赖准备阶段随其它缺包一起装上；解析到别处（可能是代理）只告警，真失败会回退并如实报告。

已有证书（Cloudflare Origin CA 证书同样走这一模式，可以给文件路径，也可以交互粘贴 PEM）：

```bash
xtun change-cert-mode --cert-mode existing \
  --cert-file /etc/ssl/cloudflare/cert.pem \
  --key-file /etc/ssl/cloudflare/key.pem
```

Cloudflare Origin CA：

```bash
xtun change-cert-mode --non-interactive --cert-mode existing \
  --cert-pem @/root/cf-origin.pem \
  --key-pem @/root/cf-origin.key
```

`acme-dns-cf` 需要：

- `--acme-email`
- `--cf-dns-token`

建议 Cloudflare Token 权限：

- `Zone / DNS / Edit`
- `Zone / Zone / Read`

`acme-http` 只需要：

- `--acme-email`
- 域名（`--xhttp-domain`）已解析到本机

```bash
xtun change-cert-mode --non-interactive --cert-mode acme-http \
  --acme-email you@example.com
```

刷新当前证书：

```bash
xtun renew-cert
```

## Cloudflare 面板配置

请手动确认：

1. `XHTTP CDN` 域名指向 VPS 公网 IP，并打开橙云代理。
2. `Reality` 域名建议灰云 / DNS only。
3. SSL/TLS 模式和证书模式匹配：
   - `self-signed` -> `Full`
   - `existing` / `acme-dns-cf` -> `Full (strict)`
4. 使用 Cloudflare CDN 的 XHTTP 时，建议开启 gRPC。
5. 为 XHTTP 路径创建缓存绕过规则，避免边缘缓存影响连接稳定性。

缓存规则表达式示例：

```text
(http.host eq "cdn.example.com") and (http.request.uri.path contains "/your-xhttp-path")
```

用 `and` 而不是 `or`：同一 zone 里若还有其它子域名，`or` 会让它们只要命中同样的路径
也被一并绕过缓存。表达式已限定为「本域名 且 本路径」，共享 zone 与独立子域名都适用，
也不需要为共享域名另写一套保守规则。

面板路径：

```text
缓存 -> Cache Rules -> 创建缓存规则 -> 自定义筛选表达式 -> Cache eligibility: Bypass cache
```

## XHTTP 高级选项

xpadding 是按配置给 XHTTP 请求/响应加一段随机长度的填充，让包长特征不那么规整；它不改变传输内容，只是可选的抗流量分析手段。ECH 则是在 CDN TLS 层隐藏真实 SNI。

默认策略：

- `XHTTP` 默认不启用 ECH
- 导出的 XHTTP 分享链接默认不带 `ech=`
- `XHTTP` 默认不启用 xpadding
- `XHTTP VLESS Encryption` 默认开启

显式启用 ECH / xpadding：

```bash
bash xtun.sh install --non-interactive \
  ... \
  --enable-xhttp-ech \
  --enable-xhttp-xpadding
```

默认 ECH 配置（用 `--enable-xhttp-ech` 启用时）：客户端自己用 DoH 查询**真实 CDN 域名** HTTPS 记录（type 65）里的 ECHConfig，能跟随 Cloudflare 的密钥轮换：

```text
https://dns.alidns.com/dns-query
```

也可以用 `--xhttp-ech-config-list` 指定显式 DoH 地址、`cloudflare-ech.com+https://…` 共享名组合，或完整的 Base64 ECHConfigList。旧 state 里已有的值原样保留。

默认 xpadding 配置：

```text
Header=Referer, key=x_padding, placement=queryInHeader, method=tokenish
```

交互式安装/高级项里启用 xpadding 时，脚本直接套用上面的默认值，不再逐个提问；要改这些值请用 `--xhttp-xpadding-key` / `--xhttp-xpadding-header` / `--xhttp-xpadding-placement` / `--xhttp-xpadding-method`。

如需禁用 XHTTP VLESS Encryption：

```bash
bash xtun.sh install --non-interactive \
  ... \
  --disable-xhttp-vless-encryption
```

## 网络优化

新装默认关闭网络优化，内核策略为 `none`。启用后先在**当前内核**上应用 BBR + fq、sysctl/qdisc 与 systemd helper——不换内核也已经生效；只有另外选择 `joey`，才会额外按架构安装第三方项目 `byJoey/Actions-bbr-v3` 的 Joey BBRv3 内核包：

- `x86_64 / amd64` 使用上游 `x86_64-*` release
- `aarch64 / arm64` 使用上游 `arm64-*` release
- 下载的 deb 会按 GitHub Release API 的 SHA256 digest 校验
- 脚本不会直接执行上游的交互式 `install.sh`；只使用其 GitHub Release 中发布的内核 deb 资源
- 安装内核后不会自动重启；需要手动重启 VPS 后才会加载 BBRv3

执行时机：

- 交互式安装在确认页输入 `advanced` 后进入网络优化选项；新装默认 `n`，基础安装不额外询问
- 非交互安装时传入 `--enable-net-opt` 会自动执行；传入 `--disable-net-opt` 会跳过
- 高级项启用网络优化后可选择 Joey 内核，新装默认 `n` / `none`；`--bbr-kernel none` 只写 sysctl / helper / service，明确选择 `--bbr-kernel joey` 才安装第三方内核
- 重建或恢复草稿保留已保存的网络优化/内核选择；新默认不会覆盖旧选择
- 已安装过旧版网络优化的机器，更新脚本后可直接运行 `xtun apply-net-opt` 重新应用；`--bbr-kernel joey|none` 可切换内核策略并写回状态
- 当前网络优化只面向 Debian / Ubuntu 系，并要求当前机器架构能匹配上面的 `amd64` 或 `arm64`
- 如果当前已经运行 Joey BBRv3，脚本只会刷新 sysctl、helper 和 systemd 服务，不会重复安装内核

旧机器升级网络优化的推荐步骤：

```bash
xtun update-script
xtun apply-net-opt
```

如果命令提示已安装 Joey BBRv3 内核并需要重启，执行 `reboot` 后再用 `xtun status` 或 `modinfo tcp_bbr` 确认。

随后脚本会写入并应用：

- `tcp_congestion_control`：内核暴露 `bbr1` 就用 `bbr1`，否则用 `bbr`
- `default_qdisc = fq`
- `tcp_mem` 按 `MemTotal` 的 1/8、1/6、1/4 三档给（内存小于 256MB 时跳过，交给内核自己估）
- 加大的 `rmem / wmem / optmem / somaxconn / tcp_rmem / tcp_wmem / udp_rmem_min / udp_wmem_min`
- `netdev_max_backlog / netdev_budget / netdev_budget_usecs`、`tcp_no_metrics_save = 1`
- `tcp_fastopen / tcp_mtu_probing / tcp_slow_start_after_idle / tcp_keepalive_*`
- `tcp_tw_reuse = 1`（内核默认的 `2` 只对 loopback 生效，而代理机烧本地端口的是出网那一侧）
- `tcp_fin_timeout = 15`（默认 60s 的 FIN-WAIT-2 对建了就拆的代理连接太长）
- `tcp_notsent_lowat = 131072`（未发送数据超过 128KB 就不再往 socket 缓冲里塞，h2 多路复用下的小流不用排在大流后面）
- `fs.file-max` 按 `MemTotal` 的 1/4 给、封顶 200 万，兜住 `xray.service` 里的 `LimitNOFILE=1048576`；内存撑不到就不写，交给内核自己估
- systemd oneshot 开机后重新应用 qdisc（`fq limit 100000 flow_limit 1000`）、`RPS`、`XPS`，并把出网网卡和默认路由的 MTU 夹到 1500

如果当前内核还不是 Joey BBRv3，但对应内核包已经安装，脚本会保留配置并提示重启；重启后再运行 `xtun status` 或 `modinfo tcp_bbr` 可确认生效。

关于 MTU：部分云厂商的 DHCP 会下发巨帧 MTU（例如 Oracle VCN 给 9000）。对一台流量全走公网的代理机来说这只有坏处——每条新连接从 `advmss 8960` 起步，先白吃一轮 PMTU 探测才退回 1500 附近。helper 只往下夹、不往上抬：链路或默认路由的 MTU 大于 1500 才改，PPPoE / 隧道那种 1492、1450 的链路原样保留。

网络栈体检：

```bash
xtun diagnose --net
```

输出内核版本、拥塞控制与可用算法、`tcp_bbr` 模块版本、默认/网卡 qdisc、MTU、`tcp_notsent_lowat`、`fs.file-max`、nginx 的 `worker_connections / worker_rlimit_nofile` 与 master 进程的 `LimitNOFILE`、haproxy `maxconn`，以及 `ss -tin` 统计的已建立连接拥塞算法分布。拥塞控制不在 bbr 系时计入失败。`xtun status` 面板也有一行「拥塞控制 / qdisc」。

### nginx 主配置接管

`worker_connections` / `worker_rlimit_nofile` 只能写在 `/etc/nginx/nginx.conf`。新装默认不接管；可在 `advanced` 中明确选择，或使用 `--manage-nginx-main`。旧安装保留已保存的选择，没有接管记录时不因升级自动接管。已安装节点需要开启时运行：

```bash
xtun apply-config --manage-nginx-main
```

接管模板：`worker_rlimit_nofile 1048576`、`worker_connections 65535` + `multi_accept`，并保留两个用户块（`xtun-user:nginx-main` / `xtun-user:nginx-http`），手工调优写在标记之间就能活过每次重写。首次接管前会把 `/etc/nginx/nginx.conf` 的原件存到 `/var/lib/xtun/originals/`（不与可轮转的事务备份混放）。

卸载或 `xtun apply-config --no-manage-nginx-main` 时按「首次原件 → 旧备份里最早的一份 → 保留当前文件并报告」的顺序处理；**找不到可信原件时不会写回发行版默认模板**，而是保留当前文件并在报告里列为「未能确认」。想停止接管又确认过当前文件可以丢弃时，也可以自己先备份再手工替换。Ubuntu 24.04 的 nginx 1.24 不认独立的 `http2 on;` 指令，脚本会自动退回 `listen ... ssl http2;` 老语法。

相关文件：

- `/etc/sysctl.d/98-xtun-net.conf`
- `/usr/local/sbin/xtun-net-optimize.sh`
- `xtun-net-optimize.service`

`/etc/sysctl.d/` 按文件名排序加载，后加载的盖掉先加载的。手写一个 `99-*.conf` 会压住 `98-xtun-net.conf` 里的同名键：改了 xtun 模板却不见效，多半就是这个原因。最终值以 `sysctl -n <键>` 为准，别只看文件。

第三方来源：

- Joey BBRv3 内核包来自 `byJoey/Actions-bbr-v3`
- 项目地址：https://github.com/byJoey/Actions-bbr-v3
- 上游 LICENSE 标注为 MIT；本脚本仅在安装时引用其 release 产物，请以该上游仓库的最新说明为准

和直接运行 `byJoey/Actions-bbr-v3` 的差别：

- `xtun` 只引用上游 release 产物，不执行上游交互式安装脚本。
- `xtun` 会把网络优化接入自身的备份、日志、状态面板和 systemd helper。
- `xtun` 安装内核后不会自动重启；需要你确认窗口后手动重启 VPS。

## 故障处理

### 有未完成操作时恢复

`status`、`diagnose` 只报告未完成操作；新的修改会被阻止。先处理报告中的失败原因，再运行：

```bash
xtun recover
xtun recover --yes    # 已明确决定按清单恢复时
```

若安装尚未写入管理命令，使用同一候选目录的 `bash xtun.sh recover`。恢复会核对保存的文件和服务状态；已提交但收尾中断的操作只补清理。恢复成功不代表原修改成功，需要重新发起原任务。清单损坏或恢复失败时保留现场，不手工删除 pending 绕过检查。

恢复不会卸载已安装的软件包、删除新增系统用户或清空运行日志。实时 sysctl、qdisc、RPS/XPS、内核与外部注册须单独核对，不能仅凭文件恢复就认定已还原。

### 交互安装失败后继续

交互安装时，脚本会把已确认过的选择保存到：

```bash
/root/.xtun-install-draft.env
```

草稿带 schema、任务类型、来源和更新时间，权限 `0600`。外部证书/WARP 等敏感输入沿用间接引用（例如 `@/path`）；安装生成的身份和密钥保存在私有草稿中，以便重试时保持一致。

如果中途在依赖准备、下载、证书、WARP 或配置校验阶段失败，先按提示处理未完成操作；确认恢复完成后再次执行并选择任务：

```bash
bash xtun.sh            # 菜单里选「1. 安装 / 恢复草稿 / 重建」
bash xtun.sh install --task resume --non-interactive   # 非交互恢复
```

恢复沿用草稿里的身份与选择；想丢掉草稿从零开始，菜单里选「丢弃草稿并重新安装」，
或 `xtun.sh install --task fresh --discard-draft`。安装成功后 draft 文件会自动删除。

节点资料 `/root/xtun-output.md` 和 PNG 为 `0600`，PNG 目录为 `0700`。失败结果会说明停在哪个安装阶段、哪些软件包保留，以及草稿和文件/服务是否已恢复。

### Xray 或 443 不正常

先跑：

```bash
xtun repair-perms
xtun status
xtun diagnose
```

如果刚做过 `install`、`change-*`、`upgrade`，查看终端最后几条 `[步骤]`、`[完成]`、`[警告]` 输出。脚本会尽量标明失败发生在下载校验、配置校验、服务重启还是回滚阶段。

### Cloudflare 521 / 525

按顺序检查：

1. `xray` 是否运行
2. `haproxy` 是否运行
3. `nginx` 是否运行
4. `xray` 是否监听 `2443` 和 `8001`
5. `nginx` 是否监听 `127.0.0.1:8443`
6. `haproxy` 是否监听 `:443`
7. Cloudflare SSL/TLS 模式是否正确
8. 证书是否覆盖 CDN 域名
9. XHTTP 路径是否被 Cloudflare 缓存规则绕过

### Reality 地址用 IP 还是域名

默认导出的 Reality 节点地址是公网 IP，`serverName/SNI` 使用你设置的 Reality 域名。

- 稳定优先：客户端地址用公网 IP
- 维护优先：客户端地址用灰云域名

## 开发与测试

本仓库是 shell 项目（`bash` + `shellcheck`）。基础回归：

```bash
bash tests/smoke.sh          # 270 组；沙箱化，可在已部署机器上以 root 跑
```

其余套件按需要单独跑（多数要求 root，部分要求真实 systemd；命令与前置条件见[测试与三端手册](docs/TEST-VPS-RUNBOOK.md)）：

```bash
bash tests/install-smoke.sh container       # 容器内全新安装冒烟（CI 同款，需要 docker）
python3 tests/install-boundary.py           # 安装入口 PTY 边界
python3 tests/task-menu-boundary.py         # 任务菜单 PTY 边界
python3 tests/native-transport.py           # 原生双向传输与负例
bash tests/migration.sh                     # 历史版本组合迁移
XTUN_TEST_ISOLATED_VPS=yes bash tests/systemd-recovery.sh
XTUN_TEST_ISOLATED_VPS=yes bash tests/filesystem-recovery.sh
XTUN_TEST_ISOLATED_VPS=yes bash tests/ownership-systemd.sh
bash tests/deployment-recovery.sh upgrade   # 会替换本机安装内容，仅限可重建环境
```

用例会把所有托管路径改写到临时沙箱（`tests/common.sh` 的 `sandbox_managed_paths`），所以即使在已部署的机器上以 root 跑测试，也不会碰到真实的 `/usr/local/etc/xray`、`/etc/haproxy` 等文件。`tests/smoke.sh` 结尾还有一层守卫，真实托管文件一旦消失就直接让测试失败。

仓库入口：`xtun.sh`、`lib/`、`tests/`、`static/fallback/`；CI 配置见 [.github/workflows/ci.yml](.github/workflows/ci.yml)——ShellCheck + 270 组 smoke、Debian 12/13 与 Ubuntu 24.04 的 systemd 容器安装矩阵、官方客户端容器、latest 发现与语义/传输任务。

## 参考

- Xray `wireguard` 出站配置文档  
  https://xtls.github.io/config/outbounds/wireguard.html
- `wgcf`（生成 WARP WireGuard profile）  
  https://github.com/ViRb3/wgcf
- Xray 官方讨论 `#4118`  
  https://github.com/XTLS/Xray-core/discussions/4118
- Xray 官方仓库  
  https://github.com/XTLS/Xray-core
