# append 路径与字符串拼接的性能优化

- **状态**: Implemented
- **创建日期**: 2026-09-03
- **最后更新**: 2026-09-03
- **档位**: 轻量档（无公开行为变更；唯一的 API 面变化是给 `SemanticStringComponent` 增加一个**带默认实现**的下划线要求，源码兼容）

## 摘要

存储层（扁平原子数组 + 边界表 + 条带锁）经过八轮评审已无低垂果实，剩余的时间开销集中在两处：`string` 的拼接实现（逐 token `+=`），以及 builder 与存在量（`any SemanticStringComponent`）append 的装配路径（两次 `as?` 探测、每个叶子一个单元素临时数组、result builder 每条语句整体拷一次累积数组、复合组件展平后再逐原子拷进存储）。本提案落地四项互相独立的优化，全部不改变任何可观测行为，并把已裁决清单 S3（builder 装配路径慢于 `main` 1.24–1.7×）的差距压回去，而不必把「保留组件结构」请回来。

## 范围

| 文件 | 改动 |
|---|---|
| `Sources/Semantic/SemanticString.swift` | `concatenated(_:)`：先算总字节数，把每个原子的 UTF-8 直接拷进一个 `[UInt8]`，再 `String(decoding:as:)`；`SemanticString` 特化 `_appendAsElement(into:)` |
| `Sources/Semantic/SemanticStringComponent.swift` | 协议新增 `_appendAsElement(into:)` 要求与默认实现；`PlainAtomicSemanticComponent` 与 `Optional` 各自特化 |
| `Sources/Semantic/Components/AnyComponent.swift` | `AtomicComponent` 特化 `_appendAsElement(into:)` |
| `Sources/Semantic/SemanticString+Mutation.swift` | `append(some SemanticStringComponent)` 改为一次协议分派；`appendComponentElement(flattening:)` 在目标为空且展平结果无空原子时直接接管数组，非空目标时批量 `append(contentsOf:)` |
| `Sources/Semantic/SemanticStringBuilder.swift` | `buildPartialBlock(accumulated:next:)` 系列的 `accumulated` 参数改为 `consuming` |
| `Tests/SemanticTests/AppendPathPerformanceTests.swift` | **新增**：四项优化各自的行为钉子 |
| `AGENTS.md`、`docs/SettledFindings.md`、`docs/README.md` | 同步 append 重载的描述、S3 / S4 的现状说明、文档索引 |

不在范围内：让复合组件直接写入目标数组的 `buildComponents(into:)`（每层嵌套再省一次临时数组，改动面大，待本批落地后另行评估）；三项内存方向的改动（边界表 `implicitPrefixCount`、Frozen `Span` 稀疏 identifier 列、`AtomicComponent` 瘦身）。

## 关键设计与取舍

### 1. `concatenated(_:)` 直接写 UTF-8 缓冲

`+=` 每次都要走 `String.append` 的通用路径（容量检查、ASCII 标志维护、可能的桥接判断）。改为两遍：第一遍累加 `utf8.count`，第二遍用 `withUTF8` 把每个 token 的字节 memcpy 进一个按总长预留的 `[UInt8]`，最后 `String(decoding:as:)` 一次性构造。输入全部来自合法的 Swift `String`，解码校验必然通过；结果是 native UTF-8 字符串，字节与原实现逐一相同。

**为什么不用 `String(unsafeUninitializedCapacity:)`**：它能省掉「字节数组 → String」这一次拷贝（原型实测 7.6 ms 对 8.4 ms），但要求 macOS 11 / iOS 14 / watchOS 7，而本包的部署目标是 macOS 10.15 / iOS 13 / watchOS 6，只能用 `#available` 做双路径。10% 的差距不值得两套实现两套测试。

**为什么用 `append(contentsOf:)` 而不是预分配后按偏移 `initialize`**：两遍之间 token 的字节数按理不变，但若某个桥接字符串在两次读取之间转码结果不一致（例如含未配对代理项的 `NSString`），按偏移写入会越界写内存。`[UInt8].append(contentsOf:)` 走的同样是 memcpy，容量预留准确时不会重分配，但每个 token 多一次容量检查与计数更新，实测 10.0 ms 对按偏移写入的 7.9 ms——为「无论 token 是什么表示都不可能越界写」付 25%，仍比 `+=` 快 2.8×。

### 2. 存在量 append 改为一次协议分派（双分派）

`append(_ component: some SemanticStringComponent)` 原来依次做 `as? AtomicComponent`、`as? SemanticString` 两次动态转换，落空后调 `buildComponents()`——对一个 `Keyword` 来说就是两次失败的转换加一个单元素数组分配。现在协议上增加要求：

