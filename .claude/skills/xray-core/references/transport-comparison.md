# 传输与安全层

核查基线：v26.9.9。构建支持见 [transport_internet.go](../source/config/transport_internet.go)，
稳定版参照 [对应文件](../source/stable/v26.3.27/infra/conf/transport_internet.go)。

| 传输 | 当前状态 | 需要注意 |
|---|---|---|
| RAW/TCP | 支持 | 常与 TLS/REALITY 组合；XTLS Vision 是 flow |
| XHTTP / SplitHTTP | 支持 | auto、packet-up、stream-up、stream-one；H1/H2/H3 与上下行分离 |
| gRPC | 支持，有弃用警告 | 可搭配 TLS 或 REALITY；官方迁移方向为 XHTTP stream-up H2 |
| WebSocket | 支持，有弃用警告 | 通常配 TLS；不能直接配置 REALITY |
| HTTPUpgrade | 支持，有弃用警告 | 通常配 TLS；不能直接配置 REALITY |
| mKCP | 支持且仍有更新 | 不与已移除的独立 QUIC transport 合并称为“均已过时”；伪装配置查 Finalmask |
| Hysteria | 支持 | 与 QUIC 参数和 Finalmask 的具体关系按版本核对 |
| 旧独立 HTTP/H2/H3 transport | 已移除 | 使用 XHTTP stream-one H2/H3 |
| 旧独立 QUIC transport | 已移除 | 不代表 XHTTP H3 或 Hysteria 不受支持 |

REALITY 是安全层，XTLS Vision 是协议 flow，二者不是与 WebSocket/XHTTP 同列的 transport。
RAW、XHTTP、gRPC 可选择 REALITY；实际握手兼容性另看服务端与客户端版本。

选择方案时沿用用户的 CDN、反代、客户端和网络约束，不把某种传输或参数组视为所有环境的最优配置。
设计依据见 [维护者说明](../citations/maintainer-intent.md)。
