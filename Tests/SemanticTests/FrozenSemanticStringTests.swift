import Foundation
import Testing
@testable import Semantic

/// Tests for `FrozenSemanticString` — the immutable arena snapshot — and for
/// `SemanticString.frozen()`. The contract: freezing preserves text, semantic
/// runs, and identifiers exactly; the columnar `Codable` form round-trips and
/// rejects corrupted input; the `SemanticType` code mapping is a bijection.
@Suite("FrozenSemanticString")
struct FrozenSemanticStringTests {
    private func buildDeclarationBlock() -> SemanticString {
        SemanticString {
            DeclarationBlock(level: 1) {
                Keyword("struct")
                Space()
                TypeDeclaration(kind: .struct, "Foo")
            } body: {
                MemberList(level: 1) {
                    SemanticString {
                        Keyword("var")
                        Space()
                        Variable("x")
                    }
                    SemanticString {
                        Comment("offset: 0x10")
                    }
                }
            }
        }
    }

    /// Every `SemanticType` value. `TypeKind`/`Context` combinations come
    /// from `allCases`; the top-level cases are listed by hand because
    /// `SemanticType` has associated values and cannot be `CaseIterable`.
    /// `assertCaseListIsExhaustive(_:)` below keeps the hand list honest.
    private var allSemanticTypes: [SemanticType] {
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

    /// Compile-time canary for `allSemanticTypes`: this `switch` must stay
    /// exhaustive **without** a `default` clause. Adding a top-level case to
    /// `SemanticType` fails compilation here, forcing `allSemanticTypes` and
    /// `typeCodeBijection`'s pinned count to be updated together — the
    /// mechanism that lets the bijection test actually catch a colliding
    /// code for a future case.
    private func assertCaseListIsExhaustive(_ semanticType: SemanticType) {
        switch semanticType {
        case .standard, .comment, .keyword, .variable, .numeric, .argument, .error, .other,
             .type, .member, .function:
            break
        }
    }

    // MARK: - Freezing Equivalence

    @Test("Freezing preserves text, components, and span walk")
    func freezingPreservesContent() {
        let original = buildDeclarationBlock()
        let frozen = original.frozen()

        #expect(frozen.text == original.string)
        #expect(frozen.string == original.string)
        #expect(frozen.components == original.components)
        #expect(frozen.count == original.components.count)

        var reconstructedText = ""
        var walkedTypes: [SemanticType] = []
        frozen.enumerateSpans { spanText, type, _ in
            reconstructedText += spanText
            walkedTypes.append(type)
        }
        #expect(reconstructedText == original.string)
        #expect(walkedTypes == original.components.map(\.type))
    }

    @Test("Freezing a flat streamed string preserves identifiers via interning")
    func freezingInternsIdentifiers() {
        var semanticString = SemanticString()
        semanticString.pushIdentifierScope("$s7ModuleA4TypeV")
        semanticString.append("ModuleA", type: .type(.other, .name))
        semanticString.append(".", type: .standard)
        semanticString.append("Type", type: .type(.struct, .name))
        semanticString.popIdentifierScope()
        semanticString.append(" ", type: .standard)
        semanticString.pushIdentifierScope("$s7ModuleA4TypeV")
        semanticString.append("Type", type: .type(.struct, .name))
        semanticString.popIdentifierScope()

        let frozen = semanticString.frozen()

        // Both scopes used the same identifier — interned to one table entry.
        #expect(frozen.identifierTable == ["$s7ModuleA4TypeV"])
        #expect(frozen.spans.filter { $0.identifierIndex == 1 }.count == 4)
        #expect(frozen.spans.filter { $0.identifierIndex == 0 }.count == 1)

        var walkedIdentifiers: [String?] = []
        frozen.enumerateSpans { _, _, identifier in
            walkedIdentifiers.append(identifier)
        }
        #expect(walkedIdentifiers == semanticString.components.map(\.identifier))
    }

    @Test("Freezing skips zero-length components")
    func freezingSkipsEmptyComponents() {
        let semanticString = SemanticString(components: [
            AtomicComponent(string: "a", type: .standard),
            AtomicComponent(string: "", type: .keyword),
            AtomicComponent(string: "b", type: .standard),
        ])
        let frozen = semanticString.frozen()
        #expect(frozen.text == "ab")
        #expect(frozen.spans.count == 2)
    }

    @Test("Freezing an empty string yields an empty frozen string")
    func freezingEmptyString() {
        let frozen = SemanticString().frozen()
        #expect(frozen.isEmpty)
        #expect(frozen.text == "")
        #expect(frozen.spans.isEmpty)
        #expect(frozen.identifierTable.isEmpty)
    }

    @Test("Freezing preserves multi-byte and emoji content")
    func freezingPreservesMultiByteContent() {
        var semanticString = SemanticString()
        semanticString.append("你好, 世界", type: .comment)
        semanticString.append(" 🎉👨‍👩‍👧‍👦", type: .standard)
        let frozen = semanticString.frozen()
        #expect(frozen.text == "你好, 世界 🎉👨‍👩‍👧‍👦")
        #expect(frozen.components == semanticString.components)
    }

    // MARK: - Long Token Splitting

    @Test("Tokens beyond UInt16.max UTF-8 bytes split at grapheme boundaries")
    func longTokenSplitting() {
        // 30,000 three-byte characters = 90,000 UTF-8 bytes — forces
        // splitting, and 65,535 is not divisible by 3 so a naive byte split
        // would tear a scalar. Each 汉 is a single-scalar cluster, so this
        // pins the alignment arithmetic; the multi-scalar-cluster case is
        // `ThirdReviewRegressionTests.oversizedTokenSplitsAtGraphemeClusterBoundaries`.
        let longToken = String(repeating: "汉", count: 30000)
        var semanticString = SemanticString()
        semanticString.append(longToken, type: .comment)

        let frozen = semanticString.frozen()
        #expect(frozen.text == longToken)
        #expect(frozen.spans.count > 1)
        for span in frozen.spans {
            #expect(Int(span.length) <= Int(UInt16.max))
            #expect(Int(span.length).isMultiple(of: 3), "a torn scalar would break the 3-byte alignment")
            #expect(span.typeCode == SemanticType.comment.frozenTypeCode)
        }

        var reconstructedText = ""
        frozen.enumerateSpans { spanText, type, _ in
            reconstructedText += spanText
            #expect(type == .comment)
        }
        #expect(reconstructedText == longToken)
    }

    // MARK: - Semantic Type Codes

    @Test("frozenTypeCode is a bijection over every SemanticType case")
    func typeCodeBijection() {
        var seenCodes: Set<UInt8> = []
        for semanticType in allSemanticTypes {
            assertCaseListIsExhaustive(semanticType)
            let code = semanticType.frozenTypeCode
            #expect(seenCodes.insert(code).inserted, "duplicate code \(code) for \(semanticType)")
            #expect(SemanticType(frozenTypeCode: code) == semanticType)
            #expect(code < SemanticType.nextFreeFrozenTypeCode, "assigned code \(code) must stay below the next-free marker")
        }
        #expect(seenCodes.count == allSemanticTypes.count, "every SemanticType value owns exactly one code")
        #expect(seenCodes.count == 22, "update alongside allSemanticTypes when adding a case")
    }

    @Test("Unknown type codes decode to nil and render as .other")
    func unknownTypeCode() {
        #expect(SemanticType(frozenTypeCode: 22) == nil)
        #expect(SemanticType(frozenTypeCode: .max) == nil)

        let frozen = FrozenSemanticString(
            text: "x",
            spans: [.init(length: 1, typeCode: .max, identifierIndex: 0)],
            identifierTable: []
        )
        var walkedTypes: [SemanticType] = []
        frozen.enumerateSpans { _, type, _ in
            walkedTypes.append(type)
        }
        #expect(walkedTypes == [.other])
    }

    // MARK: - Codable

    @Test("Codable round-trips exactly")
    func codableRoundTrip() throws {
        var semanticString = buildDeclarationBlock()
        semanticString.pushIdentifierScope("$sIdentifier")
        semanticString.append("Linked", type: .type(.class, .name))
        semanticString.popIdentifierScope()

        let frozen = semanticString.frozen()
        let encoded = try JSONEncoder().encode(frozen)
        let decoded = try JSONDecoder().decode(FrozenSemanticString.self, from: encoded)
        #expect(decoded == frozen)
        #expect(decoded.components == frozen.components)
    }

    @Test("Columnar encoding is materially smaller than SemanticString encoding")
    func codableIsCompact() throws {
        let original = buildDeclarationBlock()
        let frozen = original.frozen()
        let encoder = JSONEncoder()
        let semanticStringData = try encoder.encode(original)
        let frozenData = try encoder.encode(frozen)
        #expect(frozenData.count < semanticStringData.count / 2)
    }

    @Test("Decoding rejects corrupted input")
    func decodingValidation() throws {
        func expectCorrupt(_ json: String) {
            let data = Data(json.utf8)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(FrozenSemanticString.self, from: data)
            }
        }

        // Column count mismatch.
        expectCorrupt(#"{"text":"ab","spanLengths":[1,1],"spanTypeCodes":[0],"spanIdentifierIndices":[0,0],"identifierTable":[]}"#)
        // Lengths do not cover the text.
        expectCorrupt(#"{"text":"ab","spanLengths":[1],"spanTypeCodes":[0],"spanIdentifierIndices":[0],"identifierTable":[]}"#)
        // An out-of-range identifier index is *not* corrupt: like an unknown
        // type code it degrades to a graceful default (`nil`) in every reader,
        // and the unchecked init / encoder produce exactly such values, so the
        // decoder must accept it or refuse this type's own output. See
        // `FourthReviewRegressionTests.codableRoundTripAcceptsOutOfRangeIdentifierIndex`.
    }

    // MARK: - Memory Shape

    @Test("Span is 8 bytes")
    func spanLayout() {
        #expect(MemoryLayout<FrozenSemanticString.Span>.stride == 8)
    }
}
