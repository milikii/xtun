# xtun 新 VPS 生产就绪计划：以 Xray v26.9.9 为起点持续追新

> 审查日期：2026-09-12。代码基线：本地 `f219480`，脚本版本 `1.1.0`。
> 本轮交付为审查和规划，没有实施以下代码改动，没有安装或升级生产服务。
> 核心决策：当前必须接入 `v26.9.9`；后续默认追踪官方最新已发布版本，包含 pre-release，不采用 stable 优先策略。
> 本文是 [当前计划](PLAN.md) 的详细施工依据：先完成目标核心接入、默认安装与导出修复，再验证维护可靠性；后量子扩展另行验收。

REALITY/XHTTP/ECH 的逐字段决定、社区依据及导出规则见 [参数契约](PARAMETERS.md)；Android v2rayNG、Windows v2rayN、Debian NAS Docker 的现场步骤见 [测试 VPS 验收手册](TEST-VPS-RUNBOOK.md)。两份文档均为本计划的实施约束，当前没有把待测项目标为通过。

## 1. 结论与目标边界

**当前项目已有完整的部署架构和较多回归用例，但还不能宣称：在一台全新 VPS 上按默认流程安装，就能稳定交付所有标注的节点。** 有些缺口属于尚未完成的验证，本次也发现了可复现的实际错误。下一阶段以 `v26.9.9` 为实施和验证基线，把追新机制与生产就绪一起交付。

用户已经明确选择最新版核心。新装和显式核心升级默认发现最新官方发布，包含预发布；每次操作解析一次并锁定准确版本，验证失败则停止或恢复原服务。`v26.9.9` 是本轮必须完成的起点，后续出现新版时按 §3.4 推进基线。追新不等于默认打开所有 ECH、混淆或签名功能。

首个生产版本交付范围定为：**在明确支持的系统、架构和客户端版本上，可靠生成现有五类 VLESS 节点；IPv6、H3、WARP 按各自验收结果开放。** “各类”暂指项目已经实现的链路组合，不扩张为所有 Xray 协议及任意客户端都兼容。

保留现有 `HAProxy → nginx / Xray` 架构、链接与 PNG 导出、`node_link_entries` 单一链接清单。已经完成的订阅和 mihomo 输出删除不重做；暂不增加面板、订阅服务或新的常驻控制进程。

生产就绪要同时具备四项证据：

1. 全新系统从公开安装入口成功安装，下载到的确实是经过验证的版本组合。
2. 导出的链接能被声明支持的客户端正确导入，并按节点名称所描述的路径传输。
3. 变更、续证、升级、重启及失败恢复后，运行配置、状态与导出仍一致。
4. 在独立测试 VPS 和真实客户端网络中持续运行，达到预先设定的验收标准。

`bash -n`、ShellCheck、`xray run -test`、服务 active、打开伪装站、生成 PNG，分别只证明其中一部分，不能互相替代。

## 2. 本次核验记录

### 2.1 技能、代码和发布状态

