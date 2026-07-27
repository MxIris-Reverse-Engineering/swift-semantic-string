import Foundation
import Testing
@testable import Semantic

/// Regression tests for API introduced by the two-state storage change
/// (`compact()`, `FrozenSemanticString`, the flat/tree fast paths). These
/// reference symbols that only exist after the change, so unlike
/// `StorageDivergenceRegressionTests` they cannot be run against the previous
/// revision for comparison.
///
/// Each test asserts the behavior the new code *documents* for itself.
@Suite("Two-State Storage Regressions")
struct TwoStateStorageRegressionTests {
    // MARK: - Helpers

    /// A tree-state string whose elements are whole rows — the shape a
    /// container like `MemberList` depends on.
    private func memberRowsString() -> SemanticString {
        let firstMember = SemanticString {
            Keyword("var")
            Space()
            Variable("x")
        }
        let secondMember = SemanticString {
            Keyword("var")
            Space()
            Variable("y")
        }
        return SemanticString {
            firstMember
            secondMember
        }
    }

    // MARK: - compact() Must Not Change Observable Behavior

    @Test("compact() leaves isEmpty unchanged")
    func compactionLeavesIsEmptyUnchanged() {
        // `compact()` documents `components`, `string`, equality, hashing and
        // Codable output as unchanged. `isEmpty` reads a different array before
        // and after compaction, so it is not on that list — but a caller has
        // no way to know that from the documentation.
        var semanticString = SemanticString {
            EmptyComponent()
        }
        let isEmptyBeforeCompaction = semanticString.isEmpty

        semanticString.compact()

        #expect(semanticString.isEmpty == isEmptyBeforeCompaction)
    }

    @Test("Compaction changes element granularity, which is why it stays internal")
    func compactionChangesElementGranularity() {
        // Compaction replaces row elements with token elements. A container
        // that treats one element as one row therefore renders a compacted
        // value differently — one row per token instead of one row per member.
        // That is unavoidable, and it is exactly why `compact()` must not be
        // public: no type-level signal stops a caller from passing a compacted
        // value as prebuilt `content:`. Public callers get `frozen()`, whose
        // type forbids further composition.
        let memberRows = memberRowsString()

        let renderedFromTree = SemanticString {
            MemberList(level: 1, content: memberRows)
        }
        let renderedFromCompacted = SemanticString {
            MemberList(level: 1, content: memberRows.compacted())
        }

        #expect(renderedFromTree.string == "\n    var x\n    var y\n")
        #expect(renderedFromCompacted.string != renderedFromTree.string)
    }

    @Test("compacted() does not fill the cache of the value it was called on")
    func compactedDoesNotFillTheSourceCache() {
        // `compact()` reads `components` *before* `makeUnique()`, so while the
        // storage is still shared the flattened array is published into the
        // original's cache and then copied. A memory-optimization API ends up
        // increasing the footprint of the pair.
        let original = memberRowsString()
        #expect(original._storage.cachedComponents == nil)

        _ = original.compacted()

        #expect(original._storage.cachedComponents == nil)
    }

    // MARK: - The Flat Fast Path Must Cover Every Leaf Component

    @Test("Appending an atomic leaf component keeps the flat representation")
    func atomicLeafComponentAppendKeepsFlatStorage() {
        // `Keyword`, `Space`, `BreakLine`, `Indent`, `TypeName`, … are all
        // `AtomicSemanticComponent`s that flatten to exactly one
        // `AtomicComponent`. The fast path tests for the erased box type
        // `AtomicComponent` instead, so every one of them forces the whole
        // accumulated content to be re-boxed into the tree form — the cost the
        // flat state exists to avoid.
        //
        // NOTE: this contradicts `TwoStateStorageTests`'
        // `genericLeafComponentAppendConvertsToTree`, which pins the current
        // behavior. Only one of the two can stand.
        var streamed = SemanticString()
        streamed.append("prefix", type: .standard)
        #expect(streamed._storage.isFlat)

        streamed.append(Keyword("func"))

        #expect(streamed._storage.isFlat)
        #expect(streamed.string == "prefixfunc")
        #expect(streamed.components.last?.type == .keyword)
    }

    @Test("Appending Space and Indent keeps the flat representation")
    func whitespaceComponentAppendKeepsFlatStorage() {
        var streamed = SemanticString()
        streamed.append("prefix", type: .standard)

        streamed.append(Space())
        streamed.append(Indent(level: 1))

        #expect(streamed._storage.isFlat)
        #expect(streamed.string == "prefix     ")
    }

    // MARK: - FrozenSemanticString Validation

    @Test("Decoding rejects spans that split a Unicode scalar")
    func frozenDecodingRejectsSpansThatSplitUnicodeScalars() throws {
        // `init(text:spans:identifierTable:)` names Codable decoding as one of
        // the two *validated* construction paths, and `enumerateSpans`
        // documents that "span boundaries are always Unicode scalar aligned, so
        // the slices are valid substrings". Decoding checks column counts,
        // total byte coverage and identifier range — but not alignment.
        //
        // "汉字" is 6 UTF-8 bytes; lengths [1, 5] cover exactly 6 bytes while
        // cutting the first scalar in half.
        let payload = """
        {
          "text": "汉字",
          "spanLengths": [1, 5],
          "spanTypeCodes": [0, 0],
          "spanIdentifierIndices": [0, 0],
          "identifierTable": []
        }
        """

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(FrozenSemanticString.self, from: Data(payload.utf8))
        }
    }

    @Test("Enumerated spans partition multi-byte text exactly")
    func enumeratedSpansPartitionMultiByteText() throws {
        // The positive counterpart: every span boundary of a legitimately
        // frozen string lands on a scalar boundary even when tokens mix ASCII,
        // CJK, and emoji, so the slices reconstruct the text token for token.
        let semanticString = SemanticString {
            Keyword("变量")
            Space()
            Variable("名字")
            Standard(" = ")
            Standard("🇨🇳👨‍👩‍👧")
        }
        let frozen = semanticString.frozen()

        var spanTexts: [String] = []
        frozen.enumerateSpans { spanText, _, _ in
            spanTexts.append(String(spanText))
        }

        #expect(spanTexts == semanticString.components.map(\.string))
        #expect(spanTexts.joined() == frozen.text)
        #expect(frozen.text == semanticString.string)
    }

    // MARK: - Concurrency

    @Test("Reading shared storage while a copy is mutated is race free")
    func concurrentReadWhileCopyOnWriteMutation() async {
        // The shared cache lock guards the lazy fills in `string` /
        // `components`, but `Storage.init(copying:)` — reached from
        // `makeUnique()` on the copy-on-write path — reads `cachedComponents`
        // and `cachedString` without taking it. This test exercises exactly
        // that pairing: readers filling a cold shared cache while other tasks
        // copy-and-mutate the same storage.
        //
        // It passes under a normal run; run it under ThreadSanitizer
        // (`swift test --sanitize=thread`) to see the race.
        for _ in 0 ..< 64 {
            let shared = memberRowsString()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = shared.string }
                group.addTask { _ = shared.components }
                group.addTask {
                    var mutatedCopy = shared
                    mutatedCopy.append("z", type: .standard)
                    _ = mutatedCopy.string
                }
                group.addTask {
                    var mutatedCopy = shared
                    mutatedCopy.append(Keyword("k"))
                    _ = mutatedCopy.count
                }
                await group.waitForAll()
            }
        }
    }
}
