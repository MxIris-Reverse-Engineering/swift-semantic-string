/// An immutable, memory-compact snapshot of a `SemanticString`.
///
/// `SemanticString` is the *builder*: composable, streamable, mutable.
/// `FrozenSemanticString` is the *terminal form* for content that is fully
/// built and will only ever be read — rendered, encoded, exported, or
/// searched. Freezing collapses the per-token component representation
/// (40 bytes per `AtomicComponent` plus heap allocations for strings longer
/// than 15 UTF-8 bytes) into three flat allocations:
///
/// - `text`: the complete UTF-8 text, stored exactly once
/// - `spans`: one 8-byte `Span` per token (UTF-8 length, semantic type code,
///   identifier table index)
/// - `identifierTable`: interned span identifiers; measured corpora carry
///   identifiers on ~8% of tokens with only a few thousand distinct values
///
/// Every stored property is `let`, so the type is unconditionally `Sendable`
/// with no locks and no copy-on-write machinery. There is deliberately no
/// mutation API and no conversion back to `SemanticString`: freezing is
/// one-way, which pins the "build, then read-only" lifecycle at the type
/// level.
public struct FrozenSemanticString: Sendable {
    /// One semantic run of UTF-8 text. Spans carry lengths, not offsets —
    /// consumers walk them sequentially, accumulating positions.
    public struct Span: Sendable, Hashable {
        /// UTF-8 byte length of the run.
        ///
        /// The guarantee that holds for **every** span boundary is Unicode
        /// *scalar* alignment. Grapheme cluster (`Character`) alignment holds
        /// only *within* a token: when a single token exceeds `UInt16.max`
        /// bytes it is split into consecutive spans with identical `typeCode`
        /// and `identifierIndex` at cluster boundaries (a single cluster that
        /// itself exceeds `UInt16.max` bytes — a pathological joiner chain —
        /// degrades to scalar splits). Span boundaries *between* tokens sit
        /// wherever the builder put the tokens, and adjacent tokens can
        /// legitimately split one cluster — `Keyword("e")` followed by
        /// `Standard("\u{0301}")` freezes to two spans whose boundary falls
        /// inside the composed character. Consumers that need cluster-aligned
        /// runs must merge adjacent spans themselves.
        public let length: UInt16

        /// `SemanticType` encoded via `SemanticType.frozenTypeCode`.
        public let typeCode: UInt8

        /// 1-based index into `identifierTable`; `0` means no identifier.
        public let identifierIndex: UInt32

        @inlinable
        public init(length: UInt16, typeCode: UInt8, identifierIndex: UInt32) {
            self.length = length
            self.typeCode = typeCode
            self.identifierIndex = identifierIndex
        }
    }

    /// The complete text, stored once. `Span` lengths partition its UTF-8
    /// view exactly.
    public let text: String

    public let spans: [Span]

    /// Interned span identifiers, referenced 1-based by
    /// `Span.identifierIndex`.
    ///
    /// Not required to be minimal: a decoded value keeps whatever table it
    /// arrived with, including duplicate or unreferenced entries. Equality and
    /// hashing resolve identifiers through the table rather than comparing it
    /// verbatim, so table shape is not observable.
    public let identifierTable: [String]

    /// Creates a frozen string from raw parts. The caller is responsible for
    /// the invariants: `spans` lengths partition `text`'s UTF-8 view exactly,
    /// no span has zero length, and boundaries fall on Unicode scalars.
    /// Violating *those* invariants traps, with a diagnostic naming this
    /// type, in every read that walks the text — `enumerateSpans(_:)`,
    /// `components`, and `==`'s span-resolving path — a deliberate loud
    /// failure, because silently truncating a mis-sliced value would be far
    /// harder to debug. `hash(into:)` and the property reads (`string`,
    /// `count`, `isEmpty`) do not walk the text and return quietly.
    ///
    /// Two fields degrade instead of trapping, on every construction path,
    /// decoding included: an out-of-range `identifierIndex` resolves to `nil`,
    /// and an unknown `typeCode` resolves to `.other`. Both are deliberate
    /// forward compatibility — a payload from a *newer* encoder must stay
    /// readable — so `Codable` decoding validates the length/coverage/alignment
    /// invariants but rejects neither an unknown type code nor an out-of-range
    /// identifier index; it keeps both verbatim.
    @inlinable
    public init(text: String, spans: [Span], identifierTable: [String]) {
        self.text = text
        self.spans = spans
        self.identifierTable = identifierTable
    }
}

// MARK: - Read Access

extension FrozenSemanticString {
    /// The complete string. Free — `text` is the storage.
    @inlinable
    public var string: String { text }

