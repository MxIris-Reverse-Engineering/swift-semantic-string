// MARK: - Definition Region

/// Content that is the printed form of one definition — a type, a protocol,
/// any declaration with an identity of its own — inside the printed form of
/// another.
///
/// A printer that prints a definition together with the definitions nested
/// in it can wrap each nested one in a region. A reader then finds where
/// each nested definition lies in the text
/// (`FrozenSemanticString.separatingDefinitionRegions()`) and takes it out
/// as a string of its own (`content(ofDefinitionRegion:)`, then
/// `removingIndentation(levels:)`), instead of printing it a second time.
///
/// A region changes nothing about the text: the content renders exactly as
/// it would unwrapped, atom for atom, and it keeps its element structure.
/// What it adds is its identity, recorded on each atom's `identifier`; the
/// separation reads it back and restores the atoms' own identifiers, so
/// separating a string printed with regions gives back exactly the string
/// printed without them. Until then the atoms' `identifier` holds the
/// encoding — a string printed with regions is meant to be frozen and
/// separated, not rendered or linked as is.
///
/// A region covers its content's atoms and nothing else. The line break a
/// `NestedDeclaration` puts in front of it, or anything a container prints
/// around it, belongs to the enclosing text. Regions nest, and a region
/// inside another is recorded with its depth and the region enclosing it.
///
/// Regions compose with `VisibilityRegion` in either nesting order, and both
/// orders produce the same atoms: on an identifier carrying both, the
/// visibility encoding stays outermost, so containers and
/// `separatingVisibilityRegions()` read it exactly as they would without the
/// definition region, and the two separations can run in either order.
///
/// The identity belongs to the caller. It must not be empty and must not
/// contain control characters, which the encoding reserves. Two regions with
/// the same identity directly next to each other read back as one.
public struct DefinitionRegion: SemanticStringComponent {
    @usableFromInline
    let identity: String

    @usableFromInline
    let content: SemanticString

    /// Creates a region from a sync result builder.
    @inlinable
    public init(_ identity: String, @SemanticStringBuilder content: () -> SemanticString) {
        DefinitionTag.validate(identity)
        self.identity = identity
        self.content = content()
    }

    /// Creates a region from an async result builder.
    @inlinable
    public init(_ identity: String, @SemanticStringBuilder content: () async throws -> SemanticString) async rethrows {
        DefinitionTag.validate(identity)
        self.identity = identity
        self.content = try await content()
    }

    /// Creates a region around pre-built content.
    @inlinable
    public init(_ identity: String, content: SemanticString) {
        DefinitionTag.validate(identity)
        self.identity = identity
        self.content = content
    }

    /// The content's atoms, each carrying the identity. Used where a
    /// composite flattens its children directly; the content then forms one
    /// run, as any composite's does.
    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        taggedAtoms(content.components[...])
    }

    /// Appends one element per element of the content, so wrapping content
    /// in a region never merges the items a container sees.
    @inlinable
    public func _appendAsElement(into semanticString: inout SemanticString) {
        let elements = content.elements
        for index in elements.indices {
            let atoms = elements.atoms(ofElementAt: index)
            guard !atoms.isEmpty else { continue }
            semanticString.appendComponentElement(flattening: taggedAtoms(atoms))
        }
    }

    @inlinable
    func taggedAtoms(_ atoms: ArraySlice<AtomicComponent>) -> [AtomicComponent] {
        // Atoms mostly share a handful of identifiers (none, a visibility tag,
        // the tag of the region nested inside), so each distinct one is
        // re-encoded once.
        var taggedIdentifierByIdentifier: [String?: String] = [:]
        var result: [AtomicComponent] = []
        result.reserveCapacity(atoms.count)
        for atom in atoms {
            let taggedIdentifier: String
            if let cached = taggedIdentifierByIdentifier[atom.identifier] {
                taggedIdentifier = cached
            } else {
                taggedIdentifier = DefinitionTag.adding(identity, to: atom.identifier)
                taggedIdentifierByIdentifier[atom.identifier] = taggedIdentifier
            }
            result.append(AtomicComponent(string: atom.string, type: atom.type, identifier: taggedIdentifier))
        }
        return result
    }
}

// MARK: - Tag Encoding

/// The encoding of definition identities in `AtomicComponent.identifier`.
///
/// `␆<identities>␆<original identifier>`, where `<identities>` lists the
/// identities of every enclosing region, outermost first, separated by `␇`
/// (U+0006 and U+0007; an identity may not contain control characters, and
/// no real identifier starts with one).
///
/// On an identifier that carries a visibility tag, the encoding goes inside
/// the tag's original identifier — `␁<conditions>␁␆<identities>␆<original
/// identifier>` — so the visibility tag stays outermost. Containers
/// recognize a visibility tag by its first character, and
/// `separatingVisibilityRegions()` restores a tag's original identifier,
/// definition encoding included, untouched; adding a visibility tag to an
/// identifier carrying a definition encoding needs nothing from this type,
/// since `VisibilityTag.adding` already puts the existing identifier inside.
@usableFromInline
enum DefinitionTag {
    @usableFromInline
    static let tagMarker: Character = "\u{6}"

