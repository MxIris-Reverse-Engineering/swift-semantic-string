# 扁平存储重设计：单一表示 + 显式元素边界

## 动机

双态存储（flat / tree）落地并经过一轮修正（[StorageCorrectnessAndLockRework.md](StorageCorrectnessAndLockRework.md)、[ReviewFixes.md](ReviewFixes.md)）之后，第二轮独立评审仍然找出了 15 处缺陷。逐条核验（探针程序 + 与 `main` 的逐字节对照）确认全部属实，其中 10 条可以追溯到同一个源头——双态设计要求每条 API 路径在一个组合面上保持一致：

- **两种表示**（flat / tree）× 每个读写点都要行为等价，`convertToTree()` 状态迁移本身就是缺陷来源（append 一个「渲染为零输出」的组件会永久毁掉 flat 表示，实测内存 +63%）；
- **共享 CoW storage 上的惰性组件缓存**，催生了「发布 / 不发布」这个无法沿组件协议传递的概念（`frozen()` 保护了自己的缓存，却仍会填满每个被 `MemberList` 持有的子串的缓存）；
- **靠重载决议选择快路径**，同一个值因静态类型不同走不同路径（定制叶子被拆成多个元素、identifier scope 只在部分路径生效）。

逐条打补丁会继续往这个组合面上加代码——第二轮的缺陷绝大多数正是第一轮修正新引入的。因此选择消灭组合面本身。

## 范围

`SemanticString.Storage`、`SemanticStringElements`、`SemanticString` 核心与 `+Mutation` / `+Composition`、全部容器组件的展平循环、对应测试套件。`FrozenSemanticString` 不在本次重设计范围内（它的三处缺陷独立修复：`==` 快路径破坏传递性、32 位 `Int(UInt32)` 转换陷入、解码校验的文档谎言）。

## 关键设计

### 存储

```swift
final class Storage {
    var atoms: [AtomicComponent]      // 全部原子，永远扁平，永无零长原子
    var elementEndOffsets: [Int]?     // 元素边界（end offset）；nil = 每原子一个元素
    var cachedString: String?         // 唯一的共享可变状态，由分片锁保护
}
```

核心观察：tree 形态保留 composite 对象只为一件事——元素粒度（`MemberList` 一个元素一行）。而 `buildComponents()` 无参数、确定性，composite 在构建之后没有任何再利用价值。于是把粒度记成**数据**（边界表），composite 在 append 时**立即展平**、随后丢弃。

- 流式路径（`append(_:type:)` / `write`）保持 `elementEndOffsets == nil`，零额外开销；首个非 1:1 元素出现时才物化边界表，代价是每元素 8 字节——对比旧 tree 形态每 token 40 字节存在型容器 + 64 字节堆箱。
- **零输出元素**（append 的 `nil` optional、`EmptyComponent`、空 composite）记录为零长边界（`ends[i] == ends[i-1]`）：不占原子、不产文本，但占一个元素位——与历史元素树的可观察行为完全一致。
- 「append 一个组件 = 记一个元素」对所有组件重载统一成立；`append(_ semanticString:)` 是元素级拼接。唯一例外与历史一致：`append("", type:)` 完全不记录。

### 消灭的缺陷类别

| 旧缺陷 | 新设计下 |
| --- | --- |
| 空 composite append 毁掉 flat（+63% 内存） | 不存在第二种状态可翻转；实测差距降到 +3.8%（边界表本身） |
| `frozen()` / `isEmpty` 填满嵌套子串的缓存 | `components` 就是存储，读取无副作用；「发布/不发布」概念整个消失 |
| 容器 scratch 循环比 main 慢 1.7× | 容器直接切零拷贝 slice，实测**比 main 快**（Joined 82 vs 99 ms） |
| 定制叶子被拆成多元素 / 粒度分叉 | 所有 append 汇合到一个漏斗，粒度=边界表，一处定义 |
| `compact()` 丢缓存、死代码、不变式漏洞 | `compact()` / `convertToTree()` / 组件缓存整体删除 |
| ForEach 判空每条目双展平 | `isEmpty` 是 O(1) 元素计数 |

### 行为决策（与 main 的逐字节对照）

