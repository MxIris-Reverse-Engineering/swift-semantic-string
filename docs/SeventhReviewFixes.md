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

## 未完成（后续批次）

代码修复尚未落地，按优先级：

1. **真缺陷**：`FrozenSemanticString` 零长 span 绕过全部 trap 并制造空 `AtomicComponent`（第三轮补的「三向全部变响」不含零长这一向，解码器却校验它，两侧不一致）；`ConcurrencyTests` 两处注释描述了套件并不具备的覆盖，而 `AGENTS.md` 把该套件 TSan 跑绿定为改存储的准入门槛。
2. **性能**：`makingUnscopedCopy()` 使 `appending`/`+` 永远无法走就地分支（实测 1.65×，**且是第一轮明确修过、被第二轮重设计冲掉的回归**）；`closeElement` 的整表物化；`SemanticStringElements.init(_:[some SemanticStringComponent])` 漏 `reserveCapacity`（构造实测 10.5×，构造+渲染持平）；plain-leaf 断言的 debug 开销。
3. **可选加固**：`CacheLockStripes.stride` 硬编码 128，改为 `max(128, 按 cache line 向上取整的 primitive stride)` 可把运行时 trap 变为编译期恒成立。

## 验证

- 本批改动为纯文档/注释，`swift build` 通过，无测试变更。
- 文中每个数字均来自本轮双二进制实测，驱动程序为一次性探针（未入库）；`main` 侧对照数据见各节。
