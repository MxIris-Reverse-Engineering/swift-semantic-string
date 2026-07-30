import Foundation
import Testing
@testable import Semantic

/// Pins the behaviors that the two-state storage review found broken or
/// unguarded. Each test names the defect it exists to prevent, so a future
/// change that reintroduces one fails with an explanation rather than a
/// bare expectation.
@Suite("Review Findings")
struct ReviewFindingsRegressionTests {
    // MARK: - Leaves With a Custom buildComponents()

    /// A leaf that overrides `buildComponents()` to emit more than one atom.
    /// Deliberately conforms to `AtomicSemanticComponent` only: promising
    /// `PlainAtomicSemanticComponent` would be a lie, and the fast path is
    /// allowed to trust that promise.
    struct DecoratedLeaf: AtomicSemanticComponent {
        let string: String
        var type: SemanticType { .keyword }

        func buildComponents() -> [AtomicComponent] {
            [
                AtomicComponent(string: "<", type: .standard),
                AtomicComponent(string: string, type: .keyword),
                AtomicComponent(string: ">", type: .standard),
            ]
        }
    }

    @Test("A custom buildComponents() is honoured through every append spelling")
    func customBuildComponentsSurvivesEveryAppendSpelling() {
        // The flat fast path used to convert leaves with
        // `AtomicComponent(component)`, which ignores an override. The same
        // value then rendered "<Foo>" through a builder and "Foo" through
        // `append` — one value, two renderings, no diagnostic.
        let leaf = DecoratedLeaf(string: "Foo")

        var appended = SemanticString()
        appended.append(leaf)

        var appendedInPlace = SemanticString()
        appendedInPlace += leaf

        let renderings: [(name: String, value: SemanticString)] = [
            ("append", appended),
            ("appending", SemanticString().appending(leaf)),
            ("+", SemanticString() + leaf),
            ("+=", appendedInPlace),
            ("builder", SemanticString { leaf }),
            ("Group", SemanticString { Group { leaf } }),
            ("asSemanticString", leaf.asSemanticString()),
        ]

        for rendering in renderings {
            #expect(rendering.value.string == "<Foo>", "\(rendering.name) ignored the override")
            #expect(rendering.value.count == 3, "\(rendering.name) ignored the override")
        }
    }

    @Test("A leaf reaching append through an existential keeps its identifier")
    func identifierSurvivesEveryAppendSpelling() {
        // `AtomicComponent(_ component: some AtomicSemanticComponent)` hard-codes
        // `identifier` to nil, so routing the fast path through it silently
        // dropped the span identity that `AtomicComponent` exists to carry.
        let identified = AtomicComponent(string: "Foo", type: .keyword, identifier: "mangled")
        let existential: any AtomicSemanticComponent = identified

        var concrete = SemanticString()
        concrete.append(identified)

        var throughExistential = SemanticString()
        throughExistential.append(existential)

        var throughGeneric = SemanticString()
        Self.appendLeaf(identified, to: &throughGeneric)

        var appendedInPlace = SemanticString()
        appendedInPlace += identified

        let renderings: [(name: String, value: SemanticString)] = [
            ("concrete append", concrete),
            ("existential append", throughExistential),
            ("generic append", throughGeneric),
            ("+=", appendedInPlace),
            ("appending", SemanticString().appending(identified)),
            ("+", SemanticString() + identified),
            ("builder", SemanticString { identified }),
        ]

        for rendering in renderings {
            #expect(rendering.value.components.first?.identifier == "mangled", "\(rendering.name) dropped the identifier")
        }
    }

    /// An unspecialized generic caller, which is where a statically-resolved
    /// fast path is easiest to get wrong.
    static func appendLeaf<Leaf: AtomicSemanticComponent>(_ leaf: Leaf, to target: inout SemanticString) {
        target.append(leaf)
    }

    @Test("Plain leaves append without materializing the boundary table")
    func plainLeavesStayOneToOne() {
        var streamed = SemanticString()
        streamed.append(Keyword("func"))
        streamed.append(Space())
        streamed.append(FunctionName("run"))
        streamed.append(Indent(level: 1))

        #expect(streamed._storage.elementEndOffsets == nil)
        #expect(streamed.count == 4)
    }

    // MARK: - Element Views Must Not Box Atoms

    @Test("A streamed string's element view is the typed array, not existentials")
    func streamedElementViewDoesNotBox() {
        // Materializing `[any SemanticStringComponent]` here would cost a
        // 40-byte container plus a 64-byte heap box per atom — measured at
        // +79 MB and +23 ms for a 400k-atom string handed to
        // `MemberList(level:content:)`.
        var streamed = SemanticString()
        for index in 0 ..< 8 {
            streamed.append("token\(index)", type: .standard)
        }

        guard case .contents(let atoms, let elementEndOffsets) = streamed.elements.representation else {
            Issue.record("a string's element view should be its contents run")
            return
        }
        #expect(atoms.count == 8)
        #expect(elementEndOffsets == nil)
    }

