/// A preprocessor macro component with `.macro` semantic type.
///
/// Example:
/// ```swift
/// Macro("NS_REFINED_FOR_SWIFT")  // styled as a macro
/// Macro("NS_SWIFT_NAME")         // the name; its argument list is separate text
/// ```
public struct Macro: AtomicSemanticComponent {
    public let string: String

    @inlinable
    public var type: SemanticType { .macro }

    @inlinable
    public init(_ string: String) {
        self.string = string
    }
}
