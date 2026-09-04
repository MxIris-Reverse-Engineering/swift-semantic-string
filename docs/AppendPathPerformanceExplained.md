# append 路径与字符串拼接优化详解

> 配套提案见 [AppendPathPerformance.md](AppendPathPerformance.md)（决策记录与完整数字）。
> 本文讲**改了什么、为什么这么改是成立的、细节在哪**，面向任何 Swift 开发者，不要求了解本库内部。读完应该能自己判断类似场景该不该这么改。2026-09-03 落地（`99c2e99`）。

## 0. 三分钟背景：这个库里的字符串长什么样

`SemanticString` 是「带语义标签的文本」：一段代码声明被切成一串 token，每个 token 记着文字和它的语义角色（关键字、类型名、变量名……），渲染时按角色上色。

```swift
public struct AtomicComponent {
    public let string: String        // 文字
    public let type: SemanticType    // 语义角色
    public let identifier: String?   // 可选的跨 token 关联标识
}
```

一个 `SemanticString` 内部就是一个 `[AtomicComponent]` 数组（下文叫「原子数组」），外加一张记录「哪几个原子属于同一行 / 同一项」的边界表，以及一个惰性缓存的完整字符串 `string`。

构造它有两种写法：

```swift
// 流式：一个一个追加
var declaration = SemanticString()
declaration.append(Keyword("public"))
declaration.append(Space())

// 声明式：SwiftUI 风格的 result builder
let declaration = SemanticString {
    Keyword("public")
    Space()
    TypeName(kind: .struct, "Foo")
}
```

`Keyword`、`Space` 这些叫**叶子组件**，只产出一个原子；`MemberList`、`Joined`、`ForEach` 这些叫**复合组件**，`buildComponents()` 会展开成一串原子。所有组件都遵循 `SemanticStringComponent` 协议，协议原本只有一个要求：`func buildComponents() -> [AtomicComponent]`。

术语速查（后文直接用）：

- **存在量**：`any SemanticStringComponent` 这种类型。它是一个盒子，编译期只知道盒子里的东西遵循协议，不知道具体类型。
- **静态分派 / 动态分派**：编译期知道具体类型时，调用直接落到目标函数（静态）；只知道协议时，运行时查表决定（动态）。
- **写时复制（copy-on-write）**：Swift 的 `Array`、`String` 赋值时只共享底层缓冲区，谁先修改谁才真的拷一份。
- **borrowing / consuming**：Swift 5.9 起可以给参数标注所有权。borrowing 是「借来看看，用完还你」，consuming 是「给我了，我可以直接改」。

## 1. 先测量：时间花在哪

方法：探针与库源码同模块 `-O` 编译，取多次运行最优值。改动前的基线是 `1021589`。

| 场景 | 实测 | 直觉上应该 |
|---|---|---|
| 把 100 万个原子拼成一个 `String`（11.7 MB 文本） | 28 ms | memcpy 11 MB 只要 1–2 ms |
| 以存在量形式 append 80 万个叶子 | 122 ms | 静态类型 append 同样的叶子只要 46 ms |
| builder 里 8 条语句的块 × 10 万次 | 206 ms | 8 次静态 append × 10 万次 ≈ 46 ms |
| 把一个 1 万原子的复合组件变成 `SemanticString` | 0.31 ms | 它自己展开只要 0.18 ms |

每一行「实测」与「直觉」之间的差距，就是一项优化的空间。查过、没有问题的两处：`==` 比较同一份存储的副本（`Array ==` 自带同一缓冲区短路，0 ms，不必加 `===` 快路径）；`Space` / `Indent` 同时遵循 `CustomStringConvertible`，会不会在 builder 里被路由到 `Standard(description)` 重载而丢掉语义类型（不会，组件重载优先）。

## 2. 优化一：拼接字符串改成拷字节

### 原来的写法

```swift
var computed = ""
computed.reserveCapacity(utf8ByteCount)
for atom in atoms {
    computed += atom.string
}
```

看起来已经很省了：容量预留过，每次只是 `+=`。

### 为什么它慢

`String +=` 每次都走通用的 `append` 路径：判断右侧是不是桥接的 `NSString`、两边是不是 ASCII / NFC，更新这些标志位，检查容量，再把字节拷过去。这些判断每个 token 一次，100 万个 token 就是 100 万次，比字节本身的搬运贵得多。

