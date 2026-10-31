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
- 同一个 `AnnotatedAtom` 的片若在构造之后被标成不同的样子——`markAtoms(from:visibleUnder:)` 的起点落在两片之间——分离只把标记一致的相邻片并回，span 会比不打标记时多。打印器从一条注释之前开始标记就不会遇到。

和另外两种分离不同，这个分离要读字节（判断空白、给超长原子数非空格字节），所以它像 `enumerateSpans(_:)` 一样走一遍文本，遇到违反 unchecked 构造器不变量的值时 trap，诊断信息与其他读取方相同。从 identifier 里读出的 kind 与角色不再校验：手工构造的串里出现控制字符，读出来原样保留，不 trap。

## 影响面

- 纯增量 API，全部 `@inlinable`、`Sendable`，不引入任何依赖。
- 没打标记时：输出、行为和开销都不变，容器与现有的三种操作（两种分离、投影）没有改动。
- 打标记的开销在调用方：每个被包住的原子每层多一次字符串拼接；`AnnotatedAtom` 只在打标记时把一个原子拆成几个。

## 迁移注意事项

无需迁移。编码是本库内部格式，调用方只通过 `AnnotationRegionTable` 读，不应自己解析 `identifier`。

## 验证

- `AnnotationRegionTests`（32 个测试，其中 3 个参数化，共 42 例）：编码往返，注释字段留在可见性标记与定义身份里面；三种区域六种嵌套顺序得到相同原子，区域包在 `AnnotatedAtom` 外面或里面结果相同；区域与段不改文本、保留元素结构，`AnnotatedAtom` 是一个元素、片取它的类型与 identifier；锚点的选取；超长原子记下非空格字节数；空内容什么都不记。分离：还原不打标记的打印，三组选项下冻结串逐个相等（span 一一对应）；表的字面值——一条注释的四个段，一棵字段偏移树的深度、外层索引与裁剪后的范围；紧挨着的同 kind 区域、同角色段、内容完全相同的 `AnnotatedAtom` 读回为几个；首个原子带条件的区域紧跟同 kind 区域时照样从它自己开始；区域跨过 `MemberList` 打的装饰；首尾空白的裁剪，只含空白的区域不进表；三种分离六种顺序结果相同；嵌套定义切出、去缩进后与单独打印相等（冻结串与注释表），带与不带可见性标记两种打印；全量打印在八组选项下投影再分离，与按选项打印再分离相同；超过 65535 字节的 `AnnotatedAtom` 并回后与 `frozen()` 的切法相同，相邻两个相同的超长锚点在去缩进前后都读回为两个；片被标成不同样子时不乱并；已知限制（紧挨着的无锚段读回为一个）钉成测试；手工构造的 identifier 不 trap；畸形 span 的三种 trap 与各前提条件的 trap 用退出测试；README 示例原样跑一遍。
- 变异测试：故意破坏设计的七处，每一处都让测试变红——同 kind 一律接续（DefinitionRegion 的读法）7 个测试红；选锚点时不看可见性条件 3 个红，其中包括投影契约；前导原子接续已有锚点的区域 2 个红；不认超长原子的后几片 2 个红，改用「identifier 与前一个 span 相同就算同一原子」的朴素规则 3 个红；不裁剪 2 个红；不并回片 6 个红；把注释字段放在最外层 8 个红。第一轮时投影契约对「选锚点不看条件」不变红：样本打印器里没有「首个原子带条件的区域紧跟同 kind 区域」这种形状，补上之后才变红。
- 全部 464 个测试通过，watchOS `arm64_32` 编译通过。未合入的 `fix/32-bit-separation-traps` 分支里那个扫描 32 位转换写法的测试，对新代码同样成立（identifier 下标只经 `Int(exactly:)` 转换，没有 `Int(UInt32.max)`）。
- 下游：MachOSwiftSection、MachOObjCSection 的 `marksCommentStructure` 契约测试，由它们各自的提案负责。

## 落地步骤

每一步单独构建通过、测试通过后提交。

