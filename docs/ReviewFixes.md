# 双态存储评审修正：可移植性、叶子快路径与读取副作用

- **前置**：[TwoStateStorage.md](TwoStateStorage.md)（双态存储）、[FrozenSemanticString.md](FrozenSemanticString.md)（不可变终态）、[StorageCorrectnessAndLockRework.md](StorageCorrectnessAndLockRework.md)（分片锁）
- **范围**：`Sources/Semantic/` 全量重组 + 12 处修正，`Tests/SemanticTests/ReviewFindingsRegressionTests.swift` 新增 19 条回归测试

## 动机

双态存储与 `FrozenSemanticString` 落地后做了一轮独立评审，逐条用探针程序在改动前后两侧实测对照。评审提出 15 条，验证后 12 条成立需要处理，3 条属于已在 `AGENTS.md` / `README.md` 中声明的有意取舍、无需改代码。

需要处理的问题分四类：

1. **可移植性**——分片锁的引入让包无法为 watchOS 编译，也无法在 Linux 构建；
2. **叶子快路径的语义**——为省一次分配而绕过 `buildComponents()`，同时丢掉了 `identifier` 和自定义展开；
3. **读取的副作用**——`isEmpty` / `frozen()` 会把展平结果发布进可能被共享的缓存，一个以降内存为目的的调用反而先涨内存；
4. **元素视图的装箱**——`elements` 每次读取都把扁平原子重新装箱，在容器入口把双态存储的收益整个吐回去。

## 关键修正与取舍

### 一、平台锁抽象（`Storage/CacheLockStripes.swift`）

**问题。** 条带索引的混合常量 `0x9E37_79B9_7F4A_7C15` 写在 `UInt` 运算里。`UInt` 在 32 位架构上是 32 位，这是硬编译错误——而 watchOS 真机（`arm64_32` / `armv7k`）是 Apple 平台上仅存的 32 位目标。同时 `import os.lock` 没有平台保护，把一个此前零 import、纯 stdlib 的包变成了 Darwin 专属。

**为什么没被发现。** `-typecheck` 查不出常量溢出（要到代码生成阶段才报）；Apple silicon 上的 watchOS **模拟器是 arm64（64 位）**，模拟器构建同样编译通过；仓库没有 CI。

**取舍。** 混合运算统一提升到 `UInt64`，而不是把常量截断成 32 位。截断看起来更省事，但 `mixed >> 32` 会恒为 0，256 条条带全塌成一条，退化成设计文档里实测 434.9 ms 的那把全局单锁——比不加锁的单线程还慢。实测对比：4096 个连续 32 位地址，`UInt64` 混合用满 256 条带（单条带最多 18 个），截断版本 4096 个地址全落在同一条。

平台原语收敛到一个文件：Darwin 用 `os_unfair_lock`（`Synchronization.Mutex` 需要 macOS 15，`NSLock` 会拖进 Foundation），Windows 用 `SRWLOCK`，其余用 `pthread_mutex_t`。抽象层只暴露 `stripe(forAddress:)` / `lock` / `unlock`，其余代码不再见到任何平台符号。

### 二、叶子快路径改为显式承诺（`PlainAtomicSemanticComponent`）

**问题。** 快路径写成 `appendAtomicComponent(AtomicComponent(component))`，用转换构造器而非 `component.buildComponents()`。这一个选择造成两个症状：自定义 `buildComponents()` 被无声忽略（同一个值经 `append` 渲染 `Foo`、经 builder 渲染 `<Foo>`）；`AtomicComponent.identifier` 被清空（转换构造器把它硬编码为 `nil`），恰好抹掉上一个 commit 刚加的能力。

**取舍。** 直接改调 `buildComponents()` 是正确的，但每次追加多一个小数组分配——正是快路径要省掉的东西。改为引入标记协议 `PlainAtomicSemanticComponent`：遵循它等于**承诺 `buildComponents()` 就是继承来的默认实现**，快路径才被允许直接读 `string` / `type`。

- 库内 18 个叶子类型全部遵循（集中在 `Components/PlainAtomicComponentConformances.swift`），流式路径的零分配特性不变；
- `AtomicComponent` **不**遵循——它覆写了 `buildComponents()` 以携带 `identifier`，走精确重载；
- 覆写了 `buildComponents()` 的第三方叶子只遵循 `AtomicSemanticComponent`，走 `buildComponents()` 的正确路径，代价是一次小数组分配。

默认是安全的：不主动承诺就不会被抄近路。

### 三、读取不再发布缓存

`components` / `string` 会把结果填进 `Storage` 的缓存，而 `Storage` 可能被多个值共享——一个从没要求过展平的值会因此长期持有整份 `[AtomicComponent]`。三处修正：

- **`frozen()`**：改走 `componentsWithoutPublishing()` 与 `cachedStringIfPresent()`，缓存已热就复用、没热就本地算。`compact()` 早先已修过同样的毛病，这次补上公开 API。
- **`isEmpty`**：树态改为 `elements.flattensToNothing()`，遇到第一个有输出的元素即停，不物化、不发布。`ForEach(_:separator:)` 每个条目调一次，所以是逐项付费。实测 40 万元素单次调用 390 ms → 0.008 ms，且共享副本读取后原值不再多留 15.3 MB。
- **写时复制拆成两条**：`makeUnique()` 保留缓存（仅 `compact()` 用，它要读缓存），`makeUniqueForMutation()` 丢弃缓存。所有变更操作下一句就 `invalidateCache()`，为它们持锁复制两个缓存字段是纯浪费。

### 四、元素视图不再装箱（`SemanticStringElements`）

