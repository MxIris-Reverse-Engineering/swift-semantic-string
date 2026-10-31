import Testing
@testable import Semantic

extension AnnotationRegion.Kind {
    fileprivate static let memberAddress = Self("memberAddress")

    fileprivate static let fieldOffset = Self("fieldOffset")

    fileprivate static let fieldLayoutNode = Self("fieldLayoutNode")

    fileprivate static let enumLayoutCase = Self("enumLayoutCase")

    fileprivate static let enumLayoutLine = Self("enumLayoutLine")
}

/// Tests for `AnnotationRegion`, `AnnotationSegment`, `AnnotatedAtom` and
/// the separation. The contract they pin: marking content never changes
/// what is printed or how containers lay it out; separating gives back
/// exactly the string printed without annotations, span for span, and finds
/// every region and segment — adjacent ones of one kind as several; the
/// three separations run in any order; a nested definition taken out of its
/// parent's print and de-indented separates like its own print; and a
/// projection separates like printing with those options.
@Suite("AnnotationRegion")
struct AnnotationRegionTests {
    // MARK: - A printer in miniature

    private struct TreeNode {
        var name: String

        var children: [TreeNode] = []
    }

    private struct Member {
        var name: String

        /// Shown under the `addresses` option.
        var address: String?

        /// Always shown; its tree only under `expandedOffsets`.
        var fieldOffset: String?

        var offsetTree: [TreeNode] = []

        /// A comment whose value reads one way under `hex`, another without.
        var offsetValue: (hexadecimal: String, decimal: String)?

        /// A block printed as ONE atom whose lines after the first carry
        /// their own indentation — the shape of a per-case enum layout
        /// comment.
        var layoutLines: [String] = []

        /// Notes printed directly one after another, each optionally opening
        /// with words shown only under `hex`: a note whose first atom is
        /// conditional, right after another note.
        var notes: [(hexOnlyPrefix: String?, text: String)] = []
    }

    private struct Definition {
        var name: String

        var members: [Member] = []

        var nestedDefinitions: [Definition] = []

        func definition(named name: String) -> Definition? {
            if self.name == name {
                return self
            }
            for nestedDefinition in nestedDefinitions {
                if let found = nestedDefinition.definition(named: name) {
                    return found
                }
            }
            return nil
        }
    }

    private struct Mode {
        var marksAnnotations: Bool

        var marksDefinitions = true

        /// `nil`: print everything, wrapping what only some options show in
        /// visibility regions. Otherwise: print only what these options show.
        var enabledOptions: Set<String>? = nil
    }

    private static let sample = Definition(
        name: "Outer",
        members: [
            Member(
                name: "first",
                address: "0x10",
                fieldOffset: "0x0",
                offsetTree: [TreeNode(name: "a", children: [TreeNode(name: "x"), TreeNode(name: "y")]), TreeNode(name: "b")]
            ),
            Member(
                name: "second",
                address: "0x20",
                offsetValue: (hexadecimal: "0x8", decimal: "8"),
                layoutLines: ["Case 0 (0x00)", "  offset 0x08 = 0x01"],
                notes: [(hexOnlyPrefix: nil, text: "first note"), (hexOnlyPrefix: "(hex)", text: "second note"), (hexOnlyPrefix: "(hex)", text: "third note")]
            ),
        ],
        nestedDefinitions: [
            Definition(
                name: "Inner",
                members: [
                    Member(name: "inner", address: "0x30", fieldOffset: "0x8", offsetTree: [TreeNode(name: "c")], layoutLines: ["Case 1 (0x01)", "Case 2 (0x02)"]),
                    Member(name: "plain"),
                ],
                nestedDefinitions: [
                    Definition(name: "Innermost", members: [Member(name: "deepest", address: "0x40", fieldOffset: "0x10", offsetValue: (hexadecimal: "0x4", decimal: "4"))]),
                ]
            ),
        ]
    )

    private static let options = ["addresses", "expandedOffsets", "hex"]

    private static func visible(under condition: VisibilityCondition, in mode: Mode, @SemanticStringBuilder _ content: () -> SemanticString) -> SemanticString {
        guard let enabledOptions = mode.enabledOptions else {
            return SemanticString { VisibilityRegion(condition, content: content()) }
        }
        return condition.isSatisfied(where: { enabledOptions.contains($0) }) ? content() : SemanticString()
    }

    private static func annotated(_ kind: AnnotationRegion.Kind, in mode: Mode, @SemanticStringBuilder _ content: () -> SemanticString) -> SemanticString {
        mode.marksAnnotations ? SemanticString { AnnotationRegion(kind, content: content()) } : content()
    }

    private static func segment(_ role: AnnotationSegment.Role, in mode: Mode, @SemanticStringBuilder _ content: () -> SemanticString) -> SemanticString {
        mode.marksAnnotations ? SemanticString { AnnotationSegment(role, content: content()) } : content()
    }

    /// One `.comment` atom, `// ` and the parts; an annotated atom of them
    /// when marking.
    private static func commentLine(_ parts: [(role: AnnotationSegment.Role?, text: String)], in mode: Mode) -> SemanticString {
        guard mode.marksAnnotations else {
            return SemanticString { AtomicComponent(string: "// " + parts.map(\.text).joined(), type: .comment) }
        }
        return SemanticString {
            AnnotatedAtom(type: .comment) {
                AnnotationSegment(.marker) { "// " }
                for part in parts {
                    if let role = part.role {
                        AnnotationSegment(role) { part.text }
                    } else {
                        part.text
                    }
                }
            }
        }
    }