    /// `true` when the snapshot renders nothing. On every validated value
    /// this is equivalent to `text.isEmpty` — no span may be zero-length, so
    /// "no spans" and "no text" coincide.
    ///
    /// This is the same measure as `SemanticString.isEmpty`, which likewise
    /// reports "no components": freezing preserves it. Element slots the
    /// builder records for appends that flatten to nothing are layout
    /// bookkeeping that neither measure observes, and a snapshot does not
    /// carry them — exactly as a `Codable` round trip has always dropped
    /// them.
    @inlinable
    public var isEmpty: Bool { spans.isEmpty }

    /// The number of spans.
    ///
    /// This is a span count, not a token count: a token over `UInt16.max`
    /// UTF-8 bytes occupies several spans.
    @inlinable
    public var count: Int { spans.count }

    /// Resolves a `Span.identifierIndex` against the table.
    ///
    /// Out-of-range indices resolve to `nil` rather than trapping, so a
    /// payload that reached the unchecked initializer degrades to "no
    /// identifier" instead of taking the process down. `Int(exactly:)`
    /// keeps that promise on 32-bit targets (watchOS devices), where a
    /// plain `Int(identifierIndex)` conversion would itself trap for
    /// indices above `Int32.max`.
    @inlinable
    public func identifier(at identifierIndex: UInt32) -> String? {
        guard identifierIndex != 0,
              let tableIndex = Int(exactly: identifierIndex),
              tableIndex <= identifierTable.count
        else {
            return nil
        }
        return identifierTable[tableIndex - 1]
    }

    /// Walks every span in order, yielding its text slice, resolved semantic
    /// type, and identifier. Span boundaries are always Unicode scalar
    /// aligned, so the slices are valid substrings.
    ///
    /// Spans whose `typeCode` no longer maps to a `SemanticType` (decoded
    /// from a future encoder) resolve to `.other` rather than crashing.
    ///
    /// Advances one span boundary, enforcing the unchecked initializer's
    /// invariants with diagnostics that name this type: a span that overruns
    /// the text and a boundary inside a multi-byte scalar both trap here,
    /// instead of dying in bare standard-library index arithmetic.
    @usableFromInline
    internal func spanUpperBound(after lowerBound: String.Index, spanLength: UInt16) -> String.Index {
        let utf8View = text.utf8
        guard let upperBound = utf8View.index(lowerBound, offsetBy: Int(spanLength), limitedBy: utf8View.endIndex) else {
            preconditionFailure("FrozenSemanticString spans overrun the text; the unchecked init's invariants were violated")
        }
        precondition(
            upperBound.samePosition(in: text.unicodeScalars) != nil,
            "FrozenSemanticString span boundary splits a Unicode scalar; the unchecked init's invariants were violated"
        )
        return upperBound
    }

    /// This is where the unchecked initializer's invariants are enforced, in
    /// every direction: spans that overrun the text, spans that undercover
    /// it, and a boundary inside a multi-byte scalar all trap with a
    /// diagnostic naming this type — a deliberate loud failure, because
    /// silently truncating or mis-slicing the value would be far harder to
    /// debug. The `==` resolving path walks the same way and traps the same
    /// way; `hash(into:)` does not walk the text and never traps.
    @inlinable
    public func enumerateSpans(_ body: (_ spanText: Substring, _ type: SemanticType, _ identifier: String?) -> Void) {
        var lowerBound = text.startIndex
        for span in spans {
            let upperBound = spanUpperBound(after: lowerBound, spanLength: span.length)
            let spanText = text[lowerBound ..< upperBound]
            let type = SemanticType(frozenTypeCode: span.typeCode) ?? .other
            body(spanText, type, identifier(at: span.identifierIndex))
            lowerBound = upperBound
        }
        precondition(
            lowerBound == text.endIndex,
            "FrozenSemanticString spans undercover the text; the unchecked init's invariants were violated"
        )
    }

    /// Materializes the spans as `AtomicComponent`s.
    ///
    /// Compatibility/testing view — it recreates the per-token allocation
    /// cost that freezing removed, so hot paths should prefer
    /// `enumerateSpans(_:)`. Tokens that were split at the `UInt16.max`
    /// length limit remain split here.
    @inlinable
    public var components: [AtomicComponent] {
        var result: [AtomicComponent] = []
        result.reserveCapacity(spans.count)
        enumerateSpans { spanText, type, identifier in
            result.append(AtomicComponent(string: String(spanText), type: type, identifier: identifier))
        }
        return result
    }
}

// MARK: - Hashable Conformance

