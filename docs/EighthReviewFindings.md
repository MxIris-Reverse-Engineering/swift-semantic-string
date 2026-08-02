# 第八轮评审：四问核验

## 动机

对 PR #1 又跑了一轮独立评审，报告 15 项发现。本篇按项目规定的四问逐条核验：**能否复现（是否误报）**、**`main` 是否同样存在**、**值不值得修**、**以前是否修过**。

**首要背景：本轮评审读的是 `4bf98e3`，而 PR 的实际 head 是 `2b07c0a`。** `4bf98e3` 停在第六轮结束；第七轮的文档诚实化（`1405424`）、裁决清单（`aac65f0`）、零长 span 修复（`71fa421`）、拥有权与锁条带修复（`2b07c0a`）都已经在分支上——评审读到的是一份陈旧的 remote-tracking 引用，不是分支的真实状态。因此 15 项里有 5 项评的是已经修过的代码，2 项评的是第七轮刚写下的裁决。核验一律在 **`2b07c0a`** 上进行，因为那才是待合并的实际内容。

核验手段是把 `Sources/Semantic` 的全部源文件与探针一起编译进同一个模块（`swiftc -O -module-name Semantic`），从而能直接触到 internal 存储 API；预期会 trap 的场景各自独立成进程，按退出码判定。测试有效性用变异测试判定：注入该测试声称能抓的回归，看它是否真的转红。

## 结论总览

| # | 发现 | 复现 | `main` | 裁决 |
| --- | --- | --- | --- | --- |
| 1 | `PlainAtomicSemanticComponent` 违约叶子的内容分叉 | 属实 | 无此协议 | 已裁决 [S4](SettledFindings.md)，理由仍成立 |
| 2 | 畸形 frozen 值入 `Set` 靠哈希碰撞才 trap | **属实**（exit 133） | 无此类型 | 第五轮有意决策，**补记未评估的后果** → S7 |
| 3 | `-Ounchecked` 擦除全部 `precondition` | **属实**（10 项测试转红） | 无此类型 | **测试待修**；语言语义部分不修 → S8 |
| 4 | 零长 span 不 trap | 已修（`71fa421`） | 无此类型 | 第七轮已修，实测 trap 生效 |
| 5 | `atoms(ofElementAt:)` 双索引基准 | **属实**（exit 133） | 无此视图 | **待修** |
| 6 | `==`/`hash` 比较归一后的类型 | 属实 | 无此类型 | 第四轮有意修复，**补记跨版本后果** → S9 |
| 7 | `CacheLockStripes` 三处防线 | 部分已修 | 无此表 | stride 已修；**错误码与 `#else #error` 待修** |
| 8 | 快路径断言的 debug 代价 | 已缓解（-6%） | 无此协议 | 第七轮已优化并文档化，仍是最慢路径 |
| 9 | 急切展平使冷内存差于 `main` 19% | **误报** | — | **无法复现，方向相反** → S10 |
| 10 | `appending` 全量拷贝 | 已改 `consuming` | 更快（常数） | 第七轮已处理，且推翻了原因果分析 |
| 11 | 32 位条带散列测试无效 | **属实**（256 vs 256） | 无此表 | **待修** |
| 12 | `appendMatrix` 四种组合实为一种 | **属实**（变异后仍绿） | 无此表 | **待修**（真实覆盖由第六轮测试提供） |
| 13 | `components` 缓存时间界在 release 失效 | **属实**（debug 红 / release 绿） | **`main` 更强** | **待修**（本分支引入的强度回归） |
| 14 | `init(stringLiteral:)` 无锁写缓存 | 属实（代码事实） | 同样写法，但无锁可言 | **待修**（审计清单不完整） |
| 15 | 文档与代码矛盾 | 大部分已修 | — | `if(false)` 一处**待修** |

**7 项待修，1 项误报，其余为已修或已裁决。**

## 逐条四问

### 1 · `PlainAtomicSemanticComponent` 违约叶子的内容分叉

命中已裁决清单 **S4**（第六轮裁决，第七轮复核并修正了协议文档的失实表述）。理由——快路径的全部价值就是不调用 `buildComponents()`，无法免费加运行时校验——仍然成立。评审建议的 witness 式协议（`var plainAtom: AtomicComponent { get }`）值得作为独立提案评估，但它改变的是公开协议形状，不属于本轮范围。**跳过，不重走四问。**

### 2 · 畸形 frozen 值入 `Set` 靠哈希碰撞才 trap

