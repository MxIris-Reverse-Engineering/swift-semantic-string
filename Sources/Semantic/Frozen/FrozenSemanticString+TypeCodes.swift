// MARK: - Semantic Type Codes

extension SemanticType {
    /// Stable storage/wire code for `FrozenSemanticString.Span.typeCode`.
    ///
    /// Append-only: existing assignments must never be renumbered, or
    /// previously encoded frozen strings decode with wrong styling. New
    /// `SemanticType` cases — and new `TypeKind` cases — take the next free
    /// code from `nextFreeFrozenTypeCode`.
    ///
    /// Codes are written out one per case rather than derived arithmetically.
    /// The previous form computed `.type` codes as `8 + typeKindOffset * 2`,
    /// which put the block's growth edge directly against `.member`'s fixed
    /// code of 18: adding a sixth `TypeKind` would compile (the encoder's
    /// `switch` over `TypeKind` forces you to give it an offset, and `5` is
    /// the obvious one) and silently emit 18 for
    /// `.type(newKind, .declaration)` — the same code `.member(.declaration)`
    /// already owns. The decoder's `case 8 ... 17` would not have been
    /// updated, and nothing in the type system would have objected.
    /// `FrozenTypeCodeTests` pins uniqueness so a future case cannot
    /// reintroduce the collision.
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
            // Each kind owns a fixed pair: declaration, then name. A new kind
            // must take a fresh pair starting at `nextFreeFrozenTypeCode` —
            // *not* the next value after `.other`'s pair, which belongs to
            // `.member`.
            let base: UInt8
            switch typeKind {
            case .enum: base = 8
            case .struct: base = 10
            case .class: base = 12
            case .protocol: base = 14
            case .other: base = 16
            }
            return base + (context == .declaration ? 0 : 1)
        case .member(let context):
            return 18 + (context == .declaration ? 0 : 1)
        case .function(let context):
            return 20 + (context == .declaration ? 0 : 1)
        }
    }

    /// The lowest code no case has claimed. New cases start here.
    @inlinable
    public static var nextFreeFrozenTypeCode: UInt8 { 22 }

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
        case 8, 9: self = .type(.enum, frozenTypeCode == 8 ? .declaration : .name)
        case 10, 11: self = .type(.struct, frozenTypeCode == 10 ? .declaration : .name)
        case 12, 13: self = .type(.class, frozenTypeCode == 12 ? .declaration : .name)
        case 14, 15: self = .type(.protocol, frozenTypeCode == 14 ? .declaration : .name)
        case 16, 17: self = .type(.other, frozenTypeCode == 16 ? .declaration : .name)
        case 18, 19: self = .member(frozenTypeCode == 18 ? .declaration : .name)
        case 20, 21: self = .function(frozenTypeCode == 20 ? .declaration : .name)
        default:
            return nil
        }
    }
}
