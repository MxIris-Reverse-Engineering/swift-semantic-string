// MARK: - Core Protocol

/// A component that can be converted into semantic string content.
///
/// This protocol is the foundation of the semantic string system, similar to
/// SwiftUI's `View` protocol. Components can be either atomic (with a single
/// string and semantic type) or composite (containing other components).
///
/// Conforming to this protocol:
/// - For atomic components, also conform to `AtomicSemanticComponent`
/// - For composite components, implement `buildComponents()` directly
///
/// Example atomic component:
/// ```swift
/// struct Keyword: AtomicSemanticComponent {
///     let string: String
///     var type: SemanticType { .keyword }
/// }
/// ```
///
/// Example composite component:
/// ```swift
/// struct Group: SemanticStringComponent {
///     let items: [any SemanticStringComponent]
///
///     func buildComponents() -> [AtomicComponent] {
///         items.flatMap { $0.buildComponents() }
///     }
/// }
/// ```
public protocol SemanticStringComponent: Sendable {
    /// Expands this component into an array of atomic components.
    ///
    /// For atomic components, this returns a single-element array.
    /// For composite components, this recursively expands all children.
    func buildComponents() -> [AtomicComponent]
}

// MARK: - Atomic Component Protocol

/// A component with a single string value and semantic type.
///
/// Atomic components are the leaf nodes of the semantic string tree.
/// They represent indivisible units of styled text.
///
/// The default implementation of `buildComponents()` wraps `self`
/// in an `AtomicComponent`.
public protocol AtomicSemanticComponent: SemanticStringComponent {
    /// The string content of this component.
    var string: String { get }

    /// The semantic type for styling/categorization.
    var type: SemanticType { get }
}

extension AtomicSemanticComponent {
    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        if string.isEmpty {
            return []
        }
        return [AtomicComponent(string: string, type: type)]
    }
}

// MARK: - Plain Atomic Component Protocol

/// An atomic component whose `buildComponents()` is exactly the inherited
/// default: one `AtomicComponent(string:type:)`, or none when `string` is
/// empty.
///
/// Conforming is a promise, and it buys the zero-allocation streaming path:
/// `SemanticString.append(_:)` has a statically-resolved overload for plain
/// leaves that stores `string` and `type` straight into the atom array, with
/// no dynamic cast and no intermediate array. All of the library's own leaves
/// (`Keyword`, `Space`, `Indent`, `TypeName`, …) conform.
///
/// **Do not conform if you override `buildComponents()`.** The fast path does
/// not call it, so an override would be silently ignored for values appended
/// through `append` / `appending` / `+` / `+=` while still being honoured when
/// the same value goes through a `@SemanticStringBuilder` — the same component
/// producing different *content* depending on how it was assembled. Leaves
/// that override `buildComponents()` conform to `AtomicSemanticComponent`
/// only and take the correct, slightly slower path — which still records one
/// element however many atoms the override produces. `AtomicComponent` is one
/// such leaf: it overrides `buildComponents()` to carry `identifier` through.
public protocol PlainAtomicSemanticComponent: AtomicSemanticComponent {}

// MARK: - Convenience Extensions

extension SemanticStringComponent {
    /// Converts this component to a `SemanticString`.
    @inlinable
    public func asSemanticString() -> SemanticString {
        SemanticString(self)
    }
}

// MARK: - Never Conformance (for result builder)

extension Never: SemanticStringComponent {
    public func buildComponents() -> [AtomicComponent] {
        switch self {}
    }
}

// MARK: - Optional Conformance

extension Optional: SemanticStringComponent where Wrapped: SemanticStringComponent {
    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        self?.buildComponents() ?? []
    }
}

// MARK: - Array Conformance

extension Array: SemanticStringComponent where Element: SemanticStringComponent {
    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        flatMap { $0.buildComponents() }
    }
}
