# 可见性区域：一次打印，按任意选项还原

- **状态**：已实现，合入 `next`（分支 `feature/visibility-regions`，尚未发版）
- **日期**：2026-09-29
- **使用方**：MachOSwiftSection、MachOObjCSection 的「标记模式」打印；RuntimeViewer 的 Find 语料

## 动机

RuntimeViewer 的 Find 在引擎里给每个对象存一份打印好的 interface，搜索只在这份文本上跑。内容区显示的文本由一组
「显示选项」决定：ObjC 的 strip 开关去掉合成 ivar、合成 getter / setter、override 等整行成员，注释开关在行尾加上
偏移和地址；Swift 的开关控制偏移 / 地址 / 布局注释行、stripped symbolic item，opaque 类型写成 `some` 还是
`some View`。语料若按某一组选项打印，用户换一组就对不上：此前语料固定按「全部显示」打印，结果能搜到内容区
根本不显示的东西；改成跟随用户选项，又得在每次切换开关时把整个镜像重新打印一遍（SwiftUI 一遍约两分钟）。

要的是：**打印一次全量文本，搜索时再按当前选项还原出显示文本**。只有打印器知道每段文字受哪个选项控制——
注释文字能被调用方的模板改写，从文字认不出来；一个成员有几行注释取决于偏移、符号是否存在，从位置也推不出来。
所以打印器要能在输出时把这个归属一起交出来，本库提供承载它的方式和按选项还原的算法。

## 范围

- 新组件 `VisibilityRegion`：包住一段内容，声明它在什么条件下可见。
- 新类型 `VisibilityCondition`：以命名选项为变量的布尔条件（析取范式）。
- 流式写入的对应物 `SemanticString.markAtoms(from:visibleUnder:)`：给已经写进去的一段原子补上条件，供
  `write(_:)` 一类逐段写入的打印代码使用（MachOSwiftSection 的 NodePrinter 写 opaque 类型约束就是这种）。
- 冻结后把区域分离出来：`FrozenSemanticString.separatingVisibilityRegions()`，返回去掉标记的文本和一张区域表。
- 按选项还原：区域表对文本做投影，得到「这组选项下打印器会输出的文本」，并能把原文本的偏移映射到投影后的偏移。
- 本库的容器（`MemberList`、`BlockList`、`Rows`、`Joined`、`Group`、`ForEach`、`NestedDeclaration`、
  `DeclarationBlock`）把成员的条件带到它们为成员打的换行、缩进、分隔符和前后缀上。

不改动：`SemanticString` 的存储、`frozen()`、`FrozenSemanticString` 的存储布局与 `Codable` 格式。不打标记的
调用方看不到任何输出上的差别；容器在每个成员上多一次「第一个原子有没有标记」的判断。

## 关键设计与取舍

### 标记放在原子的 `identifier` 上，不插入额外原子

`VisibilityRegion` 在展平时把内容里每个原子的 `identifier` 改写成「条件 + 原 identifier」的编码串，文本与语义类型
一字不动。于是标记模式打印出的文本与「全部显示」打印逐字节相同，容器与打印器的任何内部判断都不受影响
（例如 `DeclarationBlock` 看 body 最后一个原子是否以换行结尾来决定是否补换行）。区域保持元素结构：包住三个
成员的区域，放进容器后仍是三个成员。

否决的做法：在区域两端插入成对的标记原子，冻结时再剔除。它能显式表达区域边界，但额外的原子会穿过所有容器，
任何查看末原子、原子个数的逻辑都可能被干扰，每个打印器都得逐处排查。

代价：区域内原子原来的 `identifier`（如类型名的跳转标识）在标记模式的 `SemanticString` 里被编码进标记串，
分离区域时原样恢复，所以分离后的 `FrozenSemanticString` 与普通打印的一致。区域可以嵌套，内层原子的条件是
外层条件与内层条件的合取。

### 条件用析取范式

