// MARK: - Visibility Region

/// Content that is visible only under a `VisibilityCondition`.
///
/// A region changes nothing about the text: the content renders exactly as
/// it would unwrapped, atom for atom, and it keeps its element structure —
/// appended into a container, a region holding three items contributes three
/// items. What it adds is the condition, recorded on each atom's
/// `identifier`; `FrozenSemanticString.separatingVisibilityRegions()` later
/// reads it back into a `VisibilityRegionTable`, which projects the text to
/// any option values. Regions nest, and an atom inside several is visible
/// when all of their conditions hold.
///
/// The atoms' own identifiers are carried inside that encoding and restored
/// by the separation, so separating a string printed with regions gives
/// back exactly the string printed without them. Until then the atoms'
/// `identifier` holds the encoding — a string printed with regions is meant
/// to be frozen and separated, not rendered or linked as is. An empty
/// identifier comes back as `nil`.
///
/// A region always around its content changes nothing and records nothing,
/// so `VisibilityRegion(.always) { … }` is the content itself.
///
/// Wrap the optional content itself, not the container around it: a
/// container whose item sits entirely in a region gives the line break,
/// indentation or separator it prints for that item the same condition, and
/// its prefix, suffix and trailing line break the condition that some item
/// is visible (see `VisibilityLayout`), so the projection removes exactly
/// what printing without the item would not have printed. Two things fall
/// outside that: `ForEachIndexed`, whose content lays itself out from
/// `isFirst` / `isLast`, and a `DeclarationBlock` body whose last visible
/// byte changes with the options — it decides its closing line break from
/// the body as printed in full.
public struct VisibilityRegion: SemanticStringComponent {
    @usableFromInline
    let condition: VisibilityCondition

    @usableFromInline
    let content: SemanticString

    /// Creates a region from a sync result builder.
    @inlinable
    public init(_ condition: VisibilityCondition, @SemanticStringBuilder content: () -> SemanticString) {
        self.condition = condition
        self.content = content()
    }

    /// Creates a region from an async result builder.
    @inlinable
    public init(_ condition: VisibilityCondition, @SemanticStringBuilder content: () async throws -> SemanticString) async rethrows {
        self.condition = condition
        self.content = try await content()
    }

    /// Creates a region around pre-built content.
    @inlinable
    public init(_ condition: VisibilityCondition, content: SemanticString) {
        self.condition = condition
        self.content = content
    }

    /// The content's atoms, each carrying the condition. Used where a
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
        guard !condition.isAlways else {
            return Array(atoms)
        }
        let encodedCondition = VisibilityTag.encode(condition)
        // Atoms mostly share a handful of identifiers (none, or the tag of
        // the region nested inside), so each distinct one is re-encoded once.
        var taggedIdentifierByIdentifier: [String?: String] = [:]
        var result: [AtomicComponent] = []
        result.reserveCapacity(atoms.count)
        for atom in atoms {
            let taggedIdentifier: String
            if let cached = taggedIdentifierByIdentifier[atom.identifier] {
                taggedIdentifier = cached
            } else {
                taggedIdentifier = VisibilityTag.adding(encodedCondition, to: atom.identifier)
                taggedIdentifierByIdentifier[atom.identifier] = taggedIdentifier
            }
            result.append(AtomicComponent(string: atom.string, type: atom.type, identifier: taggedIdentifier))
        }
        return result
    }
}

// MARK: - Tag Encoding

/// The encoding of region conditions in `AtomicComponent.identifier`.
///
/// `␁<conditions>␁<original identifier>`, where `<conditions>` lists the
/// conditions of every enclosing region, outermost first, separated by `␂`;
/// a condition lists its alternatives separated by `␃`, an alternative its
/// requirements separated by `␄`, and a requirement is `+` or `-` followed by
/// the option name. `never` is `␅`. (`␁`–`␅` are U+0001–U+0005, which an
/// option name may not contain and no real identifier starts with.)
@usableFromInline
enum VisibilityTag {
    @usableFromInline
    static let tagMarker: Character = "\u{1}"

    @usableFromInline
    static let conditionSeparator: Character = "\u{2}"