```swift
func _appendAsElement(into semanticString: inout SemanticString)
```

默认实现即原来的兜底（`appendComponentElement(flattening: buildComponents())`）；`PlainAtomicSemanticComponent` 的扩展特化为静态快路径 `semanticString.append(self)`；`AtomicComponent` 特化为保留 `identifier` 的 `appendAtomElement`；`SemanticString` 特化为整体作为**一个**元素的 `appendSemanticStringElement`；`Optional` 转发给被包裹值。`append(some SemanticStringComponent)` 的函数体只剩一行 `component._appendAsElement(into: &self)`：静态类型已知时被特化成直接调用，存在量时是一次协议见证表间接调用。

**粒度不变量不变**：每个特化记录的元素数与原来对应分支完全一致，`SemanticString` 经存在量仍是一个元素（`AGENTS.md` 不变量 1）。

**S4 的分叉形态随之改变**：违反 `PlainAtomicSemanticComponent` 承诺（conform 了却又 override `buildComponents()`）的叶子，原来「经 `append` 走快路径、经 builder 走 `buildComponents()`」两边内容不同；现在 builder 也经 `append(some SemanticStringComponent)` → 快路径，两边内容**一致**了，override 只在被复合组件直接调用 `buildComponents()` 时才被采纳：`MemberList` / `BlockList` / `Rows` 的 `[Component]` 数组初始化器、`Joined` 的 separator / prefix / suffix、`NestedDeclaration(_:)`、`TupleComponent`、`Array` / `Optional` 展平。release 实测：`append` 与 builder 都渲染 `"x"`，`MemberList(level:, [leaf])` 渲染 `"<x>"`。分叉没有消失，只是挪了位置；debug 断言在两条 append 路径上都会触发。`SettledFindings.md` S4 同步更新。

**为什么是下划线 public 要求而不是内部要求**：协议要求必须是 public 才能被外部类型的默认实现满足；下划线是 Swift 生态里「public 只因技术需要、调用方不要碰」的惯例，文档明确写「不要实现、不要调用」。

### 3. result builder 的累积参数改为 `consuming`

`buildPartialBlock(accumulated:next:)` 的参数默认是 borrowing，函数体里 `var result = accumulated` 之后 `append` 看到引用计数为 2，必然整体拷贝一次累积数组——一个 8 条语句的 builder 块要拷 7 次。改为 `consuming` 后，调用点的 `accumulated` 是上一步的临时值、之后不再使用，所有权直接转移，append 在原地完成。这些方法不是 `@inlinable`，跨模块时优化器无法自行消除该拷贝，所以下游 app 的收益只会比同模块探针更大。

### 4. 复合组件 append 进空字符串时直接接管数组

`appendComponentElement(flattening:)` 原来先探测是否存在非空原子，然后逐原子过滤拷贝。改为先做一次「是否含空原子」的全扫描：含则保留原来的过滤循环；不含且目标存储为空（`atoms.isEmpty`）则 `_storage.atoms = builtComponents`，O(1) 接管；不含但目标非空则批量 `append(contentsOf:)`。接管后的数组可能与复合组件仍持有的 `content`（`ForEach` / `IfLet`）共享缓冲区，后续对该字符串的任何 append 都由数组自身的写时复制隔离——那次拷贝恰是原来无条件付出的那次。`SemanticString(composite)`、`asSemanticString()`、`[SemanticString].joined(separator:)` 全部受益。

「目标为空」只看 `atoms`，不看边界表：`init(components: [AtomicComponent])` 收到全空输入时会留下零长元素槽（`atoms == []`、`elementEndOffsets == [0]`），接管后 `closeElement(appendedAtomCount:)` 在非 nil 的表上追加末尾偏移，与过滤循环路径的结果逐字节相同。

## 影响面

- **无公开行为变更**：`string`、`components`、元素边界、`==`/`hash`/`Codable`、identifier scope 语义、零宽 append 的 no-op 语义全部不变。
- **API 面**：`SemanticStringComponent` 多一个带默认实现的下划线要求；已有外部遵循者无需改动即可编译。
- **S4 分叉形态改变**（见上）；S3 的记账数字更新。
- **性能**：见「验证」。

## 迁移注意事项

- 外部类型**不要**实现 `_appendAsElement(into:)`；需要自定义展平的继续 override `buildComponents()`，默认实现会走它。
- 违反 `PlainAtomicSemanticComponent` 承诺的叶子：以前 builder 路径会「碰巧」采纳 override，现在不会。这是承诺本来的含义，不是新增约束；协议文档已经整段警告。

## 验证

