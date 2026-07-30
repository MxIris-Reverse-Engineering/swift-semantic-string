# 第五轮评审修正：isEmpty 语义收敛、Frozen 相等性收口与测试基础设施诚实化

## 动机

第五轮评审（15 处发现，全部经独立环境逐条复现核实，无误报）暴露出三类问题：

1. **「不存储零长组件」决定的连带影响没有收干净。** 第三轮为手工数组补的「零长元素槽」方案让 `isEmpty`（数元素槽）与 `count` / `first` / `==` / `hash` / `Codable`（全部数组件）脱钩：`==` 相等的两个值对 `isEmpty` 给出相反答案、`!isEmpty` 不再蕴含 `first != nil`（先判空再强解包会崩）、`Codable` 往返把 `isEmpty` 翻面，而 `map` 把组件映射为空串后 `count`、下标、`contains(type:)` 全部给出错误答案且 `.string` 一字不变。
2. **`FrozenSemanticString` 的 `==` / `hash` 对边角输入失守。** `==` 快路径只比 span 向量不比切片，被 Unicode 组合符的 canonical 重排（U+0307/U+0323 这类不同 combining class 的标记）击穿：正常 `frozen()` 产出的两个内容不同的快照被判相等，Hashable 契约与传递性双双破坏。`hash` 与 `==` 慢路径重复了 `enumerateSpans` 的 UTF-8 索引推进却没有它的 precondition：越界值死在裸标准库消息里，错位值被静默按舍入后的切片处理。
3. **测试与文档基础设施不可信。** 一条逐字节比较两次 `JSONEncoder` 输出的断言没设 `.sortedKeys`，42% 的运行随机变红；AGENTS.md 声称的「分配数守卫」不存在（1687 行全是功能断言）；`typeCodeBijection` 的「基于 allCases」声明对顶层 case 不成立；README 声称的「identifier index 越界校验」在最后一个 commit 里被有意删除而 README 未跟改；解码器注释声称的资源上界实测防不住（38 MB 恶意 payload 将 RSS 推至约 1 GB，且对照实验证明放大主体是 `JSONDecoder` 解析本身，重排 `init(from:)` 内部校验顺序无济于事）。

## 范围

- `SemanticString.isEmpty` 改为组件计数（`Sources/Semantic/SemanticString.swift`），元素槽降级为纯容器排版簿记；`ForEach` 随之与 `Joined` / `Group` 一致地跳过空项（全库容器判空统一）。
- `appending(_:type:)` 恢复空串 early return（`+Composition.swift`），开放的 identifier scope 不再被无操作的 appending 清空。
- `FrozenSemanticString`：`==` 快路径加字节相等门槛；`hash(into:)` 重写为不走文本（text + span 数 + 逐 span 归一 type / identifier）；`==` 慢路径与 `enumerateSpans` 共用带类型化诊断的边界推进 helper（`spanUpperBound(after:spanLength:)`），越界方向也换上具名消息。
- `append(_ component: some PlainAtomicSemanticComponent)` 增加 debug 断言守卫 `buildComponents()` 承诺；存在类型 append 漏斗为 `SemanticString` 子元素增加批量拷贝快路径。
- 测试：`FourthReviewRegressionTests` 的逐字节比较补 `.sortedKeys`；`typeCodeBijection` 增加编译期穷尽性哨兵 `assertCaseListIsExhaustive`；新增 `FifthReviewRegressionTests`（11 项，含三个 exit test）；四处钉住旧语义的 pin 随语义决定重写。
- 文档：`Span.length` / README / AGENTS.md 的「span 不切分 Character」承诺限定到单 token 内部（全局保证仅为 scalar 对齐）；README 解码校验清单删去已不存在的 identifier 越界校验并补「不可信字节须在解码器之前限制大小」；AGENTS.md 的「分配数守卫」假陈述、`cacheLockStripeStride` 错误符号名、appending scope 语义、isEmpty 语义各处同步改写。

## 关键设计与取舍

