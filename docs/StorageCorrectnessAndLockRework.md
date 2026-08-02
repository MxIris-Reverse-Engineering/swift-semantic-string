# 双态存储的行为一致性修正与缓存锁重做

- **日期**: 2026-07-27
- **提交**: `2dc9bcf`（分支 `feature/flat-contents-storage`）
- **状态**: 已落地，全部验证通过
- **前置**: [TwoStateStorage.md](TwoStateStorage.md)、[FrozenSemanticString.md](FrozenSemanticString.md)

## 动机

对 PR#1（双态存储 + `FrozenSemanticString`）做代码审查时，用同一份测试文件分别在
`main` 和该分支上跑对照，暴露出三类问题。

**一、flat 态绕过了零长度过滤，与 tree 态行为分叉。** `components` 在 flat 态直接
返回 `flatComponents`，而 tree 态的展平会经 `AtomicComponent.buildComponents()` 丢掉
空串组件。结果是同样的内容在两种形态下 `components` 数量、相等性、哈希、容器排版都不同。
六个对照测试在 `main` 上通过、在该分支上失败：

- `MemberList` 多出一行空的缩进行（`"\n    \n    var x\n"` 而非 `"\n    var x\n"`）
- `Joined` 在展平为空的项周围照样吐分隔符（`"Int, , String"`）
- 追加空组件后 `count`、相等性、哈希全部改变

这直接违反该分支自己在 `Storage` 文档里声明的核心不变量（两种形态对外完全一致），
也违反 AGENTS.md 里既有的「空串在原子层过滤」约定。

**二、全库共享的单把 `NSLock` 把并发构建串行化了。** 8 线程各建 5 万个互不相关的
临时字符串、每个做一次冷缓存填充：`main` 46.6 ms，该分支 434.9 ms。同样总量单线程跑
267 ms → 278 ms，只慢 4%，说明代价全部来自锁争用。也就是说在该分支上**并发（435 ms）
比串行（278 ms）还慢**，而这把锁的注释恰好写着它是为「printer 产生海量临时字符串」
设计、且「实践中无争用」。

**三、写时复制的复制路径仍有竞争。** `Storage.init(copying:)` 不持锁就读
`cachedComponents` / `cachedString`，与另一线程在锁内的填充写并发。ThreadSanitizer
在同一个「一边读一边复制并改」的测试上报 3 条竞争（`main` 上同样的测试报 26 条——
所以这不是该分支引入的，但分支声明的「TSan 无竞争」并不成立）。

另有若干正确性与性能细节：`compact()` 在共享状态下先展平、把结果发布进原值的缓存；
`compact()` 翻转 `isEmpty`；所有一等叶子组件（`Keyword` / `Space` / `Indent` /
`TypeName` …）掉出 flat 快路径；`frozen()` 明明有缓存全文却重新拼一遍；解码只校验字节
覆盖量、不校验 span 边界是否落在 Unicode 标量边界上；新增公开 API 全部缺 `@inlinable`。

## 范围

- `Sources/Semantic/SemanticString.swift`、`Sources/Semantic/FrozenSemanticString.swift`
- 新增 `Tests/SemanticTests/StorageDivergenceRegressionTests.swift`（8 个测试，只用
  两个 revision 都有的 API，可在 `main` 上原样跑作对照）
- 新增 `Tests/SemanticTests/TwoStateStorageRegressionTests.swift`（8 个测试，覆盖本分支
  新增的 `compact()` / `frozen()` / 快路径 / 并发）
- 新增 `Tests/SemanticTests/ConcurrencyTests.swift`（17 个测试，见下文「并发测试」一节）
- 修改 `TwoStateStorageTests` 中一处把快路径缺失钉成预期行为的断言

## 关键设计与取舍

### 零长度不变量放在写入口，而不是读出口

flat 态的全部价值在于 `components` 是 O(1) 的直接返回。若改为读时过滤
（`flatComponents.filter { !$0.string.isEmpty }`），每次读都要 O(n) 扫描加一次数组分配，
等于废掉这个形态。因此把不变量前移到所有写入 flat 数组的入口：
`appendAtomicComponent(_:)` 与两个 `[AtomicComponent]` 初始化器。初始化器先扫描一遍、
只在确实含空串时才 `filter`，常见情况零拷贝。

顺带记录一个对照结果：`init(components: [AtomicComponent])` 在 `main` 上**也**不过滤
（它把数组原样预缓存进 `cachedComponents`），且 `main` 上一次无关的 append 会让缓存失效、
重算出过滤后的结果——即 `main` 自身在这条路径上就不自洽。本次修改把两条路径统一了。

### `isEmpty` 语义统一为「展平后为空」

