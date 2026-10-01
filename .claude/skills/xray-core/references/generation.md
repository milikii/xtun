# 生成与验证契约

本文说明**本工具的请求格式**，不是 Xray-core 的完整配置 schema。规则来自
[生成规则](../extracted/compatibility/generation.yaml)，版本身份来自 [sources.yaml](../sources.yaml)。
原生字段的语义仍需对照目标版本的官方配置与运行实现；工具拒绝某字段不等于内核不支持。

所有命令假设当前目录是技能根目录；仓库根使用时给 `scripts/` 加上
`.claude/skills/xray-core/` 前缀。Python 3.10+，安装依赖：

```bash
python3 -m pip install -r scripts/requirements.txt
```

建议在虚拟环境安装，不修改系统 Python。下载或执行外部内核前必须得到用户授权；只做生成
（不传 `--binary`、不请求生成密钥）和结构检查不需要执行 Xray。

## 1. 先确定版本

```bash
python3 scripts/upstream.py check --output /private/new-observation.json
# 需要先有有效缓存；不会把离线结果标为实时最新
python3 scripts/upstream.py check --offline
```

`check` 分别观察 stable、prerelease、latest published、main 和 docs；支持 `--cache PATH`、
`--sources PATH`、`--timeout N`、`--max-pages N`、`--fail-on-change`。默认成功观测退出 0，
加 `--fail-on-change` 后发现差异退出 1；网络失败不会伪装为成功刷新。

目前生成器接受固定 `v26.3.27`、历史 `v26.9.9`、`v26.9.30`；不接受 `latest`、
任意新 tag 或 main。上游发现新版本后，先更新证据/规则并完成验证，再扩展生成范围。
不同两端版本可以显式指定，但仅有字段规则检查不等于互操作已经验证。

## 2. 最小请求

```json
{
  "version": "v26.3.27",
  "server": {
    "address": "proxy.example.com",
    "port": 8443
  },
  "transport": {"type": "raw"},
  "security": {
    "type": "tls",
    "server_name": "proxy.example.com",
    "certificate_file": "server.pem",
    "key_file": "server.key"
  }
}
```

这是使用示例域名和证书路径的输入，不是已部署节点。执行生成不会查 DNS、申请证书或证明证书存在。
缺省随机生成一个用户 UUID。请求 JSON 拒绝重复键、非有限数字和未知字段。

```bash
python3 scripts/generate.py --request /private/request.json --output /private/new-bundle
```

输出父目录必须存在，输出目录必须不存在。新输出目录 `0700`，文件 `0600`；不覆盖。

### 顶层键

| 键 | 类型 / 默认 | 含义 |
|---|---|---|
| `version` | 必填字符串 | 服务端明确 tag |
| `client_version` | 字符串，默认 `version` | 客户端明确 tag |
| `server` | 必填对象 | 对外地址、端口、可选监听地址 |
| `transport` | 必填对象 | 传输名称及两端设置 |
| `security` | 必填对象 | `tls` / `reality` / `none` |
| `label` | 字符串，默认 `VLESS` | 分享链接标签，不是内核路由 tag |
| `users` | 非空数组，默认 `[{}]` | 用户 ID、服务端 email、可选 flow |
| `flow` | 字符串，默认空 | 用户缺省 flow，可由每位用户覆盖 |
| `encryption` | 对象，默认 `{"mode":"none"}` | VLESS Encryption，独立于传输安全层 |
| `trusted_private_network` | 布尔，默认 `false` | 无传输加密且无 Encryption 时的显式可信私网声明 |
| `client_port` | 1–65535 整数，默认 `10808` | 客户端本地 SOCKS 端口，仅监听 loopback |
| `download` | 可选对象 | XHTTP 同一 listener/session store 的另一下行地址 |

`server.address` 是无 URL scheme 的 ASCII/IDNA 域名或 IP；IPv6 **不加方括号**，不使用 zone ID。
`server.port` 必填且为 1–65535 的整数。可选 `server.listen` 必须是 IP，默认 `0.0.0.0`；
这是生成配置值，不表示工具已经监听。监听暴露范围需使用者自行审查。

`users` 的每个对象只接受 `id`、`email`、`flow`。`id` 必须为 UUID；省略时随机生成，重复会拒绝。
`email` 仅进入服务端。支持空 flow、`xtls-rprx-vision` 及客户端 `xtls-rprx-vision-udp443`；
工具按两端职责去掉服务端 `-udp443` 后缀，组合仍受规则约束。

## 3. 传输设置

```json
{
  "type": "xhttp",
  "settings": {"path": "/private-route", "mode": "packet-up"},
  "server_settings": {},
  "client_settings": {}
}
```