- **`isEmpty` 采用 `main` 的文档语义「has no components」**（用户决定）。修复后 `isEmpty` ⟺ `count == 0` ⟺ `first == nil` ⟺ `string.isEmpty`，且与 `==` / `hash` / `Codable` 的比较基准一致——「相等值在一切空判上一致」从声称变为构造性成立。代价是与 `main` 的一处行为分歧：append 一个展平为空的组件（`EmptyComponent`、nil optional）在 `main` 上使 `isEmpty` 为 false，现在为 true。元素槽仍然记录（容器行语义需要），但不再被任何公开度量观察。
- **`==` 快路径的门槛是文本字节相等，而不是删除快路径。** 字节相同 + span 向量相同 + 表相同 ⇒ 逐 span 切片必然逐字节相同，捷径与解析环恒一致；NFC/NFD 对仍走解析环保持相等。`hash` 不再哈希切片，改为 text（String 哈希本身 canonical 一致）+ span 数 + 逐 span 归一字段：相等值仍必然同 hash，代价是 canonical 重排对这类不等值成为合法哈希碰撞（由 `==` 区分）。收益实测：50 万 span 值 `hashValue` 23.6 ms → 8.9 ms（-62%），Set 插入 51.5 ms → 17.9 ms（-65%），且 `hash` 对任何畸形值不再可能 trap。
- **畸形值的失败模式统一为「读时带名 trap，hash 安静」。** `enumerateSpans`、`components`、`==` 慢路径共用同一 helper，三个违约方向（越界 / 覆盖不足 / 切分标量）全部以具名诊断 trap；每 span 的 precondition **保留**而非降为 `assert`——它是 release 下唯一挡住 unchecked init 坏值的守卫，本轮恰好证明这类值能一路安静走到读取点。
- **两个微优化实测负收益，回退并留注释。** 存储 stripe 指针（省每次 `.string` 读的地址混淆）与存在类型 plain-leaf 转换（省一元素数组分配）都跑输原实现（协议转换比小数组分配更贵；多一个依赖加载比几条 ALU 混淆更贵），按测量结果回退，代码内注明原因防止重试。builder 装配路径慢于 `main` 的回归是「每层 eager 展平」的架构代价（换来的是读取路径与流式 append 的收益），维持第三轮的如实记账不变；缓存命中读取比 `main` 慢的部分是锁的代价（`main` 的无锁缓存是数据竞争），AGENTS.md 已有「不要加无锁快路径」的既定结论。
- **解码器的「资源上界」注释改为实话。** 对照实验（同一 38 MB 恶意 payload，仅解码 `text` 字段的消费者）显示峰值 RSS 同样接近 1 GB——放大主体是 `JSONDecoder` 对整个文档的解析，发生在 `init(from:)` 任何校验之前。校验顺序界定的只是本初始化器**构建**的 `[Span]`，防护职责（对 payload 字节数设上限）归调用方且必须在解码器之前，注释与 README 均已改为这个表述。

## 影响面

- `isEmpty` 的行为变更影响所有以元素槽语义依赖它的调用方（已知只有 `ForEach` 判空与四处测试 pin，均已随改）。`ForEach` 输出对空项从 `"a, , b"` 变为 `"a, b"`，与 `Joined` / `Group` 一致，是继「零长组件不存储」之后的第二处有意偏离 `main`。
- `appending("", ...)` 恢复返回 `self`（scope 保留），使用流式 identifier scope 的写入方不再丢引用元数据。
- `FrozenSemanticString` 的 `==` 对 canonical 重排对从误判相等改为正确不等；依赖旧误判的调用方（不应存在）会观察到变化。畸形值的 `hashValue` / `Set` 插入从裸 stdlib 崩溃变为安静成功，trap 转移到内容读取点。
- 42% 随机红的测试恢复稳定（复测 10/10 通过）；违约的 `PlainAtomicSemanticComponent` conformance 现在在 debug 首次流式 append 即断言失败。

## 迁移注意事项

- 判断「这个值渲染出来是不是空」用 `isEmpty` 即可（与 `string.isEmpty` 恒等且 O(1)）；不再存在「占槽但无内容」的可观察状态。
- `map` 把组件映射为空串会**删除**该组件（索引前移），需要占位请映射为占位符而非 `""`；与源数组按位置配对前先自行过滤空串。
- 消费 `FrozenSemanticString` span 需要字形簇对齐时必须自行合并相邻 span——跨 token 边界从不保证簇对齐（文档已改为实话）。
- 从不可信通道解码 `FrozenSemanticString`（或任何 Codable 类型）前，先限制 payload 字节数；`init(from:)` 的校验管不住解码器本身的内存放大。
