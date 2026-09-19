# 新测试 VPS 全新安装与全自动套件验证报告（2026-09-19）

> 执行日期：2026-09-19。执行机器：测试 VPS `172.239.117.239`（Debian GNU/Linux 12 bookworm、x86_64、内核 6.1.0-47-amd64、1 vCPU、约 1.9 GiB 内存）。
> 候选：仓库 `main` 的 `cd8a9aa6c1b9fc17716d9fc67de76611e6699b13`，从公开入口安装。
> 方法：公开引导入口下载 → 全新非交互安装 → 在真实 systemd 的 Debian 12 上执行全部自动套件 → 维护路径 → 卸载 → 还原宿主原有服务。
> 私有现场与原始日志保留在测试 VPS `/root/xtun-evidence/` 与本机 `/root/xtun-vps-backups/`，不进入公开仓库；本报告只记录去秘密结果。
> 本文是执行记录，不替代 [当前入口 PLAN](PLAN.md)、[详细计划](PLAN-UX-RELIABILITY.md) 和[决策](DECISIONS-UX-RELIABILITY.md)。

## 1. 结论

1. **公开入口全新安装成功**：依赖安装、核心下载校验、Xray/nginx/HAProxy 配置校验、服务启动、5 个基础节点与二维码全部正常，退出码 0。
2. **全部自动套件通过**：canonical smoke、两套 PTY、原生双向传输、历史迁移、systemd/文件系统/归属恢复与三组部署故障注入，退出码全为 0。
3. **维护路径行为正确**：`recover` 无操作、同值 `change-path`/`change-uuid` 为 noop、同版本 `upgrade` 识别可信身份后 noop，前后文件与服务 PID 快照完全一致。
4. **卸载干净且宿主已还原**：`uninstall --yes` 删除全部托管文件、停止服务、保留软件包；测试前备份的 VOXI Xray / Hysteria / OpenVPN-vpngate 现场已完整恢复并运行。
5. **R2 根因确认**：生成器的 nginx 版本判断本身正确；旧测试 VPS 的 nginx 故障是"配置由 ≥1.25.1 环境生成、二进制回落到 1.22.1"的环境漂移。
6. **R3 判定为 CI 抖动**：HEAD 的两次 CI 失败在本机真实 Debian 12 amd64 上无法复现，且两次失败点不同、同一 debian:12 baseline 在其中一次为成功，属非确定性，不是确定性代码回归（详见 §7）。

## 2. 环境与候选身份

| 项目 | 值 |
| --- | --- |
| 主机 | `172.239.117.239`，Debian 12 bookworm，x86_64，1 vCPU，约 1.9 GiB |
| 安装入口 | `https://raw.githubusercontent.com/milikii/xtun/main/xtun.sh` |
| 入口 SHA256 | `1d8cf6e25d151892f56ad840d8ab990f93bc6c9ee36c38064ee3339f35de5c14` |
| 解析提交 | `cd8a9aa6c1b9fc17716d9fc67de76611e6699b13`（与 `origin/main` 一致） |
| 来源 | `github-commit` |
| bundle 内容签名 | `d446b9905ec98c47987d48784dc0acd00863591db9b8b9801adf35dd623662aa` |
| 脚本 / state / 参数 | `1.1.0` / schema `2` / 修订 `2` |
| 核心 | `v26.9.9 / 52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120`，身份 `c4ae6798c38e` |
| 依赖版本 | nginx `1.22.1-9+deb12u10`、haproxy `2.6.12-1+deb12u3` |

> 说明：`d446b990…` 是 bundle 的**内容签名**，不是提交；提交以 `.xtun-bundle.json` 的 `commit` 字段为准。

## 3. 全新安装

安装命令（公开入口，非交互，使用自签证书，不启用 WARP）：

```bash
curl -fsSL https://raw.githubusercontent.com/milikii/xtun/main/xtun.sh -o xtun.sh
bash xtun.sh install --non-interactive --task fresh \
  --xray-version v26.9.9 \
  --server-ip 172.239.117.239 \
  --node-label-prefix TST \
  --reality-sni www.microsoft.com \
  --xhttp-domain cdn.example.com \
  --xhttp-path /assets/v3 \
  --cert-mode self-signed \
  --disable-warp
```

结果：**退出码 0**。关键观察点：

