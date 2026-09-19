# 测试 VPS 与三端交互验收手册

> 计划日期：2026-09-12；实现与证据更新：2026-09-15。可复现核心基线 Xray `v26.9.9`。本文提供复现与后续验收步骤；最新结果见[批次 C/D/E 报告](REPORT-2026-09-15-CDE.md)，前序恢复见[接手报告](REPORT-2026-09-14-W04R-W05R.md)，未执行项目保持待验证。
> 使用者：按新计划 W14/W15 分批验收的实施者，以及操作 Android、Windows、Debian NAS 的用户。
> 依赖：[当前计划](PLAN.md)、[详细 W 工单](PLAN-UX-RELIABILITY.md)、[决策](DECISIONS-UX-RELIABILITY.md)与[参数契约](PARAMETERS.md)。所有故障注入使用独立测试 VPS、独立客户端配置和独立 NAS 测试容器。

> **排程决定：** 按 D18/D19，完整范围统一发布。A–E 代码及报告列出的自动/实机证据已交付；后续为公共 ACME、G1 强制断电、真人/三端和观察。按 D30，提交与 push 已授权，正式 release 仍需完整验收。设备到位先 W14.1/W15.1，再修正并完成 W14.2/W15 全矩阵；R4 不取代首轮真人。

## 1. 交付顺序与停止条件

首轮验收使用当前已实现的独立 NAS/ECH 导出，记录准确候选；导出成功不等于客户端网络通过。最终候选须补齐下面的完整材料和范围。真人任务、影响预期与记录格式见详细计划 J01–J16。等待操作者/设备期间可补公共证书、断电与独立回归证据，不能提前勾选 G4/G5。

先证明普通五类节点按名字工作，再开启节点 3 的 ECH 变体，最后验证 split ECH、IPv6/H3 和生命周期。任一阶段失败，保存证据并回到对应工单修复；不能在测试机手改托管配置后，将结果当作公开安装入口已经修好。

| 阶段 | 执行者 | 必须交付 |
| --- | --- | --- |
| R0 候选准备 | 实施者 | 精确 ref/commit/入口及 bundle 摘要、核心身份、参数修订、当前 W 阶段对应检查、可复现安装说明；最终候选需 G1/G3 与同 SHA CI |
| R1 干净 VPS 安装 | 实施 AI | 默认入口成功、不跳过 SNI、监听与证书检查、五类 URI/真实 PNG/原生 JSON |
| R2 普通三端验证 | AI 准备，用户操作 GUI | v2rayNG、v2rayN、NAS Docker 的字段保留、双向内容与路径证据 |
| R3 ECH 单独验证 | AI 准备，三端分别执行 | 查询来源、强制 ECH 正/负用例、实际网络差异与冷启动结果 |
| R4 人工交互验收 | 用户操作，AI 记录修复 | 复制/扫码/NAS 导出、错误恢复、菜单理解、编辑与重新导入 |
| R5 维护和观察 | 实施 AI | 重启、升级恢复、续证、长连接、72 小时及 7 天记录 |

只有某个平台/节点/变体完成对应阶段，才能在兼容表写“通过”。基础节点已通过、ECH 未通过时，单独列明 ECH 待支持；不能把 ECH 失败隐藏掉，也不必将无关的普通节点结果作废。一台 VPS 上的结果只覆盖它的系统与架构，不能外推整个系统矩阵。

## 2. R0：准备材料与环境记录

1. 从准确候选生成安装说明，记录 runtime 摘要、安装回执、state schema 与参数修订。`export-client` / `rebuild-qr` 已可执行；用本手册命令导出实际文件，不给用户带占位凭据的客户端 JSON。
2. 准备一台可重建的测试 VPS；首轮建议 Debian 13 amd64，先用发行版内核、关闭 WARP 和可选网络优化。其余系统/架构按主计划另测。
3. 准备受控 Cloudflare 域名、橙云、边缘证书及 Full (strict) 回源证书。记录套餐、ECH/HTTP2/gRPC 设置、缓存规则和实际源站绑定，不将 Cloudflare 的默认说明当成本账户实测。
4. 选择经预检的 REALITY SNI 与真实远端 target，记录目标端口、TLS/SNI 检查及 PQ 观察结果。不得因目标未支持可选签名而跳过所有普通节点测试。
5. 准备独立受控测试端点：回显随机请求标识，提供确定内容的下载和上传哈希校验。普通网页、出口 IP 查询和测速值只能作为补充。
6. 建立下面的客户端记录。用户已确认应用种类，不再要求其重选客户端；准确版本在实际设备上读取。

