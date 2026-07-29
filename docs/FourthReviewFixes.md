# 第四轮评审修正：Frozen 的 Codable 幂等与相等归一

## 动机

第四轮独立评审在已与 `main` 逐字节对齐的 PR 上，未在存储/容器/并发任一角度找到真实 bug，但钉出两处 `FrozenSemanticString` 上真实、触发面窄的一致性缺陷。两者同源——同一个字段，**读取路径**当它是「未知/越界 → 优雅降级到默认值」，另一条代码路径却当它是原始存储字节：

1. **Codable 往返不幂等**：unchecked init 明确承诺越界 `identifierIndex` 「resolves to nil」，这是一个可用值（`identifier(at:)` 返回 nil、`enumerateSpans` 正常遍历），编码器也会把它写出——但解码器却把它当畸形载荷抛错。于是一个类型自己能构造、能编码的值，喂回自己的解码器却被拒收。
2. **相等/哈希比较原始 `typeCode`**：`enumerateSpans`、`components`、渲染全部把未知 `typeCode` 归一为 `.other`（前向兼容，来自更新版编码器的载荷必须可读），但 `==`（逐 span）与 `hash(into:)` 却比较/组合存储的原始字节。结果：一个携带未知码、一个携带 `.other` 自己的码——两者被**每一个读者**渲染成完全相同的内容，却判不相等、hash 不同，`Set`/`Dictionary` 查找互相落空。这与 `==` 方法自述的「compares rendered content, not storage layout」直接矛盾（它对 identifier 走 `identifier(at:)` 归一、对 text 走 canonical 比较，唯独 typeCode 用原始值）。

## 范围

- `Sources/Semantic/Frozen/FrozenSemanticString+Codable.swift` —— 解码器不再拒收越界 `identifierIndex`，原样保留（读取时 `identifier(at:)` 自行归 nil）。删去那段 `Int(exactly:)` + 范围校验循环；解码器 header 文档改为「只拒绝会 trap 读者的结构性畸形（覆盖、对齐、列数），未知 typeCode 与越界 index 一律降级保留」。
- `Sources/Semantic/Frozen/FrozenSemanticString.swift` —— `==` 逐 span 比较 `SemanticType(frozenTypeCode:) ?? .other` 而非原始 `typeCode`；`hash(into:)` 同步组合归一后的类型；unchecked init 与 `==` 的文档补齐 typeCode 归一的说明。
- 测试 —— 新增 `FourthReviewRegressionTests`（2 项，fail-first）；`FrozenSemanticStringTests.decodingValidation` 里「越界 index 必须抛错」的旧断言翻转为说明性注释（它锁死的正是缺陷 ①）。
- 文档 —— AGENTS.md（测试清单、类型码归一的读者范围）、README 索引、本篇。

## 关键设计与取舍

### 缺陷 ①：解码「都降级为 nil」，而非「都拒收」

修法有两个方向：让解码器**降级**（接受越界 index，读取时归 nil），或让 unchecked init **也拒收**（构造期就消除越界 index）。选前者，理由有三：

- **对称性**：解码器**本就保留**未知 `typeCode`（`RedesignRegressionTests.unknownFrozenTypeCodeDecodesToOther` 钉住「decoded.spans[0].typeCode == 250」）。越界 `identifierIndex` 是它的精确类比——同样「未知/越界 → 读取时归一」。让二者走同一策略，解码器的契约才自洽：**只拒绝会 trap 读者的结构性畸形**（覆盖不足、标量未对齐、列数不符、零长 span），对读者能安全降级的字段一律放行。
- **可行性**：unchecked init 是 `@inlinable`、非 throwing、契约上「调用方负责不变量」的廉价构造器。让它「拒收」只能改成构造期归零，需要对每个 span 扫描 table（O(spans)），违背其「不检查」的设计初衷。
- **幂等强度**：原样保留使 `decode(encode(x))` 与 `x` **逐字节**相同（新回归测试断言再编码得到同一 payload），比归零更强。而且原样保留的越界 index 经该类型自己的 `==` 归一后与归零值仍判等，等价语义不受损。

