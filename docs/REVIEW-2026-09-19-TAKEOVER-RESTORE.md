# 接管还原缺陷复核（2026-09-19）：宿主自带的 xray.service 与核心被覆盖后未还原

> 复核日期：2026-09-19。发现环境：测试 VPS `172.239.117.239`（Debian 12 amd64，1 vCPU）。
> 候选：`cd8a9aa` / `fa237af`（修复前），修复后在同一机器复验。
> 方法：真机安装-卸载循环；第一次循环人工移开宿主 unit，第二次、第三次保留现场直接安装。
> 本文记录缺陷、复现与修复；原始日志在测试机 `/root/xtun-evidence/` 与本机 `/root/xtun-vps-backups/`，不进仓库。

## 1. 结论

安装 xtun 到一台**已经有自己的 Xray 服务**的机器时：

1. 安装前检查的「端口与资源归属」只列 TCP/UDP 端口和 nginx 主配置，**不报告、也不确认已存在的 `/etc/systemd/system/xray.service`**；
2. 安装直接覆盖这个 unit，并覆盖 `/usr/local/bin/xray`；
3. 卸载把这两条路径当作"xtun 自己的"删除，**不还原宿主原来的 unit 与核心**。

这违反 D11（有归属证据才接管、恢复或删除资源）、D20.1（恢复只删除可证明为本次创建的托管路径）和 D20.4（恢复服务的实际操作前状态）。属于静默接管 + 卸载丢数据。

## 2. 复现

现场：该 VPS 原本运行用户自己的 `xray.service`（VOXI Wi-Fi Calling 的 VLESS REALITY，核心 26.3.27，unit 摘要 `ee1bf845…`，enabled + active）。

```bash
systemctl stop xray                 # 只停服务，保留 unit 文件（安装需要空的 443）
bash xtun.sh install --non-interactive --task fresh ... --disable-warp
# 安装日志的「端口与资源归属」没有任何一行提到 xray.service
xtun uninstall --yes
```

| 路径 | 安装前 | 卸载后（修复前） |
| --- | --- | --- |
| `/etc/systemd/system/xray.service` | 宿主 unit，`ee1bf845…` | **被删除**，宿主的 unit 丢失 |
| `/usr/local/bin/xray` | 宿主核心 26.3.27，`8255dd93…` | **被删除**，宿主核心丢失 |
| `/var/log/xray`、`/var/lib/xray` | 宿主服务的运行目录 | **被删除**，被还原的 unit 因 `ReadWritePaths` 指向不存在目录而无法启动 |

卸载退出码为 1，但原因是既有的「共享 HAProxy 配置清理未能确认」，与这三条路径无关；报告里这三条只写「已删除」。

## 3. 影响

- 先有自己的 Xray/REALITY 服务、再装 xtun 的用户，卸载后服务定义和核心消失，且安装阶段没有任何提示。
- 即使把 unit 找回来，`/var/log/xray`、`/var/lib/xray` 被删也会让它起不来。
- 触发条件很常见：用户已有的 `xray.service` 处于停止/失败状态时，443 是空的，安装会顺利通过。

## 4. 修复（本次落地）

- `write_xray_service`：首次遇到已存在的 unit 时 `record_takeover_original`，并记录当时的启用/运行状态（`/var/lib/xtun/originals/service-state/<unit>.state`，只认第一次）。
- `install_xray_runtime`：对 `/usr/local/bin/xray` 做同样的首次接管登记。
- 卸载：登记为「接管前已存在」的 `XRAY_SERVICE_FILE` / `XRAY_BIN` 走还原分支而不是删除；文件还原后按记录恢复启用/运行状态；报告写明「已还原」。
- 新增 `record_takeover_original_service_state` / `restore_takeover_original_service_state`（复用 `service_enable_state` / `service_active_state`）。
- 反过来，xtun 自己创建的 unit/核心登记为 `existed=0`，卸载仍按删除处理，行为不变。

## 5. 验证

- 自动：新增 `run_xray_takeover_record_case`（安装侧登记 unit/核心与状态）和 `run_uninstall_takeover_restore_case`（卸载侧还原 unit/核心并恢复 enabled+active）；`run_uninstall_ownership_case` 补反向断言，确认 xtun 自建的 unit 仍被删除。
- canonical smoke：**255 组通过**（原 253 + 2 新增，`smoke ok`）；ShellCheck 改动文件 0 发现。
- 真机（同一台测试 VPS，修复后 cycle 3）：安装日志与登记表出现
  `/usr/local/bin/xray  1  …  8255dd93…` 与 `/etc/systemd/system/xray.service  1  …  ee1bf845…`，
  `service-state/xray.service.state` 为 `ENABLED=enabled` / `ACTIVE=inactive`；卸载后两条路径逐字节还原（摘要一致），enabled 状态恢复，报告写「已还原安装前的 xray.service」「已还原安装前的核心二进制」「已按接管前记录还原启用/运行状态」。

## 6. 残留（未在本次修复）

- **H33：宿主服务的运行目录仍被删除**。`/var/log/xray`、`/var/lib/xray` 不在接管登记范围内，卸载直接删。对于把 `ReadWritePaths` 指到这两个路径的宿主 unit（本例就是），还原后的服务仍起不来，需要人工重建目录。正确做法是把这两个目录也纳入「接管前已存在则不删除」的范围；现有 `record_takeover_original` 对目录不适用（它用 `mktemp` 建普通文件再 `cp -aT`，遇到目录会失败），需要先扩展该机制或另设登记，本次未做。
- **安装摘要仍不报告已存在的 `xray.service`**。修复解决了"还原"，但没有解决"接管前告知"。建议在「端口与资源归属」里增加一行，或在交互安装中把它列为需要确认的影响项。
- 同类路径 `/usr/local/share/xray`（宿主自带 geo 资源时）与 `/usr/local/etc/xray` 目前仍按删除处理，未评估。