| 设备 | 必须记录 | 首轮模式 |
| --- | --- | --- |
| Android | Android/v2rayNG 版本、实际 Xray 核心版本、架构、导入方式、Wi-Fi/移动网络 | 先 Wi-Fi，再移动数据；记录 VPN/DNS 设置 |
| Windows | Windows/v2rayN 版本、当前选用的核心类型和版本、架构 | 先系统代理，再 TUN；记录影响 DNS 的设置 |
| Debian NAS | Debian/CPU 架构、镜像来源/tag/digest、容器内实际 xray version、Entrypoint/命令、网络与挂载 | 独立 Linux host 网络测试容器、只读私有配置；使用导出的回环监听，先确认端口空闲 |

不要求 GUI 的版本号与 Xray 相同；以实际内核为准。若 GUI 内核落后，先在测试配置中使用其支持的更新办法，再验收。Docker `:latest` 不能替代 `xray version` 与 digest。

### 2.1 已知现场与隔离核心

以下结合[本次复核](REVIEW-2026-09-14.md)与[接手报告](REPORT-2026-09-14-W04R-W05R.md)，开测时仍须重新记录：

| 环境 | 已有证据 | 后续处理 |
| --- | --- | --- |
| 当前本机生产 | bundle 0.11.14 声明 schema 1；实际 state 2；Xray 26.3.27/d2758a0/arm64；A 的 63 条、B 独立范围的 62 条记录分别按各自基线核对 | 保持现场；迁移用脱敏隔离副本，不按包版本推断 state |
| 原测试 VPS | W06 的系统、IPv6、模块和端口是历史证据 | 旧地址认证失败，后续不使用旧凭据反复尝试 |
| 新授权 VPS `194.195.251.247` | Debian 12 amd64、Xray 26.9.9；C/D/E 已安装，state2/参数2/users；托管 nginx 配置曾因"≥1.25.1 环境生成、二进制回落 1.22.1"导致重启循环，2026-09-19 已按 1.22 语法手工修正 | 保留作工作机；开测前记录 pending/服务/端口，SSH 密码与配置不变 |
| 全新测试 VPS `172.239.117.239` | Debian 12 amd64、1 vCPU/1.9 GiB；2026-09-19 从公开入口全新安装 `cd8a9aa` 成功，253 组 smoke、PTY 68/9、原生 17 场景、迁移 3 组与恢复/部署套件全通过；见[新 VPS 验证报告](REPORT-2026-09-19-VPS-VERIFICATION.md) | 可继续作真机安装与套件环境；该机原有 VOXI Xray（TCP 443）/Hysteria（UDP 443）/OpenVPN 已按备份还原，重装前先停用 443 或再次完整备份 |
| H3 正向环境 | 新 VPS 实际 nginx 1.30.1 有 http_v3，但测试自签证书不满足直连公共信任 | 仍须准备受客户端信任证书、外部 UDP 可达环境；模块存在不能替代完整正向证据 |

真机安装/卸载验收前，先归档宿主原有服务（配置、unit、脚本、二进制、日志、网络与服务状态）并另存副本。注意 **xtun 卸载会删除 `/var/log/xray` 与 `/var/lib/xray`**：原 unit 若用 `ReadWritePaths` 指向它们，还原时要先重建目录（`xray:xray 0750`）再启动。2026-09-19 已在 `172.239.117.239` 按此流程完成卸载与还原，步骤见该机备份目录的 `RESTORE.md`。

本机目标核心测试使用独立目录下的准确二进制与资源。先记录其 `version` 和摘要，再通过 `TEST_HOST_XRAY_BIN` 指定它。本轮已在 arm64/amd64 执行；复现时路径按实际替换：

```bash
TEST_HOST_XRAY_BIN=/path/to/isolated/xray bash tests/smoke.sh
```

不要为了在本机测 v26.9.9 而运行会替换生产核心的 `tests/install-smoke.sh install-core`。安装/服务测试使用可重建容器或独立 VPS；静态配置接受与候选命令成功不算真实传输。

### 2.2 补修与 H3 回归矩阵

H25–H29 已完成前序报告列出的自动/实机复验；H30 已有批次 B 的意图/证书/UDP 逻辑和实机负向结果。以下保留每项要求供后续修改重测。Ctrl-C/TERM/SIGKILL 已测，**强制断电未测**；公网 H3 仍未测。记录前后文件/服务状态、原始退出码和恢复结果，不用某个 helper 的成功替代完整入口或真人证据。