### 现在的写法

```swift
var utf8Bytes: [UInt8] = []
utf8Bytes.reserveCapacity(utf8ByteCount)
for atom in atoms {
    var tokenString = atom.string
    tokenString.withUTF8 { tokenUTF8 in
        utf8Bytes.append(contentsOf: tokenUTF8)      // 一次 memcpy
    }
}
return String(decoding: utf8Bytes, as: UTF8.self)   // 校验 + 一次拷贝
```

### 为什么可以这么做

1. **Swift `String` 内部就是 UTF-8 字节。** `withUTF8` 直接给出这段字节的指针。不超过 15 字节的短字符串内联在结构体里，它会先复制到栈上临时缓冲；桥接的 `NSString` 会先转成原生表示。两种情况都只是让「拿到连续字节」这一步付出正常代价，`+=` 内部同样要做。
2. **合法 `String` 的字节拼起来仍然是合法 UTF-8。** 每个字符串自身完整，首尾相接不会产生非法序列。所以 `String(decoding:as:)` 的校验必然通过、不会插入替换字符 U+FFFD，输出字节与 `+=` 的结果逐一相同。
3. **所有下游只看字节。** `==`（canonical 比较）、`hash`、`frozen()` 的 span 长度都由字节决定；字节相同则一切相同。

测试用 CJK、ZWJ 家庭 emoji、跨 token 的组合重音（`"e"` + `"\u{0301}"`）、超过 15 字节的堆分配字符串、桥接 `NSString` 各来一个，断言输出与字面量逐字节相等，冻结后的 `text` 也一样。

### 两个更快但被放弃的方案

- **`String(unsafeUninitializedCapacity:)`**：省掉「字节数组 → `String`」最后一次拷贝（实测 7.6 ms），但要 macOS 11 / iOS 14；本库部署目标是 macOS 10.15 / iOS 13，只能用 `#available` 做双路径。10% 的差距不值得两套实现两套测试。
- **预分配后按偏移裸写**（`initialize(from:count:)`，实测 7.9 ms）：第一遍算每个 token 的 `utf8.count`，第二遍按偏移写入。两遍之间若某个桥接字符串转码结果的字节数不一致——理论上不会，但无法对每一种 `String` 表示给出证明——就会越界写内存。`append(contentsOf:)` 每个 token 多一次容量检查（10.0 ms），换来无论 token 是什么都不可能越界。为内存安全付 25%，这笔账值。

**结果**：28.2 → 10.0 ms（2.8×）。`frozen()` 冷路径（第一次计算文本）36 → 19 ms。

## 3. 优化二：存在量 append 改为一次协议分派

### 问题：盒子里是谁，得问两次

`append` 有几个重载，编译器按**静态类型**挑：

```swift
mutating func append(_ component: some PlainAtomicSemanticComponent)  // 直接读 string / type 写进数组，零分配
mutating func append(_ component: AtomicComponent)                     // 保留 identifier
mutating func append(_ semanticString: SemanticString)                 // 按元素拼接
mutating func append(_ component: some SemanticStringComponent)        // 兜底
```

写 `declaration.append(Keyword("x"))` 时编译器知道是 `Keyword`，落到第一条快路径。但 builder 收集子项时装的是 `[any SemanticStringComponent]`，逐个 append 时静态类型只有 `any …`，永远落到兜底。兜底原来长这样：

```swift
if let atomicComponent = component as? AtomicComponent { … return }   // 动态转换 1
if let semanticString = component as? SemanticString { … return }     // 动态转换 2
appendComponentElement(flattening: component.buildComponents())        // 分配一个单元素数组，再逐元素拷进存储
```

一个 `Keyword` 走到这里：两次失败的 `as?`（各自要查运行时类型元数据），再分配一个只装一个元素的数组，再逐元素拷进存储。实测每个叶子约 150 ns，静态路径约 57 ns。

### 思路：让盒子里的类型自己报路

与其在外面猜「你是不是 X」，不如给协议加一个要求，每种类型自己实现「把我 append 进去」：

