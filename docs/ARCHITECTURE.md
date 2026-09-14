# xtun 架构说明

本文讲「为什么这么设计」。操作步骤见 README。

> 现状更新：2026-09-14。下述部署拓扑保留；恢复层证据见[接手报告](REPORT-2026-09-14-W04R-W05R.md)，菜单与 H3 意图见[批次 B 报告](REPORT-2026-09-14-BATCH-B.md)，完整目标见[决策](DECISIONS-UX-RELIABILITY.md)。强制断电和 H3 真实公网/客户端路径仍待验收。

## 请求流图

```text
公网 TCP :443
  |
  v
haproxy（SNI TCP 分流）
  |-- SNI = XHTTP CDN 域名 --> nginx 127.0.0.1:8443 --> xray 127.0.0.1:8001（VLESS + XHTTP）
  `-- 其它 SNI -------------> xray Reality 127.0.0.1:2443
                                |-- 鉴权通过 --> VLESS + Vision / fallbacks 8001
                                `-- 鉴权失败 --> dokodemo 127.0.0.1:2444
                                                  |-- SNI == REALITY_SNI --> 真实目标站
                                                  `-- 其它 SNI --> blackhole

公网 UDP :443（H3 启用时）
  |
  v
nginx（QUIC，TLS 在 nginx 终结）--> xray 127.0.0.1:8001
```

本机端口一览：2443 Reality 入站 / 2444 dokodemo 回落过滤 / 8001 XHTTP 入站 / 8443 nginx TLS（TCP）/ 443 haproxy（TCP）+ nginx（UDP，仅 H3）。

## 为什么有 haproxy

Reality 的目标域是用户指定的第三方权威站点。xray 的 Reality 入站收到 SNI = CDN 域名（XHTTP 域名）的流量时，会按 realitySettings 的逻辑把回落转给远端目标站而不是本机 nginx。所以必须有一个前置 SNI 分流，把「SNI 是自己 CDN 域名」的流量先摘出来交给 nginx，其余（包括无 SNI、随机 SNI 的扫描器）才进 Reality 入站。

没换 nginx stream 模块的原因：haproxy 已有 reload、splice、用户块和测试覆盖，迁移收益不抵风险。

## 为什么 Reality 目标不用自己的域名

Reality 的原理是「偷」目标的 TLS 握手。目标如果指回本机 nginx（「自偷」）：

- 握手特征是自己人，训练过的主动探测者更容易对比出异常；
- 一旦配置失误（比如 SNI 分流漏了），等于把自己的伪装站暴露成 Reality 的回落目标，探测者拿到的响应和真实用户完全一致，反而失去了「偷大站」的掩护价值。

第三方目标需要按实际 SNI 与 target 检查，不能只凭机构类别判断适用。`check-sni` 在安装和改 SNI 时执行项目预检，涵盖 TLS/密钥组/ALPN、证书、HTTP、地址与耗时；这些项目包含协议条件和项目策略，不能一概称为 Xray 的 12 项硬性要求。

W06 已按保存或显式指定的真实 target/端口执行有界探测，复用同次采集，并区分 FAIL、WARN 和未验证。证书签发者只说明链来源，不能证明是否经过 CDN；“CDN 前置”保留未验证，同主机跳转等按实际规则提示。预检结果不能代替客户端真实握手与路径验证；字段及目标核心的限制以[参数契约](PARAMETERS.md)和对应官方源码为准。

## 防跑流量：dokodemo-door 过滤

Xray 官方文档明确指出：Reality 对鉴权失败的流量会转发到 target。如果目标在 CDN 后面，你的服务器就充当了 CDN 的端口转发，被扫描器发现后会偷跑流量。

xtun 采用 Xray-examples 的官方「without being stolen」模板：

- Reality 入站的 `target` 固定指向本机 `dokodemo-door`（127.0.0.1:2444）；
- dokodemo 开启 `sniffing`（`destOverride: tls`，`routeOnly: true`），路由按嗅探出的 SNI 匹配；
- 路由最前两条规则：`SNI == REALITY_SNI` 的回落放行 direct 到真实目标，其余 blackhole。

不配置 `limitFallbackUpload/Download`：官方提示回落限速可能形成特征，一键脚本若使用应随机化。SNI 过滤限制允许的回落目标，但不能由此宣称完全没有转发风险。`check-sni` 不再用 CA 品牌推断 CDN 身份；目标选择仍须结合可核对的站点与连接证据。

## 为什么 1.1.0 不再提供订阅与 mihomo 输出

- 单人节点，导入是一次性的动作，链接 + 二维码是所有客户端的公共分母。
- 订阅是一个匿名可拉取的 HTTPS 路径，token 再长也是一个常驻的攻击面，而它换来的「多设备自动同步」在单人场景里用不上。
- mihomo 的 xhttp 字段随版本漂移，仓库里没有本地校验器（`mihomo -t` 需要另下二进制），生成器只能靠人肉对照 wiki，维护成本高于收益。
- 分离节点的链接 1100–1700 字符，终端二维码不实用，所以 1.1.0 起改为终端二维码 + PNG 文件（`/root/xtun-qr/`，随链接重建）。

## nginx 主配置为什么要接管

`worker_connections` 和 `worker_rlimit_nofile` 只能写在主配置里。xtun 只接管 conf.d 的 server 段时，drop-in 提高的 fd 限额仍可能受主配置连接数限制；例如 `worker_connections 768` 且反代每连接占两个 fd 时，只能容纳约 384 条此类连接，实际还受其它资源占用影响。

接管受 `NGINX_MAIN_MANAGED` 控制，**新装默认关闭**，高级项或已有的 `apply-config --manage-nginx-main` 可明确启用；旧安装保留已保存的选择。手工调优写在 `xtun-user:*` 标记之间可跨重写保留。首次接管前将原件复制到 `/var/lib/xtun/originals/`，与可轮转备份分开；卸载或停止接管按「首次原件 → 旧备份里最早的可信原件 → 保留当前文件并报告」处理，不能写默认模板冒充恢复。

## 状态与回滚

- 工作区写出的状态为 `/usr/local/etc/xray/node-meta.env` schema v2，shell 转义 kv、0600；旧格式兼容读取。脚本声明与机器实际 state 分别记录，不能互相推断。
- 已有备份会话使用 `/root/xtun-backups/<时间戳+随机后缀>/`，同秒动作不共用目录。成功动作完成后才轮转普通成功备份，默认保留 5 份；首次接管原件与未解决失败证据单独保留。
- 单文件 staging 后替换与多个文件同代恢复是不同保障。配置、state、核心/资源和客户端产物跨多个路径，无法靠一次 `mv` 全局原子提交；已有 generation 层承担清单、候选、应用、检查与恢复。
- 当前顺序为确认 → 锁后复检 → 首次快照和完整持久恢复清单 → staging/验证 → 应用/健康检查 → 持久提交决定 → 清理。安装/卸载的确认前备份问题已修复。
- 普通备份 manifest v2 的七列严格验证，支持旧 v1；独立路径快照避免父/子路径覆盖。首次接管原件和包归属使用独立 v2 登记，新原件带摘要；旧 v1 原件保留 `legacy` 标识，不假称具备历史摘要。
- `/var/lib/xtun/pending-op.tsv` v2 保存代次、完整路径、服务及权限快照，引用不可变 manifest 副本和摘要。扩展路径先持久化，再允许写入；新进程按数据解析恢复清单，不 source/eval。
- 服务恢复覆盖 active、inactive、不存在及 enable 状态。先停当前实例再恢复 unit/文件，随后 daemon-reload 并核对每项；任何必需动作失败都保留 pending 与未恢复对象。既有日志仅恢复 mode/UID/GID，内容保留。
- 提交前同步目标，先写与 pending 摘要绑定的 `outcome.tsv`，再完成备份和删除 pending。提交决定已落盘而清理失败时不能回滚新代；显式 `xtun recover [--yes]` 只补收尾。没有提交决定才恢复操作前状态，原动作失败不因恢复成功变为成功。
- 操作日志在 `/var/log/xtun/operations.log`，随 logrotate 轮转。普通日志可单独警告，manifest/未完成清单等恢复证据必须可靠；二者失败策略不同，详见 D20。

安装范围包含 wrapper/bundle、核心/资源、配置/state/链接/PNG、TLS、unit/drop-in 和实际涉及的可选/旧资源；核心升级只登记二进制/资源及 Xray 服务，脚本更新只登记 wrapper/bundle。具体调用使用 `begin_generation_paths` 或共用范围接口；不能靠某个写文件 helper 临时补齐尚未落盘的范围。

草稿独立于托管回退，在确认后以 0600 持久保存；生成 REALITY 和 VLESS Encryption 密钥后、写配置前再次保存，强杀后的续装不依赖内存或 EXIT trap 保住身份。产物权限失败与旧二维码清理失败属于必需步骤失败。

共享软件包不会因回退被自动卸载；新增包留下原本不存在的 unit 时必须列为未恢复，不能擅自删除共享单元并宣称恢复完成。系统用户、新日志、实时 sysctl/qdisc/RPS/XPS、内核和外部注册同样不属于自动文件回退。已有 13 个真实 systemd、5 个文件系统与 5 个共享 HAProxy 场景；虚拟机强制断电仍须独立验证。

## 可选 H3 的实现边界

W09.1 已将 H3 分成持久意图、组件/证书/端口条件和真实网络验证。新装 `H3_INTENT=off`；显式开启后检查实际 nginx 模块、匹配域名的完整公共信任链及所有 UDP 443 监听的归属。existing/ACME 只说明证书来源，Origin CA 与自签不能据此放行直连 H3。

旧完整托管配置识别为 `legacy-on`，残缺证据为 `unknown`；查看不落盘，应用前要求明确意图并重算能力。nginx QUIC/Alt-Svc、节点 8/9 与说明共用本次判定，失败保留旧配置或进入同代恢复。节点 9 的 ALPN 位于 `downloadSettings.tlsSettings.alpn`。架构图的 UDP 路径只说明部署形态，本地配置检查不等于公网或客户端通过。
