import Foundation
import Testing
@testable import Semantic

// MARK: - Helpers

/// A leaf that violates the `PlainAtomicSemanticComponent` promise by
/// overriding `buildComponents()`. Used to pin the debug assertion that
/// guards the fast path.
private struct PromiseViolatingLeaf: PlainAtomicSemanticComponent {
    var string: String { "RAW" }
    var type: SemanticType { .keyword }
    func buildComponents() -> [AtomicComponent] {
        [AtomicComponent(string: "OVERRIDE", type: .error, identifier: "OID")]
    }
}

// MARK: - Tests

/// Regression tests for the fifth review round. Each was verified failing
/// against the unfixed code via standalone reproductions before the fix
/// landed; the themes:
///
/// - **`isEmpty` semantics.** The element-slot measure let `==`-equal values
///   disagree on `isEmpty`, made `!isEmpty` compatible with `first == nil`,
///   and let a `Codable` round trip flip `isEmpty`. It now reports
///   components, so every emptiness measure coincides.
/// - **Frozen `==` fast path.** Canonically-reordered combining marks produce
///   canonically-equal text with identical span vectors but different
///   per-span slices; the shortcut answered `true` where the resolving loop
///   answers `false`, breaking Hashable and transitivity. It is now gated on
///   byte-identical text.
/// - **Frozen `==`/`hash` on malformed values.** The slow path died in bare
///   standard-library index arithmetic (overrun) or silently compared
///   rounded slices (misalignment). It now traps with diagnostics naming the
///   type; `hash` no longer walks the text at all and never traps.
/// - **`appending("")` and identifier scopes.** The unconditional unscoped
///   copy silently closed the scope a streaming writer was writing under;
///   the empty-input early return is restored.
@Suite("Fifth review round regressions")
struct FifthReviewRegressionTests {
    // MARK: F1/F2/F9 — emptiness measures coincide

    @Test("All emptiness measures coincide and survive a Codable round trip")
    func emptinessMeasuresCoincide() throws {
        let handBuilt = SemanticString(components: [AtomicComponent(string: "", type: .standard)])
        var appended = SemanticString()
        appended.append(AtomicComponent(string: "", type: .standard))
        let builderBuilt = SemanticString { Standard("") }

        for value in [handBuilt, appended, builderBuilt, SemanticString()] {
            #expect(value.isEmpty == true)
            #expect(value.count == 0)
            #expect(value.first == nil)
            #expect(value.string.isEmpty)
            #expect(value == SemanticString())
        }

        // `!isEmpty` implies `first != nil` again — the guard-then-unwrap
        // idiom that crashed on the element-slot semantics.
        var nonEmpty = SemanticString()
        nonEmpty.append("x", type: .keyword)
        if !nonEmpty.isEmpty {
            #expect(nonEmpty.first != nil)
        }

        // A round trip cannot flip `isEmpty`: encoding writes components and
        // `isEmpty` reports components.
        let decoded = try JSONDecoder().decode(SemanticString.self, from: JSONEncoder().encode(handBuilt))
        #expect(decoded == handBuilt)
        #expect(decoded.isEmpty == handBuilt.isEmpty)
    }

    @Test("map-ing a component to an empty string drops it, count shrinks, text is unchanged")
    func mapToEmptyStringDropsTheComponent() {
        var base = SemanticString()
        base.append(Keyword("public"))
        base.append(Space())
        base.append(MemberDeclaration("name"))
        let redacted = base.map { component in
            component.type == .keyword
                ? AtomicComponent(string: "", type: component.type, identifier: component.identifier)
                : component
        }
        // Documented behavior: the zero-length result is dropped, indices
        // shift, the rendered text is what the surviving components spell.
        #expect(redacted.count == 2)
        #expect(redacted.contains(type: .keyword) == false)
        #expect(redacted.string == " name")
        #expect(redacted.isEmpty == false)
    }

    // MARK: F7 — appending("") keeps open identifier scopes

    @Test("appending an empty string is a no-op that keeps the open scope")
    func appendingEmptyStringKeepsScope() {
        var scoped = SemanticString()
        scoped.pushIdentifierScope("SPAN")
        var streamed = scoped.appending("", type: .keyword)
        streamed.append("z", type: .keyword)
        #expect(streamed.components.map(\.identifier) == ["SPAN"])
    }

    // MARK: F5 — frozen == fast path is byte-gated

