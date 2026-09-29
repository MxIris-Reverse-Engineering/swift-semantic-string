import Testing
@testable import Semantic

/// Tests for `VisibilityRegion`, `VisibilityCondition`, the region table and
/// the projection. The contract they pin: wrapping content in regions never
/// changes what is printed; separating the regions gives back exactly the
/// string printed without them; and projecting to any option values gives
/// exactly what printing only the visible content gives — for the library's
/// containers, as long as a container whose items can all be hidden sits in
/// a region of its own.
@Suite("VisibilityRegion")
struct VisibilityRegionTests {
    // MARK: - Conditions

    @Test("conditions are normalized: order, duplicates, contradictions and subsumed alternatives do not matter")
    func conditionNormalization() {
        let enabledA = VisibilityCondition.enabled("a")
        #expect(VisibilityCondition.any([enabledA, .all([.enabled("a"), .enabled("b")])]) == enabledA)
        #expect(VisibilityCondition.all([.enabled("a"), .disabled("b")]) == VisibilityCondition.all([.disabled("b"), .enabled("a"), .enabled("a")]))
        #expect(VisibilityCondition.all([.enabled("a"), .disabled("a")]).isNever)
        #expect(VisibilityCondition.all([]).isAlways)
        #expect(VisibilityCondition.any([]).isNever)
        #expect(VisibilityCondition.any([.never, .always]).isAlways)
        #expect(!enabledA.isAlways && !enabledA.isNever)
    }

    @Test("a condition holds when every requirement of one alternative holds")
    func conditionEvaluation() {
        let condition = VisibilityCondition.any([.all([.enabled("a"), .disabled("b")]), .enabled("c")])
        for assignment in Self.assignments(of: ["a", "b", "c"]) {
            let expected = (assignment.contains("a") && !assignment.contains("b")) || assignment.contains("c")
            #expect(condition.isSatisfied { assignment.contains($0) } == expected, "\(assignment.sorted())")
        }
        #expect(VisibilityCondition.always.isSatisfied { _ in false })
        #expect(!VisibilityCondition.never.isSatisfied { _ in true })
    }

    @Test("conditions survive the identifier encoding")
    func conditionEncodingRoundTrip() {
        let conditions: [VisibilityCondition] = [
            .enabled("objc.addIvarOffsetComments"),
            .disabled("objc.stripOverrides"),
            .all([.disabled("objc.stripOverrides"), .disabled("objc.stripSynthesizedMethods")]),
            .any([.all([.enabled("a"), .disabled("b")]), .enabled("c")]),
            .never,
        ]
        for condition in conditions {
            #expect(VisibilityTag.decodeCondition(Substring(VisibilityTag.encode(condition))) == condition)
        }
        let nested = VisibilityTag.adding(VisibilityTag.encode(.enabled("outer")), to: VisibilityTag.adding(VisibilityTag.encode(.disabled("inner")), to: "$s4Main3FooV"))
        let decoded = VisibilityTag.decode(nested)
        #expect(decoded?.conditions == [.enabled("outer"), .disabled("inner")])
        #expect(decoded?.originalIdentifier == "$s4Main3FooV")
        #expect(VisibilityTag.decode("$s4Main3FooV") == nil)
    }

    // MARK: - Regions change nothing

    @Test("a region prints its content unchanged and keeps its element structure")
    func regionIsTransparent() {
        let plain = SemanticString {
            MemberList(level: 1) {
                Standard("first")
                Standard("second")
                Standard("third")
            }
        }
        let regioned = SemanticString {
            MemberList(level: 1) {
                Standard("first")
                VisibilityRegion(.enabled("option")) {
                    Standard("second")
                    Standard("third")
                }
            }
        }
        #expect(regioned.string == plain.string)
        #expect(regioned.components.map(\.string) == plain.components.map(\.string))
        #expect(VisibilityRegion(.always) { Keyword("same") }.buildComponents() == [AtomicComponent(string: "same", type: .keyword)])
    }

