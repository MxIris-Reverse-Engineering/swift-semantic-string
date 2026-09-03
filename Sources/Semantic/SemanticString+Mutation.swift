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
    ///
    /// A flattening with no zero-length atoms — every library composite's,
    /// and any well-behaved third-party one's — is appended in bulk, and
    /// when this value holds no atoms yet the array is **adopted** outright
    /// instead of copied: `SemanticString(composite)`, `asSemanticString()`,
    /// and `joined(separator:)` then pay one flattening and no second copy
    /// (measured 0.32 ms → 0.19 ms for a 10k-atom `Group`). The adopted
    /// buffer may still be shared with the composite — `ForEach` and `IfLet`
    /// retain their flattening — and the array's own copy-on-write isolates
    /// the next mutation, which is the copy that used to be unconditional.
    /// Emptiness is judged on `atoms` alone: a value carrying only
    /// zero-length element slots adopts too, and `closeElement` extends its
    /// existing table exactly as the filtering loop would.
    @usableFromInline
    internal mutating func appendComponentElement(flattening builtComponents: [AtomicComponent]) {
        if builtComponents.isEmpty {
            return
        }
        if builtComponents.contains(where: { $0.string.isEmpty }) {
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
            return
        }
        makeUniqueForMutation()
        if _storage.atoms.isEmpty {
            _storage.atoms = builtComponents
        } else {
            _storage.atoms.append(contentsOf: builtComponents)
        }
        _storage.closeElement(appendedAtomCount: builtComponents.count)
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
    ///
    /// Reads `string` **once** and compares the built atom field by field.
    /// The previous form read `component.string` twice more and built a
    /// throwaway single-element array to compare against — for `Indent`,
    /// whose `string` is a fresh `String(repeating:)`, that meant allocating
    /// the same padding three times per appended token, plus the array. The
    /// remaining `buildComponents()` call is irreducible: verifying what it
    /// returns requires calling it. That still makes this the most expensive
    /// append overload in debug, which is why the assertion is documented as
    /// a development aid rather than a guarantee.
    @usableFromInline
    internal static func upholdsPlainAtomicPromise(_ component: some PlainAtomicSemanticComponent) -> Bool {
        let componentString = component.string
        let built = component.buildComponents()
        if componentString.isEmpty {
            return built.isEmpty
        }
        guard built.count == 1, let onlyAtom = built.first else {
            return false
        }
        return onlyAtom.string == componentString
            && onlyAtom.type == component.type
            && onlyAtom.identifier == nil
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
    ///
    /// Dispatches once through `_appendAsElement(into:)`, so a component
    /// reaching here as an existential or through an unspecialized generic
    /// takes the path its static type would: plain leaves the
    /// zero-allocation path, `AtomicComponent` the identifier-preserving
    /// path, a `SemanticString` the one-element bulk path, everything else
    /// `buildComponents()`. This replaced two `as?` probes plus a one-element
    /// array per plain leaf — measured 121.9 ms → 69.8 ms for 800k
    /// existential leaf appends against a 44 ms static floor
    /// (`docs/AppendPathPerformance.md`).
    @inlinable
    public mutating func append(_ component: some SemanticStringComponent) {
        component._appendAsElement(into: &self)
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
