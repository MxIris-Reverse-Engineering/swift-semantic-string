import Testing
@testable import Semantic

extension AnnotationRegion.Kind {
    fileprivate static let memberAddress = Self("memberAddress")

    fileprivate static let fieldOffset = Self("fieldOffset")

    fileprivate static let fieldLayoutNode = Self("fieldLayoutNode")
}

/// Tests for `AnnotationRegion`, `AnnotationSegment` and `AnnotatedAtom`.
/// The contract they pin: marking content never changes what is printed or
/// how containers lay it out; the marks live inside visibility tags and
/// definition identities, so the three kinds of region nest in any order
/// with identical atoms; and where a region is recognized — its anchor —
/// depends on its own content alone.
@Suite("AnnotationRegion")
struct AnnotationRegionTests {
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
}