**复现**：属实，且机制比报告描述得更精确。构造两个畸形值，文本同为 `"abc"`、span 数同为 1、`typeCode` 与 `identifierIndex` 全同，**只有 span 字节长度不同**（103 与 104）。`hash(into:)` 不哈希 span 长度，所以两者哈希相同；`==` 的字节相同快路径要求 `spans` 相等，而它们不等，于是插入被迫走 span 解析环。实测：`hashValue` 计算成功、第一次 `insert` 成功、第二次 `insert` 进程 exit 133。单独一个畸形值全程安静（exit 0）。

**`main`**：不存在 `FrozenSemanticString`，不适用。

**以前修过吗**：这是第五轮 `ab96ed4` 的**有意决策**，`docs/FifthReviewFixes.md` 记为「畸形值的失败模式统一为『读时带名 trap，hash 安静』」，收益实测 50 万 span 值哈希 -62%、`Set` 插入 -65%。但该轮的影响面写的是「畸形值的 `hashValue` / `Set` 插入从裸 stdlib 崩溃变为安静成功」——**「`Set` 插入变为安静成功」只在不发生哈希桶碰撞时成立**，这一层当时没有评估。

**值不值得修**：畸形值只能由 public unchecked 初始化器手工构造，`frozen()` 与解码器都不可能产出；该初始化器的契约明确写了违反不变量会 trap。所以「崩」本身在契约内，问题是**崩得不确定**。要让它确定，只有两条路：unchecked init 加校验（那它就不再 unchecked，O(n) 代价正是它存在的理由），或 `hash` 重新走文本（撤销第五轮的 -62%）。两者都比问题本身更糟。**不修，但把「`Set`/`Dictionary` 插入可能触发解析环，因而 trap 时机取决于哈希碰撞」补进 unchecked init 的文档**——当前文档只列了 `enumerateSpans` / `components` / `==` 解析路径三个 trap 点，读者据此会以为容器操作是安全的。裁决记为 S7。

### 3 · `-Ounchecked` 擦除全部 `precondition`

**复现**：属实，且比报告更严重。报告在 `4bf98e3` 上看到 6 项测试转红，本地 tip 因第七轮新增了 4 项零长 span 的 trap 测试，实测 **10 项转红**。具体行为：`-Ounchecked` 下 `FrozenSemanticString(text: "ab", spans: [1, 0, 1])` 静默产出 `["a", "", "b"]`——正是第七轮刚修掉的那个缺陷，在这个模式下修复等于不存在；两个畸形值在 `Set` 中静默判等，count 折叠为 1。

**`main`**：不存在该类型，不适用。

**以前修过吗**：第五轮明确选择 `precondition` 而非 `assert`，理由是「它是 release 下唯一挡住 unchecked init 坏值的守卫」。当时评估的对立面是 `assert`（`-O` 下消失），**没有评估 `-Ounchecked`**。

**值不值得修**：**要分成两半判。** `-Ounchecked` 移除 `precondition` 是 Swift 的语言语义，不是本库的缺陷——同一模式下标准库自己的数组边界检查也全部消失，`Array` 越界同样是 UB。要求库在 `-Ounchecked` 下仍然守住不变量，等于要求它不遵守用户显式选择的编译模式。**这部分不修**，但 unchecked init 的文档应当写明「这些 trap 在 `-Ounchecked` 下不存在，契约随之降级为纯 UB 契约」。

真正该修的是**测试**：10 项 exit test 在 `-Ounchecked` 下变红而不是跳过。第六轮为 `assert` 那项加了 `#if DEBUG` 守卫，同类的 `precondition` 项漏了——这是那次修复的横向排查遗漏。项目文档里没有任何命令用 `-Ounchecked`，所以优先级不高，但漏排查本身要补上。裁决记为 S8。

### 4 · 零长 span 不 trap

第七轮 `71fa421` 已修，修在三个消费点共用的 `spanUpperBound(after:spanLength:)` 上。实测确认：`components` 与 `==` 慢路径均 exit 133。

**残留（设计内）**：`count` 对该畸形值仍报 3、`isEmpty` 仍为 false，因为这两个度量按第五轮的既定决策不走文本。这与「hash 安静」同源，属 S7 的范围。

### 5 · `atoms(ofElementAt:)` 双索引基准

**复现**：属实。同一份三元素内容，`.strings` 表示下三个元素的 slice `startIndex` 全是 0，`.contents` 表示下是 0 / 1 / 2。对元素 1 取 `slice[0]`：`.strings` 正常，`.contents` 进程 exit 133。