| 场景 | 工单 | 必须核对 |
| --- | --- | --- |
| H25 临时包返回 0/1/2/23/130/143 | W01-R | 公共单文件入口原样返回；临时资源清理不抹掉错误 |
| H26 安装任务取消、确认 n/EOF/Ctrl-C；卸载 n | W01-R/W05-R | 持久 bundle、锁、日志、备份、state、隐式草稿不变；无 service/package 动作 |
| 预览后、拿锁前现场改变 | W01-R | 锁后复检识别变化，旧确认失效，重新预览 |
| H27 不存在→备份→创建→再备份→恢复 | W02-R | 首次 existed=0 不变，恢复删除本次托管创建；已有原件场景仍保留首次内容 |
| H28 manifest 为目录/不可写/写入失败 | W02-R | 非零且不继续改托管目标；缺失证据不能解释成原本不存在 |
| H28 generation 后追加核心/geo/bundle 路径 | W04-R | 首个相应写入前持久清单完整；标记写入/rename/回读失败阻断 |
| H29 原先 active/inactive/不存在，及 enable 被改变 | W04-R | 恢复到操作前状态；必要 daemon-reload、stop/reload/start 失败不报已恢复 |
| 共享 HAProxy 保留但配置删除/reload 失败 | W02-R/W04-R | 按独立归属恢复配置或保留必要资源并报告不完整；检查实际监听，不以手动停服务提示代验收 |
| state/PNG/输出目录只读、磁盘满、第二服务失败 | W04-R | 文件/状态/产物代次一致，或列明恢复失败和可信恢复点 |
| Ctrl-C/TERM、SIGKILL、强制断电后重入 | W04-R/W05-R | 分别留证；后两者依持久清单恢复，不借 trap 测试代签；查看入口不自行恢复 |
| 极简环境缺 openssl/iproute2/qrencode | W05-R | 确认前列待复检，确认后准备依赖；失败不应用托管配置，保留输入与真实恢复结果 |
| H30 默认/显式/旧 H3 意图，证书和 UDP 矩阵 | W09.1 | 新默认不自动启用，旧选择保留；Origin CA/自签/未知信任不冒充公网可信，外来端口不接管 |

强杀/断电测试只在可销毁环境进行，报告实际中断点、存储/文件系统、重入方式及残留。恢复假成功、错误退出 0、外来资源被误改均返回对应工单；不因其它用例通过而关闭整项。

### 2.3 迁移基线

| 起点 | 候选验收要求 |
| --- | --- |
| 实际生产组合：bundle 0.11.14 / state v2 / Xray 26.3.27 | 检查旧包实际读写兼容；凭据/选择/资源归属保持，失败可恢复；不猜 state v2 来源 |
| 历史组合：bundle 0.11.14 / state v1 | 保留旧状态迁移用例，不被新增实际组合替代 |
| 工作区 1.1.0 / state v2 | 包含已有 W01–W06/W08.1 增量；以准确候选 SHA/内容身份区分，不能只比版本字符串 |

三组已在 arm64 与 amd64 运行：使用历史提交 `b6eb98b49d01c9b524aa0a679cc951d5b72c9db7`（0.11.14）和 `434075910feb1ce6c93873be7a550a5a7591230e`（1.1.0）的实际生成器、合成身份及对应核心。0.11.14/state2 是显式构造的生产组合夹具，不能宣称旧 schema1 生成器自行产出 state2。参数应用前先完成核心选择，注入 PNG 失败验证原件恢复，再成功迁移；不把它写成三范围的原子系统升级。

clients/users 冲突/空数组、xmux 来源未知、既有 H3/ECH 选择等边界另由 smoke 覆盖。不复制生产秘密到公开报告；本机生产不参与迁移。

### 2.4 已有自动与 VPS 套件的复现

先保留工作区和候选摘要，检查准确核心身份。以下命令在 root shell 执行，使用同一官方归档中的独立核心和 geo 数据，不安装生产核心。完整 smoke 和两套 PTY 会经过真实安装/维护的 root 检查；测试 worker 隔离托管路径和服务调用，无 root 帮助入口由 smoke 内的 `setpriv` 单独验证。若通过 sudo 执行，显式保留 `TEST_HOST_XRAY_BIN` 和 `TEST_HOST_XRAY_ASSET_DIR`：

```bash
export TEST_HOST_XRAY_BIN=/path/to/isolated/xray-release/xray
export TEST_HOST_XRAY_ASSET_DIR=/path/to/isolated/xray-release
bash tests/smoke.sh
python3 tests/install-boundary.py --evidence /path/to/private-evidence
python3 tests/task-menu-boundary.py --evidence /path/to/private-menu-evidence
python3 tests/native-transport.py --workdir /path/to/private-native-evidence
bash tests/migration.sh /path/to/private-migration-evidence
```

资源目录须含可读非空的 `geoip.dat` 和 `geosite.dat`。测试显式设置 Xray 的资源查找目录；仅复制二进制不算具备完整测试依赖。缺文件会在开始运行用例前报错。迁移要求完整 Git 历史（CI checkout `fetch-depth: 0`）；旧核心可由 `TEST_OLD_XRAY_BIN` / `TEST_OLD_XRAY_ASSET_DIR` 指定，否则从官方已校验归档下载到测试目录。

原生传输需要 Python、nginx、iproute2、util-linux 与可创建 network namespace 的 root 环境。套件只在独立 namespace 内建立测试地址和监听；五类节点及原生 ECH 正向各上传/下载 64 MiB，校验内容，并验证 UUID/密钥/shortId/路径/ECH/split 逐腿阻断失败。它不使用真实 Cloudflare，不改变宿主服务。

