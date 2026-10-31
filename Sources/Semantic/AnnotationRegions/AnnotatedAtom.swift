// MARK: - Annotated Atom

/// One atom, printed as pieces so that its parts can be annotated.
///
/// A printer that writes a comment as a single string — `// Address:
/// 0x135DC`, or a block of several lines — cannot put a segment or a region
/// around part of it, because marks go on whole atoms. An annotated atom
/// prints the same text as pieces: each atom of its content is one piece,
/// and pieces sit in segments and regions like any atom.
/// `FrozenSemanticString.separatingAnnotationRegions()` then merges the
/// pieces back into the one span the atom would have frozen to — split at
/// `UInt16.max` UTF-8 bytes exactly as `frozen()` splits it — so the
/// separated string is exactly the string printed with the atom whole.
///
/// ```swift
/// AnnotatedAtom(type: .comment) {
///     AnnotationSegment(.marker) { "// " }
///     AnnotationSegment(.label) { "Address" }
///     AnnotationSegment(.separator) { ": " }
///     AnnotationSegment(.value) { "0x135DC" }
/// }
/// // separates to the span Comment("Address: 0x135DC") freezes to
/// ```
///
/// Every piece takes the atom's `type` and `identifier`, whatever its own
/// were. The atom is one element. It traps when its content holds an atom
/// with an identifier of its own, a visibility condition or a definition
/// identity — one atom has one identifier and one visibility — or another
/// annotated atom. Marks added around the atom afterwards are not its
/// content and go on every piece alike: wrapping it in a `VisibilityRegion`,
/// `DefinitionRegion` or `AnnotationRegion`, or marking it with
/// `markAtoms(from:visibleUnder:)`, is how it is meant to be used.
///
/// Until the annotations are separated, operations that count or inspect
/// atoms — `components`, `count`, `trimmingWhitespace()` — see the pieces.
/// An annotated atom holding nothing prints nothing.
public struct AnnotatedAtom: SemanticStringComponent {
    @usableFromInline
    let type: SemanticType

    @usableFromInline
    let identifier: String?

    @usableFromInline
    let content: SemanticString

    /// Creates an annotated atom from a sync result builder.
    @inlinable
    public init(type: SemanticType, identifier: String? = nil, @SemanticStringBuilder content: () -> SemanticString) {
        self.type = type
        self.identifier = identifier
        self.content = content()
    }

    /// Creates an annotated atom from an async result builder.
    @inlinable
    public init(type: SemanticType, identifier: String? = nil, @SemanticStringBuilder content: () async throws -> SemanticString) async rethrows {
        self.type = type
        self.identifier = identifier
        self.content = try await content()
    }

    /// Creates an annotated atom around pre-built content.
    @inlinable
    public init(type: SemanticType, identifier: String? = nil, content: SemanticString) {
        self.type = type
        self.identifier = identifier
        self.content = content
    }

    /// The pieces. Appended as one element, through the default
    /// `_appendAsElement(into:)`.
    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        let atoms = content.components
        guard !atoms.isEmpty else { return [] }
        let phases = AnnotationTag.phases(of: atoms[...])
        let ownIdentifier = identifier.map { Substring($0) } ?? ""
        var pieces: [AtomicComponent] = []
        pieces.reserveCapacity(atoms.count)
        for (offset, atom) in atoms.enumerated() {
            let decomposition = AnnotationTag.decompose(atom.identifier)
            precondition(
                decomposition.outerPart.isEmpty,
                "the pieces of an AnnotatedAtom cannot carry visibility conditions or definition identities; mark the AnnotatedAtom instead"
            )
            precondition(
                decomposition.original.isEmpty,
                "the pieces of an AnnotatedAtom carry no identifier of their own; pass the atom's identifier to the AnnotatedAtom"
            )
            precondition(decomposition.marks.piece == nil, "an AnnotatedAtom cannot contain another AnnotatedAtom")
            var marks = decomposition.marks
            marks.piece = phases[offset]
            if marks.nonSpaceByteCount == nil, atom.string.utf8.count > Int(UInt16.max) {
                marks.nonSpaceByteCount = AnnotationTag.nonSpaceByteCount(of: atom.string)
            }
            let pieceIdentifier = AnnotationTag.Decomposition(outerPart: "", marks: marks, original: ownIdentifier).identifier(with: marks)
            pieces.append(AtomicComponent(string: atom.string, type: type, identifier: pieceIdentifier))
        }
        return pieces
    }
}
