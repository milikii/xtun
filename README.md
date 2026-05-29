# xtun

一个面向 Debian / Ubuntu VPS 的一键部署脚本，用来在一台机器上稳定搭建：

- `VLESS + REALITY + Vision` 直连节点
- `VLESS + XHTTP + TLS + CDN + VLESS Encryption` 节点
- `上行 XHTTP + TLS + CDN ｜ 下行 XHTTP + Reality` 上下行分离节点
- `Cloudflare WARP Team` 选择性出站
- `haproxy + nginx + xray` 的混合前置与 `443` 端口复用架构
- 可选 `Cloudflare Origin CA` / `acme.sh + Cloudflare DNS` 证书模式
- 可选 `Joey BBRv3 + fq + RPS/XPS` 网络优化

脚本主入口：

```bash
xtun.sh
```

安装完成后会自动落到：

```bash
/usr/local/sbin/xtun
```

对应的脚本 bundle 会放到：

```bash
/usr/local/lib/xtun
```

命令约定：

- 第一次安装：`bash xtun.sh`
- 安装完成后的维护：`xtun`

## 当前脚本架构

当前是“混合前置”架构：

- `haproxy :443`
  - 只负责按 `SNI` 做 TCP 分流
  - `CDN 域名 -> nginx 127.0.0.1:8443`
  - 其它域名 -> `xray reality 127.0.0.1:2443`
- `xray 127.0.0.1:2443`
  - `REALITY + Vision`
  - `fallback -> 127.0.0.1:8001`
  - `target -> 你设置的 Reality 伪装站，比如 www.sony.co.jp:443`
- `xray 127.0.0.1:8001`
  - `VLESS + XHTTP`
  - 默认开启 `VLESS Encryption`
- `nginx 127.0.0.1:8443`
  - 给 `CDN 域名` 提供 TLS / HTTP2
  - `/XHTTP_PATH -> grpc_pass 127.0.0.1:8001`
  - `/ -> 本地静态伪装站（默认 AI Signals Review）`

也就是说，三节点共享同一个 `443`，但实现方式是：

- `Reality` 由 `haproxy:443 -> xray:2443`
- `XHTTP CDN` 由 `haproxy:443 -> nginx:8443 -> xray:8001`
- `XHTTP 上下行分离` 仍然复用同一套服务端，只是在客户端通过 `downloadSettings` 实现上下行拆分

## 这套脚本适合什么场景

适合：

- 你想一台 VPS 同时提供 `Reality`、`xhttp CDN`、`xhttp split`
- 你需要 `WARP Team` 作为一部分出站
- 你希望后续直接改：
  - `Reality 域名/SNI`
  - `XHTTP 路径`
  - `节点名前缀`
  - `UUID`
  - `WARP 开关`
  - `证书模式`

不适合：

- 非 Debian / Ubuntu 系统
- 不想使用 root
- 想保留自己已有的复杂 `nginx` 网站体系且不希望脚本接管 `nginx`

## 安装前准备

最少需要：

- 一台 Debian / Ubuntu VPS
- root 权限
- 一个用于 `XHTTP CDN` 的 Cloudflare 橙云域名
- 一个证书可覆盖的 `Reality` 域名
  - 推荐同一张通配证书下的灰云子域名
  - 例如：
    - `cdn.example.com` 用于 CDN
    - `reality.example.com` 用于 Reality

如果你要启用 WARP Team，还需要：

- Cloudflare Zero Trust 团队名
- Service Token 的 `Client ID`
- Service Token 的 `Client Secret`

敏感参数建议不要直接写在 shell history 里。当前脚本支持：

- 直接用环境变量，例如：`WARP_CLIENT_SECRET=xxx bash xtun.sh install ...`
- 用 `@文件路径` 读取，例如：`--warp-client-secret @/root/secret.txt`

从 `0.4.9` 开始，下面这些敏感参数不再接受“命令行直接明文传值”：

- `--warp-client-secret`
- `--cf-dns-token`
- `--reality-private-key`
- `--cert-pem`
- `--key-pem`

`REALITY SNI` 也不再默认塞固定值。安装时需要你自己明确填写。

## 快速开始

现在可以直接用单文件入口启动，脚本会自动处理 bundle：

