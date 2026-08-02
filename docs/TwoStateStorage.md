# SemanticString 双态存储（flat / tree）设计记录

- **日期**: 2026-07-26
- **提交**: `5bad30c`（分支 `feature/flat-contents-storage`）
- **状态**: 已落地；本文若干实现细节已被后续修正取代，见
  [StorageCorrectnessAndLockRework.md](StorageCorrectnessAndLockRework.md)

> **后续修正**：本文记录的是当时的落地状态。审查发现三处与本文描述不符或不成立之处，
> 已在 `2dc9bcf` 修正：flat 态当时并未过滤零长度组件（与 tree 态行为分叉）；
> 「行为不变性」一节的结论因此当时并不成立；缓存填充的共享单锁把并发建串行化，
> 已换成按缓存行间隔的分片锁；`compact()` / `compacted()` 已降为内部 API。
> 下文保留原貌，仅在相应段落标注。

## 动机

`AtomicComponent` 40 字节，超过 existential 容器 24 字节的内联缓冲，因此旧的单一
`elements: [any SemanticStringComponent]` 存储对**每个 token** 支付 40 字节容器 +
64 字节 malloc 箱；首次 flatten 后 `cachedComponents` 再存一份 40 字节/token 的
扁平数组，两份长期共存。在 RuntimeViewer 全量打印 AppKit + SwiftUI 的实测中
（346 万 token、27.3 MB 文本），仅装箱树就驻留 300+ MB，进程 footprint 1.27 GB。

## 设计

`Storage` 持有两个数组，任一时刻只有一个非空（`isFlat` 判别）：

- **flat**（`flatComponents: [AtomicComponent]`）：类型化数组，零装箱。进入路径：
  流式原子 append（printer 热路径，旧实现每 token 装一次箱）、
  `init(components: [AtomicComponent])`（解码、transformer）、`compact()`。
- **tree**（`treeElements: [any SemanticStringComponent]`）：构建期形态，保留
  element 边界——`MemberList` 类容器把一个 element 当一行，组合件必须整体保留。
  向 flat 字符串 append 组合件时先经 `convertToTree()` 把已有原子转回树。

**行为不变性**：flat 态只承载旧存储本来就以「逐个装箱的 AtomicComponent element」
形式持有的内容，因此 `elements` 视图在两种形态下粒度完全一致；`components`、
`string`、相等性、哈希、Codable 输出、容器行布局全部不变。

> 修正（`2dc9bcf`）：这条结论当时并不成立——flat 态的 `components` 直接返回数组，
> 绕过了 tree 态展平时的零长度组件过滤，导致两种形态在组件数量、相等性、哈希与容器
> 排版上确有分叉。现已在所有写入 flat 数组的入口补上过滤，使该结论成立。

**`compact()` / `compacted()`**：把已定稿的树坍缩为 flat，释放组合树与全部箱子。
调用方在存储边界显式使用（如 RuntimeViewer 的 `RuntimeObjectInterface.init`）。
约束：compact 之后不得再把该字符串当作 `MemberList` 等容器的预构建 `content:`
使用（element 粒度已变为逐原子）；实践中所有容器调用点都走 builder 闭包，不受影响。

> 修正（`2dc9bcf`）：这条约束没有任何类型或运行时保障，而同一批工作已提供了在类型层面
> 强制同一生命周期的 `frozen()`。`compact()` / `compacted()` 因此降为内部 API，
> 公开出口只保留 `frozen()`。另外原实现在存储仍被共享时就先展平，会把结果发布进原值的
> 缓存，已改为先取得独占所有权。

**并发**：`cachedComponents` / `cachedString` 的惰性填充原本对跨线程共享的 storage
存在无同步竞写（既有隐患），现由全库共享的单把 `NSLock` 保护；昂贵的 flatten 在锁外
计算，锁内只做比较-存储。不用每实例锁是为了避免给 printer 的海量临时字符串各加一次分配。

> 修正（`2dc9bcf`）：共享单锁让无关字符串互相串行——8 线程各建 5 万个临时串做冷填充，
> 实测 46.6 ms（改造前）→ 434.9 ms，并发甚至慢于串行。已换成按对象地址分片、且每片按
> 缓存行间隔的 `os_unfair_lock` 表（256 片），同一负载 44.7 ms。另外写时复制路径
> （`Storage.init(copying:)`）当时仍不持锁读缓存，TSan 报 3 条竞争，也已修正。

## 取舍

- 双数组 + `isFlat` 而非 enum payload：绕开 enum 关联值取出/写回在热路径上的 CoW 拷贝陷阱。
- ~~全局锁而非每实例锁：填充仅每字符串一次且极短；代价是 TSan 插桩下 StressTests 的两个
  计时断言（缓存读 ≤2× 构建）超预算——无插桩运行通过，属预期。~~
  已被分片锁取代（`2dc9bcf`）：全局锁的真实代价不是插桩下的计时断言，而是并发构建被
  串行化近 10 倍；换成分片锁后那两个计时断言在 TSan 下也通过了。
- O2 已随后落地为独立的不可变终态类型，见
  [FrozenSemanticString.md](FrozenSemanticString.md)：text arena + 8 B Span +
  identifier 内插 + 列式 Codable，实测在 O1 基础上再降至 ~285 MB（基线 1.27 GB）。

## 影响与验证

- 本库 275 测试全过（新增 `TwoStateStorageTests` 23 个，覆盖状态转换、append 矩阵、
  compact 语义、容器粒度回归、Codable、冷缓存并发）；TSan 无 race 报告。

> 修正（`2dc9bcf`）：「TSan 无 race 报告」当时不成立——新增的并发测试只有并发**读**，
> 没有「一边读一边写时复制并改」的组合，因此没有触发仍然存在的复制路径竞争。补上该组合
> 后 TSan 报 3 条竞争（同一测试在改造前的 `main` 上报 26 条），现已清零。
- MachOSwiftSection 60 个 interface/dump 快照逐字节一致。
- RuntimeViewer 探针（AppKit + SwiftUI 全量打印）：语料输出逐字节一致；
  footprint 1.27 GB → 382 MB（-70%）；峰值 RSS 1.35 GB → 489 MB；打印耗时持平。

## 迁移注意

对下游透明，无 API 破坏。新增可选 API：`compact()` / `compacted()`——仅在「字符串
已定稿且此后只读」的存储边界调用；构建中途不要调用。

> 修正（`2dc9bcf`）：`compact()` / `compacted()` 已降为内部 API，从未随版本对外发布。
> 下游请改用 `frozen()`。
