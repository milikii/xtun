# xtun

`xtun` 是一个面向 Debian / Ubuntu VPS 的一键部署与维护脚本。它把 `xray`、`haproxy`、`nginx`、Cloudflare CDN、可选 WARP 出站、证书和网络优化组合成一套可重复安装、可回滚、可维护的代理节点栈。

当前版本：`0.11.6`

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
- `Cloudflare Origin CA`、已有证书、自签证书、`acme.sh + Cloudflare DNS` 证书模式
- 多客户端独立 UUID 导出
- `Joey BBRv3 + qdisc + RPS/XPS` 网络优化
- 安装、变更、升级、卸载过程中的备份、校验、回滚和操作日志

## 适用场景

适合：

- 一台 Debian / Ubuntu VPS 同时提供 Reality、XHTTP CDN 和 XHTTP split 节点
- 希望 Cloudflare CDN 只承载 XHTTP，Reality 走直连或灰云域名
- 需要让部分目标域名走 Cloudflare WARP，其它流量保持直连
- 需要后续通过 `xtun` 修改 SNI、路径、UUID、证书、WARP 和客户端导出

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

后续维护都可以直接运行 `xtun`，不用再进入仓库目录。

菜单顶部只画一块精简面板（服务状态、监听 443、WARP 开关、稳定性信号），不跑配置自检和 TLS 握手，所以翻菜单不会卡。需要完整体检时走菜单 `4`、`xtun status` 或 `xtun diagnose`。

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
xtun change-cert-mode --cert-mode cf-origin-ca --cert-pem @/root/cf-origin.pem --key-pem @/root/cf-origin.key
```

## 架构说明

`xtun` 使用混合前置架构：

```text
公网 :443
  |
  v
haproxy
  |-- SNI = XHTTP CDN 域名 --> nginx 127.0.0.1:8443 --> xray 127.0.0.1:8001
  `-- 其它 SNI -------------> xray 127.0.0.1:2443
```

组件职责：

| 组件 | 监听 | 作用 |
| --- | --- | --- |
| `haproxy` | `:443` | 按 SNI 做 TCP 分流 |
| `nginx` | `127.0.0.1:8443` | 给 CDN 域名提供 TLS/HTTP2，并把 XHTTP 路径转发给 Xray |
| `xray` Reality | `127.0.0.1:2443` | `VLESS + REALITY + Vision` |
| `xray` XHTTP | `127.0.0.1:8001` | `VLESS + XHTTP`，默认开启 VLESS Encryption |
| 本地静态站 | `/var/www/xtun-fallback` | nginx 根路径伪装站 |

Reality、XHTTP CDN、XHTTP split 共享同一个 `443`。split 节点不增加额外服务端入站，而是由客户端 `downloadSettings` 控制上下行链路。

## 安装会写入哪些文件

主要路径：

| 路径 | 说明 |
| --- | --- |
| `/usr/local/sbin/xtun` | 安装后的管理命令 |
| `/usr/local/lib/xtun` | 脚本 bundle |
| `/usr/local/etc/xray/config.json` | Xray 配置 |
| `/etc/nginx/conf.d/xtun.conf` | nginx 托管配置 |
| `/etc/systemd/system/nginx.service.d/xtun-limits.conf` | nginx 的 fd 限额 drop-in |
| `/etc/haproxy/haproxy.cfg` | haproxy 托管配置 |
| `/etc/systemd/system/xray.service` | Xray systemd unit |
| `/usr/local/etc/xray/node-meta.env` | xtun 状态文件 |
| `/root/xtun-output.md` | 当前客户端的人类可读节点输出 |
| `/root/xtun-subscriptions/vless-raw.txt` | Raw VLESS 订阅 |
| `/root/xtun-subscriptions/vless-base64.txt` | Base64 VLESS 订阅 |
| `/root/xtun-subscriptions/manifest.txt` | 订阅文件清单 |
| `/root/xtun-subscriptions/qr/` | 可选二维码 PNG |
| `/root/xtun-backups/` | 变更备份目录 |
| `/var/log/xtun/operations.log` | 全局操作日志 |
| `/var/www/xtun-fallback` | 本地静态伪装站 |

如果系统里有 `qrencode`，脚本会生成订阅二维码 PNG；没有时只跳过二维码，不影响安装。

## 日常命令

### 查看状态

```bash
xtun status
```

状态面板会显示服务状态、监听端口、证书到期时间、WARP 出站模式、WARP 规则数量、最近备份、自恢复状态和稳定性信号。

查看原始 systemd 输出：

```bash
xtun status --raw
```

### 一次性诊断

```bash
xtun diagnose
```

`diagnose` 会检查：

- `xray / haproxy / nginx` 状态
- `443 / 2443 / 8001 / 8443` 监听
- Xray/nginx/haproxy 配置自检
- nginx 的 `worker_connections`（低于 4096 会给出提示，但不算失败）
- 本地 TLS 握手
- WARP 出站配置与 Endpoint 解析
- 最近核心自恢复记录

关键项失败时会以非 0 退出，适合接入外部监控。

### 查看和导出节点

```bash
xtun show-links
xtun show-links --qr
```

多客户端场景下，指定客户端：

```bash
xtun show-links --client phone
```

`show-links` 属于查看类命令：不加 `--client` 时只读输出文件，加了 `--client` 也只是按当前状态重新生成输出与订阅文件（写入是原子的），不会新开备份会话去挤掉真正的变更备份。

### 多客户端

默认安装会保留一组 `default` 客户端。新增客户端会复用服务端配置，但生成独立的 Reality UUID 和 XHTTP UUID。

```bash
xtun add-client phone
xtun list-clients
xtun show-links --client phone
```

指定 UUID：

