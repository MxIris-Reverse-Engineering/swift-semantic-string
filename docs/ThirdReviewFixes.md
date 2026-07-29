# 第三轮评审修正：扁平存储收尾与 Frozen 正确性

## 动机

扁平存储重设计（[FlatStorageRedesign.md](FlatStorageRedesign.md)）落地后的第三轮独立评审给出 15 项发现，全部经 main/PR 双二进制探针与源码核验属实。与前两轮不同，这一轮没有动摇存储设计本身——评审自带的 400 组随机差分确认库内构造路径与 main 逐字节一致——问题集中在三类：

1. **重设计的收尾疏漏**（4 项）：手工数组构造丢元素槽导致相等值 `isEmpty` 相反、`DeclarationBlock` 预留容量用了元素数、空原子过滤对第三方组件的容器渲染影响未见文档、builder 收集路径的性能回退被文档写成无条件更快。
2. **`FrozenSemanticString` 自身缺陷**（6 项，先于本轮存在）：`==` 混用规范化文本比较与字节长度比较破坏「冻结保相等」、unchecked init 违约三向只有一向 trap、超长 token 按标量切分劈开字形簇、解码器先物化全部列再校验、`isEmpty` 语义翻转未文档化、类型码碰撞边的守卫测试指认错误。
3. **加固与腐化**（5 项）：锁条带缺尺寸断言、CoW 路径的免锁写缺前提说明、守卫路径已被删除的死测试、元素切片的索引基准陷阱、写反的测试注释。

## 范围

- `Sources/Semantic/SemanticString.swift` — `init(components: [AtomicComponent])` 丢空原子时记录零长元素槽（`flatContents(droppingZeroLengthComponentsFrom:)`）；`makeUniqueForMutation()` 免锁写 `cachedString` 的可靠性论证写入注释。
- `Sources/Semantic/Components/Block.swift` — `DeclarationBlock` 预留容量改用 `body.totalComponentCount`。
- `Sources/Semantic/Frozen/FrozenSemanticString.swift` — `==` / `hash(into:)` 逐 span 比较/哈希**文本切片**（canonical，与 `text ==` 同一标准）而非字节长度；`enumerateSpans` 补齐覆盖不足与标量未对齐两个方向的 trap；`isEmpty` 的「渲染空」语义文档化。
- `Sources/Semantic/Frozen/FrozenSemanticString+Freezing.swift` — 超长 token 按**字形簇**边界切分，单簇超限时该簇退化为标量切分。
- `Sources/Semantic/Frozen/FrozenSemanticString+Codable.swift` — 解码顺序即校验顺序：先证 `spanLengths.count ≤ text.utf8.count`（每 span 至少 1 字节）并走完长度列全部校验，再物化其余三列。
- `Sources/Semantic/Storage/CacheLockStripes.swift` — `MemoryLayout<Primitive>.stride <= stride` 断言；Windows 条件编译统一为 `canImport(WinSDK)`。
- `Sources/Semantic/Storage/SemanticStringElements.swift` — `atoms(ofElementAt:)` 切片索引非零起的消费约束写入文档。
- 测试 — 新增 `ThirdReviewRegressionTests`（12 项，fail-first）；`ConcurrencyTests` 删除守卫路径已不存在的条带碰撞死锁测试；`ReviewFindingsRegressionTests.everySemanticType` 改用 `allCases`；多处陈旧注释修正。
- 文档 — AGENTS.md（builder 路径性能、类型码守卫指认、路径笔误、scope 不对称）、README（空原子对容器判空的影响、字形簇切分）、本篇。

## 关键设计与取舍

### 手工数组构造记零长元素槽（而非恢复保留空原子）

`append` 一个空 `AtomicComponent` 记一个零长元素，`init(components:)` 却把空原子连槽一起丢——于是 `components` 相同（`==`、hash 相同）的两个值 `isEmpty` 相反，经 `Set`/`Dictionary` 键去重后答案取决于谁先插入。修复方向选「补槽」而非「保留原子」：零长原子在一切路径被丢弃是上一轮拍板的唯一有意偏离（保证 `Codable` 往返幂等），零长**元素**照记则与 append 路径一致。无空原子的输入仍走 `elementEndOffsets == nil` 的 1:1 快路径，不付任何新代价。

### 容器判空看过滤后的展平：保留新行为，钉为有意偏离

第三方组件 `buildComponents()` 只返回一个空原子时，main 会为它渲染一整行空行/分隔符，而 `Keyword("")`（默认实现返回 `[]`）却被跳过——同一个「空白叶子」因实现细节而行为分叉。扁平存储把两者统一为「展平为空即为空」。恢复 main 行为需要容器知道「过滤前是否为空」，等于重新引入两套表示的分叉类，故保留新行为，README 写明，`ThirdReviewRegressionTests` 钉住六个容器的输出。**这是继零长原子过滤之后第二条（也是同根的）有意偏离。**

### Frozen `==` 的比较标准统一为 canonical

`text` 用 `String ==`（NFC/NFD 等价）而 span 用字节长度，等于一半 canonical 一半 byte-wise：两个 `==` 且同 hash 的 `SemanticString`（NFC "é" vs NFD "e"+组合符）冻结后 `!=`、hash 不同、`Set` 存两份。修复把逐 span 比较改为文本切片比较（`Substring ==`，同为 canonical），hash 同步改为哈希切片。传递性保持（canonical 等价是等价关系，span 计数守卫保证配对成立）；成本仍 O(文本长度)。快路径（同表同 spans 直接判等）保留。

### unchecked init 的违约三向全部变响

