// MARK: - Annotation Region Table

/// Where the annotation regions and segments of a string printed with them
/// lie in its text.
///
/// Produced by `FrozenSemanticString.separatingAnnotationRegions()`, which
/// also returns the text it describes. The offsets count UTF-8 bytes, and
/// they hold in the string printed with annotations and in every separation
/// of it alike, since no separation changes a byte of text.
public struct AnnotationRegionTable: Hashable, Sendable {
    /// One region's run of text.
    public struct Region: Hashable, Sendable {
        public let kind: AnnotationRegion.Kind

        /// Where the region's first atom starts, less leading atoms that
        /// hold only whitespace — spaces, tabs, line breaks — and lie in no
        /// segment.
        public let utf8Offset: UInt32

        /// Up to where the region's last atom ends, less trailing atoms that
        /// hold only whitespace and lie in no segment. Whatever lies in
        /// between counts, line breaks or indentation a container printed
        /// between the region's items included.
        public let utf8Length: UInt32

        /// How many regions enclose this one: `0` for a region directly in
        /// the text.
        public let depth: Int

        /// The index in `AnnotationRegionTable.regions` of the region
        /// directly enclosing this one; `nil` at depth `0`.
        public let enclosingRegionIndex: Int?

        @inlinable
        public init(kind: AnnotationRegion.Kind, utf8Offset: UInt32, utf8Length: UInt32, depth: Int, enclosingRegionIndex: Int?) {
            self.kind = kind
            self.utf8Offset = utf8Offset
            self.utf8Length = utf8Length
            self.depth = depth
            self.enclosingRegionIndex = enclosingRegionIndex
        }
    }

    /// One segment's run of text. Never trimmed.
    public struct Segment: Hashable, Sendable {
        public let role: AnnotationSegment.Role

        public let utf8Offset: UInt32

        public let utf8Length: UInt32

        /// The index in `AnnotationRegionTable.regions` of the innermost
        /// region the segment lies in; `nil` for a segment in no region.
        public let regionIndex: Int?

        @inlinable
        public init(role: AnnotationSegment.Role, utf8Offset: UInt32, utf8Length: UInt32, regionIndex: Int?) {
            self.role = role
            self.utf8Offset = utf8Offset
            self.utf8Length = utf8Length
            self.regionIndex = regionIndex
        }
    }

    /// The regions in text order, each after the region enclosing it. A
    /// region holding nothing but whitespace outside segments is not here,
    /// and neither are the regions inside it.
    public let regions: [Region]

    /// The segments in text order.
    public let segments: [Segment]

    @inlinable
    public init(regions: [Region], segments: [Segment]) {
        self.regions = regions
        self.segments = segments
    }

    /// No regions and no segments.
    public static let empty = AnnotationRegionTable(regions: [], segments: [])

    @inlinable
    public var isEmpty: Bool { regions.isEmpty && segments.isEmpty }

    /// The regions of `kind`, in text order.
    @inlinable
    public func regions(ofKind kind: AnnotationRegion.Kind) -> [Region] {
        regions.filter { $0.kind == kind }
    }

    /// The segments whose innermost region is the one at `regionIndex` in
    /// `regions` — segments of the regions nested in it excluded — or, for
    /// `nil`, the segments in no region; in text order.
    @inlinable
    public func segments(inRegionAt regionIndex: Int?) -> [Segment] {
        segments.filter { $0.regionIndex == regionIndex }
    }
}

// MARK: - Separating