以 `main` 的 136 项 golden 输出为基准：

1. **输出逐字节一致**：全部 `.string` 输出与 main 相同，包括 `ForEach(separator:)` 对空条目发分隔符的行为（`["a","","b"]` → `"a, , b"`）——上一轮把它改成了 `"a, b"`，与 PR 的 byte-identical 承诺冲突，本轮恢复。
2. **`isEmpty` 恢复 main 语义**：「没有元素」而非「展平为空」，O(1)。`SemanticString { EmptyComponent() }.isEmpty == false`；`count == 0` 才是「渲染为空」的判据。
3. **唯一的有意偏离**：零长原子在**所有**构造路径被丢弃（上一轮只覆盖 `[AtomicComponent]` 初始化器，本轮连第三方 composite 展平输出也过滤）。手工构造 `AtomicComponent(string: "")` 不再进入 `count` / `components` / 编码输出；元素计数不受影响（零长元素照记）。`Codable` 往返因此**永远幂等**——编码输出里不可能出现空原子。
4. **identifier scope 保持窄语义**：只有 `append(_:type:)` / `write` 打 stamp（与 main 一致），组件自带 identifier；类型文档里「stamps every appended atomic component」的错误表述已修正。`appending("", type:)` 的空串提前返回不再泄漏 scope 栈。
5. **`string` 热读保留锁**：唯一剩下的缓存仍需分片锁（main 的无锁读写是数据竞争，正是上一轮要修的）。实测 200 万次热读 29 ms vs main 20 ms——每次约 +4.5 ns，是正确性的价格。评审建议的「flat 态免锁快路径」会原样带回 main 的 race，未采纳。

### 取舍

- **composite 的展平从首次读取提前到 append 时。** 总工作量不变（`buildComponents()` 无论如何只会执行一次），改变的只是时机；副作用不纯的第三方 `buildComponents()` 会观察到调用时机变化。换来的是读取路径完全无副作用。
- **`compact()` / `compacted()` 删除**（原本就是 internal 且公开不可达）：存储永远是紧凑的，`frozen()` 仍是公开的终态出口。
- **`PlainAtomicSemanticComponent` 保留**：仍然免掉一次单元素数组分配；违约的后果从「粒度+内容双分叉」缩小为「内容分叉」（所有路径的元素数现在一致）。

## 影响面

- 公开 API 无删减；`SemanticString` 的可观察行为回到与 `main` 逐字节一致，仅第 3 条（零长原子过滤）是有意偏离，依赖「空原子占 `count`」或旧编码载荷含空原子的调用方受影响。
- 内部：`Storage` 字段全换（`isFlat` / `flatComponents` / `treeElements` / `cachedComponents` → `atoms` / `elementEndOffsets`），`SemanticStringElements` 表示改为 `contents` / `strings` 两种零拷贝形态，直接触达 `_storage` 的测试全部迁移。
- 性能：容器展平快于 main；流式追加零开销不变；`components` 读取从「锁 + 缓存」变为直读存储；40 万 token 场景「先 append 一个空组件再流式写入」的内存惩罚从 +24.7 MB 降到 +1.5 MB。

## 验证

- 346 项测试全绿；其中 13 项（`RedesignRegressionTests`）先于修复落地，9 项在旧实现上确认为红、修复后转绿。
- 136 项 golden 输出与 `main` 对照：唯一差异即上述有意偏离。
- `swift test --sanitize=thread --filter ConcurrencyTests`：17 项全绿无竞争。
- `arm64_32-apple-watchos6.0` 交叉编译通过（32 位 `Int` 陷入修复的编译级验证）。

## 迁移注意事项

- 若有代码依赖 `SemanticString { EmptyComponent() }.isEmpty == true`（上一版双态实现的短暂行为，未发版），改用 `count == 0`。
- 旧编码载荷若含零长组件，解码后该项消失（`string` 不变）；这是既有决策的收尾，不是新偏离。
- `AGENTS.md` 的存储章节已整体重写；`TwoStateStorage.md` 与 `StorageCorrectnessAndLockRework.md` 保留为历史记录，其中描述的双态机制已被本篇取代。
