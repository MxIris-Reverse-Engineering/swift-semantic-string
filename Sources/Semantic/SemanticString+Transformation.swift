// MARK: - Transformation

extension SemanticString {
    /// Returns a new semantic string with every component transformed.
    ///
    /// A component mapped to an empty string is **dropped** — storage never
    /// holds zero-length components — so the result's `count` shrinks and
    /// indices shift while `string` is unchanged. Callers that need the
    /// component to survive should map to a placeholder instead of `""`.
    @inlinable
    public func map(_ modifier: (AtomicComponent) -> AtomicComponent) -> SemanticString {
        SemanticString(components: components.map(modifier))
    }

    /// Returns a new semantic string with every component's type transformed.
    /// Strings are preserved, so the component count is too.
    @inlinable
    public func replacing(_ transform: (SemanticType) -> SemanticType) -> SemanticString {
        map { AtomicComponent(string: $0.string, type: transform($0.type), identifier: $0.identifier) }
    }

    @inlinable
    public func replacing(from types: SemanticType..., to newType: SemanticType) -> SemanticString {
        map { component in
            if types.contains(component.type) {
                return AtomicComponent(string: component.string, type: newType, identifier: component.identifier)
            } else {
                return component
            }
        }
    }
}

// MARK: - Trimming

extension SemanticString {
    /// Returns a new semantic string with leading whitespace-only components removed.
    @inlinable
    public func trimmingLeadingWhitespace() -> SemanticString {
        let items = components
        var startIndex = items.startIndex
        while startIndex < items.endIndex,
              items[startIndex].string.allSatisfy(\.isWhitespace) {
            startIndex += 1
        }
        return SemanticString(components: Array(items[startIndex...]))
    }

    /// Returns a new semantic string with trailing whitespace-only components removed.
    @inlinable
    public func trimmingTrailingWhitespace() -> SemanticString {
        let items = components
        var endIndex = items.endIndex
        while endIndex > items.startIndex,
              items[endIndex - 1].string.allSatisfy(\.isWhitespace) {
            endIndex -= 1
        }
        return SemanticString(components: Array(items[..<endIndex]))
    }

    /// Returns a new semantic string with both leading and trailing whitespace-only components removed.
    @inlinable
    public func trimmingWhitespace() -> SemanticString {
        let items = components
        var startIndex = items.startIndex
        while startIndex < items.endIndex,
              items[startIndex].string.allSatisfy(\.isWhitespace) {
            startIndex += 1
        }
        var endIndex = items.endIndex
        while endIndex > startIndex,
              items[endIndex - 1].string.allSatisfy(\.isWhitespace) {
            endIndex -= 1
        }
        return SemanticString(components: Array(items[startIndex..<endIndex]))
    }

    /// Returns a new semantic string with leading newline-only components removed.
    @inlinable
    public func trimmingLeadingNewlines() -> SemanticString {
        let items = components
        var startIndex = items.startIndex
        while startIndex < items.endIndex,
              items[startIndex].string.allSatisfy(\.isNewline) {
            startIndex += 1
        }
        return SemanticString(components: Array(items[startIndex...]))
    }

    /// Returns a new semantic string with trailing newline-only components removed.
    @inlinable
    public func trimmingTrailingNewlines() -> SemanticString {
        let items = components
        var endIndex = items.endIndex
        while endIndex > items.startIndex,
              items[endIndex - 1].string.allSatisfy(\.isNewline) {
            endIndex -= 1
        }
        return SemanticString(components: Array(items[..<endIndex]))
    }

    /// Returns a new semantic string with both leading and trailing newline-only components removed.
    @inlinable
    public func trimmingNewlines() -> SemanticString {
        let items = components
        var startIndex = items.startIndex
        while startIndex < items.endIndex,
              items[startIndex].string.allSatisfy(\.isNewline) {
            startIndex += 1
        }
        var endIndex = items.endIndex
        while endIndex > startIndex,
              items[endIndex - 1].string.allSatisfy(\.isNewline) {
            endIndex -= 1
        }
        return SemanticString(components: Array(items[startIndex..<endIndex]))
    }
}

// MARK: - Subscript Access

extension SemanticString {
    /// Access a component by index.
    @inlinable
    public subscript(index: Int) -> AtomicComponent? {
        let items = components
        guard index >= 0, index < items.count else { return nil }
        return items[index]
    }

    /// Access a range of components.
    @inlinable
    public subscript(range: Range<Int>) -> SemanticString {
        let items = components
        let validRange = range.clamped(to: 0 ..< items.count)
        return SemanticString(components: Array(items[validRange]))
    }
}

// MARK: - Dropping

extension SemanticString {
    /// Returns a new semantic string with the first `n` components removed.
    @inlinable
    public func dropFirst(_ n: Int = 1) -> SemanticString {
        SemanticString(components: Array(components.dropFirst(n)))
    }

    /// Returns a new semantic string with the last `n` components removed.
    @inlinable
    public func dropLast(_ n: Int = 1) -> SemanticString {
        SemanticString(components: Array(components.dropLast(n)))
    }

    /// Returns a new semantic string with components while the predicate is true.
    @inlinable
    public func drop(while predicate: (AtomicComponent) -> Bool) -> SemanticString {
        SemanticString(components: Array(components.drop(while: predicate)))
    }
}

// MARK: - Prefix/Suffix Extraction

extension SemanticString {
    /// Returns a semantic string containing the first `n` components.
    @inlinable
    public func prefix(_ n: Int) -> SemanticString {
        SemanticString(components: Array(components.prefix(n)))
    }

    /// Returns a semantic string containing the last `n` components.
    @inlinable
    public func suffix(_ n: Int) -> SemanticString {
        SemanticString(components: Array(components.suffix(n)))
    }
}

// MARK: - Filtering

extension SemanticString {
    /// Returns a semantic string containing only components of the specified type.
    @inlinable
    public func filter(byType type: SemanticType) -> SemanticString {
        SemanticString(components: components.filter { $0.type == type })
    }

    /// Returns a semantic string containing only components matching the predicate.
    @inlinable
    public func filter(_ predicate: (AtomicComponent) -> Bool) -> SemanticString {
        SemanticString(components: components.filter(predicate))
    }
}