```bash
xtun add-client phone \
  --reality-uuid 33333333-3333-3333-3333-333333333333 \
  --xhttp-uuid 44444444-4444-4444-4444-444444444444
```

### 常用变更

```bash
xtun change-sni --reality-sni reality.example.com
xtun change-path --xhttp-path /assets/v3
xtun change-label-prefix --node-label-prefix HKG
xtun change-uuid
xtun change-uuid --reality-only
xtun change-uuid --xhttp-only
```

这些 `change-*` 命令会走现有校验、重启、回滚流程。应用失败时会回滚最近一次托管变更。

回滚只还原托管的配置文件。健康状态、自恢复历史和 `/var/log/xtun` 下的操作日志不进回滚清单——它们本来就不进备份，排障时恰恰要看这份现场记录。

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
| `upgrade` | 升级 Xray core，并校验 `.dgst` SHA256 |
| `update-script` | 更新 `/usr/local/lib/xtun` bundle 和 `/usr/local/sbin/xtun` wrapper |
| `apply-net-opt` | 重新应用 Joey BBRv3 网络优化和 qdisc/sysctl 配置 |
| `apply-config` | 按当前状态重新生成 xray / haproxy / nginx 托管配置 |
| `version` | 打印脚本版本（也支持 `--version` / `-v`） |

`update-script` 只换脚本 bundle，不会碰已经落盘的托管配置。所以升级脚本后想让新版模板里的参数生效，还要再跑一次：

```bash
xtun update-script
xtun apply-config
```

`apply-config` 走和 `change-*` 一样的备份、校验、重启、回滚流程，但不改任何客户端参数，所以不会重刷部署文档。

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

`worker_connections` 只能写在 `/etc/nginx/nginx.conf` 的 `events` 块里，而 xtun 只接管 `conf.d/` 下的一个 server 段，够不着它。发行版默认值 768 在反代场景下要打对折——每个 worker 实际只够 384 个客户端。`xtun diagnose` 会把当前值报出来，低于 4096 时提示手工调整：

```text
events {
    worker_connections 8192;
}
```

### 卸载

只删除 xtun 托管文件，不卸载软件包：

```bash
xtun uninstall --yes
```

删除托管文件并尝试卸载主要软件包：

```bash
xtun uninstall --purge --yes
```

`--purge` 会尝试卸载 `haproxy`、`nginx`、`jq`、`uuid-runtime`，并清理 `/root/.acme.sh`、`/var/log/xtun` 等路径。旧版本装过 `cloudflare-warp` 的机器，也会一并清掉遗留的 APT 源、keyring 和 `/var/lib/cloudflare-warp`。

不带 `--yes` 时会要求二次确认：普通卸载回答 `y`，`--purge` 需要完整输入 `purge`（确认前会先列出这次会做的四件事）。菜单里的 `17. 卸载托管文件` 和 `18. 完全卸载（含软件包）` 同样要走这道确认，不会一按回车就删。

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

安装时加 `--enable-warp` 就够了，脚本会自动向 Cloudflare 注册一台免费 WARP 设备（生成 X25519 密钥对 + 一次 API 调用），私钥写进 `node-meta.env`（`0600`）和 `config.json`（`0640 root:xray`），不会出现在输出文件或订阅里。

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

从旧版本升级上来的机器，第一次执行 `change-warp` 会顺手停用并清理 `warp-svc`、`xtun-warp-health.timer`、MDM XML、APT 源和 keyring。彻底删包需要自己跑一次：

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

- 在交互终端里不带任何修改参数直接跑 `xtun change-warp-rules`（或走菜单 13），会进一个规则编辑器：`a` 添加、`d` 按序号或规则名删除、`r` 恢复默认、`s` 保存并应用、`q` 放弃退出。`q` 不写任何东西
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
| `existing` | 已有 Cloudflare Origin CA 或 Let's Encrypt 证书 | `Full (strict)` |
| `cf-origin-ca` | 手动从 Cloudflare 面板生成 Origin CA | `Full (strict)` |
| `acme-dns-cf` | 用 `acme.sh + Cloudflare DNS API` 自动申请公有证书 | `Full (strict)` |

已有证书：

```bash
xtun change-cert-mode --cert-mode existing \
  --cert-file /etc/ssl/cloudflare/cert.pem \
  --key-file /etc/ssl/cloudflare/key.pem
```

Cloudflare Origin CA：

```bash
xtun change-cert-mode --non-interactive --cert-mode cf-origin-ca \
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
   - `existing` / `cf-origin-ca` / `acme-dns-cf` -> `Full (strict)`
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
- 已安装过旧版网络优化的机器，更新脚本后可直接运行 `xtun apply-net-opt` 重新应用新版 Joey BBRv3 网络优化
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
- `fs.file-max` 按 `MemTotal` 的 1/4 给、封顶 200 万，兜住 `xray.service` 里的 `LimitNOFILE=1048576`；内存撑不到就不写，交给内核自己估
- systemd oneshot 开机后重新应用 qdisc（`fq limit 100000 flow_limit 1000`）、`RPS`、`XPS`，并把出网网卡和默认路由的 MTU 夹到 1500

如果当前内核还不是 Joey BBRv3，但对应内核包已经安装，脚本会保留配置并提示重启；重启后再运行 `xtun status` 或 `modinfo tcp_bbr` 可确认生效。

关于 MTU：部分云厂商的 DHCP 会下发巨帧 MTU（例如 Oracle VCN 给 9000）。对一台流量全走公网的代理机来说这只有坏处——每条新连接从 `advmss 8960` 起步，先白吃一轮 PMTU 探测才退回 1500 附近。helper 只往下夹、不往上抬：链路或默认路由的 MTU 大于 1500 才改，PPPoE / 隧道那种 1492、1450 的链路原样保留。

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
