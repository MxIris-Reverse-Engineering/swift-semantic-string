import Foundation
import Testing
@testable import Semantic

/// Behaviors that must hold regardless of how `SemanticString` stores its
/// contents internally.
///
/// Every test here uses only public API that has existed across every storage
/// design this library has had — the boxed element tree, the two-state
/// flat/tree storage, and the current flat atoms + boundary table — so the
/// same file compiles and runs against any revision. That makes the suite a
/// differential harness: a test that fails only after a storage change is a
/// regression, a test that fails on both sides is a pre-existing
/// inconsistency.
///
/// The invariants under test: content and granularity are unchanged by how a
/// value was assembled (streamed, built, spliced), and the long-standing rule
/// recorded in AGENTS.md — "Empty strings are filtered at the atomic level".
@Suite("Storage Divergence Regressions")
struct StorageDivergenceRegressionTests {
    // MARK: - Helpers

    /// A string assembled the way a printer assembles one: streamed atomic
    /// appends, no result builder.
    private func streamedString(_ atomicComponents: [AtomicComponent]) -> SemanticString {
        var semanticString = SemanticString()
        for atomicComponent in atomicComponents {
            semanticString.append(atomicComponent)
        }
        return semanticString
    }

    // MARK: - Zero-Length Atoms Must Not Survive Flattening

    @Test("A streamed zero-length atom does not survive flattening")
    func streamedZeroLengthAtomIsFiltered() {
        let semanticString = streamedString([
            AtomicComponent(string: "a", type: .standard),
            AtomicComponent(string: "", type: .keyword),
            AtomicComponent(string: "b", type: .standard),
        ])

        #expect(semanticString.components.map(\.string) == ["a", "b"])
        #expect(semanticString.count == 2)
        #expect(semanticString.string == "ab")
    }

    @Test("Appending a string that holds a zero-length atom does not import it")
    func appendedZeroLengthAtomIsFiltered() {
        var head = SemanticString()
        head.append("h", type: .standard)

        let tail = streamedString([
            AtomicComponent(string: "", type: .keyword),
            AtomicComponent(string: "z", type: .standard),
        ])
        head.append(tail)

        #expect(head.components.map(\.string) == ["h", "z"])
        #expect(head.count == 2)
    }

    @Test("Equality ignores zero-length atoms on both construction paths")
    func equalityIgnoresZeroLengthAtoms() {
        let withZeroLengthAtom = streamedString([
            AtomicComponent(string: "value", type: .variable),
            AtomicComponent(string: "", type: .keyword),
        ])
        let withoutZeroLengthAtom = streamedString([
            AtomicComponent(string: "value", type: .variable),
        ])

        #expect(withZeroLengthAtom == withoutZeroLengthAtom)
        #expect(withZeroLengthAtom.hashValue == withoutZeroLengthAtom.hashValue)
    }

    @Test("A string holding nothing but a zero-length atom flattens to nothing")
    func zeroLengthOnlyStringFlattensToNothing() {
        let semanticString = streamedString([AtomicComponent(string: "", type: .keyword)])

        #expect(semanticString.count == 0)
        #expect(semanticString.buildComponents().isEmpty)
        #expect(semanticString == SemanticString())
    }

    // MARK: - Container Layout Must Not Gain Blank Rows

    @Test("MemberList skips a member that flattens to nothing")
    func memberListSkipsMemberThatFlattensToNothing() {
        // A member that a printer emitted but that produced no text: e.g. an
        // annotation whose body turned out to be empty.
        let blankMember = streamedString([AtomicComponent(string: "", type: .standard)])
        let realMember = SemanticString {
            Keyword("var")
            Space()
            Variable("x")
        }

        let rendered = SemanticString {
            MemberList(level: 1) {
                blankMember
                realMember
            }
        }

        #expect(rendered.string == "\n    var x\n")
    }

    @Test("Joined drops an item that flattens to nothing instead of emitting a separator for it")
    func joinedDropsItemThatFlattensToNothing() {
        let blankItem = streamedString([AtomicComponent(string: "", type: .standard)])
        let firstRealItem = streamedString([AtomicComponent(string: "Int", type: .type(.struct, .name))])
        let secondRealItem = streamedString([AtomicComponent(string: "String", type: .type(.struct, .name))])

        let rendered = SemanticString {
            Joined(separator: ", ") {
                firstRealItem
                blankItem
                secondRealItem
            }
        }

        #expect(rendered.string == "Int, String")
    }

    // MARK: - The Two Array-Backed Construction Paths Must Agree

    @Test("init(components: [AtomicComponent]) and init(components: [any SemanticStringComponent]) agree")
    func arrayBackedConstructionPathsAgree() {
        let atomicComponents = [
            AtomicComponent(string: "a", type: .standard),
            AtomicComponent(string: "", type: .keyword),
            AtomicComponent(string: "b", type: .standard),
        ]

        let fromAtomicArray = SemanticString(components: atomicComponents)
        let fromExistentialArray = SemanticString(components: atomicComponents.map { $0 as any SemanticStringComponent })

        #expect(fromAtomicArray.components == fromExistentialArray.components)
        #expect(fromAtomicArray == fromExistentialArray)
        #expect(fromAtomicArray.count == fromExistentialArray.count)
    }

    @Test("Flattening is stable across an unrelated mutation")
    func flatteningIsStableAcrossUnrelatedMutation() {
        // Reading `components` before and after appending unrelated content
        // must not change how the *existing* content flattens. On storage that
        // pre-caches an unfiltered array and then recomputes a filtered one on
        // invalidation, it does.
        var semanticString = SemanticString(components: [
            AtomicComponent(string: "a", type: .standard),
            AtomicComponent(string: "", type: .keyword),
        ])
        let componentsBeforeMutation = semanticString.components

        semanticString.append("c", type: .standard)
        let componentsAfterMutation = semanticString.components

        #expect(Array(componentsAfterMutation.dropLast()) == componentsBeforeMutation)
    }
}
