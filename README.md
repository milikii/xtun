# xtun

`xtun` 是一个面向 Debian / Ubuntu VPS 的一键部署与维护脚本。它把 `xray`、`haproxy`、`nginx`、Cloudflare CDN、可选 WARP 出站、证书和网络优化组合成一套可重复安装、可回滚、可维护的代理节点栈。

当前版本：`1.1.0`

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
- 现有证书（含 Cloudflare Origin CA）、自签证书、`acme.sh + Cloudflare DNS` 证书模式
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
- 不希望脚本安装第三方 Joey BBRv3 内核包的场景

## 快速开始

在 VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/milikii/xtun/main/xtun.sh -o xtun.sh
bash xtun.sh
```

不带参数时会进入菜单。第一次安装通常选择：

```text
1. 安装或重装
```

安装完成后会生成管理命令：

```bash
xtun
```

### Xray 核心版本策略

新安装和 `xtun upgrade` 默认解析 Xray-core 最新已发布版本，包含 pre-release；单次操作会固定 tag、tag 指向的提交、资产 URL 和 SHA256。需要复现指定版本时使用：

```bash
xtun upgrade --xray-version vX.Y.Z
```

CI 当前用 `v26.9.9` 作为可复现基线；`latest-check` 工作流单独验证默认追新路径。

后续维护都可以直接运行 `xtun`，不用再进入仓库目录。

菜单顶部只画一块精简面板（服务状态、监听 443、WARP 开关），不跑配置自检和 TLS 握手，所以翻菜单不会卡。需要完整体检时走菜单 `4`、`xtun status` 或 `xtun diagnose`。

停在菜单提示符上不会占住脚本锁，另一个终端里的 `xtun` 仍然可以正常执行变更；锁只在具体的写命令执行期间持有。

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
| - | XHTTP-TLS-H3 / XHTTP-SPLIT-CDN-H3（H3 可用时） | H3 直连下行 |

### 命令表

| 命令 | 作用 |
| --- | --- |
| `install [参数]` | 安装或重装 |
| `update-script` | 更新脚本本体 |
| `upgrade [--xray-version vX.Y.Z]` | 升级 Xray 核心；默认追踪最新已发布版本 |
| `check-sni [域名]` | Reality 目标域名 12 项预检 |
| `change-uuid` / `change-sni` / `change-path` | 轮换 UUID / 改 SNI（含预检）/ 改路径 |
| `change-warp` / `change-warp-rules` | WARP 开关 / 分流规则 |
| `change-cert-mode` / `renew-cert` | 换证书模式 / 续期证书 |
| `show-links [--qr]` | 查看节点链接；`--qr` 追加每条链接的终端二维码 |
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
| `/usr/local/etc/xray/config.json` | Xray 配置 |
| `/etc/nginx/conf.d/xtun.conf` | nginx 托管配置 |
| `/etc/nginx/nginx.conf` | 仅 `--manage-nginx-main` 接管时由 xtun 整体重写 |
| `/etc/systemd/system/nginx.service.d/xtun-limits.conf` | nginx 的 fd 限额 drop-in |
| `/etc/haproxy/haproxy.cfg` | haproxy 托管配置 |
| `/etc/systemd/system/xray.service` | Xray systemd unit |
| `/usr/local/etc/xray/node-meta.env` | xtun 状态文件 |
| `/root/xtun-output.md` | 人类可读节点输出（节点 1–9 + 二维码段） |
| `/root/xtun-qr/` | 节点二维码 PNG（每条节点一张，随链接重建） |
| `/root/xtun-backups/` | 变更备份目录 |
| `/var/log/xtun/operations.log` | 全局操作日志 |
| `/var/www/xtun-fallback` | 本地静态伪装站 |

## 日常命令

### 查看状态

```bash
xtun status
```

状态面板会显示服务状态、监听端口、证书到期时间、WARP 出站模式、WARP 规则数量和最近备份。

查看原始 systemd 输出：

```bash
xtun status --raw
```

### 路由拦截

出站路由固定带两条卫生规则：`geoip:private` 与 `geosite:private` 一律 blackhole，防止来自代理的流量访问内网/回环地址。回国流量（`geoip:cn` / `geosite:cn`）默认不拦截，安装时加 `--block-cn` 或交互里选择开启即可；已装节点改状态文件里的 `ROUTE_BLOCK_CN` 后跑 `xtun apply-config` 生效。

`xtun diagnose` 会报当前拦截状态（`private` / `private+cn`）。

### IPv6 双栈

安装时脚本会探测本机全局单播 IPv6（`ip -6 route get 2606:4700:4700::1111`，只认 `2000::/3`），问到「REALITY 直连节点 IPv6」时直接给默认值；留空（或 `--no-ipv6`）跳过。

有 IPv6 时：

- haproxy 监听改为 `bind :::443 v4v6`（无 IPv6 的机器同样合法，IPv4 走 mapped 地址）
- 追加两条链接：`REALITY-V6`（节点 1 的 IPv6 版）与 `XHTTP-SPLIT-CDN-REALITY-V6`（节点 4 的 IPv6 下行）
- `xtun status` 面板与 `xtun diagnose` 会显示 IPv6 状态

也可以显式指定：`--server-ip6 2408:8120::xxx`。

### XHTTP H3 直连下行

满足以下两个条件时自动启用（`xtun status` 面板可见）：

1. nginx 编译含 `http_v3` 模块（Debian 13 的 1.26 自带；Debian 12 / Ubuntu 24.04 需 nginx.org 官方源）
2. 证书模式为 `existing` / `acme-dns-cf`（客户端要能校验证书，自签名不行）

任一不满足时整段功能自动关闭，`xtun diagnose` 会给出原因。

启用后：nginx 直接在公网 UDP 443 监听 QUIC（`listen 443 quic reuseport`，有 IPv6 再加 `[::]:443`），TLS 在 nginx 终结，并下发 `Alt-Svc: h3=":443"`。链接追加 `XHTTP-TLS-H3`（H3 直连）与 `XHTTP-SPLIT-CDN-H3`（上行 CDN h2、下行 H3 直连），这两条对应输出文件的节点 8 / 9。防火墙需放行 UDP 443；`xtun diagnose` 会探测 QUIC 监听并在缺失时报出。

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
xtun show-links --qr
```