```swift
public protocol SemanticStringComponent {
    func buildComponents() -> [AtomicComponent]
    func _appendAsElement(into semanticString: inout SemanticString)   // 新增
}

extension SemanticStringComponent {           // 默认实现：原来的兜底
    public func _appendAsElement(into semanticString: inout SemanticString) {
        semanticString.appendComponentElement(flattening: buildComponents())
    }
}

extension PlainAtomicSemanticComponent {      // 叶子：静态快路径
    public func _appendAsElement(into semanticString: inout SemanticString) {
        semanticString.append(self)
    }
}

extension AtomicComponent {                   // 保留 identifier
    public func _appendAsElement(into semanticString: inout SemanticString) {
        semanticString.appendAtomElement(self)
    }
}

extension SemanticString {                    // 整体作为一个元素
    public func _appendAsElement(into semanticString: inout SemanticString) {
        semanticString.appendSemanticStringElement(self)
    }
}

extension Optional where Wrapped: SemanticStringComponent {   // 转发给内部值
    public func _appendAsElement(into semanticString: inout SemanticString) {
        if let wrapped = self {
            wrapped._appendAsElement(into: &semanticString)
        }
    }
}

// 兜底只剩一行
public mutating func append(_ component: some SemanticStringComponent) {
    component._appendAsElement(into: &self)
}
```

这个模式叫**双分派**：第一次分派由协议见证表完成——运行时查一次表，拿到该具体类型的实现；第二次在实现内部已经知道 `Self` 是谁，是静态调用。存在量调用协议要求的代价约等于一次间接函数调用，没有 `as?`，没有临时数组。静态类型已知时，编译器直接把这一行特化成对具体实现的调用，与原来的静态重载没有区别。

### 为什么行为不变

每个特化调用的正是原来 `as?` 命中之后调用的那个内部函数：

| 盒子里的类型 | 原来走到 | 现在走到 |
|---|---|---|
| `AtomicComponent` | `as?` 命中 → `appendAtomElement` | 特化 → `appendAtomElement` |
| `SemanticString` | `as?` 命中 → `appendSemanticStringElement` | 特化 → `appendSemanticStringElement` |
| `Keyword` 等库内叶子 | 两次落空 → `buildComponents()` → 单元素数组 → 逐元素拷入 | 特化 → `append(some PlainAtomicSemanticComponent)` |
| 其它（复合组件、自定义叶子） | `buildComponents()` → 逐元素拷入 | 默认实现 → 同 |

第三行两边落点不同，但结果相同：`PlainAtomicSemanticComponent` 的定义就是「我的 `buildComponents()` 是继承的默认实现，即 `[AtomicComponent(string: string, type: type)]`」。快路径读 `string` / `type` 直接构造，与调用 `buildComponents()` 得到的完全一样。「一个组件 = 一个元素」的粒度规则也没变：每个特化记录的元素数与原来对应分支一致。

**唯一的可观测差别**出现在违反这个约定的类型上：遵循了 `PlainAtomicSemanticComponent` 却又 override 了 `buildComponents()`。以前它经 `append` 走快路径（忽略 override）、经 builder 走兜底（采纳 override），两边内容不同；现在 builder 也走快路径，两边一致，override 只在复合组件直接调用它的 `buildComponents()` 时被采纳（例如 `MemberList(level:, [leaf])`、`Joined` 的 separator）。这不是新约束——协议文档一直整段警告不要这么做，debug 下的断言现在在两条路径上都会触发。已裁决清单里 S4 记录了这条分叉，理由不变、形态更新。

### 几个细节

- **为什么是 public 又加下划线。** 协议要求必须 public，外部类型的遵循才能拿到默认实现；下划线是 Swift 社区表示「public 只是技术需要，别调用、别实现」的惯例。文档明确写了外部类型不要实现它，需要自定义展平的继续 override `buildComponents()`。
- **默认实现会选对吗？** `Keyword` 在 `Keyword.swift` 里声明遵循 `AtomicSemanticComponent`，在 `PlainAtomicComponentConformances.swift` 里再遵循 `PlainAtomicSemanticComponent`。Swift 解析协议见证时会选**最特化协议扩展**里的默认实现，所以 `Keyword` 拿到的是快路径版本。这一点读代码看不出来，所以专门有一个测试：把违约叶子以存在量形式 append，debug 下必须触发快路径的断言（子进程非零退出）。如果见证解析到了通用默认实现，子进程会安静退出 0，测试失败。
- **`Optional` 也特化了。** `Keyword?` 以前展平成数组再 append；现在有值就转发给内部值的路径，`nil` 什么都不做——语义与「展平为空数组 → 完全 no-op」一致。
- **一个编译器怪癖。** `declaration.append(leaf as any SemanticStringComponent)` 这种写法编译不过（改动前也不过）：类型检查器会拿 `as` 转换去匹配最特化的泛型重载然后报错。测试里一律先 `let existential: any SemanticStringComponent = leaf` 再 `append(existential)`。

