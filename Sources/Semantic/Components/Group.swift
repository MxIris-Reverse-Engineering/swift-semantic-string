/// A transparent grouping container for semantic string components.
///
/// Use `Group` to collect multiple components and optionally apply a separator.
/// Unlike `Joined`, `Group` preserves the structure for later manipulation.
///
/// Example:
/// ```swift
/// Group {
///     Keyword("public")
///     Space()
///     Keyword("func")
/// }
/// .separator(Standard(", "))
/// ```
public struct Group: SemanticStringComponent {
    @usableFromInline
    var items: [any SemanticStringComponent]

    @usableFromInline
    var separator: (any SemanticStringComponent)?

    /// Creates a group from a builder.
    @inlinable
    public init(@SemanticStringBuilder content: () -> SemanticString) {
        self.items = content().elements
        self.separator = nil
    }

    /// Creates a group from an array of semantic strings.
    @inlinable
    public init(_ items: [SemanticString]) {
        self.items = items
        self.separator = nil
    }

    /// Creates a group from variadic semantic strings.
    @inlinable
    public init(_ items: SemanticString...) {
        self.items = items
        self.separator = nil
    }

    /// Creates an empty group.
    @inlinable
    public init() {
        self.items = []
        self.separator = nil
    }

    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        if let sep = separator {
            let sepComponents = sep.buildComponents()
            var result: [AtomicComponent] = []
            var needsSeparator = false
            for item in items {
                let components = item.buildComponents()
                guard !components.isEmpty else { continue }
                if needsSeparator {
                    result.append(contentsOf: sepComponents)
                }
                result.append(contentsOf: components)
                needsSeparator = true
            }
            return result
        }

        var result: [AtomicComponent] = []
        for item in items {
            result.append(contentsOf: item.buildComponents())
        }
        return result
    }

    /// Applies a separator between components.
    @inlinable
    public func separator(_ separator: some SemanticStringComponent) -> Group {
        var copy = self
        copy.separator = separator
        return copy
    }

    /// Applies a string separator between components.
    @inlinable
    public func separator(_ separator: String) -> Group {
        var copy = self
        copy.separator = Standard(separator)
        return copy
    }
}