```bash
curl -fsSL https://raw.githubusercontent.com/milikii/xtun/main/xtun.sh -o xtun.sh
bash xtun.sh
```

不带参数时会进入菜单。第一次安装一般直接选：

```text
1. 安装或重装
```

说明：

- 如果当前目录已经有完整 `lib/`，脚本会直接本地运行
- 如果当前目录只有单文件入口，脚本会自动拉取完整 bundle 后再执行
- 如果机器上已经装过 `/usr/local/lib/xtun`，也会优先复用已安装 bundle

### 交互安装失败后怎么继续

交互安装时，脚本会把你已经填过的值先保存到：

```bash
/root/.xtun-install-draft.env
```

如果中途在预检、下载、证书、WARP 或配置校验阶段失败，再次执行：

```bash
bash xtun.sh
```

脚本会自动带回上次已经填过的值，不需要从头重新输入。安装成功后，这个 draft 文件会自动删除。

## 最小非交互示例

下面是推荐的最小安装方式：

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
  --warp-team your-team \
  --warp-client-id xxxxxxxxx.access \
  --warp-client-secret @/root/warp-client-secret.txt
```

等价的更安全写法：

```bash
export WARP_CLIENT_SECRET=xxxxxxxxx
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
  --warp-team your-team \
  --warp-client-id xxxxxxxxx.access
```

如果你明确不需要 WARP：

```bash
bash xtun.sh install --non-interactive \
  ... \
  --disable-warp
```

如果你明确不想启用 `XHTTP VLESS Encryption`：

```bash
bash xtun.sh install --non-interactive \
  ... \
  --disable-xhttp-vless-encryption
```

## 当前脚本的运行保证

当前版本已经补上的几个关键行为：

- 持久化管理命令不是单文件裸拷贝，而是 `wrapper + bundle` 结构
- 单文件入口会自动 bootstrap 到完整 bundle，不再要求手动先解压仓库
- `Xray` 核心仍然优先安装最新版本，但会同时下载 release 的 `.dgst` 并校验 `SHA256`
- `Xray / nginx / haproxy` 托管配置使用临时文件生成后再原子替换
- `TLS` 证书和私钥先写 staging，再校验匹配后替换正式文件
- 配置校验或服务重启失败时，会自动回滚最近一次托管变更
- 如果安装在运行时 / 可选组件 / 最终启动阶段失败，会自动回滚 bundle、Xray 核心和托管配置
- 安装、升级、校验、重启、回滚都会输出阶段日志，便于直接判断卡在哪一步
- 所有操作会额外落盘到 `/var/log/xtun/operations.log`
- 每次有备份目录的操作，还会把本次会话日志写到 `${BACKUP_DIR}/operation.log`
- 状态文件带 `STATE_VERSION`，脚本读取旧版本状态文件时会给出提示
- 交互安装失败后会保留一份安装 draft，方便再次进入时继续填写
- 安装前会做预检：443 端口占用、CDN 域名解析、Cloudflare Token 在线校验（在相关模式下）
- 启用 WARP 时会额外安装一个健康检查 timer，定期验证本地 WARP SOCKS5 是否可用
- 默认保留最近 5 次备份，超出的旧备份会自动清理
- 使用文件锁避免两个终端同时运行脚本互相踩配置

## 安装完成后会得到什么

脚本会托管：

- `/usr/local/sbin/xtun`
- `/usr/local/lib/xtun`
- `/usr/local/etc/xray/config.json`
- `/etc/nginx/conf.d/xtun.conf`
- `/etc/systemd/system/xray.service`
- `/usr/local/etc/xray/node-meta.env`
- `/root/xtun-output.md`
- `/root/xtun-subscriptions/vless-raw.txt`
- `/root/xtun-subscriptions/vless-base64.txt`
- `/root/xtun-subscriptions/manifest.txt`
- `/var/www/xtun-fallback`

如果系统里有 `qrencode`，还会在 `/root/xtun-subscriptions/qr/` 生成订阅二维码 PNG；没有 `qrencode` 时只跳过二维码，不影响安装。

安装成功后会导出 3 个节点：

1. `REALITY + Vision`
2. `XHTTP + TLS + CDN + VLESS Encryption`
3. `上行 XHTTP + TLS + CDN ｜ 下行 XHTTP + Reality`

默认说明：

- `XHTTP` 默认不启用 `ECH`
- 导出的两个 `XHTTP` 分享链接默认不带 `ech=`
- `XHTTP` 默认不启用 `xpadding`
- `XHTTP VLESS Encryption` 默认开启
- 默认会给节点名加统一前缀，便于客户端区分机器

如果你明确要测试 ECH / xpadding，可以在安装时显式开启：

```bash
bash xtun.sh install --non-interactive \
  ... \
  --enable-xhttp-ech \
  --enable-xhttp-xpadding
