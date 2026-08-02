// MARK: - Enumeration

extension SemanticString {
    @inlinable
    public func enumerate(using block: (String, SemanticType) -> Void) {
        components.forEach { block($0.string, $0.type) }
    }
}

// MARK: - Prefix and Suffix Checking

extension SemanticString {
    /// Returns `true` if the combined string starts with the given prefix.
    @inlinable
    public func hasPrefix(_ prefix: String) -> Bool {
        string.hasPrefix(prefix)
    }

    /// Returns `true` if the combined string ends with the given suffix.
    @inlinable
    public func hasSuffix(_ suffix: String) -> Bool {
        string.hasSuffix(suffix)
    }

    /// Returns `true` if the first component has the given semantic type.
    @inlinable
    public func starts(with type: SemanticType) -> Bool {
        first?.type == type
    }

    /// Returns `true` if the last component has the given semantic type.
    @inlinable
    public func ends(with type: SemanticType) -> Bool {
        last?.type == type
    }

    /// Returns `true` if the first component's string starts with the given prefix.
    @inlinable
    public func firstComponentHasPrefix(_ prefix: String) -> Bool {
        first?.string.hasPrefix(prefix) ?? false
    }

    /// Returns `true` if the last component's string ends with the given suffix.
    @inlinable
    public func lastComponentHasSuffix(_ suffix: String) -> Bool {
        last?.string.hasSuffix(suffix) ?? false
    }
}

// MARK: - Containment

extension SemanticString {
    /// Returns `true` if any component has the specified semantic type.
    @inlinable
    public func contains(type: SemanticType) -> Bool {
        components.contains { $0.type == type }
    }

    /// Returns `true` if the combined string contains the specified substring.
    @inlinable
    public func contains(_ substring: String) -> Bool {
        guard !substring.isEmpty else { return true }
        let source = string.utf8
        let pattern = substring.utf8
        guard source.count >= pattern.count else { return false }
        var sourceIndex = source.startIndex
        let searchEnd = source.index(source.endIndex, offsetBy: -pattern.count)
        while sourceIndex <= searchEnd {
            if source[sourceIndex...].starts(with: pattern) {
                return true
            }
            source.formIndex(after: &sourceIndex)
        }
        return false
    }
}