具备 Docker 的隔离测试机可执行 `bash tests/docker-client.sh`，验证真实 CLI 导出、固定官方镜像、只读挂载、0600 文件与 SOCKS 启动。默认追新选择及语义/传输可用 `bash tests/install-smoke.sh check-latest` 复现；该命令使用临时核心和资源，不安装到宿主。执行需 sudo 权限，前置依赖与 CI 相同。

在授权测试 VPS 的候选目录执行下面的原生套件。systemd/ownership 使用唯一测试 unit；filesystem 仅填满专用 tmpfs；deployment 会实际替换这台 VPS 的安装内容。先备份它的配置、二进制、unit/drop-in、包清单与 SSH 指纹，已有 pending 要先处理。完整现场保留为 root 私有目录。

```bash
export XTUN_TEST_ISOLATED_VPS=yes
bash tests/systemd-recovery.sh
bash tests/filesystem-recovery.sh
bash tests/ownership-systemd.sh
bash tests/deployment-recovery.sh upgrade
bash tests/deployment-recovery.sh update-script
bash tests/deployment-recovery.sh install-output-failure
```

安装故障套件可能按设计留下新装共享包的未恢复记录。查看 `result.txt`、`operation.log` 和当前 pending，先处理具体残留，再从同一候选执行 `bash xtun.sh recover --yes`；不得直接删 pending 让后续测试通过。软件包、账户和日志内容不会自动卸载或删除。

缺依赖测试使用新 minbase，不物理移走 VPS 宿主工具：

```bash
XTUN_TEST_ROOTFS="/var/tmp/xtun-minbase-$(date -u +%Y%m%d-%H%M%S)"
debootstrap --variant=minbase bookworm "$XTUN_TEST_ROOTFS" http://deb.debian.org/debian
XTUN_TEST_ISOLATED_VPS=yes bash tests/minimal-install.sh "$XTUN_TEST_ROOTFS"
```

批次 A 的 systemd 13/13、filesystem 5/5、ownership 5/5、minbase 5/5，以及安装/升级/bundle 故障和草稿续装结果保持为历史证据。批次 B 的 canonical smoke 增至 220 条，安装/任务菜单 PTY 分别为 68/9 个场景；准确双架构结果与新信号反例见批次 B 报告。sleep unit、模拟失败与共享 HAProxy 的实际 HTTP 监听分别记录，不能互相替代。

批次 B 后续 CI 补修 `6956e01` / run `34853691008` 及 222 条 smoke 是历史基线。C/D/E 当前 canonical smoke 为 252 组、PTY 为 68/9；双架构原生 17 场景、历史迁移 3 组和 VPS 26 项实际维护结果见最新报告。push 的 CI 按对应 SHA 检查，安装矩阵为 Debian 12/13、Ubuntu 24.04，另含官方客户端容器。

每次修改相关范围时，按实际候选复核以下行为：

1. `show-links --summary`、`show-links --node 3`、`show-links --qr --node 3` 前后文件、备份和服务 PID 不变；不存在的节点返回非零。
2. 旧 state 未记录 H3 时，只读识别清晰的托管关闭配置；即使 nginx 有 http_v3，也不自动创建 QUIC/Alt-Svc/节点 8/9。
3. 仅在已核对测试自签证书的环境，执行 `change-h3 --enable-h3 --non-interactive` 应失败，核对没有新备份或服务应用。公共信任正向环境单独验收，不能照搬此负向预期。
4. UUID/path/H3 同值请求为 noop；实际路径修改与还原走同代提交。应用失败核对配置、state、输出、PNG 和服务状态恢复，原命令仍非零。
5. 更换 bundle 使用准确候选归档；脚本更新不重启服务，同内容重试不生成恢复点。原生 suite 在独立沙箱运行；真实维护通过已安装入口验证，记录两种范围。
6. 测试前后比较 root 密码哈希的指纹和 sshd 配置摘要，确认 SSH 主进程仍运行；不将密码、哈希正文、私有 URI 或原始配置写入仓库。

### 2.5 强制断电补证与收尾

本次未执行虚拟机强制断电。后续先准备外部控制台、可恢复镜像和云平台电源控制，记录虚拟磁盘/文件系统，再在明确的 pending 写入后、文件替换中和提交决定后分别断电；重新开机后先只读核对证据，再运行显式恢复并比较文件、权限、服务及结果。SIGKILL、guest reboot 和 INT/TERM 不代替该项。

每轮收尾重新核对 root 密码哈希指纹、sshd 配置及 SSH 状态，不改变用户提供的密码；本机生产使用事先保存的文件/目录和服务 PID canary 比较。清除套件自己创建的 unit/mount，保留未解决失败证据。实时网络参数/内核、包管理变化和原件缺历史摘要分别记录，不能写成自动完全恢复。

