/// Element-boundary view of semantic string content.
///
/// Element granularity is semantic: containers like `MemberList` treat one
/// element as one row. Storage keeps every atom in one flat array with an
/// explicit boundary table, so an element's components are always a
/// contiguous run — this view hands them out as `ArraySlice`s, which cost
/// nothing to produce and nothing to consume.
///
/// The view has two cases because containers are built from two shapes of
/// input: the elements of a single string (`content:` initializers, builder
/// results) and an array of independent strings (`_ items: [SemanticString]`
/// initializers), where each string is one element. Neither case copies or
/// boxes anything at construction time.
@usableFromInline
struct SemanticStringElements: Sendable {
    @usableFromInline
    enum Representation: Sendable {
        /// One string's contents: a flat atom array plus its boundary table
        /// (`nil` = every atom is its own element).
        case contents(atoms: [AtomicComponent], elementEndOffsets: [Int]?)

        /// Independent strings, each one element.
        case strings([SemanticString])
    }

    @usableFromInline
    var representation: Representation

    @inlinable
    init(atoms: [AtomicComponent], elementEndOffsets: [Int]?) {
        self.representation = .contents(atoms: atoms, elementEndOffsets: elementEndOffsets)
    }

    /// Creates a view over independent strings, each one element.
    @inlinable
    init(_ items: [SemanticString]) {
        self.representation = .strings(items)
    }

    /// Creates a view over arbitrary components, each one element, by
    /// flattening them eagerly into one contents run.
    @inlinable
    init(_ items: [some SemanticStringComponent]) {
        var atoms: [AtomicComponent] = []
        var elementEndOffsets: [Int] = []
        elementEndOffsets.reserveCapacity(items.count)
        // `atoms` receives every atom of every item, so leaving it unreserved
        // grew it through ~18 geometric reallocations for a 10k-row container
        // while the boundary table beside it was reserved. One atom per item
        // is the floor (an item flattening to nothing contributes none), which
        // is enough to skip the early doubling rounds.
        atoms.reserveCapacity(items.count)
        for item in items {
            for atom in item.buildComponents() where !atom.string.isEmpty {
                atoms.append(atom)
            }
            elementEndOffsets.append(atoms.count)
        }
        self.representation = .contents(atoms: atoms, elementEndOffsets: elementEndOffsets)
    }

    @inlinable
    init() {
        self.representation = .contents(atoms: [], elementEndOffsets: nil)
    }

    @inlinable
    var count: Int {
        switch representation {
        case .contents(let atoms, let elementEndOffsets):
            return elementEndOffsets?.count ?? atoms.count
        case .strings(let items):
            return items.count
        }
    }

    @inlinable
    var isEmpty: Bool { count == 0 }

    @inlinable
    var indices: Range<Int> { 0 ..< count }

    /// The components of element `index`, as a zero-copy slice of the
    /// underlying flat array. Empty exactly when the element flattens to
    /// nothing.
    ///
    /// The slice's indices are **not zero-based**: a `.contents` slice keeps
    /// the element's absolute offsets into the flat array, while a `.strings`
    /// slice starts at 0 — so `slice[0]` works for one representation and
    /// traps for the other. Consume the slice only through its own
    /// properties (`isEmpty`, `first`, `last`, iteration,
    /// `append(contentsOf:)`), never through literal positions. `index` must
    /// come from `indices`; out-of-range values trap on the slicing itself.
    @inlinable
    func atoms(ofElementAt index: Int) -> ArraySlice<AtomicComponent> {
        switch representation {
        case .contents(let atoms, let elementEndOffsets):
            guard let elementEndOffsets else {
                return atoms[index ... index]
            }
            let start = index == 0 ? 0 : elementEndOffsets[index - 1]
            return atoms[start ..< elementEndOffsets[index]]
        case .strings(let items):
            let itemAtoms = items[index]._storage.atoms
            return itemAtoms[itemAtoms.startIndex...]
        }
    }

    /// Appends the flattening of every element to `result`.
    @inlinable
    func appendAllComponents(into result: inout [AtomicComponent]) {
        switch representation {
        case .contents(let atoms, _):
            result.append(contentsOf: atoms)
        case .strings(let items):
            for item in items {
                result.append(contentsOf: item._storage.atoms)
            }
        }
    }

    /// The total number of components across all elements.
    @inlinable
    var totalComponentCount: Int {
        switch representation {
        case .contents(let atoms, _):
            return atoms.count
        case .strings(let items):
            var total = 0
            for item in items {
                total += item._storage.atoms.count
            }
            return total
        }
    }
}