    @Test("separating the regions gives back the string printed without them, identifiers included")
    func separationRestoresThePlainPrint() {
        let typeReference = AtomicComponent(string: "Foo", type: .type(.struct, .name), identifier: "$s4Main3FooV")
        func build(marked: Bool) -> SemanticString {
            SemanticString {
                Keyword("struct")
                Space()
                TypeDeclaration(kind: .struct, "Bar")
                MemberList(level: 1) {
                    SemanticString {
                        Keyword("var")
                        Space()
                        Variable("x")
                        Standard(": ")
                        typeReference
                    }
                    if marked {
                        VisibilityRegion(.enabled("comments")) {
                            VisibilityRegion(.disabled("strip")) {
                                SemanticString {
                                    Comment("offset: 0x10")
                                    Space()
                                    typeReference
                                }
                            }
                        }
                    } else {
                        SemanticString {
                            Comment("offset: 0x10")
                            Space()
                            typeReference
                        }
                    }
                }
            }
        }
        let separated = build(marked: true).frozen().separatingVisibilityRegions()
        #expect(separated.text == build(marked: false).frozen())
        // The member's own atoms carry both nested conditions; the line break
        // and indentation the member list put in front of it carry their
        // conjunction. Both are one condition and one run.
        #expect(separated.regions.conditions == [.all([.enabled("comments"), .disabled("strip")])])
        #expect(separated.regions.regions.count == 1)

        let unmarked = build(marked: false).frozen()
        let unmarkedSeparation = unmarked.separatingVisibilityRegions()
        #expect(unmarkedSeparation.text == unmarked)
        #expect(unmarkedSeparation.regions.isEmpty)
    }

    // MARK: - Projection equals printing the visible content

    /// One printable item: its text and the condition it is visible under.
    private struct Item {
        let text: String
        let condition: VisibilityCondition
    }

    private static let optionNames = ["a", "b", "c"]