| 项目 | 本次证据 | 含义 |
| --- | --- | --- |
| 项目技能 | `/root/.agents/skills/xray-core-official-knowledge` 已软链接到仓库 `.claude/skills/xray-core-official-knowledge`，并在本会话可用 | 已安装，无需重复复制另一份 |
| 技能时效 | `sources.yaml` 同步日为 2026-09-09；源码提交 `52a412d9…` 与 `v26.9.9` tag 相同；本轮比对的五个配置/传输文件逐字节一致 | 本文按目标 tag 核对源码，不靠 `docs/stable` 目录名判断版本 |
| 目标核心 | 官方 `v26.9.9`，`prerelease=true`、`draft=false`；2026-09-12 核对发布列表中没有更新版本 | 预发布标签不改变本项目采用最新版的决定；详见 §2.4 |
| 本地代码 | `f219480`，比远端 main 多一个提交 | 已完成的 bundle 签名修复还没有随远端 main 交付 |
| 远端 main | `434075910feb1ce6c93873be7a550a5a7591230e` | 通过 GitHub API 重新核对 |
| 最新 CI | [34382309011](https://github.com/milikii/xtun/actions/runs/34382309011) 失败 | 两个 job 均失败；其中 smoke 步骤成功，ShellCheck 和安装步骤失败 |
| Shell 语法 | 本轮对入口、lib、tests 共 37 个 `.sh` 文件执行 `bash -n`，通过 | 不包含 YAML 内嵌 shell 的语法检查 |
| ShellCheck | 本轮复现 `tests/cases_output.sh:819` 的 SC2012 | 不能沿用“全绿”的旧结论 |
| CI 内嵌脚本 | 单独提取 `Run install smoke` 后，`bash -n` 返回 2 | 外层单引号被 `grep -q '二维码 ('` 截断 |
| 113 条 smoke | 当前 PLAN 记录了全量通过；远端 smoke 步骤也成功 | 本轮未重新执行全套 smoke，不把历史记录写成本次实测 |
| 本机安装版本 | 只读确认 bundle 为 `0.11.14`，Xray 为 `26.3.27`、linux/arm64 | 本机正在运行旧 bundle，不能替代当前版本的新装验收 |

现有 `docs/PLAN.md` 和 `docs/archive/PLAN-1.1.0.md` 有未提交修改，本轮保留。实施者应先查看工作区状态，避免覆盖这些文件。现有计划记载的“本机生产节点暂时别动”约束继续保留；下述真实安装和故障演练使用独立测试环境。

### 2.2 已确认的问题及影响

| 编号 | 证据与位置 | 实际影响 | 优先级 |
| --- | --- | --- | --- |
| F01 | [CI](../.github/workflows/ci.yml) 内嵌脚本语法错误；[二维码测试](../tests/cases_output.sh) SC2012 | 当前公开版本没有完整的绿色安装验收 | P0 |
| F02 | [sni.sh](../lib/cli/sni.sh) 的 `run_sni_checks` 把 target 主机名传给 `sni_probe_http`，后者用于 curl `--resolve` 的 IP 位置 | 普通 `域名:443` 目标会使 HTTP 探测失败；本轮最小复现 curl 返回 49。现有 CI 用 `--skip-sni-check` 掩盖了这条路径 | P0 |
| F03 | 同文件的无参数入口先因空 target 退出；`--timeout 0` 被接受；HTTP 探测固定连接 443 | 已安装节点的便捷检查入口失效；超时和实际检查目标不可靠 | P1 |
| F04 | [安装参数表](../lib/cli/install.sh) 把 `--no-ipv6` 放进取值参数表 | 单独使用返回“需要值”；后接 `--disable-warp` 时会吞掉该开关并把它写入 `SERVER_IP6`。本轮两种情况均已复现 | P0 |
| F05 | [output.sh](../lib/ui/output.sh) 的 `build_xhttp_split_h3_extra_json` 将 `alpn: ["h3"]` 放在 `downloadSettings` 根部 | Xray 标准结构要求 `downloadSettings.tlsSettings.alpn`；下行没有被指定为 H3，可能仍按 H2 工作，单纯“能上网”也抓不到错误 | P1 |
| F06 | 同文件 `build_link_context` 给 IPv6 分离节点的外层 `build_xhttp_uri` 传入 VPS IPv6 | 名称宣称 CDN 上行，URI 实际直接连接源站 IPv6；CDN 被绕开，Origin CA 证书场景还可能验证失败 | P1 |
| F07 | [core.sh](../lib/ui/core.sh) 的 `h3_disabled_reason` 只根据 nginx 模块和 `CERT_MODE=existing/acme-dns-cf` 放行 | `existing` 也接受 Origin CA 或自签证书，不能推出客户端信任该证书；目前可生成不可按默认信任设置连接的 H3 链接 | P1 |
| F08 | [安装编排](../lib/cli/install.sh) 在安装依赖前生成输入、运行预检；[env.sh](../lib/base/env.sh) 的 `random_hex` 依赖 openssl | 极简镜像缺少 openssl/iproute2 等工具时，默认流程存在引导依赖缺口；现有安装 CI 预装 openssl 等工具，未覆盖这一条件 | P1 |
| F09 | [runtime.sh](../lib/base/runtime.sh) 部分流程在服务变更后写 state/output，失败直接返回；[commands.sh](../lib/change/commands.sh) 的 `change_uuid_cmd` 未接入统一回滚 | 存在运行配置、磁盘配置、状态和链接处于不同代的失败窗口。代码路径已核对，尚未做真实故障注入 | P1 |
| F10 | `upgrade_cmd` 中 `install_xray`/setcap 失败直接返回；安装函数会先替换二进制，再写资源文件 | 安装后半段失败时可能留下部分新核心文件，不能把“返回非零”当成“已恢复旧版本” | P1 |
| F11 | [本地 TLS 探测](../lib/ui/core.sh) 无超时，仅按 `openssl s_client` 退出码判断 | 诊断可能长时间等待，也没有证明主机名、证书信任或真实代理链路正确 | P1 |
| F12 | [核心下载](../lib/install.sh) 使用 `/releases/latest`，CI 固定 `v26.3.27` | 按当前代码安装和验收均不能实现用户要求的 `v26.9.9` 与后续预发布追踪 | P0 |
| F13 | `XHTTP_ECH_FORCE_QUERY` 被 CLI 接收、写入 state 并展示；导出未生成有效设置，目标版本 TLSConfig 也无 `echForceQuery` | 用户可设置一个没有实际效果的选项；应清理入口与展示，并保留旧状态的兼容读取 | P1 |

F05 此前在本轮审查中做了两层复现：纯生成器输出中，根部 ALPN 为 `["h3"]`、`tlsSettings.alpn` 为空；把该输出嵌入客户端配置后，**Xray 26.3.27 的 `run -test` 仍返回 `Configuration OK`**。这是旧核心的实测记录，不是 `v26.9.9` 二进制验收。另行核对的 `v26.9.9` 源码确认：ALPN 属于 TLSConfig，XHTTP 根据 TLS 的 NextProtocol 决定 H2/H3。因此新核心仍须增加语义和实际路径测试。[S2]、[S3]、[S8]

F07 的证书信任结论也已对照 Cloudflare 官方说明：Origin CA 用于 Cloudflare 到源站，不属于普通客户端默认信任的公网证书。[S6]

### 2.3 当前测试的边界

已有回归覆盖状态解析、生成器、输入校验、部分失败传播与回滚，应该继续保留。缺口主要在不同组件组合后的真实行为：

- 安装 CI 仅有一个 Debian 13 容器，跳过 SNI，关闭 WARP/网络优化/nginx 主配置接管，使用自签证书；不能代表默认安装与全部可选分支。
- PNG 单元用例用桩写入 `PNG` 文本，适合检查编排与权限，不能证明二维码可解码或客户端能扫码导入。
- H3 输出用例主要检查节点标题、数量和出现 `alpn=h3`，没有验证分离节点内层 ALPN，也没有证明 UDP 传输。
- 没有足够证据证明五类链接在声明支持的 GUI 客户端中无损导入，或 split 的两条路径实际按设计工作。

### 2.4 v26.9.9 的官方版本锚点

2026-09-12 查询官方 [发布 API][S9]、[tag ref][S10] 和 [发布列表][S11]：目标 tag 为 `v26.9.9`，提交为 `52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120`，发布时间为 `2026-09-08T22:28:10Z`。GitHub 将它标为 pre-release；`/releases/latest` 仍指向 `v26.3.27`，所以该接口不符合本项目的追新策略。

| 架构 | 官方压缩包 | 发布 API 提供的 SHA256 |
| --- | --- | --- |
| amd64 | `Xray-linux-64.zip` | `1eb9175d0f0a8f8149c9230a7fc5ae66ce332ed20a53155ce61fe62e3f58b7df` |
| arm64 | `Xray-linux-arm64-v8a.zip` | `3e38d72dfc5eb65c91df0e5583e9b6676c32232041da47de6ae73946b526d66c` |

这些摘要来自官方 API 元数据，本轮没有下载并重新计算上述二进制压缩包的摘要，也没有运行 `v26.9.9`。实施者必须下载实际资产、校验摘要、核对 `xray version` 后再执行验收。

本轮将 tag 源码的 `infra/conf/transport_internet.go`、`transport_security.go`、`transport_method.go`、`vless.go` 和 `transport/internet/splithttp/dialer.go` 与技能 `source/` 对应文件比对，五个文件完全一致。配置结论可追溯到这些文件；CLI 命令输出另核对同一提交的源码。[S2]–[S5]、[S8]、[S12]–[S14]

### 2.5 本轮补充的 ECH 与客户端研究

已查阅 XHTTP 主讨论 #4113、分享规范 #716、ECH 讨论 #5033/#5999 及相关 PR/故障报告，逐项对照目标源码；来源和适用边界集中在 [参数契约 §7–9](PARAMETERS.md)。新增的关键结论为：

- v26.9.9 的 TLS/XHTTP `auto` 实际为 `packet-up`，部分旧维护者示例已不代表该版本默认；REALITY 的 auto 规则另有区别。
- `echForceQuery` 已移除，配置 ECH 后获取失败不能透明降级；缓存可能在到期后使用旧值并异步更新，必须测试长期闲置与真实轮换。
- 固定 REALITY 依赖对初始 ClientHello 的 X25519MLKEM768 key_share 有要求，应作为三端客户端兼容门槛；它不等于所有 target 都必须协商 PQ。[S15]、[S16]
- 已核对 v2rayNG/v2rayN 指定提交的 URI→运行配置 ECH 流向；用户实际安装版本尚未验证。NAS 需要原生 JSON 与准确镜像版本。
- 当前环境对 AliDNS 域名/IP 入口执行 HTTP/2 POST DNS wire 查询均取得共享名的 ECHConfig；没有执行用户域名的强制 ECH 握手，也没有取得中国大陆各接入网络的可达性证据。

据此确定：普通 CDN 保留，可选 ECH 变体先认证节点 3；AliDNS 为可替换的首轮候选，真实域名查询优先、共享名为显式备选。资料不足以认定 Cloudflare ECH 在大陆被统一封锁或密码学攻破，也不能承诺本项目当前导出的 ECH 已稳定可用。

## 3. 产品决策与最新版核心契约

### 3.1 先明确支持集合

| 范围 | 首批目标 | 放行原则 |
| --- | --- | --- |
| 主路径 | 现有节点 1–5 | 五类全部通过真实客户端与端到端验收，才统一称为受支持 |
| IPv6 | 节点 6、7 | IPv6 实际可达，节点 7 保持 CDN 上行，只把 Reality 下行改为 IPv6 |
| H3 | 节点 8、9 | 正确配置、可信证书、nginx 能力、UDP 可达及客户端 H3 支持均有证据 |
| 系统候选 | Debian 13 amd64/arm64、Ubuntu 24.04 amd64 优先 | 逐组合列出通过情况；本机 arm64 运行旧版本不是新版本 arm64 安装证明 |
| 扩展系统 | Debian 12、Ubuntu arm64 等 | 完成相同门槛后再列入正式支持；不能只凭 `ID_LIKE=debian` 宣称支持 |
| 客户端 | Android v2rayNG、Windows v2rayN、Debian NAS 的 Xray-core Docker；`v26.9.9` 原生客户端作为本轮参照 | 记录应用/核心版本与导入方式；Docker 另记镜像 digest、网络和卷。未适配的组合如实列为待支持 |

实际客户端种类已由用户确定，不再要求重新选择。准确应用版本、内置核心版本及 Docker 镜像身份在测试设备上读取并填表；它们不阻塞计划和默认路径修复。首批没有验证的客户端和可选节点，不进入支持声明。

### 3.2 新安装的推荐默认值

以下是本计划的产品建议，尚未修改当前代码。**已有节点保留原状态，不因默认值调整自动关闭功能或轮换凭据。**

| 选项 | 推荐决策 | 理由 |
| --- | --- | --- |
| Xray 核心 | 当前接入 `v26.9.9`；默认新装/显式升级选择最新官方发布，包含预发布；单次操作锁定 tag/commit/摘要 | 同时满足追新与可复现；CI 使用相同解析器和下载路径 |
| Reality + Vision | 保持现有基础组合与鉴权失败回落过滤 | 已有架构不需要为参数更新整体改写 |
| XHTTP | 保留 `mode=auto`；CDN TLS 基础路径采用 H2，新装省略整块 `xmux` | v26.9.9 的 TLS auto → packet-up，xmux 整块默认已变化；不套用旧讨论中的默认值 |
| VLESS Encryption | 在首批支持它的 Xray 客户端集合中保留开启 | 当前默认已开启；必须验证四类 XHTTP 链路的服务端 decryption 与客户端 encryption 配对 |
| 不支持 Encryption 的客户端 | 使用显式兼容选择，服务端与客户端一起改变 | 不能只把某条 URI 改成 `encryption=none`，让它连接仍要求加密的同一个入站 |
| WARP | 新装默认关闭，按需求显式开启 | 注册和隧道可达性独立验收，避免影响基础节点安装 |
| 网络优化/第三方内核 | 新装先用发行版内核；网络优化默认关闭，Joey 内核显式选择 | 先建立可重复的基线，再验证性能收益和重启恢复 |
| ECH | 新装默认关闭，增加显式的 CDN ECH 导出变体；旧状态保留原选择 | 先验证节点 3；配置非空只显示已配置。查询/握手失败不在同一 ECH 连接自动改成普通 TLS |
| xpadding 混淆、ML-DSA 签名 | 继续不作为默认必开能力 | 客户端、版本与组合验证完成后再开放对应承诺 |
| H3/IPv6 自动导出 | 只导出满足已认证条件的组合 | 若某组合暂未认证，显示原因并暂停其默认导出，不把“生成成功”包装成“可用” |
| 证书 | 生产优先 ACME 公网证书或适合当前路径的已有证书 | Origin CA 可用于 CDN 回源；H3 直连必须另外满足普通客户端信任条件 |

自签证书与 Cloudflare Full 的现有选择可以保留，但应准确标注适用路径；`v26.9.9` 会拒绝 `allowInsecure=true`，直连必须满足相应的证书验证条件。[S2]

### 3.3 “最新参数”的维护契约

**确定采用：最新官方发布，包含预发布；当前起点为 [v26.9.9](https://github.com/XTLS/Xray-core/releases/tag/v26.9.9)。** 不再以“正式版缺什么能力”作为接入预发布的前置问题。

每份验收报告及每次安装/升级记录一个准确组合：

```text
xtun commit + Xray tag/commit + 架构与下载摘要
+ 参数配置修订 + 官方来源版本 + 客户端应用/内核版本
+ 已验证的系统、节点和可选功能 + 验证日期
```

默认版本选择与可复现记录分别实现：操作开始时发现最新版，随后所有步骤共用本次解析结果。显式指定 tag 用于复现和回退；下载失败、摘要异常或不兼容时清晰失败，不静默改装旧正式版。已在运行的机器通过显式升级命令更新核心，安装定时器替用户自动更新生产服务不在本计划范围内。

维护已建立的 [docs/PARAMETERS.md](PARAMETERS.md)，按实测建立 `docs/COMPATIBILITY.md`；这些文档不放进运行时归档。参数表逐项记录完整 JSON 路径、服务端/客户端归属、required/recommended/optional/default-kept、双方匹配关系、目标核心版本及官方出处；实施者补充导入与运行证据。

本次已核对的几个边界：

| 字段/行为 | 规划要求 |
| --- | --- |
| `realitySettings.target` | 现有生成器指向本机 2444 过滤入口是有意设计；用户设置的远端 `REALITY_TARGET` 由 dokodemo 连接，不要机械替换成直接 target |
| REALITY ClientHello | v26.9.9 锁定依赖要求初始 key_share 有合法 X25519MLKEM768，并在可选 X25519 之前；实际核心/fingerprint 需验证，目标站 PQ 与 ML-DSA 另行判断 |
| `password` / `publicKey` | `v26.9.9` 同时接受，非空 password 优先；原生参照配置采用 password。分享 URI 仍按客户端规范使用 `pbk=`，嵌套 extra 中的别名按导入实测选择，不同时写两个可能冲突的值 |
| VLESS `clients` / `users` | `v26.9.9` 支持 users 并兼容 clients；clients 非 null 时覆盖 users，空数组也会覆盖。新生成的入站统一使用 users；同步修改 config 回读，只写一种结构，保留旧 clients 读取与 UUID |
| `raw` / `tcp` | 核心别名与 URI 类型名称分别处理；无需为了名称更新强制用户重新导入 |
| TLS ALPN | TLS 字段写在 `tlsSettings`；H3 分离下行使用该层的 `["h3"]`，不能写到 stream 根部 |
| XHTTP `downloadSettings` | 按独立 StreamConfig 审查地址、安全层、路径与可选参数；特别检查两侧是否被 URI 导入器保留 |
| XHTTP `mode=auto` | 该版本 TLS → packet-up；REALITY 无 downloadSettings → stream-one，有 downloadSettings → stream-up。导入后核对实际模式，不照搬旧主讨论中的 TLS/H2 说明 |
| `xmux` | `v26.9.9` 整块零值/省略时为 maxConnections=3、hMaxRequestTimes=600–900、hMaxReusableSecs=1800–3000。部分非零设置绕过整块默认；maxConnections 与 maxConcurrency 的上限不能同时为正。新装省略整块，现有 `16-32` 作为旧项目配置保留迁移记录 |
| `allowInsecure` | `v26.9.9` 保留 JSON 字段解析，但 true 会触发 removed-feature 错误；false 或省略可用。URI 的 `insecure=0/allowInsecure=0` 是导入器约定，最终 JSON 必须保持证书验证 |
| ECH | TLSConfig 有 `echConfigList`、`echSockopt`，没有 `echForceQuery`；配置非空即走强制 ECH 语义。停用旧 force 入口且兼容读取旧状态；按 CDN 所在 TLS 层导出，不向 REALITY/直连 H3 注入 Cloudflare 配置 |
| xpadding | 检查每个开放选项是否进入服务端与实际需要匹配的客户端层；包含 split 内外层和 H3，不以“状态里有变量”当成功证据 |
| `mldsa65Seed/Verify` | 签名与普通 Reality 可用性分开。目标证书链长度大于 3500 字节用于签名准备度，不能变成所有普通节点的新装硬门槛 |

以上来源见 [S1]–[S5]、[S7]、[S8]、[S15]–[S17]。参数表同时区分“核心支持、xtun 生成、客户端导入、端到端通过”四个状态；任何新增非显然参数，先补官方证据与目标版本验证，再进入生成器。

### 3.4 后续追新的实施规则

1. **版本发现：** 使用官方 releases 列表，包含 `prerelease=true`，排除 draft。按 §7/C1 的分页和数值版本规则解析一次；不使用 `/releases/latest` 或 `/latest/download` 代表最新版。
2. **持续验证：** PR 保留当前 `v26.9.9` 的可复现基线；每日和手动触发的 latest 任务运行相同解析器、下载器和关键安装/配置/传输检查。一次任务内服务器与参照客户端使用同一 tag，报告显示准确版本。
3. **上游有新版：** 建立该 tag 的源码、默认值、命令输出与弃用差异记录，运行受影响检查及必要的旧节点迁移验证；通过后推进 CI 基线和兼容表，保留此前版本的验证记录。不能长期仅更新版本字符串而不审查生成参数。
4. **新装与升级：** 未进入静态基线清单的新 tag 仍可被 latest 策略选中，依赖下载完整性、候选配置和就绪检查决定操作结果；实际不兼容时失败并说明所需适配，已有服务恢复原版本。清单用于复现，不充当让版本永久停留在旧版的允许列表。
5. **可靠性标注：** 本轮首次生产验收执行 §10 的 72 小时与 7 天观察；后续每次上游发布执行必要回归和受影响链路检查，不要求每次等待 7 天才能追新。运行报告分别标注功能验证与已观察时长，旧版观察记录不转算给新版。

最新任务失败必须在 CI 和版本报告中可见，不能通过忽略错误、改测旧核心或自动删去不兼容字段来维持“支持最新版”的声明。

## 4. 总体执行顺序

| 阶段 | 交付 | 退出条件 |
| --- | --- | --- |
| A：v26.9.9 接入、追新与 CI | 共享版本解析/下载、目标核心验证、1.1.1 发布准备 | 两个现有 CI job 对同一候选提交和同一核心成功；默认发现包含预发布 |
| B：新装与导出正确性 | F02–F08 修复及定向回归 | 默认预检能跑，CLI 不吞参数，导出路径与名称一致 |
| C：参数迁移与分发契约 | users/xmux 迁移、ECH 变体、NAS 原生 JSON、兼容表和产物一致性 | 参数按目标核心生效，旧节点凭据不变，分发与验收可追溯 |
| D：维护与失败恢复 | 事务补齐、证书与升级恢复 | 故障注入证明核心配置/state/链接保持一致 |
| E：完整验收 | 产物安装矩阵、客户端和真实链路报告 | 所声明的五类节点与可选组合逐项通过 |
| F：持续运行与正式发布 | 新 VPS 验收记录、运维手册 | 持续运行与重启演练达标，正式版本对应已验证提交 |
| G：能力演进 | PQ 观察、签名或其他协议的独立提案 | 不影响已经建立的发布门槛 |

建议把后续 `1.2.0` 定位为生产就绪版本，先做候选版本验证；版本号以最终交付范围为准。当前 PLAN §3.1 的 SNI 正确性修复进入 B，§3.2 的 PQ 观察放到 G；普通客户端兼容性进入 C/E，签名兼容性仍留在 G。

F02/F04 和最新版策略缺口 F12 都是本轮 P0，必须进入最近的修复版。A 可以先形成绿色提交供后续开发，正式打 `1.1.1` tag 要等 B 中这些 P0 修复完成并重新验证最终 SHA。`v26.9.9` 接入是 A 的必做项，不留到 PQ 调查阶段再决定。修复版交付与 §10 的生产推荐门槛分别记录。

## 5. 阶段 A：接入 v26.9.9 与追新机制，恢复 CI

沿用当前 [PLAN §2](PLAN.md) 的 CI 修法，并把核心接入作为同阶段工单 T01 的组成部分。不重复实现已完成的订阅删除、PNG 导出或 bundle 签名修复。T01 可拆成脚本整理、共享解析/下载、目标核心 CI 三个小提交，最后联合验收。

1. 修改 `tests/cases_output.sh` 的 PNG 计数，保留数量、权限、旧图清理等断言，清除 SC2012。
2. 新增 `tests/install-smoke.sh`，把 YAML 内层安装脚本移出；工作流仅负责启动、调用、收集现场与销毁容器。
3. 输出先完整捕获再匹配，避免管道提前退出；保留实际 qrencode 安装和真实 PNG 生成断言。
4. 提前执行 §7/C1 的第 1–5 项：共享 baseline/latest 解析与下载实现、显式 tag 复现、同次操作版本锁定及真实摘要校验。将 CI 原有 `v26.3.27` 常量替换为共享的 `v26.9.9` 基线；安装 job 也使用同一解析结果，不能只更新离线 job 的下载地址。
5. 在独立临时目录用目标二进制验证 `version`、`x25519`、`vlessenc` 及服务端/参照客户端 `run -test`；测试传入实际候选 `XRAY_BIN`，不得误用宿主机的旧核心。添加预发布选择、版本跨月比较、API 变化及摘要失败的定向用例。
6. `v26.9.9` 的 x25519 源码输出为 `PrivateKey`、`Password (PublicKey)`、`Hash32`，现有公钥解析分支已涵盖该标签；用真实目标二进制验证后保留兼容的实现。vlessenc 会输出两组完整认证方案，应保证选中的 decryption/encryption 属于同一组；本轮保持现有第一组 X25519 认证选择。[S13]、[S14]
7. 让新增脚本进入现有 ShellCheck 和 `bash -n` 检查；记录所有旧用例与新增用例结果。接入每日/手动 latest 检查，完整传输层随后由 T10 扩展；此时 latest 解析必须已经包含 `v26.9.9`。
8. 更新入口和 README 的版本信息，确认运行时归档包含 `xtun.sh/lib/static` 及共享版本模块，不依赖 tests/docs/技能目录。
9. 提交、推送后核对 CI 的 `head_sha` 和实际 Xray tag。先交付绿色验证基线，待 T02/T03 的 P0 修复及拟纳入修复版的其它改动完成，再在两个 job 都通过的最终 SHA 上创建新 tag；不移动现有 `v1.1.0`。

**验收：** 完整 smoke、ShellCheck、安装脚本语法、`v26.9.9` 真实容器安装全部成功；默认版本解析选中最新预发布，指定 tag 能复现，两个 job 的核心一致。发布说明准确表述为目标核心接入与缺陷修复，不提前宣称已通过本计划后面的生产验收。

## 6. 阶段 B：修默认安装路径和节点语义

建议拆为“安装/SNI”和“导出/证书能力”两个独立 PR。

### B1. 安装输入与最小依赖

涉及 `lib/cli/install.sh`、`lib/install/input.sh`、`lib/install.sh`、`lib/base/env.sh` 及 CLI 测试。

1. 将 `--no-ipv6` 作为不取值的开关解析，拒绝误吞后续参数。
2. 在安装请求中区分“未指定、显式禁用、指定 IPv6”；显式禁用后不得被自动探测重新填回。明确与 `--server-ip6` 同时出现时的优先级，并测试两种顺序。
3. 梳理输入生成和预检调用前的工具依赖，增加最小引导依赖阶段；缺工具时先准确处理，随后才生成随机值或发起 TLS 检查。不要让容器测试预先安装全部依赖来掩盖缺口。
4. 基础环境检查覆盖 systemd、发行版版本、架构、可写空间、APT 状态与端口占用；现有 nginx/haproxy 服务的存在不能直接当作已由 xtun 托管的证明。
5. 输入格式错误尽早退出。第三方下载和探测都有有界超时，错误区分缺依赖、DNS 失败、远端拒绝和不兼容。

**验收用例：** `--no-ipv6` 单独、位于其它开关前后、与显式 IPv6 冲突；机器有 IPv6 但要求禁用；最小镜像缺 openssl/iproute2；已有非托管 443 服务；非法参数不得进入配置写入和服务变更。

### B2. SNI 预检正确性

涉及 `lib/cli/sni.sh` 与 `tests/cases_sni.sh`。沿用探测、纯判定、汇总三层，不另造探测框架。

1. 先完成参数解析与必要状态读取，再决定 SNI/target/server IP。显式参数优先；无参数检查已保存的 SNI 和真实远端 target；显式新域名不沿用旧节点无关的 target。
2. HTTP 探测改用 `curl --connect-to` 连接实际 target host/port，同时保持 URL 的 SNI/Host；不再把主机名塞入 `--resolve` 的 IP 项。TLS、证书和 HTTP 遵守同一目标。
3. 拒绝零、全零、负数和非数字 timeout，规范化正数前导零。DNS 探测也应有预算；帮助区分单次探测预算与整条命令可能的总时长。
4. 保留当前支持的 target 地址语法，暂不顺带扩展 target 的 IPv6 解析；节点 IPv6 导出与远端 target 格式是不同工作。
5. 检查相对重定向的主机判断；不要把证书签发机构等同于 CDN 识别结果。把协议必需条件、项目选择策略和性能建议分开表述，无法判断时显示未知或告警。
6. 独立保留 `--skip-sni-check` 的显式跳过能力，但发布验收必须包含不跳过的默认路径。

**验收：** 已安装无参数入口；只有 config 可回读；显式域名/target/server IP 覆盖；目标域名和目标 IP；8443 等非默认目标端口；0/000/01/负数/文字超时；相对跳转；所有失败原因可辨认。单元测试使用探测桩，再用独立测试环境的真实域名补一次默认流程验收。

### B3. H3、IPv6 与证书能力

涉及 `lib/ui/output.sh`、`lib/ui/core.sh`、证书辅助函数、`tests/cases_output.sh`、`tests/cases_nginx_net.sh`。

1. 将 H3 split 的 ALPN 放到 `downloadSettings.tlsSettings.alpn`，去掉根部错误字段。验证外层 CDN 仍使用 H2。
2. 修复节点 7：外层 URI 地址仍为 `XHTTP_DOMAIN`，仅 Reality downloadSettings 指向 VPS IPv6。URI authority 的方括号与 Xray JSON 地址格式分开验证。
3. 证书能力按内容判断：证书和私钥配对、覆盖域名、有效期、完整链、普通客户端可验证的信任链。`CERT_MODE=existing` 只是输入方式，不是信任证明。
4. 区分“nginx 有 H3 模块”“配置已启用”“UDP 正在监听”“外部客户端实测可达”。缺任意必要条件时，不宣称 H3 已可用；不要自动添加不安全的证书绕过。
5. 检查启用 xpadding 时，H3 直连和分离下行是否携带服务端要求的同组参数。暂不能证明的组合暂停导出或明确列为待认证。
6. 保持 `node_link_entries` 是文本、链接和 PNG 的共同来源；一处过滤某节点后，所有输出中的名称、数量、位次与文件均应一致，旧图不得继续误导用户。

**验收：** 解码每条 URI 的 query/extra，检查完整内外层地址、ALPN、SNI、UUID、路径与 Encryption；测试公网可信证书、Origin CA、自签证书、域名不符、过期、链不完整；分别覆盖无 IPv6、仅 IPv6 变体、仅 H3、二者同时启用。H3 最终验收还必须证明实际 UDP 路径，不能只看字符串。

## 7. 阶段 C：参数迁移、核心版本与分发契约

### C1. 版本解析、下载与运行时产物

涉及 `xtun.sh` 的 bootstrap、`lib/install.sh`、`lib/install/self.sh`、安装/升级 CLI 与 CI。新增小型 `lib/base/versions.sh` 或等价公共模块，统一版本规则与解析结果。**第 1–5 项随 A/T01 提前实施**；第 6–9 项由 T06 补齐分发记录与完整性，应用后的恢复由 T08 负责。

1. **分离选择策略和基线。** 共享模块记录 `baseline=v26.9.9`、对应两架构摘要以及 `default=latest-published`。baseline 供可复现 CI 使用，不能成为新装永久默认版本。规划新增 `--xray-version <tag>`，在安装和核心升级入口统一支持，帮助说明它用于明确指定版本；这是待实现接口，当前不能直接照抄执行。
2. **完整发现最新版。** 默认读取 `/repos/XTLS/Xray-core/releases?per_page=100`，跟随分页，包含所有非 draft 正式版及预发布。当前 tag 以 `v<整数>.<整数>.<整数>` 的数值三元组比较，正确处理 `v26.9.9` 到 `v26.10.1`，不按字符串、更新时间或列表第一项选择。若分页/限流/总时间预算使结果不完整，或出现更新但规则无法识别的版本命名，应失败并说明，不能悄悄挑旧版本。先确定最新 tag，再检查当前架构资产；资产缺失不得导致降级选取。
3. **解析后固定本次上下文。** 获取所选 tag 的 release 元数据与 tag 指向的提交；annotated tag 要解析到 commit，不把 `target_commitish=main` 当固定 SHA。记录 tag、commit、prerelease、架构、资产名/ID、准确 URL、期望摘要和解析时间。该操作中的安装器、密钥生成、配置校验和参照客户端共用此结果；不在各阶段重新请求 latest。显式 tag 跳过动态选择，但执行相同完整性校验。
4. **校验实际下载。** amd64 对应 `Xray-linux-64.zip`，arm64 对应 `Xray-linux-arm64-v8a.zip`。优先使用该 release API 的 SHA256，必要时解析同 tag、同资产 `.dgst` 的明确 SHA256 记录；两者都有时冲突即失败。v26.9.9 基线同时与 §2.4 记录比对，未来基线使用对应版本记录。所有下载都使用固定 tag/资产 URL，下载后重算摘要并核对候选 `xray version`；二进制与包内资源来自同次下载，不使用 `/latest/download` 补缺件。
5. **验证失败不碰运行版本。** 连接/总超时、有限重试和临时目录清理统一实现；API 不可达、资产缺失、摘要异常、版本不符、必要命令/配置不兼容均清晰失败。新装不静默回退旧正式版；升级在候选准备/验证成功前保留旧核心。全新的 tag 不因未登记在静态基线表中就被拒绝，实际校验失败才返回具体原因。
6. **记录实际产物。** 安装后保存 tag、提交、二进制版本、包摘要及 geoip/geosite 资源摘要；诊断显示当前版本和上次操作结果。Geo 数据是当前 private/WARP 路由的运行依赖，必须与核心一起进入备份与恢复集合。SHA256 是完整性核验，报告不把 API 摘要描述成独立签名验证。
7. **固定 xtun 产物身份。** 入口脚本与后续 bundle 指向同一个已发布 ref/commit。只把 README 的 raw/main 改为 raw/tag 不够，还要处理 `BOOTSTRAP_BRANCH_REF=main` 默认值。xtun 自身的 ref 固定与 Xray 核心采用最新发布是两项不同的版本规则。
8. **完整准备自更新。** bundle 先准备并校验入口和运行文件，再切换；不能先删除正在使用的 bundle 后逐个复制而没有恢复路径。共享版本模块必须包含在实际 runtime archive 中。
9. **显式升级与回退。** 默认升级使用本次发现的最新 tag；显式指定较旧 tag 的降级必须通过对应配置兼容验证。失败自动恢复到这台机器实际的上一套可用快照；恢复二进制时也恢复配置、资源、state 和输出，不能用旧核心强行启动已经迁移为 users 的新配置。

**解析与下载验收矩阵：**

| 输入或故障 | 必须结果 |
| --- | --- |
| 正式版 v26.3.27 + 预发布 v26.9.9 | 默认选 v26.9.9；两个现有 CI job 可显式复现同一版本 |
| 乱序列表、跨页、v26.9.9/v26.10.1、最新项为 draft | 完整分页后按数值版本选最高非 draft；忽略 draft |
| 操作中途又发布新版 | 当前操作继续使用已锁定 tag；下一次新操作发现新版 |
| 显式指定 v26.9.9，但已有更新版 | 安装所指定版本并记录显式选择；默认策略仍是 latest-published |
| API 限流/不可达、分页未完成、元数据无效 | 可解释地失败，不使用缓存旧版冒充最新版 |
| 最新版缺当前架构资产、摘要缺失/冲突/不符、二进制版本不符 | 不切到更旧 tag，不应用候选文件 |
| 新 tag 未录入静态基线表但资产、命令、配置均通过 | 可继续安装/升级；报告该 tag 的实际验证范围 |
| amd64/arm64，bootstrap/runtime archive，升级应用后失败 | 资产与入口准确，公共模块可用；T08 证明旧核心、资源、配置和链接完整恢复 |

### C2. 参数与客户端契约

1. **落实参数与节点清单。** 以 [参数契约 §2–4](PARAMETERS.md) 为节点 1–9 的独立预期，逐项核对外层/下行地址、安全层、UUID、Encryption、SNI、路径、ALPN 与依赖条件。不能从同一个生成器计算测试预期。
2. **迁移 VLESS 入站。** 修改 `lib/generators.sh` 的两处入站生成，采用 `settings.users`；同步 `lib/state.sh` 的 Reality/XHTTP UUID 回读。回读必须遵循核心的 clients 优先规则，不能在有效 clients 存在时取另一个 users；只有 users、只有旧 clients、两者共存/冲突、clients 为空数组、状态丢失等均有明确处理。异常或空用户集不能静默生成新 UUID。保留原 UUID、flow 和 decryption。旧节点只更新 bundle 时保持原配置；重新生成配置前检查实际核心，未达到新模板要求时在写入前提示先显式升级。核心升级用候选二进制验证新结构，再由 T08 一起切换核心和配置，避免旧核心读取新结构。
3. **明确 Reality 字段边界。** 原生参照 JSON 使用 `realitySettings.password`；旧 publicKey 可读，二者冲突不双写。URI `pbk=` 保留，嵌套别名按真实导入结果确定；保持本机 2444 回落过滤结构。为所有 REALITY 组合增加 v26.9.9 初始 ClientHello 的 key_share 兼容检查，不能只根据 GUI 的 chrome 标签放行，也不把这一要求误加到远端 target 的 PQ 观察上。
4. **采用目标 xmux 默认。** 新装导出省略整块 xmux，使 `v26.9.9` 使用 maxConnections=3、hMaxRequestTimes=600–900、hMaxReusableSecs=1800–3000；检查每个 extra/downloadSettings 层，没有遗留的部分非零覆盖。旧安装按配置修订标识保留原有 `16-32` 等显式输出策略，新装默认不追溯覆盖旧策略；已有 state 无修订键时按历史策略迁移。整个 state 丢失时，UUID 可从 config 回读，但客户端专用输出策略需从备份或原输出恢复；无法确定时明确报告，避免误判修订。以后启用调优配置必须记录完整有效值、来源和同条件测量结果。
5. **落实 ECH 决策。** 按 [参数契约 §5–6](PARAMETERS.md) 停用 `--xhttp-ech-force-query`，显式传入给出停用错误，旧 state 保留兼容读取。校验 DNS 来源/标准 Base64 格式和 URI 编解码，ECH 仅在 CDN 所在 TLS 层输出；AliDNS 为可替换候选，真实域名优先、共享名显式选择。保留旧来源和强制 ECH 失败语义；`echSockopt` 另行验证，不机械承接旧 force 值。
6. **验证 TLS 与命令语义。** 使用 `v26.9.9` 及 latest 任务所选核心检查服务器和参照客户端配置；断言 `allowInsecure=true` 不被当作支持能力、false/省略正常，H3 ALPN 位于正确层。x25519/vlessenc 解析输出完整性和成对关系必须覆盖未知格式、缺字段和失败；不得因输出顺序变化交叉选取两套 Encryption 凭据。
7. **完成参数流向审查。** 对其余开放选项逐项检查 CLI → 状态 → 服务端 → URI/extra → 客户端；未知字段可能被忽略，`run -test` 通过不能替代语义及链路验证。高级选项的缺省不随核心升级被自动开启。
8. **控制已有节点迁移。** 新默认值只作用于新安装；apply-config、续证、核心升级不得顺便轮换 UUID、密钥、路径、Encryption 或开启可选功能。对于 default-kept 参数，上游升级可能改变实际取值，必须列入版本差异与验证记录。新增版本元信息/参数修订键时同步白名单、读写、缺省、迁移和回滚；只有状态兼容语义确实变化才调整 `STATE_VERSION_CURRENT`。
9. **提供三端可用产物。** 在同一节点语义上实现 URI/PNG/原生客户端 JSON；新增显式 ECH/plain 导出变体，保持旧编号、默认五张 PNG 和旧 state 意图。导出覆盖值不自动改全局状态或重启服务；NAS JSON 包含正确凭据和可验证运行结构，不让用户自己翻译 URI。
10. **按证据输出 ECH 状态。** 已配置、取得记录、该客户端网络的握手/传输通过分别显示；服务器查询结果不能替代客户端查询。普通菜单提供简明下一步，诊断保留查询、格式、握手与 CDN 错误原因；按验收手册执行冷启动、轮换与人工操作测试。

**参数迁移验收：** 仅更新 bundle 且核心仍旧、旧 clients 配置 → v26.9.9 users 配置、仅 config 可回读、迁移中失败恢复、旧链接凭据持续可用；新安装没有部分 xmux 覆盖、旧状态按旧修订输出；无效 ECH 参数不再显示成功；五类参照配置与实际 URI 的内外层含义一致。早期核心的回退必须使用迁移前快照，不能只换二进制。

**客户端报告至少包含：** 平台、应用/核心版本、导入方式、关键字段保留、五类节点连接、双向内容与 split 路径、可选能力和日期。v2rayNG/v2rayN 分别记录 URI 与真实 PNG；NAS 记录 JSON、镜像 digest、网络/DNS/卷。ECH 补充来源、正负握手用例、缓存/轮换与实际接入网络，原生参照不能替代 GUI 导入。

## 8. 阶段 D：补齐生命周期和失败恢复

### D1. 托管变更一致性

优先完善 `lib/base/runtime.sh`、`lib/change/commands.sh`、`lib/change/workflow.sh` 的现有公共流程；避免一次性重写整个 shell 项目。

1. 列出每个命令的变更集合：配置、证书、state、output、核心及资源、bundle、systemd 文件。每次操作开始时记录路径原先是否存在；同一事务只保存第一次快照，防止把已修改内容覆盖进“旧备份”。
2. 候选文件在临时位置完成生成与可行的校验，再进入应用阶段。必须在日志中区分“准备、应用、检查、提交、恢复”，不把多文件逐个 `mv` 描述成真正的整体原子事务。
3. 配置、状态和文本链接属于同一次变更。任一必要写入、权限设置、校验、服务应用或就绪检查失败，都恢复该命令的完整必要文件集合，并验证旧服务恢复。
4. 将 `change_uuid_cmd` 接入与其它变更一致的恢复路径；补 `finalize_installation`、`apply_managed_files`、`apply_xray_only_managed_update` 中 state/output 失败的恢复，不能只补返回码。
5. 核心升级在覆盖前准备好二进制、资源与权限，并用本次所选候选核心校验必要配置和命令；下载/解包/资源复制/setcap 的后半段失败也要恢复，不限于 `validate_configs` 或 restart 失败。同步恢复版本元信息与参数修订，特别覆盖旧 clients 配置升级成 users 后的失败窗口。
6. Xray 的 `Type=simple` 启动命令返回成功后，还要在有界时间内确认服务持续 active、监听正常、基础探测成功。应用失败的原因和恢复结果分别记录。
7. 继续维持“PNG 是派生物”的约定：编码失败只告警，不因此回滚已经成功的节点配置。但旧图不能冒充新凭据，输出应准确报告可用链接和未生成的图。
8. 记录恢复范围：文件与服务恢复不等于撤销 APT 包安装、已注册 WARP 设备、ACME 远端签发或内核安装。第三方内核单独作为显式操作验收，不承诺文件回滚即可撤销它。

**必须注入的故障：** 生成配置失败、state 写失败、output 写失败、证书提升失败、核心资产复制失败、setcap 失败、nginx/haproxy 校验失败、Xray 启动后退出、服务恢复失败、操作中断、磁盘空间不足。使用沙箱/一次性 VM，不在现有生产机注入。

**断言：** 失败命令返回非零；不打印“已完成”；成功恢复后文件和有效凭据均为旧一代；恢复失败明确报告现场和备份位置。不要只测试“rollback 函数调用过”，还要比较文件内容、版本和可用链路。恢复的是操作前该机器实际可用的组合，并记录“请求升级到什么版本、最终运行什么版本”；不能把恢复报告成“最新版安装成功”。

### D2. 证书自动续期与诊断

涉及 `lib/install/certs.sh`、`lib/ui/core.sh`、`lib/cli/core.sh`。

1. 让 ACME 自动 reload helper 与手动证书更新遵守同一份证书验证和锁约定；自动钩子目前直接提升文件并重载 nginx，需要单独纳入失败演练。
2. 新证书必须配对、覆盖域名、处于有效期内，所需链完整；提升后先验证 nginx，再重载并确认实际服务证书已更新。
3. reload/健康检查失败时恢复原证书文件并报告失败；证书和私钥不能一新一旧。续证失败不应让原来的可用证书立即失效。
4. 用 ACME staging 或受控签发环境验证自动调度、续期钩子、重启后调度仍存在；生产验收再检查最终证书链。只测试 `renew-cert` 手动入口不算自动续期已验证。
5. `local_tls_probe_state` 增加有界超时；诊断区分本地握手、源站证书适用性、CDN 边缘证书和真实节点连接。自签/Origin CA 的本地检查不能直接套公网客户端信任规则。
6. 保持菜单轻量；深度网络检查由显式诊断或验收任务触发。暂不引入自动切换 SNI、自动换核心或循环重启服务的后台“自愈”。

**验收：** 模拟证书即将到期、过期、错误 SAN、错配私钥、reload 失败、并发改配置与自动续证；旧服务恢复，真实对外证书指纹和到期时间符合预期。证书刷新仅按需要操作 nginx，不无故重启 Reality 服务。

## 9. 阶段 E：建立有实际证明力的验收

### E1. 分层测试及其证明范围

| 层次 | 实施内容 | 能证明什么 |
| --- | --- | --- |
| L0 静态检查 | 所有 shell 语法、ShellCheck、工作流中的 shell | 语法与常见 shell 错误 |
| L1 离线回归 | 现有 smoke，加真实缺陷的输入、导出和恢复用例 | 单函数及编排约定 |
| L2 目标核心检查 | `v26.9.9` 基线与 latest 任务所选核心分别校验服务器/参照客户端 JSON、命令输出及关键字段语义 | 明确哪个核心接受配置，避免版本漂移或字段漏写/错层 |
| L3 产物与服务安装 | 一次性 systemd 容器，从单文件/bootstrap 和 runtime archive 安装 | 依赖、归档、服务和本地集成 |
| L4 原生客户端传输 | 独立 Xray 客户端与服务器使用同次任务的目标 tag，通过每条节点连接受控测试端点 | 鉴权、上下行、传输及路由组合 |
| L5 真实环境 | 独立 VPS、真实 Cloudflare 橙云、真实 GUI 客户端 | 公网可达、CDN 行为、导入兼容与实际使用 |
| L6 生命周期 | VM 重启、升级、故障恢复、续证、持续运行 | 运维和长期稳定性 |

容器共用宿主机内核，不能验证安装内核后的真实启动；模拟 CDN 也不能证明 Cloudflare 边缘正常。L3/L4 的结果应说明使用了哪些桩和测试例外，L5 必须检验原样生产产物。

CI 按以下三组落地，共用解析器、下载校验和配置生成路径：

| 任务 | 触发和目标 | 必须输出 |
| --- | --- | --- |
| baseline | PR/提交；本轮准确 tag 为 v26.9.9，amd64/arm64 均有对应检查 | L0–L4 结果、xtun SHA、tag/commit/资产摘要；架构若仅下载校验则如实标注，不能算原生运行通过 |
| latest | 每日和手动；解析最新非 draft 发布，包含预发布；发布候选前再执行一次 | 相同关键安装/配置/传输检查及准确版本；失败可见，不能用 continue-on-error 掩盖 |
| migration/rollback | 核心/参数/状态变更时；上一套已验证组合到目标版本 | UUID/密钥保留、users/clients 回读、资源/state/输出恢复及旧链接实测 |

baseline 和 latest 解析为同一 tag 时可复用相同资产与传输结果，但版本发现和锁定用例仍须独立覆盖。latest 运行中若上游再发布新版，当前运行继续使用锁定版本，下一次触发再验证新版。后续基线按 §3.4 推进，不能永远只在 v26.9.9 上获得绿灯。

### E2. 五类主节点的端到端矩阵

| 节点 | 必须验证的链路 | 额外断言 |
| --- | --- | --- |
| 1 REALITY | 客户端 → HAProxy → Reality/Vision → 测试端点 | 正确 UUID/公钥/shortId 可用；错误凭据不能获得代理能力 |
| 2 XHTTP-REALITY | 客户端 → Reality 外层 → VLESS fallback → 本机 XHTTP 入站 | 使用 XHTTP UUID/Encryption，不能误连 Vision 用户后也算成功 |
| 3 XHTTP-CDN | 客户端 → Cloudflare → nginx → XHTTP | 证明经过 CDN，路径无缓存、重写、挑战或截断问题 |
| 4 CDN/REALITY split | 上行 CDN、下行 Reality | 两条路径确实分别建立；不能仅测共同的最终出口 IP |
| 5 REALITY/CDN split | 上行 Reality、下行 CDN | 同上，且验证反向分离时安全层及 downloadSettings 没丢失 |

对每种节点执行：

1. 从实际导出 URI 构建/导入配置，发送带随机标识的请求；测试端点回显标识，防止缓存或误走直连造成假通过。
2. 下载和上传固定内容（建议各 64 MiB），校验哈希；同时测短请求、并发请求、持续流和空闲后恢复。
3. split 用连接记录、测试代理计数或临时客户端日志证明两条路径；在隔离环境阻断其中一条，验证会出现预期失败，排除静默合并成单一路径。
4. 验证错误 UUID、错误 shortId/公钥、错误 XHTTP path，以及正常与异常 SNI 回落。保留当前 private 路由防护；不能通过修改生产模板允许任意私网流量让测试通过。
5. 若承诺代理 UDP，再独立验证 SOCKS UDP/DNS 等实际转发；H3 的外层 UDP 与被代理的应用 UDP 是两件事。Vision 对 UDP 443 的策略按目标版本单独记录。

实验室内的 TLS 目标、回显服务和模拟 CDN 使用受控 fixture。若为实验室网络配置了例外，只能证明对应传输层；不可把该结果替代未修改生产配置的公网验收。

### E3. GUI 客户端与 PNG

1. 首批 GUI 为 Android v2rayNG 与 Windows v2rayN；读取实际应用/内核版本，检查 XHTTP、Encryption、extra/downloadSettings、ECH 和 REALITY ClientHello 兼容性。原生参照使用 v26.9.9，不把“应用最新版”当成“内置核心已达标”。
2. 两款 GUI 的每条受支持节点分别通过复制 URI 和真实 PNG 导入。可增加 `zbarimg` 等测试依赖验证 PNG 解码后与 URI 逐字节一致；该检查不能替代应用的扫码/二维码图导入。
3. 检查导入后实际配置：UUID、密钥、路径、ALPN、Encryption、下载地址和安全层是否完整；客户端不展示字段时使用其可导出的运行配置或测试日志验证。
4. PNG 使用真实 qrencode 测默认长度、长合法路径/标签、ECH/xpadding 等已开放组合。超出编码能力时明确告警并保留文本链接，不输出损坏或截断的“成功二维码”。
5. 不支持某组合就记录不支持，调整客户端支持范围；优先更新客户端或使用支持的导入方式。服务端继续以最新版为目标，不通过关闭证书校验、丢弃 split、删除 Encryption 或悄悄降低核心版本把测试变绿。
6. Debian NAS 使用独立 Docker 测试实例与原生 JSON，记录镜像 digest、实际核心、bridge/host 模式、端口与 DNS。容器不能直接导入分享 URI，不要求 NAS 扫码；端口绑定与卷按 [验收手册 §4.3](TEST-VPS-RUNBOOK.md#43-debian-nas-的-xray-core-docker) 核对。
7. 按 [验收手册 §5–6](TEST-VPS-RUNBOOK.md) 检查 ECH 强制语义、正负用例、缓存/轮换、切网及用户操作。编辑后保存、改备注、重新导出导入均不能丢字段；浏览器 ECH 测试网页不能替代节点外层 ECH 验证。

### E4. 系统、证书与功能组合

不要求一次穷举所有开关的笛卡尔积，按依赖关系覆盖最容易相互影响的组合：

- 每个首批 OS/架构组合：全新镜像、公开入口安装、重复执行不乱改凭据、`apply-config`、重启、自更新及核心升级恢复。
- 证书：自签、Origin CA、公网可信 existing、ACME；分别验证 CDN 和直连适用性。
- 主配置接管：新装默认路径、显式不接管、存在自定义用户块、旧版本迁移。
- IPv6：禁用、有地址但不可达、可达、客户端仅 IPv4、修复后的 split IPv6 下行。
- H3：模块缺失、证书不合适、UDP 被阻断、可用；确认对 TCP 五类主节点的影响。
- WARP：关闭、注册失败、已有 profile、隧道不可达；开启时证明命中规则与非命中规则的出口正确。无需 WARP 的基础安装应能独立成功。
- 网络优化：关闭、发行版 BBR、显式第三方内核；第三方内核的安装和重启仅在可重建 VM 上验证。
- 高级组合：Encryption 开/关，ECH 与 CDN，xpadding 与每个公开提供的 XHTTP 内外层组合。

PR CI 跑可重复、无生产凭据的检查；真实 Cloudflare/客户端验收可以用单独的手动触发流程。真实凭据任务关闭 xtrace，报告和上传的配置脱敏，保留必要的版本、错误及路径证据。

## 10. 阶段 F：独立新 VPS 验收、持续运行与发布

### F1. 执行前置条件

准备独立可销毁 VPS、受控 CDN 域名、可用证书方式、Reality 目标和已确定的客户端。记录系统镜像、架构、虚拟化、CPU/RAM、网络限制、DNS/Cloudflare 设置。先建立发行版内核、关闭可选优化的基线。

具体执行采用 [测试 VPS 验收手册](TEST-VPS-RUNBOOK.md) 的 R0–R5；先完成普通五类节点，再验证节点 3 ECH 与各个可选 split 变体。Android/Windows/NAS 的实际版本和接入网络分别留证，单台 VPS 不代替整个系统/架构矩阵。

操作顺序：

1. 从待发布版本的公开安装入口安装，记录安装产物 commit、核心版本与摘要，不从工作树偷带未发布修复。本轮先显式复现 v26.9.9，再验证默认 latest 路径；两者若解析相同版本可合并传输验收，但两种选择路径都要有证据。
2. 默认 SNI 预检通过，基础服务和权限正确；2443/2444/8001/8443 保持本地绑定，对外仅开放设计要求的入口。
3. 用真实客户端逐条完成 §9 的五类节点测试；CDN、证书、split、可选节点分别记录，不能用伪装站 HTTP 200 替代。
4. 重复应用当前配置，确认 UUID、密钥和路径不意外轮换；进行显式 UUID/路径/SNI 变更，确认旧/新链接行为符合预期。
5. 重启 VM，确认开机服务、证书调度、监听和节点连接自动恢复。
6. 演练候选版本升级失败后的恢复，并再次检验旧链接；记录恢复所需操作和耗时。
7. 进行持续运行验证，再按报告决定是否放行生产声明。观察期间固定该实例的核心版本；若上游发布新版，另开验证运行，不替换正在观察的核心后继续累计旧版本时长。

### F2. 建议的首轮验收门槛

下面的数值是**项目拟定的验收目标**，不是 Xray 官方保证或本轮已完成的测试。执行前固定目标，不能测试失败后无记录地放宽。

| 指标 | 首轮目标 |
| --- | --- |
| 新装重复性 | 每个首批支持组合至少 3 次从干净环境完成安装，无需手改托管配置 |
| 核心节点 | 每个受支持客户端的 5 类节点均完成鉴权、双向传输、内容校验与路径验证 |
| ECH 可选能力 | 逐客户端/网络/节点通过配置保留、有效来源、强制 ECH 正负用例及缓存恢复；真实轮换未观察到时如实记录，不外推全国可用 |
| 交互与导出 | 两款 GUI 复制/扫码/编辑后保留字段，NAS 原生 JSON 可启动；错误能引导下一步，ECH/plain 选择明确 |
| VM 重启 | 每个受支持 VM 组合至少 3 次；网络就绪后 60 秒内恢复基础连接，超时有明确原因 |
| 恢复演练 | 必要故障用例全部返回准确状态，旧有效配置和链接可以恢复；恢复失败可定位 |
| 持续运行 | 首次候选组合至少 72 小时；同一组合累计观察至少 7 天后再标为长期使用推荐；后续追新按 §3.4 记录功能验证和观察时长 |
| 请求成功率 | 固定频率的受控小请求目标 ≥99.9%；发布由链路对照和失败归因共同判断，不能只报重试后的成功率 |
| 资源 | 无非预期服务退出/OOM；固定负载下 RSS、FD、连接数达到平台，不持续无界增长；日志轮转正常 |
| 凭据和输出 | 运行配置、state、文本链接一致；PNG 成功生成或明确提示派生物失败；日志/公开报告不包含密钥 |

有意注入的断网与外部目标故障单独记录，使用直连对照等证据归因。系统性故障不能以“网络波动”从统计中剔除。吞吐量仅在固定负载、相同机型与网络条件下比较，不承诺所有 VPS 的最优速度。

### F3. 正式发布与运维交接

1. 在 `docs/validation/YYYY-MM-DD-<candidate>.md` 记录候选 commit、准确 Xray tag/commit/摘要、参数修订、各矩阵结果、CI 链接、客户端与运行报告、已知限制。报告中的 v26.9.9 通过记录不自动覆盖未来 latest。
2. 只有绿色 CI 和报告对应的代码才打正式 tag；如果修复后 commit 改变，补跑受影响检查，并保证最终报告包含该 commit 的结果。
3. 验证 xtun tag 下载入口和 bootstrap 仍解析到同一产物；新开干净环境做最后一次公开入口安装检查，记录此时默认策略解析出的 Xray tag。若它已高于报告基线，补跑新版的必要检查并单独记录结果。
4. README 明确已验证系统/客户端、默认追新策略、当前验收核心、可选节点条件、首次安装步骤和显式版本选择方式，不再笼统说所有 Debian/Ubuntu 都稳定。版本选择示例在对应 CLI 实现后再公开为可执行命令。
5. 增加简明运维手册：安装记录、查看健康、证书续期、备份位置、核心/bundle 回退、故障定位顺序，以及什么情况下需要重新导入链接。
6. 旧生产机升级是另一个实施任务，从当时真实已安装版本重新核对迁移路径。本次发现本机为 `0.11.14`，不能照抄旧归档里以 `1.0.0` 为起点的命令。

## 11. 阶段 G：通过可靠性验收后的能力演进

### G1. 后量子就绪度观察

继续采用当前 PLAN 中已详细设计的 `xray tls ping` 探测方案：只解析有 SNI 的握手结果，完整输出才给结论，超时/缺核心/旧命令/未知格式为可解释的 WARN。解析依据更新为 v26.9.9 的 `tls/ping.go`；该文件与此前核对的 v26.3.27 文件内容相同，不把源码相同写成已跑过新核心的证明。latest CI 继续监测输出格式变化。[S12]

普通安装不会因为目标缺少 ML-DSA 准备条件而失败；`>3500` 的长度要求与 `X25519MLKEM768` 能力分别显示。保留现有检查的退出约定：参数错误 1，硬性检查失败 2，仅告警不导致失败。详细用例复用 [当前 PLAN §3](PLAN.md)，避免写两份互相漂移的解析规范。

### G2. ML-DSA 签名立项门槛

1. 区分 VLESS Encryption、Reality 密钥交换和 Reality 额外签名，不能把它们统一描述成同一个“后量子开关”。
2. 先验证服务端 seed、客户端 verify、目标要求、分享 URI 字段和目标客户端支持；Reality 普通直连、XHTTP Reality 和 split 的内外层都要覆盖。
3. 特别验证 QR 容量：v26.9.9 源码要求 verify 公钥解码后 1952 字节，单字段无填充 Base64URL 约 2603 字符，叠加 split 链接后编码与扫码可能成为实际限制。[S2]
4. 如果链接/PNG 交付方式无法承载，不默认启用签名，也不擅自恢复订阅。先提出明确的产品选择和兼容方案。
5. 通过后再写密钥生成、保存、轮换、迁移、重新导入、撤销与回滚的独立施工图。

### G3. 其他协议与调优

新的 Trojan、VMess、Shadowsocks 或其它传输只在有明确客户端/场景需求时立项；每增加一种都要有服务端、导出/导入、端到端和生命周期验收。不要为了“种类齐全”扩大首个生产版本范围。

性能调优每次只改一个可解释的变量组，以同一机器、同一网络、相同并发和文件比较基线。`xmux`、内核拥塞控制、qdisc、WARP、H3 分开测，收益不足时保留原配置，避免把单机经验固化成普适默认值。

## 12. 可直接交给实施 AI 的任务清单

| 工单 | 任务与主要文件 | 依赖 | 完成证据 |
| --- | --- | --- | --- |
| T01 | v26.9.9 接入、§7/C1 第 1–5 项共享解析/下载、CI 修复、`tests/install-smoke.sh` | 无 | 含预发布的默认发现、显式 tag、两架构摘要与命令解析正确；两个 job 对同一 SHA/核心全绿；正式 tag 等 T02/T03 |
| T02 | `--no-ipv6`、引导依赖和环境检查；安装 CLI/input/install | T01 | 参数不吞位、显式禁用有效、极简镜像入口通过 |
| T03 | SNI 入口、目标映射、超时与诊断；cli/sni | T01 | F02/F03 回归及不跳过 SNI 的安装通过 |
| T04 | H3 ALPN、IPv6 split、统一导出；ui/output | T01 | URI 语义矩阵正确，旧编号/PNG 一致 |
| T05 | H3 证书能力与诊断超时；ui/core、certs | T04 | 不误放行 Origin CA/自签直连，能力分层准确 |
| T06 | §7/C1 第 6–9 项版本/资源记录、bootstrap/ref、运行时归档、自更新完整性 | T01 | 精确分发产物安装，公共版本模块可用，完整候选与备份可供 T08 恢复 |
| T07 | 参数契约落地：users/xmux 迁移、REALITY 新兼容要求、ECH 校验/变体、NAS JSON；generators/state/output/CLI | T02–T06 | 旧凭据/状态意图保留、正确默认与层级、旧 force 停用、导出不改服务；子项见参数契约，实际三端通过项由 T11 填写 |
| T08 | 配置/state/output、UUID、核心/资源/参数修订更新的失败恢复 | T06、T07 | 包括旧 clients → users 在内的文件与链路级故障注入通过 |
| T09 | ACME 自动续期、并发锁、证书恢复 | T05、T08 | 调度、reload、失败恢复与真实证书检查通过 |
| T10 | baseline/latest/migration CI、同版本原生五节点传输、PNG 解码、强制 ECH 正负测试 | T02–T08 | v26.9.9 与当次 latest 的安装、语义/传输及版本完整；ECH 配置失败不降级的证据按参数契约记录 |
| T11 | v2rayNG/v2rayN/NAS Docker、真实 Cloudflare/ECH、系统矩阵、人工交互与持续运行 | T07–T10 | 按验收手册 R0–R5 出报告，填写兼容表，真实入口最终检查，正式 tag |
| T12 | PQ 观察与签名调查，按需追加协议 | T11 | 独立报告与施工图，不使默认组合未经验证改变 |

T01 先交付最新版接入和验证基础，随后 T02/T03/T04 可以分别推进。T04 与 T07 都涉及 output，T01/T02/T06 都涉及安装层，需明确提交边界并顺序集成；T05 与 T09 的证书改动同理。每个 PR 聚焦一个可验证结果，不混入无关重构。

交给每位实施者的共同要求：

```text
基于 docs/PLAN-PRODUCTION-READINESS.md 执行指定工单。
字段与导出遵守 docs/PARAMETERS.md；真实环境和人工交互遵守 docs/TEST-VPS-RUNBOOK.md。
本轮 Xray 基线必须为 v26.9.9；默认新装/显式升级追踪最新官方发布，包含 pre-release。
单次操作锁定 tag/commit/摘要；不要使用 releases/latest、旧正式版默认或静态允许列表替代追新策略。
开始先记录当前 SHA 和工作区改动，不覆盖他人的未提交内容。
Xray 字段以官方 docs/source 和目标版本源码为依据，摘要不能代替验证。
保持本机生产节点不变，在沙箱、一次性容器或独立测试 VPS 验证。
先为已确认缺陷补能失败的回归，再做最小实现；不要写仅复述实现的测试。
不要以修改预期、跳过预检、关闭证书验证或丢弃字段让结果变绿。
交付：变更说明、提交 SHA、实际 Xray tag/摘要、参数修订、实际执行的验证、CI 链接、未通过项、恢复方案。
只在验收条件确实满足时标完成；未执行项目明确写“未执行”。
```

### 2026-09-12 T01 实施状态

提交 `32ac9ea` 已完成 T01 的代码实施：新增共享版本解析/下载模块，安装与升级支持显式 `--xray-version`，默认解析 latest-published（包含 pre-release），CI 改用共享 `v26.9.9` 基线，安装冒烟脚本移出 YAML，并补齐版本选择、摘要冲突、候选命令与 PNG 计数回归。

本地验证结果：入口、lib、tests 全部 `bash -n` 与 ShellCheck 通过；`tests/smoke.sh` 完整通过（`smoke ok`）；真实 latest 检查在临时目录下载并验证 `v26.9.9`，记录 `prerelease=true`、提交 `52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120`、arm64 资产 `Xray-linux-arm64-v8a.zip` 与 SHA256 `3e38d72dfc5eb65c91df0e5583e9b6676c32232041da47de6ae73946b526d66c`，并通过候选 `version`、`x25519`、`vlessenc` 与服务端/参照客户端 `run -test`。

Actions 结果：候选提交 `32ac9ea` 已推送，CI run [34703713056](https://github.com/milikii/xtun/actions/runs/34703713056) 中 `shellcheck-and-smoke` 与 `install-smoke` 均成功；`latest-check` 按事件条件跳过，默认 latest 路径以上述本地真实下载验证为准。因此 T01 的代码、CI 与容器验收已完成，正式 tag 仍等待 T02/T03 的 P0 修复。

## 13. 主要依据

- [S1] 技能 `sources.yaml`：快照来源、日期与版本范围。
- [S2] Xray v26.9.9 固定提交 `infra/conf/transport_security.go`，与本地 `source/config/transport_security.go` 一致：TLS/Reality、password、allowInsecure、ECH、ML-DSA。
- [S3] 同版本 `transport/internet/splithttp/dialer.go`，与本地对应源码一致：`decideHTTPVersion` 根据 TLS ALPN 选择 H2/H3。
- [S4] 同版本 `infra/conf/vless.go`，与本地 `source/config/vless.go` 一致：入站 users/clients、Encryption 和回落约束。
- [S5] 同版本 `infra/conf/transport_method.go`，与本地对应源码一致：XHTTP extra/downloadSettings、xmux 默认与互斥校验。
- [S6] Cloudflare Origin CA 官方文档：源站证书的信任适用范围。
- [S7] 本地官方 Reality 文档：target、公钥别名、ML-DSA 与目标要求；结合固定版本源码使用。
- [S8] Xray v26.9.9 `infra/conf/transport_internet.go`，与本地对应源码一致：StreamConfig 及传输设置层次。
- [S9] 官方 v26.9.9 release API：prerelease、发布时间、资产 URL/摘要；本轮摘要记录不是本地重算结果。
- [S10] 官方 tag ref API：v26.9.9 指向提交 `52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120`。
- [S11] 官方 releases 列表：发现最新发布时包含预发布；实际实现须处理分页。
- [S12] Xray v26.9.9 `main/commands/all/tls/ping.go`：有/无 SNI 段、PQ 与证书链长度输出。
- [S13] 同版本 `main/commands/all/curve25519.go`：x25519 公私钥输出标签和生成逻辑。
- [S14] 同版本 `main/commands/all/vlessenc.go`：两组认证方案的 decryption/encryption 输出。
- [S15] 同版本 `go.mod`：锁定 REALITY 依赖提交；客户端握手约束按该依赖核对。
- [S16] REALITY 依赖 `8cdf7bf9c7f09cb9814bf08c3eb877f68b85fba8` 的 `tls.go`：初始 key_share 与目标 ServerHello 的不同条件。
- [S17] Xray 固定版本 `transport/internet/tls/ech.go`：ECH 获取失败语义、查询格式与过期缓存处理。社区和客户端固定提交来源集中见 [参数契约](PARAMETERS.md)。

[S1]: ../.claude/skills/xray-core-official-knowledge/sources.yaml
[S2]: https://github.com/XTLS/Xray-core/blob/52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120/infra/conf/transport_security.go
[S3]: https://github.com/XTLS/Xray-core/blob/52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120/transport/internet/splithttp/dialer.go
[S4]: https://github.com/XTLS/Xray-core/blob/52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120/infra/conf/vless.go
[S5]: https://github.com/XTLS/Xray-core/blob/52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120/infra/conf/transport_method.go
[S6]: https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/
[S7]: ../.claude/skills/xray-core-official-knowledge/docs/stable/config/transports/reality.md
[S8]: https://github.com/XTLS/Xray-core/blob/52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120/infra/conf/transport_internet.go
[S9]: https://api.github.com/repos/XTLS/Xray-core/releases/tags/v26.9.9
[S10]: https://api.github.com/repos/XTLS/Xray-core/git/ref/tags/v26.9.9
[S11]: https://api.github.com/repos/XTLS/Xray-core/releases
[S12]: https://github.com/XTLS/Xray-core/blob/52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120/main/commands/all/tls/ping.go
[S13]: https://github.com/XTLS/Xray-core/blob/52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120/main/commands/all/curve25519.go
[S14]: https://github.com/XTLS/Xray-core/blob/52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120/main/commands/all/vlessenc.go
[S15]: https://github.com/XTLS/Xray-core/blob/52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120/go.mod
[S16]: https://github.com/XTLS/REALITY/blob/8cdf7bf9c7f09cb9814bf08c3eb877f68b85fba8/tls.go
[S17]: https://github.com/XTLS/Xray-core/blob/52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120/transport/internet/tls/ech.go