## 3. R1：安装与产物检查

1. 从固定候选公开入口安装，显式复现 v26.9.9；另测默认 latest 解析包含预发布。两者若锁定同一核心，可共用传输结果，但选择路径分别留证。
2. 安装只填写必要的域名、证书和地址等输入，不使用 `--skip-sni-check` 掩盖目标探测。失败输出应有具体原因和可行的下一步。
3. 对照实际产物检查 systemd、Xray/nginx/HAProxy 配置和权限；确认 2443/2444/8001/8443 仅按设计本地绑定，对外开放实际需要的端口。
4. 默认得到节点 1–5；可选节点没有满足条件时显示原因。核对节点名字、编号、URI 与 PNG 文件对应；真实解码 PNG 后与 URI 一致。
5. 检查实际导出的原生 JSON：真实凭据配对、没有占位符，没有服务器 privateKey；用同一候选核心执行 `run -test`。这个步骤不代替传输验证。
6. 对照参数契约确认 users/clients 迁移、`xmux` 整块默认、ALPN、IPv6 split 地址、ECH 层级。旧节点用迁移前快照单独验证，不能拿新装结果代替。
7. 首轮普通节点产物与稍后 ECH 变体分别标识。只改变客户端 ECH 导出时，不应重启 VPS 服务或改变配置/state 中的凭据。

## 4. R2：三端基础功能与导入

### 4.1 Android v2rayNG

1. 将测试配置放在可辨认的测试分组。复制节点 1 URI 导入，连接后访问带随机标识的测试端点；依次完成节点 2–5。
2. 每条节点再通过实际 PNG 扫码导入；比较两种导入的名字和运行配置，删除重复测试项时不得误删现有节点。
3. 读取实际运行配置或可靠诊断输出，核对 UUID、Encryption、flow、fingerprint、SNI、path、ALPN、extra/downloadSettings 及 ECH 状态。应用表单看不到某字段不代表它丢失，应查运行结果。
4. 打开编辑界面，不修改关键字段，保存后重连；再修改备注并保存。两次均应保留额外参数，不能出现“刚导入能用，编辑后坏了”。
5. 每条受支持节点做 64 MiB 下载与上传并校验内容；split 需对应上下行连接证据。REALITY 各变体核对实际核心能产生目标版本要求的 ClientHello。
6. 在移动数据重复短请求与关键传输；记录运营商/地区或可识别的接入条件。切 Wi-Fi/移动数据后记录恢复时间和是否需要人为重启。

### 4.2 Windows v2rayN

1. 明确选用 Xray 核心，复制节点 1–5 URI 导入；按应用支持的方式导入实际二维码图，再比较运行配置。
2. 先用系统代理测受控端点、内容校验和 split 路径；再用 TUN 重复 DNS 引导、冷启动和短请求。不要用一个未遵守系统代理的程序制造假阴性。
3. 编辑、改备注、重新导出再导入后，核对 Encryption、`extra`、`ech` 与别名字段；百分号编码只能还原一次。
4. 休眠后恢复、退出再启动核心，验证连接恢复与状态显示。记录系统时间与原始错误，不能只统计自动重试后的成功。

### 4.3 Debian NAS 的 Xray-core Docker

先在已安装的测试 VPS 导出，再通过私有 SSH 通道将文件传到 NAS 的专用目录；不要把含凭据 JSON 放进公开仓库：

```bash
xtun export-client --node 3 --variant plain --format json --output /root/xtun-clients/node3.json
```

固定官方镜像为 `ghcr.io/xtls/xray-core:26.9.9`，实际运行用多架构 index digest：

| 对象 | SHA256 |
| --- | --- |
| 多架构 index | `45338c4df61fda061c47ce62aafda6c5d7d59cbdefc33f2e335d8b0c748b748a` |
| linux/amd64 | `9a17fb7fcda36f80d041fc1f12f1d661d3f7c502572b2a6f2e4432534789a20b` |
| linux/arm64 | `2924913941c200d4e3b9636179f6777ed857c9a3a0d761c01eec8f90a25106d2` |

镜像的 Entrypoint 是 `/usr/local/bin/xray`，默认用户为 65532；下面显式使用配置文件的属主 UID/GID，保证 0600 文件可读。Linux host 网络保留导出的 `127.0.0.1:10808`，无需手工修改 JSON 或发布容器端口。先确认 NAS 上该端口空闲，已有代理继续运行在各自端口。

在 NAS 的 `node3.json` 所在目录，用 Bash 执行（需 Docker 权限与 Python 3）：

