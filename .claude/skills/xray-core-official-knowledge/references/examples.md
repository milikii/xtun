# 版本化配置示例

- [v26.3.27 稳定版](../examples/vless-xhttp-reality-v26.3.27.json)：network、clients。
- [v26.9.9 预发布](../examples/vless-xhttp-reality-v26.9.9.json)：method、users。

文件是带 meta、server、client 的示例包装，**不能整份作为 Xray 配置传入**。
使用时选出 server 或 client 对象，替换 UUID、地址、REALITY 私钥/对应 password、
shortId 和经过核实的 target/SNI。运行 `xray x25519` 生成实际密钥，按用户网络约束
参照官方 [REALITY 文档](../docs/stable/config/transports/reality.md) 选择目标。

两端 UUID、shortId、路径必须按协议匹配；客户端 password 来自服务端私钥，
serverName 必须被服务端允许。target 是服务端转发目标，address 是客户端连接的代理地址，
两者不是同一个角色。不要在客户端填写 target/privateKey。

示例省略 XMUX，使用各版本自身默认值；没有将历史 maxConcurrency=16–32 固化进去。
XHTTP + REALITY 的 mode 使用 auto，实际模式由对应版本运行逻辑决定。
VLESS encryption/decryption 的 none 是该示例的选择，不代表协议不支持 VLESS Encryption。

示例只验证替换为临时测试数据后能否被对应二进制接受。
配置检查不验证 target 适用性、实际握手、客户端生态兼容性或网络性能。
详细结果见 [验证记录](validation.md)。
