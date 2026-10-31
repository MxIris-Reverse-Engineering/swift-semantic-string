# 注释结构区域：标出一段文字是什么、它的每一段是什么

- **状态**：实现中（分支 `feature/annotation-regions`）
- **日期**：2026-10-31
- **使用方**：MachOSwiftSection、MachOObjCSection 的 `marksCommentStructure`；RuntimeViewer 的 SourceEditor 注释标签（它的提案 `draft-source-editor-comment-annotations`）

## 动机

RuntimeViewer 用 Xcode 的 SourceEditor 显示 interface 时，要把生成器输出的注释画成标签：藏起 `// `、`/* */` 和标点，标签名与数值分色，字段偏移树做成可折叠的大纲，枚举布局按 case 折叠。注释的结构由生成器在打印时给出，RuntimeViewer 不解析注释文本——用户能用 Transformer 模板改写注释的措辞，从文字认不出结构。

所以打印器要能在输出时标出：这段文字是哪种注释（kind），它的每一段扮演什么角色（marker、label、value……），注释之间怎么嵌套（字段偏移树的节点套节点）。本库提供承载这些标记的组件，以及冻结后读回标记的表。与可见性区域、定义区域一样，标记不改文本。

## 范围

新增四样，全部在 `Semantic` 里：

- `AnnotationRegion`：包住一段内容，标出它的 kind（`AnnotationRegion.Kind`）。可以嵌套，同 kind 也可以。
- `AnnotationSegment`：包住一段内容，标出它在所在区域里的角色（`AnnotationSegment.Role`）。内容可以是任意原子——不同语义类型、带 identifier、带可见性或定义区域的标记都行；只是段是叶子，里面不能再有段或注释区域。
- `AnnotatedAtom`：把「不打标记时的一个原子」拆成几片来打印，片可以分别放进段和子区域；分离时这几片并回一个原子。
- `FrozenSemanticString.separatingAnnotationRegions()`：返回去掉标记、并回拆开的原子的文本，以及 `AnnotationRegionTable`——每个区域的 kind、UTF-8 范围、深度、直接外层区域；每个段的角色、UTF-8 范围、所在区域。

```swift
AnnotationRegion(.memberAddress) {
    AnnotatedAtom(type: .comment) {
        AnnotationSegment(.marker) { "// " }
        AnnotationSegment(.label) { "Address" }
        AnnotationSegment(.separator) { ": " }
        AnnotationSegment(.value) { "0x135DC" }
    }
}
// 冻结后 separatingAnnotationRegions()：
//   text：与 Comment("Address: 0x135DC") 冻结的结果相等，一个 span
//   annotations.regions：memberAddress，UTF-8 范围 0 ..< 19
//   annotations.segments：marker 0 ..< 3、label 3 ..< 10、separator 10 ..< 12、value 12 ..< 19
```

本库给出两个生成器共用的常量：角色 `marker`、`label`、`qualifier`、`separator`、`key`、`value`、`name`、`type`、`treePrefix`、`text`，kind `note`。生成器专有的 kind（`memberAddress`、`impAddress`……）在各自的库里扩展 `AnnotationRegion.Kind`。

三个组件的内容为空时什么也不记，和本库其他组件一样。

不改动：`SemanticString` 的存储、`frozen()`、`FrozenSemanticString` 的存储布局与 `Codable` 格式，可见性区域与定义区域的组件和分离、投影、`content(ofDefinitionRegion:)`、`removingIndentation(levels:)`，以及所有容器。不打标记的调用方看不到任何差别。

未经询问采用的假设：

- 区域不带属性。三方第一版都不用；以后要加是纯增量（构造器加一个带默认值的参数，表里加一个字段）。
- `AnnotatedAtom` 一并做，理由见「分离后与不打标记时逐个相等」。生成器可以不用它，那样分离结果只做到逐字节相等。
- 名字用 Annotation 而不用 Comment：组件本身不限于注释。
- 不做 `OutputTransformer` 的模板分段（一次扫描模板、分出字面文字与代入值，供生成器在自定义模板下标出 value 段）。评估过，三方第一版都不用：自定义模板下整条注释记一个 text 段，RuntimeViewer 已接受；MachOObjCSection 的渲染层只拿到 `(Int) -> String` 的闭包，按第一个 `: ` 切段。以后要按占位符拆数值再另提。

## 关键设计与取舍

### 标记放在 identifier 上，排在可见性与定义的编码里面

和另外两种区域一样，标记写在原子的 `identifier` 里，不插入原子，文本、语义类型、元素结构都不变。编码放在可见性标记与定义区域编码之后、原 identifier 之前：`␁<条件>␁␆<身份>␆␐<注释结构>␐<原 identifier>`（控制字符取 U+0010 起，另外两种区域用的是 U+0001–U+0007）。容器和 `separatingVisibilityRegions()` 只看第一个字符；`separatingDefinitionRegions()` 与 `content(ofDefinitionRegion:)` 把注释部分当作原 identifier 的一部分原样保留——三者一行都不用改。三种区域按任意顺序嵌套得到相同的原子，三种分离按任意顺序做结果相同。