**结果**：存在量 append 121.9 → 69.8 ms（−43%），距离静态下界 44 ms 还有一次间接调用的差距。

## 4. 优化三：result builder 的累积参数改 `consuming`

### builder 展开后长什么样

```swift
SemanticString { a; b; c }
// 编译器生成的等价代码：
SemanticStringBuilder.buildFinalResult(
    SemanticStringBuilder.buildPartialBlock(
        accumulated: SemanticStringBuilder.buildPartialBlock(
            accumulated: SemanticStringBuilder.buildPartialBlock(first: a),
            next: b),
        next: c))
```

每条语句一次 `buildPartialBlock(accumulated:next:)`，实现是：

```swift
public static func buildPartialBlock(accumulated: [Element], next: Element) -> [Element] {
    var result = accumulated
    result.append(next)
    return result
}
```

### 为什么每一步都在拷整个数组

函数参数默认是 borrowing：调用方仍然持有 `accumulated`，函数只是借用。`var result = accumulated` 让缓冲区引用计数变成 2，接着 `append` 一看「不止我一个人在用」，就把整个数组拷一份再改。8 条语句的块拷 7 次，每次分配、逐元素拷贝、释放旧的。可调用方那个 `accumulated` 其实是上一步的临时返回值，之后再也不会用到——这份拷贝是白做的。

### `consuming` 做了什么

```swift
public static func buildPartialBlock(accumulated: consuming [Element], next: Element) -> [Element]
```

标注 consuming 后，调用方把所有权交给函数：`var result = accumulated` 是一次移动而不是拷贝，引用计数仍是 1，`append` 原地完成。

**为什么安全**：consuming 只改变谁负责释放，不改变值语义。如果某个调用方在调用之后还要用那个值，编译器会在调用点自动插入一份拷贝，行为不变，只是没省到。builder 展开出来的调用链里每个中间值都只用一次，所以全部省下。

**为什么优化器没有自动做掉**：这些方法不是 `@inlinable`，对另一个模块的调用方来说函数体不可见，编译器无法证明「函数内部不会把参数留下来」，只能保守地按借用处理。同模块探针测到的收益，在下游 app 里只会更大。

**结果**：8 语句块 × 10 万次，199 → 141 ms；与优化二叠加 199 → 92 ms。

## 5. 优化四：接管复合组件的展平结果

### 原来的两次拷贝

`declaration.append(Group(rows))` 的流程：`Group.buildComponents()` 把每一行的原子拷进一个新数组（第一次拷贝），然后 `appendComponentElement` 逐个原子过滤空字符串后 append 进存储（第二次拷贝）：

```swift
guard built.contains(where: { !$0.string.isEmpty }) else { return }
makeUniqueForMutation()
for atom in built where !atom.string.isEmpty {
    _storage.atoms.append(atom)
}
```

### 为什么可以直接接管

Swift 数组赋值不拷贝：`_storage.atoms = built` 只是让存储指向 `built` 的缓冲区，引用计数加一，O(1)。之后谁先修改谁拷贝——如果复合组件还活着并持有这个数组（`ForEach` / `IfLet` 会把展平结果存在 `content` 里），字符串下一次 append 时数组自己会拷一份，两边互不影响。这次拷贝正是原来无条件付出的那次，现在只在真的需要时才付。

两个前置条件：

1. **展平结果不含空原子。** 存储的不变量是「原子数组里永远没有零长字符串」，所以先全扫描一遍：含空原子的仍走原来的过滤循环；不含的才批量处理。全扫描只读每个字符串的长度，远比逐元素 append 便宜。
2. **目标为空才接管**，否则用 `append(contentsOf:)` 批量追加（一次 memcpy 加引用计数，代替逐元素 append 的容量检查）。

