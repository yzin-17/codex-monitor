# 一次性来源迁移工具

这些脚本记录 2026-09-10 的来源导入与兼容补丁，仅供在隔离临时目录复现，不是日常更新入口。import_reference.py 会替换指定目标中的 Sources、Tests、scripts、docs 等目录；不要在包含本地修改的工作树运行。

日常开发直接修改现有生产文件，并按需更新 docs/UPSTREAM_LOCK.json 的当前 sha256 和 modified 字段，原始 source_sha256 保持不变。运行 scripts/test.sh 和 scripts/build.sh 验证。

一次性自动导入工作流已在完成后移除，避免后来修改工具文件触发整仓重新导入。原始导入和构建证据可从 docs/VALIDATION.md 的工作流链接查看。