extension FrozenSemanticString {
    /// Splits a string printed with annotation regions into the text it
    /// would have been printed as without them — every atom's own
    /// identifier restored, a visibility tag and definition identities on it
    /// included, and the pieces of each `AnnotatedAtom` merged back into the
    /// spans the atom freezes to — and the table of its regions and
    /// segments.
    ///
    /// A string with no annotations comes back unchanged, with an empty
    /// table. The text is shared, not copied. Running it before or after
    /// `separatingVisibilityRegions()` or `separatingDefinitionRegions()`
    /// gives the same text and the same tables; run it on a projection of
    /// the visibility-separated text to read the regions as that projection
    /// shows them — the same as printing with those options and separating.
    ///
    /// Walks the text, and traps on a value that violates the unchecked
    /// initializer's invariants, as `enumerateSpans(_:)` does.
    @inlinable
    public func separatingAnnotationRegions() -> (text: FrozenSemanticString, annotations: AnnotationRegionTable) {
        guard identifierTable.contains(where: AnnotationTag.carriesMarks) else {
            return (self, .empty)
        }
        // Compared as `UInt64`: `Int(UInt32.max)` does not fit a 32-bit `Int`.
        precondition(UInt64(text.utf8.count) <= UInt64(UInt32.max), "a text over 4 GiB cannot carry annotation regions")

        var separatedIdentifierTable: [String] = []
        var separatedIdentifierIndexByValue: [String: UInt32] = [:]

        // Per original table index (1-based; slot 0 is "no identifier"): the
        // identifier index in the separated table, and the marks.
        var separatedIdentifierIndexByOriginalIndex = [UInt32](repeating: 0, count: identifierTable.count + 1)
        var marksByOriginalIndex = [AnnotationTag.Marks](repeating: AnnotationTag.Marks(), count: identifierTable.count + 1)
        for (tableOffset, identifier) in identifierTable.enumerated() {
            let originalIndex = tableOffset + 1
            let decomposition = AnnotationTag.decompose(identifier)
            marksByOriginalIndex[originalIndex] = decomposition.marks
            guard let separatedIdentifier = decomposition.identifier(with: AnnotationTag.Marks()) else {
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

        var separator = AnnotationSeparator(bytes: Array(text.utf8), spanCapacity: spans.count)
        var spanStart = 0
        for span in spans {
            precondition(span.length > 0, "FrozenSemanticString has a zero-length span; the unchecked init's invariants were violated")
            let spanEnd = spanStart + Int(span.length)
            precondition(spanEnd <= separator.bytes.count, "FrozenSemanticString spans overrun the text; the unchecked init's invariants were violated")
            // An index past the table reads as no identifier, as it does in
            // every reader. `Int(exactly:)` because a 32-bit `Int` cannot hold
            // every `UInt32`, and a decoded payload keeps an out-of-range
            // index verbatim.
            let originalIndex = Int(exactly: span.identifierIndex).flatMap { $0 < marksByOriginalIndex.count ? $0 : nil } ?? 0
            separator.consume(
                span,
                from: spanStart,
                to: spanEnd,
                marks: marksByOriginalIndex[originalIndex],
                separatedIdentifierIndex: separatedIdentifierIndexByOriginalIndex[originalIndex]
            )
            spanStart = spanEnd
        }
        precondition(spanStart == separator.bytes.count, "FrozenSemanticString spans undercover the text; the unchecked init's invariants were violated")
        separator.flushMergeRun()

        return (
            FrozenSemanticString(text: text, spans: separator.separatedSpans, identifierTable: separatedIdentifierTable),
            separator.table()
        )
    }
}

// MARK: - The Separation Pass

/// One pass over the spans of a string printed with annotations: which
/// region, segment and annotated atom each span is in, and the spans of the
/// separated text.
///
/// A span continues an open region of the same kind when its phase says it
/// can — leading and anchor atoms only while the region still awaits its
/// anchor, following atoms after it, unanchored atoms only an unanchored
/// region — and otherwise starts a new one (see `AnnotationTag.Phase`). The
/// spans freezing split one long atom into are recognized as one atom and
/// continue whatever its first span opened. A span without an entry at some
/// depth leaves the region open there, so a region spans whatever a
/// container printed between its items; a span with a different entry ends
/// it.
@usableFromInline
struct AnnotationSeparator {
    @usableFromInline
    enum InstanceState {
        case awaitingAnchor

        case anchored

        case unanchored
    }

    @usableFromInline
    struct OpenInstance {
        /// Into `pendingRegions` or `pendingSegments`; unused for annotated
        /// atoms.
        @usableFromInline
        let pendingIndex: Int

        /// The kind or role; empty for annotated atoms.
        @usableFromInline
        let name: String

        @usableFromInline
        var state: InstanceState

        /// Where its last span ends.
        @usableFromInline
        var lastEnd: Int

        @inlinable
        init(pendingIndex: Int, name: String, state: InstanceState, lastEnd: Int) {
            self.pendingIndex = pendingIndex
            self.name = name
            self.state = state
            self.lastEnd = lastEnd
        }
    }

    @usableFromInline
    struct PendingRegion {
        @usableFromInline
        let kind: String

        @usableFromInline
        let depth: Int

        @usableFromInline
        let enclosingPendingIndex: Int?

        /// Where its first atom that is not trimmed starts; `nil` while it
        /// has none.
        @usableFromInline
        var significantStart: Int?

        @usableFromInline
        var significantEnd: Int

        @inlinable
        init(kind: String, depth: Int, enclosingPendingIndex: Int?) {
            self.kind = kind
            self.depth = depth
            self.enclosingPendingIndex = enclosingPendingIndex
            self.significantStart = nil
            self.significantEnd = 0
        }
    }

    @usableFromInline
    struct PendingSegment {
        @usableFromInline
        let role: String

        @usableFromInline
        let regionPendingIndex: Int?

        @usableFromInline
        let start: Int

        @usableFromInline
        var end: Int

        @inlinable
        init(role: String, regionPendingIndex: Int?, start: Int, end: Int) {
            self.role = role
            self.regionPendingIndex = regionPendingIndex
            self.start = start
            self.end = end
        }
    }

    /// Consecutive pieces of one annotated atom, to be merged into one token.
    @usableFromInline
    struct MergeRun {
        @usableFromInline
        let start: Int

        @usableFromInline
        var end: Int

        @usableFromInline
        let typeCode: UInt8

        @usableFromInline
        let identifierIndex: UInt32

        @inlinable
        init(start: Int, end: Int, typeCode: UInt8, identifierIndex: UInt32) {
            self.start = start
            self.end = end
            self.typeCode = typeCode
            self.identifierIndex = identifierIndex
        }
    }

    @usableFromInline
    let bytes: [UInt8]

    @usableFromInline
    var separatedSpans: [FrozenSemanticString.Span] = []

    @usableFromInline
    var pendingRegions: [PendingRegion] = []

    @usableFromInline
    var pendingSegments: [PendingSegment] = []

    /// One per depth, outermost first; deeper ones stay open while spans
    /// without entries that deep go by.
    @usableFromInline
    var openRegions: [OpenInstance] = []

    @usableFromInline
    var openSegment: OpenInstance?

    @usableFromInline
    var openAnnotatedAtom: OpenInstance?

    @usableFromInline
    var mergeRun: MergeRun?

    // The atom the current span belongs to: several spans when freezing
    // split it.

    @usableFromInline
    var atomStart = 0

    @usableFromInline
    var atomIsLong = false

    @usableFromInline
    var atomRemainingNonSpaceByteCount = 0

    /// Whether some byte of the atom so far is not whitespace, or the atom
    /// lies in a segment: what keeps it from being trimmed off a region.
    @usableFromInline
    var atomIsSignificant = false

    @usableFromInline
    var previousIdentifierIndex: UInt32?

    @inlinable
    init(bytes: [UInt8], spanCapacity: Int) {
        self.bytes = bytes
        separatedSpans.reserveCapacity(spanCapacity)
    }

    @inlinable
    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }

    @inlinable
    static func nonSpaceByteCount(of bytes: ArraySlice<UInt8>) -> Int {
        var count = 0
        for byte in bytes where byte != UInt8(ascii: " ") {
            count += 1
        }
        return count
    }

    /// Whether an atom in `phase` continues `instance`, a span ago or across
    /// spans without an entry at its depth.
    @inlinable
    static func continues(_ instance: OpenInstance, in phase: AnnotationTag.Phase) -> Bool {
        switch phase {
        case .leading, .anchor:
            instance.state == .awaitingAnchor
        case .following:
            instance.state != .unanchored
        case .unanchored:
            instance.state == .unanchored
        }
    }

    @inlinable
    static func state(after phase: AnnotationTag.Phase) -> InstanceState {
        switch phase {
        case .leading:
            .awaitingAnchor
        case .anchor, .following:
            .anchored
        case .unanchored:
            .unanchored
        }
    }

    @inlinable
    mutating func consume(
        _ span: FrozenSemanticString.Span,
        from spanStart: Int,
        to spanEnd: Int,
        marks: AnnotationTag.Marks,
        separatedIdentifierIndex: UInt32
    ) {
        let spanBytes = bytes[spanStart ..< spanEnd]

        // A long atom's later spans carry its identifier and continue it while
        // its non-space bytes last; a span of spaces after them can only be
        // its tail, since a new atom carrying the same marks would have a
        // non-space byte to count.
        var isAtomContinuation = false
        if atomIsLong, previousIdentifierIndex == span.identifierIndex {
            let spanNonSpaceByteCount = Self.nonSpaceByteCount(of: spanBytes)
            if atomRemainingNonSpaceByteCount > 0 || spanNonSpaceByteCount == 0 {
                isAtomContinuation = true
                atomRemainingNonSpaceByteCount -= spanNonSpaceByteCount
            }
        }
        if !isAtomContinuation {
            atomStart = spanStart
            atomIsSignificant = false
            if let recordedNonSpaceByteCount = marks.nonSpaceByteCount {
                atomIsLong = true
                atomRemainingNonSpaceByteCount = recordedNonSpaceByteCount - Self.nonSpaceByteCount(of: spanBytes)
            } else {
                atomIsLong = false
            }
        }
        previousIdentifierIndex = span.identifierIndex
        if !atomIsSignificant {
            atomIsSignificant = marks.segment != nil || spanBytes.contains { !Self.isWhitespace($0) }
        }

        consumeRegions(marks.regions, from: spanStart, to: spanEnd, isAtomContinuation: isAtomContinuation)
        consumeSegment(marks.segment, regionDepth: marks.regions.count, from: spanStart, to: spanEnd, isAtomContinuation: isAtomContinuation)
        emit(span, piecePhase: marks.piece, from: spanStart, to: spanEnd, separatedIdentifierIndex: separatedIdentifierIndex, isAtomContinuation: isAtomContinuation)
    }

    @inlinable
    mutating func consumeRegions(_ entries: [AnnotationTag.Entry], from spanStart: Int, to spanEnd: Int, isAtomContinuation: Bool) {
        for (depth, entry) in entries.enumerated() {
            if depth < openRegions.count,
               openRegions[depth].name == entry.name,
               (isAtomContinuation && openRegions[depth].lastEnd == spanStart) || Self.continues(openRegions[depth], in: entry.phase) {
                openRegions[depth].state = Self.state(after: entry.phase)
                openRegions[depth].lastEnd = spanEnd
            } else {
                openRegions.removeSubrange(min(depth, openRegions.count)...)
                pendingRegions.append(PendingRegion(
                    kind: entry.name,
                    depth: depth,
                    enclosingPendingIndex: depth == 0 ? nil : openRegions[depth - 1].pendingIndex
                ))
                openRegions.append(OpenInstance(
                    pendingIndex: pendingRegions.count - 1,
                    name: entry.name,
                    state: Self.state(after: entry.phase),
                    lastEnd: spanEnd
                ))
            }
            if atomIsSignificant {
                let pendingIndex = openRegions[depth].pendingIndex
                if pendingRegions[pendingIndex].significantStart == nil {
                    pendingRegions[pendingIndex].significantStart = atomStart
                }
                pendingRegions[pendingIndex].significantEnd = spanEnd
            }
        }
    }

    @inlinable
    mutating func consumeSegment(_ entry: AnnotationTag.Entry?, regionDepth: Int, from spanStart: Int, to spanEnd: Int, isAtomContinuation: Bool) {
        guard let entry else { return }
        let regionPendingIndex = regionDepth == 0 ? nil : openRegions[regionDepth - 1].pendingIndex
        if let open = openSegment,
           open.name == entry.name,
           pendingSegments[open.pendingIndex].regionPendingIndex == regionPendingIndex,
           (isAtomContinuation && open.lastEnd == spanStart) || Self.continues(open, in: entry.phase) {
            openSegment = OpenInstance(pendingIndex: open.pendingIndex, name: open.name, state: Self.state(after: entry.phase), lastEnd: spanEnd)
            pendingSegments[open.pendingIndex].end = spanEnd
        } else {
            pendingSegments.append(PendingSegment(role: entry.name, regionPendingIndex: regionPendingIndex, start: spanStart, end: spanEnd))
            openSegment = OpenInstance(pendingIndex: pendingSegments.count - 1, name: entry.name, state: Self.state(after: entry.phase), lastEnd: spanEnd)
        }
    }

    /// Adds the span to the separated text: as it is, or, for a piece of an
    /// annotated atom, to the token the atom's pieces merge back into.
    @inlinable
    mutating func emit(
        _ span: FrozenSemanticString.Span,
        piecePhase: AnnotationTag.Phase?,
        from spanStart: Int,
        to spanEnd: Int,
        separatedIdentifierIndex: UInt32,
        isAtomContinuation: Bool
    ) {
        guard let piecePhase else {
            openAnnotatedAtom = nil
            flushMergeRun()
            separatedSpans.append(FrozenSemanticString.Span(length: span.length, typeCode: span.typeCode, identifierIndex: separatedIdentifierIndex))
            return
        }
        // An annotated atom is one element: its pieces are always contiguous.
        var continuesAtom = false
        if let open = openAnnotatedAtom, open.lastEnd == spanStart {
            continuesAtom = isAtomContinuation || Self.continues(open, in: piecePhase)
        }
        openAnnotatedAtom = OpenInstance(pendingIndex: 0, name: "", state: Self.state(after: piecePhase), lastEnd: spanEnd)
        // Pieces only merge when they agree on what the atom is; pieces that
        // got different marks afterwards (a streaming mark starting in the
        // middle of an atom) stay apart.
        if continuesAtom, let run = mergeRun, run.end == spanStart, run.typeCode == span.typeCode, run.identifierIndex == separatedIdentifierIndex {
            mergeRun = MergeRun(start: run.start, end: spanEnd, typeCode: run.typeCode, identifierIndex: run.identifierIndex)
        } else {
            flushMergeRun()
            mergeRun = MergeRun(start: spanStart, end: spanEnd, typeCode: span.typeCode, identifierIndex: separatedIdentifierIndex)
        }
    }

    /// Emits the pending merged token, split at `UInt16.max` UTF-8 bytes
    /// exactly as `frozen()` splits the atom it was printed as.
    @inlinable
    mutating func flushMergeRun() {
        guard let run = mergeRun else { return }
        mergeRun = nil
        let byteCount = run.end - run.start
        if byteCount <= Int(UInt16.max) {
            separatedSpans.append(FrozenSemanticString.Span(length: UInt16(byteCount), typeCode: run.typeCode, identifierIndex: run.identifierIndex))
            return
        }
        SemanticString.appendSpans(
            forTokenWithUTF8ByteCount: byteCount,
            tokenString: String(decoding: bytes[run.start ..< run.end], as: UTF8.self),
            typeCode: run.typeCode,
            identifierIndex: run.identifierIndex,
            into: &separatedSpans
        )
    }

    /// The table: regions trimmed of leading and trailing atoms that hold
    /// only whitespace and lie in no segment, those left with nothing
    /// dropped.
    @inlinable
    func table() -> AnnotationRegionTable {
        var tableIndexByPendingIndex = [Int?](repeating: nil, count: pendingRegions.count)
        var regions: [AnnotationRegionTable.Region] = []
        regions.reserveCapacity(pendingRegions.count)
        for (pendingIndex, pendingRegion) in pendingRegions.enumerated() {
            // A region left with nothing has only whitespace outside
            // segments, and so has every region inside it: those go too, and
            // an enclosing index never points at a dropped region.
            guard let significantStart = pendingRegion.significantStart else { continue }
            tableIndexByPendingIndex[pendingIndex] = regions.count
            regions.append(AnnotationRegionTable.Region(
                kind: AnnotationRegion.Kind(uncheckedRawValue: pendingRegion.kind),
                utf8Offset: UInt32(significantStart),
                utf8Length: UInt32(pendingRegion.significantEnd - significantStart),
                depth: pendingRegion.depth,
                enclosingRegionIndex: pendingRegion.enclosingPendingIndex.flatMap { tableIndexByPendingIndex[$0] }
            ))
        }
        let segments = pendingSegments.map { pendingSegment in
            AnnotationRegionTable.Segment(
                role: AnnotationSegment.Role(uncheckedRawValue: pendingSegment.role),
                utf8Offset: UInt32(pendingSegment.start),
                utf8Length: UInt32(pendingSegment.end - pendingSegment.start),
                regionIndex: pendingSegment.regionPendingIndex.flatMap { tableIndexByPendingIndex[$0] }
            )
        }
        return AnnotationRegionTable(regions: regions, segments: segments)
    }
}