**`main`**：不存在元素视图，不适用。

**以前修过吗**：来自 `4aaa56e`（第二轮结构性重设计），从未被报告过。第七轮把它列在 `SettledFindings` 之外，也没列入待修——是本轮第一次正式裁决。

**值不值得修**：**修。** 当前唯一的防线是一段 11 行的文档注释（「只通过 slice 自身的属性消费，绝不用字面位置」），而有 6 个 `@inlinable public` 函数依赖这个约定。哪种基准由**调用方选了哪个初始化器**决定，不由容器代码决定，所以容器作者无法在本地推断。修法：`init(_ items: [SemanticString])` 已经有一个急切展平进单一 `.contents` 运行的姊妹初始化器，把 `.strings` 表示整体去掉即可统一——但那会牺牲 `[SemanticString]` 容器的零拷贝优势（该优势是本分支相对 `main` 的主要收益之一，见 `docs/ThirdReviewFixes.md`）。折中方案是让 `.strings` 分支返回 `itemAtoms[...]` 时保持与 `.contents` 一致的绝对基准，或反过来把 `.contents` 分支重新切片为零基。后者是一行改动且不影响任何现有调用点，优先。

### 6 · `==`/`hash` 比较归一后的类型

**复现**：属实。`typeCode: 200` 与 `typeCode: 7`（`.other` 自己的码）的两个快照相等、哈希相同、`Set` 计数为 1；实测存活的字节取决于插入顺序（先插 200 则存活 200，反之存活 7），而两者编码出的 JSON 不同。

**`main`**：不存在该类型，不适用。

**以前修过吗**：**这不是缺陷，是第四轮 `039e0fd` 的有意修复。** `docs/FourthReviewFixes.md` 记载：`enumerateSpans`、`components`、渲染全部把未知 `typeCode` 归一为 `.other`，而 `==`/`hash` 当时比较原始字节，导致「被每一个读者渲染成完全相同内容的两个值判不相等，`Set`/`Dictionary` 查找互相落空」。该轮还写明了迁移建议：需要按原始字节区分的调用方改比 `spans.map(\.typeCode)`。

**值不值得修**：**理由仍成立，不推翻。** 但评审提出了第四轮**没有评估**的后果：`nextFreeFrozenTypeCode` 现在是 22，将来第一次把真实语义赋给某个旧载荷已携带的码时，此前相等的两个解码快照会突然不等——`Set` 成员关系跨库版本变化，无解码错误也无编译错误。这是任何「未知码归一」方案的固有属性：改用显式 `.unknown(UInt8)` 保留原始码，就会把第四轮修掉的问题（未知码与 `.other` 判不等）原样请回来，两者不可兼得。**当前选择有据可依**，但该后果必须记进档，并在 `AGENTS.md` 的类型码章节写明「给既有码位赋新语义会改变已发布快照之间的相等性」。裁决记为 S9。

### 7 · `CacheLockStripes` 的三处防线

**复现**：三点中一点已修、两点属实。

- **stride 硬编码 + 运行时 `precondition`** —— 第七轮 `2b07c0a` 已改为推导（`max(128, ≥ primitive stride 的最小 2 的幂)`），残留的 `assert` 只是不变量的 debug 重述。**已修。**
- **`pthread_mutex_init` 的返回值被丢弃** —— 属实，`initializePrimitive` 仍是裸调用。
- **`#if canImport` 导入链没有 `#else #error`，且与 `Primitive` 的分支链不一致** —— 属实。导入链覆盖 `Darwin | Glibc | Musl | Bionic | WinSDK`，而 `Primitive` 解析为 `Darwin | WinSDK | else -> pthread_mutex_t`。在这五者之外的目标（WASI 的 `WASILibc`，或任何改名的 libc overlay）上不会发出任何 `import`，构建以四处重复的 `cannot find type 'pthread_mutex_t' in scope` 结束，而不是一条可执行的诊断。

**`main`**：不存在该表，不适用。

**以前修过吗**：条带表来自 `718b602`（第一轮评审修复），当时的重点是把单把 `NSLock` 换成条带并去掉 Foundation 依赖，平台分支的完备性没有被审过。