```

默认 ECH 配置为：

```text
cloudflare-ech.com+https://223.5.5.5/dns-query
```

xpadding 默认使用：

```text
Header=Referer, key=x_padding, placement=queryInHeader, method=tokenish
```

## WARP Team 教程

### WARP Team 在这套脚本里做什么

这套脚本里的 WARP 不是“整机全局代理”，而是：

- 让 `Xray` 的一部分目标域名走 `Cloudflare WARP Team`
- 其它流量仍按原规则直连

默认会走 WARP 的目标包括：

- `geosite:google`
- `geosite:youtube`
- `geosite:openai`
- `geosite:netflix`
- `geosite:disney`
- `gemini.google.com`
- `claude.ai`
- `anthropic.com` 及常用 API 域名
- `x.com / twitter.com / t.co / twimg.com`
- `github.com` 和 Copilot 相关域名

Telegram 默认直连。

### 需要准备什么

需要 3 个值：

- `团队名`
- `Client ID`
- `Client Secret`

### 安装时怎么填

交互安装时会问：

- 是否启用选择性 WARP 出站
- Cloudflare Zero Trust 团队名
- Cloudflare 服务令牌 Client ID
- Cloudflare 服务令牌 Client Secret
- 本地 WARP SOCKS5 端口

非交互安装时直接传：

```bash
--warp-team your-team
--warp-client-id xxxxx.access
--warp-client-secret xxxxx
--warp-proxy-port 40000
```

### 装好后如何验证

先看面板：

```bash
xtun status
```

再看原始服务状态：

```bash
systemctl status --no-pager warp-svc
```

如果要查看当前 MDM 配置：

```bash
sed -n '1,200p' /var/lib/cloudflare-warp/mdm.xml
```

### 以后如何开关 WARP

关闭：

```bash
xtun change-warp --disable-warp
```

重新启用：

```bash
xtun change-warp --enable-warp
```

如果要重新指定 WARP Team 参数：

```bash
xtun change-warp --enable-warp \
  --warp-team your-team \
  --warp-client-id xxxxx.access \
  --warp-client-secret xxxxx \
  --warp-proxy-port 40000
```

启用后还会自动安装：

- `/usr/local/sbin/xtun-warp-health.sh`
- `xtun-warp-health.service`
- `xtun-warp-health.timer`

它会定期探测本地 WARP SOCKS5 是否还能正常获取出口 IP；如果失败，会自动执行 `mdm refresh + restart warp-svc`。

### 维护 WARP 分流规则

查看当前生效规则：

```bash
xtun change-warp-rules --list
```

新增一个域名：

```bash
xtun change-warp-rules --add-domain chat.openai.com
```

删除一个域名：

```bash
xtun change-warp-rules --del-domain github.com
```

恢复到脚本默认规则集合：

```bash
xtun change-warp-rules --reset-defaults
```

说明：

- 裸域名会自动转成 `domain:` 规则
- 也可以直接传 `geosite:xxx`
- 规则会写入 `/usr/local/etc/xray/warp-domains.list`
- 更新后会自动重写 `xray` 配置并走现有校验 / 重启 / 回滚流程

## 证书模式

### 1. self-signed

适合快速测试。

要求：

- Cloudflare SSL/TLS 设为 `Full`

### 2. existing

适合你已经有证书的情况，比如：

- Cloudflare Origin CA
- Let’s Encrypt

要求：

- Cloudflare SSL/TLS 设为 `Full (strict)`

支持两种输入方式：

1. 直接给本机文件路径
2. 直接粘贴 PEM 内容，由脚本写入

本机已有文件示例：

```bash
bash xtun.sh install \
  --cert-mode existing \
  --cert-file /etc/ssl/cloudflare/cert.pem \
  --key-file /etc/ssl/cloudflare/key.pem