`show-links` 属于查看类命令：只读打印输出文件，不重写任何托管文件。加 `--qr` 在末尾逐条打印每个分享链接的终端二维码（ANSI，按节点名标注）。

上下行分离节点的链接有 1100–1700 字符，终端里画出来是 137×137 个字符块，手机对着终端扫成功率很低——这几条建议改用 PNG：

- PNG 目录在 `/root/xtun-qr/`（`0700`），每条节点一张，文件名「位次-节点名.png」（`01-…` 到 `09-…`），随链接一起重新生成
- 取回本地：`scp root@<本机 IP>:/root/xtun-qr/'*.png' .`
- `qrencode` 由安装器安装；已装节点缺它时 `apt-get install -y qrencode && xtun apply-config` 即可补齐 PNG

### 常用变更

```bash
xtun change-sni --reality-sni reality.example.com
xtun change-path --xhttp-path /assets/v3
xtun change-uuid
xtun change-uuid --reality-only
xtun change-uuid --xhttp-only
```

这些 `change-*` 命令会走现有校验、重启、回滚流程。应用失败时会回滚最近一次托管变更。

回滚只还原托管的配置文件。`/var/log/xtun` 下的操作日志不进回滚清单——它本来就不进备份，排障时恰恰要看这份现场记录。

参数支持 `--opt value` 和 `--opt=value` 两种写法，例如 `xtun change-sni --reality-sni=reality.example.com`。

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
| `upgrade [--xray-version vX.Y.Z]` | 升级 Xray core，校验发布 API / `.dgst` SHA256 |
| `update-script` | 更新 `/usr/local/lib/xtun` bundle 和 `/usr/local/sbin/xtun` wrapper |
| `apply-net-opt` | 重新应用 Joey BBRv3 网络优化和 qdisc/sysctl 配置 |
| `apply-config` | 按当前状态重新生成 xray / haproxy / nginx 托管配置 |
| `version` | 打印脚本版本（也支持 `--version` / `-v`） |

`update-script` 只换脚本 bundle，不会碰已经落盘的托管配置。所以升级脚本后想让新版模板里的参数生效，还要再跑一次：