    private static func treeNode(_ node: TreeNode, isLast: Bool, prefix: String, level: Int, mode: Mode) -> SemanticString {
        annotated(.fieldLayoutNode, in: mode) {
            BreakLine()
            Indent(level: level)
            commentLine([(.treePrefix, prefix + (isLast ? "└── " : "├── ")), (.name, node.name)], in: mode)
            for (index, child) in node.children.enumerated() {
                treeNode(child, isLast: index == node.children.count - 1, prefix: prefix + (isLast ? "    " : "│   "), level: level, mode: mode)
            }
        }
    }

    private static func layoutBlock(_ lines: [String], level: Int, mode: Mode) -> SemanticString {
        let indentation = String(repeating: " ", count: level * 4)
        guard mode.marksAnnotations else {
            return SemanticString {
                AtomicComponent(string: lines.map { "// " + $0 }.joined(separator: "\n" + indentation) + "\n" + indentation, type: .comment)
            }
        }
        return SemanticString {
            AnnotationRegion(.enumLayoutCase) {
                AnnotatedAtom(type: .comment) {
                    for (index, line) in lines.enumerated() {
                        if index > 0 {
                            "\n"
                            indentation
                        }
                        AnnotationRegion(.enumLayoutLine) {
                            AnnotationSegment(.marker) { "// " }
                            AnnotationSegment(.text) { line }
                        }
                    }
                    "\n"
                    indentation
                }
            }
        }
    }

    private static func memberRow(_ member: Member, level: Int, mode: Mode) -> SemanticString {
        SemanticString {
            if let address = member.address {
                visible(under: .enabled("addresses"), in: mode) {
                    annotated(.memberAddress, in: mode) {
                        commentLine([(.label, "Address"), (.separator, ": "), (.value, address)], in: mode)
                        BreakLine()
                        Indent(level: level)
                    }
                }
            }
            if let fieldOffset = member.fieldOffset {
                annotated(.fieldOffset, in: mode) {
                    commentLine([(.label, "Field offset"), (.separator, ": "), (.value, fieldOffset)], in: mode)
                    visible(under: .enabled("expandedOffsets"), in: mode) {
                        for (index, node) in member.offsetTree.enumerated() {
                            treeNode(node, isLast: index == member.offsetTree.count - 1, prefix: "", level: level, mode: mode)
                        }
                    }
                    BreakLine()
                    Indent(level: level)
                }
            }
            if let offsetValue = member.offsetValue {
                annotated(.note, in: mode) {
                    commentLine([(.label, "Offset"), (.separator, ": ")], in: mode)
                    segment(.value, in: mode) {
                        visible(under: .enabled("hex"), in: mode) { AtomicComponent(string: offsetValue.hexadecimal, type: .comment) }
                        visible(under: .disabled("hex"), in: mode) { AtomicComponent(string: offsetValue.decimal, type: .comment) }
                    }
                    BreakLine()
                    Indent(level: level)
                }
            }
            if !member.layoutLines.isEmpty {
                layoutBlock(member.layoutLines, level: level, mode: mode)
            }
            for note in member.notes {
                annotated(.note, in: mode) {
                    if let hexOnlyPrefix = note.hexOnlyPrefix {
                        visible(under: .enabled("hex"), in: mode) {
                            commentLine([(.qualifier, hexOnlyPrefix)], in: mode)
                            Space()
                        }
                    }
                    commentLine([(.text, note.text)], in: mode)
                    BreakLine()
                    Indent(level: level)
                }
            }
            Keyword("var")
            Space()
            Variable(member.name)
            Standard(": Int")
        }
    }

    private static func render(_ definition: Definition, level: Int, mode: Mode) -> SemanticString {
        SemanticString {
            DeclarationBlock(level: level) {
                Keyword("struct")
                Space()
                TypeDeclaration(kind: .struct, definition.name)
            } body: {
                for nestedDefinition in definition.nestedDefinitions {
                    NestedDeclaration {
                        if mode.marksDefinitions {
                            DefinitionRegion(nestedDefinition.name, content: render(nestedDefinition, level: level + 1, mode: mode))
                        } else {
                            render(nestedDefinition, level: level + 1, mode: mode)
                        }
                    }
                }
                if !definition.nestedDefinitions.isEmpty && !definition.members.isEmpty {
                    BreakLine()
                }
                MemberList(level: level) {
                    for member in definition.members {
                        memberRow(member, level: level, mode: mode)
                    }
                }
            }
        }
    }

    /// The text of `range` in `text`.
    private static func text(of utf8Offset: UInt32, length utf8Length: UInt32, in text: FrozenSemanticString) -> String {
        let bytes = Array(text.text.utf8)
        return String(decoding: bytes[Int(utf8Offset) ..< Int(utf8Offset + utf8Length)], as: UTF8.self)
    }

    // MARK: - Marking changes nothing

