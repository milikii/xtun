# 维护与校验

依赖：Python 3.9+、Git、PyYAML（[requirements.txt](../scripts/requirements.txt)）。
脚本使用本地官方克隆与下载的 API JSON，不会自行联网或替你将 main 当作最新发布。

1. 查询 GitHub releases 与 releases/latest，区分稳定、预发布和 main。
   刷新 XTLS/Xray-core、XTLS/Xray-docs-next、XTLS/REALITY 官方克隆。
2. 修改 [sources.yaml](../sources.yaml) 的完整 SHA、版本与提取范围。
   REALITY 的 SHA 必须来自所选 Core tag 的 go.mod，不能简单取依赖仓库 HEAD。
3. 用同步脚本先查看计划，再写入。过期文件会要求显式检查，脚本不会静默删除。

```bash
python3 scripts/snapshot.py sync --core /path/Xray-core --docs /path/Xray-docs-next --reality /path/REALITY
python3 scripts/snapshot.py sync --core /path/Xray-core --docs /path/Xray-docs-next --reality /path/REALITY --write
python3 scripts/history.py --core /path/Xray-core --releases-json /path/releases.json --write
```

4. 检查原始差异，再修改参数、默认值、兼容表与逐版摘要。发布正文仅有跳转链接时使用相邻
   tag 的提交索引。引用维护者新观点时保存原文、作者、时间和上下文，更新 citations 的证据清单。
5. 原样保留官方文档，把文档与实现差异写入
   [source-conflicts.md](source-conflicts.md)。维护所有被入口引用的材料，清理已无用途的占位模板。
6. 执行完整性、链接与行为检查，最后更新 last_sync、last_verified、revision 和验证记录。

```bash
python3 scripts/snapshot.py verify
python3 scripts/snapshot.py check-upstream --core /path/Xray-core --docs /path/Xray-docs-next --releases-json /path/releases.json
python3 scripts/check_configs.py --binary /path/xray --version v26.3.27 --report source/validation/v26.3.27.json
python3 scripts/check_configs.py --binary /path/xray-prerelease --version v26.9.9 --report source/validation/v26.9.9.json
```

验证报告包含当前示例配置的 SHA-256；修改示例后须重跑对应版本的检查并保存报告，再运行 `verify`。

`check-upstream` 只反映提供的克隆 HEAD 与 API 文件；使用陈旧输入不构成实时核查。
`verify` 检查固定源码、证据哈希、结构、示例与维护的本地链接；未复制的翻译和 level-0
造成的上游正文链接缺口单独列在 sources.yaml，不擅自改写原文。
配置测试只验证解析/构建。真实握手、路由效果、吞吐和特定地区兼容性需另行验证。
本机 Codex 的加载与同步由使用者的技能目录管理，不在知识维护脚本中修改全局配置。
