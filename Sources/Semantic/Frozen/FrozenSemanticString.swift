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
        /// UTF-8 byte length of the run. Tokens longer than `UInt16.max`
        /// bytes are split into consecutive spans with identical `typeCode`
        /// and `identifierIndex` at Unicode scalar boundaries; consumers that
        /// only concatenate or attribute runs see no difference.
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
    /// Violating *those* invariants traps in `enumerateSpans(_:)` — a
    /// deliberate loud failure, because silently truncating a mis-sliced
    /// value would be far harder to debug.
    ///
    /// Two fields degrade instead of trapping, on every construction path:
    /// an out-of-range `identifierIndex` resolves to `nil`, and an unknown
    /// `typeCode` resolves to `.other`. The latter is deliberate forward
    /// compatibility — a payload from a *newer* encoder must stay readable —
    /// so `Codable` decoding validates the length/coverage/alignment/index
    /// invariants but does **not** reject unknown type codes.
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
    @inlinable
    public func enumerateSpans(_ body: (_ spanText: Substring, _ type: SemanticType, _ identifier: String?) -> Void) {
        var lowerBound = text.startIndex
        let utf8View = text.utf8
        for span in spans {
            let upperBound = utf8View.index(lowerBound, offsetBy: Int(span.length))
            let spanText = text[lowerBound ..< upperBound]
            let type = SemanticType(frozenTypeCode: span.typeCode) ?? .other
            body(spanText, type, identifier(at: span.identifierIndex))
            lowerBound = upperBound
        }
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
    /// Note that this remains a comparison of *frozen* values: two different
    /// `SemanticString`s can freeze to equal snapshots, because a token over
    /// `UInt16.max` bytes and the same text split across adjacent same-type
    /// tokens produce identical spans. Use the source strings when token
    /// identity matters.
    public static func == (lhs: FrozenSemanticString, rhs: FrozenSemanticString) -> Bool {
        guard lhs.text == rhs.text, lhs.spans.count == rhs.spans.count else {
            return false
        }
        // Identical tables with identical spans are certainly equal. This is
        // a sufficient condition only: a table can carry duplicate entries
        // (decoding preserves them), so two values over the *same* table may
        // reference the same identifier through different indices. Returning
        // `lhs.spans == rhs.spans` as the final answer here would deny that
        // pair while the resolving loop below grants it against a third
        // value — breaking transitivity. Fall through instead.
        if lhs.identifierTable == rhs.identifierTable, lhs.spans == rhs.spans {
            return true
        }
        for (leftSpan, rightSpan) in zip(lhs.spans, rhs.spans) {
            guard leftSpan.length == rightSpan.length,
                  leftSpan.typeCode == rightSpan.typeCode,
                  lhs.identifier(at: leftSpan.identifierIndex) == rhs.identifier(at: rightSpan.identifierIndex)
            else {
                return false
            }
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(spans.count)
        for span in spans {
            hasher.combine(span.length)
            hasher.combine(span.typeCode)
            hasher.combine(identifier(at: span.identifierIndex))
        }
    }
}
