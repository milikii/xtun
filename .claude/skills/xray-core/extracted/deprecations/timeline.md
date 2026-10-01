# 别名、弃用与移除时间线

分类含义：**别名**仍可解析；**弃用**通常警告但仍工作；**移除**在构建或运行路径拒绝。
不能仅依据字段是否存在于 Go struct 判断状态。下面的首次版本来自官方提交与 tag 包含关系。

| 首次进入的版本 | 变化 | 当前状态/依据 |
|---|---|---|
| v24.9.7 | 移除旧独立 QUIC transport | [提交](../../source/commits/patches/9a953c07.patch)；XHTTP H3 是另一种传输 |
| v24.10.16 | REALITY 增加 target，兼容 dest | [提交](../../source/commits/patches/75729ce7.patch) |
| v24.12.15 | 移除旧独立 HTTP transport | [提交](../../source/commits/patches/ae62a0fb.patch)；迁移 XHTTP stream-one |
| v25.3.6 | REALITY 增加 password，兼容 publicKey | [提交](../../source/commits/patches/dde0a4f2.patch)；改名方向不能写反 |
| v26.1.31 预发布 | allowInsecure = true 返回移除错误 | [提交](../../source/commits/patches/2c92339f.patch)；[v26.2.6 稳定说明](../../source/releases/v26.2.6.md) |
| v26.5.3 | 移除 echForceQuery，配置 ECH 后强制使用 | [版本记录](../../source/commits/v26.5.3.md)；稳定版早期默认值不适用于新版 |
| v26.5.9 | 入站 users 兼容 clients/accounts | [提交](../../source/commits/patches/c42deab5.patch)；具体协议分别核对 |
| v26.7.11 | method 兼容 network | [提交](../../source/commits/patches/fb548f54.patch) |
| v26.7.11 | 限制公网无加密 VLESS/Trojan 出站；移除 VMess/SS 的 none/zero/plain | [提交](../../source/commits/patches/d7fa2076.patch)；不要概括成移除整个协议 |
| v26.9.8 | 拒绝 proxySettings；Freedom 解析策略迁往 sockopt | [提交](../../source/commits/patches/3e2f040c.patch)；旧 Freedom 非 AsIs 策略先做兼容迁移 |

当前 gRPC、WebSocket、HTTPUpgrade 的弃用警告见
[配置构建](../../source/config/transport_internet.go)：仍可使用，不推断具体未来移除日期。
`security: "xtls"` 的旧模式已拒绝；XTLS Vision 使用 flow 搭配 TLS/REALITY，不能混淆。
