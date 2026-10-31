// MARK: - Tag Encoding

/// The encoding of annotation regions, annotation segments and annotated
/// atoms in `AtomicComponent.identifier`.
///
/// `␐<fields>␐<original identifier>`. On an identifier that carries a
/// visibility tag or definition identities, the encoding goes after both —
/// `␁<conditions>␁␆<identities>␆␐<fields>␐<original identifier>` — so they
/// stay outermost: containers and `separatingVisibilityRegions()` recognize a
/// visibility tag by its first character, and `separatingDefinitionRegions()`
/// and `content(ofDefinitionRegion:)` keep everything after the identities as
/// the original identifier, annotation fields included, untouched. Adding a
/// visibility tag or an identity to an identifier carrying annotation fields
/// therefore needs nothing from this type.
///
/// The fields, in this order, each opened by its own marker:
///
/// - `␔<count>`: on an atom over `UInt16.max` UTF-8 bytes, how many of its
///   bytes are not spaces (see `Phase.anchor`);
/// - `␓<phase>`: the `AnnotatedAtom` the atom is a piece of;
/// - `␑<phase><kind>`: one per enclosing `AnnotationRegion`, outermost first;
/// - `␒<phase><role>`: the `AnnotationSegment` the atom is in.
///
/// (U+0010–U+0014. A kind or role may not contain control characters, and no
/// real identifier starts with one.)
@usableFromInline
enum AnnotationTag {
    @usableFromInline
    static let partMarker: Character = "\u{10}"

    @usableFromInline
    static let regionMarker: Character = "\u{11}"

    @usableFromInline
    static let segmentMarker: Character = "\u{12}"

    @usableFromInline
    static let pieceMarker: Character = "\u{13}"

    @usableFromInline
    static let nonSpaceByteCountMarker: Character = "\u{14}"

    /// Where an atom sits in the region, segment or annotated atom it is
    /// marked with. Phases are what let two regions of the same kind sit
    /// side by side and still read back as two: they depend on nothing but
    /// the region's own content, so the same content marks the same wherever
    /// it is printed, and no operation that changes a marked string removes
    /// the atom a region is recognized by.
    @usableFromInline
    enum Phase: Character, Sendable {
        /// Before the anchor. Leading atoms hold nothing but spaces, or carry
        /// visibility conditions some other atom of the region does not.
        case leading = "-"

        /// The first atom that has a byte other than a space and whose
        /// visibility conditions every atom of the region carries.
        ///
        /// `removingIndentation(levels:)` removes only spaces, so it can
        /// shrink an anchor but never remove it; a projection removes whole
        /// atoms by condition, and the anchor is visible whenever any atom of
        /// the region is; taking a definition region out changes no atom.
        /// Freezing splits an atom over `UInt16.max` UTF-8 bytes into several
        /// spans that carry the same identifier, so such an atom also records
        /// how many of its bytes are not spaces — a number indentation
        /// removal does not change — and the separation tells the rest of its
        /// spans from the anchor of a new region by it.
        case anchor = "*"

        /// After the anchor.
        case following = "+"

        /// Every atom of a region that has no anchor: one holding nothing but
        /// spaces, or one whose every atom with a byte other than a space
        /// carries a visibility condition another atom does not.
        case unanchored = "~"
    }

    /// A region's or segment's mark on one atom.
    @usableFromInline
    struct Entry: Hashable, Sendable {
        /// The kind or the role.
        @usableFromInline
        let name: String

        @usableFromInline
        let phase: Phase

        @inlinable
        init(name: String, phase: Phase) {
            self.name = name
            self.phase = phase
        }
    }

    /// The annotation fields of one identifier.
    @usableFromInline
    struct Marks: Hashable, Sendable {
        @usableFromInline
        var nonSpaceByteCount: Int?

        /// The phase in the `AnnotatedAtom` the atom is a piece of.
        @usableFromInline
        var piece: Phase?