文档一直承诺「违反不变量在 `enumerateSpans` 大声失败」，实际只有覆盖超出会 trap：覆盖不足静默截断（`"ab"` 只走出 `["a"]`），标量未对齐静默产出零长组件（违反全库不变量）。补两个 `precondition` 后三向全 trap，文档承诺成真；`isEmpty == true && string == "abc"` 的幻影值也随之在首次遍历暴露。代价是每 span 一次索引形态检查，相对 body 调用可忽略。

### 超长 token 按字形簇切分

按标量切分的 span 拼接回原文没问题，但逐 span 的消费者（着色、选区、`components`）拿到的是残缺半簇——ZWJ emoji 被劈成「男人+悬空连接符」。改按 `Character` 边界切分；单个字形簇本身超过 65535 字节（病态连接符链）时无法装进任何 span，该簇退化为标量切分并在文档注明。字形簇边界必为标量边界，解码器的对齐校验无需改动。

### 解码顺序即校验顺序

敌意载荷可以用几 MB 的 JSON 声明五百万个 span，旧实现先物化五列（约 35 MB）再跑第一条校验。重排为：`text` → `spanLengths` → 数量上界（每 span ≥1 字节 ⟹ `count ≤ text.utf8.count`）→ 零长扫描 + 覆盖和 + 对齐走查 → 才解码其余三列。`spanLengths` 自身的物化省不掉（JSONDecoder 先整体解析载荷），但其余列的放大被上界封死。合法载荷的行为与错误种类不变，仅双重畸形载荷的报错顺序改变。

### 未修（有意）

- **builder 收集路径慢于 main 约 1.4–1.7×**：急切展平在 builder 收集时拷一次、容器渲染再拷一次，main 靠保留装箱元素只拷一次。消除它就是把「保留结构」请回来——正是上一轮拆掉的东西。作为交换，流式 append 快 2.7×、`+=` 快 4×、`[SemanticString]` 条目容器快于 main。文档从「无条件更快」改为如实记账（本篇「验证」节有数字）。
- **`makeUniqueForMutation()` 的免锁写不加锁**：`isKnownUniquelyReferenced` 证明唯一所有权后免锁清缓存是可靠的（`Storage` 只能经 `SemanticString` 的强引用到达；对同一值的并发读写在 struct 层已是 race）。加锁会给最热的 append 路径每次多付一个锁往返。前提条件已写入注释：任何让 `Storage` 可绕过强引用到达的未来改动（intern 表、`Unmanaged` 快路径、`weak` 缓存）必须把这行写挪进条带锁。
- **类型码写死的碰撞边（17 挨着 18）不重排**：重排就是破坏已持久化载荷。守卫是 `FrozenSemanticStringTests.typeCodeBijection`（基于 `allCases`，断言两两唯一 + 总数恰为 22）；错误指认它处的两处文档已修正，`ReviewFindingsRegressionTests` 的枚举也改为 `allCases`。

## 影响面

- 公开行为变化仅两处，均为收尾对齐：手工数组构造含空原子时 `isEmpty` 与 append 路径一致（原先为 `true` 的场景现为 `false`）；`FrozenSemanticString` 的 `==`/`hash` 对 NFC/NFD 等价内容判等（原先不等）。依赖旧行为的调用方——按字节区分规范化形态的去重逻辑——应改比 `spans.map(\.length)` 或编码后的字节。
- unchecked init 构造的畸形 `FrozenSemanticString` 从静默错误变为 trap；`Codable` 解码路径不受影响（本就拒绝）。
- 超长 token 的 span 边界位置改变（簇对齐），span **数量**在极端形态下可能略有不同；拼接结果与解码兼容性不变。
- 其余全部为内部注释、文档与测试变更。

## 验证

- 全量 357 项测试绿（50→51 套件）；新增 `ThirdReviewRegressionTests` 12 项先行落地，其中 6 项在修复前确认为红（F3 两项、F2、F6、F5 两项——后两项经 Swift Testing exit test 证明旧代码静默正常退出）、6 项为行为钉（F1 容器输出、F7 拒绝、F9 翻转、1:1 保持、纯标量切分、类型区分）。
- `DeclarationBlock` 预留容量修复无可观测行为差异（纯重分配次数），无 repro 测试，属陈述性修复。
- 第三轮探针数字（`-O`，main 与 PR 双二进制）：
  - F1 容器输出差异全部复现并钉住（`"-k"→"k"`、`"(, k)"→"(k)"`、`"struct {\n}"→"struct {}"` 等六形态）。
  - F4 builder 收集：纯收集 71.8→99.1 ms（1.38×）、MemberList 75.9→127.9 ms（1.68×）、Joined 85.7→136.6 ms（1.59×）（200 次 × 2000 行）。
  - F2/F5/F6/F9 的修复前形态逐一实测（spans `[2]` vs `[3]` 不等、`"ab"`→`["a"]` 静默、4001 字符 vs 4000、`isEmpty` 翻转）。
- TSan `ConcurrencyTests` 全绿；arm64_32 watchOS 交叉编译通过。

## 迁移注意事项

- 若有代码依赖「`SemanticString(components:)` 传入全空原子数组 ⇒ `isEmpty == true`」，其语义现在与逐个 append 一致（`false`，零长元素占位）；判「渲染为空」请用 `count == 0` 或 `string.isEmpty`。
- 若有代码依赖 frozen 值按字节区分 NFC/NFD，改比 `spans` 或编码字节。
- 通过 unchecked `init(text:spans:identifierTable:)` 构造且违反不变量的值，首次 `enumerateSpans` / `components` / `==` 遍历会 trap——这是文档一直承诺的行为，修复只是兑现。