    @Test("a region and a segment print their content unchanged and keep its element structure")
    func regionsAndSegmentsAreTransparent() {
        let plain = SemanticString {
            MemberList(level: 1) {
                Standard("first")
                Comment("Address: 0x10")
                Standard("third")
            }
        }
        let marked = SemanticString {
            MemberList(level: 1) {
                Standard("first")
                AnnotationRegion(.memberAddress) {
                    Comment("Address: 0x10")
                    AnnotationSegment(.text) {
                        Standard("third")
                    }
                }
            }
        }
        #expect(marked.string == plain.string)
        #expect(marked.components.map(\.string) == plain.components.map(\.string))
        #expect(marked.components.map(\.type) == plain.components.map(\.type))
    }

    @Test("an annotated atom prints as one element of its own type, whatever its pieces were")
    func annotatedAtomIsOneElementOfItsType() throws {
        let plain = SemanticString {
            MemberList(level: 1) {
                Comment("Address: 0x135DC")
                Keyword("let")
            }
        }
        let marked = SemanticString {
            MemberList(level: 1) {
                AnnotatedAtom(type: .comment, identifier: "$s4Main3FooV") {
                    AnnotationSegment(.marker) { "// " }
                    AnnotationSegment(.label) { Keyword("Address") }
                    ": "
                    AnnotationSegment(.value) { Numeric("0x135DC") }
                }
                Keyword("let")
            }
        }
        #expect(marked.string == plain.string)
        let pieces = marked.components.filter { $0.type == .comment }
        #expect(pieces.map(\.string) == ["// ", "Address", ": ", "0x135DC"])
        for piece in pieces {
            #expect(AnnotationTag.decompose(piece.identifier).original == "$s4Main3FooV")
        }
    }

    @Test("an async-built region, segment or annotated atom is the same as a sync-built one")
    func asyncBuildersMatchSyncBuilders() async throws {
        @Sendable func asyncContent() async throws -> SemanticString {
            SemanticString {
                Keyword("let")
                Space()
                Variable("value")
            }
        }
        let syncContent = SemanticString {
            Keyword("let")
            Space()
            Variable("value")
        }
        let asyncRegion = try await AnnotationRegion(.note) { try await asyncContent() }
        #expect(asyncRegion.buildComponents() == AnnotationRegion(.note, content: syncContent).buildComponents())
        let asyncSegment = try await AnnotationSegment(.text) { try await asyncContent() }
        #expect(asyncSegment.buildComponents() == AnnotationSegment(.text, content: syncContent).buildComponents())
        let asyncAtom = try await AnnotatedAtom(type: .comment) { try await asyncContent() }
        #expect(asyncAtom.buildComponents() == AnnotatedAtom(type: .comment, content: syncContent).buildComponents())
    }

    @Test("a region, segment or annotated atom holding nothing records nothing")
    func emptyContentRecordsNothing() {
        let marked = SemanticString {
            AnnotationRegion(.note) {}
            AnnotationSegment(.text) { Standard("") }
            AnnotatedAtom(type: .comment) {}
        }
        #expect(marked.isEmpty)
        #expect(marked.elements.isEmpty)
    }

    // MARK: - Encoding

    @Test("the marks round-trip, and stay inside a visibility tag and definition identities")
    func marksRoundTripInsideTheOtherEncodings() throws {
        let marks = AnnotationTag.Marks(
            nonSpaceByteCount: 70000,
            piece: .anchor,
            regions: [.init(name: "fieldOffset", phase: .leading), .init(name: "fieldLayoutNode", phase: .following)],
            segment: .init(name: "treePrefix", phase: .unanchored)
        )
        let annotated = AnnotationTag.Decomposition(outerPart: "", marks: marks, original: "$sSiD").identifier(with: marks)
        let decomposed = AnnotationTag.decompose(annotated)
        #expect(decomposed.marks == marks)
        #expect(decomposed.original == "$sSiD")
        #expect(decomposed.outerPart.isEmpty)

        // A definition identity and a visibility tag added afterwards go
        // outside, and both read the annotation fields as part of the
        // original identifier.
        let withIdentity = DefinitionTag.adding("Owner", to: annotated)
        let withVisibility = VisibilityTag.adding(VisibilityTag.encode(.enabled("comments")), to: withIdentity)
        #expect(VisibilityTag.isTag(withVisibility))
        #expect(VisibilityTag.decode(withVisibility)?.originalIdentifier == withIdentity)
        #expect(DefinitionTag.decompose(withVisibility).original[...] == annotated?[...])
        let decomposedWithBoth = AnnotationTag.decompose(withVisibility)
        #expect(decomposedWithBoth.marks == marks)
        #expect(decomposedWithBoth.original == "$sSiD")
        #expect(decomposedWithBoth.identifier(with: .init()) == VisibilityTag.adding(VisibilityTag.encode(.enabled("comments")), to: DefinitionTag.adding("Owner", to: "$sSiD")))

        // An identifier with no fields, or malformed ones, carries none.
        #expect(AnnotationTag.decompose("$sSiD").marks.isEmpty)
        #expect(AnnotationTag.decompose("\u{10}\u{11}\u{10}$sSiD").marks.isEmpty)
        #expect(AnnotationTag.decompose(nil).identifier(with: .init()) == nil)
    }

