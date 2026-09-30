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

    /// Appends this component's flattening to `semanticString` as one
    /// element.
    ///
    /// **Implementation detail — do not implement it, do not call it.** It
    /// is a requirement only so that the library's own component kinds each
    /// take their proper append path through a single witness-table call
    /// when they reach `SemanticString.append(_:)` as an existential or
    /// through an unspecialized generic: plain leaves the zero-allocation
    /// path, `AtomicComponent` the identifier-preserving path,
    /// `SemanticString` the one-element bulk path. The default flattens
    /// through `buildComponents()`, which is what every third-party
    /// component gets — a custom `buildComponents()` is honoured through it.
    /// It is `public` because a requirement that external conformers satisfy
    /// through a default must be; the underscore marks it as outside the
    /// calling surface.
    func _appendAsElement(into semanticString: inout SemanticString)
}

extension SemanticStringComponent {
    /// The general path: flatten eagerly, record one element. See the
    /// requirement's documentation.
    @inlinable
    public func _appendAsElement(into semanticString: inout SemanticString) {
        semanticString.appendComponentElement(flattening: buildComponents())
    }
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
/// not call it, so an override is silently ignored wherever the value is
/// *appended* — `append` / `appending` / `+` / `+=`, as an existential or
/// through a generic, and every `@SemanticStringBuilder` child, because the
/// builder appends its children — while still being honoured wherever a
/// composite calls `buildComponents()` directly: the `[Component]` array
/// initializers of `MemberList` / `BlockList` / `Rows`, `Joined`'s separator,
/// prefix and suffix, `NestedDeclaration(_:)`, `TupleComponent`, and `Array` /
/// `Optional` flattening. The same component then produces different
/// *content* depending on where it was placed. The two results compare
/// unequal and hash differently, so a `Set` or a dictionary key holds both.
///
/// **Nothing enforces this in release.** Debug builds assert the promise on
/// every fast-path append, but `assert` is compiled out under `-O`: a
/// violating conformance built for release ships the divergence silently,
/// with no diagnostic and no crash. The assertion is a development aid that
/// fires only if a debug build happens to stream that particular leaf — it is
/// not a guarantee, and a conformance that is only ever exercised in release
/// is never checked at all. Treat the promise as a contract you uphold, not
/// one the library verifies for you.
///
/// Leaves that override `buildComponents()` conform to
/// `AtomicSemanticComponent` only and take the correct, slightly slower
/// path — which still records one element however many atoms the override
/// produces. `AtomicComponent` is one such leaf: it overrides
/// `buildComponents()` to carry `identifier` through.
public protocol PlainAtomicSemanticComponent: AtomicSemanticComponent {}

extension PlainAtomicSemanticComponent {
    /// Plain leaves take the statically-resolved fast path even when they
    /// arrive as an existential: `append(_: some PlainAtomicSemanticComponent)`
    /// reads `string` / `type` straight into the atom array. The debug
    /// assertion guarding the promise therefore fires on this path too.
    @inlinable
    public func _appendAsElement(into semanticString: inout SemanticString) {
        semanticString.append(self)
    }
}

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

    /// Forwards to the payload's own path; `nil` appends nothing — a
    /// complete no-op, exactly as flattening to `[]` is.
    @inlinable
    public func _appendAsElement(into semanticString: inout SemanticString) {
        if let wrapped = self {
            wrapped._appendAsElement(into: &semanticString)
        }
    }
}

// MARK: - Array Conformance

extension Array: SemanticStringComponent where Element: SemanticStringComponent {
    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        flatMap { $0.buildComponents() }
    }
}
