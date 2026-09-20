# 首轮真机（手机）验证记录（2026-09-20）

> 记录人：项目维护者（操作者本人）。设备与网络由操作者提供；本文只记录操作者报告的结果与仍缺的检查项。
> 被测环境：测试 VPS `172.239.117.239`，xtun 候选 `f53a4e5`，证书 `acme-http`（Let's Encrypt），域名 `li.miliki.us.ci`（Cloudflare 代理）。
> 相关：[HTTP-01 报告](REPORT-2026-09-20-ACME-HTTP01.md)、[测试手册](TEST-VPS-RUNBOOK.md)、[发布就绪清单](RELEASE-READINESS-1.2.0.md)。

## 1. 结论

操作者在手机上导入并连接，报告以下节点**可用**（能连通并使用）：

| 节点 | 类型 | 结果 |
| --- | --- | --- |
| 1 `LI-REALITY` | VLESS + REALITY + Vision | 可用 |
| 2 `LI-XHTTP-REALITY` | XHTTP + REALITY（含 VLESS Encryption） | 可用 |
| 3 `LI-XHTTP-CDN` | XHTTP + TLS（真实域名 + 公网可信证书） | 可用 |
| 3 `LI-XHTTP-CDN-ECH` | 同节点 3，CDN TLS 层启用 ECH（`ech=` 指向 AliDNS DoH 查询真实域名 ECHConfig） | 可用 |

这是 G2「第一轮真人 + 基础节点真实传输」与 G4「ECH 组合」的第一手证据：**基础节点 1/2/3 与 ECH 变体在真实设备与真实网络上连通**。ECH 通过说明该域名 HTTPS 记录里的 ECHConfig 可被客户端取到、Cloudflare 边缘接受该握手。

## 2. 尚未记录 / 仍缺

按 [D16](DECISIONS-UX-RELIABILITY.md#d16) 与 [runbook](TEST-VPS-RUNBOOK.md)，以下项目**本次没有记录**，不能算已通过：

- 客户端应用名与版本（v2rayNG / 其它）、系统版本、设备型号。
- 网络类型（蜂窝/Wi-Fi/运营商）与实际地理接入。
- 双向内容校验（下载与上传的具体结果、速度量级）。
- 导入后「编辑节点再保存」字段是否保留。
- 节点 4/5（split：CDN 上行 / REALITY 下行，及其反向）未报告。
- 节点 3 的普通变体与 **ECH 变体均已通过**；ECH 的 DoH/边缘细节（解析到的 ECHConfig 版本、是否命中 AliDNS 缓存）未留证据。
- Windows v2rayN 与 Debian NAS Docker（G4 的其余两端）。
- IPv6、H3、WARP、xpadding 等组合。

## 3. 本轮导出的 ECH 变体（待测）

`export-client --node 3 --variant ech` 成功；`li.miliki.us.ci` 的 HTTPS 记录（type 65）当前带 ECH 配置，导出值使用真实 serverName + AliDNS DoH 查询：

```text
vless://6b1abd97-13dd-4ca0-b11b-7f181e46ef2b@li.miliki.us.ci:443?...&type=xhttp&mode=auto&path=%2Fassets%2Fv3&host=li.miliki.us.ci&ech=https%3A%2F%2Fdns.alidns.com%2Fdns-query#LI-XHTTP-CDN-ECH
```

（完整链接与二维码在测试机 `/root/xtun-qr/` 与维护者会话中，不入库。）

## 4. 对闸门的影响

- **G2**：从「待操作者」推进到「首轮已开始，基础节点 1/2/3 真实连通」；补齐 §2 的应用/版本、双向内容与编辑保留后可关闭首轮。
- **G4**：Android 端有初步结果；Windows 与 NAS 仍待。
- 本记录只覆盖一次操作者报告，不外推到其它设备、网络或客户端。