    @Test("the three kinds of region nest in any order with the same atoms")
    func nestingOrderDoesNotMatter() {
        let content = SemanticString {
            Comment("Address: 0x10")
            Space()
            AtomicComponent(string: "Int", type: .type(.struct, .name), identifier: "$sSiD")
        }
        func wrapped(_ order: [Int]) -> SemanticString {
            order.reduce(content) { inner, layer in
                switch layer {
                case 0: SemanticString { VisibilityRegion(.enabled("comments"), content: inner) }
                case 1: SemanticString { DefinitionRegion("Owner", content: inner) }
                default: SemanticString { AnnotationRegion(.memberAddress, content: inner) }
                }
            }
        }
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        let reference = wrapped(orders[0]).components
        for order in orders.dropFirst() {
            #expect(wrapped(order).components == reference, "\(order)")
        }
    }

    @Test("a region covering every piece of an annotated atom marks it the same from outside or inside")
    func regionAroundOrInsideAnAnnotatedAtom() {
        let outside = SemanticString {
            AnnotationRegion(.memberAddress) {
                AnnotatedAtom(type: .comment) {
                    AnnotationSegment(.marker) { "// " }
                    AnnotationSegment(.value) { "0x10" }
                }
            }
        }
        let inside = SemanticString {
            AnnotatedAtom(type: .comment) {
                AnnotationRegion(.memberAddress) {
                    AnnotationSegment(.marker) { "// " }
                    AnnotationSegment(.value) { "0x10" }
                }
            }
        }
        #expect(outside.components == inside.components)
    }

    // MARK: - Phases