**值不值得修**：**修，代价极低。** 两处都是编译期就能封死的：`#else #error("...")` 加在两条链上，`pthread_mutex_init` 的返回值用 `precondition` 检查（它只在参数非法或资源耗尽时失败，正常路径零成本）。这件事的紧要程度在本分支里是**上升的**——`README.md` 与 `AGENTS.md` 新增了「也能在 Linux 和 Windows 上构建」的承诺并强调「每一处都在 `#if canImport` 之后」，而 `Package.swift` 只声明了 Apple 平台（`platforms:` 只设最低版本，不阻止 SwiftPM 为 Linux 构建），仓库也没有任何非 Darwin 平台的 CI。承诺与验证之间目前是空的。

### 8 · 快路径断言的 debug 代价

第七轮 `2b07c0a` 已优化（只读一次 `string`、按字段比较，30 万次 append 149.7 ms → 140.9 ms），并已在 `AGENTS.md` 与协议文档写明它在 debug 下仍是最慢的 append 路径、且 `@inlinable` 使下游 Debug 应用同样付费。主成本（调用 `buildComponents()` 本身）不可约。**无新增动作。**

### 9 · 急切展平使冷内存差于 `main` 19%

**复现失败——判为误报。** 三组独立测量，每组 10,000 个保留的声明字符串，取峰值常驻内存：

| 内容形状 | 场景 | `main` | 本分支 |
| --- | --- | --- | --- |
| 85 个叶子组件 | 构建后不渲染 | 65.8 MB | 66.0 MB |
| 85 个叶子组件 | 构建并渲染 | 111.7 MB | 70.7 MB |
| 217 个叶子组件 | 构建后不渲染 | 142.7 MB | **128.7 MB** |
| 217 个叶子组件 | 构建并渲染 | 257.1 MB | 138.6 MB |
| 217 原子包在**单个 `Group`** 里 | 构建后不渲染 | 144.0 MB | **129.5 MB** |
| 同上 | 构建并渲染 | 258.5 MB | 139.3 MB |

**没有任何一组重现报告的方向。** 第三组是刻意构造的最不利形状——整个声明是一个 composite 元素，`main` 理应只保留一个装箱组件而本分支保留全部展平原子——本分支仍然更省。原因是 `main` 的叶子本身也是装箱的：`Group` 内部持有一个 builder 结果 `SemanticString`，那个值在 `main` 上已经是一整个装箱元素数组，每元素 40 字节容器加 64 字节堆盒，比本分支的 40 字节原子更贵。

报告给出的 127.2 MB / 107.0 MB 与本测量的量级接近但方向相反，推测其对照组的构造路径与此不同（未在报告中说明）。**冷内存方向不存在回归，无需记账。** 已记账的时间方向（builder 收集路径慢于 `main`）是另一回事，见 S3。裁决记为 S10。

### 10 · `appending` / `+` 全量拷贝

第七轮 `2b07c0a` 已把 `appending` 族改为 `consuming`，并**推翻了报告的因果分析**：`makingUnscopedCopy()` 里的 `var copy = self` 不是 1.65× 差距的原因（默认累加写法在改动前后都是约 76 ms，`consuming` 对它毫无影响，因为 `acc` 是赋值目标、右值求值期间仍是活绑定）。真实原因是元素本身变大——`main` 复制每元素一个装箱指针（8 字节、1 次引用计数），本分支复制 `AtomicComponent`（40 字节、2 次）。`consuming` 保留下来是因为它启用了两条此前不存在的路径（链式 `appending` 1.78×，显式 `consume` 累加从 75.1 ms 降到 0.2 ms）。详见 `docs/SeventhReviewFixes.md`。**无新增动作。**

### 11 · 32 位条带散列测试无效

**复现**：属实。用该测试自己的输入（`address` 从 `0x1000_0000` 起、步进 64、4096 次）分别跑三种实现：

| 实现 | 不同条带数 |
| --- | --- |
| 现行 64 位混合 | 256 |
| 把乘数截断成 32 位，在 64 位主机上求值 | **256** |
| 同样的截断代码，在真正 32 位的 `UInt` 上求值 | **1** |

测试断言 `usedStripes.count > 128`。**它声称能抓的那个回归，在任何能跑这套测试的机器上都同样得到 256，断言照过。** 只有 `UInt` 真是 32 位的地方才塌成 1，而那是 arm64_32 / armv7k，`swift test` 从不在那里跑，仓库也没有 CI。

**`main`**：不存在该表，不适用。

**以前修过吗**：测试来自 `718b602`（第一轮评审修复），与条带表同批引入，从未被质疑过。

