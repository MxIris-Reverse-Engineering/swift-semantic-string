// MARK: - Removing Indentation

extension FrozenSemanticString {
    /// The string with `levels` levels of indentation — four spaces each,
    /// the width of `Indent` and of the block components — removed from the
    /// start of every line. A line with nothing on it but its line break
    /// (`\n` or `\r\n`) is left as it is, and so is an empty last line.
    ///
    /// This is what turns a definition printed nested, every line indented
    /// by its nesting depth, into the definition as it prints on its own
    /// (see `content(ofDefinitionRegion:)`). The removal reaches inside
    /// atoms: a multi-line comment that indents each of its lines loses the
    /// indentation of each. A span shrinks by the spaces removed from it,
    /// and a span left with nothing is dropped; the identifier table is
    /// rebuilt in the order `frozen()` builds one, without identifiers only
    /// dropped spans used, so separating visibility regions afterwards
    /// numbers their conditions as the same text frozen directly would.
    ///
    /// `nil` when some other line does not start with that much
    /// indentation. `levels` must not be negative; `0` returns the string
    /// unchanged.
    ///
    /// A token over `UInt16.max` UTF-8 bytes keeps the span boundaries it
    /// was frozen with, each moved by what was removed before it, so the
    /// result can split such a token at other offsets than freezing the same
    /// text directly would. Text, types and identifiers agree regardless.
    @inlinable
    public func removingIndentation(levels: Int) -> FrozenSemanticString? {
        precondition(levels >= 0, "cannot remove a negative number of indentation levels")
        guard levels > 0, !spans.isEmpty else {
            return self
        }
        let indentationWidth = levels * 4
        let lineFeed = UInt8(ascii: "\n")
        let carriageReturn = UInt8(ascii: "\r")
        let space = UInt8(ascii: " ")
        let originalBytes = Array(text.utf8)
        let byteCount = originalBytes.count

        // The indentation of each line, in text order.
        var removedRanges: [Range<Int>] = []
        var lineStart = 0
        while lineStart < byteCount {
            let firstByte = originalBytes[lineStart]
            let isBlankLine = firstByte == lineFeed
                || (firstByte == carriageReturn && lineStart + 1 < byteCount && originalBytes[lineStart + 1] == lineFeed)
            if !isBlankLine {
                let indentationEnd = lineStart + indentationWidth
                guard indentationEnd <= byteCount else {
                    return nil
                }
                for byteOffset in lineStart ..< indentationEnd where originalBytes[byteOffset] != space {
                    return nil
                }
                removedRanges.append(lineStart ..< indentationEnd)
            }
            guard let lineFeedOffset = originalBytes[lineStart...].firstIndex(of: lineFeed) else {
                break
            }
            lineStart = lineFeedOffset + 1
        }

        var interner = IdentifierInterner()
        var rebuiltIdentifierIndexByOriginalIndex: [UInt32: UInt32] = [:]
        var rebuiltSpans: [Span] = []
        rebuiltSpans.reserveCapacity(spans.count)
        var spanStart = 0
        var nextRemovedRangeIndex = 0
        for span in spans {
            precondition(span.length > 0, "FrozenSemanticString has a zero-length span; the unchecked init's invariants were violated")
            let spanEnd = spanStart + Int(span.length)
            precondition(spanEnd <= byteCount, "FrozenSemanticString spans overrun the text; the unchecked init's invariants were violated")
            var removedByteCount = 0
            while nextRemovedRangeIndex < removedRanges.count, removedRanges[nextRemovedRangeIndex].lowerBound < spanEnd {
                let removedRange = removedRanges[nextRemovedRangeIndex]
                removedByteCount += min(removedRange.upperBound, spanEnd) - max(removedRange.lowerBound, spanStart)
                // A range reaching past this span continues into the next.
                guard removedRange.upperBound <= spanEnd else { break }
                nextRemovedRangeIndex += 1
            }
            let keptByteCount = Int(span.length) - removedByteCount
            if keptByteCount > 0 {
                let rebuiltIdentifierIndex: UInt32
                if let cachedIndex = rebuiltIdentifierIndexByOriginalIndex[span.identifierIndex] {
                    rebuiltIdentifierIndex = cachedIndex
                } else {
                    rebuiltIdentifierIndex = interner.index(of: identifier(at: span.identifierIndex))
                    rebuiltIdentifierIndexByOriginalIndex[span.identifierIndex] = rebuiltIdentifierIndex
                }
                rebuiltSpans.append(Span(length: UInt16(keptByteCount), typeCode: span.typeCode, identifierIndex: rebuiltIdentifierIndex))
            }
            spanStart = spanEnd
        }
        precondition(spanStart == byteCount, "FrozenSemanticString spans undercover the text; the unchecked init's invariants were violated")

        var keptBytes: [UInt8] = []
        keptBytes.reserveCapacity(byteCount - removedRanges.count * indentationWidth)
        var keptRunStart = 0
        for removedRange in removedRanges {
            keptBytes.append(contentsOf: originalBytes[keptRunStart ..< removedRange.lowerBound])
            keptRunStart = removedRange.upperBound
        }
        keptBytes.append(contentsOf: originalBytes[keptRunStart...])

        // Only ASCII spaces that follow a line feed or open the text were
        // removed, so the bytes are still valid UTF-8 and every span boundary
        // still falls on a Unicode scalar.
        return FrozenSemanticString(
            text: String(decoding: keptBytes, as: UTF8.self),
            spans: rebuiltSpans,
            identifierTable: interner.identifierTable
        )
    }
}

// MARK: - Identifier Interning

extension FrozenSemanticString {
    /// Builds an identifier table the way `frozen()` does: each identifier
    /// once, in the order spans first use it. The operations that rebuild a
    /// frozen string from part of another use it, so their results number
    /// identifiers — and, through them, visibility conditions — exactly as
    /// freezing the same atoms directly would.
    @usableFromInline
    struct IdentifierInterner {
        @usableFromInline
        var identifierTable: [String] = []

        @usableFromInline
        var indexByIdentifier: [String: UInt32] = [:]

        @inlinable
        init() {}

        /// The 1-based table index of `identifier`; `0` for `nil`.
        @inlinable
        mutating func index(of identifier: String?) -> UInt32 {
            guard let identifier else {
                return 0
            }
            if let existingIndex = indexByIdentifier[identifier] {
                return existingIndex
            }
            identifierTable.append(identifier)
            let index = UInt32(identifierTable.count)
            indexByIdentifier[identifier] = index
            return index
        }
    }
}
