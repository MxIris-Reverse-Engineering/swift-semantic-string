// MARK: - Freezing

extension SemanticString {
    /// Returns the immutable, memory-compact snapshot of this string.
    /// See `FrozenSemanticString`.
    ///
    /// Never inflates the value it is called on. Reading `components` and
    /// `string` would publish the flattened array and the full text into
    /// storage this value may be *sharing*, so a call whose entire purpose is
    /// to reduce footprint would first raise it — permanently, for every value
    /// holding the same storage. Both are read cache-if-present and otherwise
    /// computed locally.
    @inlinable
    public func frozen() -> FrozenSemanticString {
        let atomicComponents = componentsWithoutPublishing()

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
            // Zero-length components carry no text and no renderable run;
            // tree flattening already filters them, this covers flat-built
            // strings holding manually constructed empty atomics.
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

    /// Emits one span for the common case, or several scalar-aligned spans
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

        // Split at Unicode scalar boundaries so every span slices cleanly.
        var currentSpanByteCount = 0
        for unicodeScalar in tokenString.unicodeScalars {
            let scalarByteCount = UTF8.width(unicodeScalar)
            if currentSpanByteCount + scalarByteCount > Int(UInt16.max) {
                spans.append(.init(length: UInt16(currentSpanByteCount), typeCode: typeCode, identifierIndex: identifierIndex))
                currentSpanByteCount = 0
            }
            currentSpanByteCount += scalarByteCount
        }
        if currentSpanByteCount > 0 {
            spans.append(.init(length: UInt16(currentSpanByteCount), typeCode: typeCode, identifierIndex: identifierIndex))
        }
    }
}