- 依赖包安装完成（haproxy/nginx/qrencode 等）。
- 核心解析到 v26.9.9，tag 指向提交 `52a412d9…`，下载并校验通过。
- `xray run -test`、`nginx -t`、`haproxy -c -f` 三项校验全部通过。
- xray / nginx / haproxy 三服务启动并 enable。
- 生成 5 个基础节点（1–5）与对应 PNG；节点前缀 `TST`。
- 监听符合预期：`*:443`(haproxy)、`127.0.0.1:8443`(nginx)、`127.0.0.1:2443/2444/8001`(xray)；默认 H3 关闭，未占用 UDP 443。
- `xtun diagnose` 摘要：**未发现关键问题**。
- nginx 1.22.1 上生成的是旧语法 `listen 127.0.0.1:8443 ssl http2;`，证明 `nginx_version_at_least 1.25.1` 分支工作正常。

## 4. 自动套件结果（xtun 已安装状态）

| 套件 | 命令 | 结果 |
| --- | --- | --- |
| canonical smoke | `bash tests/smoke.sh </dev/null` | **exit 0**，253 组，末尾 `smoke ok` |
| 安装 PTY 边界 | `python3 tests/install-boundary.py` | **exit 0**，68 PASS / 0 FAIL |
| 任务菜单 PTY 边界 | `python3 tests/task-menu-boundary.py` | **exit 0**，9 PASS / 0 FAIL |
| 原生传输与负例 | `python3 tests/native-transport.py` | **exit 0**，17 场景（6 正向 64 MiB 双向 + 11 负向拒绝） |
| 历史迁移矩阵 | `bash tests/migration.sh` | **exit 0**，3 组历史组合 |
| systemd 恢复 | `XTUN_TEST_ISOLATED_VPS=yes bash tests/systemd-recovery.sh` | **exit 0** |
| 文件系统恢复 | `XTUN_TEST_ISOLATED_VPS=yes bash tests/filesystem-recovery.sh` | **exit 0**，5 场景 |
| 归属/共享 HAProxy | `XTUN_TEST_ISOLATED_VPS=yes bash tests/ownership-systemd.sh` | **exit 0**，5 场景 |
| 部署故障（upgrade） | `bash tests/deployment-recovery.sh upgrade` | **exit 0** |
| 部署故障（update-script） | `bash tests/deployment-recovery.sh update-script` | **exit 0** |
| 部署故障（install-output-failure） | `bash tests/deployment-recovery.sh install-output-failure` | **exit 0** |

补充：卸载后再跑一次"仅依赖仓库、不依赖已安装系统"的子集（均以 `</dev/null` 干净 stdin 执行）——原生传输 **exit 0**、文件系统恢复 **exit 0**；迁移、systemd 恢复、归属套件按自身前置检查明确报"装上再跑"并退出（因为它们需要已安装的核心资源 `/usr/local/share/xray/geoip.dat`、`geosite.dat`），这是设计内的前置条件，不是回归。

> 与文档的差异：`REPORT-2026-09-15-CDE.md` 记 canonical smoke 为 252 组；`cd8a9aa` 新增 `run_cloudflare_cache_scope_case` 后为 **253 组**。

## 5. 维护路径

| 操作 | 结果 |
| --- | --- |
| `xtun recover --yes` | 无未完成托管操作，exit 0 |
| `xtun change-path --xhttp-path /assets/v3 --non-interactive` | 同值 noop："没有需要修改的内容"，exit 0；未写文件、未重启服务 |
| `xtun change-uuid --reality-only --reality-uuid <当前值> --non-interactive` | 同值 noop，exit 0 |
| `xtun upgrade --xray-version v26.9.9` | 可信同身份 noop："未替换文件、未创建备份、未重启服务"，exit 0 |
| `xtun apply-config`（干净 EOF） | 预览一次后提示"输入已结束，已取消当前操作"，exit 1；**未产生任何写入**（符合确认边界） |

前后快照（`config.json`、`node-meta.env`、`xtun-output.md`、QR `manifest.json` 摘要 + xray/nginx/haproxy MainPID）**完全一致**。

> 过程中曾出现 `apply-config` 连续重复提示的现象，经复核是测试脚本自身用 `bash -s` 把脚本文本喂给了 stdin 造成的假象：改用 `</dev/null` 后只提示一次即取消，产品行为正确。

## 6. 卸载与宿主还原

测试前该 VPS 已在运行用户自己的服务：`xray.service`（VOXI Wi-Fi Calling 的 VLESS REALITY，v26.3.27，TCP 443）、`hysteria-server.service`（UDP 443）、`openvpn-vpngate.service` 与 `vpngate-policy/health/refresh`。安装前已完整备份配置、unit、脚本、二进制、日志与网络/服务状态，并把归档另存到本机。

