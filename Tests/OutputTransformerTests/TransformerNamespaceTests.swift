import Foundation
import Testing
@testable import OutputTransformer

/// This module holds only the namespace and the `Module` protocol; every
/// concrete transformer lives with its subject matter (MachOSwiftSection for
/// the Swift ones, MachOObjCSection for the ObjC ones) and is tested there.
/// What is checked here is that the protocol is usable on its own.
@Suite("Transformer namespace")
struct TransformerNamespaceTests {
    /// A stand-in module, standing for any real conformer.
    struct DoublingModule: Transformer.Module {
        enum Parameter: CaseIterable, Hashable, Sendable {
            case factor
        }

        static let displayName = "Doubling"

        var isEnabled: Bool = false

        func transform(_ input: Int) -> Int {
            isEnabled ? input * 2 : input
        }
    }

    @Test("A module can be declared against the protocol alone")
    func moduleConformsUsingProtocolOnly() {
        var module = DoublingModule()
        #expect(DoublingModule.displayName == "Doubling")
        #expect(module.transform(21) == 21)

        module.isEnabled = true
        #expect(module.transform(21) == 42)
    }

    @Test("Module inherits Codable, Hashable and Sendable")
    func moduleInheritsRequiredConformances() throws {
        let module = DoublingModule(isEnabled: true)
        let decoded = try JSONDecoder().decode(
            DoublingModule.self,
            from: JSONEncoder().encode(module)
        )
        #expect(decoded == module)
        #expect(decoded.hashValue == module.hashValue)
    }
}
