import Foundation
import Testing
@testable import Semantic

// MARK: - Fixtures

/// A third-party plain leaf. Through an existential it must render exactly
/// what the statically-typed fast path renders.
private struct ThirdPartyPlainLeaf: PlainAtomicSemanticComponent {
    let string: String
    var type: SemanticType { .argument }
}

/// A third-party leaf that customizes `buildComponents()` and therefore stays
/// on `AtomicSemanticComponent`. The override must be honoured on every path,
/// including the existential one.
private struct DecoratedLeaf: AtomicSemanticComponent {
    let name: String
    var string: String { "<" + name + ">" }
    var type: SemanticType { .variable }
    func buildComponents() -> [AtomicComponent] {
        [
            AtomicComponent(string: "<", type: .standard),
            AtomicComponent(string: name, type: .variable, identifier: "decorated:" + name),
            AtomicComponent(string: ">", type: .standard),
        ]
    }
}

/// A third-party composite. Its flattening is one element however many atoms
/// it contains, on every path.
private struct ThirdPartyComposite: SemanticStringComponent {
    func buildComponents() -> [AtomicComponent] {
        [
            AtomicComponent(string: "alpha", type: .keyword),
            AtomicComponent(string: " ", type: .standard),
            AtomicComponent(string: "beta", type: .keyword),
        ]
    }
}

/// A composite whose flattening interleaves zero-length atoms, so the
/// adopt-the-array shortcut must not apply to it.
private struct BlankInterleavingComposite: SemanticStringComponent {
    func buildComponents() -> [AtomicComponent] {
        [
            AtomicComponent(string: "a", type: .standard),
            AtomicComponent(string: "", type: .standard),
            AtomicComponent(string: "b", type: .standard),
        ]
    }
}

// MARK: - Tests

/// Behavior pins for the append-path performance work
/// (`docs/AppendPathPerformance.md`). None of these guards a timing or an
/// allocation count — the repository has no such tests by convention — they
/// pin the behavior each optimized path must preserve, so a regression in the
/// rewrite shows up as a wrong string, a wrong element count, or a lost
/// identifier rather than as a slower benchmark.
@Suite("Append path performance pins")
struct AppendPathPerformanceTests {
    // MARK: 1. Concatenation

    /// The concatenation copies raw UTF-8 bytes. Tokens that exercise every
    /// representation a `String` can take — small inline, heap-allocated,
    /// multi-byte scalars, a grapheme cluster split across two tokens, and
    /// a bridged `NSString` — must come out byte-identical to the joined
    /// token strings.
    @Test("string is the byte-exact concatenation across every token representation")
    func concatenationIsByteExact() {
        let bridged = NSString(string: "Ünïcödé-bridged-token-longer-than-fifteen-bytes") as String
        var semanticString = SemanticString()
        semanticString.append("let", type: .keyword)
        semanticString.append(" ", type: .standard)
        semanticString.append("identifierLongerThanFifteenBytes", type: .variable)
        semanticString.append("语义字符串", type: .comment)
        semanticString.append("👨‍👩‍👧‍👦", type: .standard)
        semanticString.append("e", type: .keyword)
        semanticString.append("\u{0301}", type: .standard)
        semanticString.append(bridged, type: .argument)

        let expected = "let identifierLongerThanFifteenBytes语义字符串👨‍👩‍👧‍👦e\u{0301}Ünïcödé-bridged-token-longer-than-fifteen-bytes"
        #expect(semanticString.string == expected)
        #expect(semanticString.string.utf8.elementsEqual(expected.utf8))
        #expect(semanticString.frozen().text.utf8.elementsEqual(expected.utf8))
    }

    @Test("string of an empty value is the empty string")
    func concatenationOfEmptyValue() {
        #expect(SemanticString().string == "")
        #expect(SemanticString().string.utf8.isEmpty)
    }

    // MARK: 2. Existential append dispatch

    @Test("A plain leaf reaching append through an existential renders what the static path renders")
    func existentialPlainLeafMatchesStaticPath() {
        let leaf = ThirdPartyPlainLeaf(string: "value")
        var viaStatic = SemanticString()
        viaStatic.append(leaf)
        let existential: any SemanticStringComponent = leaf
        var viaExistential = SemanticString()
        viaExistential.append(existential)

        #expect(viaExistential == viaStatic)
        #expect(viaExistential.components == [AtomicComponent(string: "value", type: .argument)])
        #expect(viaExistential._storage.elementEndOffsets == nil)
    }

    @Test("A leaf overriding buildComponents() keeps its override through an existential")
    func existentialCustomLeafHonoursOverride() {
        let existential: any SemanticStringComponent = DecoratedLeaf(name: "x")
        var semanticString = SemanticString()
        semanticString.append(existential)

        #expect(semanticString.string == "<x>")
        #expect(semanticString.components.map(\.identifier) == [nil, "decorated:x", nil])
        #expect(semanticString._storage.elementCount == 1)
    }

    @Test("A composite reaching append through an existential is one element")
    func existentialCompositeIsOneElement() {
        var semanticString = SemanticString()
        semanticString.append("prefix", type: .standard)
        let existential: any SemanticStringComponent = ThirdPartyComposite()
        semanticString.append(existential)

        #expect(semanticString.string == "prefixalpha beta")
        #expect(semanticString._storage.elementCount == 2)
        #expect(semanticString._storage.elementEndOffsets == [1, 4])
    }

    @Test("An AtomicComponent reaching append through an existential keeps its identifier")
    func existentialAtomicComponentKeepsIdentifier() {
        let atom = AtomicComponent(string: "name", type: .member(.name), identifier: "mangled")
        let existential: any SemanticStringComponent = atom
        var semanticString = SemanticString()
        semanticString.append(existential)

        #expect(semanticString.components == [atom])
        #expect(semanticString._storage.elementEndOffsets == nil)
    }

