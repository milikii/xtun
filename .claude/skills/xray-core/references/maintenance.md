# 维护与校验

依赖：Python 3.10+、Git、PyYAML（[requirements.txt](../scripts/requirements.txt)）。
隔离握手另需 OpenSSL 和用户明确允许执行的对应版本二进制。脚本不安装服务或修改全局技能设置。
以下命令在技能目录执行。

## 发现不等于支持

```bash
python3 scripts/upstream.py check --cache /private/path/upstream-cache.json --output /private/path/new-observation.json
python3 scripts/upstream.py check --offline --cache /private/path/upstream-cache.json
```

联网观察分别报告稳定版、预发布、最新发布、main 与 docs 提交。离线保留原采集时间，
新鲜度未知。新版本出现不自动扩展生成规则。main、已发布行为与维护者建议分开记录。
`snapshot.py check-upstream` 是旧的本地输入比较器，不代表实时查询，稳定版按提供列表的发布时间选择；
需要官方 `/releases/latest` 选择时使用 `upstream.py`。

## 固定原文与审查规则

1. 刷新官方克隆，检查目标 tag 的完整 SHA。修改 [sources.yaml](../sources.yaml) 的提取范围。
   REALITY SHA 来自对应 Core 的 go.mod，而不是依赖仓库 HEAD。
2. 新版本使用独立来源键/路径，保留历史快照。先 dry-run，再显式写入：

```bash
python3 scripts/snapshot.py sync --core /path/Xray-core --docs /path/Xray-docs-next --reality /path/REALITY
python3 scripts/snapshot.py sync --core /path/Xray-core --docs /path/Xray-docs-next --reality /path/REALITY --write
python3 scripts/history.py --core /path/Xray-core --releases-json /path/releases.json --write
```

3. 核对构建与运行代码，再更新参数、默认值、组合、废弃项和 generation.yaml。
   字段存在不证明运行可用。未知组合拒绝生成，不等于内核不支持。
4. 官网与源码冲突记入 [source-conflicts.md](source-conflicts.md)，不改写官方正文。
   引用发言保存原文、作者、日期与上下文。文档快照的提交和最新 docs 观察分开。
5. 更新 SKILL 元数据；源码同步日期不是行为验证日期。未执行的验证不得更新为通过。

## 分层验证

```bash
python3 scripts/snapshot.py verify
python3 -m unittest discover -s tests
python3 tests/check_distribution.py
python3 scripts/check_configs.py --bundle /private/path/bundle \
  --server-binary /path/server-xray --client-binary /path/client-xray \
  --report /private/path/new-build-report.json --require-build
python3 scripts/check_handshake.py --help
```

真实二进制的下载及执行必须先获授权；不能用 mock 或 `run -test` 代替握手。
`tests/native_matrix.py --help` 提供固定版本构建矩阵，`--handshake` 显式启用本地链路。
未覆盖的拓扑会跳过，矩阵不会把跳过算作通过。没有真实内核运行记录时只能称工具已实现。
外部 CDN、证书部署、第三方 GUI、地区可达性、UDP 应用流量及性能另行验证。

历史两份示例的旧回归入口为 `scripts/check_examples.py`，不要把历史报告转写成新生成器验证。
更改示例须重跑对应版本并更新报告哈希。通用生成器契约见 [generation.md](generation.md)。

`verify` 检查固定原文、证据哈希、版本和依赖锁定、规则来源、历史报告及维护链接。
`check_distribution.py` 复制技能到独立路径运行离线生成，并以临时 Git index/tree 检查当前
工作树归档内容；不创建提交，不改变真实暂存区。配置、链接、缓存与私人设置不应进入版本控制。