### 相邻的同 kind 区域靠「锚点」分开

DefinitionRegion 把紧挨着的同身份区域读成一个，这里不行：连续的地址注释、连续的逐字节行就是紧挨着的同 kind 区域。所以每个原子上，每层区域（段和 `AnnotatedAtom` 也一样）除了 kind 还记一个阶段：

- **锚点**：区域里第一个同时满足两点的原子——含有空格以外的字节；区域里每个原子都带着它身上的全部可见性条件（它没有条件也算）。
- **前导**：锚点之前的原子。
- **后续**：锚点之后的原子。
- **无锚**：找不到这样的原子时，区域的全部原子。

分离时按 span 顺序读：前导和锚点开始一个新区域，除非当前同 kind 的区域还停在前导阶段；后续接上当前同 kind 的区域；无锚只接无锚的区域。超过 65535 字节的原子冻结时会切成几个 span，这种原子另记它的非空格字节数，分离据此把同一个原子的后几片，和紧接着出现、标记相同的新锚点分开。

阶段只取决于区域自己的内容，所以同一段注释内联打印和单独打印得到相同的标记。改动带标记字符串的操作也都动不了锚点：

- `removingIndentation(levels:)` 只删行首的空格。锚点含有空格以外的字节，删不掉；前导、后续被删掉不影响边界。
- 投影按条件整段删掉原子。区域里只要还有原子可见，锚点就可见。所以「全量打印、投影到某组选项、再分离」与「按这组选项打印、再分离」得到相同的表。
- `content(ofDefinitionRegion:)` 不改原子。

否决的做法：

- 按位置递增的实例编号（全局计数器，或父区域里的序号）：同一段注释内联打印和单独打印拿到不同编号，切出、去缩进后的嵌套定义就不再等于它的单独打印；全局计数器还需要原子操作或锁。
- 只在区域的第一个原子上记「从这里开始」：第一个原子是缩进时会被去缩进删掉，落在可见性区域里时会被投影删掉，剩下的部分就悄悄并进前一个同 kind 区域。
- 把段的范围编码进一个原子的 identifier、不拆原子：区域就有了两套编码（跨原子的与原子内部的）；而且多行原子（枚举逐 case 的块）去缩进时内部偏移整体移动，`removingIndentation` 得懂这套编码并改写它。

### 区域从第一个原子到最后一个原子

区域保留内容的元素结构。有几个元素的区域直接放进 `MemberList` 这类容器时，容器在它的元素之间打的换行和缩进不属于这个区域。读回时一个区域从它的第一个原子到最后一个原子（首尾的空白见下一节），中间的这些装饰算在范围内：不属于它的原子不会让它结束，同一层出现另一个区域才会。

### 区域的范围不含首尾的空白

表里报出的区域范围，去掉首尾那些不属于任何段、又只含空格、制表符或换行的原子（`Indent`、`BreakLine`，以及多行块里的缩进片与换行片）；段的范围从不裁。只含这种原子的区域不进表，它里面的区域也一样。

这样生成器能把现成的「缩进 + 注释 + 换行」整个包进区域，不必为了对齐区域边界重排原子。字段偏移树的根区域就需要这一点：根那一行的换行必须留在根区域里、树的可见性区域外面（挪进去，那几个换行字节在投影前的标记就与不打注释标记时不同），于是树被投影掉以后根区域以换行结尾，裁掉后正好是根那一行。

一个原子算不算空白只看它自己的字节。去缩进只删空格、投影整段删原子，都改变不了一个原子是不是只含空白，所以裁剪不影响前面两条契约。

### 分离后与不打标记时逐个相等

生成器为了标出段，要把今天的一个原子（`// Address: 0x135DC`，枚举逐 case 的多行块）拆成几个原子，而 `frozen()` 一个原子出一个 span。`AnnotatedAtom(type:identifier:)` 声明「这几片在不打标记时是一个原子」：片的文本拼起来就是那个原子，类型和 identifier 用 `AnnotatedAtom` 给的；分离时同一个 `AnnotatedAtom` 的片并回一个 span，超过 65535 字节的按 `frozen()` 的规则重新切。片的归属同样用锚点记，所以第一片是缩进、被去缩进删空时，后面的片不会并进前面无关的 span。

RuntimeViewer 已把契约放宽为「分离后每个字节的文本、语义类型与 identifier 相同，span 边界可以不同」，不用 `AnnotatedAtom` 也满足。仍然提供它，因为「分离出的就是不打标记时的打印」是另外两种区域都守住的性质：生成器的契约测试可以直接比冻结串，RuntimeViewer 拿到的 span 数也与今天相同。代价是一个组件，和分离时的一次合并。

构造 `AnnotatedAtom` 时，它的内容里不能有带自己 identifier 的原子，不能有可见性或定义区域的标记（一个原子只有一个 identifier、一个可见性），也不能再有 `AnnotatedAtom`；违反时 trap。构造之后在外面整体套上的标记不受此限：外层的 `VisibilityRegion`、`markAtoms(from:visibleUnder:)`、`DefinitionRegion` 给每一片加的是同一个标记，分离时照常并回一个 span。

