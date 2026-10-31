// MARK: - Annotation Region

/// Content that is one thing of a kind its printer names — a comment giving
/// a member's address, a node of a field-offset tree, the layout notes of
/// one enum case.
///
/// A printer that knows the structure of what it prints wraps each piece of
/// it in a region, and the parts of a region in `AnnotationSegment`s, so a
/// reader can present that structure — a comment drawn as a tag, a tree
/// folded to its root — without parsing text the user may have reworded.
/// `FrozenSemanticString.separatingAnnotationRegions()` reads the regions
/// back into an `AnnotationRegionTable`.
///
/// A region changes nothing about the text: the content renders exactly as
/// it would unwrapped, atom for atom, and it keeps its element structure.
/// What it adds is its kind, recorded on each atom's `identifier`; the
/// separation reads it back and restores the atoms' own identifiers, so
/// separating a string printed with regions gives back exactly the string
/// printed without them. Until then the atoms' `identifier` holds the
/// encoding — a string printed with regions is meant to be frozen and
/// separated, not rendered or linked as is.
///
/// Regions nest, one kind inside another or inside itself. Two regions of
/// the same kind directly next to each other read back as two. A region
/// spans from its first atom to its last — line breaks or indentation a
/// container prints between its items included — less leading and trailing
/// atoms that hold only whitespace and lie in no segment.
///
/// Regions compose with `VisibilityRegion` and `DefinitionRegion` in any
/// nesting order, and every order produces the same atoms: on an identifier
/// carrying several, the visibility encoding stays outermost and the
/// definition identities next, so containers and the other two separations
/// read them exactly as they would without annotations, and the three
/// separations run in any order.
///
/// A region holding nothing records nothing.
public struct AnnotationRegion: SemanticStringComponent {
    /// What a region is. The kinds belong to the printers that mark them;
    /// this library never interprets them, and defines only the ones more
    /// than one printer uses. A printer adds its own in an extension:
    ///
    /// ```swift
    /// extension AnnotationRegion.Kind {
    ///     public static let memberAddress = Self("memberAddress")
    /// }
    /// ```
    ///
    /// A kind must not be empty and must not contain control characters,
    /// which the encoding reserves.
    public struct Kind: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        @inlinable
        public init(rawValue: String) {
            AnnotationTag.validate(rawValue, describedAs: "kind")
            self.init(uncheckedRawValue: rawValue)
        }

        @inlinable
        public init(_ rawValue: String) {
            self.init(rawValue: rawValue)
        }

        /// A kind read back from an identifier, which a hand-built string
        /// may have filled with anything but the encoding's own markers; a
        /// reader does not trap on it.
        @inlinable
        init(uncheckedRawValue rawValue: String) {
            self.rawValue = rawValue
        }

        /// An explanatory comment that belongs to no more specific kind.
        public static let note = Kind("note")
    }

    @usableFromInline
    let kind: Kind

    @usableFromInline
    let content: SemanticString

    /// Creates a region from a sync result builder.
    @inlinable
    public init(_ kind: Kind, @SemanticStringBuilder content: () -> SemanticString) {
        self.kind = kind
        self.content = content()
    }

    /// Creates a region from an async result builder.
    @inlinable
    public init(_ kind: Kind, @SemanticStringBuilder content: () async throws -> SemanticString) async rethrows {
        self.kind = kind
        self.content = try await content()
    }

    /// Creates a region around pre-built content.
    @inlinable
    public init(_ kind: Kind, content: SemanticString) {
        self.kind = kind
        self.content = content
    }

    /// The content's atoms, each carrying the kind. Used where a composite
    /// flattens its children directly; the content then forms one run, as
    /// any composite's does.
    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        let atoms = content.components
        guard !atoms.isEmpty else { return [] }
        return AnnotationTag.tagged(atoms, with: .region(kind: kind.rawValue))
    }

    /// Appends one element per element of the content, so wrapping content
    /// in a region never merges the items a container sees.
    @inlinable
    public func _appendAsElement(into semanticString: inout SemanticString) {
        AnnotationTag.appendTagged(content, with: .region(kind: kind.rawValue), into: &semanticString)
    }
}