```

直接传 PEM 内容示例：

```bash
bash xtun.sh install \
  --cert-mode existing \
  --cert-pem @/etc/ssl/cloudflare/cert.pem \
  --key-pem @/etc/ssl/cloudflare/key.pem
```

### 3. cf-origin-ca

使用你在 Cloudflare 面板里生成的 Origin CA 证书和私钥。

交互模式下会直接让你粘贴：

- Cloudflare Origin CA 证书 PEM
- Cloudflare Origin CA 私钥 PEM

非交互模式可使用文件：

```bash
bash xtun.sh install \
  --cert-mode cf-origin-ca \
  --cert-pem @/root/cf-origin.pem \
  --key-pem @/root/cf-origin.key
```

这个模式不需要 Cloudflare API Token。

### 4. acme-dns-cf

通过 `acme.sh + Cloudflare DNS API` 申请公有证书。

需要：

- `--acme-email`
- `--cf-dns-token`

建议 Token 权限：

- `Zone / DNS / Edit`
- `Zone / Zone / Read`

## Cloudflare 侧需要做什么

请手动确认：

1. `CDN 域名`
   - 指向 VPS 公网 IP
   - 打开橙云代理
2. `Reality 域名`
   - 推荐灰云 / DNS only
   - 证书必须覆盖它
3. SSL/TLS 模式：
   - `self-signed` -> `Full`
   - `existing` -> `Full (strict)`
   - `cf-origin-ca` -> `Full (strict)`
   - `acme-dns-cf` -> `Full (strict)`
4. 如果走 Cloudflare CDN 的 `XHTTP`
   - 建议开启 `gRPC`
5. 如果走 Cloudflare CDN 的 `XHTTP`
   - 建议额外配置 `缓存 -> Cache Rules`
   - 新建一条规则，把 `Cache eligibility` 设为 `Bypass cache`
   - 表达式可直接写成：

```text
(http.host eq "cdn.example.com") or (http.request.uri.path contains "/your-xhttp-path")
```

把 `cdn.example.com` 和 `/your-xhttp-path` 替换成你自己的 `XHTTP` 域名和路径即可。

面板路径参考：

- 左侧菜单 `缓存`
- `Cache Rules`
- `创建缓存规则`
- `如果传入请求匹配... -> 自定义筛选表达式`
- `Cache eligibility -> Bypass cache`

这条规则的目的，是避免 `XHTTP` 请求被 Cloudflare 边缘缓存后影响连接稳定性。

## 常用命令

### 查看状态

```bash
xtun status
```

当前状态面板除了 systemd 状态，还会额外显示：

- `443 / 2443 / 8001 / 8443` 监听情况
- 当前证书到期时间
- `WARP` 出口 IP 探测结果
- 当前 `WARP` 规则数量
- 最近一次备份目录
- `xtun-warp-health.timer` 的运行状态
- 最近一次核心 / WARP 自恢复结果
- 最近一条自恢复历史记录
- 近 1 小时 / 24 小时的核心与 WARP 自恢复次数
- 一个简化的稳定性信号：`稳定 / 观察中 / 高风险`

### 查看原始 systemd 输出

```bash
xtun status --raw
```

### 一次性运行服务端诊断

```bash
xtun diagnose
```

这个命令会集中输出：

- `xray / haproxy / nginx / warp-svc` 当前状态
- 关键监听端口 `443 / 2443 / 8001 / 8443`
- `Xray / nginx / haproxy` 配置自检结果
- 本地 `TLS` 握手探测结果
- 最近一次核心 / WARP 自恢复信息
- 最近一条自恢复历史记录
- 近 1 小时 / 24 小时恢复次数
- 稳定性信号

并且：

- 如果关键服务、关键监听端口、配置自检或本地 TLS 探测失败，`diagnose` 会以非 0 退出
- 可以直接拿它做脚本化巡检或外层监控
- 失败时会额外输出按 `服务 / 端口 / 配置 / 连接 / WARP` 分类的摘要，减少排障噪音

### 查看节点链接

```bash
xtun show-links
```

如果已经添加了多个客户端，可以选择某个客户端重新生成本地输出和订阅文件：

```bash
xtun show-links --client phone
```

如果系统里装了 `qrencode`，也可以直接输出二维码：

```bash
xtun show-links --qr
```

### 添加 / 查看客户端

默认安装会保留一组 `default` 客户端链接。新增客户端会复用同一组服务端节点、域名、路径与 Reality 参数，但给该客户端生成独立的 REALITY UUID 和 XHTTP UUID。

```bash
xtun add-client phone
xtun list-clients
```

也可以显式指定客户端 UUID：

```bash
xtun add-client phone \
  --reality-uuid 33333333-3333-3333-3333-333333333333 \
  --xhttp-uuid 44444444-4444-4444-4444-444444444444
