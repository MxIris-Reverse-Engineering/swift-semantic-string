# 第七轮评审：四问核验与文档诚实化

## 动机

第六轮之后又做了一轮独立评审，报告 15 项发现。本轮不采信转述，对每一项按项目规定的四问逐条核验：**能否复现（是否误报）**、**`main` 是否同样存在**、**值不值得修**、**以前是否修过**。核验手段是双二进制探针——用同一份驱动程序分别链接 `main` 与本分支，逐项对照输出与实测数字。

结论：**15 项全部复现属实，无技术性误报**，但性质分布极不均匀：

- **7 项值得修**（其中 1 项是被本分支自己冲掉的回归、1 项是上一轮只修了一半的同类遗漏）；
- **5 项在前几轮已被明确裁决**（有意偏离 / 有意不修 / 用户决定），属重复报告；
- **1 项 `main` 上表现完全相同**，非本分支引入；
- **1 项**为可选加固。

重复报告占三分之一，是因为此前六轮的裁决只散落在各轮修复文档里，没有一份可供对照的清单。本轮同时补上这份清单（[SettledFindings.md](SettledFindings.md)）。

**本批只落地文档修正**（下述「范围」全部为文档与注释），代码修复分批进行，未完成项在文末列明。

## 范围

本批改动全部为文档/注释诚实化，无行为变更：

- `Sources/Semantic/SemanticStringComponent.swift` —— `PlainAtomicSemanticComponent` 的协议文档此前称「debug 断言使违约实现在首个流式测试即失败，而不会把分叉发布出去」，与实现相反。改为实话：`assert` 在 `-O` 下被编译掉，违约实现在 release 下**静默发布内容分叉**（实测 `append` 渲染 `"x"`、builder 渲染 `"<x>"`，两值 `!=`、hash 不同、进程退出码 0）；断言只在恰好有 debug 测试流式写入该叶子时才触发，是开发辅助而非保证。
- `AGENTS.md` 三处：
  1. 存储章节仍称「展平为空的组件记录零长元素槽」——第六轮已改为完全 no-op，该段漏改，与同文件第 90 行自相矛盾。改为 no-op，并写明零长槽只存活于 `init(components:)`。
  2. 同段补充边界表物化的代价：`closeElement` 用 `Array(1 ... previousAtomCount)` 一次性分配，**永不回收**，且此后每次写时复制都跟着复制（实测数字见下）。「流式零开销」只对**从未**收到非 1:1 append 的字符串成立。
  3. 不变量 1 删去失实的「唯一对空输入不记元素的入口是 `append(_:type:)`」，并补上真实存在的粒度分歧（见下）；「零分配 append 路径」条目删去被证伪的「粒度不可能在路径间分叉」，改为指向该分歧，并补记断言自身的性能代价。