        /// Outermost first.
        @usableFromInline
        var regions: [Entry]

        @usableFromInline
        var segment: Entry?

        @inlinable
        init(nonSpaceByteCount: Int? = nil, piece: Phase? = nil, regions: [Entry] = [], segment: Entry? = nil) {
            self.nonSpaceByteCount = nonSpaceByteCount
            self.piece = piece
            self.regions = regions
            self.segment = segment
        }

        @inlinable
        var isEmpty: Bool {
            nonSpaceByteCount == nil && piece == nil && regions.isEmpty && segment == nil
        }
    }

    /// An identifier taken apart around its annotation fields.
    @usableFromInline
    struct Decomposition {
        /// The visibility tag's conditions and the definition identities,
        /// exactly as they are; empty when the identifier has neither.
        @usableFromInline
        let outerPart: Substring

        @usableFromInline
        let marks: Marks

        @usableFromInline
        let original: Substring

        @inlinable
        init(outerPart: Substring, marks: Marks, original: Substring) {
            self.outerPart = outerPart
            self.marks = marks
            self.original = original
        }

        /// The identifier put back together with `marks` in place of the
        /// ones it had, or `nil` when nothing is left.
        @inlinable
        func identifier(with marks: Marks) -> String? {
            var rebuilt = String(outerPart)
            if !marks.isEmpty {
                rebuilt += AnnotationTag.encode(marks)
            }
            rebuilt += original
            return rebuilt.isEmpty ? nil : rebuilt
        }
    }

    @inlinable
    static func validate(_ name: String, describedAs description: String) {
        precondition(!name.isEmpty, "an annotation \(description) must not be empty")
        precondition(
            !name.unicodeScalars.contains { $0.value < 0x20 },
            "an annotation \(description) must not contain control characters"
        )
    }

    /// Whether `identifier` carries annotation fields. The markers are
    /// control characters no kind, role or real identifier contains, so
    /// finding one is enough.
    @inlinable
    static func carriesMarks(_ identifier: String) -> Bool {
        identifier.contains(partMarker)
    }

    /// Where the part of `identifier` that can carry annotation fields
    /// starts: after a visibility tag's conditions and definition identities
    /// when it has them. A malformed definition part — no closing marker — is
    /// the original identifier to `DefinitionTag.decompose`, and so it is
    /// here.
    @inlinable
    static func annotationPartStart(of identifier: String) -> String.Index {
        let definitionPartStart = DefinitionTag.definitionPartStart(of: identifier)
        let definitionPart = identifier[definitionPartStart...]
        guard definitionPart.first == DefinitionTag.tagMarker,
              let closingMarkerIndex = definitionPart.dropFirst().firstIndex(of: DefinitionTag.tagMarker)
        else {
            return definitionPartStart
        }
        return identifier.index(after: closingMarkerIndex)
    }

    @inlinable
    static func decompose(_ identifier: String?) -> Decomposition {
        guard let identifier else {
            return Decomposition(outerPart: "", marks: Marks(), original: "")
        }
        let partStart = annotationPartStart(of: identifier)
        let annotationPart = identifier[partStart...]
        guard annotationPart.first == partMarker,
              let closingMarkerIndex = annotationPart.dropFirst().firstIndex(of: partMarker),
              let marks = decodeFields(annotationPart[annotationPart.index(after: annotationPart.startIndex) ..< closingMarkerIndex])
        else {
            return Decomposition(outerPart: identifier[..<partStart], marks: Marks(), original: annotationPart)
        }
        return Decomposition(
            outerPart: identifier[..<partStart],
            marks: marks,
            original: annotationPart[annotationPart.index(after: closingMarkerIndex)...]
        )
    }

