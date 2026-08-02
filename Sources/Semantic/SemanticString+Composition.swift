// MARK: - Appending (Non-Mutating)

extension SemanticString {
    /// `self` with its identifier scopes cleared. Every `appending` result
    /// that actually appends starts here: building a fresh string never leaks
    /// open scopes on `self` into the result. Overloads that append nothing
    /// (`appending("")`, a false `if:` condition) return `self` unchanged
    /// instead — scopes included — matching the historical early returns, so
    /// a streaming writer that probes with empty input keeps its open scope.
    ///
    /// `consuming`, and that is the whole point. Written as a borrowing
    /// method it bound a second strong reference to the storage before the
    /// subsequent `append`, so `isKnownUniquelyReferenced` inside
    /// `makeUniqueForMutation()` was **always** false and every `appending` /
    /// `+` deep-copied the atom array — even `result = result + x`, where the
    /// operand is dead on the next line. Consuming forwards ownership when
    /// the caller has no further use for the value, letting that append hit
    /// the in-place branch; when the caller does keep using it, the compiler
    /// inserts the copy that used to be unconditional. This is a repeat fix:
    /// the first review round removed the same `var copy = self` pattern for
    /// the same reason, and the flat-storage redesign reintroduced it.
    @inlinable
    internal consuming func makingUnscopedCopy() -> SemanticString {
        var copy = self
        copy.identifierScopeStack = []
        return copy
    }

    /// Returns a new semantic string with the other string appended.
    @inlinable
    public consuming func appending(_ other: SemanticString) -> SemanticString {
        var copy = makingUnscopedCopy()
        copy.append(other)
        return copy
    }

    /// Returns a new semantic string with the component appended as one
    /// element.
    @inlinable
    public consuming func appending(_ component: some SemanticStringComponent) -> SemanticString {
        var copy = makingUnscopedCopy()
        copy.append(component)
        return copy
    }

    /// Returns a new semantic string with the leaf appended. Statically
    /// resolved; allocates nothing beyond the result's storage.
    @inlinable
    public consuming func appending(_ component: some PlainAtomicSemanticComponent) -> SemanticString {
        var copy = makingUnscopedCopy()
        copy.append(component)
        return copy
    }

    /// Returns a new semantic string with the erased leaf appended, keeping
    /// its `identifier`.
    @inlinable
    public consuming func appending(_ component: AtomicComponent) -> SemanticString {
        var copy = makingUnscopedCopy()
        copy.append(component)
        return copy
    }

    /// Returns a new semantic string with the string appended.
    ///
    /// Unlike the mutating `append(_:type:)`, this never stamps identifier
    /// scopes — the result is a fresh string and carries none. Appending an
    /// empty string returns `self` unchanged, open scopes included, matching
    /// the historical early return: a streaming writer that appends empty
    /// input must not lose the scope it is writing under.
    @inlinable
    public consuming func appending(_ string: String, type: SemanticType = .standard) -> SemanticString {
        guard !string.isEmpty else { return self }
        var copy = makingUnscopedCopy()
        copy.append(string, type: type)
        return copy
    }
}

// MARK: - Wrapping

extension SemanticString {
    /// Returns a new semantic string wrapped with the given prefix and suffix.
    @inlinable
    public func wrapped(prefix: String, suffix: String) -> SemanticString {
        var result = SemanticString()
        result.append(Standard(prefix))
        result.append(self)
        result.append(Standard(suffix))
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
    public static func + (lhs: consuming SemanticString, rhs: SemanticString) -> SemanticString {
        lhs.appending(rhs)
    }

    @inlinable
    public static func + (lhs: consuming SemanticString, rhs: some SemanticStringComponent) -> SemanticString {
        lhs.appending(rhs)
    }

    @inlinable
    public static func + (lhs: consuming SemanticString, rhs: some PlainAtomicSemanticComponent) -> SemanticString {
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
