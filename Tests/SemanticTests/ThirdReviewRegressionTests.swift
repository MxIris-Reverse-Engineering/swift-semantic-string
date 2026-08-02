import Foundation
import Testing
@testable import Semantic

// MARK: - Fixtures

/// A third-party leaf whose override emits exactly one zero-length atom.
/// The shape behind the round-3 container-emptiness finding: the default
/// `AtomicSemanticComponent.buildComponents()` filters empty strings, so only
/// a custom override can hand a container an empty atom.
private struct SingleEmptyAtomLeaf: SemanticStringComponent {
    func buildComponents() -> [AtomicComponent] {
        [AtomicComponent(string: "", type: .comment)]
    }
}

// MARK: - Tests

@Suite("Third review round regressions")
struct ThirdReviewRegressionTests {
    // MARK: F3 — hand-built arrays keep element slots for dropped empty atoms

    @Test("Equal values agree on isEmpty however they were built")
    func handBuiltEmptyAtomKeepsItsElementSlot() {
        var appendedEmpty = SemanticString()
        appendedEmpty.append(AtomicComponent(string: "", type: .standard))
        let handBuiltEmpty = SemanticString(components: [AtomicComponent(string: "", type: .standard)])

        #expect(appendedEmpty == handBuiltEmpty)
        #expect(appendedEmpty.hashValue == handBuiltEmpty.hashValue)
        // Equal values must not give opposite answers to `isEmpty`, or passing
        // one through a Set/Dictionary key silently changes rendering
        // decisions built on it. Since the fifth round `isEmpty` reports
        // components — the measure `==` compares — so agreement holds by
        // construction, including against a value that never saw the empty
        // append at all.
        #expect(appendedEmpty.isEmpty == true)
        #expect(handBuiltEmpty.isEmpty == true)
        #expect(appendedEmpty == SemanticString())
        #expect(appendedEmpty.first == nil)
        #expect(appendedEmpty.count == 0)
        // Sixth round: the append is a complete no-op — no element slot.
        // The hand-built array initializer still records one slot per input
        // component; both shapes are container-layout bookkeeping invisible
        // to every public measure, so the divergence is unobservable.
        #expect(appendedEmpty._storage.elementCount == 0)
        #expect(handBuiltEmpty._storage.elementCount == 1)
    }

    @Test("Hand-built arrays record one element per input component")
    func handBuiltArrayElementGranularity() {
        let value = SemanticString(components: [
            AtomicComponent(string: "a", type: .standard),
            AtomicComponent(string: "", type: .standard),
            AtomicComponent(string: "b", type: .standard),
        ])
        // Atoms drop the empty entry; the element table keeps its slot.
        #expect(value.count == 2)
        #expect(value.components.map(\.string) == ["a", "b"])
        #expect(value._storage.elementEndOffsets == [1, 1, 2])
        #expect(value._storage.elementCount == 3)
        #expect(value.isEmpty == false)
    }

    @Test("Hand-built arrays without empty atoms stay one-to-one")
    func handBuiltArrayWithoutEmptiesStaysOneToOne() {
        let value = SemanticString(components: [
            AtomicComponent(string: "a", type: .standard),
            AtomicComponent(string: "b", type: .standard),
        ])
        #expect(value._storage.elementEndOffsets == nil)
        #expect(value._storage.elementCount == 2)
    }

    // MARK: F2 — frozen() preserves equality across canonical equivalence

    @Test("Canonically equivalent equal sources freeze to equal snapshots")
    func canonicallyEquivalentSourcesFreezeEqual() {
        // NFC "é" (2 UTF-8 bytes) and NFD "e" + combining acute (3 bytes):
        // String equality is canonical, so the sources compare equal —
        // freezing must not turn an equal pair into an unequal one.
        let nfc = SemanticString(components: [AtomicComponent(string: "\u{00E9}", type: .standard)])
        let nfd = SemanticString(components: [AtomicComponent(string: "e\u{0301}", type: .standard)])
        #expect(nfc == nfd)
        #expect(nfc.hashValue == nfd.hashValue)

        let frozenNFC = nfc.frozen()
        let frozenNFD = nfd.frozen()
        #expect(frozenNFC == frozenNFD)
        #expect(frozenNFC.hashValue == frozenNFD.hashValue)
        #expect(Set([frozenNFC, frozenNFD]).count == 1)
    }

    @Test("Byte-identical spans with different types stay unequal")
    func differentTypesStayUnequalWhenFrozen() {
        let keyword = SemanticString(components: [AtomicComponent(string: "let", type: .keyword)])
        let standard = SemanticString(components: [AtomicComponent(string: "let", type: .standard)])
        #expect(keyword.frozen() != standard.frozen())
    }

    // MARK: F6 — oversized tokens split at grapheme cluster boundaries

