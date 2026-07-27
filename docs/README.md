# 文档索引

本目录收录 swift-semantic-string 的设计记录与演进说明。面向使用者的 API 说明在仓库根目录的 [README.md](../README.md)，面向 coding agent 的工作指南在 [AGENTS.md](../AGENTS.md)（`CLAUDE.md` 是它的符号链接）。

## 设计记录

按落地顺序排列：

- [superpowers/specs/2026-04-18-semantic-string-performance-design.md](superpowers/specs/2026-04-18-semantic-string-performance-design.md) —— 热路径的分配与拷贝优化（预留容量、`Joined` 重排、`Indent` 缓存），并新增 correctness 与 stress 两组测试。无 API 变更、无行为变更。
- [TwoStateStorage.md](TwoStateStorage.md) —— `SemanticString.Storage` 改为 flat / tree 双态：流式内容走零装箱的 `[AtomicComponent]`，构建期形态保留 element 边界。含新增的 `compact()` / `compacted()` 及其调用约束、缓存填充的加锁方案。实测驻留内存 1.27 GB → 382 MB。
- [FrozenSemanticString.md](FrozenSemanticString.md) —— 在双态存储之上引入不可变终态类型 `FrozenSemanticString`：text arena + 每 token 8 字节 span + identifier 内插表 + 列式 Codable，把「构建完再也不改」从运行时约定提升为类型约束。实测再降至约 285 MB（相对基线 -78%）。

## 约定

- 每篇设计记录写清五件事：动机、范围、关键设计与取舍、影响面、迁移注意事项。
- 新增或重命名文档时同步更新本索引。
- 对外文档（根 README 等）用英文；本目录的设计记录用中文。
