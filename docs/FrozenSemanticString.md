# FrozenSemanticString：不可变终态形式设计记录

- **日期**: 2026-07-26
- **提交**: `6727d5f`（分支 `feature/flat-contents-storage`）
- **状态**: 已落地，全部验证通过
- **前置**: [TwoStateStorage.md](TwoStateStorage.md)（O1，双态存储）

## 动机

O1 之后，定稿 interface 的驻留形态是 `[AtomicComponent]`：每 token 40 字节
（string 16 + type 2 + padding + identifier 16）+ 超过 15 UTF-8 字节的 token
各占一次堆分配 + `cachedString` 可能再存一份全文。RuntimeViewer 的 interface
一旦生成就是纯只读的——为只读数据扛可变构建器的全部机制（CoW、缓存、锁）没有意义。

## 设计

`FrozenSemanticString`：构建（`SemanticString`）与只读（Frozen）在类型层面分离。

```
text: String                 全文 UTF-8，恰好一份
spans: [Span]                每 token 8 字节（length: UInt16, typeCode: UInt8, identifierIndex: UInt32）
identifierTable: [String]    identifier 内插表（1-based；0 = 无）
```

- **单向冻结**：`SemanticString.frozen()`；无 mutation API、不提供反向转换。
  「构建完再也不改」由类型系统保证，取代 O1 里 `compact()` 的运行时约定
  （`2dc9bcf` 起 `compact()` 已降为内部 API，`frozen()` 是唯一公开出口）。
  `frozen()` 直接复用已缓存的 `string` 作为 text arena，不再重新逐 token 拼接。
- **全 `let`** ⇒ 无条件 `Sendable`，无锁、无 `@unchecked`。
- Span 只存长度不存偏移，消费方顺序累加（渲染本来就是顺序遍历）。
- 超过 `UInt16.max` UTF-8 字节的 token 拆成相邻同类 span；只做拼接或按 run
  上色的消费者察觉不到差异。（第三轮修正：拆分边界从 Unicode scalar 提升为
  grapheme cluster，单个 cluster 自身超过 65535 字节时才退化为 scalar 边界，
  见 [ThirdReviewFixes.md](ThirdReviewFixes.md)。）
- `SemanticType` ↔ `UInt8` 映射**只增不改号**；未知 code（未来版本编出的）枚举时
  落到 `.other` 而非崩溃。
- **Codable 列式编码**（text + 四个同质数组），比 SemanticString 的
  逐-token-字典编码小一个数量级——远程（XPC/TCP）传 interface 直接受益。
  解码校验列数一致、长度覆盖全文、identifier 索引在表内、**每个 span 边界落在
  Unicode 标量边界上**（最后一项在 `2dc9bcf` 补齐：只校验字节覆盖量不足以拒绝把标量
  切成两半的载荷，而 String 的索引取整会把这种错位悄悄吸收掉，使后续所有 span 都切错）。

## 实测（RuntimeViewer 探针，AppKit + SwiftUI 全量打印，346 万 token）

| | 基线（改造前） | O1（双态+compact） | O2（Frozen） |
|---|---|---|---|
| 退出 footprint | 1.27 GB | 382 MB | **~285 MB（-78%）** |
| 峰值 RSS | 1.35 GB | 489 MB | **~400 MB** |
| 打印耗时 | 147 s | 139 s | 142 s（持平） |
| 语料输出 | — | 逐字节一致 | 逐字节一致* |

\* token 计数 +3：SwiftUI 中 3 个超 64 KB 的长 token 按设计拆分为相邻 span；
字节数、注释占比、行数完全一致。

实测 identifier 只出现在 8.4% 的 token 上、distinct 仅 6,338 个——内插表
不足 0.5 MB，而每 token 的 identifier 内联成本从 16 字节降到 4 字节索引。

## 消费端迁移（RuntimeViewer 侧）

- `RuntimeObjectInterface.interfaceString` 改为 `FrozenSemanticString`；
  init 仍接受 `SemanticString`，在存储边界冻结——生成端调用点零改动。
- 渲染（`attributedString(for:)`）迁到 `enumerateSpans` 遍历：全文直接取
  `text`（不再逐 token 拼接），UTF-16 range 按 span 累加，链接解析在遍历中完成。
- 纯文本消费者（导出、MCP、分享）用 `.string`，签名不变。

## 迁移注意

- 需要 `[AtomicComponent]` 兼容视图时用 `frozen.components`——会重建逐 token
  分配，仅限测试/兼容场景；热路径一律 `enumerateSpans`。
- 长 token 拆分意味着 `frozen.components` 与原 `components` 在超 64 KB token 上
  数量可能不同（内容拼接后等价）；做逐 token 对比的测试需注意。
- 编码格式与 `SemanticString` 的 Codable 不兼容（有意为之）；持久化/跨进程两端
  须同步升级。
