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
    let body: SemanticStringElements

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
        // Conservative lower bound: header + space + "{" + body + break + indent + "}" ≈ body.count + 8.
        // Array grows geometrically, so under-reserving is harmless.
        result.reserveCapacity(body.count + 8)

        // Compute header/closing indent once per call. DeclarationBlock indents
        // by (level - 1), so level 0/1 produce an empty indent string that is
        // filtered by the `isEmpty` guards at each call site.
        let indentString = CommonAtomicComponents.indentString(forLevel: level - 1)

        // Header with indent
        if level > 0 && !indentString.isEmpty {
            result.append(AtomicComponent(string: indentString, type: .standard))
        }
        result.append(contentsOf: header.buildComponents())

        // Opening brace
        result.append(CommonAtomicComponents.space)
        result.append(AtomicComponent(string: "{", type: .standard))

        // Body - components handle their own structure (NestedDeclaration adds BreakLine, MemberList handles its own)
        let bodyStartCount = result.count
        body.appendAllComponents(into: &result)

        // Closing brace with indent (only if body had content)
        if result.count > bodyStartCount {
            // Add BreakLine before closing brace if body doesn't end with newline
            if let last = result.last, !last.string.hasSuffix("\n") {
                result.append(CommonAtomicComponents.breakLine)
            }
            if level > 0 && !indentString.isEmpty {
                result.append(AtomicComponent(string: indentString, type: .standard))
            }
        }
        result.append(AtomicComponent(string: "}", type: .standard))

        return result
    }
}

// MARK: - Nested Declaration

/// A nested type or protocol declaration within a parent.
///
/// Adds a BreakLine before the nested content to separate it from the previous sibling.
///
/// Example output (when placed inside a DeclarationBlock body):
/// ```
/// class Outer {
///     var x: Int
///
///     struct Inner {      ← NestedDeclaration adds the \n before this block
///         var y: Int
///     }
/// }
/// ```
///
/// Usage:
/// ```swift
/// NestedDeclaration {
///     DeclarationBlock(level: 2) {
///         Keyword("struct")
///         Space()
///         TypeName(kind: .struct, "Inner")
///     } body: {
///         // ...
///     }
/// }
/// ```
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
/// No indentation is added — each item controls its own indent.
///
/// Example output (default):
/// ```
///                     ← breakLine before item 1
/// protocol Foo {      ← item 1
///     func bar()
/// }
///                     ← breakLine before item 2
/// protocol Baz {      ← item 2
///     func qux()
/// }
///                     ← trailing breakLine
/// ```
///
/// Example output (with `.separatedByEmptyLine()`):
/// ```
///                     ← breakLine before item 1
/// protocol Foo {
///     func bar()
/// }
///                     ← extra breakLine (empty line separator)
///                     ← breakLine before item 2
/// protocol Baz {
///     func qux()
/// }
///                     ← trailing breakLine
/// ```
///
/// Usage:
/// ```swift
/// BlockList {
///     protocolBlock1
///     protocolBlock2
/// }
/// .separatedByEmptyLine()  // optional
/// ```
public struct BlockList: SemanticStringComponent {
    @usableFromInline
    let items: SemanticStringElements

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
        self.items = SemanticStringElements(items)
        self._separatedByEmptyLine = false
    }

    /// Creates from an array of components.
    @inlinable
    public init<Component: SemanticStringComponent>(_ items: [Component]) {
        self.items = SemanticStringElements(items)
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
    init(items: SemanticStringElements, separatedByEmptyLine: Bool) {
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
        // Pattern per item: leading break + item (+ optional separator break) + trailing break.
        result.reserveCapacity(items.totalComponentCount + items.count * 2 + 1)
        var hasContent = false
        for index in items.indices {
            // Zero-copy slice; empty items are skipped entirely.
            let itemComponents = items.atoms(ofElementAt: index)
            guard !itemComponents.isEmpty else { continue }
            if _separatedByEmptyLine && hasContent {
                result.append(CommonAtomicComponents.breakLine)
            }
            result.append(CommonAtomicComponents.breakLine)
            result.append(contentsOf: itemComponents)
            hasContent = true
        }
        if hasContent {
            result.append(CommonAtomicComponents.breakLine)
        }
        return result
    }
}

// MARK: - Member List