变量是调用方定义的选项名（字符串，本库不解释其含义），字面量是「某选项开」或「某选项关」。单个区域的条件是
若干合取项的析取，嵌套给出合取。析取主要出现在容器上：一组成员里只要还有一个可见，这组的前后缀就要保留。

### 容器把成员的条件带到自己的装饰上

投影只删掉条件不成立的区域，不做任何按行或按空白的猜测。能做到这一点，是因为容器为某个成员打出的装饰带着
和那个成员相同的条件：

- `MemberList` / `BlockList` 在成员前的换行与缩进 → 该成员的条件；
- `Rows` / `Joined` / `Group` / `ForEach` 在成员之间的分隔符、`BlockList.separatedByEmptyLine()` 的空行 →
  「该成员可见且前面已有成员可见」；
- `Joined` 的前后缀、`MemberList` / `BlockList` 末尾的换行、`DeclarationBlock` 关闭花括号前的换行与缩进 →
  「任一成员可见」；
- `NestedDeclaration` 前面的换行 → 其内容的条件。

「成员整个在区域里」的判定：它的每个原子都带标记；它的条件是这些原子上各组条件的析取。只要有一个原子不带
标记，成员就是无条件的——没打标记的内容走的正是这条路径，只看第一个原子就返回。

曾经试过另一种做法：投影时删掉「因删除而只剩空白的行」，不改容器。它在成员被部分删掉时成立，但一组成员被
整组删掉时，删不掉组与组之间本该保留的空行，多行区域也会留下空行，随机测试很快就找到了反例。

两处例外：`ForEachIndexed` 由内容自己按 `isFirst` / `isLast` 排版，容器无从得知；`DeclarationBlock` 按 body
在全量打印时的最后一个字节决定要不要补换行，body 的结尾若随选项变化则还原不出。

### 区域表

分离区域时得到按文本顺序排列的「连续 UTF-8 范围 + 条件编号」列表和去重后的条件表。嵌套的几层条件在这里
合并成一个规范化的条件，所以成员自身与容器为它打的装饰（语义相同、写法不同）落在同一个条件、同一段范围里。
投影结果带一张保留范围表，用来把原文本的偏移映射到投影后的偏移（落在被删内容里的偏移没有映射）。

## 影响面

- 纯增量 API，全部 `@inlinable`、`Sendable`，不引入任何依赖。
- 不打标记时输出与行为不变；开销上唯一的新增是容器对每个成员多看一眼首原子是否带标记（未带标记即走原路径），
  这次判断的代价尚未测量，见「验证」末条。
- 标记模式的开销只在调用方：每个被包住的原子多一次字符串拼接。

## 迁移注意事项

无需迁移。标记串的编码是本库内部格式，调用方只通过 `VisibilityCondition` 与区域表读写，不应解析 `identifier`。

## 验证

- 条件求值、编码往返、嵌套合取的单元测试（`VisibilityRegionTests`）。
- 投影与容器的一致性：对 `MemberList`（含外层再包一层区域）、`Rows`、`BlockList`（含空行分隔）、带标题的分组
  `Joined`、行内的 `Joined` / `Group` / `ForEach`、整个 body 可能被删空的嵌套 `DeclarationBlock`，随机给成员分配
  条件，在全部选项取值下比较「打全量再投影」与「只打可见成员」，`FrozenSemanticString` 完全相等（文本、span、
  identifier）。
- 分离区域后的 `FrozenSemanticString` 与不打标记的打印相等（含 `identifier`）；`markAtoms` 与区域逐原子一致。
- 全部 412 个测试通过（含新增），既有测试一条未改，即没打标记时输出与行为不变；watchOS `arm64_32` 编译通过。
- 下游的对照测试：MachOObjCSection 对 Foundation 的全部 class / protocol / category、MachOSwiftSection 对
  SymbolTestsCore 的全部顶层类型 / 协议 / 扩展，在多组选项组合下「投影 == 直接打印」逐字节相同。
- 尚未做：没打标记时容器多出的那次判断的开销，没有做 release 模式下与 `main` 的对比测量。