extension FrozenSemanticString: Hashable {
    /// Compares rendered content, not storage layout.
    ///
    /// The synthesized conformance would compare `identifierTable` verbatim,
    /// so two values carrying the same identifiers in a differently shaped
    /// table — a decoded payload keeps duplicate and unreferenced entries as
    /// they arrived — would compare unequal despite being indistinguishable
    /// to every reader. Resolving each span's identifier removes the table
    /// from the comparison.
    ///
    /// Type codes are resolved the same way, and for the same reason: an
    /// unknown code (decoded from a future encoder) renders as `.other` in
    /// every reader — `enumerateSpans`, `components`, styling — so a snapshot
    /// carrying it must compare equal to one carrying `.other`'s own code.
    /// Comparing the raw byte instead would deny that pair while every reader
    /// reports them identical.
    ///
    /// Note that this remains a comparison of *frozen* values: two different
    /// `SemanticString`s can freeze to equal snapshots, because a token over
    /// `UInt16.max` bytes and the same text split across adjacent same-type
    /// tokens produce identical spans. Use the source strings when token
    /// identity matters.
    public static func == (lhs: FrozenSemanticString, rhs: FrozenSemanticString) -> Bool {
        guard lhs.text == rhs.text, lhs.spans.count == rhs.spans.count else {
            return false
        }
        // Identical tables with identical spans over *byte-identical* text
        // are certainly equal: every per-span slice below would be
        // byte-identical too. All three conditions are required. Identical
        // tables alone are only sufficient, not necessary — a table can carry
        // duplicate entries (decoding preserves them), so two values over the
        // *same* table may reference the same identifier through different
        // indices; returning `lhs.spans == rhs.spans` as the final answer
        // would deny that pair while the resolving loop below grants it
        // against a third value, breaking transitivity. And the byte check on
        // the text is what keeps this shortcut sound: `lhs.text == rhs.text`
        // above is canonical, so canonically-equal texts with *reordered
        // combining marks* can carry identical span vectors while their
        // per-span slices differ — the resolving loop denies those, and the
        // shortcut must not overrule it.
        if lhs.identifierTable == rhs.identifierTable, lhs.spans == rhs.spans,
           lhs.text.utf8.elementsEqual(rhs.text.utf8) {
            return true
        }
        // Compare each span's *text*, not its byte length. The `text`
        // comparison above is canonical (`String ==` treats NFC and NFD as
        // equal), so a byte-length comparison here would deny NFC/NFD pairs
        // that every reader — `text`, `string`, `components`, rendering —
        // reports as identical, and `frozen()` would turn equal
        // `SemanticString`s into unequal snapshots. `Substring ==` applies
        // the same canonical standard per span, which keeps this relation
        // transitive.
        //
        // The boundary walk enforces the unchecked initializer's invariants
        // exactly as `enumerateSpans(_:)` does: a value whose spans overrun
        // the text or split a scalar traps here with a diagnostic naming
        // this type, rather than dying in bare index arithmetic or silently
        // comparing mis-sliced text.
        var leftLowerBound = lhs.text.startIndex
        var rightLowerBound = rhs.text.startIndex
        for (leftSpan, rightSpan) in zip(lhs.spans, rhs.spans) {
            let leftUpperBound = lhs.spanUpperBound(after: leftLowerBound, spanLength: leftSpan.length)
            let rightUpperBound = rhs.spanUpperBound(after: rightLowerBound, spanLength: rightSpan.length)
            // Compare the *resolved* type, not the raw code: an unknown code
            // resolves to `.other`, so two spans that every reader renders as
            // `.other` must compare equal here too.
            guard lhs.text[leftLowerBound ..< leftUpperBound] == rhs.text[rightLowerBound ..< rightUpperBound],
                  (SemanticType(frozenTypeCode: leftSpan.typeCode) ?? .other) == (SemanticType(frozenTypeCode: rightSpan.typeCode) ?? .other),
                  lhs.identifier(at: leftSpan.identifierIndex) == rhs.identifier(at: rightSpan.identifierIndex)
            else {
                return false
            }
            leftLowerBound = leftUpperBound
            rightLowerBound = rightUpperBound
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        // Everything `==` requires of equal values is covered without
        // touching span boundaries: the full text (String hashing is
        // canonical, so NFC/NFD values that compare equal hash equal), the
        // span count, and each span's *resolved* type and identifier — an
        // unknown code resolves to `.other` and an out-of-range index to
        // `nil`, exactly as `==` resolves them. Span byte lengths are
        // deliberately not hashed: equal values may split canonically-equal
        // text at different byte offsets.
        //
        // Not walking the text also means hashing never traps, even on a
        // value that violates the unchecked initializer's invariants — such
        // a value hashes quietly and then traps, with a diagnostic naming
        // this type, in whatever read walks it (`enumerateSpans`,
        // `components`, `==`'s resolving path). Hashing every span's slice,
        // as this used to, cost a second full pass over the text and died in
        // bare standard-library index arithmetic on malformed values.
        hasher.combine(text)
        hasher.combine(spans.count)
        for span in spans {
            hasher.combine(SemanticType(frozenTypeCode: span.typeCode) ?? .other)
            hasher.combine(identifier(at: span.identifierIndex))
        }
    }
}
