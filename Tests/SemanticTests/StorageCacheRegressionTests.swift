import Foundation
import Testing
@testable import Semantic

/// Regression tests for the storage's single shared-mutable cache (the
/// concatenated string) and for `FrozenSemanticString`'s validated decoding.
///
/// Each test asserts the behavior the code *documents* for itself.
@Suite("Storage Cache Regressions")
struct StorageCacheRegressionTests {
    // MARK: - Helpers

    /// A string whose elements are whole rows — the shape a container like
    /// `MemberList` depends on.
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

    // MARK: - frozen() Must Not Inflate Anything

    @Test("frozen() does not fill the string cache of the value it was called on")
    func frozenDoesNotFillTheSourceCache() {
        // `frozen()` documents that it never inflates its receiver: the
        // components are the storage itself (nothing to publish), and the
        // text is computed locally unless a previous render already cached it.
        let original = memberRowsString()
        #expect(original._storage.cachedString == nil)

        _ = original.frozen()

        #expect(original._storage.cachedString == nil)
    }

    @Test("frozen() does not fill the caches of nested member strings")
    func frozenDoesNotFillNestedCaches() {
        // The stronger guarantee, and the scenario the design targets: a
        // printer holds every row, freezes the assembled parent to lower its
        // footprint, and the rows must not grow caches as a side effect.
        // Containers read rows through zero-copy slices, so building and
        // freezing the parent touches no row cache.
        let rows = [
            SemanticString {
                Keyword("let")
                Space()
                Variable("a")
            },
            SemanticString {
                Keyword("let")
                Space()
                Variable("b")
            },
        ]
        let outer = SemanticString(MemberList(level: 1, rows))

        _ = outer.frozen()
        _ = outer.isEmpty

        #expect(rows[0]._storage.cachedString == nil)
        #expect(rows[1]._storage.cachedString == nil)
    }

    @Test("frozen() still uses the string cache when it is already populated")
    func frozenReusesAnAlreadyPopulatedCache() {
        // Not publishing must not mean re-computing: a value that has already
        // been rendered has the text on hand, and freezing it should cost no
        // second concatenation.
        let original = memberRowsString()
        let renderedString = original.string
        #expect(original._storage.cachedString != nil)

        let frozen = original.frozen()

        #expect(frozen.text == renderedString)
        #expect(frozen.components == original.components)
    }

    // MARK: - Streaming Never Materializes Structure

    @Test("Appending an atomic leaf component keeps the one-to-one representation")
    func atomicLeafComponentAppendKeepsOneToOne() {
        // `Keyword`, `Space`, `BreakLine`, `Indent`, `TypeName`, … are all
        // `PlainAtomicSemanticComponent`s: they flatten to exactly one
        // `AtomicComponent` and say so in their conformance, so appending one
        // is exactly a streamed append — no boundary table, no allocation.
        var streamed = SemanticString()
        streamed.append("prefix", type: .standard)
        #expect(streamed._storage.elementEndOffsets == nil)

        streamed.append(Keyword("func"))

        #expect(streamed._storage.elementEndOffsets == nil)
        #expect(streamed.string == "prefixfunc")
        #expect(streamed.components.last?.type == .keyword)
    }

    @Test("Appending Space and Indent keeps the one-to-one representation")
    func whitespaceComponentAppendKeepsOneToOne() {
        var streamed = SemanticString()
        streamed.append("prefix", type: .standard)

        streamed.append(Space())
        streamed.append(Indent(level: 1))

        #expect(streamed._storage.elementEndOffsets == nil)
        #expect(streamed.string == "prefix     ")
    }

    // MARK: - FrozenSemanticString Validation

    @Test("Decoding rejects spans that split a Unicode scalar")
    func frozenDecodingRejectsSpansThatSplitUnicodeScalars() throws {
        // Codable decoding is the validated construction path, and
        // `enumerateSpans` documents that "span boundaries are always Unicode
        // scalar aligned, so the slices are valid substrings". Byte coverage
        // alone does not establish that, so decoding walks the boundaries.
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
        // The stripe lock guards the lazy `string` fill — the storage's only
        // shared-mutable state. Copy-on-write copies contents without touching
        // the cache, and `components` reads the storage array directly, so
        // this pairing (readers filling a cold shared cache while other tasks
        // copy-and-mutate the same storage) is the whole synchronization
        // surface.
        //
        // Assertions alone prove nothing here — run it under ThreadSanitizer
        // (`swift test --sanitize=thread`) to exercise what it is for.
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