```bash
xtun update-script
xtun apply-config
```

`apply-config` 走和 `change-*` 一样的备份、校验、重启、回滚流程，但不改节点参数，所以不会重刷部署文档。

### 从 1.0.x 升级到 1.1.0 的注意点

1.1.0 起不再提供订阅地址与 mihomo yaml：客户端里已添加的 `https://<域名>/sub/<token>/…` 订阅会 404。请删掉客户端里的旧订阅，改用分享链接或扫码重新导入（`xtun show-links` / `/root/xtun-qr/` 里的 PNG）。

- Cloudflare 缓存绕过规则里的 `/sub/` 子句可以删也可以留，不影响任何东西
- 旧的 `/var/www/xtun-sub` 订阅目录会在 `install` / `apply-config` / `uninstall` 的遗留清理里自动删掉
- 客户端不支持的旧字段（如订阅式导入）不再生成；mihomo 用户请改用链接手工导

### 托管配置里的自定义片段

`haproxy.cfg` 和 `/etc/nginx/conf.d/xtun.conf` 是整份重写的：每次 `change-*`、`apply-config`，以及自动跑的 `renew-cert`，都会按当前状态重新生成一遍。直接手工加的参数会被无声抹掉。

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

`change-*`、`apply-config`、`renew-cert` 应用完新配置后：

| 服务 | 动作 | 原因 |
| --- | --- | --- |
| `xray` | 重启 | 没有配置热重载，只能重启；会掐断在跑的连接 |
| `haproxy` | 重载 | 先自检配置再给 master 发 `USR2`，老进程继续伺候已建立的连接 |
| `nginx` | 重载 | 收到 `SIGHUP` 会重读配置和证书，老 worker 把在飞的请求做完再退 |

服务当前没在跑时才退回 `restart`。唯一例外是 fd 限额 drop-in 有变化时：`LimitNOFILE` 是进程 rlimit，reload 套不上，这一次会走 `daemon-reload` + `restart nginx`。

`renew-cert` 装给 acme.sh 的续期钩子只 `reload nginx`，不碰 xray——这张证书只有 nginx 在用（Reality 有自己的密钥对，XHTTP 入站是挂在 nginx 后面的明文 h2c），重启 xray 只会把所有在跑的 Reality 会话白白掐断一次。钩子里的失败也不吞：acme.sh 会把 `reloadcmd` 的非 0 退出记成续期失败，「证书换了但没生效」正是该被看见的那一类失败。

### nginx 的连接与 fd 限额

发行版打包的 `nginx.service` 一个 `LimitNOFILE` 都没写，worker 拿到的就是 systemd 的默认软限额 1024。而 nginx 在这套架构里是纯反代：一条客户端连接要占两个 fd（下游一个、到 xray 的上游一个）。所以 xtun 会写一个 drop-in 把它对齐到 `xray.service`：

```text
/etc/systemd/system/nginx.service.d/xtun-limits.conf
[Service]
LimitNOFILE=1048576
```

`worker_connections` 只能写在 `/etc/nginx/nginx.conf` 的 `events` 块里。xtun 接管主配置时（新装默认接管，`apply-config --manage-nginx-main` 可补开）直接写 `worker_connections 65535` + `multi_accept`；未接管的旧节点，`diagnose` 会报当前值并提示运行 `apply-config --manage-nginx-main` 由 xtun 接管，或手工在 `events` 块里调大。

### 卸载

只删除 xtun 托管文件，不卸载软件包：

```bash
xtun uninstall --yes
```

删除托管文件并尝试卸载主要软件包：

```bash
xtun uninstall --purge --yes
```

`--purge` 会尝试卸载 `haproxy`、`nginx`、`jq`、`uuid-runtime`、`qrencode`，并清理 `/root/.acme.sh`、`/var/log/xtun` 等路径。旧版本装过 `cloudflare-warp`、带过核心巡检 timer，或用过 1.0.0 的 `/var/www/xtun-sub` 订阅目录的机器，卸载时会一并清掉遗留的 APT 源、keyring、`/var/lib/cloudflare-warp`、巡检单元和订阅目录。

