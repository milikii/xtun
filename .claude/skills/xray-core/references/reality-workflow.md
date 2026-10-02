# REALITY：配置决策与目标检测

此流程用于指导 harness，不维护“永久可用域名列表”，不扫描网段或批量寻找公共目标。
仅检测用户明确选择的少量候选，事先说明会从当前机器发起 DNS/TCP/TLS 连接。

## 证据与适用范围

先读 [sources.yaml](../sources.yaml)。以下解释使用已收录 v26.9.30 的证据，不自动外推新版本：

- [官网 REALITY](../docs/stable/config/transports/reality.md)：概念与配置意图，滚动快照。
- [配置构建](../source/versions/v26.9.30/infra/conf/transport_security.go)：`REALITYConfig.Build`、角色、键和条件。
- [Core 集成](../source/versions/v26.9.30/transport/internet/reality/reality.go) 与
  [锁定依赖](../source/dependencies/reality/v26.9.30/tls.go)：实际认证及 ClientHello 检查。
- [官方 TLS ping](../source/versions/v26.9.30/main/commands/all/tls/ping.go)：`executePing`、输出与失败行为。

旧稳定版/历史预发布使用各自路径，不用最新版文件替代对应依赖。尤其不要把客户端需要携带的
MLKEM key share，和所选 target 最终协商哪种密钥交换混为同一个条件。

## 1. 先分清三类地址

- 客户端连接的代理地址：用户的 Xray 服务端，而不是被选中的目标网站。
- 服务端 `target`：REALITY 使用的转发目标，可带端口。
- 客户端 `serverName` 与服务端允许列表：应符合所选目标的实际 SNI/证书/握手行为。

不能凭网站主页打开就推断全部成立，也不能随意将 IP、Host、SNI 当作可互换字段。
明确所用传输与 flow 后核对对应版本约束；RAW、XHTTP 等不是同一套运行路径。

## 2. 目标检测分层记录

| 检查 | 记录什么 | 不代表什么 |
|---|---|---|
| DNS | 解析时间、当前 VPS、IPv4/IPv6、实际连接 IP | DNS 永不变化、其他地区相同 |
| TCP | 指定端口可达、超时/拒绝 | TLS 或 REALITY 已通过 |
| 带 SNI 的 TLS | 证书链/名称/有效期验证、协议、ALPN、可观测密钥交换信息 | REALITY 认证通过 |
| 无 SNI 的诊断 | 目标此时如何响应 | 证书可信、客户端可不配置 SNI |
| REALITY 两端测试 | 对应内核/指纹、凭据配对、实际数据与错误身份拒绝 | CDN 或地区可达性保证 |

若使用现有、获准执行且身份已核验的官方内核，可运行该版本支持的 `xray tls ping`。
下面是流程示意，路径和域名都需由操作者替换；不在知识维护时自动执行：

```bash
# 先创建用户指定的私有报告目录；不要复用已有报告文件。
umask 077
set -C
/path/to/verified-xray tls ping candidate.example:443 > /private/new-target-tls.txt 2>&1
```

按实际版本源码确认是否支持 `-ip` 等参数。多地址测试需显式选择少量地址、加外层超时，
不能让失联目标永久挂住工具。输出可能包含网络位置和目标信息，报告按私有文件保存。

### 不能只看返回码或“Handshake succeeded”

v26.9.30 的 `executePing` 分别测试无 SNI 和带 SNI：

- **无 SNI 分支显式跳过证书验证**，成功不能当作安全连接通过。
- 带 SNI 分支使用证书验证；需要单独查看其结果。
- 某些握手失败只是打印 `Handshake failure`，命令仍可能正常结束。
- 因此退出码 0、第一段成功、或日志里存在一个成功字符串都不足以判定目标合格。

它不接收真实节点凭据，可用程序提取各段测量结果；不要为通过检测给实际客户端开启不安全验证。
普通 OpenSSL/Python TLS 探测也不能证明 Xray 指纹、MLKEM ClientHello 或 REALITY 认证兼容。
探测工具无法观测某项时报告 unknown，不把没有输出当成“不支持”。

## 3. 从检测结果到配置

1. 对照目标版本的官方建议和运行要求，检查 TLS、ALPN、目标名称和客户端能力。
2. 对采用额外签名/后量子相关选项的情况，再核对其独立条件；不要把它们当成所有 REALITY 配置的统一要求。
3. 将目标选择理由、当前观测、未验证条件记录为非凭据说明。不提供永不失效或某地区必通的保证。
4. 依 [私密产物规范](private-artifacts.md) 本地生成凭据、配对并直接写文件。
5. 分别做配置构建与真实链路验证。已有 `check_handshake.py` 适配的是本地测试 target，
   它通过也不能证明原公共 target 在实际 VPS 上合适。

## 4. 故障时按层排查

客户端到 VPS、VPS 到 target、TLS/SNI、ClientHello、时间条件、身份配对和数据转发分别定位。
不要因“节点延迟测试失败”就立即更换密钥或重装服务；探测 URL、自身路由或 DNS 也可能导致失败。
日志由本地程序脱敏后再交给模型，不读取含凭据的完整配置。

目标是随时间变化的外部依赖：将目标复查纳入维护流程，但不在加载技能时自动创建定时任务。