原实现按元素数判断（flat 看 `flatComponents`，tree 看 `treeElements`），所以
`compact()` 会把「元素非空但展平为空」的字符串的 `isEmpty` 从 `false` 翻成 `true`。
现在 flat 态仍是 O(1)（因为有上面的不变量，空数组是唯一展平为空的方式），tree 态在元素
非空时查展平结果（首次之后走缓存）。

**这是一处行为变更**：`SemanticString { EmptyComponent() }.isEmpty` 从 `false` 变
`true`（`main` 也是 `false`）。取舍理由是语义正确性优先——`isEmpty` 与 `count == 0`
此前可以互相矛盾。

### `compact()` / `compacted()` 降为 internal

压紧会把「一个元素 = 一行」变成「一个元素 = 一个 token」，而没有任何类型层面的信号阻止
调用方之后把压紧过的值当作 `MemberList` 的预构建 `content:` 传进去（实测渲染成一 token
一行，且无任何诊断）。这个约束只靠文档约定维持，而同一批工作已经提供了类型层面强制同一
生命周期的 `frozen()`。因此公开出口只保留 `frozen()`，`compact()` 作为内部实现细节存在。
这也是 [FrozenSemanticString.md](FrozenSemanticString.md) 里已经记下的方向。

### `compact()` 先取得独占所有权再展平

原实现先读 `components`（此时存储仍被共享）再 `makeUnique()`，等于把整份展平数组写进
**原值**的缓存里，然后才复制。对一个以省内存为目的的 API，净效果是「树 + 展平缓存 +
复制出的 flat」三份并存。改为先 `makeUnique()`，然后复用已有缓存或就地展平（独占后读自己
的缓存无需加锁）。

### 叶子组件的 flat 快路径改为静态派发

原快路径判断的是 `component as? AtomicComponent`——那是类型擦除后的盒子类型，而
`Keyword` / `Space` / `BreakLine` / `Indent` / `TypeName` 这些一等叶子组件全都不匹配，
于是每追加一个就触发 `convertToTree()`，把此前累积的所有原子重新装箱，并让后续追加全部走
装箱路径。这恰好废掉本分支的核心优化。

改为三层重载，由编译期重载解析静态选中：

| 重载 | 命中者 | 行为 |
|---|---|---|
| `append(_: AtomicComponent)` | 擦除后的盒子（带 `identifier`） | 直接进 flat |
| `append(_: some AtomicSemanticComponent)` | 一等叶子组件 | 转成 `AtomicComponent` 进 flat |
| `append(_: some SemanticStringComponent)` | 组合件 | 转 tree |

非泛型重载必须排在最前：`AtomicComponent(_ component: some AtomicSemanticComponent)`
会把 `identifier` 置为 `nil`，只有精确匹配那条能保住它。第三条里保留了运行时兜底
（先试 `AtomicComponent`、再试 `any AtomicSemanticComponent`），这样通过 existential
进来的调用方（`appending(_:)`、`+=`、持有 `any SemanticStringComponent` 的代码）
同样能走 flat，不必为每个入口再加重载。

### 缓存锁：按地址分片 + 按缓存行间隔

三个候选各有问题：

- **每实例一把锁**：`NSLock` 是对象，等于给每个临时字符串多一次分配——这正是原实现选择
  共享锁的理由。
- **全局共享一把锁**：无关字符串互相串行，实测并发比串行还慢（见动机第二条）。
- **`Synchronization.Mutex`**（SE-0433）：需要 macOS 15+，与本包 macOS 10.15 的部署
  目标冲突。

选定方案是按存储对象地址分片的 `os_unfair_lock` 表：无每实例分配，争用只发生在恰好落到
同一片、且同时冷填充的两个存储之间。地址先右移 4 位（对象至少 16 字节对齐，低位无熵）
再乘一个混淆常数取高位，避免连续分配的对象在表里成规律地行进。

**这里有一个只有实测才会暴露的陷阱**：`os_unfair_lock` 只有 4 字节，紧凑排列时 32 把锁
挤在同一条缓存行上。此时线程即使锁的是**不同**分片，也在争抢同一条缓存行，表现和单把
全局锁一样糟——实测 273 ms，恰好等于串行时间 269 ms。把每片按 128 字节（缓存行）间隔
之后同一份负载降到 117 ms。分片数从 64 提到 256 后进一步到 44.7 ms，已追平 `main`。

分片数与常驻内存的取舍：64 片 8 KB / 256 片 32 KB / 1024 片 128 KB，实测 1024 片
（45.3 ms）相对 256 片（44.7 ms）已无收益，取 **256 片**。

### `init(copying:)` 从 `@inlinable` 降为 `@usableFromInline`

函数体现在要在锁内读缓存，而跨模块内联会把锁原语一并暴露到内联体里。每次写时复制多一次
非内联调用，相对于同一函数里的数组拷贝可忽略。

### 顺带：库不再依赖 Foundation

