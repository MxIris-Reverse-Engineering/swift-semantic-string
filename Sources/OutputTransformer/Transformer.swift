import Foundation

// MARK: - Transformer Namespace

/// Shared namespace for output-transformer modules.
///
/// This module deliberately holds **only** the namespace and the ``Module``
/// protocol — no concrete transformer. A transformer's tokens carry the
/// vocabulary of whatever it describes (`bitsNeededForTag`, `ivar offset`),
/// which belongs to the library that owns that domain, not to a general-purpose
/// string package. Concrete modules therefore live next to their subject:
///
/// | Module | Home |
/// |---|---|
/// | `SwiftFieldOffset`, `SwiftVTableOffset`, `SwiftMemberAddress`, `SwiftTypeLayout`, `SwiftEnumLayout` | MachOSwiftSection |
/// | `CType`, `ObjCIvarOffset` | MachOObjCSection |
///
/// They all extend this one namespace, so a consumer that imports several of
/// them still writes `Transformer.CType` and `Transformer.SwiftEnumLayout`
/// without qualification, and a settings UI can present them side by side.
public enum Transformer {}

// MARK: - Module Protocol

extension Transformer {
    /// A transformer module that converts input to output.
    ///
    /// Each module defines:
    /// - `Parameter`: Predefined parameters displayed in a settings UI for user configuration.
    /// - `Input`: Input passed by the caller at runtime.
    /// - `Output`: Output returned to the caller.
    public protocol Module: Codable, Sendable, Hashable {
        /// Predefined parameters, displayed in a settings UI for user configuration.
        associatedtype Parameter: CaseIterable & Hashable & Sendable

        /// Input passed by the caller at runtime.
        associatedtype Input

        /// Output returned to the caller.
        associatedtype Output

        /// Display name for a settings UI.
        static var displayName: String { get }

        /// Whether this module is enabled.
        var isEnabled: Bool { get set }

        /// Applies this module's transformation.
        func transform(_ input: Input) -> Output
    }
}
