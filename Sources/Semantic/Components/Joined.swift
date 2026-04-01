/// A component that joins multiple semantic strings with a separator,
/// automatically filtering out empty items.
///
/// Example usage in a builder:
/// ```swift
/// Joined(separator: ", ") {
///     Keyword("public")
///     Keyword("static")
///     Keyword("func")
/// }
/// ```
///
/// Example usage with prefix and suffix:
/// ```swift
/// Joined(separator: ", ", prefix: "(", suffix: ")") {
///     TypeName("Int")
///     TypeName("String")
/// }
/// // Result: (Int, String)
/// ```
///
/// Example usage with array:
/// ```swift
/// Joined(separator: ", ", items)
/// ```
public struct Joined: SemanticStringComponent {
    @usableFromInline
    let items: [any SemanticStringComponent]

    @usableFromInline
    let separator: any SemanticStringComponent

    @usableFromInline
    let prefix: (any SemanticStringComponent)?

    @usableFromInline
    let suffix: (any SemanticStringComponent)?

    // MARK: - Builder Initializers

    /// Creates a joined component from a builder with a string separator.
    @inlinable
    public init(
        separator: String = "",
        prefix: String? = nil,
        suffix: String? = nil,
        @SemanticStringBuilder content: () -> SemanticString
    ) {
        self.separator = Standard(separator)
        self.prefix = prefix.map { Standard($0) }
        self.suffix = suffix.map { Standard($0) }
        self.items = content().elements
    }

    /// Creates a joined component from a builder with a component separator.
    @inlinable
    public init(
        separator: some SemanticStringComponent = Standard(""),
        prefix: (some SemanticStringComponent)? = nil as Standard?,
        suffix: (some SemanticStringComponent)? = nil as Standard?,
        @SemanticStringBuilder content: () -> SemanticString
    ) {
        self.separator = separator
        self.prefix = prefix
        self.suffix = suffix
        self.items = content().elements
    }

    // MARK: - Builder Prefix/Suffix Initializers

    /// Creates a joined component with result builder closures for prefix and suffix.
    ///
    /// Example usage:
    /// ```swift
    /// Joined {
    ///     for item in items {
    ///         item.semanticString
    ///     }
    /// } prefix: {
    ///     BreakLine()
    ///     Keyword("@required")
    /// }
    /// ```
    @inlinable
    public init(
        separator: String = "",
        @SemanticStringBuilder content: () -> SemanticString,
        @SemanticStringBuilder prefix: () -> SemanticString
    ) {
        self.separator = Standard(separator)
        self.prefix = prefix()
        self.suffix = nil
        self.items = content().elements
    }

    /// Creates a joined component with result builder closures for prefix and suffix.
    ///
    /// Example usage:
    /// ```swift
    /// Joined {
    ///     for item in items {
    ///         item.semanticString
    ///     }
    /// } prefix: {
    ///     BreakLine()
    ///     Keyword("@required")
    /// } suffix: {
    ///     BreakLine()
    /// }
    /// ```
    @inlinable
    public init(
        separator: String = "",
        @SemanticStringBuilder content: () -> SemanticString,
        @SemanticStringBuilder prefix: () -> SemanticString,
        @SemanticStringBuilder suffix: () -> SemanticString
    ) {
        self.separator = Standard(separator)
        self.prefix = prefix()
        self.suffix = suffix()
        self.items = content().elements
    }

    // MARK: - Array Initializers

    /// Creates a joined component from an array of semantic strings.
    @inlinable
    public init(
        separator: String = "",
        prefix: String? = nil,
        suffix: String? = nil,
        _ items: [SemanticString]
    ) {
        self.separator = Standard(separator)
        self.prefix = prefix.map { Standard($0) }
        self.suffix = suffix.map { Standard($0) }
        self.items = items
    }

    /// Creates a joined component from an array with a component separator.
    @inlinable
    public init(
        separator: some SemanticStringComponent = Standard(""),
        prefix: (some SemanticStringComponent)? = nil as Standard?,
        suffix: (some SemanticStringComponent)? = nil as Standard?,
        _ items: [SemanticString]
    ) {
        self.separator = separator
        self.prefix = prefix
        self.suffix = suffix
        self.items = items
    }

    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        let sepComponents = separator.buildComponents()
        var result: [AtomicComponent] = []
        var hasContent = false

        for item in items {
            let components = item.buildComponents()
            guard !components.isEmpty else { continue }
            if hasContent {
                result.append(contentsOf: sepComponents)
            }
            result.append(contentsOf: components)
            hasContent = true
        }

        guard hasContent else { return [] }

        // Add prefix and suffix only if there was content
        if let prefix {
            let prefixComponents = prefix.buildComponents()
            result.insert(contentsOf: prefixComponents, at: 0)
        }
        if let suffix {
            result.append(contentsOf: suffix.buildComponents())
        }

        return result
    }
}

// MARK: - Array Extensions

extension Array where Element == SemanticString {
    /// Joins an array of semantic strings with a separator.
    @inlinable
    public func joined(separator: String) -> SemanticString {
        joined(separator: Standard(separator))
    }

    /// Joins an array of semantic strings with a component separator.
    @inlinable
    public func joined(separator: some SemanticStringComponent) -> SemanticString {
        Joined(separator: separator, self).asSemanticString()
    }
}

extension Array where Element: SemanticStringComponent {
    /// Joins an array of components with a separator.
    @inlinable
    public func joined(separator: String) -> SemanticString {
        map { $0.asSemanticString() }.joined(separator: separator)
    }

    /// Joins an array of components with a component separator.
    @inlinable
    public func joined(separator: some SemanticStringComponent) -> SemanticString {
        map { $0.asSemanticString() }.joined(separator: separator)
    }
}
