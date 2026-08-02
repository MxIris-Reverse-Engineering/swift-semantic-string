// MARK: - Freezing

extension SemanticString {
    /// Returns the immutable, memory-compact snapshot of this string.
    /// See `FrozenSemanticString`.
    ///
    /// Never inflates the value it is called on, or any value sharing its
    /// storage: `components` is the storage itself (no cache to fill), and
    /// the text reuses the string cache only when a previous render already
    /// paid for it — otherwise it is computed locally and not published.
    @inlinable
    public func frozen() -> FrozenSemanticString {
        let atomicComponents = _storage.atoms

        // Zero-length components contribute no bytes, so concatenating the
        // non-empty ones is by construction exactly `string` — free when the
        // value has already been rendered, measured, or compared.
        let text = _storage.cachedStringIfPresent() ?? Self.concatenated(atomicComponents)

        var spans: [FrozenSemanticString.Span] = []
        spans.reserveCapacity(atomicComponents.count)
        var identifierTable: [String] = []
        var identifierIndexByValue: [String: UInt32] = [:]

        for component in atomicComponents {
            let componentUTF8ByteCount = component.string.utf8.count
            // Storage never holds zero-length components; this guard is a
            // defensive restatement of that invariant, because a zero-length
            // span must never reach the frozen form.
            guard componentUTF8ByteCount > 0 else { continue }

            let typeCode = component.type.frozenTypeCode
            let identifierIndex: UInt32
            if let identifier = component.identifier {
                if let existingIndex = identifierIndexByValue[identifier] {
                    identifierIndex = existingIndex
                } else {
                    identifierTable.append(identifier)
                    identifierIndex = UInt32(identifierTable.count)
                    identifierIndexByValue[identifier] = identifierIndex
                }
            } else {
                identifierIndex = 0
            }

            Self.appendSpans(
                forTokenWithUTF8ByteCount: componentUTF8ByteCount,
                tokenString: component.string,
                typeCode: typeCode,
                identifierIndex: identifierIndex,
                into: &spans
            )
        }

        return FrozenSemanticString(text: text, spans: spans, identifierTable: identifierTable)
    }

    /// Emits one span for the common case, or several grapheme-aligned spans
    /// when a single token exceeds `UInt16.max` UTF-8 bytes.
    @usableFromInline
    internal static func appendSpans(
        forTokenWithUTF8ByteCount utf8ByteCount: Int,
        tokenString: String,
        typeCode: UInt8,
        identifierIndex: UInt32,
        into spans: inout [FrozenSemanticString.Span]
    ) {
        if utf8ByteCount <= Int(UInt16.max) {
            spans.append(.init(length: UInt16(utf8ByteCount), typeCode: typeCode, identifierIndex: identifierIndex))
            return
        }

        // Split at grapheme cluster boundaries: a split inside a cluster
        // (e.g. between the scalars of a ZWJ emoji sequence) still
        // concatenates back to the same text, but every span consumer —
        // styling, selection, `components` — sees a broken half-cluster.
        // Cluster boundaries are scalar boundaries, so the decoder's
        // alignment validation accepts these spans unchanged.
        var currentSpanByteCount = 0
        for character in tokenString {
            var characterByteCount = 0
            for unicodeScalar in character.unicodeScalars {
                characterByteCount += UTF8.width(unicodeScalar)
            }

            if characterByteCount > Int(UInt16.max) {
                // A single cluster that cannot fit any span — a pathological
                // joiner chain. Flush what has accumulated, then degrade to
                // scalar-boundary splits for this cluster alone; its tail
                // keeps accumulating with the following characters.
                if currentSpanByteCount > 0 {
                    spans.append(.init(length: UInt16(currentSpanByteCount), typeCode: typeCode, identifierIndex: identifierIndex))
                    currentSpanByteCount = 0
                }
                for unicodeScalar in character.unicodeScalars {
                    let scalarByteCount = UTF8.width(unicodeScalar)
                    if currentSpanByteCount + scalarByteCount > Int(UInt16.max) {
                        spans.append(.init(length: UInt16(currentSpanByteCount), typeCode: typeCode, identifierIndex: identifierIndex))
                        currentSpanByteCount = 0
                    }
                    currentSpanByteCount += scalarByteCount
                }
                continue
            }

            if currentSpanByteCount + characterByteCount > Int(UInt16.max) {
                spans.append(.init(length: UInt16(currentSpanByteCount), typeCode: typeCode, identifierIndex: identifierIndex))
                currentSpanByteCount = 0
            }
            currentSpanByteCount += characterByteCount
        }
        if currentSpanByteCount > 0 {
            spans.append(.init(length: UInt16(currentSpanByteCount), typeCode: typeCode, identifierIndex: identifierIndex))
        }
    }
}