```

### 查看订阅文件

安装和每次变更后，脚本会刷新本地订阅文件：

```bash
ls -l /root/xtun-subscriptions
```

其中：

- `vless-raw.txt` 是当前选中客户端的 5 条原始 `vless://` 链接，适合支持 URI 行订阅的客户端
- `vless-base64.txt` 是 base64 订阅，适合 V2RayN / Xray 风格导入
- `manifest.txt` 记录订阅文件和二维码 PNG 的生成状态
- `qr/` 目录只在系统安装了 `qrencode` 时生成

### 修改 REALITY 域名 / SNI

```bash
xtun change-sni --reality-sni reality.example.com
```

### 修改 XHTTP 路径

```bash
xtun change-path --xhttp-path /assets/v3
```

### 修改节点名前缀

```bash
xtun change-label-prefix --node-label-prefix HKG
```

### 轮换 UUID

```bash
xtun change-uuid
```

只换 REALITY：

```bash
xtun change-uuid --reality-only
```

只换 XHTTP：

```bash
xtun change-uuid --xhttp-only
```

`change-*` 命令现在都会输出阶段日志；如果应用新配置后校验失败或重启失败，会自动回滚最近一次托管变更。

### 开关 WARP

```bash
xtun change-warp --disable-warp
```

```bash
xtun change-warp --enable-warp
```

### 修改 WARP 分流规则

```bash
xtun change-warp-rules --add-domain chat.openai.com
```

### 切换证书模式

```bash
xtun change-cert-mode --cert-mode existing \
  --cert-file /etc/ssl/cloudflare/cert.pem \
  --key-file /etc/ssl/cloudflare/key.pem
```

切换到 Cloudflare Origin CA：

```bash
xtun change-cert-mode --cert-mode cf-origin-ca
```

非交互写法：

```bash
xtun change-cert-mode --non-interactive --cert-mode cf-origin-ca \
  --cert-pem @/root/cf-origin.pem \
  --key-pem @/root/cf-origin.key
```

说明：

- 该命令更新的是当前 VPS 的共享 XHTTP CDN 证书。
- 同一台机器上的默认客户端和 `add-client` 生成的命名客户端会一起使用新证书。
- 如果你有东京、圣何塞等多台 VPS，需要分别在每台 VPS 上执行一次。

### 本地静态伪装站

脚本默认会把 AI 资讯风格的静态站发布到：

```bash
/var/www/xtun-fallback
```

Nginx 根路径 `/` 会直接读取这个本地站点，不再反代外部名站；`XHTTP_PATH` 仍然单独转发到本机 Xray。

### 续期 / 刷新当前证书

```bash
xtun renew-cert
```

说明：

- `self-signed`：重新生成一张新的自签名证书
- `existing`：需要重新提供证书来源，例如 `--cert-file/--key-file` 或 `--cert-pem/--key-pem`
- `cf-origin-ca`：重新提供 Cloudflare Origin CA 证书 PEM 和私钥 PEM
- `acme-dns-cf`：重新执行 `acme.sh` 的申请 / 安装流程

敏感参数请使用环境变量或 `@文件路径`：

```bash
CF_DNS_TOKEN=xxxxxxxx xtun renew-cert --non-interactive
```

### 升级 Xray 核心

```bash
xtun upgrade
```

说明：

- 仍然优先跟随 `XTLS/Xray-core` 最新 release
- 下载 zip 后会校验对应 `.dgst` 里的 `SHA256`
- 如果升级后的配置校验失败，或 `xray` 重启失败，会自动回滚 `xray` 二进制和资源文件

### 重启服务

```bash
xtun restart
```

### 更新脚本本身

```bash
xtun update-script
```

说明：