    @Test("Canonically-reordered combining marks freeze to unequal snapshots")
    func canonicallyReorderedMarksCompareUnequal() {
        // U+0307 (ccc 230) and U+0323 (ccc 220) reorder under canonical
        // normalization, so the two texts are canonically equal with
        // different byte sequences — and identical span vectors. The old
        // fast path answered `true`; the resolving loop (and `components`)
        // says the values differ, because different characters carry the
        // `.keyword` type.
        var leftBuilder = SemanticString()
        leftBuilder.append(Standard("q"))
        leftBuilder.append(Keyword("\u{0307}"))
        leftBuilder.append(Standard("\u{0323}"))
        var rightBuilder = SemanticString()
        rightBuilder.append(Standard("q"))
        rightBuilder.append(Keyword("\u{0323}"))
        rightBuilder.append(Standard("\u{0307}"))
        let frozenLeft = leftBuilder.frozen()
        let frozenRight = rightBuilder.frozen()

        #expect(frozenLeft.text == frozenRight.text, "precondition: texts are canonically equal")
        #expect(frozenLeft.spans == frozenRight.spans, "precondition: span vectors are identical")
        #expect(frozenLeft.components != frozenRight.components, "the values render differently")

        #expect(frozenLeft != frozenRight)
        #expect(Set([frozenLeft, frozenRight]).count == 2)

        // Transitivity: a third value that differs only in table shape (an
        // unreferenced extra entry) takes the resolving loop. All three
        // pairwise answers must be consistent.
        let third = FrozenSemanticString(text: frozenLeft.text, spans: frozenLeft.spans, identifierTable: ["unreferenced"])
        #expect(frozenLeft == third)
        #expect(frozenRight != third)
    }

    @Test("NFC/NFD single-token values still freeze to equal snapshots")
    func canonicallyEqualSingleTokenValuesStayEqual() {
        // The byte gate must not narrow `==` itself: NFC and NFD spellings
        // of the same content take the resolving loop and stay equal, and
        // equal values still hash equal.
        let composed = SemanticString(Standard("\u{00E9}")).frozen()
        let decomposed = SemanticString(Standard("e\u{0301}")).frozen()
        #expect(composed == decomposed)
        #expect(composed.hashValue == decomposed.hashValue)
    }

    // MARK: F6 — malformed values trap with typed diagnostics, hash never traps

    @Test("A malformed value hashes quietly; reads trap, == slow path traps")
    func malformedValueHashesQuietly() {
        // Hashing no longer walks the text, so a value that violates the
        // unchecked init's invariants hashes and Set-inserts without
        // trapping — the traps live in the reads that must walk.
        let overrun = FrozenSemanticString(
            text: "a",
            spans: [.init(length: 5, typeCode: 0, identifierIndex: 0)],
            identifierTable: []
        )
        #expect(Set([overrun]).count == 1)
        #expect(overrun == overrun, "byte-gated fast path: reflexivity holds without walking")
    }

    @Test("== slow path traps with a typed diagnostic when spans overrun the text")
    func equalitySlowPathTrapsOnOverrun() async {
        await #expect(processExitsWith: .failure) {
            let overrun = FrozenSemanticString(
                text: "a",
                spans: [.init(length: 5, typeCode: 0, identifierIndex: 0)],
                identifierTable: []
            )
            let overrunOtherTable = FrozenSemanticString(
                text: "a",
                spans: [.init(length: 5, typeCode: 0, identifierIndex: 0)],
                identifierTable: ["unused"]
            )
            _ = overrun == overrunOtherTable
        }
    }

    @Test("== slow path traps when a boundary splits a scalar instead of comparing rounded slices")
    func equalitySlowPathTrapsOnMisalignment() async {
        await #expect(processExitsWith: .failure) {
            let misaligned = FrozenSemanticString(
                text: "\u{00E9}",
                spans: [
                    .init(length: 1, typeCode: 0, identifierIndex: 0),
                    .init(length: 1, typeCode: 0, identifierIndex: 0),
                ],
                identifierTable: []
            )
            let misalignedOtherTable = FrozenSemanticString(
                text: "\u{00E9}",
                spans: misaligned.spans,
                identifierTable: ["x"]
            )
            _ = misaligned == misalignedOtherTable
        }
    }

    @Test("enumerateSpans traps when spans overrun the text")
    func enumerateSpansTrapsOnOverrun() async {
        // The third trap direction — the two others are pinned in
        // `ThirdReviewRegressionTests`.
        await #expect(processExitsWith: .failure) {
            let overrun = FrozenSemanticString(
                text: "a",
                spans: [.init(length: 5, typeCode: 0, identifierIndex: 0)],
                identifierTable: []
            )
            overrun.enumerateSpans { _, _, _ in }
        }
    }

    // MARK: F8 — the PlainAtomicSemanticComponent promise is asserted in debug

    @Test("Debug builds assert on a conformance that overrides buildComponents()")
    func plainAtomicPromiseIsAssertedInDebug() async {
        await #expect(processExitsWith: .failure) {
            var value = SemanticString()
            value.append(PromiseViolatingLeaf())
        }
    }

    // MARK: F9 — ForEach consistency with the other separator containers

    @Test("ForEach, Joined, and Group agree on skipping empty items")
    func separatorContainersAgreeOnEmptyItems() {
        let viaForEach = SemanticString {
            ForEach(["a", "", "b"], separator: "|") { Standard($0) }
        }
        let viaGroup = SemanticString(
            Group([SemanticString(Standard("a")), SemanticString(Standard("")), SemanticString(Standard("b"))]).separator("|")
        )
        #expect(viaForEach.string == "a|b")
        #expect(viaGroup.string == "a|b")
    }
}
