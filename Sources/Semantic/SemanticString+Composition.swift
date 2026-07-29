// MARK: - Appending (Non-Mutating)

extension SemanticString {
    /// Builds `self` plus one atom as a fresh value.
    ///
    /// Constructs the result's storage directly instead of copying `self` and
    /// mutating the copy. Copy-then-mutate always finds the storage shared —
    /// the copy and `self` both hold it — so it pays a storage allocation
    /// *and* the array copy, where building the array first pays only the
    /// array copy and one allocation. Every `appending` / `+` / `wrapped` /
    /// `parenthesized` call goes through here, so the difference is per call
    /// on a path that historically did no copy-on-write work at all.
    @inlinable
    internal func appendingAtomicComponent(_ atomicComponent: AtomicComponent) -> SemanticString {
        var result = self
        result.identifierScopeStack = []
        guard !atomicComponent.string.isEmpty else { return result }
        if _storage.isFlat {
            var components = _storage.flatComponents
            components.append(atomicComponent)
            result._storage = Storage(flatComponents: components)
        } else {
            var elements = _storage.treeElements
            elements.append(atomicComponent)
            result._storage = Storage(treeElements: elements)
        }
        return result
    }

    /// Returns a new semantic string with the other string appended.
    ///
    /// Matches the historical semantics of building a fresh string: the
    /// result carries no identifier scopes, regardless of any scopes open
    /// on `self`.
    @inlinable
    public func appending(_ other: SemanticString) -> SemanticString {
        var copy = self
        copy.identifierScopeStack = []
        copy.append(other)
        return copy
    }

    /// Returns a new semantic string with the component appended.
    @inlinable
    public func appending(_ component: some SemanticStringComponent) -> SemanticString {
        var copy = self
        copy.identifierScopeStack = []
        copy.append(component)
        return copy
    }

    /// Returns a new semantic string with the leaf appended.
    ///
    /// Statically resolved, and — because a plain leaf is exactly one atom —
    /// able to build the result's storage in one pass.
    @inlinable
    public func appending(_ component: some PlainAtomicSemanticComponent) -> SemanticString {
        appendingAtomicComponent(AtomicComponent(string: component.string, type: component.type))
    }

    /// Returns a new semantic string with the erased leaf appended, keeping
    /// its `identifier`.
    @inlinable
    public func appending(_ component: AtomicComponent) -> SemanticString {
        appendingAtomicComponent(component)
    }

    /// Returns a new semantic string with the string appended.
    ///
    /// Unlike the mutating `append(_:type:)`, this never stamps identifier
    /// scopes — matching its historical behavior of assembling a fresh
    /// unscoped `AtomicComponent`.
    @inlinable
    public func appending(_ string: String, type: SemanticType = .standard) -> SemanticString {
        guard !string.isEmpty else { return self }
        return appendingAtomicComponent(AtomicComponent(string: string, type: type))
    }
}

// MARK: - Wrapping

extension SemanticString {
    /// Returns a new semantic string wrapped with the given prefix and suffix.
    @inlinable
    public func wrapped(prefix: String, suffix: String) -> SemanticString {
        // Builds the result flat and in one pass, on storage that is unique
        // from the first statement so no copy-on-write copy ever happens.
        // Going through `SemanticString(Standard(prefix)).appending(self)`
        // would instead start from a *tree* storage, so appending `self`
        // would re-box every one of its atoms as a tree element.
        var result = SemanticString()
        result.appendAtomicComponent(AtomicComponent(string: prefix, type: .standard))
        result.append(self)
        result.appendAtomicComponent(AtomicComponent(string: suffix, type: .standard))
        return result
    }

    /// Returns a new semantic string wrapped with the given prefix and suffix, only if condition is true.
    @inlinable
    public func wrapped(prefix: String, suffix: String, if condition: Bool) -> SemanticString {
        condition ? wrapped(prefix: prefix, suffix: suffix) : self
    }

    /// Returns a new semantic string wrapped in parentheses.
    @inlinable
    public func parenthesized() -> SemanticString {
        wrapped(prefix: "(", suffix: ")")
    }

    /// Returns a new semantic string wrapped in brackets.
    @inlinable
    public func bracketed() -> SemanticString {
        wrapped(prefix: "[", suffix: "]")
    }

    /// Returns a new semantic string wrapped in braces.
    @inlinable
    public func braced() -> SemanticString {
        wrapped(prefix: "{", suffix: "}")
    }

    /// Returns a new semantic string wrapped in angle brackets.
    @inlinable
    public func angleBracketed() -> SemanticString {
        wrapped(prefix: "<", suffix: ">")
    }
}

// MARK: - Conditional Operations

extension SemanticString {
    /// Returns the semantic string with the prefix prepended, only if the condition is true.
    @inlinable
    public func prefixed(with prefix: String, if condition: Bool) -> SemanticString {
        condition ? SemanticString(Standard(prefix)).appending(self) : self
    }

    /// Returns the semantic string with the prefix prepended, only if the condition is true.
    @inlinable
    public func prefixed(with prefix: SemanticString, if condition: Bool) -> SemanticString {
        condition ? prefix.appending(self) : self
    }

    /// Returns the semantic string with the prefix prepended, only if the condition is true.
    @inlinable
    public func prefixed(with prefix: some SemanticStringComponent, if condition: Bool) -> SemanticString {
        condition ? SemanticString(prefix).appending(self) : self
    }

    /// Returns the semantic string with the suffix appended, only if the condition is true.
    @inlinable
    public func suffixed(with suffix: String, if condition: Bool) -> SemanticString {
        condition ? appending(SemanticString(Standard(suffix))) : self
    }

    /// Returns the semantic string with the suffix appended, only if the condition is true.
    @inlinable
    public func suffixed(with suffix: SemanticString, if condition: Bool) -> SemanticString {
        condition ? appending(suffix) : self
    }

    /// Returns the semantic string with the suffix appended, only if the condition is true.
    @inlinable
    public func suffixed(with suffix: some SemanticStringComponent, if condition: Bool) -> SemanticString {
        condition ? appending(SemanticString(suffix)) : self
    }

    /// Returns self if the condition is true, otherwise returns an empty semantic string.
    @inlinable
    public func `if`(_ condition: Bool) -> SemanticString {
        condition ? self : SemanticString()
    }

    /// Returns self if the value is non-nil, otherwise returns an empty semantic string.
    /// The closure receives the unwrapped value.
    @inlinable
    public func ifLet<Value>(_ value: Value?, @SemanticStringBuilder then: (Value) -> SemanticString) -> SemanticString {
        if let value {
            return appending(then(value))
        }
        return self
    }
}

// MARK: - Operators

extension SemanticString {
    @inlinable
    public static func + (lhs: SemanticString, rhs: SemanticString) -> SemanticString {
        lhs.appending(rhs)
    }

    @inlinable
    public static func + (lhs: SemanticString, rhs: some SemanticStringComponent) -> SemanticString {
        lhs.appending(rhs)
    }

    @inlinable
    public static func + (lhs: SemanticString, rhs: some PlainAtomicSemanticComponent) -> SemanticString {
        lhs.appending(rhs)
    }

    @inlinable
    public static func += (lhs: inout SemanticString, rhs: SemanticString) {
        lhs.append(rhs)
    }

    @inlinable
    public static func += (lhs: inout SemanticString, rhs: some SemanticStringComponent) {
        lhs.append(rhs)
    }

    @inlinable
    public static func += (lhs: inout SemanticString, rhs: some PlainAtomicSemanticComponent) {
        lhs.append(rhs)
    }
}
