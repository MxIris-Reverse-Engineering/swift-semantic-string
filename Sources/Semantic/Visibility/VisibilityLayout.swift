// MARK: - Visibility Layout

/// How the library's containers pass the conditions of their items on to
/// the decorations they print around them.
///
/// A container decorates its items: `MemberList` puts a line break and the
/// indentation in front of each, `Rows` and `Joined` a separator between two,
/// `Joined` a prefix and a suffix around them all, `MemberList` and
/// `BlockList` a line break after the last. Printed without the hidden items,
/// those decorations would change too. So when an item is visible only under
/// a condition — every atom of it sits in a `VisibilityRegion` — the
/// decoration that belongs to it carries the same condition, and one that
/// belongs to the whole container carries the condition that some item is
/// visible. A projection then removes exactly what the container would not
/// have printed, with no knowledge of how the container lays things out.
///
/// Conditions are optional here, `nil` standing for "always": an item with
/// any unconditional atom is always visible, and that is the path content
/// printed without regions takes — one look at the first atom, no
/// allocation.
@usableFromInline
enum VisibilityLayout {
    /// The condition `atoms` are visible under as an item: that some part of
    /// them is visible. `nil` when some atom carries no condition.
    @inlinable
    static func condition(ofItem atoms: ArraySlice<AtomicComponent>) -> VisibilityCondition? {
        guard let firstIdentifier = atoms.first?.identifier, VisibilityTag.isTag(firstIdentifier) else {
            return nil
        }
        var seenIdentifiers: Set<String> = []
        var alternatives: [VisibilityCondition] = []
        for atom in atoms {
            guard let identifier = atom.identifier, VisibilityTag.isTag(identifier) else {
                return nil
            }
            guard seenIdentifiers.insert(identifier).inserted else { continue }
            guard let decoded = VisibilityTag.decode(identifier) else {
                return nil
            }
            alternatives.append(.all(decoded.conditions))
        }
        let combined = VisibilityCondition.any(alternatives)
        return combined.isAlways ? nil : combined
    }

    @inlinable
    static func condition(ofItem atoms: [AtomicComponent]) -> VisibilityCondition? {
        condition(ofItem: atoms[...])
    }

    /// Visible when either is; `nil` is always.
    @inlinable
    static func either(_ lhs: VisibilityCondition?, _ rhs: VisibilityCondition?) -> VisibilityCondition? {
        guard let lhs, let rhs else { return nil }
        let combined = VisibilityCondition.any([lhs, rhs])
        return combined.isAlways ? nil : combined
    }

    /// Visible when both are; `nil` is always.
    @inlinable
    static func both(_ lhs: VisibilityCondition?, _ rhs: VisibilityCondition?) -> VisibilityCondition? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        let combined = VisibilityCondition.all([lhs, rhs])
        return combined.isAlways ? nil : combined
    }

    /// `atom`, visible only under `condition`.
    @inlinable
    static func decoration(_ atom: AtomicComponent, visibleUnder condition: VisibilityCondition?) -> AtomicComponent {
        guard let condition else { return atom }
        return AtomicComponent(
            string: atom.string,
            type: atom.type,
            identifier: VisibilityTag.adding(VisibilityTag.encode(condition), to: atom.identifier)
        )
    }

    /// `atoms`, each visible only under `condition`.
    @inlinable
    static func decorations(_ atoms: [AtomicComponent], visibleUnder condition: VisibilityCondition?) -> [AtomicComponent] {
        guard let condition else { return atoms }
        let encodedCondition = VisibilityTag.encode(condition)
        return atoms.map { atom in
            AtomicComponent(string: atom.string, type: atom.type, identifier: VisibilityTag.adding(encodedCondition, to: atom.identifier))
        }
    }
}
