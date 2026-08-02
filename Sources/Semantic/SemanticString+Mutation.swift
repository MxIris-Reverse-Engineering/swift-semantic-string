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
    /// An empty atom is a complete no-op — no atom, no element slot, and
    /// crucially no `makeUniqueForMutation()`: the rendered text does not
    /// change, so the string cache stays warm and a `nil` (1:1) boundary
    /// table stays `nil` instead of being materialized for a zero-length
    /// slot. Element slots are container-layout bookkeeping that every
    /// consumer skips (`guard !itemComponents.isEmpty`), so dropping the
    /// slot is unobservable; sixth round — previously this recorded the
    /// slot, which cost a full table materialization and a cache drop per
    /// zero-width append.
    @usableFromInline
    internal mutating func appendAtomElement(_ atomicComponent: AtomicComponent) {
        if atomicComponent.string.isEmpty {
            return
        }
        makeUniqueForMutation()
        _storage.atoms.append(atomicComponent)
        _storage.closeElement(appendedAtomCount: 1)
    }

    /// Appends the flattening of one component as one element.
    ///
    /// Zero-length atoms in the flattening are dropped; a flattening that
    /// drops to nothing is a complete no-op (see `appendAtomElement`).
    @usableFromInline
    internal mutating func appendComponentElement(flattening builtComponents: [AtomicComponent]) {
        guard builtComponents.contains(where: { !$0.string.isEmpty }) else {
            return
        }
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
    /// have produced exactly this — a promise the compiler cannot check, so
    /// debug builds assert it: a conformance that overrides
    /// `buildComponents()` fails loudly here instead of silently rendering
    /// different content per construction path.
    @inlinable
    public mutating func append(_ component: some PlainAtomicSemanticComponent) {
        assert(
            Self.upholdsPlainAtomicPromise(component),
            "\(type(of: component)) conforms to PlainAtomicSemanticComponent but overrides buildComponents(); the fast path would ignore the override. Conform to AtomicSemanticComponent only."
        )
        appendAtomElement(AtomicComponent(string: component.string, type: component.type))
    }

    /// Debug-only check backing the assertion above. `true` when the leaf's
    /// `buildComponents()` produces exactly what the fast path stores.
    @usableFromInline
    internal static func upholdsPlainAtomicPromise(_ component: some PlainAtomicSemanticComponent) -> Bool {
        let built = component.buildComponents()
        if component.string.isEmpty {
            return built.isEmpty
        }
        return built == [AtomicComponent(string: component.string, type: component.type)]
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
    /// empty composite) is a complete no-op: no atoms, no element slot, no
    /// cache drop — containers skip empty elements anyway, so the slot was
    /// never observable (sixth round).
    @inlinable
    public mutating func append(_ component: some SemanticStringComponent) {
        if let atomicComponent = component as? AtomicComponent {
            appendAtomElement(atomicComponent)
            return
        }
        // A `SemanticString` reached as a component — every builder child is
        // one — is one element, like any other component here. Its atoms
        // already uphold the "no zero-length components" invariant, so they
        // are appended in bulk instead of through the per-atom filter loop.
        if let semanticString = component as? SemanticString {
            appendSemanticStringElement(semanticString)
            return
        }
        // No plain-leaf existential fast path here, deliberately: measured, a
        // protocol-conformance cast per component costs more than the
        // one-element array `buildComponents()` allocates. Statically typed
        // appends already skip both.
        appendComponentElement(flattening: component.buildComponents())
    }

    /// Appends another string's contents as **one element**, in bulk.
    ///
    /// This is the existential-append counterpart of
    /// `append(_ semanticString:)` below, which preserves the argument's own
    /// element boundaries instead. Sound without filtering because storage
    /// never holds zero-length atoms.
    @usableFromInline
    internal mutating func appendSemanticStringElement(_ semanticString: SemanticString) {
        let appendedAtoms = semanticString._storage.atoms
        if appendedAtoms.isEmpty {
            return
        }
        makeUniqueForMutation()
        _storage.atoms.append(contentsOf: appendedAtoms)
        _storage.closeElement(appendedAtomCount: appendedAtoms.count)
    }

    /// Concatenates another string's contents, element boundaries included.
    /// Appending a string that renders nothing is a complete no-op, whatever
    /// zero-length element slots it may carry (see `appendAtomElement`).
    @inlinable
    public mutating func append(_ semanticString: SemanticString) {
        if semanticString._storage.atoms.isEmpty {
            return
        }
        makeUniqueForMutation()
        _storage.appendContents(of: semanticString._storage)
    }
}
