# 请求示例（不是已部署节点）

- `raw-tls.json`：稳定版 RAW + TLS，不执行内核也可生成结构。
- `xhttp-reality.json`：固定预发布版 XHTTP + REALITY；必须替换地址、SNI 与 target，
  并用获准执行的对应 `--binary` 生成密钥。示例 target 并非可用的公共目标。

省略 UUID/私钥表示生成时创建独立凭据；这些文件不包含可复用真实凭据。
示例域名与证书路径是占位符。生成不证明域名、证书、target 或握手可用。
完整契约见 [generation.md](../../references/generation.md)。