- 会下载最新脚本 bundle 并覆盖 `/usr/local/lib/xtun`
- 会同时更新 `/usr/local/sbin/xtun` wrapper
- 如果 bundle 安装失败，会自动回滚到更新前的持久化脚本文件

### 抢修权限

如果你遇到：

- `xray.service` 起不来
- `status=23`
- `config.json / cert.pem / key.pem / access.log / error.log` 权限不对

先直接跑：

```bash
xtun repair-perms
```

这个命令会：

- 修正 `config.json`
- 修正证书目录和证书文件
- 修正 `/var/log/xray`
- 修正 `access.log / error.log`
- 尝试重启 `xray`、`haproxy` 与 `nginx`

### 卸载脚本托管文件

```bash
xtun uninstall --yes
```

说明：

- 会删除脚本托管的配置、证书、systemd unit、bundle 和输出文件
- 不会卸载已经装上的软件包
- 每次卸载前会先把托管文件备份到本次 `BACKUP_DIR`

### 完全卸载（含软件包）

```bash
xtun uninstall --purge --yes
```

说明：

- 会删除脚本托管文件
- 会尝试卸载脚本安装的主要软件包：
  - `haproxy`
  - `nginx`
  - `jq`
  - `uuid-runtime`
  - `cloudflare-warp`
- 还会额外清理：
  - `/root/.acme.sh`
  - `/var/lib/cloudflare-warp`
  - `/var/log/xtun`

### 操作日志

全局日志：

```bash
/var/log/xtun/operations.log
```

单次会话日志：

```bash
${BACKUP_DIR}/operation.log
```

## 常见问题

### 1. Reality 用 IP 还是域名

建议：

- 稳定优先：客户端地址直接用公网 IP
- 维护优先：客户端地址用灰云域名

当前脚本默认导出的 `Reality` 节点地址是公网 IP，`serverName/SNI` 则使用你设置的 Reality 域名。

### 2. 为什么 XHTTP 默认像正常业务路径

脚本默认会从这些候选里随机选一个：

- `/api/v1/ping`
- `/health`
- `/status/check`
- `/service/healthz`
- `/v1/report`
- `/metrics/pulse`
- `/gateway/ping`
- `/session/refresh`
- `/edge/check`
- `/content/live`

这样比早期固定的静态资源目录更自然，也更接近普通网站里会出现的轻量探测 / 业务接口路径。

### 3. 为什么默认不启用 ECH

因为在很多网络环境里，尤其中国网络下：

- `ECH` 依赖额外 DNS / DoH 查询
- 容易引入额外不稳定性

所以脚本默认：

- `XHTTP` 不启用 `ECH`
- 导出的分享链接不带 `ech=`

如果你后续明确要测，可以在安装时加 `--enable-xhttp-ech`，或者用 `--xhttp-ech-config-list` 指定自己的 ECH 配置列表。当前脚本不会把 `echForceQuery` 写进分享链接，因为主流 VLESS URI 规范只确认了 `ech=` 对应 `echConfigList`。

### 4. 为什么默认不启用 xpadding

`xpadding` 是 XHTTP 的高级伪装选项，依赖较新的 Xray / 客户端实现。默认关闭是为了避免旧客户端导入失败或行为不一致。

如果你明确要测，可以在安装时加：

```bash
--enable-xhttp-xpadding
```

默认写入 Xray 的字段是：

- `xPaddingObfsMode: true`
- `xPaddingKey: x_padding`
- `xPaddingHeader: Referer`
- `xPaddingPlacement: queryInHeader`
- `xPaddingMethod: tokenish`

### 5. 现在的三节点里，split 为什么不用额外服务端入站

因为这套架构里：

- 服务端只有一套 `xhttp` 入站
- “上下行分离”是客户端通过 `downloadSettings` 实现的

也就是说：

- 节点 2 和 节点 3 共用同一个服务端 `xhttp` 入站
- 区别在客户端的下载链路选择

### 5. Cloudflare 返回 521 / 525 怎么办

先分层排查：

1. `xray` 是否真的运行
2. `haproxy` 是否真的运行
3. `nginx` 是否真的运行
4. `xray` 是否监听了 `2443` 和 `8001`
5. `nginx` 是否监听了 `127.0.0.1:8443`
6. `haproxy` 是否监听了 `:443`
7. Cloudflare SSL/TLS 模式是否正确
8. 证书是否覆盖 `CDN 域名`

