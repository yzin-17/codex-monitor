# 一次性来源迁移工具

这些脚本记录 2026-09-10 的来源导入与兼容补丁，仅供历史追溯，不是日常更新入口。import_reference.py 会替换指定目标中的 Sources、Tests、scripts、docs 等目录；不要在现有工作树运行。

0.3.0 起不再维护或检查源码哈希，docs/UPSTREAM_LOCK.json 仅保留来源版本与路径记录。旧迁移脚本依赖迁移当时的清单结构，不适用于现在的工作树。日常开发直接修改现有生产文件，执行 scripts/test.sh 和 scripts/build.sh。

一次性自动导入工作流已移除，避免修改工具文件触发整仓重新导入。原始导入和构建记录仍可从 docs/VALIDATION.md 的工作流链接查看。
