import Foundation
import Testing
@testable import Semantic

// MARK: - Fixtures

/// A third-party leaf that overrides `buildComponents()` to emit two atoms.
/// One appended leaf must stay one element, whatever its atom count.
private struct AnnotatedName: AtomicSemanticComponent {
    let name: String
    var string: String { "@" + name }
    var type: SemanticType { .standard }
    func buildComponents() -> [AtomicComponent] {
        [
            AtomicComponent(string: "@", type: .keyword),
            AtomicComponent(string: name, type: .member(.name)),
        ]
    }
}

/// A third-party composite whose flattening emits a zero-length atom.
/// Zero-length atoms must never survive into storage, on any path.
private struct BlankEmitter: SemanticStringComponent {
    func buildComponents() -> [AtomicComponent] {
        [
            AtomicComponent(string: "a", type: .standard),
            AtomicComponent(string: "", type: .standard),
        ]
    }
}

/// Counts how many times its flattening runs, so a test can pin
/// "each element flattens exactly once".
private final class FlattenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private struct CountingLeaf: SemanticStringComponent {
    let counter: FlattenCounter
    let value: String
    func buildComponents() -> [AtomicComponent] {
        counter.increment()
        return [AtomicComponent(string: value, type: .standard)]
    }
}

// MARK: - Tests

/// Regression tests for the second review round, written before the
/// flat-atoms-plus-boundaries storage redesign. Expected values are the
/// behavior contract: byte-identical output with `main` for every rendering
/// path, with one documented exception (zero-length atoms are dropped from
/// storage on every construction path).
@Suite("Redesign Regression")
struct RedesignRegressionTests {
    // MARK: Frozen equality (finding 2)

    @Test("Frozen equality stays transitive with duplicate table entries")
    func frozenEqualityIsTransitiveWithDuplicateTableEntries() {
        let duplicateTable = ["X", "X"]
        let indexOne = FrozenSemanticString(
            text: "ab",
            spans: [.init(length: 2, typeCode: 0, identifierIndex: 1)],
            identifierTable: duplicateTable
        )
        let indexTwo = FrozenSemanticString(
            text: "ab",
            spans: [.init(length: 2, typeCode: 0, identifierIndex: 2)],
            identifierTable: duplicateTable
        )
        let minimalTable = FrozenSemanticString(
            text: "ab",
            spans: [.init(length: 2, typeCode: 0, identifierIndex: 1)],
            identifierTable: ["X"]
        )
        #expect(indexOne == minimalTable)
        #expect(indexTwo == minimalTable)
        #expect(indexOne == indexTwo, "equality must be transitive: both compare equal to the minimal-table value")
        #expect(Set([indexOne, indexTwo, minimalTable]).count == 1)
    }

    // MARK: Element granularity (finding 6)

    @Test("A streamed custom leaf stays one element")
    func streamedCustomLeafKeepsItsElementBoundary() {
        var row = SemanticString()
        row.append(AnnotatedName(name: "alpha"))
        row.append(AnnotatedName(name: "beta"))
        let rendered = SemanticString(MemberList(level: 1, content: row)).string
        #expect(rendered == "\n    @alpha\n    @beta\n", "one appended leaf renders as one row, as on main")
    }

    @Test("Builder and streamed appends agree on leaf granularity")
    func builderAndStreamedLeafGranularityAgree() {
        var streamed = SemanticString()
        streamed.append(AnnotatedName(name: "alpha"))
        streamed.append(AnnotatedName(name: "beta"))
        let built = SemanticString {
            AnnotatedName(name: "alpha")
            AnnotatedName(name: "beta")
        }
        let streamedRendering = SemanticString(MemberList(level: 1, content: streamed)).string
        let builtRendering = SemanticString(MemberList(level: 1, content: built)).string
        #expect(streamedRendering == builtRendering)
    }

    // MARK: ForEach byte parity (finding 7)

    @Test("ForEach separator output matches main around empty items")
    func forEachSeparatorMatchesMainAroundEmptyItems() {
        let separated = SemanticString {
            ForEach(["a", "", "b"], separator: ", ") { item in
                Standard(item)
            }
        }
        #expect(separated.string == "a, , b")
    }