同模块 `-O` 编译的探针（`swiftc -O -wmo -swift-version 6 -module-name Semantic Sources/Semantic/**/*.swift probe.swift`），取多次运行最优值，`main` 与 `next` 当前同 tip（`1021589`）。原型数字在实现前测得，落地后重测填入「落地」列。

| 场景 | 改动前 | 原型 | 落地 |
|---|---|---|---|
| `concatenated()`，100 万原子 | 28.2 ms | 8.4 ms（按偏移写入） | **10.0 ms**（有界 `append(contentsOf:)`，见决策日志） |
| `frozen()` 冷路径（缓存未填，含一次拼接），100 万原子 | 36.2 ms | — | **18.6 ms** |
| 存在量 append，8 叶子 × 10 万 | 121.9 ms | 71.2 ms | **69.8 ms** |
| 静态 `append(Keyword)`，同上（下界） | 46.1 ms | 46.3 ms | 44.4 ms |
| `SemanticString { 8 叶子 }` × 10 万（真实 builder 闭包） | 205.7 ms | 153.4 ms | **148.7 ms** |
| builder 显式链 × 10 万（仅 `consuming`） | 199.2 ms | 140.6 ms | — |
| builder 显式链 × 10 万（`consuming` + 双分派） | 199.2 ms | 95.5 ms | **92.5 ms** |
| `SemanticString { for row in rows { row } }`，2000 行 | 0.60 ms | 0.49 ms | **0.46 ms** |
| `MemberList { for row in rows { row } }.asSemanticString()`，2000 行 | 0.95 ms | 0.85 ms | **0.63 ms** |
| `MemberList(level: 1, rows).asSemanticString()`，2000 行 | 0.37 ms | — | **0.19 ms** |
| `SemanticString(Group(rows))`，1 万原子（空目标接管） | 0.31 ms | 0.19 ms | **0.18 ms** |
| 同上追加到非空目标（批量 append） | 0.30 ms | 0.30 ms | 0.28 ms |
| `enumerateSpans`、`==`、`hash`（未改动，对照） | 28.3 / 6.7 / 23.7 ms | — | 28.3 / 6.5 / 23.7 ms |

「改动前」与「落地」两列来自同一会话、同一探针源码分别对 `HEAD`（`1021589`）与工作树编译的两个二进制，交替运行三次取最优；「原型」列是实现前在源码副本上的探测值。`enumerateSpans` 一次出现 35.9 ms 的离群值，三次复跑两侧均为 28 ms，且用 `+=` 与 `String(decoding:)` 分别拼出的同一文本上直接对比无差异，判为噪声。

测试：全套 `swift test` 401 项通过（改动前 387 项 + 本批 14 项）、`swift test -c release` 399 项通过（两项 `#if DEBUG` 断言测试按设计不参与）、`swift test --sanitize=thread --filter ConcurrencyTests` 19 项通过且无告警（append 漏斗被改动，锁与缓存未动但仍跑一遍）、watchOS `arm64_32` 编译通过。

本批新增测试里有一项直接证明分派落点：违反 `PlainAtomicSemanticComponent` 承诺的叶子以存在量形式 `append` 时，debug 下必须触发快路径的断言（子进程 exit 非 0）。若协议见证被解析到通用默认实现，子进程会安静退出 0，该测试即失败。

## 决策日志

| 日期 | 决定 | 理由 |
|---|---|---|
| 2026-09-03 | 用户在对话中批准「先做性能」，本提案直接以 In Progress 创建 | 四项均为无行为变更的性能优化，属轻量档；内存方向三项另行提案 |
| 2026-09-03 | 拼接不用 `String(unsafeUninitializedCapacity:)` | 需要 macOS 11 / iOS 14，与部署目标冲突；10% 差距不值得双路径 |
| 2026-09-03 | 拼接用 `[UInt8].append(contentsOf:)` 而非按偏移 `initialize` | 后者依赖两遍读取字节数一致，桥接字符串下无法证明，不一致即越界写；前者有界，代价是 10.0 ms 对 7.9 ms（25%） |
| 2026-09-03 | 双分派要求取名 `_appendAsElement(into:)`，public 加下划线 | 外部类型必须能拿到默认实现，故须 public；下划线表明不是调用面 |
| 2026-09-03 | 接受 S4 分叉形态改变 | builder 与 `append` 两条路径内容一致是承诺的本意；override 只剩复合组件直接调用 `buildComponents()` 一处采纳，文档同步 |
| 2026-09-03 | `buildComponents(into:)` 汇入式展平不入本批 | 改动面覆盖全部复合组件；先看前四项落地后 S3 的剩余差距再定 |
| 2026-09-03 | 实现完成，状态置为 Implemented，与代码同批次提交 | 四项全部落地并复测；无配套指南或实现说明（本文已含全部不可见于代码的决策），无新增术语 |