    @inlinable
    static func encode(_ marks: Marks) -> String {
        var encoded = String(partMarker)
        if let nonSpaceByteCount = marks.nonSpaceByteCount {
            encoded.append(nonSpaceByteCountMarker)
            encoded += String(nonSpaceByteCount)
        }
        if let piece = marks.piece {
            encoded.append(pieceMarker)
            encoded.append(piece.rawValue)
        }
        for region in marks.regions {
            encoded.append(regionMarker)
            encoded.append(region.phase.rawValue)
            encoded += region.name
        }
        if let segment = marks.segment {
            encoded.append(segmentMarker)
            encoded.append(segment.phase.rawValue)
            encoded += segment.name
        }
        encoded.append(partMarker)
        return encoded
    }

    @inlinable
    static func isFieldMarker(_ character: Character) -> Bool {
        character == regionMarker || character == segmentMarker || character == pieceMarker || character == nonSpaceByteCountMarker
    }

    /// The fields between the two part markers, or `nil` when they are
    /// malformed — which only a hand-built identifier can be, and which then
    /// reads as carrying no annotation at all.
    @inlinable
    static func decodeFields(_ fields: Substring) -> Marks? {
        var marks = Marks()
        var remaining = fields
        while let marker = remaining.first {
            let body = remaining.dropFirst()
            let fieldEnd = body.firstIndex(where: isFieldMarker) ?? body.endIndex
            let field = body[..<fieldEnd]
            remaining = body[fieldEnd...]
            switch marker {
            case nonSpaceByteCountMarker:
                guard let nonSpaceByteCount = Int(field) else { return nil }
                marks.nonSpaceByteCount = nonSpaceByteCount
            case pieceMarker:
                guard field.count == 1, let phase = field.first.flatMap(Phase.init(rawValue:)) else { return nil }
                marks.piece = phase
            case regionMarker, segmentMarker:
                guard let phase = field.first.flatMap(Phase.init(rawValue:)), field.count > 1 else { return nil }
                let entry = Entry(name: String(field.dropFirst()), phase: phase)
                if marker == regionMarker {
                    marks.regions.append(entry)
                } else {
                    marks.segment = entry
                }
            default:
                return nil
            }
        }
        return marks
    }

    // MARK: - Phases

    @inlinable
    static func hasNonSpaceByte(_ string: String) -> Bool {
        string.utf8.contains { $0 != UInt8(ascii: " ") }
    }

    @inlinable
    static func nonSpaceByteCount(of string: String) -> Int {
        var count = 0
        for byte in string.utf8 where byte != UInt8(ascii: " ") {
            count += 1
        }
        return count
    }

    /// The encoded visibility conditions an identifier carries; empty when
    /// it carries none. A malformed tag — no second marker — is a plain
    /// identifier to `VisibilityTag.decode`, and so it is here.
    @inlinable
    static func visibilityConditionCodes(of identifier: String?) -> Set<Substring> {
        guard let identifier, VisibilityTag.isTag(identifier) else {
            return []
        }
        let body = identifier.dropFirst()
        guard let closingMarkerIndex = body.firstIndex(of: VisibilityTag.tagMarker) else {
            return []
        }
        return Set(body[..<closingMarkerIndex].split(separator: VisibilityTag.conditionSeparator, omittingEmptySubsequences: false))
    }

    /// The phase of each of `atoms` — the whole content of one region,
    /// segment or annotated atom — in order. See `Phase`.
    @inlinable
    static func phases(of atoms: ArraySlice<AtomicComponent>) -> [Phase] {
        guard !atoms.isEmpty else {
            return []
        }
        // Only content wrapped around a visibility region has atoms that are
        // visible under different conditions; everywhere else every atom
        // qualifies as the anchor and this costs one look per atom.
        var conditionCodes: [Set<Substring>] = []
        var sharedConditionCodes: Set<Substring> = []
        if atoms.contains(where: { $0.identifier.map(VisibilityTag.isTag) ?? false }) {
            conditionCodes = atoms.map { visibilityConditionCodes(of: $0.identifier) }
            sharedConditionCodes = conditionCodes.dropFirst().reduce(conditionCodes[0]) { $0.intersection($1) }
        }
        var anchorOffset: Int?
        for (offset, atom) in atoms.enumerated() where hasNonSpaceByte(atom.string) {
            if conditionCodes.isEmpty || conditionCodes[offset] == sharedConditionCodes {
                anchorOffset = offset
                break
            }
        }
        guard let anchorOffset else {
            return Array(repeating: .unanchored, count: atoms.count)
        }
        return (0 ..< atoms.count).map { offset in
            offset < anchorOffset ? .leading : (offset == anchorOffset ? .anchor : .following)
        }
    }