1. **编码与三个组件**：`AnnotationRegion`（含 `Kind`）、`AnnotationSegment`（含 `Role`）、`AnnotatedAtom`，以及阶段的计算与编码。测试覆盖编码、三种区域的嵌套顺序、元素结构、各前提条件的 trap。（已完成）
2. **分离与表**：`AnnotationRegionTable` 与 `separatingAnnotationRegions()`——边界判定、片组并回与重切、首尾空白裁剪。测试覆盖相邻实例、嵌套、容器装饰、裁剪、三种分离的顺序、切出与去缩进、投影、超长原子、已知限制。（已完成）
3. **文档与收尾**：README 新增一节；AGENTS.md 的架构说明、identifier 编码规则与测试文件清单；本文的状态与验证结果；watchOS `arm64_32` 编译检查。（已完成）

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-31 | 建为草案 | RuntimeViewer 的 SourceEditor 注释标签需要生成器在打印时给出注释结构；本库、两个生成器、RuntimeViewer 各由一个会话负责，本库先出 API。 |
| 2026-10-31 | 分离契约以「每个字节的文本、语义类型与 identifier 相同」为底线，另提供 `AnnotatedAtom` 做到冻结串逐个相等 | RuntimeViewer 放宽了契约；MachOSwiftSection 希望拆开的原子能并回，MachOObjCSection 要求开关关着时原子与今天相同。可选的 `AnnotatedAtom` 同时满足三方，并保住「分离出的就是不打标记时的打印」。 |
| 2026-10-31 | 实例边界用锚点记录，不用编号 | MachOSwiftSection 要求标记与位置无关（同一条注释内联打印与单独打印相同），并要求「全量打印投影后再分离」与「按选项打印再分离」结果相同；锚点经得起去缩进、投影和切出。 |
| 2026-10-31 | 表里的区域范围裁掉首尾空白，段不裁 | MachOSwiftSection 提出：字段偏移根区域必须包住根那一行的换行，裁剪让生成器不必为对齐区域边界重排原子。 |
| 2026-10-31 | 不做区域属性，不做 `OutputTransformer` 的模板分段 | 三方第一版都不用；以后要加都是纯增量。 |
| 2026-10-31 | 用户批准，开始实现 | — |
| 2026-10-31 | 注释字段的控制字符取 U+0010–U+0014：U+0010 包住整段，U+0011 区域、U+0012 段、U+0013 片、U+0014 超长原子的非空格字节数 | 另外两种区域用了 U+0001–U+0007；每种字段一个标记，解码时不必看上下文。 |
| 2026-10-31 | 锚点要求「区域里每个原子都带着它身上的全部可见性条件」，按条件的编码串求交集来判断 | 这是投影后锚点仍在的充分条件；按编码串而不按条件之间的逻辑蕴含判断，宁可少认锚点，也不认错。 |
| 2026-10-31 | 分离遍历文本，畸形值 trap；读出的 kind 与角色不再校验 | 判断空白、数非空格字节都要读字节，与 `enumerateSpans(_:)` 一样把不变量的违反变成带名诊断；读取方不该因为手工构造的串里有怪字符而崩溃。 |
| 2026-10-31 | 片被标成不同样子时只并回一致的相邻片，不 trap | 只有从一条注释中间开始的流式标记会造成这种情形，打印器不会这样做；不并比并错安全，也不值得为此让分离崩溃。 |
| 2026-10-31 | 测试的样本打印器加入「首个原子带条件的注释紧跟同 kind 注释」 | 变异测试发现投影契约在原样本上抓不到「选锚点不看条件」，补上后变红。 |
| 2026-10-31 | 实现完成，待用户看过后收尾 | 文档同步：README 新增一节；AGENTS.md 的组件说明、identifier 编码规则、测试文件清单，并新增「注释标记不带位置」一条；本文的验证结果。不另写使用指南或实现说明：契约、限制和降级都写在本文与 README 里。没有要进术语表的新术语——「锚点」「片」在本文首次出现处已解释，且只在本库内部使用。 |