```bash
chmod 600 node3.json
XTUN_NAS_CONFIG="$(realpath node3.json)"
XTUN_NAS_IMAGE=ghcr.io/xtls/xray-core@sha256:45338c4df61fda061c47ce62aafda6c5d7d59cbdefc33f2e335d8b0c748b748a
XTUN_NAS_CONTAINER="xtun-client-test-$(date -u +%Y%m%d%H%M%S)"
XTUN_NAS_OPTIONS=(--read-only --cap-drop=ALL --security-opt=no-new-privileges
  --user "$(stat -c '%u:%g' "${XTUN_NAS_CONFIG}")"
  --mount "type=bind,src=${XTUN_NAS_CONFIG},dst=/config/client.json,readonly")
python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 10808))
PY
docker pull "${XTUN_NAS_IMAGE}"
docker run --rm "${XTUN_NAS_IMAGE}" version
docker run --rm "${XTUN_NAS_OPTIONS[@]}" "${XTUN_NAS_IMAGE}" run -test -config /config/client.json
docker run --rm -d --name "${XTUN_NAS_CONTAINER}" --network host \
  "${XTUN_NAS_OPTIONS[@]}" "${XTUN_NAS_IMAGE}" run -config /config/client.json
docker logs "${XTUN_NAS_CONTAINER}"
```

任一步失败先停止处理，不继续启动。端口已占用时另开独立测试环境，或明确制作并验证不同监听的副本；不能停止原有代理来制造空闲。通过宿主 `socks5h://127.0.0.1:10808` 请求受控内容端点，记录代理解析模式、双向内容哈希和 split 路径。测试结束只停止本次容器：

```bash
docker stop "${XTUN_NAS_CONTAINER}"
```

依次加载各节点/变体，另测 NAS 的 DNS/DoH 引导、核心冷启动、容器和宿主重启。CI 容器仅证明固定镜像接受实际导出的 JSON 并启动 SOCKS；真实 NAS 数据路径仍待 W15。需要 bridge 时单独制作容器内非回环监听并仅向宿主回环发布端口，记录这项有意变更并另测，不能继承 host 网络结论。

普通节点通过标准：请求标识与内容正确，流量确实走选中出站，路径与节点名称一致，编辑和重新导入不丢字段。不能用所有节点相同的出口 IP 证明 split；用客户端连接记录、受控日志及隔离阻断其中一条路径的结果验证。

## 5. R3：ECH 的严格验收

### 5.1 从普通 CDN 到 ECH

1. 先确认同一域名、同一网络、同一客户端的节点 3 普通 TLS 版本可用；记录时间、核心、连接地址、SNI/Host、证书、H2 与内容校验。
2. 在该客户端网络上用 AliDNS 候选发起 HTTP/2 POST DNS wire 查询，解析 HTTPS RR 的 ech 内容。查询真实 CDN 域名；如无 ech，记录缺项，再显式测试 `cloudflare-ech.com` 的共享配置方案。记录来源、TTL 和配置指纹，不只记录 HTTP 200。
3. 导出 `节点 3 · ECH`。保持地址、SNI、Host、UUID、Encryption、path 与普通版本一致，只在正确 TLS 层加入来源。核对实际导入的运行 JSON，而非只查看原始 URI。
4. 冷启动测试核心，关闭测试分组中的自动切换/直连回退，让受控流量只经这一个出站。完成短请求及双向传输，记录实际核心、ECH 来源和边缘握手证据。
5. 如果目标核心能提供 ECH 接受状态，保存该证据；不能提供时，报告必须写明采用了“目标源码的强制 ECH 语义 + 实际配置保留 + 正向传输 + 下述负向用例”这一证明方式。证据不足则维持待验证。
6. 在独立测试副本中使用错误配置做负向验证，再恢复正确配置重新成功。错误试验不能改坏普通节点或已有生产配置。

DNS wire 诊断由实施 AI 提供工具或从测试核心日志采集，普通 GUI 操作不要求用户手工构造二进制查询。同网络的笔记本/NAS 辅助查询只能标作同网参考；Android 实际 VPN/核心路径仍需运行配置、客户端日志和强制 ECH 正负传输来验证，不能用 VPS 代测。

**不接受的 ECH 证明：** URI 有 `ech=`、应用显示“启用”、服务 active、抓包看到 GREASE ECH 扩展、通过代理打开浏览器 ECH 检查网站、或单纯能上网。浏览器检查网站通常观察浏览器到该网站的 TLS，不一定观察 Xray 到 CDN 的外层连接。

### 5.2 正常、故障与时间矩阵

