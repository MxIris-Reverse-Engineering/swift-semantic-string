// MARK: - Declaration Block

/// A declaration block with header, braces, and indented body.
///
/// Example output:
/// ```
///     struct Foo {
///         var x: Int
///     }
/// ```
///
/// Usage:
/// ```swift
/// DeclarationBlock(level: 1) {
///     Keyword("struct")
///     Space()
///     TypeName(kind: .struct, "Foo")
/// } body: {
///     // members...
/// }
/// ```
public struct DeclarationBlock: SemanticStringComponent {
    @usableFromInline
    let level: Int

    @usableFromInline
    let header: any SemanticStringComponent

    @usableFromInline
    let body: [any SemanticStringComponent]

    /// Creates a declaration block with sync builders.
    @inlinable
    public init(
        level: Int,
        @SemanticStringBuilder header: () -> SemanticString,
        @SemanticStringBuilder body: () -> SemanticString
    ) {
        self.level = level
        self.header = header()
        self.body = body().elements
    }

    /// Creates a declaration block with async body builder.
    @inlinable
    public init(
        level: Int,
        @SemanticStringBuilder header: () -> SemanticString,
        @SemanticStringBuilder body: () async throws -> SemanticString
    ) async rethrows {
        self.level = level
        self.header = header()
        self.body = try await body().elements
    }

    /// Creates a declaration block with async header and body builders.
    @inlinable
    public init(
        level: Int,
        @SemanticStringBuilder header: () async throws -> SemanticString,
        @SemanticStringBuilder body: () async throws -> SemanticString
    ) async rethrows {
        self.level = level
        self.header = try await header()
        self.body = try await body().elements
    }

    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        var result: [AtomicComponent] = []

        // Header with indent
        if level > 0 {
            let indentString = String(repeating: " ", count: (level - 1) * 4)
            if !indentString.isEmpty {
                result.append(AtomicComponent(string: indentString, type: .standard))
            }
        }
        result.append(contentsOf: header.buildComponents())

        // Opening brace
        result.append(CommonAtomicComponents.space)
        result.append(AtomicComponent(string: "{", type: .standard))

        // Body - components handle their own structure (NestedDeclaration adds BreakLine, MemberList handles its own)
        let bodyComponents = body.flatMap { $0.buildComponents() }
        result.append(contentsOf: bodyComponents)

        // Closing brace with indent (only if body had content)
        if !bodyComponents.isEmpty {
            // Add BreakLine before closing brace if body doesn't end with newline
            if let last = bodyComponents.last, !last.string.hasSuffix("\n") {
                result.append(CommonAtomicComponents.breakLine)
            }
            if level > 0 {
                let indentString = String(repeating: " ", count: (level - 1) * 4)
                if !indentString.isEmpty {
                    result.append(AtomicComponent(string: indentString, type: .standard))
                }
            }
        }
        result.append(AtomicComponent(string: "}", type: .standard))

        return result
    }
}

// MARK: - Nested Declaration

/// A nested type or protocol declaration within a parent.
///
/// Handles the BreakLine before the nested declaration.
public struct NestedDeclaration: SemanticStringComponent {
    @usableFromInline
    let content: any SemanticStringComponent

    @inlinable
    public init(@SemanticStringBuilder content: () -> SemanticString) {
        self.content = content()
    }

    @inlinable
    public init(@SemanticStringBuilder content: () async throws -> SemanticString) async rethrows {
        self.content = try await content()
    }

    @inlinable
    public init(_ content: some SemanticStringComponent) {
        self.content = content
    }

    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        let built = content.buildComponents()
        guard !built.isEmpty else { return [] }
        var result: [AtomicComponent] = []
        result.reserveCapacity(built.count + 1)
        result.append(CommonAtomicComponents.breakLine)
        result.append(contentsOf: built)
        return result
    }
}

// MARK: - Block List

/// A list of items with breaks before each and after the last (if non-empty).
public struct BlockList: SemanticStringComponent {
    @usableFromInline
    let items: [any SemanticStringComponent]

    @usableFromInline
    let _separatedByEmptyLine: Bool

    /// Creates from a sync result builder.
    @inlinable
    public init(@SemanticStringBuilder content: () -> SemanticString) {
        self.items = content().elements
        self._separatedByEmptyLine = false
    }

    /// Creates from pre-built content.
    @inlinable
    public init(content: SemanticString) {
        self.items = content.elements
        self._separatedByEmptyLine = false
    }

    /// Creates from an array of items.
    @inlinable
    public init(_ items: [SemanticString]) {
        self.items = items
        self._separatedByEmptyLine = false
    }

    /// Creates from an array of components.
    @inlinable
    public init<C: SemanticStringComponent>(_ items: [C]) {
        self.items = items
        self._separatedByEmptyLine = false
    }

    /// Creates from an async result builder.
    @inlinable
    public init(@SemanticStringBuilder content: () async throws -> SemanticString) async rethrows {
        let built = try await content()
        self.items = built.elements
        self._separatedByEmptyLine = false
    }

    @usableFromInline
    init(items: [any SemanticStringComponent], separatedByEmptyLine: Bool) {
        self.items = items
        self._separatedByEmptyLine = separatedByEmptyLine
    }

    /// Returns a new BlockList that adds an empty line between each group.
    @inlinable
    public func separatedByEmptyLine(_ enabled: Bool = true) -> BlockList {
        BlockList(items: items, separatedByEmptyLine: enabled)
    }

    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        var result: [AtomicComponent] = []
        var hasContent = false
        for item in items {
            let group = item.buildComponents()
            guard !group.isEmpty else { continue }
            if _separatedByEmptyLine && hasContent {
                result.append(CommonAtomicComponents.breakLine)
            }
            result.append(CommonAtomicComponents.breakLine)
            result.append(contentsOf: group)
            hasContent = true
        }
        if hasContent {
            result.append(CommonAtomicComponents.breakLine)
        }
        return result
    }
}

// MARK: - Member List

/// A list of indented member lines.
public struct MemberList: SemanticStringComponent {
    @usableFromInline
    let level: Int

    @usableFromInline
    let items: [any SemanticStringComponent]

    /// Creates from a sync result builder.
    @inlinable
    public init(level: Int, @SemanticStringBuilder content: () -> SemanticString) {
        self.level = level
        self.items = content().elements
    }

    /// Creates from pre-built content.
    @inlinable
    public init(level: Int, content: SemanticString) {
        self.level = level
        self.items = content.elements
    }

    /// Creates from an array of items.
    @inlinable
    public init(level: Int, _ items: [SemanticString]) {
        self.level = level
        self.items = items
    }

    /// Creates from an array of components.
    @inlinable
    public init<C: SemanticStringComponent>(level: Int, _ items: [C]) {
        self.level = level
        self.items = items
    }

    /// Creates from an async result builder.
    @inlinable
    public init(level: Int, @SemanticStringBuilder content: () async throws -> SemanticString) async rethrows {
        self.level = level
        let built = try await content()
        self.items = built.elements
    }

    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        let indentString = level > 0 ? String(repeating: " ", count: level * 4) : ""
        let indentComponent: AtomicComponent? = indentString.isEmpty ? nil : AtomicComponent(string: indentString, type: .standard)

        var result: [AtomicComponent] = []
        var hasContent = false
        for item in items {
            let group = item.buildComponents()
            guard !group.isEmpty else { continue }
            result.append(CommonAtomicComponents.breakLine)
            if let indentComponent {
                result.append(indentComponent)
            }
            result.append(contentsOf: group)
            hasContent = true
        }
        if hasContent {
            result.append(CommonAtomicComponents.breakLine)
        }
        return result
    }
}

