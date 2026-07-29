/// Element-boundary view of a `SemanticString`'s contents.
///
/// Element granularity is semantic: containers like `MemberList` treat one
/// element as one row. In the tree state each element may be a whole composite;
/// in the flat state every atom is its own element, matching what the
/// pre-two-state storage kept for streamed or decoded strings.
///
/// The view exists so that reading elements out of a *flat* string costs
/// nothing. Materializing them as `[any SemanticStringComponent]` would box
/// every atom — a 40-byte existential container plus a 64-byte heap box each —
/// which is exactly the cost the flat representation was introduced to remove,
/// paid back in full at every container's prebuilt-`content:` initializer.
/// Consumers walk `indices` and use `appendComponents(ofElementAt:into:)`,
/// which reads the typed array directly.
@usableFromInline
struct SemanticStringElements: Sendable {
    @usableFromInline
    enum Representation: Sendable {
        /// Every atom is its own element. By the flat form's invariant no atom
        /// is zero-length, so each element flattens to exactly itself.
        case flat([AtomicComponent])
        case tree([any SemanticStringComponent])
    }

    @usableFromInline
    var representation: Representation

    @inlinable
    init(flat components: [AtomicComponent]) {
        self.representation = .flat(components)
    }

    @inlinable
    init(tree elements: [any SemanticStringComponent]) {
        self.representation = .tree(elements)
    }

    /// Creates a tree-form view from components supplied by a caller.
    @inlinable
    init(_ elements: [any SemanticStringComponent]) {
        self.representation = .tree(elements)
    }

    /// Creates a tree-form view from a homogeneous array.
    @inlinable
    init(_ elements: [some SemanticStringComponent]) {
        self.representation = .tree(elements.map { $0 as any SemanticStringComponent })
    }

    @inlinable
    init() {
        self.representation = .flat([])
    }

    @inlinable
    var count: Int {
        switch representation {
        case .flat(let components): return components.count
        case .tree(let elements): return elements.count
        }
    }

    @inlinable
    var isEmpty: Bool { count == 0 }

    @inlinable
    var indices: Range<Int> { 0 ..< count }

    /// Appends the flattening of element `index` to `result`.
    ///
    /// The flat case appends the stored atom directly — no existential, no
    /// intermediate array.
    @inlinable
    func appendComponents(ofElementAt index: Int, into result: inout [AtomicComponent]) {
        switch representation {
        case .flat(let components):
            result.append(components[index])
        case .tree(let elements):
            result.append(contentsOf: elements[index].buildComponents())
        }
    }

    /// Appends the flattening of every element to `result`.
    @inlinable
    func appendAllComponents(into result: inout [AtomicComponent]) {
        switch representation {
        case .flat(let components):
            result.append(contentsOf: components)
        case .tree(let elements):
            for element in elements {
                result.append(contentsOf: element.buildComponents())
            }
        }
    }

    /// Whether element `index` flattens to no components.
    ///
    /// `O(1)` in the flat state: the flat form holds no zero-length atoms, so
    /// no flat element can flatten to nothing.
    @inlinable
    func isElementEmpty(at index: Int) -> Bool {
        switch representation {
        case .flat: return false
        case .tree(let elements): return elements[index].buildComponents().isEmpty
        }
    }

    /// Whether every element flattens to nothing.
    ///
    /// Stops at the first element that produces output instead of flattening
    /// the whole tree, and never publishes anything into a cache.
    @inlinable
    func flattensToNothing() -> Bool {
        switch representation {
        case .flat(let components):
            return components.isEmpty
        case .tree(let elements):
            for element in elements where !element.buildComponents().isEmpty {
                return false
            }
            return true
        }
    }

    /// The flattening of element `index`.
    ///
    /// Allocates; prefer `appendComponents(ofElementAt:into:)` when the result
    /// is going straight into a larger array.
    @inlinable
    func components(ofElementAt index: Int) -> [AtomicComponent] {
        switch representation {
        case .flat(let components): return [components[index]]
        case .tree(let elements): return elements[index].buildComponents()
        }
    }

    /// The elements as boxed existentials.
    ///
    /// Only for callers that genuinely need an `[any SemanticStringComponent]`.
    /// This is the allocation the view exists to avoid — do not call it on a
    /// path that just wants to flatten.
    @inlinable
    func boxed() -> [any SemanticStringComponent] {
        switch representation {
        case .flat(let components): return components.map { $0 as any SemanticStringComponent }
        case .tree(let elements): return elements
        }
    }
}