    @Test("ForEach separator output matches main for all-empty items")
    func forEachSeparatorAllEmptyMatchesMain() {
        let separated = SemanticString {
            ForEach(["", ""], separator: ", ") { item in
                Standard(item)
            }
        }
        #expect(separated.string == ", ")
    }

    // MARK: isEmpty semantics (decision D3)

    @Test("A zero-output element still counts against isEmpty")
    func builderEmptyStandardCountsAsElement() {
        let value = SemanticString { Standard("") }
        #expect(value.isEmpty == false, "isEmpty means \"has no elements\", as on main")
        #expect(SemanticString().isEmpty == true)
    }

    // MARK: Single flatten per element (finding 8)

    @Test("ForEach flattens each item exactly once")
    func forEachFlattensEachItemExactlyOnce() {
        let counter = FlattenCounter()
        _ = SemanticString {
            ForEach(0 ..< 1000, separator: ", ") { index in
                CountingLeaf(counter: counter, value: "v\(index)")
            }
        }
        #expect(counter.value == 1000)
    }

    // MARK: Codable idempotence (finding 10, decision D2)

    @Test("Codable round trips are idempotent for blank-emitting composites")
    func codableRoundTripIsIdempotentForBlankEmittingComposites() throws {
        let carrier = SemanticString(BlankEmitter())
        let encoded = try JSONEncoder().encode(carrier)
        let decoded = try JSONDecoder().decode(SemanticString.self, from: encoded)
        #expect(decoded == carrier)
        #expect(decoded.count == carrier.count)
    }

    @Test("Zero-length atoms are dropped from hand-made arrays")
    func handMadeZeroLengthAtomsAreDropped() {
        let value = SemanticString(components: [
            AtomicComponent(string: "a", type: .standard),
            AtomicComponent(string: "", type: .standard),
            AtomicComponent(string: "b", type: .standard),
        ])
        #expect(value.count == 2, "documented divergence from main: zero-length atoms are never stored")
        #expect(value.string == "ab")
    }

    // MARK: Identifier scopes (findings 12, 13)

    @Test("appending an empty string clears identifier scopes like every other appending")
    func appendingEmptyStringClearsIdentifierScopes() {
        var source = SemanticString()
        source.pushIdentifierScope("Foo")
        var viaEmpty = source.appending("", type: .standard)
        viaEmpty.append("streamed", type: .standard)
        #expect(viaEmpty.components.map(\.identifier) == [nil], "the result of appending carries no scopes from self")
    }

    @Test("Identifier scopes stamp string appends only")
    func identifierScopesStampOnlyStringAppends() {
        var scoped = SemanticString()
        scoped.pushIdentifierScope("Swift.Int")
        scoped.append("Int", type: .keyword)
        scoped.append(Keyword("Int"))
        scoped.append(AtomicComponent(string: "Int", type: .keyword))
        #expect(scoped.components.map(\.identifier) == ["Swift.Int", nil, nil])
    }

    // MARK: Frozen decoding contract (findings 3, 14)

    @Test("Unknown frozen type codes decode and resolve to .other")
    func unknownFrozenTypeCodeDecodesToOther() throws {
        let payload = """
        {"text":"x","spanLengths":[1],"spanTypeCodes":[250],"spanIdentifierIndices":[0],"identifierTable":[]}
        """
        let decoded = try JSONDecoder().decode(FrozenSemanticString.self, from: Data(payload.utf8))
        #expect(decoded.spans[0].typeCode == 250, "forward compatibility: unknown codes are preserved")
        #expect(decoded.components[0].type == .other)
    }

    @Test("Out-of-range identifier indices resolve to nil")
    func outOfRangeIdentifierIndexResolvesToNil() {
        let malformed = FrozenSemanticString(
            text: "ab",
            spans: [.init(length: 2, typeCode: 0, identifierIndex: 9)],
            identifierTable: []
        )
        #expect(malformed.identifier(at: 9) == nil)
        #expect(malformed.identifier(at: UInt32.max) == nil)
        #expect(malformed.identifier(at: 0) == nil)
    }
}