`settings` 是对应原生 transport settings 对象的受支持子集。`server_settings`、
`client_settings` 对共享对象进行**浅层覆盖**，不是递归合并。关键路径、Host、serviceName、
传输认证及显式 XHTTP mode 必须配对；未知字段不被忽略。

| type | 工具接受的 security | 注意 |
|---|---|---|
| `raw` | TLS / REALITY / none | 普通 RAW；别名 `tcp` |
| `xhttp` | TLS / REALITY / none | 别名 `splithttp`；具体 mode、XMUX、padding 受规则约束 |
| `ws` | TLS / none | 别名 `websocket`；弃用但仍有显式生成选项 |
| `grpc` | TLS / REALITY / none | 弃用不等于不存在或一概不兼容 |
| `httpupgrade` | TLS / none | 仍有显式生成选项，保留弃用状态提示 |
| `kcp` | none | 别名 `mkcp`；需 Encryption 或可信私网条件 |
| `hysteria` | TLS | `settings.version` 必须为 `2`；不是独立 Hysteria 代理协议 |
| `masque` | TLS | 仅 `v26.9.30`；不是独立 MASQUE 代理协议，真实运行未验证 |
| `xdrive` | 不生成 | `v26.9.30` 内核存在该能力，但存储拓扑尚未覆盖 |

这里的 none **不是允许公网裸传**；若 VLESS Encryption 也为 none，必须显式声明可信私网，
且目标必须是工具允许的私网 IP，不接受未解析域名。此声明不是对真实网络隔离的自动证明。

生成器不覆盖完整 transport schema：嵌套结构可能需要新增经过审阅的规则。旧独立
`http`/`h2`/`h3`/`quic` type 被拒绝；不要与 XHTTP 的 HTTP/2、HTTP/3 承载方式混淆。
无 Encryption 时，工具仅为 RAW + TLS/REALITY 生成 Vision；不能把此工具范围说成所有版本的普遍内核限制。

## 4. 安全层与凭据

### TLS

必填 `type: "tls"`、`server_name`、`certificate_file`、`key_file`。可选：

- `fingerprint`：默认 `chrome`；工具拒绝 `unsafe`/`random`，不保证任意其他字符串都被内核接受。
- `alpn`：非空字符串数组；同时写入两端。省略时不擅自注入 ALPN 调优。
- `client_trust_file`：显式客户端验证信任证书文件。自签测试用私有信任锚，不关闭验证。
- `ech_config_list` 与 `ech_server_keys`：必须一起提供且目标版本支持；分别进入客户端/服务端。
  工具不生成 ECH 材料，不核验 DNS/CDN 配置；链接不能无损编码时省略链接。

证书文件在实际运行环境必须可读、域名匹配且有效。构建检查把相对证书路径按 bundle 目录解析。
不要在客户端分享服务端私钥。ECDH/证书材料等仍需实际对应二进制和链路验证。

### REALITY

```json
{
  "type": "reality",
  "server_name": "target.example.com",
  "target": "target.example.com:443"
}
```

这只是结构示意；不能据此认为示例 target 适合 REALITY。目标需要自行选择、核验。
`target` 为 `host:port` 或 `[IPv6]:port`。省略密钥时，需传入匹配服务端版本的 `--binary`，
由官方 `x25519` 命令生成；可选 `short_id` 为偶数长度、最多 16 个十六进制字符，缺省随机生成。

也可以同时提供 `private_key`、`password`，不能仅提供一个。没有二进制时只检查编码，
报告密钥未作密码学配对验证；有二进制时派生并比较。`password` 是客户端凭据，不能因历史名称
`publicKey` 而公开。`fingerprint` 默认 `chrome`；公共 target、ClientHello 兼容性仍是外部前提。

### VLESS Encryption

```json
{"mode": "generate", "authentication": "mlkem768"}
```

- `none`：只允许 `mode`。
- `generate`：需要目标 `--binary`，可选 `authentication` 为 `x25519`（默认）或 `mlkem768`。
- `supplied`：提供 `server` 与 `client` 两个不同、角色正确的原生字符串；不接受共享同一字符串。
  结构/前缀配对检查不证明密钥握手成立，报告仍要求真实链路验证。

服务端 decryption 不进入客户端。即便安全层同样使用 TLS/REALITY，也不能忽略 Encryption 的配对约束。
传入 `--binary` 会做身份检查并执行密钥命令，不是纯文件操作。

## 5. XHTTP 上下行地址与多用户

```json
"download": {"address": "download.example.com", "port": 8443}
```

这是顶层可选对象，只适用于非 `stream-one` 的 XHTTP。当前工具仅支持**同一 XHTTP listener/session store**
的另一访问地址；下行复制客户端原有传输/安全设置，不生成独立后端，也不建立 CDN/反代。
它不是“上行 TLS CDN、下行 REALITY”任意混搭接口。该配置保留原生 JSON，不输出损失 downloadSettings 的链接。