### kind 与角色是开放的常量集

`AnnotationRegion.Kind` 与 `AnnotationSegment.Role` 是包一个字符串的 struct，用静态成员给常量，形状同 `Notification.Name`。两个生成器共用的放在本库，免得 RuntimeViewer 同时 import 两边时遇到两个同名的静态成员；专有的在各自的库里扩展。本库不解释这些字符串。它们不能为空、不能含控制字符（编码保留了它们），违反时 trap，与另外两种区域一致。

### 已知限制

- 两个紧挨着的同 kind 无锚区域读回为一个。无锚只出现在区域全是空格，或者每个含字的原子都另带条件的时候（比如只由两种互斥写法组成的值段）。
- 包住定义区域的注释区域，会被 `content(ofDefinitionRegion:)` 一起切开，切出的部分读回为一个区域。注释都在定义里面，生成器不这样嵌套。
- 分离之前，`components`、`count`、`trimmingWhitespace()` 这类按原子的操作看到的是 `AnnotatedAtom` 拆开的片。

## 影响面

- 纯增量 API，全部 `@inlinable`、`Sendable`，不引入任何依赖。
- 没打标记时：输出、行为和开销都不变，容器与现有的三种操作（两种分离、投影）没有改动。
- 打标记的开销在调用方：每个被包住的原子每层多一次字符串拼接；`AnnotatedAtom` 只在打标记时把一个原子拆成几个。

## 迁移注意事项

无需迁移。编码是本库内部格式，调用方只通过 `AnnotationRegionTable` 读，不应自己解析 `identifier`。

## 验证（计划）

- `AnnotationRegionTests`：编码与嵌套顺序无关、可见性与定义编码留在外层；区域不改文本、保留元素结构；分离还原不打标记的打印（用 `AnnotatedAtom` 时冻结串逐个相等，含超过 65535 字节的原子）；紧挨着的同 kind、同角色区域读回为几个，含单原子、内容完全相同的情形；同 kind 嵌套的深度与外层索引；区域跨过容器装饰；首尾空白的裁剪（段不裁、只含空白的区域不进表、投影掉树后的字段偏移根区域）；三种分离六种顺序结果相同；嵌套定义切出、去缩进后的三张表与单独打印相同，含第一片是缩进的情形；随机条件下「投影再分离」与「按选项打印再分离」相同；超长锚点的切片；各前提条件的 trap 用退出测试；已知限制钉成测试；README 示例原样跑一遍。
- 全部测试通过；watchOS `arm64_32` 编译通过。

## 落地步骤

每一步单独构建通过、测试通过后提交。

1. **编码与三个组件**：`AnnotationRegion`（含 `Kind`）、`AnnotationSegment`（含 `Role`）、`AnnotatedAtom`，以及阶段的计算与编码。测试覆盖编码、三种区域的嵌套顺序、元素结构、各前提条件的 trap。（已完成）
2. **分离与表**：`AnnotationRegionTable` 与 `separatingAnnotationRegions()`——边界判定、片组并回与重切、首尾空白裁剪。测试覆盖相邻实例、嵌套、容器装饰、裁剪、三种分离的顺序、切出与去缩进、投影、超长原子、已知限制。（已完成）
3. **文档与收尾**：README 新增一节；AGENTS.md 的架构说明、identifier 编码规则与测试文件清单；本文的状态与验证结果；watchOS `arm64_32` 编译检查。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-31 | 建为草案 | RuntimeViewer 的 SourceEditor 注释标签需要生成器在打印时给出注释结构；本库、两个生成器、RuntimeViewer 各由一个会话负责，本库先出 API。 |
| 2026-10-31 | 分离契约以「每个字节的文本、语义类型与 identifier 相同」为底线，另提供 `AnnotatedAtom` 做到冻结串逐个相等 | RuntimeViewer 放宽了契约；MachOSwiftSection 希望拆开的原子能并回，MachOObjCSection 要求开关关着时原子与今天相同。可选的 `AnnotatedAtom` 同时满足三方，并保住「分离出的就是不打标记时的打印」。 |
| 2026-10-31 | 实例边界用锚点记录，不用编号 | MachOSwiftSection 要求标记与位置无关（同一条注释内联打印与单独打印相同），并要求「全量打印投影后再分离」与「按选项打印再分离」结果相同；锚点经得起去缩进、投影和切出。 |
| 2026-10-31 | 表里的区域范围裁掉首尾空白，段不裁 | MachOSwiftSection 提出：字段偏移根区域必须包住根那一行的换行，裁剪让生成器不必为对齐区域边界重排原子。 |
| 2026-10-31 | 不做区域属性，不做 `OutputTransformer` 的模板分段 | 三方第一版都不用；以后要加都是纯增量。 |
| 2026-10-31 | 用户批准，开始实现 | — |
