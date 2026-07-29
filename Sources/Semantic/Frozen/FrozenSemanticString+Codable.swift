// MARK: - Codable

extension FrozenSemanticString: Codable {
    /// Columnar encoding: one string plus four homogeneous arrays. Compared
    /// to `SemanticString`'s array-of-keyed-objects encoding this is an
    /// order of magnitude smaller on the wire, which matters for interfaces
    /// shipped over XPC/TCP to remote inspectors.
    private enum CodingKeys: String, CodingKey {
        case text
        case spanLengths
        case spanTypeCodes
        case spanIdentifierIndices
        case identifierTable
    }

    /// The validated construction path. Everything a reader of this type could
    /// otherwise *trap* on is checked here, because this is where untrusted
    /// bytes enter: column counts agree, span lengths partition the text
    /// exactly, no span is zero-length, and every boundary falls on a Unicode
    /// scalar. Two fields are deliberately *not* rejected — an unknown
    /// `typeCode` and an out-of-range `identifierIndex` — because every reader
    /// resolves them to a graceful default (`.other`, `nil`) rather than
    /// trapping, and rejecting them would refuse both forward-compatible
    /// payloads and this type's own encoder output. Both are kept verbatim,
    /// exactly as the unchecked initializer keeps them.
    ///
    /// Decode order is validation order. A hostile payload can declare
    /// millions of spans in a few megabytes of input, so nothing beyond the
    /// lengths column is materialized until that column has been proven
    /// consistent with the text: the span count is bounded by the text's byte
    /// count first (every span covers at least one byte), which caps what the
    /// remaining columns are allowed to cost before they are decoded.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)
        let spanLengths = try container.decode([UInt16].self, forKey: .spanLengths)

        let textUTF8ByteCount = text.utf8.count
        guard spanLengths.count <= textUTF8ByteCount else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Payload declares \(spanLengths.count) spans for a text of \(textUTF8ByteCount) bytes; every span must cover at least one byte"
            ))
        }

        // A zero-length span is not producible by `frozen()` and breaks the
        // library-wide invariant that no component is empty: the value would
        // report `count > 0` and `isEmpty == false` while rendering nothing,
        // and converting it to a `SemanticString` would drop the span, so the
        // round trip would not be idempotent.
        //
        // The accumulator is 64-bit on purpose: on 32-bit targets (watchOS
        // devices) ~33k full-length spans would overflow an `Int` and trap
        // before this validator gets a chance to throw — and a validator for
        // untrusted bytes must never take the process down.
        var coveredUTF8ByteCount: UInt64 = 0
        for (spanIndex, length) in spanLengths.enumerated() {
            guard length > 0 else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Span \(spanIndex) has zero length; spans must cover at least one byte"
                ))
            }
            coveredUTF8ByteCount += UInt64(length)
        }
        guard coveredUTF8ByteCount == UInt64(textUTF8ByteCount) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Span lengths cover \(coveredUTF8ByteCount) bytes but text has \(textUTF8ByteCount)"
            ))
        }

        // Covering the right number of bytes is not enough: a boundary in the
        // middle of a multi-byte scalar passes the coverage check and then
        // makes `enumerateSpans` hand out slices that do not correspond to the
        // spans. Walk the boundaries once and reject them here, where the
        // payload is still identifiable as corrupt. Safe to walk now: the
        // coverage check above proved the offsets stay in bounds.
        let utf8View = text.utf8
        var spanBoundary = utf8View.startIndex
        for length in spanLengths {
            spanBoundary = utf8View.index(spanBoundary, offsetBy: Int(length))
            guard spanBoundary.samePosition(in: text.unicodeScalars) != nil else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Span boundary at UTF-8 offset \(utf8View.distance(from: utf8View.startIndex, to: spanBoundary)) splits a Unicode scalar"
                ))
            }
        }

        // The lengths column is fully validated; the remaining columns can
        // now cost at most one entry per proven span (plus the identifier
        // table, whose size the payload pays for in its own bytes).
        let spanTypeCodes = try container.decode([UInt8].self, forKey: .spanTypeCodes)
        let spanIdentifierIndices = try container.decode([UInt32].self, forKey: .spanIdentifierIndices)
        let identifierTable = try container.decode([String].self, forKey: .identifierTable)

        guard spanLengths.count == spanTypeCodes.count, spanLengths.count == spanIdentifierIndices.count else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Span column counts differ: \(spanLengths.count) lengths, \(spanTypeCodes.count) type codes, \(spanIdentifierIndices.count) identifier indices"
            ))
        }

        // Identifier indices are kept verbatim, out-of-range values included.
        // An out-of-range index is the exact analog of an unknown `typeCode`:
        // a reader resolves both to a graceful default — `identifier(at:)`
        // maps it to `nil` (safely, via its own `Int(exactly:)`) just as an
        // unknown code renders as `.other` — so neither can trap. Rejecting it
        // here would break round-trip idempotence: the unchecked initializer
        // accepts such a value and the encoder emits it, so the decoder would
        // refuse this type's own output. The structural invariants that *would*
        // trap a reader (coverage, alignment, column counts) are enforced above.

        var spans: [Span] = []
        spans.reserveCapacity(spanLengths.count)
        for spanIndex in spanLengths.indices {
            spans.append(.init(
                length: spanLengths[spanIndex],
                typeCode: spanTypeCodes[spanIndex],
                identifierIndex: spanIdentifierIndices[spanIndex]
            ))
        }
        self.init(text: text, spans: spans, identifierTable: identifierTable)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(spans.map(\.length), forKey: .spanLengths)
        try container.encode(spans.map(\.typeCode), forKey: .spanTypeCodes)
        try container.encode(spans.map(\.identifierIndex), forKey: .spanIdentifierIndices)
        try container.encode(identifierTable, forKey: .identifierTable)
    }
}