    // MARK: - Tagging

    /// What wraps the atoms being tagged.
    @usableFromInline
    enum Wrapper {
        case region(kind: String)

        case segment(role: String)
    }

    @usableFromInline
    struct TaggingKey: Hashable {
        @usableFromInline
        let identifier: String?

        @usableFromInline
        let phase: Phase

        @inlinable
        init(identifier: String?, phase: Phase) {
            self.identifier = identifier
            self.phase = phase
        }
    }

    /// `atoms` — the whole content of one region or segment — each marked
    /// with it as the outermost region, or as its segment.
    @inlinable
    static func tagged(_ atoms: [AtomicComponent], with wrapper: Wrapper) -> [AtomicComponent] {
        let phases = phases(of: atoms[...])
        // Atoms mostly share a handful of identifiers (none, a visibility tag,
        // the marks of the region nested inside), so each distinct one is
        // re-encoded once per phase. An atom long enough to record its
        // non-space byte count is encoded on its own.
        var taggedIdentifierByKey: [TaggingKey: String] = [:]
        var result: [AtomicComponent] = []
        result.reserveCapacity(atoms.count)
        for (offset, atom) in atoms.enumerated() {
            let phase = phases[offset]
            let isLong = atom.string.utf8.count > Int(UInt16.max)
            let key = TaggingKey(identifier: atom.identifier, phase: phase)
            let taggedIdentifier: String
            if !isLong, let cached = taggedIdentifierByKey[key] {
                taggedIdentifier = cached
            } else {
                let decomposition = decompose(atom.identifier)
                var marks = decomposition.marks
                switch wrapper {
                case .region(let kind):
                    marks.regions.insert(Entry(name: kind, phase: phase), at: 0)
                case .segment(let role):
                    precondition(marks.segment == nil, "an annotation segment cannot contain another annotation segment")
                    precondition(marks.regions.isEmpty, "an annotation segment cannot contain an annotation region")
                    marks.segment = Entry(name: role, phase: phase)
                }
                if isLong, marks.nonSpaceByteCount == nil {
                    marks.nonSpaceByteCount = nonSpaceByteCount(of: atom.string)
                }
                // Never `nil`: the marks just gained an entry.
                taggedIdentifier = decomposition.identifier(with: marks) ?? ""
                if !isLong {
                    taggedIdentifierByKey[key] = taggedIdentifier
                }
            }
            result.append(AtomicComponent(string: atom.string, type: atom.type, identifier: taggedIdentifier))
        }
        return result
    }

    /// Appends `content` marked by `wrapper`, one element per element of the
    /// content, so marking content never merges the items a container sees.
    @inlinable
    static func appendTagged(_ content: SemanticString, with wrapper: Wrapper, into semanticString: inout SemanticString) {
        let atoms = content.components
        guard !atoms.isEmpty else { return }
        let taggedAtoms = tagged(atoms, with: wrapper)
        // The element slices index the same flat array the tagged atoms
        // mirror one for one.
        let elements = content.elements
        for index in elements.indices {
            let elementAtoms = elements.atoms(ofElementAt: index)
            guard !elementAtoms.isEmpty else { continue }
            semanticString.appendComponentElement(flattening: Array(taggedAtoms[elementAtoms.startIndex ..< elementAtoms.endIndex]))
        }
    }
}
