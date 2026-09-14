# 版本边界

来源与完整 SHA 见 [sources.yaml](../sources.yaml)。本次核查日期：2026-09-14。

| 轨道 | 固定版本 | 本地证据 |
|---|---|---|
| 最新稳定版 | v26.3.27 | [源码](../source/stable/v26.3.27/)、[发布说明](../source/releases/v26.3.27.md) |
| 最新预发布 | v26.9.9 | [配置](../source/config/)、[传输](../source/transport/)、[运行实现](../source/runtime/) |
| main 开发版 | c412e77a9b712082ac9ebf27fa793951cb5a7d85 | [发布后变更](../source/commits/dev-after-v26.9.9.md)、[两个文件](../source/dev/) |
| 官网 | 46c680b71b18b48b9cc6e55e596405bd0442ab8a | [滚动文档](../docs/stable/)；目录名不代表 release 匹配 |

`v26.4.13` 至 `v26.9.9` 在此次 GitHub API 查询中均为预发布。
没有“看到日期更新就升级 stable”的规则；查看 GitHub prerelease 状态和 latest 接口。

## 对本机配置影响较大的区别

| 事项 | v26.3.27 | v26.9.9 |
|---|---|---|
| 空 XMUX 的连接控制 | maxConcurrency = 1 | maxConnections = 3 |
| 传输名称字段 | network | method；兼容 network |
| VLESS 入站用户列表 | clients | users；兼容 clients |
| outbound.proxySettings | 接受旧链式配置 | 构建拒绝，迁移 sockopt.dialerProxy |
| Freedom settings.domainStrategy | 原配置入口 | 非 AsIs 值兼容迁移到 sockopt.domainStrategy，并警告 |
| Freedom finalRules | 尚无该功能 | 已支持，具有默认策略；走 dialerProxy 时跳过 |
| REALITY 默认 minClientVer | 未设置 | 未设置，但新依赖库另有 ClientHello 限制 |
| TLS allowInsecure = true | 拒绝 | 拒绝 |
| TLS fingerprint = unsafe | 接受 | 接受；不能用于 REALITY |

上述区别以两套本地源码为准，尤其查看各版 `infra/conf`、`proxy/freedom`、
`transport/internet/splithttp` 与 `go.mod`。`network/clients` 是兼容别名，
不需要仅为换名而强迫已有可用配置迁移。

## REALITY 版本限制曾改变

- `v26.7.11`：加入默认 `minClientVer: 26.3.27`。
- `v26.9.8`：注释掉默认版本限制，并将依赖升级至
  `v0.0.0-20260908062103-8cdf7bf9c7f0`。
- 新依赖检查 ClientHello：必须存在合法 `X25519MLKEM768` key share，且位于
  可选的 `X25519` 之前；不符合条件不会被接受为合法 REALITY 客户端。

查看 [Core 的调整](../source/commits/patches/47cfe999.patch) 与
[依赖的 Server 实现](../source/dependencies/reality/v26.9.9/tls.go)。
取消默认版本号限制不能推导成所有旧客户端均恢复兼容；配置解析成功也不能保证握手成功。

## 旧版本问题

这份技能不是所有历史版本的完整源码仓库。它覆盖两套源码基线、30 条发布记录、
稳定版到最新预发布的 241 个提交及选定历史补丁。处理其它版本时先定位 tag，
用官方提交核对字段引入、别名保留、弃用和运行行为；不要仅凭版本日期猜测。