多用户输出一个服务端与 `client.json`、`client-2.json` 等独立客户端。各客户端是供不同用户选择的配置，
默认使用同一 SOCKS 端口，不能直接在同一主机同时启动而假定不冲突。

## 6. 输出与分享链接

| 文件 | 内容 |
|---|---|
| `server.json` | 单个 VLESS inbound 与 freedom outbound；含服务端秘密 |
| `client.json`、`client-N.json` | 每位用户独立 SOCKS inbound 与 VLESS outbound |
| `links.txt` | 仅包含可无损编码的客户端；全部不适用时不创建 |
| `manifest.json` | 精确版本/提交、规则/配置哈希、二进制身份（若有）、警告、初始验证状态 |
| `README.md` | 外部前提与链接省略原因，不是部署完成证明 |

`manifest.json` 不是 Xray 配置。生成后的验证报告为独立文件，不改写 manifest 中生成时的 `not_run`。
修改配置会导致哈希不匹配；不要手改清单绕过审查，应从修改后的请求重新生成。

URI 编码是保守连接字段映射，不承诺第三方 GUI 导入成功。基本 RAW/XHTTP/WS/gRPC/HTTPUpgrade
可按受支持子集编码；ECH、自定义复杂字段、downloadSettings 等不能无损表达时返回原生 JSON。
部分用户可生成链接、其他用户不能时，看 `manifest.links_skipped` 区分，不靠链接条数猜测全部用户。
标签支持 UTF-8 百分号编码；IPv6 URI 由编码器加方括号。

所有配置、UUID、REALITY password、Encryption 字符串和链接均按凭据处理。不要提交到仓库或公开报告，
不要把原始配置/内核日志写到 CI 输出。无覆盖策略同样适用于报告。

## 7. 逐层验证

### 结构与配对

```bash
python3 scripts/check_configs.py --bundle /private/new-bundle \
  --report /private/new-structure-report.json
```

无二进制时 native build 为 skipped；此命令不启动监听。它校验本生成器格式，不应直接用于任意
生产 Xray JSON 并宣称全面审计。

### 对应二进制构建

得到执行授权后：

```bash
python3 scripts/check_configs.py --bundle /private/new-bundle \
  --server-binary /path/server-xray --client-binary /path/client-xray \
  --require-build --report /private/new-build-report.json
```

逐端核验版本与短提交，自报身份检查不是签名验证；运行临时配置副本、正例与无效配置负对照。
私有过程输出不写公开报告。`--require-build` 防止缺少二进制被当作构建成功。

可选官方下载工具需要单独授权下载和执行，只支持其声明的平台资产：

```bash
python3 scripts/fetch_core.py --version v26.3.27 --arch amd64 \
  --output /private/new-core-cache
```

输出目录必须新建，父目录已存在；它核对官方发布摘要、解包边界并**运行版本检查**，不安装到系统目录。
同版本有多份构建时，使用经过来源校验且提交一致的资产。不要将官方 SHA256 等同于额外的数字签名保证。

### 显式隔离链路

```bash
python3 scripts/check_handshake.py --bundle /private/new-bundle \
  --server-binary /path/server-xray --client-binary /path/client-xray \
  --report /private/new-handshake-report.json
```

工具需要 OpenSSL，使用私有临时目录、loopback 高位端口和测试信任锚；记录环境适配，测试上传/下载
内容哈希及错误 UUID 负对照，并在负对照后复测正常传输。它不以外部目标或测速站为依赖。
不支持的拓扑明确 skipped，不冒充 passed；读取报告中的范围和原因。

**当前新工具真实 Xray 构建/握手矩阵尚未执行。** 离线 mock 或 loopback HTTP fixture 测试通过，
不等于真实 Xray transport、TLS/REALITY 或 Vision 已通过。即使未来某组合隔离测试通过，
也只代表报告所记录的版本、配置与适配环境，外部 CDN、GUI、公共 target、地区网络和性能仍未验证。

## 8. 复核依据

原生配置生成使用目标源码字段及审阅规则；示例入口：

- [官网入站](../docs/stable/config/inbound.md)（滚动文档快照，不自动匹配 tag）。
- [v26.9.30 VLESS 配置构建](../source/versions/v26.9.30/infra/conf/vless.go)。
- [v26.9.30 传输配置构建](../source/versions/v26.9.30/infra/conf/transport_method.go)。
- [v26.9.30 差异与运行证据索引](v26.9.30-delta.md)。
- [历史示例说明](examples.md)：保留既有示例及其实际验证范围，不能挪用为新生成器全矩阵证据。

每份结论须注明实际使用的目标版本和文件/符号；涉及默认值、握手、兼容性时继续核对对应运行代码。