- `README.md` 新增「Components are flattened when they are appended」一节：`buildComponents()` 在 append 时执行而非渲染时，读取可变外部状态的组件会被就地快照。此前只写在 `docs/` 与 `AGENTS.md`，面向使用者的迁移说明缺失。
- 新增本篇与 [SettledFindings.md](SettledFindings.md)，`docs/README.md` 索引同步；`AGENTS.md` 补「处理评审发现前先查已裁决清单」的指引。
- **PR 描述与标题重写**：原文描述的是 `4aaa56e` 换掉的双态设计（`isFlat`、`compact()` / `compacted()`、`TwoStateStorageTests`），这些标识符在 `Sources/` 与 `Tests/` 中**零匹配**，测试数也写成 275（实为 376）——照描述审批等于批准另一份实现。已改为实际落地的设计，并对沿用自双态时代的 RuntimeViewer 内存数字加注「重设计后未重新端到端测量」，同时把已知的性能回退（含本轮新发现的四项）如实列出。
- **补建跟踪 issue [#2](https://github.com/MxIris-Reverse-Engineering/swift-semantic-string/issues/2)**：元素边界经 `Codable` 往返坍缩。第六轮承诺"单开 issue 独立跟踪"，但 `gh issue list --state all` 返回空——承诺从未兑现。

## 关键核验结果

### 粒度确实会随静态类型分叉（推翻 AGENTS.md 的断言）

`AGENTS.md` 原称「granularity cannot diverge between paths」。实测证伪：

```swift
var direct = SemanticString();     direct.append(source)          // MemberList → 6 行
var viaGeneric = SemanticString(); f(source, into: &viaGeneric)   // MemberList → 3 行
direct == viaGeneric                                              // true
```

机制：`append(_ semanticString: SemanticString)` 按元素拼接、保留操作数自身的边界；而泛型/存在类型上下文只看得见 `some SemanticStringComponent`，走通用重载的 `as?` 分支进入 `appendSemanticStringElement`，整体记为**一个**元素。重载决议是静态的，所以同一个值因调用方静态类型不同而得到不同粒度。

这对 builder 是**必要**的（每个 builder 子项必须保持一个元素，否则 `MemberList { for row in rows { row } }` 会丢行），因此不作为缺陷修复，但必须停止把粒度描述为「值自身的属性」。

### 边界表物化的真实代价（A/B 双进程实测）

| 场景 | 一次 `+` 的写时复制成本 |
| --- | --- |
| 100 万 token 纯流式 | 38.2 MB（≈ atoms 38.1 MB，表未物化） |
| 同上 + **一次**两原子 `Group` append | **45.8 MB**（多出整张 7.6 MB 表） |

一次复合 append 使此后每次复制永久多付 20%。第六轮修掉的是「**零宽** append 物化整表」，非零宽的复合 append 走同一个 `closeElement`，同样执行 `Array(1 ... previousAtomCount)`——同类未横向排查，属上一轮的遗漏（已列入待修）。

### 断言的性能代价（此前从未评估）

debug 下 30 万次 append，PR 内部对照：

| 路径 | 耗时 |
| --- | --- |
| `append(Keyword(_:))`（带断言，文档称「零分配快路径」） | **149.7 ms** |
| `append(_:type:)`（无断言，普通路径） | **73.2 ms** |

被文档称作零分配快路径的那条，在 debug 下比普通路径慢一倍——`assert` 的 `@autoclosure` 会真的执行 `buildComponents()`，分配的正是该快路径存在意义所在的那个数组。且该重载是 `@inlinable`，链接 Release `Semantic` 的下游 Debug 应用同样付这笔开销。第五轮加入断言时详细记录了另外两个微优化的实测负收益并回退，唯独这条没测。（已列入待修。）

## 影响面

- **无行为变更、无 API 增删**，本批全部为文档与注释。
- 依赖「协议文档承诺 debug 断言会挡住违约实现」的第三方实现者，现在能从文档读到真实保证强度。
- 依赖延迟解析模式（先搭结构、后填名字/地址）的使用方，现在能从 README 读到该模式已失效及其替代写法。

## 第二批：正确性修复

### 零长 span 在读取路径全部变响

unchecked init 的契约列了四条不变量并承诺「违反者在每个走文本的读取中 trap」。第三轮补齐的是**三**向——覆盖超出、覆盖不足、标量未对齐——**零长这一向漏了**，而它写在同一句话里。后果实测：

- `isEmpty == false` 与 `text.isEmpty == true` 并存；
- `enumerateSpans` 安静吐出一个空 `Substring`；
- `components` 造出 `AtomicComponent(string: "")`——存储、展平、冻结、解码器全都禁止的东西；
- 交错形态（text `"ab"`、spans `[1, 0, 1]`）`components` 返回 `["a", "", "b"]`，`SemanticString(components:)` 丢掉空项，重建值再冻结**不再等于原值**；
- 该值自己编码出来的载荷，喂回自己的解码器被拒收。

**解码器一直在校验零长**（第三轮引入，其注释论证的理由与上述现象完全一致），所以同一条不变量，解码路径拒收、构造+读取路径放行——两个入口互相矛盾。

修复落在 `spanUpperBound(after:spanLength:)`：这是第五轮引入的共用 helper，`enumerateSpans`、`components`（经 enumerateSpans）、`==` 慢路径三个消费点全部经过它，**一处加 `precondition` 覆盖整类**。横向排查确认没有第四个走文本的遍历点：`hash(into:)` 与 `==` 快路径按设计不走文本（第五轮的既定决策，畸形值哈希不得崩溃），保持安静；编码侧只 map 字段。

用 `precondition` 而非 `assert`，与既有三向一致——它是 release 下唯一挡住 unchecked init 坏值的守卫（第五轮结论），release 全套测试确认 trap 生效。

### `ConcurrencyTests` 补上它自称拥有的覆盖

两处注释描述了套件并不具备的覆盖，而 `AGENTS.md` 把「该套件 TSan 跑绿」定为改存储/加锁的准入门槛：

1. 注释称 `appending`/`+`/`+=`「经存在类型回退进入泛型 append 重载」。实际四个分支用的全是 `Keyword`（`PlainAtomicSemanticComponent`，静态派发到 plain 重载）与 `SemanticString`（自己的重载）。**泛型 `append(_:some SemanticStringComponent)` 漏斗零并发覆盖**——而这正是每个 builder 子项的必经之路，也是做两次 `as?` 转换的那条。补两个测试：一个用 composite（两次转换都落空、走急切展平），一个经未特化泛型参数（静态类型只剩 `some SemanticStringComponent`，叶子也被迫走这里）。
2. 注释称 `frozen()`「读两个缓存……冻结冷值会同时 race 两次填充」。`frozen()` **一次填充都不做**（用只读的 `cachedStringIfPresent()`，冷时本地拼接不发布），`StorageCacheRegressionTests.frozenDoesNotFillTheSourceCache` 正是钉这个的——该测试 race 的是零次填充。注释改为实话，并补一个真正 race 那唯一一次填充的测试：一半任务读 `string`（在条带锁下发布缓存），一半任务 `frozen()`（读同一字段），要么看到已发布值要么自算，不得撕裂。

## 第三批：性能与加固

### `appending` / `+` 改为 `consuming`——以及一处对自己的结论纠正

**初判有误，实测推翻。** 本轮最初把它判为「第一轮明确修过、被第二轮重设计冲掉的回归」，依据是第一轮修复文档删掉的正是 `var copy = self` 这个模式，而第二轮重设计把它写了回来。逐项实测后这个因果站不住：

| 写法 | `main` | 本分支（borrowing） | 本分支（`consuming`） |
| --- | --- | --- | --- |
| `acc = acc + piece`（4000 次） | 42.3 ms | 75.8 ms | 76.8 ms |
| `acc = (consume acc) + piece` | — | 75.1 ms | **0.2 ms** |
| `acc += piece`（就地下界） | — | 0.2 ms | 0.2 ms |

默认累加写法在改动前后**都是约 76 ms**——`consuming` 对它毫无影响。原因是 `acc` 是赋值目标，右值求值期间它仍是活的变量绑定，编译器无从证明可以转移所有权。与 `main` 的 1.65× 差距因此**不是**那个模式造成的，而是元素本身变大的固有代价：`main` 复制的是每元素一个装箱指针（8 字节、1 次引用计数操作），本分支复制的是 `AtomicComponent`（40 字节、2 次——`string` 与 `identifier` 各一次）。第一轮真正修掉的是**额外的** `Storage` 复制（当时还会加锁并复制两个缓存字段），那个修复至今有效，`Storage(copyingContentsOf:)` 就是它。

`consuming` 仍然保留，因为它启用了两条此前**不存在**的路径——注意上表：原版即使写显式 `consume` 也是 75.1 ms，因为参数是 borrowing，函数内 `var copy = self` 照样 retain。改动后：

- **链式 `appending`**（`a.appending(x).appending(y)…`，常见写法）：13.7 ms → **7.7 ms（1.78×）**，中间临时值的所有权被正确转移；
- **显式 `consume` 的累加循环**：75.1 ms → **0.2 ms**，与就地路径持平，调用方现在有办法把 O(n²) 降为摊销 O(1)；
- **仍需复用原值的场景**：2.8 ms → 2.9 ms，编译器按需插回拷贝，语义与性能都不变。

结论：这是一项**能力增补**，不是回归修复。默认累加写法的 O(n²) 是 `appending` 值语义的固有成本（`main` 同样是 O(n²)，只是常数小），文档不应再暗示它可以被消除。

### 其余三项

- **`SemanticStringElements.init(_:[some SemanticStringComponent])` 补 `atoms.reserveCapacity`**：此前只给边界表预留、给接收全部原子的数组不留，10k 行要走约 18 次几何重分配。构造 5000×300：63.2 ms → 59.7 ms。**注意本项收益有限**——该初始化器与 `main` 的差距主体是急切展平本身的原子拷贝，不是重分配次数；且「构造+渲染」两侧本就持平，慢的只有「构造完即丢弃」这一种用法。
- **plain-leaf 断言只读一次 `string`、按字段比较**：省掉两次多余的 `string` 读取（对 `Indent` 是三次 `String(repeating:)` 分配）和一个一次性比较数组。debug 30 万次 append：149.7 ms → 140.9 ms（约 6%）。**主成本无法消除**：验证 `buildComponents()` 的返回值就必须调用它，那次数组分配是不可约的，所以这条路径在 debug 下依然比无断言的 `append(_:type:)`（76.9 ms）慢。断言的定位因此仍是开发辅助，不是零成本保证。
- **`CacheLockStripes.stride` 由推导代替硬编码**：改为 `max(128, ≥ primitive stride 的最小 2 的幂)`。原先是硬编码 128 加一个运行时 `precondition`，而该 `precondition` 位于惰性 `static let` 内——真出问题会在进程首次 `SemanticString.string` 读取时炸在 `swift_once` 里，而非构建期；`-Ounchecked` 下它被整个移除，相邻条带重叠、互斥静默消失。推导之后两种结局都不可达。用翻倍而非「向上取整到 128 的倍数」，是因为 `allocate(byteCount:alignment:)` 要求对齐是 2 的幂——384 是合法的 cache line 倍数，却是非法的对齐值。

## 未完成（后续批次）

**边界表的整表物化（`closeElement`）** 未修，是本轮唯一有意留下的代码项。方案已经设计好：把 `elementEndOffsets: [Int]?` 换成 `implicitPrefixCount: Int` + `explicitEndOffsets: [Int]`，「前 N 个原子各自一个元素」退化为一个整数，`Array(1 ... previousAtomCount)` 随之消失，纯流式字符串的表示不变（`implicitPrefixCount == atoms.count` 且 `explicitEndOffsets` 为空）。

单独成批的理由：它是全部发现里唯一需要改动核心数据结构的一项，波及 `Storage` 的 7 个方法、`SemanticStringElements.atoms(ofElementAt:)`（所有容器渲染的热路径）、`SemanticString` 的 4 处，以及 6 个直接断言 `_storage.elementEndOffsets` 的测试文件——那些断言是有意钉住存储设计的，改写时的理解偏差会掩盖真问题而不是暴露它。本轮前两批全是文档与局部改动，混入一次数据结构重构会让三者的风险互相污染。而它本身只是内存优化，不涉及正确性：一次复合 append 使其后每次写时复制多付 20%（实测 38.2 MB → 45.8 MB），代价明确且已在 `AGENTS.md` 记录在案。

**`CacheLockStripes`** 一项已在本批完成，不再列为可选加固。

## 验证

- 第一批为纯文档/注释，无行为变更。
- 第二批：新增 `SeventhReviewRegressionTests`（6 项）。四项 trap 测试**先行确认为红**——修复前畸形值静默正常退出（`.failure → .exitCode(0)`），修复后转绿；两项为对照（`hash` 必须保持安静、良构值不受影响），全程为绿。
- `swift test`（debug）：**385 项 / 55 套件**全绿。
- `swift test -c release -Xswiftc -enable-testing`：384 项全绿（少的一项是 `#if DEBUG` 守卫的断言测试）——确认零长守卫在 `-O` 下依然生效。
- `swift test --sanitize=thread --filter ConcurrencyTests`：19 项全绿，**零竞争报告**。
- `arm64_32-apple-watchos6.0` 交叉编译通过。
- 文中每个数字均来自本轮双二进制实测，驱动程序为一次性探针（未入库）；`main` 侧对照数据见各节。