    @usableFromInline
    static let identitySeparator: Character = "\u{7}"

    @inlinable
    static func validate(_ identity: String) {
        precondition(!identity.isEmpty, "a definition region needs an identity")
        precondition(
            !identity.unicodeScalars.contains { $0.value < 0x20 },
            "a definition region identity must not contain control characters"
        )
    }

    /// Whether `identifier` carries any identity. The markers are control
    /// characters no option name, identity or real identifier contains, so
    /// finding one is enough.
    @inlinable
    static func carriesIdentities(_ identifier: String) -> Bool {
        identifier.contains(tagMarker)
    }

    /// Where the part of `identifier` that can carry identities starts:
    /// right after the visibility tag's conditions when it has one, at its
    /// start otherwise. A malformed visibility tag — no second marker — is a
    /// plain identifier to `VisibilityTag.decode`, and so it is here.
    @inlinable
    static func definitionPartStart(of identifier: String) -> String.Index {
        guard VisibilityTag.isTag(identifier) else {
            return identifier.startIndex
        }
        let conditionsStart = identifier.index(after: identifier.startIndex)
        guard let originalMarkerIndex = identifier[conditionsStart...].firstIndex(of: VisibilityTag.tagMarker) else {
            return identifier.startIndex
        }
        return identifier.index(after: originalMarkerIndex)
    }

    /// `identifier` with `identity` added as the outermost definition.
    @inlinable
    static func adding(_ identity: String, to identifier: String?) -> String {
        guard let identifier else {
            var tagged = String(tagMarker)
            tagged += identity
            tagged.append(tagMarker)
            return tagged
        }
        let partStart = definitionPartStart(of: identifier)
        let definitionPart = identifier[partStart...]
        var tagged = String(identifier[..<partStart])
        tagged.append(tagMarker)
        tagged += identity
        if definitionPart.first == tagMarker {
            tagged.append(identitySeparator)
            tagged += definitionPart.dropFirst()
        } else {
            tagged.append(tagMarker)
            tagged += definitionPart
        }
        return tagged
    }

    /// An identifier taken apart: the visibility tag's prefix (empty when
    /// it has none), the identities (outermost first, empty when it carries
    /// none), and the original identifier.
    @usableFromInline
    struct Decomposition {
        @usableFromInline
        let visibilityPrefix: Substring

        @usableFromInline
        let identities: [Substring]

        @usableFromInline
        let original: Substring

        @inlinable
        init(visibilityPrefix: Substring, identities: [Substring], original: Substring) {
            self.visibilityPrefix = visibilityPrefix
            self.identities = identities
            self.original = original
        }

        /// The identifier put back together with the identities from
        /// `firstKeptIdentityIndex` on — the outer ones dropped — or `nil`
        /// when nothing is left.
        @inlinable
        func identifier(keepingIdentitiesFrom firstKeptIdentityIndex: Int) -> String? {
            var rebuilt = String(visibilityPrefix)
            let keptIdentities = identities[firstKeptIdentityIndex...]
            if let firstKeptIdentity = keptIdentities.first {
                rebuilt.append(DefinitionTag.tagMarker)
                rebuilt += firstKeptIdentity
                for identity in keptIdentities.dropFirst() {
                    rebuilt.append(DefinitionTag.identitySeparator)
                    rebuilt += identity
                }
                rebuilt.append(DefinitionTag.tagMarker)
            }
            rebuilt += original
            return rebuilt.isEmpty ? nil : rebuilt
        }
    }

    @inlinable
    static func decompose(_ identifier: String) -> Decomposition {
        let partStart = definitionPartStart(of: identifier)
        let definitionPart = identifier[partStart...]
        guard definitionPart.first == tagMarker,
              let originalMarkerIndex = definitionPart.dropFirst().firstIndex(of: tagMarker)
        else {
            return Decomposition(visibilityPrefix: identifier[..<partStart], identities: [], original: definitionPart)
        }
        let identitiesPart = definitionPart[definitionPart.index(after: definitionPart.startIndex) ..< originalMarkerIndex]
        return Decomposition(
            visibilityPrefix: identifier[..<partStart],
            identities: identitiesPart.split(separator: identitySeparator, omittingEmptySubsequences: false),
            original: definitionPart[definitionPart.index(after: originalMarkerIndex)...]
        )
    }
}