```swift
if built.isEmpty { return }
if built.contains(where: { $0.string.isEmpty }) {
    // 原来的过滤循环，不变
    return
}
makeUniqueForMutation()
if _storage.atoms.isEmpty {
    _storage.atoms = built                       // 接管，O(1)
} else {
    _storage.atoms.append(contentsOf: built)     // 批量追加
}
_storage.closeElement(appendedAtomCount: built.count)
```

一个容易漏的边角：「目标为空」只看原子数组，不看边界表。`SemanticString(components: [AtomicComponent(string: "")])` 会留下原子为空、边界表为 `[0]` 的值（零长元素槽是容器布局记账，公开接口观察不到）。接管后 `closeElement` 在这张非 nil 的表上追加末尾偏移，得到 `[0, n]`，与过滤循环的结果逐字节相同。有测试专门钉住这一情况，另有测试钉住接管后修改字符串不影响 `ForEach` 自己持有的数组。

**结果**：`SemanticString(Group(rows))` 0.31 → 0.18 ms，第二次拷贝整个消失；`MemberList(level: 1, rows).asSemanticString()` 0.37 → 0.19 ms。追加到非空目标只有 0.30 → 0.28 ms——那里的主成本是每个原子两次引用计数（`string` 与 `identifier` 各一次），循环写法改不了。

## 6. 三条通用原则

1. **少问「你是谁」。** `as?` 是运行时查表；能在类型系统里解决的分派（协议要求、泛型特化），就不要用动态转换去猜。
2. **让编译器知道所有权。** 值语义下多一个引用就多一次拷贝。`consuming` 是告诉它「这份可以直接用」，而不是靠优化器跨模块猜。
3. **拷贝能推迟就推迟。** 写时复制保证正确性，接管缓冲区比复制便宜；真正需要隔离时数组自己会拷。

反过来的三条：优化前先测，直觉上的热点和实测的热点经常不是同一个；每一处「更快但不安全」的方案要写下为什么放弃；行为不变要靠能变红的测试证明，而不是靠「我看过 diff」。

## 7. 怎么证明没改坏

- **14 项行为测试**（`Tests/SemanticTests/AppendPathPerformanceTests.swift`）：字节精确拼接、每种类型经存在量与静态路径结果一致、`Optional` 转发、接管后的写时复制隔离、零长元素槽、非空目标拼接、违约叶子经存在量触发断言。没有一项测时间——项目约定性能数字手工在 release 下对比并写进文档，不写成会随机器抖动的断言。
- **全套 401 项通过，release 399 项**（两项 `#if DEBUG` 断言测试按设计不参与），ThreadSanitizer 下并发测试无告警（append 漏斗被改动，锁与缓存未动但仍跑一遍），watchOS 32 位（`arm64_32`）编译通过。
- **A/B 方法**：同一探针源码分别对改动前后编译两份二进制，交替跑三次取最优。曾出现过一次 `enumerateSpans` 36 ms 的离群值（它没被改动），复跑三次两侧都是 28 ms，并用两种拼法产出的同一文本直接对比，确认是噪声。

## 8. 与提案的差异

无。提案在实现过程中原地更新，落地数字与决策日志都在提案里。

## 9. 没做的

- **`buildComponents(into: inout [AtomicComponent])`**：让复合组件直接写进目标数组，每层嵌套再省一次临时数组。改动面覆盖全部复合组件，留待评估。
- **内存方向**：边界表 `implicitPrefixCount`（方案已在 `SeventhReviewFixes.md` 末尾）、frozen `Span` 的稀疏 identifier 列、`AtomicComponent` 瘦身。后两项要动公开类型，需完整提案。

## 延伸阅读

- [AppendPathPerformance.md](AppendPathPerformance.md) —— 配套提案：范围、取舍、完整数字、决策日志
- [SettledFindings.md](SettledFindings.md) —— S3（builder 路径慢于 `main` 的记账）与 S4（违约叶子的内容分叉）
- `AGENTS.md` 的「Storage: Flat Atoms + Element Boundaries」与「The zero-allocation append path」两节