    @Test("Container prebuilt-content initializers take the contents run as is")
    func containersDoNotBoxPrebuiltContent() {
        var streamed = SemanticString()
        for index in 0 ..< 4 {
            streamed.append("row\(index)", type: .standard)
        }

        let memberList = MemberList(level: 1, content: streamed)
        guard case .contents = memberList.items.representation else {
            Issue.record("MemberList(level:content:) boxed a streamed string's atoms")
            return
        }

        let rows = Rows(level: 1, content: streamed)
        guard case .contents = rows.items.representation else {
            Issue.record("Rows(level:content:) boxed a streamed string's atoms")
            return
        }

        let blockList = BlockList(content: streamed)
        guard case .contents = blockList.items.representation else {
            Issue.record("BlockList(content:) boxed a streamed string's atoms")
            return
        }
    }

    // MARK: - Element Granularity

    @Test("Element granularity is per-atom when streamed and per-item when built")
    func elementGranularityMatchesHowTheStringWasBuilt() {
        var streamed = SemanticString()
        streamed.append("var", type: .keyword)
        streamed.append(" x: Int", type: .standard)
        #expect(streamed._storage.elementEndOffsets == nil)
        #expect(streamed.elements.count == streamed.components.count)
        #expect(streamed.elements.count == 2)

        let built = SemanticString {
            SemanticString {
                Keyword("var")
                Standard(" x: Int")
            }
            SemanticString {
                Keyword("var")
                Standard(" y: Int")
            }
        }
        #expect(built._storage.elementEndOffsets == [2, 4])
        #expect(built.elements.count == 2)
        #expect(built.components.count == 4)

        // One row per element, so the two forms render differently through a
        // container's prebuilt-content initializer — granularity is data, and
        // the boundary table is what carries it.
        #expect(SemanticString { MemberList(level: 1, content: built) }.string == "\n    var x: Int\n    var y: Int\n")
        #expect(SemanticString { MemberList(level: 1, content: streamed) }.string == "\n    var\n     x: Int\n")
    }

    // MARK: - isEmpty Semantics

    @Test("isEmpty is O(1) and fills no cache")
    func isEmptyDoesNotPublishTheCache() {
        // `isEmpty` is an element count. It must not concatenate, flatten, or
        // leave anything behind in storage that may be shared —
        // `ForEach(_:separator:)` calls it once per item.
        let built = SemanticString {
            Group { Keyword("a") }
            Group { Keyword("b") }
        }
        #expect(built._storage.cachedString == nil)

        #expect(!built.isEmpty)

        #expect(built._storage.cachedString == nil)
    }

    @Test("Zero-output elements keep their slot but do not affect isEmpty")
    func zeroOutputElementsDoNotAffectIsEmpty() {
        // An element that flattens to nothing occupies an element slot —
        // container-layout bookkeeping — but `isEmpty` reports components
        // (fifth review round, superseding the earlier element-count
        // semantics): all emptiness measures coincide, and they agree with
        // `==`/`hash`/`Codable`, which compare components.
        let zeroOutput = SemanticString {
            Group {}
            Group {}
        }
        #expect(zeroOutput._storage.elementCount == 2)
        #expect(zeroOutput.isEmpty == true)
        #expect(zeroOutput.count == 0)
        #expect(zeroOutput.first == nil)
        #expect(zeroOutput.string.isEmpty)
        #expect(zeroOutput == SemanticString())

        #expect(SemanticString().isEmpty)
    }

    // MARK: - Frozen Decoding Validation