    @Test("Oversized token splits at grapheme cluster boundaries")
    func oversizedTokenSplitsAtGraphemeClusterBoundaries() {
        // 4000 ZWJ family emoji, 25 UTF-8 bytes each: 100 000 bytes, so the
        // token must split. A split inside a cluster inflates the total
        // `Character` count across the pieces and leaves a dangling ZWJ at a
        // span edge, which renders as a broken emoji for span consumers.
        let familyEmoji = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let bigToken = String(repeating: familyEmoji, count: 4000)
        let frozen = SemanticString(components: [AtomicComponent(string: bigToken, type: .comment)]).frozen()

        #expect(frozen.spans.count > 1)
        #expect(frozen.string == bigToken)

        var pieceCharacterTotal = 0
        var danglingJoinerCount = 0
        frozen.enumerateSpans { spanText, _, _ in
            pieceCharacterTotal += spanText.count
            if spanText.unicodeScalars.last == "\u{200D}" {
                danglingJoinerCount += 1
            }
        }
        #expect(pieceCharacterTotal == bigToken.count)
        #expect(danglingJoinerCount == 0)
    }

    @Test("Oversized single-scalar runs still split within UInt16.max")
    func oversizedPlainTokenStillSplits() {
        // The plain-ASCII shape must keep working after the grapheme-aware
        // rewrite, and every span must stay within the UInt16 length limit.
        let bigToken = String(repeating: "x", count: 150_000)
        let frozen = SemanticString(components: [AtomicComponent(string: bigToken, type: .comment)]).frozen()
        #expect(frozen.spans.count == 3)
        #expect(frozen.spans.allSatisfy { $0.length > 0 })
        #expect(frozen.spans.map { Int($0.length) }.reduce(0, +) == 150_000)
        #expect(frozen.string == bigToken)
    }

    // MARK: F5 — unchecked-init violations trap in every direction

    @Test("enumerateSpans traps when spans undercover the text")
    func enumerateSpansTrapsOnUndercoverage() async {
        await #expect(processExitsWith: .failure) {
            let malformed = FrozenSemanticString(
                text: "ab",
                spans: [.init(length: 1, typeCode: 0, identifierIndex: 0)],
                identifierTable: []
            )
            malformed.enumerateSpans { _, _, _ in }
        }
    }

    @Test("enumerateSpans traps when a boundary splits a Unicode scalar")
    func enumerateSpansTrapsOnScalarMisalignment() async {
        await #expect(processExitsWith: .failure) {
            let malformed = FrozenSemanticString(
                text: "\u{00E9}",
                spans: [
                    .init(length: 1, typeCode: 2, identifierIndex: 0),
                    .init(length: 1, typeCode: 0, identifierIndex: 0),
                ],
                identifierTable: []
            )
            malformed.enumerateSpans { _, _, _ in }
        }
    }

    // MARK: F7 — pinned: hostile span counts are rejected

    @Test("Decoder rejects a payload declaring more spans than text bytes")
    func decoderRejectsOversizedSpanCount() {
        // Every span covers at least one byte, so the span count is bounded
        // by the text's byte count. The decoder now proves this right after
        // the lengths column — before the type-code and identifier columns
        // are materialized — so a hostile payload cannot make validation
        // itself allocate multiples of its own size.
        let payload = """
        {"text":"a","spanLengths":[1,1,1],"spanTypeCodes":[0,0,0],"spanIdentifierIndices":[0,0,0],"identifierTable":[]}
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(FrozenSemanticString.self, from: Data(payload.utf8))
        }
    }

    // MARK: F1 — pinned: container emptiness sees the filtered flattening

    @Test("A custom leaf flattening to nothing is empty to containers")
    func customEmptyLeafIsEmptyToContainers() {
        // Intended divergence from main, documented in
        // docs/ThirdReviewFixes.md: main skipped `Keyword("")` (its default
        // `buildComponents()` returns `[]`) but rendered a row/separator for a
        // custom leaf emitting one *empty atom*. Both shapes flatten to the
        // same nothing; containers now treat them identically.
        let blank = SingleEmptyAtomLeaf()

        let groupOutput = SemanticString {
            Group {
                blank
                Keyword("k")
            }.separator(Standard("-"))
        }.string
        #expect(groupOutput == "k")

        let joinedOutput = SemanticString {
            Joined(separator: ", ", prefix: "(", suffix: ")") {
                blank
                Keyword("k")
            }
        }.string
        #expect(joinedOutput == "(k)")

        let memberListOutput = SemanticString {
            MemberList(level: 1) {
                blank
                Keyword("k")
            }
        }.string
        #expect(memberListOutput == "\n    k\n")

        let declarationBlockOutput = SemanticString {
            DeclarationBlock(level: 0) {
                Keyword("struct")
            } body: {
                blank
            }
        }.string
        #expect(declarationBlockOutput == "struct {}")

        let rowsOutput = SemanticString {
            Rows(level: 1) {
                blank
                blank
            }
        }.string
        #expect(rowsOutput == "")
    }

    // MARK: F9 — pinned: freezing preserves isEmpty

    @Test("Freezing a zero-output-element value yields an empty snapshot")
    func freezingZeroOutputElementsYieldsEmptySnapshot() {
        // Since the fifth round both measures report "no components": the
        // builder's element slot is layout bookkeeping that neither
        // `SemanticString.isEmpty` nor the snapshot observes, so freezing
        // preserves `isEmpty` — there is no longer a flip to pin, and that
        // agreement is itself the regression guard.
        var value = SemanticString()
        value.append(EmptyComponent())
        #expect(value.isEmpty == true)
        #expect(value.frozen().isEmpty)
        #expect(value.frozen().string.isEmpty)
        #expect(value.isEmpty == value.frozen().isEmpty)
    }
}
