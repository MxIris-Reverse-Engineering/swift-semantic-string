// MARK: - Annotation Segment

/// Part of an `AnnotationRegion` with a role of its own — a comment's
/// marker, its label, the value it reports.
///
/// A reader that draws a comment as a tag hides some roles (`marker`,
/// `separator`, `treePrefix`) and styles the others, so a segment is what
/// lets it do that without parsing the comment's text.
/// `FrozenSemanticString.separatingAnnotationRegions()` reads segments back
/// into `AnnotationRegionTable.segments`, each with the innermost region it
/// lies in.
///
/// Like a region, a segment changes nothing about the text and keeps its
/// content's element structure, and two segments with the same role
/// directly next to each other read back as two. Its content may be any
/// atoms — of any semantic type, carrying identifiers, visibility conditions
/// or definition identities — but a segment is a leaf: it traps when its
/// content holds another segment or an annotation region. Unlike a region,
/// a segment's range is never trimmed of whitespace. A segment holding
/// nothing records nothing.
///
/// To mark the parts of what prints as a single atom without marks — a
/// comment written as one string — put the segments in an `AnnotatedAtom`.
public struct AnnotationSegment: SemanticStringComponent {
    /// The part a segment plays. The roles are the ones the printers that
    /// mark comments share; like kinds, more can be added in an extension,
    /// and this library never interprets them.
    ///
    /// A role must not be empty and must not contain control characters,
    /// which the encoding reserves.
    public struct Role: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        @inlinable
        public init(rawValue: String) {
            AnnotationTag.validate(rawValue, describedAs: "role")
            self.init(uncheckedRawValue: rawValue)
        }

        @inlinable
        public init(_ rawValue: String) {
            self.init(rawValue: rawValue)
        }

        /// See `AnnotationRegion.Kind.init(uncheckedRawValue:)`.
        @inlinable
        init(uncheckedRawValue rawValue: String) {
            self.rawValue = rawValue
        }

        /// The comment's delimiters: `// `, `/* `, ` */`.
        public static let marker = Role("marker")

        /// What the comment reports: `Address`, `VTable offset`.
        public static let label = Role("label")

        /// A word qualifying the label: the `getter` of `IMP (getter)`.
        public static let qualifier = Role("qualifier")

        /// Punctuation between the other parts: `: `, `, `, `(`, `)`.
        public static let separator = Role("separator")

        /// The name of one field of several: the `size` of `size: 16`.
        public static let key = Role("key")

        /// A value: `0x135DC`, `16`.
        public static let value = Role("value")

        /// The name of what the comment describes: a field, a case.
        public static let name = Role("name")

        /// The type of what the comment describes.
        public static let type = Role("type")

        /// The drawing of a tree's structure in front of a node: `│   ├── `.
        public static let treePrefix = Role("treePrefix")

        /// Explanatory prose.
        public static let text = Role("text")
    }

    @usableFromInline
    let role: Role

    @usableFromInline
    let content: SemanticString

    /// Creates a segment from a sync result builder.
    @inlinable
    public init(_ role: Role, @SemanticStringBuilder content: () -> SemanticString) {
        self.role = role
        self.content = content()
    }

    /// Creates a segment from an async result builder.
    @inlinable
    public init(_ role: Role, @SemanticStringBuilder content: () async throws -> SemanticString) async rethrows {
        self.role = role
        self.content = try await content()
    }

    /// Creates a segment around pre-built content.
    @inlinable
    public init(_ role: Role, content: SemanticString) {
        self.role = role
        self.content = content
    }

    /// The content's atoms, each carrying the role. Used where a composite
    /// flattens its children directly; the content then forms one run, as
    /// any composite's does.
    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        let atoms = content.components
        guard !atoms.isEmpty else { return [] }
        return AnnotationTag.tagged(atoms, with: .segment(role: role.rawValue))
    }

    /// Appends one element per element of the content, so wrapping content
    /// in a segment never merges the items a container sees.
    @inlinable
    public func _appendAsElement(into semanticString: inout SemanticString) {
        AnnotationTag.appendTagged(content, with: .segment(role: role.rawValue), into: &semanticString)
    }
}
