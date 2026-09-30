// MARK: - Visibility Region Table

/// Where the regions of a string printed with `VisibilityRegion` lie in its
/// text, and when each is visible.
///
/// Produced by `FrozenSemanticString.separatingVisibilityRegions()`, which
/// also returns the text it describes; `projection(of:where:)` then gives
/// that text as it reads under any option values.
public struct VisibilityRegionTable: Hashable, Sendable {
    /// One run of text under one condition.
    public struct Region: Hashable, Sendable {
        public let utf8Offset: UInt32

        public let utf8Length: UInt32

        /// Index into `VisibilityRegionTable.conditions`.
        public let conditionIndex: UInt32

        @inlinable
        public init(utf8Offset: UInt32, utf8Length: UInt32, conditionIndex: UInt32) {
            self.utf8Offset = utf8Offset
            self.utf8Length = utf8Length
            self.conditionIndex = conditionIndex
        }
    }

    /// The runs in text order. They do not overlap, and two runs that touch
    /// have different conditions.
    public let regions: [Region]

    /// The distinct conditions. A run inside several regions is under the
    /// conjunction of theirs, normalized, so equivalent nestings share one
    /// entry.
    public let conditions: [VisibilityCondition]

    @inlinable
    public init(regions: [Region], conditions: [VisibilityCondition]) {
        self.regions = regions
        self.conditions = conditions
    }

    /// No regions: the text reads the same under every option value.
    public static let empty = VisibilityRegionTable(regions: [], conditions: [])

    @inlinable
    public var isEmpty: Bool { regions.isEmpty }
}

// MARK: - Separating

extension FrozenSemanticString {
    /// Splits a string printed with `VisibilityRegion`s into the text it
    /// would have been printed as without them — every atom's own identifier
    /// restored — and the table of its regions.
    ///
    /// A string with no regions comes back unchanged, with an empty table.
    /// The text is shared, not copied: only the span identifiers change.
    @inlinable
    public func separatingVisibilityRegions() -> (text: FrozenSemanticString, regions: VisibilityRegionTable) {
        guard identifierTable.contains(where: VisibilityTag.isTag) else {
            return (self, .empty)
        }
        precondition(text.utf8.count <= Int(UInt32.max), "a text over 4 GiB cannot carry visibility regions")

        var separatedIdentifierTable: [String] = []
        var separatedIdentifierIndexByValue: [String: UInt32] = [:]
        func separatedIdentifierIndex(of identifier: String) -> UInt32 {
            if let existingIndex = separatedIdentifierIndexByValue[identifier] {
                return existingIndex
            }
            separatedIdentifierTable.append(identifier)
            let index = UInt32(separatedIdentifierTable.count)
            separatedIdentifierIndexByValue[identifier] = index
            return index
        }

        var conditions: [VisibilityCondition] = []
        var conditionIndexByCondition: [VisibilityCondition: UInt32] = [:]

        // Per original table index (1-based; slot 0 is "no identifier"): the
        // identifier index in the separated table, and the condition list
        // when the entry was a tag.
        var separatedIdentifierIndexByOriginalIndex = [UInt32](repeating: 0, count: identifierTable.count + 1)
        var conditionIndexByOriginalIndex = [UInt32?](repeating: nil, count: identifierTable.count + 1)
        for (tableOffset, identifier) in identifierTable.enumerated() {
            let originalIndex = tableOffset + 1
            guard let decoded = VisibilityTag.decode(identifier) else {
                separatedIdentifierIndexByOriginalIndex[originalIndex] = separatedIdentifierIndex(of: identifier)
                continue
            }
            if let originalIdentifier = decoded.originalIdentifier {
                separatedIdentifierIndexByOriginalIndex[originalIndex] = separatedIdentifierIndex(of: originalIdentifier)
            }
            let condition = VisibilityCondition.all(decoded.conditions)
            if let existingConditionIndex = conditionIndexByCondition[condition] {
                conditionIndexByOriginalIndex[originalIndex] = existingConditionIndex
            } else {
                conditions.append(condition)
                let conditionIndex = UInt32(conditions.count - 1)
                conditionIndexByCondition[condition] = conditionIndex
                conditionIndexByOriginalIndex[originalIndex] = conditionIndex
            }
        }

        var separatedSpans: [Span] = []
        separatedSpans.reserveCapacity(spans.count)
        var regions: [VisibilityRegionTable.Region] = []
        var utf8Offset: UInt32 = 0
        for span in spans {
            // An index past the table reads as no identifier, and must keep
            // doing so against the separated table, which is a different size.
            let originalIndex = Int(span.identifierIndex) < separatedIdentifierIndexByOriginalIndex.count ? Int(span.identifierIndex) : 0
            separatedSpans.append(Span(
                length: span.length,
                typeCode: span.typeCode,
                identifierIndex: separatedIdentifierIndexByOriginalIndex[originalIndex]
            ))
            if let conditionIndex = conditionIndexByOriginalIndex[originalIndex] {
                if let last = regions.last, last.conditionIndex == conditionIndex, last.utf8Offset + last.utf8Length == utf8Offset {
                    regions[regions.count - 1] = VisibilityRegionTable.Region(
                        utf8Offset: last.utf8Offset,
                        utf8Length: last.utf8Length + UInt32(span.length),
                        conditionIndex: conditionIndex
                    )
                } else {
                    regions.append(VisibilityRegionTable.Region(utf8Offset: utf8Offset, utf8Length: UInt32(span.length), conditionIndex: conditionIndex))
                }
            }
            utf8Offset += UInt32(span.length)
        }

        return (
            FrozenSemanticString(text: text, spans: separatedSpans, identifierTable: separatedIdentifierTable),
            VisibilityRegionTable(regions: regions, conditions: conditions)
        )
    }
}