| 用例 | 操作 | 预期与证据 |
| --- | --- | --- |
| E01 冷启动 | 新测试进程使用正确来源连接 | 取得配置，强制 ECH 传输通过；保留运行 JSON 和原始结果 |
| E02 格式损坏 | 非法 Base64，或故意破坏需要的末尾 padding | 明确失败，不能自动删掉字段继续联网；恢复后成功 |
| E03 错误密钥 | 使用与目标边缘不匹配、结构合法的测试 ECHConfigList | ECH 握手不能静默降级；任何重试/配置替换均留证，不能把普通 TLS 成功记作 ECH 成功 |
| E04 DoH 不可达 | 冷进程下，仅阻断测试解析器连接 | 在有界时间失败并说明查询原因，普通 CDN/REALITY 可被手动选择；不在同一 ECH 连接自动回退 |
| E05 有 HTTPS 但无 ech | 使用可控的缺 ech 查询结果 | 报告缺 ECH 数据，不能因 type 65 或 HTTP 200 就显示可用 |
| E06 缓存内失败 | 已成功取得配置后暂时阻断 DoH | 可能继续使用缓存；按记录的 TTL/缓存年龄解释，不错误要求每次都立即失败 |
| E07 过期缓存 | 覆盖 TTL 刚过期、TTL 后不足 4 小时、TTL 后超过 4 小时 | 记录旧值/异步更新/等待查询的行为与首次连接结果；不是简单睡 4 小时就算覆盖 |
| E08 真实轮换 | 持续记录配置指纹，实际观察变更后连接 | 记录首次失败、重试、刷新及恢复；未观察到轮换写“未观察到”，不能只等固定五小时就宣布通过 |
| E09 休眠与切网 | 手机息屏/后台、Windows 休眠、Wi-Fi→移动数据、容器重启 | 记录恢复时间、配置来源与缓存，核对没有后台自动关闭 ECH |
| E10 边缘/源站故障 | 对测试环境分别阻断边缘连接、制造可恢复的回源错误 | 能区分连接失败、证书问题、ECH 拒绝和 CDN HTTP 错误；换 DoH 不能被当成万能修复 |
| E11 split ECH | 节点 4/5/7/9 分别测试，先满足各自基础条件 | ECH 只在 CDN 那一层；REALITY/H3 下行不误注入，双路径与错误路径负例通过 |

冷缓存故障必须使用独立测试进程，不能因为仍有有效缓存且连接成功就误判强制 ECH 失效。E03 要使用结构合法但不适用目标的配置，不能与 E02 的解析错误合并。所有可选重试都记录原始第一次结果。

### 5.3 国内网络故障的定位顺序

| 观察 | 优先检查 | 可以作出的结论 |
| --- | --- | --- |
| 普通 CDN 和 ECH 都失败 | 边缘地址可达、证书、SNI/Host、端口、回源、路径与客户端配置 | 暂无证据把原因归给 ECH |
| 普通 CDN 成功，ECH 的 DoH 连接失败 | 解析器证书/引导/路由、Android VPN 或 Windows TUN 的循环依赖 | 先定位获取配置这一步；显式比较另一个可达 DoH |
| DoH 200，但无 ech | 查询名、type 65 实际内容、解析器过滤/缓存、zone 配置 | 尚未获得 ECHConfig，不能开始有效 ECH 验收 |
| 取得配置，握手报 ECH 拒绝 | 当前域名边缘是否接受、配置轮换/陈旧缓存、实际核心和配置格式 | 是该连接的 ECH 故障，不能凭这一例断言全国屏蔽 |
| 特定网络只有 ECH 连接超时 | 同时间/同客户端/同域名的对照、边缘路由及外层 SNI 可达性 | 可记录“该网络疑似相关阻断”，仍不能声称 ECH 密码学被破解 |
| TLS 已通过，随后 403/524 或断流 | CDN 规则、回源日志、HTTP 传输模式与超时 | 继续定位 HTTP/CDN 层；不要反复改 ECH 密钥 |

## 6. R4：人工交互验收

这里是 W14.2 的完整交互复测；首轮 W14.1 先按 J01–J16 的当次范围执行并修正问题，设备晚到也保留两个阶段。目标是用户拿到安装输出后能完成操作并理解失败。实施者先自查，再让用户按下表操作；测试时记录卡住的位置，不实时口头代替产品提示。

| 场景 | 用户操作 | 通过标准 |
| --- | --- | --- |
| U01 安装后第一眼 | 查看主输出，选择适合 Android/Windows/NAS 的导出 | 能找到普通 REALITY、普通 CDN、可选 ECH 和 NAS 配置入口；普通操作不要求理解 JSON 字段 |
| U02 复制与扫码 | 分别复制 URI、扫描真实 PNG | 一次导入得到正确名称；长链接不截断，图过大时准确说明并保留可复制 URI |
| U03 选择 ECH | 导出并导入节点 3 ECH 变体 | 清楚是额外客户端选择、当前是否验证；基础节点仍在，服务端不被重装 |
| U04 修改备注 | 编辑、保存、重新连接 | ECH/Encryption/extra 等不丢失；保留原编号与变体标识 |
| U05 ECH 故障 | 按提示定位查询或握手问题，并手动选普通节点 | 有具体下一步，用户知道所选普通节点未启用 ECH；没有隐蔽降级 |
| U06 NAS 启动 | 保存原生 JSON，按镜像说明启动测试容器 | 无需自己把 URI 翻译成 JSON；卷路径、监听与宿主端口明确，没有残留占位符 |
| U07 查询旧结果 | 关闭 SSH 后重新进入查看/导出 | 入口易找；查看不会轮换凭据或改服务；文件丢失时给出明确恢复步骤 |
| U08 更新凭据 | 测试机显式改 UUID/路径后重新导入 | 告知受影响节点与需重导入的客户端；旧 PNG/JSON 不冒充新产物 |
| U09 无法使用可选功能 | 在无 IPv6、无可信 H3 证书或未知客户端能力时查看输出 | 清楚显示原因，普通节点仍可使用；不显示“已可用”假成功 |
| U10 返回与错误输入 | 菜单返回、取消、输入非法值、重复导出 | 无误改配置、无无界等待、无悄悄覆盖不相关文件；提示与退出状态一致 |