    private static func assignments(of options: [String]) -> [Set<String>] {
        (0 ..< (1 << options.count)).map { mask in
            Set(options.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
        }
    }

    private static func randomCondition(using generator: inout SplitMix64) -> VisibilityCondition {
        switch generator.next() % 6 {
        case 0: return .always
        case 1: return .enabled(optionNames[Int(generator.next() % 3)])
        case 2: return .disabled(optionNames[Int(generator.next() % 3)])
        case 3: return .all([.disabled(optionNames[Int(generator.next() % 3)]), .disabled(optionNames[Int(generator.next() % 3)])])
        case 4: return .any([.enabled(optionNames[Int(generator.next() % 3)]), .disabled(optionNames[Int(generator.next() % 3)])])
        default: return .enabled(optionNames[Int(generator.next() % 3)])
        }
    }

    private static func randomItems(count: Int, prefix: String, using generator: inout SplitMix64) -> [Item] {
        (0 ..< count).map { Item(text: "\(prefix)\($0)", condition: randomCondition(using: &generator)) }
    }

    /// Asserts that `render(nil)` — everything, marked — projected to every
    /// option value equals `render(values)` — only what is visible, unmarked.
    private static func expectProjectionMatches(
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        render: (_ visibleUnder: Set<String>?) -> SemanticString
    ) {
        let separated = render(nil).frozen().separatingVisibilityRegions()
        for assignment in assignments(of: optionNames) {
            let projection = separated.regions.projection(of: separated.text) { assignment.contains($0) }
            let expected = render(assignment).frozen()
            #expect(projection.text == expected, "\(label) under \(assignment.sorted()):\n\(projection.text.string)\n---\n\(expected.string)", sourceLocation: sourceLocation)
        }
    }

    /// `item` as a region when marking, as itself when visible, or nothing.
    @SemanticStringBuilder
    private static func emit(_ item: Item, visibleUnder assignment: Set<String>?, @SemanticStringBuilder content: () -> SemanticString) -> SemanticString {
        if let assignment {
            if item.condition.isSatisfied(where: { assignment.contains($0) }) {
                content()
            }
        } else {
            VisibilityRegion(item.condition, content: content())
        }
    }

    @Test("member lists, with some or all members hidden, alone or inside a region of their own", arguments: 0 ..< 40)
    func memberListProjection(seed: Int) {
        var generator = SplitMix64(seed: UInt64(seed))
        let items = Self.randomItems(count: Int(generator.next() % 5) + 1, prefix: "member", using: &generator)
        let whole = Item(text: "", condition: seed % 3 == 0 ? Self.randomCondition(using: &generator) : .always)
        Self.expectProjectionMatches("MemberList") { assignment in
            SemanticString {
                Keyword("@interface")
                Space()
                TypeDeclaration(kind: .class, "Sample")
                Self.emit(whole, visibleUnder: assignment) {
                    Joined {
                        MemberList(level: 1) {
                            for item in items {
                                Self.emit(item, visibleUnder: assignment) { Variable(item.text); Standard(";") }
                            }
                        }
                    } prefix: {
                        Space()
                        Standard("{")
                    } suffix: {
                        Standard("}")
                    }
                }
                BreakLine()
                Keyword("@end")
            }
        }
    }

    @Test("rows of annotation comments above a declaration that always shows", arguments: 0 ..< 40)
    func rowsProjection(seed: Int) {
        var generator = SplitMix64(seed: UInt64(seed))
        let members = (0 ..< Int(generator.next() % 3) + 1).map { memberIndex in
            (declaration: "func member\(memberIndex)()", comments: Self.randomItems(count: Int(generator.next() % 4), prefix: "// comment \(memberIndex).", using: &generator))
        }
        Self.expectProjectionMatches("Rows") { assignment in
            SemanticString {
                DeclarationBlock(level: 1) {
                    Keyword("struct")
                    Space()
                    TypeDeclaration(kind: .struct, "Sample")
                } body: {
                    MemberList(level: 1) {
                        for member in members {
                            Rows(level: 1) {
                                for comment in member.comments {
                                    Self.emit(comment, visibleUnder: assignment) { Comment(comment.text) }
                                }
                                Standard(member.declaration)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("block lists and trailing comments inside an interface body", arguments: 0 ..< 40)
    func blockListProjection(seed: Int) {
        var generator = SplitMix64(seed: UInt64(seed))
        let groups = (0 ..< 3).map { groupIndex in
            Self.randomItems(count: Int(generator.next() % 3), prefix: "- (void)method\(groupIndex)_", using: &generator)
        }
        let trailingComment = Self.randomCondition(using: &generator)
        let separatedByEmptyLine = seed % 2 == 0
        Self.expectProjectionMatches("BlockList") { assignment in
            SemanticString {
                Keyword("@interface")
                Space()
                TypeDeclaration(kind: .class, "Sample")
                BreakLine()
                Joined(suffix: BreakLine()) {
                    for group in groups {
                        BlockList {
                            for item in group {
                                Self.emit(item, visibleUnder: assignment) {
                                    Standard(item.text + ";")
                                    Self.emit(Item(text: "", condition: trailingComment), visibleUnder: assignment) {
                                        Space()
                                        Comment("IMP: 0x1")
                                    }
                                }
                            }
                        }
                        .separatedByEmptyLine(separatedByEmptyLine)
                    }
                }
                Keyword("@end")
            }
        }
    }

    @Test("sections with headers joined by blank lines, as in an Objective-C protocol", arguments: 0 ..< 40)
    func sectionsProjection(seed: Int) {
        var generator = SplitMix64(seed: UInt64(seed))
        let required = Self.randomItems(count: Int(generator.next() % 3), prefix: "- (void)required", using: &generator)
        let optional = Self.randomItems(count: Int(generator.next() % 3), prefix: "- (void)optional", using: &generator)
        Self.expectProjectionMatches("Sections") { assignment in
            SemanticString {
                Keyword("@protocol")
                Space()
                TypeDeclaration(kind: .protocol, "Sample")
                BreakLine()
                Joined(separator: BreakLine(), prefix: BreakLine(), suffix: BreakLine()) {
                    for (header, items) in [("@required", required), ("@optional", optional)] {
                        Joined {
                            BlockList {
                                for item in items {
                                    Self.emit(item, visibleUnder: assignment) { Standard(item.text + ";") }
                                }
                            }
                        } prefix: {
                            Keyword(header)
                            BreakLine()
                        }
                    }
                }
                Keyword("@end")
            }
        }
    }

    @Test("inline lists: separators, prefixes and suffixes between and around hidden items", arguments: 0 ..< 40)
    func inlineListProjection(seed: Int) {
        var generator = SplitMix64(seed: UInt64(seed))
        let conformances = Self.randomItems(count: Int(generator.next() % 4), prefix: "Protocol", using: &generator)
        let arguments = Self.randomItems(count: Int(generator.next() % 4), prefix: "argument", using: &generator)
        let attributes = Self.randomItems(count: Int(generator.next() % 3), prefix: "@attribute", using: &generator)
        Self.expectProjectionMatches("Inline") { assignment in
            SemanticString {
                Group {
                    for attribute in attributes {
                        Self.emit(attribute, visibleUnder: assignment) { Keyword(attribute.text) }
                    }
                }
                .separator(" ")
                TypeDeclaration(kind: .class, "Sample")
                Joined(separator: ", ", prefix: " <", suffix: ">") {
                    for conformance in conformances {
                        Self.emit(conformance, visibleUnder: assignment) { TypeName(kind: .protocol, conformance.text) }
                    }
                }
                ForEach(arguments, separator: ", ") { argument in
                    Self.emit(argument, visibleUnder: assignment) { Argument(argument.text) }
                }
            }
        }
    }

    @Test("a nested declaration whose whole body can be hidden closes as an empty block", arguments: 0 ..< 20)
    func declarationBlockProjection(seed: Int) {
        var generator = SplitMix64(seed: UInt64(seed))
        let members = Self.randomItems(count: Int(generator.next() % 3) + 1, prefix: "var member", using: &generator)
        Self.expectProjectionMatches("DeclarationBlock") { assignment in
            SemanticString {
                DeclarationBlock(level: 1) {
                    Keyword("struct")
                    Space()
                    TypeDeclaration(kind: .struct, "Outer")
                } body: {
                    MemberList(level: 1) {
                        Standard("var always: Int")
                    }
                    NestedDeclaration {
                        DeclarationBlock(level: 2) {
                            Keyword("struct")
                            Space()
                            TypeDeclaration(kind: .struct, "Inner")
                        } body: {
                            MemberList(level: 2) {
                                for member in members {
                                    Self.emit(member, visibleUnder: assignment) { Standard(member.text + ": Int") }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Offsets

    @Test("every surviving byte maps to the same byte in the projection; removed bytes map to nothing")
    func offsetMapping() {
        let marked = SemanticString {
            MemberList(level: 1) {
                Standard("kept;")
                VisibilityRegion(.enabled("hidden")) { Comment("gone") }
                SemanticString {
                    Standard("también;")
                    VisibilityRegion(.enabled("hidden")) {
                        Space()
                        Comment("trailing")
                    }
                }
            }
        }
        let separated = marked.frozen().separatingVisibilityRegions()
        let projection = separated.regions.projection(of: separated.text) { _ in false }
        #expect(projection.text.string == "\n    kept;\n    también;\n")
        let originalBytes = Array(separated.text.text.utf8)
        let projectedBytes = Array(projection.text.text.utf8)
        var mappedCount = 0
        for originalOffset in originalBytes.indices {
            guard let projectedOffset = projection.projectedUTF8Offset(ofOriginalUTF8Offset: originalOffset) else { continue }
            #expect(projectedBytes[projectedOffset] == originalBytes[originalOffset])
            mappedCount += 1
        }
        #expect(mappedCount == projectedBytes.count)
        #expect(projection.projectedUTF8Offset(ofOriginalUTF8Offset: Array(separated.text.text.utf8).firstIndex(of: UInt8(ascii: "g"))!) == nil)

        let everything = separated.regions.projection(of: separated.text) { _ in true }
        #expect(everything.text == separated.text)
    }
}

/// A small deterministic generator, so a failing seed reproduces.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

@Suite("VisibilityRegion streaming")
struct VisibilityRegionStreamingTests {
    @Test("marking written atoms matches wrapping them in a region, identifier scopes included")
    func markAtomsMatchesRegion() {
        var streamed = SemanticString()
        streamed.write("some", type: .keyword)
        streamed.pushIdentifierScope("$s7SwiftUI4ViewP")
        let start = streamed.count
        streamed.write(" ", type: .standard)
        streamed.write("View", type: .type(.protocol, .name))
        streamed.markAtoms(from: start, visibleUnder: .enabled("resolution"))
        streamed.popIdentifierScope()

        let built = SemanticString {
            Keyword("some")
            VisibilityRegion(.enabled("resolution")) {
                AtomicComponent(string: " ", type: .standard, identifier: "$s7SwiftUI4ViewP")
                AtomicComponent(string: "View", type: .type(.protocol, .name), identifier: "$s7SwiftUI4ViewP")
            }
        }
        #expect(streamed.string == "some View")
        #expect(streamed.components == built.components)

        let separated = streamed.frozen().separatingVisibilityRegions()
        #expect(separated.regions.projection(of: separated.text) { _ in false }.text.string == "some")
        #expect(separated.regions.projection(of: separated.text) { _ in true }.text == separated.text)
        #expect(separated.text.components.last?.identifier == "$s7SwiftUI4ViewP")

        var unchanged = SemanticString { Keyword("a") }
        unchanged.markAtoms(from: 0, visibleUnder: .always)
        #expect(unchanged.components == [AtomicComponent(string: "a", type: .keyword)])
    }
}