**值不值得修**：**修。** `AGENTS.md` 把这个测试点名为该不变量的自动化守卫，而它守不住任何东西；一个照着 `AGENTS.md` 的警告去踩坑的贡献者会看到 385 项全绿，然后 watchOS 上每个 storage 落到条带 0——退化成实测 434.9 ms（对 44.7 ms）的单把全局锁。修法是让测试在 `UInt32` 通道上调用混合逻辑，或直接断言乘数的类型，而不是采样活的条带表。

### 12 · `appendMatrix` 的四种组合实为一种

**复现**：属实。辅助函数 `boundedString` 的注释说它「通过 append 一个 composite 元素给字符串一张物化的边界表」，实测 `Group { Keyword(text) }` 展平后恰好一个原子，`closeElement(appendedAtomCount: 1)` 直接 early return，`elementEndOffsets` 保持 `nil`。四对组合的边界表全是 `(nil, nil)`，只有 `appendContents(of:)` 的第一个快路径分支被执行。

变异测试确认：同时破坏 `for endOffset in otherEndOffsets` 拼接循环与 `while endOffset <= finalAtomCount` 展开循环之后，`appendMatrix` 与 `appendingMatchesAppend` **仍然通过**；385 项里只有第六轮补的两项（`SixthReviewRegressionTests` 的两个 splice 测试）转红。

**`main`**：不存在该表，不适用。

**以前修过吗**：`boundedString` 来自 `4aaa56e`（第二轮重设计）。第六轮做变异测试时发现了这块覆盖缺口，补了两个真正有效的测试，但**没有回头修这个名不副实的辅助函数**——所以缺口的实质是「一个声称覆盖四种组合的测试给出虚假的覆盖印象」，而不是「无人覆盖」。

**值不值得修**：**修，但严重性低于报告的定性。** 真实覆盖已经存在。要改的是把 `boundedString` 换成真会物化表的构造（`Group { Keyword("a"); Keyword("b") }` 实测产出 `elementEndOffsets == [2]`），并把 `expectedElementCount` 的推导从 `_storage.elementCount`（正在被测的同一个访问器，两侧同错则相等）换成独立的期望值。

### 13 · `components` 缓存时间界在 release 下失效

**复现**：属实，变异测试确认。把 `components` 改成 `_storage.atoms.filter { !$0.string.isEmpty }`（存储文档点名警告的那个 O(n) 回归）之后：**debug 0.095 秒失败**（超 50 ms 界），**release 0.011 秒通过**（界的 1/4.5）。

**`main`**：**`main` 上的版本更强。** `repeatedComponentsReadsAreCached` 来自 `f487313`，是 `main` 的既有测试，断言是相对界 `readElapsed < buildElapsed * 2`。本分支 `4aaa56e` 把它改成了绝对界 `< .milliseconds(50)`。

**以前修过吗**：改动本身有正当理由，写在测试的注释里——`main` 的 `components` 是惰性的，第一次读会真的构建，相对基线有意义；本分支的 `components` 直接返回存储数组，没有构建步骤可比。**但换成绝对界的代价没有被评估**，注释里「O(n) 重展平回归约为本界的 1.5–2 倍」这句话只在 debug 下成立（实测 1.87 倍），release 下实测 0.011 秒、连全量重展平也过得去。而 `docs/SeventhReviewFixes.md` 把 `swift test -c release -Xswiftc -enable-testing` 记为常规验证手段——盲区正好落在项目自己会跑的配置里。

**值不值得修**：**修。** 这是本分支引入的测试强度回归，且落在项目声明会跑的配置上。相对基线在这里确实不可用，但可以换成配置无关的判据：与一次已知 O(n) 操作（例如 `components.map(\.string)`）对比，或直接断言返回的数组与存储数组共享缓冲（`withUnsafeBufferPointer` 的基址相同），后者把时间断言换成结构断言，彻底摆脱配置依赖。

### 14 · `init(stringLiteral:)` 无锁写缓存

**复现**：属实（代码事实）。`SemanticString.swift:254` 直接写 `_storage.cachedString = value`，实测字面量构造后缓存即已填充。

**`main`**：**同样的写法，来自 `c53a80c`（Initial commit）**，不是本分支引入。但 `main` 上根本没有条带锁，也没有「每一次 `cachedString` 访问都走 `cacheLock`，唯一经审计的例外是 `makeUniqueForMutation()`」这条规则——**规则本身是本分支建的，而它建立的同一个 PR 里就有第二处未被列入的写。**

**以前修过吗**：这处写从未被改过。审计注释来自本分支的锁改造。

