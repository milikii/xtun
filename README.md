# xtun

`xtun` 是一个面向 Debian / Ubuntu VPS 的一键部署与维护脚本。它把 `xray`、`haproxy`、`nginx`、Cloudflare CDN、可选 WARP 出站、证书和网络优化组合成一套可重复安装、可回滚、可维护的代理节点栈。

当前版本：`0.6.0`

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

启用网络优化并选择队列算法：

```bash
bash xtun.sh install --non-interactive \
  ... \
  --enable-net-opt \
  --net-qdisc fq
```

`--net-qdisc` 支持：`fq`、`fq_codel`、`fq_pie`、`cake`。

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

### 服务维护

```bash
xtun restart
xtun repair-perms
xtun upgrade
xtun update-script
xtun apply-net-opt
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
| `version` | 打印脚本版本（也支持 `--version` / `-v`） |

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

- `tcp_congestion_control = bbr`
- `default_qdisc = fq`，或通过 `--net-qdisc fq|fq_codel|fq_pie|cake` 指定
- `rmem / wmem / somaxconn / tcp_fastopen / tcp_mtu_probing`
- systemd oneshot 开机后重新应用 qdisc、`RPS`、`XPS`
- 对 `fq_pie` / `cake` 这类非默认队列算法写入 `/etc/modules-load.d/xtun-net-qdisc.conf`

如果当前内核还不是 Joey BBRv3，但对应内核包已经安装，脚本会保留配置并提示重启；重启后再运行 `xtun status` 或 `modinfo tcp_bbr` 可确认生效。

相关文件：

- `/etc/sysctl.d/98-xtun-net.conf`
- `/usr/local/sbin/xtun-net-optimize.sh`
- `xtun-net-optimize.service`
- `/etc/modules-load.d/xtun-net-qdisc.conf`

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