`NSLock` 是全库唯一的 Foundation 用法（`grep -rn '^import' Sources/Semantic/` 在
`main` 上无输出）。换成 `os_unfair_lock` 后，`FrozenSemanticString.swift` 里的
`import Foundation` 也一并去掉——`Codable`、`DecodingError` 都在标准库里。现在整个
target 只有一个 `import os.lock`。

## 影响与验证

| 场景（Release） | `main` | 本分支修改前 | 修改后 |
|---|---|---|---|
| 并发冷缓存填充（8 线程 × 5 万临时串） | 46.6 ms | 434.9 ms | **44.7 ms** |
| 串行冷缓存填充（40 万） | 267.3 ms | 278.0 ms | 271.2 ms |
| 缓存命中读（20 万次 `.string`） | 1.95 ms | 4.00 ms | **2.89 ms** |
| ThreadSanitizer 竞争数（读+改同一存储） | 26 | 3 | **0** |

- 320 个测试在 debug 与 release 下全部通过；全套在 ThreadSanitizer 下零竞争报告。
- 计时断言现状：AGENTS.md 此前点名的两个缓存读断言
  （`repeatedStringReadsAreCached` / `repeatedComponentsReadsAreCached`）现在在
  TSan 下也通过。TSan 下全套会报三条 `StressTests` 计时超预算，但加 `--no-parallel`
  后只剩一条——1 万组件编解码往返（207.8 ms / 预算 200 ms），且它在 `main` 上同样超
  （200.5 ms）。另两条是测试并行执行时的 CPU 争抢，不是回归。计时结论一律从未插桩的
  运行里取。

**行为变更清单**（下游需要知道的三条）：

1. `isEmpty` 改为按展平结果判断，见上文。
2. `compact()` / `compacted()` 不再是公开 API。
3. `FrozenSemanticString` 的解码更严格：span 边界切开 Unicode 标量的载荷现在抛
   `DecodingError.dataCorrupted`，而不是静默切错后续所有 span。

## 并发测试与其有效性验证

并发相关的契约集中在 `Tests/SemanticTests/ConcurrencyTests.swift`（17 个测试）：共享值的
各类派生读取、两个缓存的交叉填充顺序、写时复制的隔离性、flat 态无锁读与副本改动并发、
派生变换（`map` / `replacing` / `filter` / trimming / 下标）、并发编码、并发 `frozen()`、
frozen 值的无同步并发读、跨 actor 边界的值语义，以及锁顺序。

**这些测试在普通运行下几乎必然通过——断言本身抓不到竞争。** 因此逐条做了变异验证
（故意把修复回退，看测试是否变红），确认它们不是装饰：

| 变异 | 结果 |
|---|---|
| 去掉 `Storage.init(copying:)` 的锁 | TSan 竞争 0 → **22**，栈顶指向复制路径 |
| 去掉 `string` 缓存发布的锁 | TSan 竞争 0 → **82**，但**全部断言仍通过** |
| 把展平移到锁内 | 死锁守卫测试**挂住**（确定性，非概率） |

第二行是这批测试存在的理由：断言全绿而竞争 82 条。判断并发是否安全只能看
`swift test --sanitize=thread`，不能看测试是否通过。

### 一个反直觉的发现：分片哈希对固定间隔的对象对是线性的

写「锁内展平会死锁」这条守卫时，最初的做法是构造大量嵌套对、期待其中若干对的 outer 与
inner 落在同一分片（1/256 的概率，4096 对应该期望 16 次碰撞）。**实测碰撞 0 次。**

原因是分片索引是地址的乘法哈希，而乘法是线性的：循环里以相同方式构造的每一对，两个
storage 的地址差是固定的，于是分片索引差也是固定的常数——要么恒等（永远碰撞），要么恒
不等（永远不碰撞）。改为变化「两次分配之间插入多少其它对象」，碰撞就按固定周期出现
（当前分片数下为 186、373、560、747……）。守卫测试因此改为主动搜索一个碰撞间隔，并断言
「确实找到了」，避免将来分片函数一改就静默退化成什么都没测。

这对锁的性能没有影响（相邻对象仍然落在不同分片，实测数据见上表）。但它意味着「持锁时
回调组件代码」这类风险在真实分配模式下是**要么永不出现、要么必然出现**——正是最难在测试
里碰上、却会在生产里稳定复现的那类问题。当前实现在锁外展平，从结构上排除了它。

## 迁移注意

- 原先调用 `compact()` 的存储边界改用 `frozen()`；确实需要保持可变的场景请在本库内评估，
  不要重新公开 `compact()`。
- 依赖 `isEmpty` 廉价性的热路径请注意：tree 态在元素非空时会触发一次展平（此后走缓存）。
- 自行构造 `FrozenSemanticString`（`init(text:spans:identifierTable:)`）的调用方仍需
  自己保证不变量——该初始化器按设计不做校验，校验只发生在 `frozen()` 与解码这两条路径。
