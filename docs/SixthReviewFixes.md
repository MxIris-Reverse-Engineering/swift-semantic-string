# 第六轮修正：合并前验证轮的收口

## 动机

第五轮之后对整条分支做了一次独立验证：对上一轮评审报告的 15 项发现逐条构造触发场景复现（而非采信转述），并与 `main` 对照区分「本分支引入」与「基线固有」。结论：12 项属实、2 项定性误报（`ForEach` 行为变更实为有意且有测试钉住；「文档描述已删设计」实为带取代标注的演进日志）、1 项现象属实但关键细节失实（库自身的 `AtomicComponent` 并未遵循 `PlainAtomicSemanticComponent`，快路径不受影响）。属实项中两项（元素边界经 `Codable` 往返坍缩、`DeclarationBlock` 的 CRLF 空行）在 `main` 上同样存在，属基线固有而非本分支回归。

本轮修复其中值得修的部分；每个行为修复都先写复现测试、确认修复前失败。

## 范围

### 代码修复

1. **零宽 append 改为完全 no-op**（`SemanticString+Mutation.swift`）。此前 append 一个渲染为空的组件（`Indent(level: 0)`、`Standard("")`、`EmptyComponent`、空 `SemanticString`）会记录一个零长元素槽——代价是无条件 `makeUniqueForMutation()`（丢字符串缓存）加 `closeElement(0)`（把隐式 1:1 边界表整张物化，5 万 atom 时 40 万字节，永久保留）。实测确认后改为四个组件重载全部提前返回，与 `append("", type:)` 既有行为对齐。
2. **Frozen `==` 慢路径补 undercover 校验**（`FrozenSemanticString.swift`）。解析式比较循环用 `zip` 遍历 span，此前从不检查是否走到 `text.endIndex`，两个 undercover 的畸形值会安静判等、进入 `Set`、在之后某次无关读取时才 trap。补上与 `enumerateSpans(_:)` 尾部一致的 `precondition`——上方注释本就声称两者一致，现在为真。字节相同的畸形孪生仍走快路径安静判等，与 `hash(into:)` 注释描述的「延迟到走文本的读取再 trap」一致。
3. **`DeclarationBlock` 识别 CRLF 结尾的 body**（`Components/Block.swift`）。「body 已以换行结尾」检测用 `hasSuffix("\n")`，按 grapheme 比较时对 `"\r\n"`（单个 `Character`）返回 false，闭合大括号前多出一个空行。改为 UTF-8 尾字节判断。`main` 同样存在此问题（本行恰在本分支被改写过，顺手修复）。
4. **release 模式测试守卫**（`FifthReviewRegressionTests.swift`）。`plainAtomicPromiseIsAssertedInDebug` 断言子进程因 `assert` 失败退出，而 `assert` 在 `-O` 下编译掉、子进程退 0，导致 `swift test -c release` 全套变红。加 `#if DEBUG`。

### 测试补强

5. **两条核心存储不变量补 pin**（新增 `SixthReviewRegressionTests.swift`）。变异测试显示：破坏 `Storage.appendContents(of:)` 的边界拼接算术、或删除 `SemanticStringElements` 数组初始化器的零长过滤，370 项测试全部照过。新增 S1/S2 两组容器渲染 pin（两个拼接分支 + `BlockList`/`MemberList`/`Rows` 三个 `[Component]` 初始化器），在两个变异体下均失败、正常代码下通过。S3/S4/S5 分别钉住上述修复 1、3、2。
6. 4 处钉住旧「零长槽」行为的内部状态测试（`FlatStorageTests`、`ThirdReviewRegressionTests`、`ReviewFindingsRegressionTests`）更新为钉住新行为。

### 文档修正

- `AGENTS.md`：`FlatStorageRedesign.md` 的定位从「当前设计」改为「结构重设计（行为决策节已被第五轮取代）」；补第六轮文档指向；两条不变量措辞同步 no-op 语义。
- `FlatStorageRedesign.md`：行为决策节顶部加取代注记（第 1、2 条被第五轮推翻，第 3 条被本轮收紧）。
- `FrozenSemanticString.md`：长 token 拆分边界 scalar → grapheme cluster（第三轮已改码，历史文档回填注记）。
- `PerformanceRegressionTests.swift`：删除引用不存在测试符号的陈旧注释，`isEmpty`/`ForEach` 语义改为实话。
- `ConcurrencyTests.swift`：夹具注释去掉已不存在的「tree-state」表述。
- `README.md` 三处：旧版本载荷含零长组件的跨版本解码警告；长 token 拆分破坏 `==`/`hash` 往返的警告；`frozen()` 按 Unicode 规范等价合并 identifier 的警告。

## 关键设计与取舍

- **零宽槽的取舍**：元素槽对渲染与一切公开度量不可见（全部 7 个 `atoms(ofElementAt:)` 消费点都 `guard !isEmpty else continue`），append 路径保留它只有成本没有收益。手工数组初始化器（`init(components: [AtomicComponent])`）**保留**占位槽——那里的槽保持输入数组的位置形状，且不在热路径上。两种形状对公开度量同样不可见，分叉无害。
- **有意不修**：`PlainAtomicSemanticComponent` 违约叶子在 release 下的内容分叉（协议文档整段警告 + debug assert 兜底，零开销路径无法免费加运行时校验）；`atoms(ofElementAt:)` 双 index base（文档已警告，消费者无字面索引用法）；`map`/解码丢零长原子（第五轮既定决策，本轮只补跨版本警告）；identifier 的 NFC/NFD 合并与长 token 的 `==` 破坏（README 警告，实际影响面近零）。
- **已知未修、单开 issue**：元素边界经 `Codable` 往返坍缩为 1:1（容器行数改变而 `==`/`hash`/重编码字节全部不变）——`main` 同样存在，非本分支回归；修法涉及编码格式决策（边界入编码 vs 修改 README 承诺），独立跟踪。

## 影响面

- 公开行为变化仅一处：`DeclarationBlock` 对 CRLF 结尾 body 不再多发一个空行（此前输出属 bug）。
- 性能：零宽 append 从「丢缓存 + 物化整表」变为零成本；流式字符串的「零开销」承诺（存储文档标题句）恢复为真。
- Frozen `==` 对 undercover 畸形值从「安静判等、延迟崩溃」变为「当场 trap 且带类型名诊断」——只影响 unchecked `init(text:spans:identifierTable:)` 的违约调用方。
- 内部：append 路径不再产生零长元素槽；仅手工数组初始化器保留。直接读 `_storage.elementCount`/`elementEndOffsets` 的测试已随之更新。

## 迁移注意事项

- 无公开 API 增删。依赖「append 空组件会占一个元素槽」的调用方不存在可观察差异（槽本就不可见）；直接检查内部存储的测试代码需按新语义更新。
- `swift test -c release -Xswiftc -enable-testing` 现在应全绿；若在旧提交上运行，会因守卫前的 assert 测试失败，属预期。

## 验证

- S3/S4/S5 三项修复的复现测试在修复前确认失败、修复后通过；S1/S2 两项不变量 pin 在两个手工变异体下确认失败、正常代码下通过。
- `swift test`（debug）：376 项 / 54 套件全绿。
- `swift test -c release -Xswiftc -enable-testing`：全绿（修复 4 的直接验证）。
