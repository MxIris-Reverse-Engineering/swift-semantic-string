// MARK: - Identifier Scopes

extension SemanticString {
    /// Pushes an identifier scope. While the innermost scope is non-nil,
    /// every string appended via `append(_:type:)` / `write(_:type:)` is
    /// stamped with that identifier. Push `nil` to open a barrier scope that
    /// suppresses stamping (e.g. punctuation between independent spans).
    @inlinable
    public mutating func pushIdentifierScope(_ identifier: String?) {
        identifierScopeStack.append(identifier)
    }

    /// Pops the innermost identifier scope. Unbalanced pops are ignored.
    @inlinable
    public mutating func popIdentifierScope() {
        if !identifierScopeStack.isEmpty {
            identifierScopeStack.removeLast()
        }
    }
}

// MARK: - Appending (Mutating)

extension SemanticString {
    /// Appends a single atomic component, staying in the flat representation
    /// when possible. Shared implementation for the stamping and
    /// non-stamping public entry points.
    @usableFromInline
    internal mutating func appendAtomicComponent(_ atomicComponent: AtomicComponent) {
        // Upholds the flat form's "no zero-length components" invariant, and
        // matches what tree flattening does with the same component.
        if atomicComponent.string.isEmpty {
            return
        }
        makeUniqueForMutation()
        if _storage.isFlat {
            _storage.flatComponents.append(atomicComponent)
        } else {
            _storage.treeElements.append(atomicComponent)
        }
    }

    /// Appends the flattening of a leaf component.
    ///
    /// Used by the paths that must honour a custom `buildComponents()`, so the
    /// input can be any length — including zero, for a leaf whose `string` is
    /// empty.
    @usableFromInline
    internal mutating func appendAtomicComponents(_ atomicComponents: [AtomicComponent]) {
        let filtered = Self.droppingZeroLengthComponents(atomicComponents)
        if filtered.isEmpty {
            return
        }
        makeUniqueForMutation()
        if _storage.isFlat {
            _storage.flatComponents.append(contentsOf: filtered)
        } else {
            _storage.treeElements.append(contentsOf: filtered.map { $0 as any SemanticStringComponent })
        }
    }

    @inlinable
    public mutating func append(_ string: String, type: SemanticType) {
        if !string.isEmpty {
            appendAtomicComponent(AtomicComponent(string: string, type: type, identifier: identifierScopeStack.last ?? nil))
        }
    }

    /// Exact-match overload for the erased leaf type, which carries an
    /// `identifier` that a rebuilt `AtomicComponent(string:type:)` would drop.
    @inlinable
    public mutating func append(_ component: AtomicComponent) {
        appendAtomicComponent(component)
    }

    /// Flat fast path for leaves that promise the inherited
    /// `buildComponents()` — `Keyword`, `Space`, `BreakLine`, `Indent`,
    /// `TypeName`, and every other `PlainAtomicSemanticComponent`.
    ///
    /// Overload resolution picks this statically, so streaming them costs no
    /// dynamic cast, no intermediate array, and — unlike the composite
    /// overload — never re-boxes the atoms accumulated so far into tree
    /// elements. Reading `string` and `type` directly is sound *only* because
    /// conformance to `PlainAtomicSemanticComponent` states that
    /// `buildComponents()` would have produced exactly this.
    @inlinable
    public mutating func append(_ component: some PlainAtomicSemanticComponent) {
        appendAtomicComponent(AtomicComponent(string: component.string, type: component.type))
    }

    /// Leaves that customize `buildComponents()`, and leaves reached through
    /// an existential or an unspecialized generic.
    ///
    /// Goes through `buildComponents()` so that an override is honoured and
    /// `AtomicComponent.identifier` survives. Costs one small array per call
    /// against the plain-leaf overload above; correctness is not negotiable
    /// here, and this is not the streaming hot path.
    @inlinable
    public mutating func append(_ component: some AtomicSemanticComponent) {
        appendAtomicComponents(component.buildComponents())
    }

    @inlinable
    public mutating func append(_ component: some SemanticStringComponent) {
        // Composites force the tree form because their element boundary is
        // semantic (one element may become one row in `MemberList`-style
        // containers). Leaves that reach this overload through an existential
        // — from `appending(_:)`, `+=`, or a caller holding
        // `any SemanticStringComponent` — still take the flat path, via
        // `buildComponents()` so that overrides and identifiers survive.
        if let atomicComponent = component as? AtomicComponent {
            appendAtomicComponent(atomicComponent)
            return
        }
        if let leaf = component as? any AtomicSemanticComponent {
            appendAtomicComponents(leaf.buildComponents())
            return
        }
        makeUniqueForMutation()
        _storage.convertToTree()
        _storage.treeElements.append(component)
    }

    @inlinable
    public mutating func append(_ semanticString: SemanticString) {
        makeUniqueForMutation()
        let otherStorage = semanticString._storage
        if _storage.isFlat {
            if otherStorage.isFlat {
                _storage.flatComponents.append(contentsOf: otherStorage.flatComponents)
            } else {
                _storage.convertToTree()
                _storage.treeElements.append(contentsOf: otherStorage.treeElements)
            }
        } else {
            if otherStorage.isFlat {
                // Splice per atom — identical to the pre-two-state behavior,
                // where a decoded/streamed string held each atom as its own
                // boxed element.
                _storage.treeElements.append(contentsOf: otherStorage.flatComponents.map { $0 as any SemanticStringComponent })
            } else {
                _storage.treeElements.append(contentsOf: otherStorage.treeElements)
            }
        }
    }
}

// MARK: - Compaction

extension SemanticString {
    /// Collapses the construction-time element tree into the flat typed
    /// representation, releasing every composite component and existential
    /// box the tree held.
    ///
    /// Call this when a string is **finalized** — fully built, about to be
    /// stored, rendered, or encoded — and will never again be consumed
    /// through its element boundaries (e.g. passed as prebuilt `content:` to
    /// a `MemberList`-style container, where one element means one row).
    /// After compaction the element view exposes one element per atomic
    /// component, which is also exactly what flattening produces, so
    /// `components`, `string`, equality, hashing, and `Codable` output are
    /// unchanged.
    ///
    /// Copies of this value made **before** compaction keep their own tree
    /// (copy-on-write); compacting one value never mutates another, and the
    /// flattening is never published into a cache the two might share.
    ///
    /// No-op when the storage is already flat.
    ///
    /// Internal on purpose. Compaction changes what one element means — from
    /// one row to one token — and nothing in the type system stops a compacted
    /// value from later being handed to a `MemberList`-style container as
    /// prebuilt `content:`, where it silently renders one row per token.
    /// `frozen()` gives callers the same memory win with that lifecycle
    /// enforced by the type instead of by convention.
    @usableFromInline
    internal mutating func compact() {
        if _storage.isFlat {
            return
        }
        // Flatten *before* taking unique ownership, but without publishing:
        // going through `components` would leave the flattened array in the
        // cache of every other value sharing this storage — a value that never
        // asked for it ends up holding a full `[AtomicComponent]`, the
        // opposite of what a memory-reducing API should do.
        let flattened = componentsWithoutPublishing()
        makeUniqueForMutation()
        _storage.flatComponents = flattened
        _storage.treeElements = []
        _storage.isFlat = true
    }

    /// Returns a copy of this string with its storage compacted.
    /// See `compact()`.
    @usableFromInline
    internal func compacted() -> SemanticString {
        var copy = self
        copy.compact()
        return copy
    }
}
