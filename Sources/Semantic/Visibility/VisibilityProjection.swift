// MARK: - Visibility Projection

/// A string printed with visibility regions, as it reads under one set of
/// option values: every region whose conditions do not all hold is removed,
/// and nothing else. The line breaks, indentation and separators a container
/// printed around a hidden item go with it, because the container gave them
/// the item's condition (see `VisibilityLayout`).
public struct VisibilityProjection: Sendable {
    /// The visible text, spans and identifiers included.
    public let text: FrozenSemanticString

    /// The runs of the original text that survived, in order.
    @usableFromInline
    let keptRuns: [KeptRun]

    @usableFromInline
    struct KeptRun: Sendable {
        @usableFromInline
        let originalUTF8Offset: Int

        @usableFromInline
        let utf8Length: Int

        @usableFromInline
        let projectedUTF8Offset: Int

        @inlinable
        init(originalUTF8Offset: Int, utf8Length: Int, projectedUTF8Offset: Int) {
            self.originalUTF8Offset = originalUTF8Offset
            self.utf8Length = utf8Length
            self.projectedUTF8Offset = projectedUTF8Offset
        }
    }

    @inlinable
    init(text: FrozenSemanticString, keptRuns: [KeptRun]) {
        self.text = text
        self.keptRuns = keptRuns
    }

    /// Where the byte at `originalUTF8Offset` of the separated text is in
    /// the projected text, or `nil` when the projection removed it.
    @inlinable
    public func projectedUTF8Offset(ofOriginalUTF8Offset originalUTF8Offset: Int) -> Int? {
        var lowerBound = 0
        var upperBound = keptRuns.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            let run = keptRuns[middle]
            if originalUTF8Offset < run.originalUTF8Offset {
                upperBound = middle
            } else if originalUTF8Offset >= run.originalUTF8Offset + run.utf8Length {
                lowerBound = middle + 1
            } else {
                return run.projectedUTF8Offset + (originalUTF8Offset - run.originalUTF8Offset)
            }
        }
        return nil
    }
}

// MARK: - Projecting

extension VisibilityRegionTable {
    /// `text` — the text this table was separated from — under the option
    /// values `isOptionEnabled` reports. See `VisibilityProjection` for what
    /// is removed.
    @inlinable
    public func projection(of text: FrozenSemanticString, where isOptionEnabled: (String) -> Bool) -> VisibilityProjection {
        let conditionHolds = conditions.map { $0.isSatisfied(where: isOptionEnabled) }
        // Nothing to remove — every region visible, the common case when the
        // options show more than they hide: the text as it is, uncopied.
        guard regions.contains(where: { !conditionHolds[Int($0.conditionIndex)] }) else {
            let byteCount = text.text.utf8.count
            return VisibilityProjection(
                text: text,
                keptRuns: byteCount == 0 ? [] : [.init(originalUTF8Offset: 0, utf8Length: byteCount, projectedUTF8Offset: 0)]
            )
        }

        let originalBytes = Array(text.text.utf8)
        let byteCount = originalBytes.count
        var isKept = [Bool](repeating: true, count: byteCount)
        for region in regions where !conditionHolds[Int(region.conditionIndex)] {
            let start = Int(region.utf8Offset)
            let end = start + Int(region.utf8Length)
            for byteOffset in start ..< end {
                isKept[byteOffset] = false
            }
        }

        var projectedBytes: [UInt8] = []
        projectedBytes.reserveCapacity(byteCount)
        var keptRuns: [VisibilityProjection.KeptRun] = []
        var byteOffset = 0
        while byteOffset < byteCount {
            guard isKept[byteOffset] else {
                byteOffset += 1
                continue
            }
            let runStart = byteOffset
            while byteOffset < byteCount, isKept[byteOffset] {
                byteOffset += 1
            }
            keptRuns.append(.init(originalUTF8Offset: runStart, utf8Length: byteOffset - runStart, projectedUTF8Offset: projectedBytes.count))
            projectedBytes.append(contentsOf: originalBytes[runStart ..< byteOffset])
        }

        // Regions are runs of whole spans, so a span survives whole or not at
        // all, and the projection's spans still end on Unicode scalar
        // boundaries.
        var projectedSpans: [FrozenSemanticString.Span] = []
        projectedSpans.reserveCapacity(text.spans.count)
        var spanStart = 0
        for span in text.spans {
            let spanEnd = spanStart + Int(span.length)
            var keptByteCount = 0
            for spanByteOffset in spanStart ..< spanEnd where isKept[spanByteOffset] {
                keptByteCount += 1
            }
            if keptByteCount > 0 {
                projectedSpans.append(.init(length: UInt16(keptByteCount), typeCode: span.typeCode, identifierIndex: span.identifierIndex))
            }
            spanStart = spanEnd
        }

        return VisibilityProjection(
            text: FrozenSemanticString(
                text: String(decoding: projectedBytes, as: UTF8.self),
                spans: projectedSpans,
                identifierTable: text.identifierTable
            ),
            keptRuns: keptRuns
        )
    }
}