    @Test("the anchor is the first atom with a byte other than a space that is visible whenever the region is")
    func anchorSelection() {
        func phases(@SemanticStringBuilder _ content: () -> SemanticString) -> [AnnotationTag.Phase] {
            AnnotationTag.phases(of: content().components[...])
        }
        #expect(phases { Indent(level: 1); Comment("a"); BreakLine() } == [.leading, .anchor, .following])
        #expect(phases { BreakLine(); Comment("a") } == [.anchor, .following])
        // Visible only under a condition the rest does not carry: not the
        // anchor, whatever its text.
        #expect(phases {
            Indent(level: 1)
            VisibilityRegion(.enabled("hex")) { Numeric("0x8") }
            Comment("a")
        } == [.leading, .leading, .anchor])
        // A condition every atom carries does not disqualify.
        #expect(phases {
            VisibilityRegion(.enabled("comments")) {
                Indent(level: 1)
                Comment("a")
                VisibilityRegion(.enabled("hex")) { Numeric("0x8") }
            }
        } == [.leading, .anchor, .following])
        // Nothing qualifies: only spaces, or only alternatives.
        #expect(phases { Indent(level: 1); Space() } == [.unanchored, .unanchored])
        #expect(phases {
            VisibilityRegion(.enabled("hex")) { Numeric("0x8") }
            VisibilityRegion(.disabled("hex")) { Numeric("8") }
        } == [.unanchored, .unanchored])
    }

    @Test("an atom over 65535 UTF-8 bytes records how many of its bytes are not spaces")
    func longAtomsRecordTheirNonSpaceByteCount() throws {
        let longText = String(repeating: "ab ", count: 30000)
        let marked = SemanticString {
            AnnotationRegion(.note) {
                Comment("short")
                Standard(longText)
            }
        }
        let identifiers = marked.components.map { AnnotationTag.decompose($0.identifier).marks.nonSpaceByteCount }
        #expect(identifiers == [nil, 60000])
    }

    // MARK: - Preconditions

    @Test("an empty kind or role traps")
    func emptyNamesTrap() async {
        await #expect(processExitsWith: .failure) {
            _ = AnnotationRegion.Kind("")
        }
        await #expect(processExitsWith: .failure) {
            _ = AnnotationSegment.Role("")
        }
    }

    @Test("a kind or role with a control character traps")
    func controlCharactersInNamesTrap() async {
        await #expect(processExitsWith: .failure) {
            _ = AnnotationRegion.Kind("member\u{10}Address")
        }
        await #expect(processExitsWith: .failure) {
            _ = AnnotationSegment.Role("va\nlue")
        }
    }

    @Test("a segment holding another segment or an annotation region traps")
    func segmentsAreLeaves() async {
        await #expect(processExitsWith: .failure) {
            _ = SemanticString {
                AnnotationSegment(.text) {
                    AnnotationSegment(.value) { "0x10" }
                }
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = SemanticString {
                AnnotationSegment(.text) {
                    AnnotationRegion(.note) { "note" }
                }
            }
        }
    }

    @Test("an annotated atom traps on pieces with an identifier, a visibility condition or a definition identity, and on another annotated atom")
    func annotatedAtomPiecesCarryNothingOfTheirOwn() async {
        await #expect(processExitsWith: .failure) {
            _ = SemanticString {
                AnnotatedAtom(type: .comment) {
                    AtomicComponent(string: "Int", type: .type(.struct, .name), identifier: "$sSiD")
                }
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = SemanticString {
                AnnotatedAtom(type: .comment) {
                    VisibilityRegion(.enabled("hex")) { "0x8" }
                }
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = SemanticString {
                AnnotatedAtom(type: .comment) {
                    DefinitionRegion("Owner") { "owned" }
                }
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = SemanticString {
                AnnotatedAtom(type: .comment) {
                    AnnotatedAtom(type: .comment) { "inner" }
                }
            }
        }
    }

    @Test("marks added around an annotated atom afterwards go on every piece alike")
    func marksAroundAnAnnotatedAtom() {
        let plainAtom = SemanticString {
            AnnotatedAtom(type: .comment) {
                AnnotationSegment(.marker) { "// " }
                AnnotationSegment(.value) { "0x10" }
            }
        }
        var streamed = plainAtom
        streamed.markAtoms(from: 0, visibleUnder: .enabled("comments"))
        let wrapped = SemanticString {
            VisibilityRegion(.enabled("comments"), content: plainAtom)
        }
        #expect(streamed.components == wrapped.components)
        for piece in wrapped.components {
            #expect(VisibilityTag.isTag(piece.identifier ?? ""))
            #expect(AnnotationTag.decompose(piece.identifier).marks.piece != nil)
        }
    }

    // MARK: - Separating

    @Test("a string without annotations comes back unchanged, with an empty table")
    func separationWithoutAnnotations() {
        let plain = Self.render(Self.sample, level: 1, mode: Mode(marksAnnotations: false)).frozen()
        let separation = plain.separatingAnnotationRegions()
        #expect(separation.text == plain)
        #expect(separation.annotations.isEmpty)
    }

    @Test("separating gives back the string printed without annotations, span for span", arguments: [nil, ["addresses", "expandedOffsets", "hex"], []] as [Set<String>?])
    func separationRestoresThePlainPrint(enabledOptions: Set<String>?) {
        let marked = Self.render(Self.sample, level: 1, mode: Mode(marksAnnotations: true, enabledOptions: enabledOptions)).frozen()
        let plain = Self.render(Self.sample, level: 1, mode: Mode(marksAnnotations: false, enabledOptions: enabledOptions)).frozen()
        #expect(marked.text == plain.text)
        #expect(marked.spans.count > plain.spans.count)
        let separated = marked.separatingAnnotationRegions().text
        #expect(separated == plain)
        #expect(separated.spans.map(\.length) == plain.spans.map(\.length))
    }

    @Test("the table records each region's kind and range, and each segment's role, range and region")
    func tableOfOneComment() {
        let marked = SemanticString {
            AnnotationRegion(.memberAddress) {
                AnnotatedAtom(type: .comment) {
                    AnnotationSegment(.marker) { "// " }
                    AnnotationSegment(.label) { "Address" }
                    AnnotationSegment(.separator) { ": " }
                    AnnotationSegment(.value) { "0x135DC" }
                }
            }
        }.frozen()
        let separation = marked.separatingAnnotationRegions()
        #expect(separation.text == Comment("Address: 0x135DC").asSemanticString().frozen())
        #expect(separation.annotations.regions == [.init(kind: .memberAddress, utf8Offset: 0, utf8Length: 19, depth: 0, enclosingRegionIndex: nil)])
        #expect(separation.annotations.segments == [
            .init(role: .marker, utf8Offset: 0, utf8Length: 3, regionIndex: 0),
            .init(role: .label, utf8Offset: 3, utf8Length: 7, regionIndex: 0),
            .init(role: .separator, utf8Offset: 10, utf8Length: 2, regionIndex: 0),
            .init(role: .value, utf8Offset: 12, utf8Length: 7, regionIndex: 0),
        ])
        #expect(separation.annotations.regions(ofKind: .memberAddress).count == 1)
        #expect(separation.annotations.segments(inRegionAt: 0).count == 4)
        #expect(separation.annotations.segments(inRegionAt: nil).isEmpty)
    }

    @Test("regions of one kind nest into a tree, each with its depth and the region enclosing it")
    func nestedRegionsOfOneKind() {
        let marked = SemanticString {
            AnnotationRegion(.fieldOffset) {
                AnnotatedAtom(type: .comment) {
                    AnnotationSegment(.marker) { "// " }
                    AnnotationSegment(.label) { "Field offset" }
                    AnnotationSegment(.separator) { ": " }
                    AnnotationSegment(.value) { "0x8" }
                }
                AnnotationRegion(.fieldLayoutNode) {
                    BreakLine()
                    AnnotatedAtom(type: .comment) {
                        AnnotationSegment(.marker) { "// " }
                        AnnotationSegment(.treePrefix) { "├── " }
                        AnnotationSegment(.name) { "a" }
                    }
                    AnnotationRegion(.fieldLayoutNode) {
                        BreakLine()
                        AnnotatedAtom(type: .comment) {
                            AnnotationSegment(.marker) { "// " }
                            AnnotationSegment(.treePrefix) { "│   └── " }
                            AnnotationSegment(.name) { "x" }
                        }
                    }
                }
                AnnotationRegion(.fieldLayoutNode) {
                    BreakLine()
                    AnnotatedAtom(type: .comment) {
                        AnnotationSegment(.marker) { "// " }
                        AnnotationSegment(.treePrefix) { "└── " }
                        AnnotationSegment(.name) { "b" }
                    }
                }
                BreakLine()
            }
        }.frozen()
        let separation = marked.separatingAnnotationRegions()
        #expect(separation.text == SemanticString {
            Comment("Field offset: 0x8")
            BreakLine()
            Comment("├── a")
            BreakLine()
            Comment("│   └── x")
            BreakLine()
            Comment("└── b")
            BreakLine()
        }.frozen())
        // "// Field offset: 0x8" is bytes 0 ..< 20, then each line starts one
        // byte after the line break: "// ├── a" 21 ..< 35, "// │   └── x"
        // 36 ..< 56, "// └── b" 57 ..< 71. The line breaks at a region's ends
        // are trimmed.
        #expect(separation.annotations.regions == [
            .init(kind: .fieldOffset, utf8Offset: 0, utf8Length: 71, depth: 0, enclosingRegionIndex: nil),
            .init(kind: .fieldLayoutNode, utf8Offset: 21, utf8Length: 35, depth: 1, enclosingRegionIndex: 0),
            .init(kind: .fieldLayoutNode, utf8Offset: 36, utf8Length: 20, depth: 2, enclosingRegionIndex: 1),
            .init(kind: .fieldLayoutNode, utf8Offset: 57, utf8Length: 14, depth: 1, enclosingRegionIndex: 0),
        ])
        #expect(separation.annotations.segments.map(\.role) == [
            .marker, .label, .separator, .value,
            .marker, .treePrefix, .name,
            .marker, .treePrefix, .name,
            .marker, .treePrefix, .name,
        ])
        #expect(separation.annotations.segments.map(\.regionIndex) == [0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3])
        #expect(separation.annotations.segments.map(\.utf8Offset) == [0, 3, 15, 17, 21, 24, 34, 36, 39, 55, 57, 60, 70])
    }

    @Test("regions, segments and annotated atoms of one kind directly next to each other read back as several")
    func adjacentInstancesStayApart() {
        let marked = SemanticString {
            AnnotationRegion(.note) { Comment("same") }
            AnnotationRegion(.note) { Comment("same") }
            AnnotationRegion(.note) {
                AnnotatedAtom(type: .comment) {
                    AnnotationSegment(.value) { "1" }
                    AnnotationSegment(.value) { "2" }
                }
                AnnotatedAtom(type: .comment) {
                    AnnotationSegment(.value) { "1" }
                    AnnotationSegment(.value) { "2" }
                }
            }
        }.frozen()
        let separation = marked.separatingAnnotationRegions()
        #expect(separation.text == SemanticString {
            Comment("same")
            Comment("same")
            AtomicComponent(string: "12", type: .comment)
            AtomicComponent(string: "12", type: .comment)
        }.frozen())
        #expect(separation.annotations.regions.map(\.utf8Offset) == [0, 7, 14])
        #expect(separation.annotations.regions.map(\.utf8Length) == [7, 7, 4])
        #expect(separation.annotations.segments.map(\.utf8Offset) == [14, 15, 16, 17])
        #expect(separation.annotations.segments.map(\.utf8Length) == [1, 1, 1, 1])
        #expect(separation.annotations.segments.map(\.regionIndex) == [2, 2, 2, 2])
    }

    @Test("a region whose first atom is shown only under a condition still starts where it starts, right after another of its kind")
    func conditionalFirstAtomStartsItsRegion() {
        let marked = SemanticString {
            AnnotationRegion(.note) { Comment("a") }
            AnnotationRegion(.note) {
                VisibilityRegion(.enabled("hex")) { Comment("(hex)") }
                Comment("b")
            }
        }.frozen()
        let visibility = marked.separatingVisibilityRegions()
        let shown = visibility.text.separatingAnnotationRegions().annotations.regions
        #expect(shown.map(\.utf8Offset) == [0, 4])
        #expect(shown.map(\.utf8Length) == [4, 12])
        let projected = visibility.regions.projection(of: visibility.text) { _ in false }.text.separatingAnnotationRegions().annotations.regions
        #expect(projected.map(\.utf8Offset) == [0, 4])
        #expect(projected.map(\.utf8Length) == [4, 4])
    }

    @Test("a region spans what a container prints between its items")
    func regionSpansContainerDecorations() throws {
        let marked = SemanticString {
            MemberList(level: 1) {
                Standard("before")
                AnnotationRegion(.note) {
                    Standard("a")
                    Standard("b")
                }
                Standard("after")
            }
        }.frozen()
        let regions = marked.separatingAnnotationRegions().annotations.regions
        let region = try #require(regions.first)
        #expect(regions.count == 1)
        #expect(Self.text(of: region.utf8Offset, length: region.utf8Length, in: marked) == "a\n    b")
    }

    @Test("a region's range leaves out the whitespace at its ends that lies in no segment, and a region of nothing else is not recorded")
    func whitespaceAtRegionEndsIsTrimmed() {
        let marked = SemanticString {
            AnnotationRegion(.note) {
                Indent(level: 1)
                AnnotationSegment(.treePrefix) { "    " }
                Comment("x")
                BreakLine()
            }
            AnnotationRegion(.fieldOffset) {
                BreakLine()
                AnnotationRegion(.fieldLayoutNode) { Indent(level: 1) }
            }
            AnnotationRegion(.memberAddress) { Comment("y") }
        }.frozen()
        let annotations = marked.separatingAnnotationRegions().annotations
        #expect(annotations.regions == [
            .init(kind: .note, utf8Offset: 4, utf8Length: 8, depth: 0, enclosingRegionIndex: nil),
            .init(kind: .memberAddress, utf8Offset: 18, utf8Length: 4, depth: 0, enclosingRegionIndex: nil),
        ])
        #expect(annotations.segments == [.init(role: .treePrefix, utf8Offset: 4, utf8Length: 4, regionIndex: 0)])
    }

    @Test("the annotation, definition and visibility separations run in any order with the same results")
    func separationsCommute() {
        let marked = Self.render(Self.sample, level: 1, mode: Mode(marksAnnotations: true)).frozen()
        func separate(in order: [Int]) -> (text: FrozenSemanticString, visibility: VisibilityRegionTable, definitions: DefinitionRegionTable, annotations: AnnotationRegionTable) {
            var text = marked
            var visibility = VisibilityRegionTable.empty
            var definitions = DefinitionRegionTable.empty
            var annotations = AnnotationRegionTable.empty
            for step in order {
                switch step {
                case 0:
                    (text, visibility) = text.separatingVisibilityRegions()
                case 1:
                    (text, definitions) = text.separatingDefinitionRegions()
                default:
                    (text, annotations) = text.separatingAnnotationRegions()
                }
            }
            return (text, visibility, definitions, annotations)
        }
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        let reference = separate(in: orders[0])
        #expect(!reference.visibility.isEmpty)
        #expect(!reference.definitions.isEmpty)
        #expect(!reference.annotations.isEmpty)
        for order in orders.dropFirst() {
            let separation = separate(in: order)
            #expect(separation.text == reference.text, "\(order)")
            #expect(separation.visibility == reference.visibility, "\(order)")
            #expect(separation.definitions == reference.definitions, "\(order)")
            #expect(separation.annotations == reference.annotations, "\(order)")
        }
        let plain = Self.render(Self.sample, level: 1, mode: Mode(marksAnnotations: false, marksDefinitions: false)).frozen()
        #expect(reference.text == plain.separatingVisibilityRegions().text)
    }

    @Test("a nested definition taken out of its parent's print and de-indented is its own print, annotations included", arguments: [true, false])
    func takenOutDefinitionSeparatesLikeItsOwnPrint(marksVisibility: Bool) throws {
        let mode = Mode(marksAnnotations: true, enabledOptions: marksVisibility ? nil : Set(Self.options))
        let marked = Self.render(Self.sample, level: 1, mode: mode).frozen()
        let visibilitySeparated = marked.separatingVisibilityRegions().text
        let regions = marked.separatingDefinitionRegions().definitions.regions
        #expect(regions.count == 2)
        for region in regions {
            let definition = try #require(Self.sample.definition(named: region.identity))
            let ownPrint = Self.render(definition, level: 1, mode: mode).frozen()
            let takenOut = try #require(marked.content(ofDefinitionRegion: region).removingIndentation(levels: region.depth + 1))
            #expect(takenOut == ownPrint, "\(region.identity)")
            let ownSeparation = ownPrint.separatingAnnotationRegions()
            #expect(!ownSeparation.annotations.isEmpty)
            #expect(takenOut.separatingAnnotationRegions().annotations == ownSeparation.annotations, "\(region.identity)")
            #expect(takenOut.separatingAnnotationRegions().text == ownSeparation.text, "\(region.identity)")

            // The same region read off the visibility-separated text.
            let takenOutOfSeparated = try #require(visibilitySeparated.content(ofDefinitionRegion: region).removingIndentation(levels: region.depth + 1))
            #expect(takenOutOfSeparated.separatingAnnotationRegions().annotations == ownSeparation.annotations, "\(region.identity)")
        }
    }

    static let optionSubsets: [Set<String>] = (0 ..< 8).map { mask in
        Set(["addresses", "expandedOffsets", "hex"].enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
    }

    @Test("a projection of the full print, separated, reads like printing with its options and separating", arguments: AnnotationRegionTests.optionSubsets)
    func projectionSeparatesLikePrintingWithItsOptions(enabledOptions: Set<String>) {
        let marked = Self.render(Self.sample, level: 1, mode: Mode(marksAnnotations: true)).frozen()
        let visibility = marked.separatingVisibilityRegions()
        let projection = visibility.regions.projection(of: visibility.text) { enabledOptions.contains($0) }
        let projected = projection.text.separatingAnnotationRegions()
        let direct = Self.render(Self.sample, level: 1, mode: Mode(marksAnnotations: true, enabledOptions: enabledOptions)).frozen().separatingAnnotationRegions()
        #expect(projected.text == direct.text)
        #expect(projected.annotations == direct.annotations)
        #expect(!direct.annotations.isEmpty)
    }

    // MARK: - Long atoms

    @Test("an annotated atom over 65535 UTF-8 bytes merges back into the spans frozen() splits it into")
    func longAnnotatedAtomsMergeIntoFrozenSpans() {
        let longText = String(repeating: "é ab", count: 20000)
        let marked = SemanticString {
            AnnotationRegion(.note) {
                AnnotatedAtom(type: .comment) {
                    AnnotationSegment(.marker) { "// " }
                    AnnotationSegment(.text) { longText }
                    " end"
                }
            }
        }.frozen()
        let plain = SemanticString { AtomicComponent(string: "// " + longText + " end", type: .comment) }.frozen()
        #expect(plain.spans.count > 1)
        let separation = marked.separatingAnnotationRegions()
        #expect(separation.text == plain)
        #expect(separation.text.spans.map(\.length) == plain.spans.map(\.length))
        #expect(separation.annotations.segments.map(\.utf8Length) == [3, UInt32(longText.utf8.count)])
        #expect(separation.annotations.regions.map(\.utf8Length) == [UInt32(plain.text.utf8.count)])
    }

    @Test("the spans of a long anchor are told apart from the identical anchor of the region right after it, also after removing indentation")
    func longAnchorsStayApart() throws {
        let longText = String(repeating: "    xyz\n", count: 12000)
        let marked = SemanticString {
            AnnotationRegion(.note) { AtomicComponent(string: longText, type: .comment) }
            AnnotationRegion(.note) { AtomicComponent(string: longText, type: .comment) }
        }.frozen()
        let byteCount = UInt32(longText.utf8.count)
        let regions = marked.separatingAnnotationRegions().annotations.regions
        #expect(regions.map(\.utf8Offset) == [0, byteCount])
        #expect(regions.map(\.utf8Length) == [byteCount, byteCount])

        let deindented = try #require(marked.removingIndentation(levels: 1))
        let deindentedText = String(repeating: "xyz\n", count: 12000)
        let direct = SemanticString {
            AnnotationRegion(.note) { AtomicComponent(string: deindentedText, type: .comment) }
            AnnotationRegion(.note) { AtomicComponent(string: deindentedText, type: .comment) }
        }.frozen()
        #expect(deindented.separatingAnnotationRegions().annotations == direct.separatingAnnotationRegions().annotations)
        #expect(deindented.separatingAnnotationRegions().text.string == direct.string)
    }

    // MARK: - Degraded input

    @Test("pieces that end up with different marks stay apart rather than merge into a wrong atom")
    func disagreeingPiecesStayApart() {
        var streamed = SemanticString {
            Keyword("let")
            AnnotatedAtom(type: .comment) {
                AnnotationSegment(.marker) { "// " }
                AnnotationSegment(.text) { "abc" }
            }
        }
        // A streaming mark starting at the second piece, which no printer
        // does: the two pieces now disagree about the atom's identifier.
        streamed.markAtoms(from: 2, visibleUnder: .enabled("comments"))
        let separated = streamed.frozen().separatingAnnotationRegions().text
        #expect(separated.components.map(\.string) == ["let", "// ", "abc"])
    }

    @Test("two unanchored segments of one role directly next to each other read back as one, a known limitation")
    func adjacentUnanchoredInstancesMerge() {
        let marked = SemanticString {
            AnnotationSegment(.treePrefix) { "    " }
            AnnotationSegment(.treePrefix) { "    " }
            AnnotationSegment(.treePrefix) { "│   " }
        }.frozen()
        let segments = marked.separatingAnnotationRegions().annotations.segments
        #expect(segments.map(\.utf8Offset) == [0, 8])
        #expect(segments.map(\.utf8Length) == [8, 6])
    }

    @Test("a hand-built identifier is read without trapping: stray characters in a kind are kept, malformed marks read as none")
    func handBuiltIdentifiersAreReadQuietly() {
        let frozen = FrozenSemanticString(
            text: "abcd",
            spans: [
                .init(length: 2, typeCode: SemanticType.comment.frozenTypeCode, identifierIndex: 1),
                .init(length: 2, typeCode: SemanticType.comment.frozenTypeCode, identifierIndex: 2),
            ],
            identifierTable: ["\u{10}\u{11}*odd\nkind\u{10}", "\u{10}\u{11}\u{10}plain"]
        )
        let separation = frozen.separatingAnnotationRegions()
        #expect(separation.annotations.regions.map(\.kind.rawValue) == ["odd\nkind"])
        #expect(separation.text.components.map(\.identifier) == [nil, "\u{10}\u{11}\u{10}plain"])
    }

    @Test("separating a value whose spans violate the unchecked initializer's invariants traps")
    func malformedSpansTrap() async {
        await #expect(processExitsWith: .failure) {
            _ = FrozenSemanticString(
                text: "ab",
                spans: [.init(length: 0, typeCode: 0, identifierIndex: 1), .init(length: 2, typeCode: 0, identifierIndex: 1)],
                identifierTable: ["\u{10}\u{11}*note\u{10}"]
            ).separatingAnnotationRegions()
        }
        await #expect(processExitsWith: .failure) {
            _ = FrozenSemanticString(
                text: "ab",
                spans: [.init(length: 3, typeCode: 0, identifierIndex: 1)],
                identifierTable: ["\u{10}\u{11}*note\u{10}"]
            ).separatingAnnotationRegions()
        }
        await #expect(processExitsWith: .failure) {
            _ = FrozenSemanticString(
                text: "abc",
                spans: [.init(length: 2, typeCode: 0, identifierIndex: 1)],
                identifierTable: ["\u{10}\u{11}*note\u{10}"]
            ).separatingAnnotationRegions()
        }
    }
}