**值不值得修**：**修，但优先级最低——它当前不是竞争。** 评审自己用七个对抗性 ThreadSanitizer 场景验证过没有实际 race，本轮不重复。它今天安全的理由是「`Storage` 在上一行刚分配、尚未逃逸」，这是构造性的，而不是审计注释所依据的 `isKnownUniquelyReferenced` 证明。`cachedString` 是 `@unchecked Sendable` 类上的 `@usableFromInline var`，会内联进客户端二进制，没有任何机制阻止出现第三处。修法是把两处写都收进 `Storage` 上一个带锁的访问器，让审计清单变得可机械核对而不是靠注释维持。

### 15 · 文档与代码矛盾

报告列了五处（a–e）。第七轮 `1405424` + `aac65f0` 已修其中四处：AGENTS.md 的零长元素槽说法（a）、`SemanticString.swift` 的同源表述（c）、缺失的 `SettledFindings.md` 与 `SeventhReviewFixes.md`（d）、以及 PR 描述指向已被替换的双态设计（e 的主体）。

**剩下 (b) 属实且未修，实测确认：**

| 组合子 | 条件为假时的实现 | append 后的 identifier |
| --- | --- | --- |
| `if(false)` | `SemanticString()` | **`nil`** |
| `ifLet(nil)` | `self` | `"SPAN"` |
| `suffixed(with:if: false)` | `self` | `"SPAN"` |
| `wrapped(prefix:suffix:if: false)` | `self` | `"SPAN"` |
| `prefixed(with:if: false)` | `self` | `"SPAN"` |

`AGENTS.md` 把这五个归为一句「likewise return `self` unchanged and keep open scopes」，对 `if(false)` 是错的——它返回全新的空值，开着的 identifier scope 随之丢失。没有任何测试钉住这五者中的任何一个。

**值不值得修**：**修文档，行为不动。** `if(false)` 丢 scope 是否是缺陷需要单独判断（`if(false)` 语义上是「丢弃这段内容」，与 `suffixed(if: false)` 的「不追加后缀」不同，丢掉 scope 有其道理），但无论结论如何，文档现在描述的都是一个不存在的行为。同时补一个测试把五者的实际行为钉住。

`docs/README.md` 的索引里另有两处历史遗留：`TwoStateStorage.md` 与 `StorageCorrectnessAndLockRework.md` 仍带「已落地，全部验证通过」的措辞，而它们描述的机制（`compact()`、`convertToTree()`、`isFlat`、共享 `NSLock`）已被 `4aaa56e` 整体删除。`AGENTS.md` 已经写明这两篇是历史，索引没跟上。

## 待修清单

按建议优先级：

1. **#5** 统一 `atoms(ofElementAt:)` 的索引基准（一行改动，消除一整类未来缺陷）
2. **#13** 把 `components` 的时间界换成配置无关的结构断言
3. **#11** 让条带散列测试真正走 32 位通道
4. **#7** 两条 `#if` 链补 `#else #error`，检查 `pthread_mutex_init` 返回值
5. **#12** 修 `boundedString` 使其真的物化边界表，并独立推导期望元素数
6. **#15b** 更正 `AGENTS.md` 的条件组合子表述并补测试；清理 `docs/README.md` 的历史条目
7. **#3** 给 10 项 exit test 补 `#if DEBUG` 之外的守卫（或显式声明不支持 `-Ounchecked`）
8. **#14** 把两处 `cachedString` 写收进带锁访问器
9. **#2 / #6** 文档补记两条已裁决决策的未评估后果

前六项都不改变公开行为。第 7–9 项含文档与内部结构调整。

## 验证

- 全部复现均在本地 tip `2b07c0a` 上完成，探针与 `Sources/Semantic` 同模块编译（`swiftc -O -swift-version 6 -module-name Semantic`）。
- 预期 trap 的场景独立成进程，按退出码判定（133 = trap，0 = 静默通过）。
- 测试有效性用变异测试判定：#12 注入两处 splice 破坏、#13 注入 O(n) 重展平回归，分别观察 debug 与 release 两种配置。
- 内存数字取 `/usr/bin/time -l` 的峰值常驻集，`main`（`1b9f2ce`）与本地 tip 用同一份探针源码分别编译。
- `-Ounchecked` 结论来自 `swift test -c release -Xswiftc -enable-testing -Xswiftc -Ounchecked`（10 项失败）与同一探针的 `-Ounchecked` 构建。
