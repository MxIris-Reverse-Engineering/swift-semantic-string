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

    /// The validated construction path. Everything a reader of this type is
    /// allowed to assume is checked here, because this is where untrusted
    /// bytes enter: column counts agree, span lengths partition the text
    /// exactly, no span is zero-length, every boundary falls on a Unicode
    /// scalar, and every identifier index is in range.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)
        let spanLengths = try container.decode([UInt16].self, forKey: .spanLengths)
        let spanTypeCodes = try container.decode([UInt8].self, forKey: .spanTypeCodes)
        let spanIdentifierIndices = try container.decode([UInt32].self, forKey: .spanIdentifierIndices)
        let identifierTable = try container.decode([String].self, forKey: .identifierTable)

        guard spanLengths.count == spanTypeCodes.count, spanLengths.count == spanIdentifierIndices.count else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Span column counts differ: \(spanLengths.count) lengths, \(spanTypeCodes.count) type codes, \(spanIdentifierIndices.count) identifier indices"
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
        guard coveredUTF8ByteCount == UInt64(text.utf8.count) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Span lengths cover \(coveredUTF8ByteCount) bytes but text has \(text.utf8.count)"
            ))
        }

        // `Int(exactly:)` instead of `Int(_:)`: on 32-bit targets the plain
        // conversion traps for indices above `Int32.max`, turning a malformed
        // payload into a crash instead of a `DecodingError`.
        for identifierIndex in spanIdentifierIndices where identifierIndex != 0 {
            guard let tableIndex = Int(exactly: identifierIndex), tableIndex <= identifierTable.count else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Identifier index \(identifierIndex) exceeds table of \(identifierTable.count)"
                ))
            }
        }

        // Covering the right number of bytes is not enough: a boundary in the
        // middle of a multi-byte scalar passes the coverage check and then
        // makes `enumerateSpans` hand out slices that do not correspond to the
        // spans — silently, because String index rounding absorbs the
        // misalignment. Walk the boundaries once and reject them here, where
        // the payload is still identifiable as corrupt. Safe to walk now: the
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