删掉校验循环后不再有 `Int(identifierIndex)` 转换，故此前那句「用 `Int(exactly:)` 防 32 位 trap」的注释一并移除——读取期的 `identifier(at:)` 仍用 `Int(exactly:)`，安全性不变。解码顺序/DoS 上界（第三轮引入，先证长度列再物化其余列）不受影响：被删的循环在其余列**之后**。

### 缺陷 ②：相等/哈希比较归一后的类型

`==` 逐 span 的守卫从 `leftSpan.typeCode == rightSpan.typeCode` 改为 `(SemanticType(frozenTypeCode: leftSpan.typeCode) ?? .other) == (SemanticType(frozenTypeCode: rightSpan.typeCode) ?? .other)`；`hash` 从 `combine(span.typeCode)` 改为 `combine(SemanticType(frozenTypeCode:) ?? .other)`。

- **传递性保持**：归一是类型码的确定性函数 `f(code)`，「resolved type 相等」是一个真正的等价关系；与既有的 canonical 文本相等、identifier 归一相等取合取，整体仍是等价关系。
- **hash 与 == 一致**：`==` 为真 ⟹ 每 span 的 resolved type 相同 ⟹ hash 组合相同的 `.other`。
- **快路径保留**：`if lhs.identifierTable == rhs.identifierTable, lhs.spans == rhs.spans { return true }`（同表同原始 spans 直接判等）是**充分条件**，原始 span 相等 ⟹ resolved type 相等，从不返回错误的「不等」，故保持不变。

## 影响面

- 公开行为变化两处，均为收尾对齐：
  1. `FrozenSemanticString` 的 Codable 解码**接受**越界 `identifierIndex`（原先抛 `DecodingError`），原样保留、读取归 nil——与 unchecked init 承诺一致，也让类型不再拒收自己编码器的产物。
  2. `==`/`hash` 对携带**未知 typeCode**（更新版编码器写出）与携带 `.other` 码的两个渲染相同的快照判等（原先不等、hash 不同）。
- 依赖旧行为的调用方——把越界 index 载荷当「必然解码失败」，或按原始 `typeCode` 字节区分两个都渲染为 `.other` 的快照——需改用结构性校验或比较 `spans.map(\.length)` / 编码字节。此类依赖预期极少（越界 index 与未知码都只来自未受检构造或跨版本 payload）。
- 其余为内部注释、文档与测试变更。合法、in-range、已知码的载荷行为完全不变。

## 迁移注意事项

- 若有代码依赖「越界 `identifierIndex` 的 frozen 载荷解码抛错」作为拒绝手段，改为在自己的边界上做范围校验——该类型现在把越界 index 视作前向兼容的可降级值，而非畸形。
- 若有代码依赖 frozen 值按**原始 `typeCode` 字节**区分两个都渲染为 `.other` 的快照，改比 `spans.map(\.typeCode)`；类型自身的 `==`/`hash` 现在按 resolved 语义判等。
- 通过合法路径（`frozen()`、in-range 值）产生的值不受任何影响。

## 验证

- 全量 **359 项测试绿**（原 357 + `FourthReviewRegressionTests` 2 项）。两条回归测试均先行确认为红：缺陷 ① 解码抛 `Identifier index 5 exceeds table of 0`；缺陷 ② `typeCode 99` 与 `7` 判不等、hashValue 不同、`Set([A]).contains(B)` 为 false。修复后转绿。
- 被翻转的 `FrozenSemanticStringTests.decodingValidation` 越界 index 断言，其正向行为（解码成功 + 读取归 nil + 逐字节再编码幂等）由 `FourthReviewRegressionTests.codableRoundTripAcceptsOutOfRangeIdentifierIndex` 覆盖。
- arm64_32 watchOS 交叉编译通过（`swiftc -target arm64_32-apple-watchos6.0` 代码生成，exit 0）；本轮改动仅删循环 + 换纯枚举映射比较，无指针宽度敏感算术。
