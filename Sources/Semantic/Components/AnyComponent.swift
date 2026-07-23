/// A type-erased atomic component that stores a string and its semantic type.
///
/// `AtomicComponent` is the concrete storage type used by `SemanticString`.
/// It's similar to SwiftUI's `AnyView` - a type-erased container for any
/// atomic semantic component.
///
/// You typically don't create `AtomicComponent` directly. Instead, use
/// specific component types like `Keyword`, `TypeName`, or `Standard`.
public struct AtomicComponent: AtomicSemanticComponent, Hashable {
    public let string: String
    public let type: SemanticType

    /// Opaque identity of the enclosing reference span (e.g. a mangled type
    /// name). Adjacent components sharing the same identifier form one
    /// logical span for consumers such as link builders and selection.
    public let identifier: String?

    @inlinable
    public init(string: String, type: SemanticType, identifier: String? = nil) {
        self.string = string
        self.type = type
        self.identifier = identifier
    }

    @inlinable
    public init(_ component: some AtomicSemanticComponent) {
        self.string = component.string
        self.type = component.type
        self.identifier = nil
    }

    /// Overrides the protocol default, which rebuilds a fresh
    /// `AtomicComponent(string:type:)` and would silently drop `identifier`.
    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        if string.isEmpty {
            return []
        }
        return [self]
    }
}

extension AtomicComponent: Codable {
    private enum CodingKeys: String, CodingKey {
        case string
        case type
        case identifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.string = try container.decode(String.self, forKey: .string)
        self.type = try container.decode(SemanticType.self, forKey: .type)
        self.identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(string, forKey: .string)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(identifier, forKey: .identifier)
    }
}

// MARK: - Type Alias for Backwards Compatibility

@available(*, deprecated, renamed: "AtomicComponent")
public typealias AnyComponent = AtomicComponent

// MARK: - Empty Component

/// A component that produces no output.
///
/// Similar to SwiftUI's `EmptyView`, this is useful as a placeholder
/// or when conditionally producing no content.
///
/// Example:
/// ```swift
/// @SemanticStringBuilder
/// var content: SemanticString {
///     if showLabel {
///         Keyword("public")
///     } else {
///         EmptyComponent()
///     }
/// }
/// ```
public struct EmptyComponent: SemanticStringComponent {
    @inlinable
    public init() {}

    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        []
    }
}

// MARK: - Tuple Components (for result builder)

/// A component that combines two components.
public struct TupleComponent2<C0: SemanticStringComponent, C1: SemanticStringComponent>: SemanticStringComponent {
    public let c0: C0
    public let c1: C1

    @inlinable
    public init(_ c0: C0, _ c1: C1) {
        self.c0 = c0
        self.c1 = c1
    }

    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        var result = c0.buildComponents()
        result.append(contentsOf: c1.buildComponents())
        return result
    }
}

/// A component that combines three components.
public struct TupleComponent3<C0: SemanticStringComponent, C1: SemanticStringComponent, C2: SemanticStringComponent>: SemanticStringComponent {
    public let c0: C0
    public let c1: C1
    public let c2: C2

    @inlinable
    public init(_ c0: C0, _ c1: C1, _ c2: C2) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
    }

    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        var result = c0.buildComponents()
        result.append(contentsOf: c1.buildComponents())
        result.append(contentsOf: c2.buildComponents())
        return result
    }
}
