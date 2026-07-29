// MARK: - Identifier Scopes

extension SemanticString {
    /// Pushes an identifier scope. While the innermost scope is non-nil,
    /// every string appended via `append(_:type:)` / `write(_:type:)` is
    /// stamped with that identifier. Push `nil` to open a barrier scope that
    /// suppresses stamping (e.g. punctuation between independent spans).
    ///
    /// Component appends (`append(Keyword(...))`, `append(component)`, `+=`)
    /// never stamp: a component that wants an identifier carries its own via
    /// `AtomicComponent(string:type:identifier:)`.
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
    /// Appends one atom as one element.
    ///
    /// An empty atom contributes nothing to `atoms` (upholding the "no
    /// zero-length components" invariant) but still records a zero-length
    /// element, exactly as the historical element tree kept a slot for it.
    @usableFromInline
    internal mutating func appendAtomElement(_ atomicComponent: AtomicComponent) {
        makeUniqueForMutation()
        if atomicComponent.string.isEmpty {
            _storage.closeElement(appendedAtomCount: 0)
        } else {
            _storage.atoms.append(atomicComponent)
            _storage.closeElement(appendedAtomCount: 1)
        }
    }

    /// Appends the flattening of one component as one element.
    ///
    /// Zero-length atoms in the flattening are dropped; a flattening that
    /// drops to nothing records a zero-length element.
    @usableFromInline
    internal mutating func appendComponentElement(flattening builtComponents: [AtomicComponent]) {
        makeUniqueForMutation()
        var appendedAtomCount = 0
        for atomicComponent in builtComponents where !atomicComponent.string.isEmpty {
            _storage.atoms.append(atomicComponent)
            appendedAtomCount += 1
        }
        _storage.closeElement(appendedAtomCount: appendedAtomCount)
    }

    /// Appends a string as one element, stamped with the innermost
    /// identifier scope. Appending an empty string is a no-op — no atom
    /// *and no element* — matching the historical behavior of this one
    /// entry point.
    @inlinable
    public mutating func append(_ string: String, type: SemanticType) {
        if !string.isEmpty {
            appendAtomElement(AtomicComponent(string: string, type: type, identifier: identifierScopeStack.last ?? nil))
        }
    }

    /// Exact-match overload for the erased leaf type, which carries an
    /// `identifier` that a rebuilt `AtomicComponent(string:type:)` would drop.
    @inlinable
    public mutating func append(_ component: AtomicComponent) {
        appendAtomElement(component)
    }

    /// Zero-allocation path for leaves that promise the inherited
    /// `buildComponents()` — `Keyword`, `Space`, `BreakLine`, `Indent`,
    /// `TypeName`, and every other `PlainAtomicSemanticComponent`.
    ///
    /// Overload resolution picks this statically, so streaming them costs no
    /// dynamic cast and no intermediate array. Reading `string` and `type`
    /// directly is sound *only* because conformance to
    /// `PlainAtomicSemanticComponent` states that `buildComponents()` would
    /// have produced exactly this.
    @inlinable
    public mutating func append(_ component: some PlainAtomicSemanticComponent) {
        appendAtomElement(AtomicComponent(string: component.string, type: component.type))
    }

    /// Leaves that customize `buildComponents()`, and leaves reached through
    /// an existential or an unspecialized generic. Goes through
    /// `buildComponents()` so that an override is honoured — and however many
    /// atoms the override produces, they stay **one element**.
    @inlinable
    public mutating func append(_ component: some AtomicSemanticComponent) {
        appendComponentElement(flattening: component.buildComponents())
    }

    /// Appends any component as one element, flattening it eagerly.
    ///
    /// One appended component is one element no matter what it flattens to —
    /// `MemberList`-style containers render it as one row. A component that
    /// flattens to nothing (an appended `nil` optional, `EmptyComponent`, an
    /// empty composite) records a zero-length element: no atoms, no text, no
    /// representation change, but it still counts against `isEmpty`, exactly
    /// as it occupied an element slot in the historical element tree.
    @inlinable
    public mutating func append(_ component: some SemanticStringComponent) {
        if let atomicComponent = component as? AtomicComponent {
            appendAtomElement(atomicComponent)
            return
        }
        appendComponentElement(flattening: component.buildComponents())
    }

    /// Concatenates another string's contents, element boundaries included.
    @inlinable
    public mutating func append(_ semanticString: SemanticString) {
        makeUniqueForMutation()
        _storage.appendContents(of: semanticString._storage)
    }
}
