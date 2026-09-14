# 维护者公开说明

这些材料解释设计意图，不自动证明当前默认值或某网络的实际效果。原文快照与获取时间见
[evidence-manifest.json](evidence-manifest.json)。发言中的他人引用按引用处理；已合入行为继续核对源码。

| 主题、作者与时间 | 原始来源 / 本地快照 | 可采用的解读与边界 |
|---|---|---|
| XHTTP 设计，RPRX；抓取 2026-09-14，未记录原帖最后编辑时间 | [Discussion #4113](https://github.com/XTLS/Xray-core/discussions/4113) / [正文提取](raw/xhttp-4113.txt) | official-statement：HTTP 中间盒、分包/流式上传、流式下行、上下行分离和 XMUX。文章中的旧默认值要按版本重核 |
| 变体兼容，RPRX，2025-12-13 | [原评论](https://github.com/XTLS/Xray-core/pull/5414#issuecomment-3649096826) / [快照](raw/xhttp-5414-3649096826.json) | maintainer-suggestion：修改默认头名称会破坏新旧兼容，建议用选项开放；不能推导成任意更名即可稳定规避检测 |
| 发布与设计迭代，RPRX，2026-01-28 | [原评论](https://github.com/XTLS/Xray-core/pull/5414#issuecomment-3812196530) / [快照](raw/xhttp-5414-3812196530.json) | official-statement：讨论先发版再迭代，并要求未配置新选项时保持原版连接兼容；不是所有变体已定型的声明 |
| 上下行独立，RPRX，2026-01-30 | [原评论](https://github.com/XTLS/Xray-core/pull/5414#issuecomment-3823861456) / [快照](raw/xhttp-5414-3823861456.json) | official-statement：“上下行分离的配置是无关的”；允许不同 CDN 和不同变体，不能擅自要求二者相同 |
| 设计优先级，RPRX，2026-02-19；更新 2026-07-28 | [BBS #19](https://github.com/XTLS/BBS/issues/19) / [快照](raw/design-priorities-19.json) | official-statement：区分宏观原理、认证/加解密、反识别，权衡场景、收益和维护成本；观点、地区观察及规划不当成普遍事实或已发布功能 |
| Chrome 指纹与连接数，RPRX，2026-05-28；更新 2026-05-29 | [原评论](https://github.com/XTLS/Xray-core/pull/6181#issuecomment-4567373533) / [快照](raw/reality-clienthello-6181.json) | maintainer-suggestion：特定背景下建议 XHTTP 连接数 6、讨论保留现代指纹。正文包含第三方邮件反馈；后来默认值已改成 3 |

当前默认值见 [按版本整理的默认表](../extracted/defaults/versioned.md)，
REALITY 版本与握手变化见 [版本指南](../references/version-guide.md)。
无须把原文中的争论或与技术无关内容带入配置建议；引用时保留足以判断范围的上下文。
