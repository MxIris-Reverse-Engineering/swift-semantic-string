// MARK: - Definition Region Table

/// Where the definitions of a string printed with `DefinitionRegion`s lie in
/// its text.
///
/// Produced by `FrozenSemanticString.separatingDefinitionRegions()`, which
/// also returns the text it describes. The offsets count UTF-8 bytes, and
/// they hold in the string printed with regions and in every separation of
/// it alike, since no separation changes a byte of text — so
/// `content(ofDefinitionRegion:)` takes a region out of the string printed
/// with regions using offsets read from this table.
public struct DefinitionRegionTable: Hashable, Sendable {
    /// One definition's run of text.
    public struct Region: Hashable, Sendable {
        /// The identity the region was printed with.
        public let identity: String

        public let utf8Offset: UInt32

        public let utf8Length: UInt32

        /// How many regions enclose this one: `0` for a region directly in
        /// the text.
        public let depth: Int

        /// The index in `DefinitionRegionTable.regions` of the region
        /// directly enclosing this one; `nil` at depth `0`.
        public let enclosingRegionIndex: Int?

        @inlinable
        public init(identity: String, utf8Offset: UInt32, utf8Length: UInt32, depth: Int, enclosingRegionIndex: Int?) {
            self.identity = identity
            self.utf8Offset = utf8Offset
            self.utf8Length = utf8Length
            self.depth = depth
            self.enclosingRegionIndex = enclosingRegionIndex
        }
    }

    /// The regions in text order, each after the region enclosing it.
    public let regions: [Region]

    @inlinable
    public init(regions: [Region]) {
        self.regions = regions
    }

    /// No regions.
    public static let empty = DefinitionRegionTable(regions: [])

    @inlinable
    public var isEmpty: Bool { regions.isEmpty }

    /// The regions printed with `identity`, in text order.
    @inlinable
    public func regions(withIdentity identity: String) -> [Region] {
        regions.filter { $0.identity == identity }
    }
}

// MARK: - Separating

extension FrozenSemanticString {
    /// Splits a string printed with `DefinitionRegion`s into the text it
    /// would have been printed as without them — every atom's own
    /// identifier restored, a visibility tag on it included — and the table
    /// of its regions.
    ///
    /// A string with no regions comes back unchanged, with an empty table.
    /// The text is shared, not copied: only the span identifiers change.
    /// Running it before or after `separatingVisibilityRegions()` gives the
    /// same text and the same tables.
    @inlinable
    public func separatingDefinitionRegions() -> (text: FrozenSemanticString, definitions: DefinitionRegionTable) {
        guard identifierTable.contains(where: DefinitionTag.carriesIdentities) else {
            return (self, .empty)
        }
        // Compared as `UInt64`: `Int(UInt32.max)` does not fit a 32-bit `Int`.
        precondition(UInt64(text.utf8.count) <= UInt64(UInt32.max), "a text over 4 GiB cannot carry definition regions")

        var separatedIdentifierTable: [String] = []
        var separatedIdentifierIndexByValue: [String: UInt32] = [:]

        // Per original table index (1-based; slot 0 is "no identifier"): the
        // identifier index in the separated table, and the identities.
        var separatedIdentifierIndexByOriginalIndex = [UInt32](repeating: 0, count: identifierTable.count + 1)
        var identitiesByOriginalIndex = [[String]](repeating: [], count: identifierTable.count + 1)
        for (tableOffset, identifier) in identifierTable.enumerated() {
            let originalIndex = tableOffset + 1
            let decomposition = DefinitionTag.decompose(identifier)
            identitiesByOriginalIndex[originalIndex] = decomposition.identities.map(String.init)
            guard let separatedIdentifier = decomposition.identifier(keepingIdentitiesFrom: decomposition.identities.count) else {
                continue
            }
            if let existingIndex = separatedIdentifierIndexByValue[separatedIdentifier] {
                separatedIdentifierIndexByOriginalIndex[originalIndex] = existingIndex
            } else {
                separatedIdentifierTable.append(separatedIdentifier)
                let index = UInt32(separatedIdentifierTable.count)
                separatedIdentifierIndexByValue[separatedIdentifier] = index
                separatedIdentifierIndexByOriginalIndex[originalIndex] = index
            }
        }

        var separatedSpans: [Span] = []
        separatedSpans.reserveCapacity(spans.count)
        var pendingRegions: [(identity: String, utf8Offset: UInt32, utf8End: UInt32, depth: Int, enclosingRegionIndex: Int?)] = []
        // The regions the previous span sits in, outermost first, as indices
        // into `pendingRegions`.
        var openRegionIndices: [Int] = []
        var utf8Offset: UInt32 = 0
        for span in spans {
            // An index past the table reads as no identifier, and must keep
            // doing so against the separated table, which is a different size.
            // `Int(exactly:)` because a 32-bit `Int` cannot hold every `UInt32`,
            // and a decoded payload keeps an out-of-range index verbatim.
            let originalIndex = Int(exactly: span.identifierIndex).flatMap { $0 < separatedIdentifierIndexByOriginalIndex.count ? $0 : nil } ?? 0
            separatedSpans.append(Span(
                length: span.length,
                typeCode: span.typeCode,
                identifierIndex: separatedIdentifierIndexByOriginalIndex[originalIndex]
            ))

            let identities = identitiesByOriginalIndex[originalIndex]
            var sharedDepth = 0
            while sharedDepth < openRegionIndices.count, sharedDepth < identities.count,
                  pendingRegions[openRegionIndices[sharedDepth]].identity == identities[sharedDepth] {
                sharedDepth += 1
            }
            while openRegionIndices.count > sharedDepth {
                pendingRegions[openRegionIndices.removeLast()].utf8End = utf8Offset
            }
            for depth in sharedDepth ..< identities.count {
                pendingRegions.append((
                    identity: identities[depth],
                    utf8Offset: utf8Offset,
                    utf8End: utf8Offset,
                    depth: depth,
                    enclosingRegionIndex: depth == 0 ? nil : openRegionIndices[depth - 1]
                ))
                openRegionIndices.append(pendingRegions.count - 1)
            }
            utf8Offset += UInt32(span.length)
        }
        for openRegionIndex in openRegionIndices {
            pendingRegions[openRegionIndex].utf8End = utf8Offset
        }

        let regions = pendingRegions.map { pendingRegion in
            DefinitionRegionTable.Region(
                identity: pendingRegion.identity,
                utf8Offset: pendingRegion.utf8Offset,
                utf8Length: pendingRegion.utf8End - pendingRegion.utf8Offset,
                depth: pendingRegion.depth,
                enclosingRegionIndex: pendingRegion.enclosingRegionIndex
            )
        }
        return (
            FrozenSemanticString(text: text, spans: separatedSpans, identifierTable: separatedIdentifierTable),
            DefinitionRegionTable(regions: regions)
        )
    }
}