    @Test("Decoding rejects a zero-length span")
    func frozenDecodingRejectsZeroLengthSpans() throws {
        // `frozen()` cannot produce one. Accepting it yields a value whose
        // `count` is 1 while it renders nothing, violating the library-wide
        // "no empty component" invariant, and the round trip through
        // `SemanticString` is not idempotent.
        let payload = """
        {
          "text": "",
          "spanLengths": [0],
          "spanTypeCodes": [0],
          "spanIdentifierIndices": [0],
          "identifierTable": []
        }
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FrozenSemanticString.self, from: Data(payload.utf8))
        }
    }

    @Test("An out-of-range identifier index resolves to nil instead of trapping")
    func outOfRangeIdentifierIndexResolvesToNil() {
        // The unchecked initializer documents that the caller owns the
        // invariants, but resolving an index by trapping takes the process
        // down on data that reached it anyway. `nil` is the graceful failure.
        let malformed = FrozenSemanticString(
            text: "ab",
            spans: [.init(length: 2, typeCode: 0, identifierIndex: 9)],
            identifierTable: []
        )
        #expect(malformed.identifier(at: 9) == nil)

        var seenIdentifiers: [String?] = []
        malformed.enumerateSpans { _, _, identifier in seenIdentifiers.append(identifier) }
        #expect(seenIdentifiers == [nil])
    }

    // MARK: - Frozen Type Codes

    @Test("Every SemanticType maps to a distinct code and round trips")
    func frozenTypeCodesAreUniqueAndRoundTrip() {
        // The codes used to be derived as `8 + typeKindOffset * 2`, whose
        // growth edge sat directly against `.member`'s fixed 18. A sixth
        // `TypeKind` would have compiled and silently collided.
        var typeByCode: [UInt8: SemanticType] = [:]
        for semanticType in Self.everySemanticType {
            let code = semanticType.frozenTypeCode
            if let existing = typeByCode[code] {
                Issue.record("\(semanticType) and \(existing) both encode to \(code)")
            }
            typeByCode[code] = semanticType
            #expect(SemanticType(frozenTypeCode: code) == semanticType, "\(semanticType) did not round trip")
        }
    }

    @Test("No assigned code reaches the next free code")
    func assignedCodesStayBelowTheNextFreeCode() {
        for semanticType in Self.everySemanticType {
            #expect(
                semanticType.frozenTypeCode < SemanticType.nextFreeFrozenTypeCode,
                "\(semanticType) encodes to \(semanticType.frozenTypeCode), at or past the next free code"
            )
        }
        #expect(SemanticType(frozenTypeCode: SemanticType.nextFreeFrozenTypeCode) == nil)
    }

    static var everySemanticType: [SemanticType] {
        // Built from `allCases` so a future `TypeKind`/`Context` case is
        // covered automatically — a hardcoded kind list would keep passing
        // while the new case collides with `.member`'s fixed codes. The
        // uniqueness guard itself is
        // `FrozenSemanticStringTests.typeCodeBijection`.
        var types: [SemanticType] = [.standard, .comment, .keyword, .variable, .numeric, .argument, .error, .other]
        for typeKind in SemanticType.TypeKind.allCases {
            for context in SemanticType.Context.allCases {
                types.append(.type(typeKind, context))
            }
        }
        for context in SemanticType.Context.allCases {
            types.append(.member(context))
            types.append(.function(context))
        }
        return types
    }

    // MARK: - Frozen Equality

    @Test("Identifier table shape does not affect equality or hashing")
    func frozenEqualityIgnoresIdentifierTableShape() {
        // The synthesized conformance compared `identifierTable` verbatim, so
        // a decoded payload carrying an unreferenced or duplicated entry
        // compared unequal to a value no reader could distinguish it from.
        let spans = [FrozenSemanticString.Span(length: 1, typeCode: 0, identifierIndex: 0)]
        let minimal = FrozenSemanticString(text: "x", spans: spans, identifierTable: [])
        let withUnreferencedEntry = FrozenSemanticString(text: "x", spans: spans, identifierTable: ["unused"])

        #expect(minimal == withUnreferencedEntry)
        #expect(minimal.hashValue == withUnreferencedEntry.hashValue)
    }

    @Test("Equal identifiers reached through different indices compare equal")
    func frozenEqualityResolvesIdentifiersThroughTheTable() {
        let left = FrozenSemanticString(
            text: "xy",
            spans: [
                .init(length: 1, typeCode: 0, identifierIndex: 1),
                .init(length: 1, typeCode: 0, identifierIndex: 0),
            ],
            identifierTable: ["shared"]
        )
        let right = FrozenSemanticString(
            text: "xy",
            spans: [
                .init(length: 1, typeCode: 0, identifierIndex: 2),
                .init(length: 1, typeCode: 0, identifierIndex: 0),
            ],
            identifierTable: ["padding", "shared"]
        )

        #expect(left == right)
        #expect(left.hashValue == right.hashValue)
    }

    @Test("Different identifiers still compare unequal")
    func frozenEqualityStillDistinguishesIdentifiers() {
        let spans = [FrozenSemanticString.Span(length: 1, typeCode: 0, identifierIndex: 1)]
        let left = FrozenSemanticString(text: "x", spans: spans, identifierTable: ["one"])
        let right = FrozenSemanticString(text: "x", spans: spans, identifierTable: ["two"])

        #expect(left != right)
    }

    // MARK: - Cross-Platform Cache Lock

    @Test("Stripe indices spread across the table for 32-bit-sized addresses")
    func stripeIndicesSpreadForNarrowAddresses() {
        // The mix must run in `UInt64` on every platform. Truncating the
        // multiplier to fit a 32-bit `UInt` — the obvious way to make this
        // compile for watchOS — leaves the high half of the product empty, so
        // `mixed >> 32` is always zero and all 256 stripes collapse into one:
        // the single global lock that measured slower than no threading at all.
        var usedStripes = Set<Int>()
        var address: UInt = 0x1000_0000
        for _ in 0 ..< 4096 {
            let stripe = CacheLockStripes.stripe(forAddress: address)
            let offset = UnsafeRawPointer(stripe) - UnsafeRawPointer(CacheLockStripes.base)
            usedStripes.insert(offset / CacheLockStripes.stride)
            address &+= 64
        }
        #expect(usedStripes.count > 128, "only \(usedStripes.count) of 256 stripes were reachable")
    }
}