    @Test("A SemanticString reaching append through an existential is one element")
    func existentialSemanticStringIsOneElement() {
        var operand = SemanticString()
        operand.append("a", type: .keyword)
        operand.append("b", type: .keyword)
        let existential: any SemanticStringComponent = operand
        var semanticString = SemanticString()
        semanticString.append(existential)

        #expect(semanticString._storage.elementCount == 1)
        #expect(semanticString._storage.elementEndOffsets == [2])
    }

    @Test("An optional reaching append through an existential unwraps to its payload's path")
    func existentialOptionalForwardsToPayload() {
        let someLeaf: any SemanticStringComponent = Optional(Keyword("some"))
        let noLeaf: any SemanticStringComponent = nil as Keyword?
        let someDecorated: any SemanticStringComponent = Optional(DecoratedLeaf(name: "y"))
        var semanticString = SemanticString()
        semanticString.append(someLeaf)
        semanticString.append(noLeaf)
        semanticString.append(someDecorated)

        #expect(semanticString.string == "some<y>")
        #expect(semanticString._storage.elementCount == 2)
        #expect(semanticString.components.map(\.identifier) == [nil, nil, "decorated:y", nil])
    }

    /// The promise-violating leaf is the one observable difference between
    /// the fast path and the flattening path. In debug the fast path asserts,
    /// so a violating conformance reaching `append` as an existential must
    /// trap too — that is what proves the existential append dispatches to
    /// the plain-leaf path rather than to the general default.
    #if DEBUG
    @Test("Debug builds assert on a promise-violating leaf reaching append through an existential")
    func existentialPromiseViolationIsAssertedInDebug() async {
        await #expect(processExitsWith: .failure) {
            struct PromiseViolatingLeaf: PlainAtomicSemanticComponent {
                var string: String { "RAW" }
                var type: SemanticType { .keyword }
                func buildComponents() -> [AtomicComponent] {
                    [AtomicComponent(string: "OVERRIDE", type: .error)]
                }
            }
            let existential: any SemanticStringComponent = PromiseViolatingLeaf()
            var value = SemanticString()
            value.append(existential)
        }
    }
    #endif

    @Test("The builder renders every construction path identically")
    func builderMatchesDirectAppends() {
        let built = SemanticString {
            Keyword("public")
            Space()
            DecoratedLeaf(name: "z")
            ThirdPartyPlainLeaf(string: "arg")
            AtomicComponent(string: "id", type: .variable, identifier: "scoped")
            Optional(Keyword("opt"))
            ThirdPartyComposite()
        }
        var direct = SemanticString()
        direct.append(Keyword("public"))
        direct.append(Space())
        direct.append(DecoratedLeaf(name: "z"))
        direct.append(ThirdPartyPlainLeaf(string: "arg"))
        direct.append(AtomicComponent(string: "id", type: .variable, identifier: "scoped"))
        direct.append(Optional(Keyword("opt")))
        direct.append(ThirdPartyComposite())

        #expect(built == direct)
        #expect(built.string == "public <z>argidoptalpha beta")
        #expect(built._storage.elementEndOffsets == direct._storage.elementEndOffsets)
        #expect(built._storage.elementCount == 7)
    }

    // MARK: 4. Adopting a composite's flattening

    @Test("A composite appended to an empty value stays isolated from the composite's own array")
    func adoptedFlatteningIsCopyOnWriteIsolated() {
        let forEach = ForEach(["one", "two"], separator: ", ") { Standard($0) }
        var semanticString = SemanticString(forEach)
        #expect(semanticString.string == "one, two")
        #expect(semanticString._storage.elementCount == 1)

        semanticString.append(Keyword("!"))
        #expect(semanticString.string == "one, two!")
        #expect(forEach.buildComponents().map(\.string) == ["one", ", ", "two"])
        #expect(SemanticString(forEach).string == "one, two")
    }

    @Test("A composite whose flattening interleaves zero-length atoms is filtered, not adopted")
    func blankInterleavingCompositeIsFiltered() {
        var semanticString = SemanticString()
        semanticString.append(BlankInterleavingComposite())
        #expect(semanticString.components.map(\.string) == ["a", "b"])
        #expect(semanticString._storage.elementEndOffsets == [2])
        #expect(semanticString.isEmpty == false)
    }

    @Test("A composite appended onto a zero-length element slot extends the existing table")
    func compositeOntoZeroLengthSlotExtendsTable() {
        // `init(components: [AtomicComponent])` keeps one slot per input
        // entry, so an all-empty input leaves `atoms == []` with a table of
        // `[0]`. The adopt shortcut sees empty atoms; it must still record
        // the new element behind the existing slot.
        var semanticString = SemanticString(components: [AtomicComponent(string: "", type: .standard)])
        #expect(semanticString._storage.elementEndOffsets == [0])
        semanticString.append(ThirdPartyComposite())
        #expect(semanticString._storage.atoms.count == 3)
        #expect(semanticString._storage.elementEndOffsets == [0, 3])
        #expect(semanticString.string == "alpha beta")
    }

    @Test("A composite appended onto existing content keeps prior elements intact")
    func compositeOntoContentSplicesAfterExistingElements() {
        var semanticString = SemanticString()
        semanticString.append("x", type: .keyword)
        semanticString.append("y", type: .keyword)
        semanticString.append(ThirdPartyComposite())
        semanticString.append("z", type: .keyword)

        #expect(semanticString.string == "xyalpha betaz")
        #expect(semanticString._storage.elementEndOffsets == [1, 2, 5, 6])
    }
}