不带 `--yes` 时会要求二次确认：先回答 `y` 确认停止服务并删除托管文件，再输入 `purge` 才会同时卸载软件包。`--purge` / `--yes` 语义不变。

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
| `acme-dns-cf` | 用 `acme.sh + Cloudflare DNS API` 自动申请公有证书 | `Full (strict)` |

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
(http.host eq "cdn.example.com") or (http.request.uri.path contains "/your-xhttp-path")
```

面板路径：

```text
缓存 -> Cache Rules -> 创建缓存规则 -> 自定义筛选表达式 -> Cache eligibility: Bypass cache
```

## XHTTP 高级选项

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

默认 ECH 配置：

```text
cloudflare-ech.com+https://223.5.5.5/dns-query
```

默认 xpadding 配置：

```text
Header=Referer, key=x_padding, placement=queryInHeader, method=tokenish
```

如需禁用 XHTTP VLESS Encryption：

```bash
bash xtun.sh install --non-interactive \
  ... \
  --disable-xhttp-vless-encryption
```

## 网络优化

如果启用网络优化，脚本会先按当前架构集成第三方项目 `byJoey/Actions-bbr-v3` 提供的 Joey BBRv3 内核包：

- `x86_64 / amd64` 使用上游 `x86_64-*` release
- `aarch64 / arm64` 使用上游 `arm64-*` release
- 下载的 deb 会按 GitHub Release API 的 SHA256 digest 校验
- 脚本不会直接执行上游的交互式 `install.sh`；只使用其 GitHub Release 中发布的内核 deb 资源
- 安装内核后不会自动重启；需要手动重启 VPS 后才会加载 BBRv3

执行时机：

- 交互式安装时会询问“是否启用网络优化”，默认是 `y`
- 非交互安装时传入 `--enable-net-opt` 会自动执行；传入 `--disable-net-opt` 会跳过
- 启用网络优化后还会问一次“是否安装 Joey BBRv3 第三方内核”，默认 `y`；不想装第三方内核用 `--bbr-kernel none`（只写 sysctl / helper / service，不改内核）
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

`worker_connections` / `worker_rlimit_nofile` 只能写在 `/etc/nginx/nginx.conf`。新装默认接管（交互问一次，默认 `y`；`--no-manage-nginx-main` 可关闭）。从旧版本升级的节点默认不接管，确认后用下面命令开启：

```bash
xtun apply-config --manage-nginx-main
```

接管模板：`worker_rlimit_nofile 1048576`、`worker_connections 65535` + `multi_accept`，并保留两个用户块（`xtun-user:nginx-main` / `xtun-user:nginx-http`），手工调优写在标记之间就能活过每次重写。卸载时若备份目录里有接管前的 `nginx.conf` 会自动还原，否则写回发行版默认模板。Ubuntu 24.04 的 nginx 1.24 不认独立的 `http2 on;` 指令，脚本会自动退回 `listen ... ssl http2;` 老语法。

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

### 交互安装失败后继续

交互安装时，脚本会把已填写的值保存到：

```bash
/root/.xtun-install-draft.env
```

如果中途在预检、下载、证书、WARP 或配置校验阶段失败，再次执行：

```bash
bash xtun.sh
```

脚本会带回上次已填写的值。安装成功后 draft 文件会自动删除。

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

本仓库是 shell 项目，基础回归测试：

```bash
bash tests/smoke.sh
```

用例会把所有托管路径改写到临时沙箱（`tests/common.sh` 的 `sandbox_managed_paths`），所以即使在已部署的机器上以 root 跑测试，也不会碰到真实的 `/usr/local/etc/xray`、`/etc/haproxy` 等文件。`tests/smoke.sh` 结尾还有一层守卫，真实托管文件一旦消失就直接让测试失败。

仓库入口：

- `xtun.sh`
- `lib/`
- `tests/`
- `static/fallback/`

## 参考

- Xray `wireguard` 出站配置文档  
  https://xtls.github.io/config/outbounds/wireguard.html
- `wgcf`（生成 WARP WireGuard profile）  
  https://github.com/ViRb3/wgcf
- Xray 官方讨论 `#4118`  
  https://github.com/XTLS/Xray-core/discussions/4118
- Xray 官方仓库  
  https://github.com/XTLS/Xray-core
