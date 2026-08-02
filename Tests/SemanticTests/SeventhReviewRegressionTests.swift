import Foundation
import Testing
@testable import Semantic

// MARK: - Tests

/// Defects the seventh review turned up, written fail-first.
///
/// The zero-length span tests below all failed before the fix: nothing
/// trapped, `enumerateSpans(_:)` yielded an empty `Substring`, and
/// `components` manufactured the zero-length `AtomicComponent` that the rest
/// of the library exists to exclude.
@Suite("Seventh Review Regressions")
struct SeventhReviewRegressionTests {
    // MARK: Zero-Length Spans

    /// The unchecked initializer documents four invariants and promises that
    /// violating them traps in every read that walks the text. Three
    /// directions were enforced by the third round — overrun, undercoverage,
    /// scalar misalignment — but a zero-length span, listed in the very same
    /// sentence, walked straight through. The decoder rejected it all along
    /// (see `FrozenSemanticString+Codable.swift`), so the two entry points
    /// disagreed about the same invariant.
    @Test("enumerateSpans traps on a zero-length span")
    func enumerateSpansTrapsOnZeroLengthSpan() async {
        await #expect(processExitsWith: .failure) {
            let malformed = FrozenSemanticString(
                text: "",
                spans: [.init(length: 0, typeCode: 0, identifierIndex: 0)],
                identifierTable: []
            )
            malformed.enumerateSpans { _, _, _ in }
        }
    }

    /// `components` walks through `enumerateSpans(_:)`, so it must trap too.
    /// Before the fix it returned `[AtomicComponent(string: "")]` — a value
    /// storage, flattening, freezing, and the decoder all forbid.
    @Test("components traps on a zero-length span instead of manufacturing an empty atom")
    func componentsTrapsOnZeroLengthSpan() async {
        await #expect(processExitsWith: .failure) {
            let malformed = FrozenSemanticString(
                text: "",
                spans: [.init(length: 0, typeCode: 0, identifierIndex: 0)],
                identifierTable: []
            )
            _ = malformed.components
        }
    }

    /// A zero-length span between two real ones is the shape that silently
    /// corrupted a round trip: `components` returned `["a", "", "b"]`,
    /// `SemanticString(components:)` dropped the empty entry, and the
    /// rebuilt value no longer equalled the original when re-frozen.
    @Test("an interleaved zero-length span traps rather than corrupting a round trip")
    func interleavedZeroLengthSpanTraps() async {
        await #expect(processExitsWith: .failure) {
            let malformed = FrozenSemanticString(
                text: "ab",
                spans: [
                    .init(length: 1, typeCode: 0, identifierIndex: 0),
                    .init(length: 0, typeCode: 0, identifierIndex: 0),
                    .init(length: 1, typeCode: 0, identifierIndex: 0),
                ],
                identifierTable: []
            )
            _ = malformed.components
        }
    }

    /// The `==` resolving path walks the same way and must trap the same way.
    /// The tables differ so the byte-identical fast path cannot swallow the
    /// comparison — that shortcut deliberately does not walk, and keeps its
    /// quiet behavior.
    @Test("== slow path traps on a zero-length span")
    func equalitySlowPathTrapsOnZeroLengthSpan() async {
        await #expect(processExitsWith: .failure) {
            let left = FrozenSemanticString(
                text: "a",
                spans: [
                    .init(length: 0, typeCode: 0, identifierIndex: 0),
                    .init(length: 1, typeCode: 0, identifierIndex: 0),
                ],
                identifierTable: []
            )
            let right = FrozenSemanticString(
                text: "a",
                spans: [
                    .init(length: 0, typeCode: 0, identifierIndex: 0),
                    .init(length: 1, typeCode: 0, identifierIndex: 0),
                ],
                identifierTable: ["unused"]
            )
            _ = left == right
        }
    }

    /// `hash(into:)` deliberately does not walk the text, so it stays quiet
    /// on a malformed value — the fifth round made that a design decision
    /// (hashing a 500k-span value got 62% faster, and hashing can no longer
    /// trap). The new precondition must not have leaked into it.
    @Test("hash stays quiet on a zero-length span")
    func hashDoesNotTrapOnZeroLengthSpan() {
        let malformed = FrozenSemanticString(
            text: "",
            spans: [.init(length: 0, typeCode: 0, identifierIndex: 0)],
            identifierTable: []
        )
        var hasher = Hasher()
        malformed.hash(into: &hasher)
        #expect(malformed.count == 1)
    }

    /// Well-formed values must be unaffected: every span carries a real
    /// length, so the guard never fires on anything `frozen()` produces.
    @Test("well-formed frozen values still read normally")
    func wellFormedValuesAreUnaffected() {
        var built = SemanticString()
        built.append("struct", type: .keyword)
        built.append(Space())
        built.append("Point", type: .type(.struct, .name))
        let frozen = built.frozen()

        var yielded: [String] = []
        frozen.enumerateSpans { spanText, _, _ in yielded.append(String(spanText)) }

        #expect(yielded == ["struct", " ", "Point"])
        #expect(frozen.components.allSatisfy { !$0.string.isEmpty })
        #expect(frozen == built.frozen())
    }
}
