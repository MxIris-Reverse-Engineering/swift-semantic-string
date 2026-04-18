/// Pre-computed atomic components for common literals to avoid repeated allocations.
@usableFromInline
enum CommonAtomicComponents {
    @usableFromInline
    static let breakLine = AtomicComponent(string: "\n", type: .standard)

    @usableFromInline
    static let space = AtomicComponent(string: " ", type: .standard)

    /// Cached indent strings for levels 0…16 (common depth for code generation).
    @usableFromInline
    static let indentStrings: [String] = (0...16).map {
        String(repeating: " ", count: $0 * 4)
    }

    /// Returns a 4-space indent string for the given positive level.
    /// Returns `""` for `level <= 0`. Uses a cache for `level <= 16`.
    @inlinable
    static func indentString(forLevel level: Int) -> String {
        if level <= 0 { return "" }
        if level <= 16 { return indentStrings[level] }
        return String(repeating: " ", count: level * 4)
    }
}

/// An indentation component.
///
/// Example:
/// ```swift
/// Indent(level: 2)  // produces 8 spaces (4 per level)
/// ```
public struct Indent: AtomicSemanticComponent, CustomStringConvertible {
    public let level: Int

    @inlinable
    public var string: String { description }

    @inlinable
    public var type: SemanticType { .standard }

    @inlinable
    public init(level: Int) {
        self.level = level
    }

    @inlinable
    public var description: String {
        CommonAtomicComponents.indentString(forLevel: level)
    }
}

/// A line break component.
///
/// Example:
/// ```swift
/// BreakLine()  // produces "\n"
/// ```
public struct BreakLine: AtomicSemanticComponent, CustomStringConvertible {
    @inlinable
    public var string: String { "\n" }

    @inlinable
    public var type: SemanticType { .standard }

    @inlinable
    public var description: String { "\n" }

    @inlinable
    public init() {}
}

/// A single space component.
///
/// Example:
/// ```swift
/// Space()  // produces " "
/// ```
public struct Space: AtomicSemanticComponent, CustomStringConvertible {
    @inlinable
    public var string: String { " " }

    @inlinable
    public var type: SemanticType { .standard }

    @inlinable
    public var description: String { " " }

    @inlinable
    public init() {}
}
