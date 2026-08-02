# 文档索引

本目录收录 swift-semantic-string 的设计记录与演进说明。面向使用者的 API 说明在仓库根目录的 [README.md](../README.md)，面向 coding agent 的工作指南在 [AGENTS.md](../AGENTS.md)（`CLAUDE.md` 是它的符号链接）。

## 设计记录

按落地顺序排列：

- [superpowers/specs/2026-04-18-semantic-string-performance-design.md](superpowers/specs/2026-04-18-semantic-string-performance-design.md) —— 热路径的分配与拷贝优化（预留容量、`Joined` 重排、`Indent` 缓存），并新增 correctness 与 stress 两组测试。无 API 变更、无行为变更。
- [TwoStateStorage.md](TwoStateStorage.md) —— `SemanticString.Storage` 改为 flat / tree 双态：流式内容走零装箱的 `[AtomicComponent]`，构建期形态保留 element 边界。含新增的 `compact()` / `compacted()` 及其调用约束、缓存填充的加锁方案。实测驻留内存 1.27 GB → 382 MB。
- [FrozenSemanticString.md](FrozenSemanticString.md) —— 在双态存储之上引入不可变终态类型 `FrozenSemanticString`：text arena + 每 token 8 字节 span + identifier 内插表 + 列式 Codable，把「构建完再也不改」从运行时约定提升为类型约束。实测再降至约 285 MB（相对基线 -78%）。
- [StorageCorrectnessAndLockRework.md](StorageCorrectnessAndLockRework.md) —— 双态存储的审查修正：flat 态补上零长度组件过滤（此前与 tree 态行为分叉）、`isEmpty` 语义统一、`compact()` 降为内部 API、叶子组件走静态派发的 flat 快路径，以及把共享的单把 `NSLock` 换成按缓存行间隔的分片 `os_unfair_lock`（并发冷填充 434.9 ms → 44.7 ms，TSan 竞争清零，并去掉 Foundation 依赖）。
- [ReviewFixes.md](ReviewFixes.md) —— 独立评审后的 12 处修正：恢复 watchOS（32 位）与 Linux/Windows 可编译性、叶子快路径改为 `PlainAtomicSemanticComponent` 显式承诺（此前会丢 `identifier` 并忽略自定义 `buildComponents()`）、`isEmpty` / `frozen()` 不再把展平结果发布进共享缓存、元素视图不再装箱扁平原子、`appending` 族不再强制整份复制，以及 `FrozenSemanticString` 的解码校验与值语义。同时把 `SemanticString.swift`（997 行）按功能点拆成扩展文件。
- [FlatStorageRedesign.md](FlatStorageRedesign.md) —— 第二轮评审（15 处确认属实，其中 10 处同源于双态设计的组合面）之后的结构性重设计：存储收敛为「单一扁平原子数组 + 显式元素边界表」，composite 在 append 时立即展平，组件缓存与 `compact()` / `convertToTree()` 整体删除。输出与 `main` 恢复逐字节一致（唯一有意偏离：零长原子在一切构造路径被丢弃），容器展平快于 `main`，「空组件毁掉 flat 表示」的 +63% 内存惩罚降为 +3.8%。**本篇取代 TwoStateStorage.md 与 StorageCorrectnessAndLockRework.md 所述的双态机制**，后两篇保留为历史记录。`FrozenSemanticString` 同批独立修复：`==` 快路径破坏传递性、32 位 `Int(UInt32)` 陷入、解码校验的文档表述。
- [ThirdReviewFixes.md](ThirdReviewFixes.md) —— 第三轮评审（15 处全部核验属实）后的收尾修正：手工数组构造补零长元素槽（相等值不再对 `isEmpty` 给出相反答案）、容器判空统一看过滤后的展平（钉为第二条有意偏离）、Frozen `==`/`hash` 统一为 canonical 比较（NFC/NFD 冻结保相等）、`enumerateSpans` 三向违约全部 trap、超长 token 按字形簇切分、解码器「先校验长度列再物化其余列」、锁条带尺寸断言，以及 builder 收集路径慢于 `main` 约 1.4–1.7× 的如实记账（有意不修的取舍）。
- [FourthReviewFixes.md](FourthReviewFixes.md) —— 第四轮评审后的两处 `FrozenSemanticString` 一致性修正：解码器不再拒收越界 `identifierIndex`（原样保留、读取归 nil，与 unchecked init 承诺及「解码保留未知 typeCode」对称，Codable 往返恢复逐字节幂等）；`==`/`hash` 比较**归一后**的 `SemanticType` 而非原始 `typeCode` 字节（两个都渲染为 `.other` 的快照恢复判等）。同源于「读者当降级、另一路径当原始字节」的字段处理不一致。
- [FifthReviewFixes.md](FifthReviewFixes.md) —— 第五轮评审（15 处，独立复现全部属实）后的收口：`isEmpty` 改为组件计数使全部空判度量重合（相等值不再对 `isEmpty` 给出相反答案，`ForEach` 随之与其它分隔容器一致跳过空项）；`appending("")` 恢复保留 identifier scope 的 early return；Frozen `==` 快路径加字节相等门槛（canonical 重排不再误判相等）、`hash` 不再走文本（50 万 span 值 hash -62%、Set 插入 -65%，畸形值哈希不再崩溃）、`==` 慢路径与 `enumerateSpans` 共用带名诊断；flaky 的逐字节 Codable 断言补 `.sortedKeys`；`typeCodeBijection` 增加编译期穷尽性哨兵；「分配数守卫」「span 不切分 Character」「identifier index 越界校验」「解码器资源上界」四处失实文档全部改为实话。
- [SixthReviewFixes.md](SixthReviewFixes.md) —— 合并前验证轮：对第五轮后分支的 15 项评审发现逐条独立复现（12 属实、2 定性误报、1 细节失实），并与 `main` 对照定位回归来源。修复：零宽 append 改为完全 no-op（不再丢缓存、不再物化边界表）、Frozen `==` 慢路径补 undercover trap、`DeclarationBlock` 识别 CRLF 结尾的 body、release 模式测试守卫；变异测试驱动补上两条核心存储不变量（边界拼接、零长过滤）的容器渲染 pin。元素边界经 `Codable` 往返坍缩确认为 `main` 固有问题，单开 issue 跟踪。
- [SeventhReviewFixes.md](SeventhReviewFixes.md) —— 第七轮：对 15 项发现逐条走完「四问」核验（能否复现 / `main` 是否也有 / 值不值得修 / 以前是否修过），全部属实——7 项待修、5 项前几轮已裁决、1 项 `main` 固有、1 项可选加固。本批只落地文档诚实化：`PlainAtomicSemanticComponent` 协议文档改为实话（`assert` 在 `-O` 下被编译掉，违约实现在 release 静默发布内容分叉）、AGENTS.md 三处（零长槽说法与第六轮自相矛盾、边界表物化的永久代价、被实测证伪的「粒度不可能在路径间分叉」）、README 补「组件在 append 时展平」的迁移说明。代码修复分批进行，未完成项在文末列明。

## 已裁决清单

- [SettledFindings.md](SettledFindings.md) —— 被判定为**有意偏离 / 有意不修 / 误报**的发现及其理由。**每次 code-review 先对照此清单**：命中且理由仍成立的直接跳过，不再重走四问；若新证据推翻理由，则更新该条并重新裁决。第七轮 15 项中有 5 项属重复报告，正是此前缺少这份清单所致。

## 约定

- 每篇设计记录写清五件事：动机、范围、关键设计与取舍、影响面、迁移注意事项。
- 新增或重命名文档时同步更新本索引。
- 对外文档（根 README 等）用英文；本目录的设计记录用中文。
