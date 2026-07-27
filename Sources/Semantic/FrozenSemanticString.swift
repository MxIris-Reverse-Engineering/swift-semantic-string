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
public struct FrozenSemanticString: Sendable, Hashable {
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
    public let identifierTable: [String]

    /// Creates a frozen string from raw parts. The caller is responsible for
    /// the invariants (`spans` lengths partition `text`'s UTF-8 view, every
    /// `typeCode` is valid, every non-zero `identifierIndex` is in range);
    /// `SemanticString.frozen()` and `Codable` decoding are the validated
    /// construction paths.
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
    @inlinable
    public var count: Int { spans.count }

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
            let identifier: String? = span.identifierIndex == 0 ? nil : identifierTable[Int(span.identifierIndex) - 1]
            body(spanText, type, identifier)
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

// MARK: - Freezing

extension SemanticString {
    /// Returns the immutable, memory-compact snapshot of this string.
    /// See `FrozenSemanticString`.
    @inlinable
    public func frozen() -> FrozenSemanticString {
        let atomicComponents = components

        // Zero-length components contribute no bytes, so concatenating the
        // non-empty ones is by construction exactly `string` — which is
        // already cached on any value that has been rendered, measured, or
        // compared. Rebuilding it here would walk every component a second
        // time and allocate a full-text buffer beside the live one, on the
        // very call whose purpose is to reduce footprint.
        let text = string

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

// MARK: - Semantic Type Codes

extension SemanticType {
    /// Stable storage/wire code for `FrozenSemanticString.Span.typeCode`.
    ///
    /// Append-only: existing assignments must never be renumbered, or
    /// previously encoded frozen strings decode with wrong styling. New
    /// `SemanticType` cases get the next free code.
    @inlinable
    public var frozenTypeCode: UInt8 {
        switch self {
        case .standard: return 0
        case .comment: return 1
        case .keyword: return 2
        case .variable: return 3
        case .numeric: return 4
        case .argument: return 5
        case .error: return 6
        case .other: return 7
        case .type(let typeKind, let context):
            let typeKindOffset: UInt8
            switch typeKind {
            case .enum: typeKindOffset = 0
            case .struct: typeKindOffset = 1
            case .class: typeKindOffset = 2
            case .protocol: typeKindOffset = 3
            case .other: typeKindOffset = 4
            }
            return 8 + typeKindOffset * 2 + (context == .declaration ? 0 : 1)
        case .member(let context):
            return 18 + (context == .declaration ? 0 : 1)
        case .function(let context):
            return 20 + (context == .declaration ? 0 : 1)
        }
    }

    /// Inverse of `frozenTypeCode`. Returns `nil` for codes this version
    /// does not know (encoded by a future version).
    @inlinable
    public init?(frozenTypeCode: UInt8) {
        switch frozenTypeCode {
        case 0: self = .standard
        case 1: self = .comment
        case 2: self = .keyword
        case 3: self = .variable
        case 4: self = .numeric
        case 5: self = .argument
        case 6: self = .error
        case 7: self = .other
        case 8 ... 17:
            let typeKindOffset = (frozenTypeCode - 8) / 2
            let typeKind: TypeKind
            switch typeKindOffset {
            case 0: typeKind = .enum
            case 1: typeKind = .struct
            case 2: typeKind = .class
            case 3: typeKind = .protocol
            default: typeKind = .other
            }
            self = .type(typeKind, (frozenTypeCode - 8).isMultiple(of: 2) ? .declaration : .name)
        case 18, 19:
            self = .member(frozenTypeCode == 18 ? .declaration : .name)
        case 20, 21:
            self = .function(frozenTypeCode == 20 ? .declaration : .name)
        default:
            return nil
        }
    }
}

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
        var coveredUTF8ByteCount = 0
        for length in spanLengths {
            coveredUTF8ByteCount += Int(length)
        }
        guard coveredUTF8ByteCount == text.utf8.count else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Span lengths cover \(coveredUTF8ByteCount) bytes but text has \(text.utf8.count)"
            ))
        }
        for identifierIndex in spanIdentifierIndices where identifierIndex != 0 {
            guard Int(identifierIndex) <= identifierTable.count else {
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