完整交互目标：基础 GUI 导入不手改 JSON；NAS 不手工拼接 Xray 字段；所有失败都能找到下一步；复制 URI 与扫码结果一致。记录每项完成耗时、额外询问次数、误操作和需人工修补点，再据此减少重复输入与难懂提示。网络下载等待与界面操作耗时分别记录。

用户正常流程只显示做决定需要的内容；配置全文、原始错误和研究来源放到详情或诊断，不把本计划中的术语全部堆到安装结束页。

## 7. R5：持续连接、维护与追新

1. 在固定候选上测试短请求、并发、至少各 64 MiB 双向传输；另做持续超过 10 分钟的流量、只有上传、只有下载及业务空闲后再发送。对照 Cloudflare 当前 125 秒等连接限制记录实际行为，不要求所有应用连接永不重连。
2. 对空闲场景分别记录“原连接是否断开”“新请求能否重建”“已有 SSH/应用会话能否继续”，不能只测重连后网页可开就称空闲流完全正常。
3. 覆盖三次 VPS 重启、测试 Docker 重启、配置重复应用、显式凭据变更与重新导入。完整故障注入按 W02-R/W04-R/W08/W12 和上方矩阵执行；旧 T08 只作追溯。
4. 自动续证使用受控环境验证调度与失败恢复，再检查真实公开证书。ECH 轮换与源站证书续期分开记录，两者不是同一种更新。
5. 固定组合观察至少 72 小时，再延伸至同组合 7 天形成正式证据。记录连续时间、请求错误/重试、连接恢复、内存/FD/磁盘、日志增长和人工干预；不能只写均值或以达到时长代替问题关闭。
6. 若观察期间上游发布新版，另建候选测试并记录新 tag，不自动升级这台观察实例后继续累计旧时长。后续按 latest 策略追新，无需把每次发布都变成重新等待七天的前置审批。

## 8. 报告模板与实施 AI 交付要求

报告存放在 `docs/validation/YYYY-MM-DD-<candidate>.md`，由实施者在实际执行后创建。可公开报告使用脱敏配置与证据索引，完整凭据留在受限测试产物中。

```yaml
status: 未执行
candidate:
  xtun_ref: 待填
  xtun_commit: 待填
  xray_tag: v26.9.9
  xray_commit: 52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120
  asset_sha256: 待实际下载核验
  parameter_revision: 2（旧安装未迁移时按实际状态填写）
environment:
  os_arch: 待填
  client_app_and_version: 待填
  actual_core_version: 待填
  docker_image_digest: 不适用或待填
  network_and_time: 待填
  cloudflare_zone_settings: 待填
result:
  node_and_variant: 待填
  import_method: URI或PNG或原生JSON
  runtime_fields: 未检查
  transport_and_hash: 未执行
  path_evidence: 未执行
  ech_query_and_source: 不适用或未执行
  ech_acceptance_evidence: 不适用或未执行
  ech_negative_tests: 不适用或未执行
  rotation_observed: 未观察
  first_attempt_failures: 未统计
  recovery_actions_and_time: 未执行
  observation_duration: 0
  usability_case_ids: 待填
  remaining_issues: 待填
```

同一客户端的各节点/变体逐行记录通过、失败、未执行或不适用，不用一个总勾选覆盖整个矩阵。填写 `docs/COMPATIBILITY.md` 时只转入有准确版本和实测证据的结论，源码存在字段仅标为“源码支持”。

实施者最终交付：可复现的代码/ref、按 W13 完成的 baseline/latest/migration 证据、实际安装命令与输入说明、三端导入步骤、参数流向与内容/路径验证、ECH 正负测试、失败恢复方法、两轮人工交互问题清单。当前 latest-check 已运行候选完整 smoke 与原生传输，baseline CI 增加历史迁移、官方客户端容器和三系统安装矩阵；各次实际结果及范围写入报告，不以工作流存在代替通过。没有完成的项目保留未执行状态；不得凭菜单截图判断整套节点已稳定可用。
