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
- `install_xray_runtime`：对 `/usr/local/bin/xray`、`/var/log/xray`、`/var/lib/xray`、`/usr/local/share/xray`（geo 资源）与 `/usr/local/etc/xray`（配置目录）做同样的首次接管登记。
- **接管机制支持目录（H33）**：`record_takeover_original` 对目录改用 `mktemp -d`，`restore_takeover_original` 增加目录分支（先拷进临时目录并校验，再移除目标并改名——`mv -fT` 不能覆盖已存在的非空目录）。文件路径行为不变。
- **安装前告知（D40）**：新增 `install_takeover_report`，在只读检查的「端口与资源归属」里列出安装前已存在、会被接管的托管路径（unit 附带 enabled/active 状态）；安装摘要增加一行「接管: 覆盖安装前已存在的托管路径，卸载时按登记还原」。不再静默接管。
- 卸载：登记为「接管前已存在」的 `XRAY_SERVICE_FILE` / `XRAY_BIN` / `XRAY_LOG_DIR` / `XRAY_STATE_DIR` / `XRAY_ASSET_DIR` / `XRAY_CONFIG_DIR` 走还原分支而不是删除；文件还原后按记录恢复启用/运行状态；报告写明「已还原」。
- 新增 `record_takeover_original_service_state` / `restore_takeover_original_service_state`（复用 `service_enable_state` / `service_active_state`）。
- 反过来，xtun 自己创建的路径登记为 `existed=0`，卸载仍按删除处理，行为不变。

## 5. 验证

- 自动：新增 `run_install_takeover_notice_case`（安装前告知：不存在时无段落、存在时逐条列出并带 unit 状态）、`run_xray_takeover_record_case`（安装侧登记 unit/核心/日志/状态/资源/配置六条路径与运行状态）和 `run_uninstall_takeover_restore_case`（卸载侧逐条还原，并确认 xtun 写进宿主目录的内容被换回宿主原件）；`run_uninstall_ownership_case` 补反向断言，确认 xtun 自建的 unit/核心仍被删除。
- canonical smoke：**256 组通过**（原 253 + 3 新增，`smoke ok`）；ShellCheck 改动文件 0 发现。
- 真机 cycle 3（unit + 核心）：登记表出现 `/usr/local/bin/xray 1 … 8255dd93…` 与 `/etc/systemd/system/xray.service 1 … ee1bf845…`，`service-state/xray.service.state` 为 `ENABLED=enabled`/`ACTIVE=inactive`；卸载后两条路径逐字节还原、enabled 恢复。
- 真机 cycle 4（含目录）：登记表新增 `/var/log/xray 1 …` 与 `/var/lib/xray 1 …`，原件目录被复制到 `/var/lib/xtun/originals/var/log/xray`、`.../var/lib/xray`；卸载报告四条「已还原」，两条目录与 unit/核心摘要全部与安装前一致。**还原后直接 `systemctl start xray` 即成功（443 由 xray 持有），没有再手工重建目录**，证明 H33 已修复。
- 真机 cycle 5（告知 + 资源/配置登记）：安装日志「端口与资源归属」出现
  `待接管（安装前已存在；卸载时会按登记还原）:`，逐条列出
  `/etc/systemd/system/xray.service（enabled/inactive）`、`/usr/local/bin/xray`、`/usr/local/share/xray`、`/usr/local/etc/xray`、`/var/log/xray`、`/var/lib/xray`；摘要出现「接管: …」一行；登记表含 share/config 两条。
- 真机 cycle 5b（完整安装 → 卸载）：卸载报告六条「已还原安装前的…」，`/usr/local/share/xray` 内容为宿主原件（`foreign-geoip` 夹具），核心与 unit 摘要与安装前一致。
- cycle 5 也顺带验证了拒绝覆盖的分支：宿主 `/usr/local/etc/xray/config.json` 不是合法 Xray JSON 时，安装在写配置阶段因迁移读取失败（jq 报错）回滚，回滚把 unit、核心、资源目录、配置目录**全部还原**——宁可失败也不清空宿主配置，属于合理行为。

## 6. 残留（未在本次修复）

- **宿主 config.json 不合法时的提示**：此时安装会因配置迁移读取失败而回滚（见 §5）。当前行为是"拒绝覆盖"，但日志只给 jq 错误，用户不容易看出是自己的配置无法迁移；是否加一句明确提示，另行评估。

## 7. 追加：共享服务误判（H34，同日修复）

§6 原先记的「共享 HAProxy 遗留」不是接管还原的问题，而是**判定依据错了**：`managed_service_preinstalled` 只看包是谁装的（`package_installed_by_xtun`），于是「宿主装过 haproxy/nginx 但从没启用」被当成"共享在用"保留——xtun 自己起来的 haproxy 继续占着 443、`/etc/haproxy/haproxy.cfg` 不清、卸载恒返回 1，还原后的宿主 xray 起不来。

**修复**：

- 安装写配置、起服务之前记录 `haproxy.service` / `nginx.service` 的首次接管状态（复用 H31 的服务状态机制；记录点放在 `write_runtime_managed_files`，不改用户工作区里已改动的 `generators.sh`）。
- `managed_service_preinstalled` 改为：包不属于 xtun，**且**服务安装前 active/enabled，才算共享在用；否则按 xtun 引入处理（停用 + 清理）。没有状态记录的老安装保守地按共享在用处理，行为不变。
- 卸载清理原件登记表后，顺手 `rmdir` 其空的父目录 `/var/lib/xtun`。

**验证**：

- 自动：新增 `run_uninstall_idle_preinstalled_service_case`（包预装但服务未启用 → 停用、清配置、无「未能确认」、退出 0）；`run_uninstall_ownership_case` 补上 `ENABLED=enabled/ACTIVE=active` 状态记录，显式钉住"共享在用仍保留"这条分支。
- canonical smoke：**257 组通过**；ShellCheck 干净。
- 真机 cycle 6：预装但停用/禁用的 haproxy/nginx，安装时记录为 `ENABLED=installed`/`ACTIVE=inactive`；卸载后两者 `inactive`+`disabled`、`/etc/haproxy/haproxy.cfg` 与 `/etc/nginx/conf.d/xtun.conf` 均被删除、`443/80 空闲`、报告无任何「未能确认」并清理了原件登记表（即退出 0）；unit/核心/日志/状态全部还原后，**直接 `systemctl start xray` 即占住 443，没有手工停任何服务**。