建议第一步先跑：

```bash
xtun repair-perms
xtun status
```

如果刚做过 `install`、`change-*`、`upgrade`，也建议顺手看一下终端里最后几条 `[步骤] / [完成] / [警告]` 输出。当前脚本已经会明确告诉你失败是出在：

- 下载和校验 `Xray` 核心
- `Xray` 配置校验
- `nginx` 配置校验
- `haproxy` 配置校验
- 服务重启
- 自动回滚

## 网络优化说明

如果启用网络优化，脚本会先按当前架构集成第三方项目 `byJoey/Actions-bbr-v3` 提供的 Joey BBRv3 内核包：

- `x86_64 / amd64` 使用上游 `x86_64-*` release
- `aarch64 / arm64` 使用上游 `arm64-*` release
- 下载的 deb 会按 GitHub Release API 的 SHA256 digest 校验
- 脚本不会直接执行上游的交互式 `install.sh`；只使用其 GitHub Release 中发布的内核 deb 资源
- 安装内核后不会自动重启；需要手动重启 VPS 后才会加载 BBRv3

执行时机：

- 交互式安装时会询问“是否启用网络优化”，默认是 `y`
- 非交互安装时传入 `--enable-net-opt` 会自动执行；传入 `--disable-net-opt` 会跳过
- 当前网络优化只面向 Debian / Ubuntu 系，并要求当前机器架构能匹配上面的 `amd64` 或 `arm64`
- 如果当前已经运行 Joey BBRv3，脚本只会刷新 sysctl、helper 和 systemd 服务，不会重复安装内核

随后脚本会写入并应用：

- `tcp_congestion_control = bbr`
- `default_qdisc = fq`
- 调整 `rmem/wmem/somaxconn/tcp_fastopen/tcp_mtu_probing`
- 通过 systemd oneshot 在开机后重新应用 `fq`、`RPS`、`XPS`

如果当前内核还不是 Joey BBRv3，但对应内核包已经安装，脚本会保留配置并提示重启；重启后再运行 `xtun status` 或 `modinfo tcp_bbr` 可确认生效。

相关文件：

- `/etc/sysctl.d/98-xtun-net.conf`
- `/usr/local/sbin/xtun-net-optimize.sh`
- `xtun-net-optimize.service`

第三方来源：

- Joey BBRv3 内核包来自 `byJoey/Actions-bbr-v3`
- 项目地址：https://github.com/byJoey/Actions-bbr-v3
- 上游 LICENSE 标注为 MIT；本脚本仅在安装时引用其 release 产物，请以该上游仓库的最新说明为准

## 客户端导出

当前输出文件默认只保留当前客户端的 5 条原始 `vless://` 分享链接：

1. `REALITY + Vision`
2. `XHTTP + Reality`
3. `XHTTP + TLS + CDN`
4. `上行 XHTTP + TLS + CDN ｜ 下行 XHTTP + Reality`
5. `上行 XHTTP + Reality ｜ 下行 XHTTP + TLS + CDN`

说明：

- 不再额外附带其它客户端结构化片段
- 新增客户端会生成独立 UUID，`xtun show-links --client NAME` 会刷新该客户端的输出和订阅文件
- `XHTTP-SPLIT` 节点的客户端兼容差异更大，继续建议直接使用脚本生成的原始分享链接导入
- 订阅文件单独写在 `/root/xtun-subscriptions/`，不会混进 Markdown 输出文件
- 当前只生成 raw/base64 VLESS 订阅；原生 Mihomo YAML 暂不生成，避免把 XHTTP split / ECH / xpadding 映射错
- 输出文件最后会单独附上一节 `XHTTP 缓存绕过（重要）`，按步骤指导你去 Cloudflare 面板创建 `Bypass cache` 规则

## 参考

- Cloudflare 官方无头 Linux 部署文档  
  https://developers.cloudflare.com/cloudflare-one/tutorials/deploy-client-headless-linux/
- Cloudflare One Client 文档  
  https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/
- Xray 官方讨论 `#4118`  
  https://github.com/XTLS/Xray-core/discussions/4118
- Xray 官方仓库  
  https://github.com/XTLS/Xray-core