| 步骤 | 结果 |
| --- | --- |
| `xtun uninstall --yes` | exit 0；删除 `/usr/local/sbin/xtun`、`/usr/local/lib/xtun`、`/usr/local/bin/xray`、`/usr/local/etc/xray`、`/usr/local/share/xray`、`/etc/systemd/system/xray.service`、`/etc/haproxy/haproxy.cfg`、`/etc/nginx/conf.d/xtun.conf`、nginx drop-in、`/var/www/xtun-fallback`、`/etc/ssl/xtun`、输出与二维码、`/var/log/xray`、`/var/lib/xray`、`/var/log/xtun`、`/var/lib/xtun/originals`；软件包按设计保留 |
| 还原 | 解包配置与脚本、还原原二进制、`daemon-reload`、`enable --now` 四个 unit |
| 一处需手工补齐 | 原 unit 的 `ReadWritePaths=/var/log/xray /var/lib/xray` 指向 xtun 卸载时删掉的目录；重建两个目录（`xray:xray 0750`）后 xray 正常启动。**已在 `RESTORE.md` 记录** |
| 最终状态 | xray `active`（TCP `*:443`）、hysteria-server `active`（UDP `0.0.0.0:443`）、openvpn-vpngate 与 vpngate-policy `active`；xtun 已不在系统内 |
| SSH | 未改动：`sshd` active，`sshd_config` 摘要 `a79998dc…`、时间戳仍为 2026-05-09；root 口令最后修改日期 `2026-05-09`（本次未改密码） |

## 7. 对既有待办的更新

### 7.1 R2：旧测试 VPS 的 nginx 故障

本次在真实 nginx 1.22.1 上全新安装，生成器正确输出 `listen … ssl http2;`，`nginx -t` 与启动均通过。**生成器没有缺陷**；旧机 `194.195.251.247` 的问题是那份 `xtun.conf` 由 ≥1.25.1 的环境生成（生成时 `nginx_version_at_least 1.25.1` 为真），之后二进制回落到 1.22.1，配置与新二进制不匹配。修复方向不变：在旧机上用当前二进制重建配置，或恢复 ≥1.25.1 的 nginx。

### 7.2 R3：HEAD 的 CI 红灯

| 运行 | 提交 | 结论 | 失败点 |
| --- | --- | --- | --- |
| 35398046761 | `cd8a9aa` | failure | install-smoke (debian:12, baseline) → Run install smoke |
| 35370804957 | `cd8a9aa` | failure | install-smoke (ubuntu:24.04, baseline) → Wait for systemd |
| 35280649878 / 35165787041 | `27aa967` | success | — |

判定为**环境抖动，非确定性回归**，依据：两次失败点不同；`debian:12 baseline` 在一次失败、在另一次成功；本机真实 Debian 12 amd64 全新安装 exit 0。仓库 job 日志 API 返回 403（需 admin），未能读到容器内细节，因此保留"需一次新 CI 运行确认"的说法。

### 7.3 R1：`lib/generators.sh` 的私有 DSH 路由

工作区那一行（`use_backend be_dsh_gateway if { req.ssl_sni -i dsh.564672.xyz }`）**本次未改动、未提交**。它只影响该机器自身的反代域名，不属于 xtun 产品范围；提交时已按文件挑选，未把它带入。

## 8. 本次未覆盖（仍为外部验收）

- **G1 强制断电**：本 VPS 无带外电源/控制台接口，SIGKILL 与 guest reboot 按决策不算数，未执行。
- **G2/G4 真人与三端**：无操作者、无 Android/Windows/NAS 设备，未执行。
- **G3 公共 ACME**：无受控公共域名与 DNS API，未做真实签发/续期；证书部分只用测试自签。
- **G5 观察与发布**：72 小时/7 天观察、正式 tag/release、生产迁移未做。
- **W17**：PQ/签名、性能、静态站研究未做。
- 容器化安装矩阵（Debian 13 / Ubuntu 24.04 / 官方客户端容器）本次未跑：该 VPS 无 Docker；由 CI 覆盖，本轮只做了真实 Debian 12。

本轮结果只覆盖**该 VPS 的系统与架构**，不外推到 Debian 13、Ubuntu 24.04 或历史 arm64 组合，也不替代真实 CDN、GUI、NAS 与真人验收。

## 9. 证据位置

- 测试 VPS（私有）：`/root/xtun-evidence/`（`smoke-clean.log`、`pty-install.log`、`pty-menu.log`、`native/summary.json`、`migration.log`、各恢复套件日志、`results.txt`、`results-final.txt`、`maintenance.log`）。
- 本机副本（私有）：`/root/xtun-vps-backups/evidence-172.239.117.239-20260919/`。
- 宿主备份与还原步骤（私有）：`/root/xtun-voxi-backup-20260919-072403/RESTORE.md`（VPS）与 `/root/xtun-vps-backups/xtun-voxi-backup-20260919-072403/`（本机）。