`elements` 原先返回 `[any SemanticStringComponent]`，对扁平字符串意味着每个原子一个 40 字节 existential 容器 + 64 字节堆盒。命中点是容器的预构建 `content:` 初始化器——正是打印器交付流式字符串的地方。

改为返回视图类型，内部保持 `.flat([AtomicComponent])` 或 `.tree([any SemanticStringComponent])`；容器遍历 `indices` 并调用 `appendComponents(ofElementAt:into:)`，扁平态直接读类型化数组。实测 40 万原子经 `MemberList(level:content:)`：24.8 ms / +79.7 MB → 0.004 ms / +0 MB，渲染行数不变。

`boxed()` 保留给确实需要数组的调用方，但不应出现在展平路径上。

### 五、`appending` 族不再强制整份复制

`appending` 原先写成 `var copy = self; copy.append(...)`，引用计数必然 ≥ 2，于是每次调用都强制走一遍 `Storage(copying:)`（加锁 + 复制两个数组和两个缓存字段），而下一句 `invalidateCache()` 立刻把缓存扔掉。

改为 `appendingAtomicComponent(_:)` 直接构造结果存储：先拷数组、再建 Storage，与改造前的分配次数一致。五轮最小值实测：`parenthesized()` 222.3 → 162.2 ms，`+` 101.2 → 74.7 ms，`appending` 101.0 → 74.4 ms（基线分别为 138.7 / 59.6 / 59.6 ms）。回归从 1.6–1.7 倍收敛到 1.17–1.25 倍，剩余部分是扁平存储本身的常数差。

### 六、`FrozenSemanticString` 的校验与值语义

- **解码拒绝 0 长度 span**。`frozen()` 造不出这种值；接受它会得到 `count == 1` 却渲染为空、且转回 `SemanticString` 再冻结不等于原值（非幂等）的东西。
- **类型码改为逐条书写**。原先 `.type` 用 `8 + typeKindOffset * 2` 计算，块的增长边正好顶着 `.member` 硬编码的 18——`TypeKind` 一旦新增第六个 case，编码侧的 switch 会强制你补 `offset = 5`，算出 18，与 `.member(.declaration)` 撞车，而解码侧的 `case 8 ... 17` 不会跟着更新，编译器只检查编码侧。现在每个 case 写死码值，并新增 `nextFreeFrozenTypeCode` 标明下一个可用码；测试遍历全部 case 断言唯一性与往返。
- **`==` / `hash` 按内容比较**。原先合成实现逐字比较 `identifierTable`，而解码器原样保留收到的表（可能含重复项或未被引用项），于是内容完全等价的两个值判不等。改为解析每个 span 的 identifier 再比较；表完全相同时走快路径。
- **`identifier(at:)` 越界返回 nil** 而非陷入。不改变合法输入的行为，但让越过不校验构造器的数据降级为"没有 identifier"，而不是让进程崩掉。

### 七、文件拆分

`SemanticString.swift` 原为 997 行。按功能点拆成 `SemanticString.swift`（存储管道、内容、初始化器）+ `+Mutation` / `+Transformation` / `+Query` / `+Composition` / `+Conformances`；存储内部移入 `Storage/`，冻结形态移入 `Frozen/`。新增 API 放进对应领域的扩展文件，不再让核心文件继续膨胀。

## 影响面

**源码兼容。** 公开 API 没有移除或改签名。新增 `PlainAtomicSemanticComponent`、`SemanticStringElements`、`FrozenSemanticString.identifier(at:)`、`SemanticType.nextFreeFrozenTypeCode`。

**行为变更，调用方需要知道：**

| 位置 | 变化 |
|---|---|
| `SemanticString.elements` | 返回类型由 `[any SemanticStringComponent]` 改为 `SemanticStringElements`。它是 `@usableFromInline internal` 之上的公开视图，此前实际不构成对外 API，但自定义容器如果读过它需要改用 `indices` + `appendComponents(ofElementAt:into:)`，或 `boxed()`。 |
| 自定义叶子组件 | 覆写 `buildComponents()` 的叶子现在会被正确展开（此前经 `append` 会被忽略）。若你的类型依赖过旧行为，需要重新确认输出。 |
| `AtomicComponent.identifier` | 经 existential 或泛型 `append` 追加时不再丢失。 |
| `FrozenSemanticString` 解码 | 0 长度 span 由接受改为抛 `DecodingError`。此前能解码的这类载荷会开始报错——它们本来就产生不了自洽的值。 |
| `FrozenSemanticString` 相等性 | `identifierTable` 形状不同、内容等价的两个值由判不等改为判等，哈希随之改变。不要把旧版本持久化的哈希值跨版本复用。 |

**未改动的行为**（评审提出但确认为已声明的有意设计）：`isEmpty` 的"展平为空"语义及其对 `ForEach(_:separator:)` 输出的影响、`init(components:)` 丢弃零长度组件、`init(text:spans:identifierTable:)` 不做校验。前两条本次在 `README.md` 中补写了面向调用方的说明。

## 迁移注意

- **新增叶子组件**：默认只遵循 `AtomicSemanticComponent`。只有在确认没有覆写 `buildComponents()` 时，才追加 `PlainAtomicSemanticComponent` 以获得零分配路径，并登记到 `Components/PlainAtomicComponentConformances.swift`。
- **新增 `SemanticType` 或 `TypeKind` case**：取 `SemanticType.nextFreeFrozenTypeCode` 并同步更新该常量，不要扩展现有块。
- **改动任何与指针宽度有关的算术**：本地跑一次 watchOS 真机架构交叉编译，命令见 `AGENTS.md` 的构建章节。模拟器构建不会暴露问题。
- **为存储行为写测试**：先确认它在没有该改动时会失败。`TwoStateStorageTests` 里两条容器粒度测试就因为走 builder 闭包而对双态存储零覆盖。