// MARK: - Taking a Region Out

extension FrozenSemanticString {
    /// One definition region of a string printed with regions, as the
    /// definition prints on its own — apart from indentation, which
    /// `removingIndentation(levels:)` removes.
    ///
    /// The text and spans are the region's. On each atom, the identities of
    /// the region and of the regions enclosing it are removed, those of the
    /// regions nested in it are kept, and a visibility tag is left as it is;
    /// the identifier table is rebuilt in the order `frozen()` builds one,
    /// so separating the result's regions gives the same tables as
    /// separating the definition's own print.
    ///
    /// Call it on the string printed with regions, or on that string after
    /// `separatingVisibilityRegions()` — not on the text
    /// `separatingDefinitionRegions()` returns, whose atoms no longer carry
    /// the identities. Traps when `region` does not start and end on span
    /// boundaries of this string, or when its atoms do not carry its
    /// identity at its depth: either means the region was read from another
    /// string.
    @inlinable
    public func content(ofDefinitionRegion region: DefinitionRegionTable.Region) -> FrozenSemanticString {
        let regionStart = Int(region.utf8Offset)
        let regionEnd = regionStart + Int(region.utf8Length)
        let utf8View = text.utf8
        precondition(regionEnd <= utf8View.count, "the definition region lies outside the text")

        var interner = IdentifierInterner()
        var rebuiltIdentifierIndexByOriginalIndex: [UInt32: UInt32] = [:]
        let firstKeptIdentityIndex = region.depth + 1
        var regionSpans: [Span] = []
        var spanStart = 0
        for span in spans {
            let spanEnd = spanStart + Int(span.length)
            if spanStart >= regionEnd {
                break
            }
            if spanEnd > regionStart {
                precondition(
                    spanStart >= regionStart && spanEnd <= regionEnd,
                    "a definition region must start and end on span boundaries"
                )
                let rebuiltIdentifierIndex: UInt32
                if let cachedIndex = rebuiltIdentifierIndexByOriginalIndex[span.identifierIndex] {
                    rebuiltIdentifierIndex = cachedIndex
                } else {
                    let decomposition = DefinitionTag.decompose(identifier(at: span.identifierIndex) ?? "")
                    precondition(
                        decomposition.identities.count >= firstKeptIdentityIndex
                            && decomposition.identities[region.depth] == region.identity,
                        "the atoms of the definition region do not carry its identity at its depth"
                    )
                    rebuiltIdentifierIndex = interner.index(of: decomposition.identifier(keepingIdentitiesFrom: firstKeptIdentityIndex))
                    rebuiltIdentifierIndexByOriginalIndex[span.identifierIndex] = rebuiltIdentifierIndex
                }
                regionSpans.append(Span(length: span.length, typeCode: span.typeCode, identifierIndex: rebuiltIdentifierIndex))
            }
            spanStart = spanEnd
        }

        let textStart = utf8View.index(utf8View.startIndex, offsetBy: regionStart)
        let textEnd = utf8View.index(textStart, offsetBy: Int(region.utf8Length))
        return FrozenSemanticString(
            text: String(Substring(utf8View[textStart ..< textEnd])),
            spans: regionSpans,
            identifierTable: interner.identifierTable
        )
    }
}