    @usableFromInline
    static let alternativeSeparator: Character = "\u{3}"

    @usableFromInline
    static let requirementSeparator: Character = "\u{4}"

    @usableFromInline
    static let neverMarker = "\u{5}"

    @inlinable
    static func isTag(_ identifier: String) -> Bool {
        identifier.first == tagMarker
    }

    @inlinable
    static func encode(_ condition: VisibilityCondition) -> String {
        guard !condition.isNever else {
            return neverMarker
        }
        var encoded = ""
        for (alternativeIndex, alternative) in condition.alternatives.enumerated() {
            if alternativeIndex > 0 {
                encoded.append(alternativeSeparator)
            }
            for (requirementIndex, requirement) in alternative.enumerated() {
                if requirementIndex > 0 {
                    encoded.append(requirementSeparator)
                }
                encoded += requirement.isEnabled ? "+" : "-"
                encoded += requirement.option
            }
        }
        return encoded
    }

    /// `identifier` with `encodedCondition` added as the outermost region.
    @inlinable
    static func adding(_ encodedCondition: String, to identifier: String?) -> String {
        if let identifier, isTag(identifier) {
            var tagged = String(tagMarker)
            tagged += encodedCondition
            tagged.append(conditionSeparator)
            tagged += identifier.dropFirst()
            return tagged
        }
        var tagged = String(tagMarker)
        tagged += encodedCondition
        tagged.append(tagMarker)
        tagged += identifier ?? ""
        return tagged
    }

    /// The conditions and the original identifier of a tag, or `nil` when
    /// `identifier` is not one.
    @inlinable
    static func decode(_ identifier: String) -> (conditions: [VisibilityCondition], originalIdentifier: String?)? {
        guard isTag(identifier) else { return nil }
        let body = identifier.dropFirst()
        guard let originalMarkerIndex = body.firstIndex(of: tagMarker) else { return nil }
        let originalIdentifier = String(body[body.index(after: originalMarkerIndex)...])
        let conditions = body[..<originalMarkerIndex]
            .split(separator: conditionSeparator, omittingEmptySubsequences: false)
            .map(decodeCondition)
        return (conditions, originalIdentifier.isEmpty ? nil : originalIdentifier)
    }

    @inlinable
    static func decodeCondition(_ encoded: Substring) -> VisibilityCondition {
        guard encoded != neverMarker else {
            return .never
        }
        let alternatives = encoded
            .split(separator: alternativeSeparator, omittingEmptySubsequences: false)
            .map { alternative -> [VisibilityCondition.Requirement] in
                alternative
                    .split(separator: requirementSeparator)
                    .map { requirement in
                        VisibilityCondition.Requirement(option: String(requirement.dropFirst()), isEnabled: requirement.first == "+")
                    }
            }
        return VisibilityCondition(alternatives: alternatives)
    }
}

// MARK: - Streaming

extension SemanticString {
    /// Marks every atom from `startIndex` on as visible only under
    /// `condition` — what wrapping them in a `VisibilityRegion` would have
    /// done, for text written piece by piece through `write(_:)` or
    /// `append(_:type:)` rather than built from components.
    ///
    /// Record `count` before writing, write, then mark from it. Nothing about
    /// the atoms but their identifiers changes: text, types, count and element
    /// boundaries stay as they are, and each atom's own identifier — an
    /// identifier scope's stamp included — is kept inside the mark, exactly as
    /// inside a region. `.always` marks nothing.
    @inlinable
    public mutating func markAtoms(from startIndex: Int, visibleUnder condition: VisibilityCondition) {
        precondition(startIndex >= 0 && startIndex <= count, "the start of the atoms to mark is out of range")
        guard startIndex < count, !condition.isAlways else { return }
        makeUniqueForMutation()
        let encodedCondition = VisibilityTag.encode(condition)
        for index in startIndex ..< _storage.atoms.count {
            let atom = _storage.atoms[index]
            _storage.atoms[index] = AtomicComponent(
                string: atom.string,
                type: atom.type,
                identifier: VisibilityTag.adding(encodedCondition, to: atom.identifier)
            )
        }
    }
}