/// A list of indented member lines. Each item gets a breakLine + indent(level * 4 spaces) before it,
/// and a trailing breakLine after the last item.
///
/// Example output (level: 1, 3 items):
/// ```
///                         ← breakLine
///     // offset: 0x10     ← indent(4) + item 1
///                         ← breakLine
///     var name: String    ← indent(4) + item 2
///                         ← breakLine
///     func foo()          ← indent(4) + item 3
///                         ← trailing breakLine
/// ```
///
/// Example output (level: 2, 2 items):
/// ```
///                             ← breakLine
///         var x: Int          ← indent(8) + item 1
///                             ← breakLine
///         var y: Int          ← indent(8) + item 2
///                             ← trailing breakLine
/// ```
///
/// Items that produce empty components are skipped entirely (no breakLine or indent).
///
/// Usage:
/// ```swift
/// MemberList(level: 1) {
///     OffsetComment(prefix: "field offset", offset: 0x10, emit: true)
///     variableDeclaration
///     functionDeclaration
/// }
/// ```
public struct MemberList: SemanticStringComponent {
    @usableFromInline
    let level: Int

    @usableFromInline
    let items: SemanticStringElements

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
        self.items = SemanticStringElements(items)
    }

    /// Creates from an array of components.
    @inlinable
    public init<Component: SemanticStringComponent>(level: Int, _ items: [Component]) {
        self.level = level
        self.items = SemanticStringElements(items)
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
        let indentString = CommonAtomicComponents.indentString(forLevel: level)
        let indentComponent: AtomicComponent? = indentString.isEmpty ? nil : AtomicComponent(string: indentString, type: .standard)

        var result: [AtomicComponent] = []
        // Pattern per item: break + indent + item, plus one trailing break.
        result.reserveCapacity(items.totalComponentCount + items.count * 2 + 1)
        var hasContent = false
        for index in items.indices {
            // Zero-copy slice; empty items are skipped entirely.
            let itemComponents = items.atoms(ofElementAt: index)
            guard !itemComponents.isEmpty else { continue }
            result.append(CommonAtomicComponents.breakLine)
            if let indentComponent {
                result.append(indentComponent)
            }
            result.append(contentsOf: itemComponents)
            hasContent = true
        }
        if hasContent {
            result.append(CommonAtomicComponents.breakLine)
        }
        return result
    }
}

// MARK: - Rows

/// A multi-row block that nests as a single item inside a row-oriented
/// container (e.g. `MemberList`) yet expands into multiple visually distinct
/// rows. Between consecutive sub-rows it emits `BreakLine + Indent(level)`;
/// it emits **no** leading or trailing `BreakLine` — the outer container's
/// leading separator opens the first sub-row, and the container's next
/// iteration (or its own trailing break) closes the block.
///
/// Use `Rows` when one logical entry in a container maps to multiple lines
/// at the same indent level — typically a declaration preceded by one or
/// more annotation comments (offset / vtable / address). Wrapping those
/// in a single `SemanticString` would fuse them into one row; `Rows`
/// preserves the per-line `BreakLine + Indent` while still letting a
/// helper return a single component.
///
/// Example output (level: 1, 3 sub-rows, inside a `MemberList(level: 1)`
/// whose leading separator is `BreakLine + Indent(4)`):
/// ```
///     // address: 0x1000              ← MemberList break + indent + sub-row 1
///     // address (setter): 0x1010     ← Rows internal break + indent + sub-row 2
///     var name: Swift.String          ← Rows internal break + indent + sub-row 3
/// ```
///
/// Sub-rows that produce empty components are skipped entirely — no
/// `BreakLine + Indent` is emitted for them, preventing stray blank lines
/// when conditional annotations (`emit: false`) collapse away.
///
/// Usage:
/// ```swift
/// MemberList(level: 1) {
///     Rows(level: 1) {
///         OffsetComment(prefix: "offset", offset: 0x10, emit: true)
///         AddressComment(addressString: "0x1000", emit: true)
///         variableDeclaration
///     }
/// }
/// ```
public struct Rows: SemanticStringComponent {
    @usableFromInline
    let level: Int

    @usableFromInline
    let items: SemanticStringElements

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
        self.items = SemanticStringElements(items)
    }

    /// Creates from an array of components.
    @inlinable
    public init<Component: SemanticStringComponent>(level: Int, _ items: [Component]) {
        self.level = level
        self.items = SemanticStringElements(items)
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
        let indentString = CommonAtomicComponents.indentString(forLevel: level)
        let indentComponent: AtomicComponent? = indentString.isEmpty ? nil : AtomicComponent(string: indentString, type: .standard)

        var result: [AtomicComponent] = []
        // Pattern per non-first sub-row: break + indent + item; first sub-row
        // is opened by the outer container's leading separator.
        result.reserveCapacity(items.totalComponentCount + items.count * 2)
        var hasContent = false
        for index in items.indices {
            // Zero-copy slice; empty sub-rows are skipped entirely.
            let itemComponents = items.atoms(ofElementAt: index)
            guard !itemComponents.isEmpty else { continue }
            if hasContent {
                result.append(CommonAtomicComponents.breakLine)
                if let indentComponent {
                    result.append(indentComponent)
                }
            }
            result.append(contentsOf: itemComponents)
            hasContent = true
        }
        return result
    }
}

