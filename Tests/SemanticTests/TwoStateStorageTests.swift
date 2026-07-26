import Foundation
import Testing
@testable import Semantic

/// Tests for the two-state (`tree` / `flat`) storage introduced to eliminate
/// per-token existential boxing, and for the `compact()` finalization API.
///
/// The contract under test: every observable behavior — `components`,
/// `string`, equality, hashing, `Codable` output, element granularity for
/// container components — is identical between the two representations, and
/// state transitions happen exactly where documented.
@Suite("Two-State Storage")
struct TwoStateStorageTests {
    // MARK: - State Transitions

    @Test("Empty init starts flat")
    func emptyInitStartsFlat() {
        let semanticString = SemanticString()
        #expect(semanticString._storage.isFlat)
        #expect(semanticString.isEmpty)
    }

    @Test("Streamed atomic appends stay flat and never box")
    func streamedAppendsStayFlat() {
        var semanticString = SemanticString()
        semanticString.append("public", type: .keyword)
        semanticString.append(" ", type: .standard)
        semanticString.append("struct", type: .keyword)
        #expect(semanticString._storage.isFlat)
        #expect(semanticString._storage.flatComponents.count == 3)
        #expect(semanticString._storage.treeElements.isEmpty)
        #expect(semanticString.string == "public struct")
    }

    @Test("String literal init is flat")
    func stringLiteralInitIsFlat() {
        let semanticString: SemanticString = "Hello"
        #expect(semanticString._storage.isFlat)
        #expect(semanticString.string == "Hello")
    }

    @Test("Init from [AtomicComponent] is flat")
    func atomicComponentArrayInitIsFlat() {
        let semanticString = SemanticString(components: [
            AtomicComponent(string: "let", type: .keyword),
            AtomicComponent(string: " value", type: .variable),
        ])
        #expect(semanticString._storage.isFlat)
        #expect(semanticString.components.count == 2)
    }

    @Test("Builder init is a tree")
    func builderInitIsTree() {
        let semanticString = SemanticString {
            Keyword("public")
            Space()
            Keyword("struct")
        }
        #expect(!semanticString._storage.isFlat)
        #expect(semanticString.string == "public struct")
    }

    @Test("Appending a composite to a flat string converts it to a tree")
    func compositeAppendConvertsToTree() {
        var semanticString = SemanticString()
        semanticString.append("prefix", type: .standard)
        #expect(semanticString._storage.isFlat)

        semanticString.append(Joined(separator: ", ") {
            Keyword("a")
            Keyword("b")
        })
        #expect(!semanticString._storage.isFlat)
        #expect(semanticString._storage.flatComponents.isEmpty)
        #expect(semanticString.string == "prefixa, b")
    }

    @Test("Appending an AtomicComponent through the generic overload stays flat")
    func genericAtomicAppendStaysFlat() {
        var semanticString = SemanticString()
        semanticString.append(AtomicComponent(string: "x", type: .variable))
        #expect(semanticString._storage.isFlat)
        #expect(semanticString.components == [AtomicComponent(string: "x", type: .variable)])
    }

    @Test("Appending a non-atomic leaf component through the generic overload converts to tree")
    func genericLeafComponentAppendConvertsToTree() {
        var semanticString = SemanticString()
        semanticString.append("prefix", type: .standard)
        semanticString.append(Keyword("func"))
        #expect(!semanticString._storage.isFlat)
        #expect(semanticString.string == "prefixfunc")
        #expect(semanticString.components.last?.type == .keyword)
    }

    // MARK: - Append Matrix

    private func flatString(_ text: String) -> SemanticString {
        var semanticString = SemanticString()
        semanticString.append(text, type: .standard)
        return semanticString
    }

    private func treeString(_ text: String) -> SemanticString {
        SemanticString {
            Keyword(text)
        }
    }

    @Test("Append matrix preserves component sequences across all state combinations")
    func appendMatrix() {
        let combinations: [(SemanticString, SemanticString)] = [
            (flatString("left"), flatString("right")),
            (flatString("left"), treeString("right")),
            (treeString("left"), flatString("right")),
            (treeString("left"), treeString("right")),
        ]
        for (leftHandSide, rightHandSide) in combinations {
            let expectedComponents = leftHandSide.components + rightHandSide.components
            var merged = leftHandSide
            merged.append(rightHandSide)
            #expect(merged.components == expectedComponents)
            #expect(merged.string == leftHandSide.string + rightHandSide.string)
        }
    }

    @Test("Non-mutating appending matches mutating append and leaves self untouched")
    func appendingMatchesAppend() {
        let base = flatString("base")
        let appended = base.appending(treeString("tail"))
        #expect(base.string == "base")
        #expect(appended.string == "basetail")

        let componentAppended = base.appending(Keyword("k"))
        #expect(componentAppended.string == "basek")
        #expect(base.components.count == 1)
    }

    // MARK: - Identifier Scopes

    @Test("Identifier stamping works on the flat fast path")
    func identifierStampingOnFlatPath() {
        var semanticString = SemanticString()
        semanticString.pushIdentifierScope("$s7ModuleA4TypeV")
        semanticString.append("Type", type: .type(.struct, .name))
        semanticString.popIdentifierScope()
        semanticString.append(".", type: .standard)

        #expect(semanticString._storage.isFlat)
        #expect(semanticString.components[0].identifier == "$s7ModuleA4TypeV")
        #expect(semanticString.components[1].identifier == nil)
    }

    @Test("appending(_:type:) never stamps identifier scopes")
    func appendingDoesNotStampIdentifiers() {
        var scoped = SemanticString()
        scoped.pushIdentifierScope("$sIdentifier")
        let result = scoped.appending("text", type: .standard)
        #expect(result.components.last?.identifier == nil)
    }

    // MARK: - Compaction

    private func buildDeclarationBlock() -> SemanticString {
        SemanticString {
            DeclarationBlock(level: 1) {
                Keyword("struct")
                Space()
                TypeDeclaration(kind: .struct, "Foo")
            } body: {
                MemberList(level: 1) {
                    SemanticString {
                        Keyword("var")
                        Space()
                        Variable("x")
                    }
                    SemanticString {
                        Keyword("var")
                        Space()
                        Variable("y")
                    }
                }
            }
        }
    }

    @Test("compact() preserves components, string, count, equality, and hash")
    func compactPreservesObservableBehavior() {
        let original = buildDeclarationBlock()
        let expectedComponents = original.components
        let expectedString = original.string

        var compacted = original
        compacted.compact()

        #expect(compacted._storage.isFlat)
        #expect(compacted.components == expectedComponents)
        #expect(compacted.string == expectedString)
        #expect(compacted.count == original.count)
        #expect(compacted == original)
        #expect(compacted.hashValue == original.hashValue)
    }

    @Test("compact() produces identical Codable output")
    func compactPreservesCodableOutput() throws {
        let original = buildDeclarationBlock()
        let compacted = original.compacted()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalData = try encoder.encode(original)
        let compactedData = try encoder.encode(compacted)
        #expect(originalData == compactedData)
    }

    @Test("compact() is idempotent and safe on empty strings")
    func compactIdempotentAndEmptySafe() {
        var empty = SemanticString()
        empty.compact()
        #expect(empty.isEmpty)
        #expect(empty._storage.isFlat)

        var compacted = buildDeclarationBlock()
        compacted.compact()
        let onceComponents = compacted.components
        compacted.compact()
        #expect(compacted.components == onceComponents)
    }

    @Test("compact() respects copy-on-write isolation")
    func compactCopyOnWriteIsolation() {
        let original = buildDeclarationBlock()
        let copyBeforeCompaction = original
        var compacted = original
        compacted.compact()

        // The copy taken before compaction keeps its tree storage.
        #expect(!copyBeforeCompaction._storage.isFlat)
        #expect(compacted._storage.isFlat)
        #expect(copyBeforeCompaction == compacted)
    }

    @Test("compact() releases the element tree")
    func compactReleasesTree() {
        var compacted = buildDeclarationBlock()
        compacted.compact()
        #expect(compacted._storage.treeElements.isEmpty)
        #expect(compacted._storage.cachedComponents == nil)
        #expect(compacted._storage.flatComponents.count == compacted.components.count)
    }

    @Test("Appends still work after compact()")
    func appendAfterCompact() {
        var semanticString = buildDeclarationBlock()
        let stringBeforeAppend = semanticString.string
        semanticString.compact()

        semanticString.append("\n", type: .standard)
        #expect(semanticString._storage.isFlat)
        #expect(semanticString.string == stringBeforeAppend + "\n")

        semanticString.append(Joined(separator: " ") {
            Keyword("extension")
            Keyword("Foo")
        })
        #expect(!semanticString._storage.isFlat)
        #expect(semanticString.string == stringBeforeAppend + "\nextension Foo")
    }

    @Test("Post-compaction elements view is per-atom")
    func compactedElementsViewIsPerAtom() {
        var compacted = buildDeclarationBlock()
        compacted.compact()
        #expect(compacted.elements.count == compacted.components.count)
    }

    // MARK: - Container Granularity (the regression this design must not cause)

    @Test("MemberList keeps one row per member when members are flat strings")
    func memberListGranularityWithFlatMembers() {
        // Each member is a streamed (flat) string of several atoms. MemberList
        // must treat each member as ONE row — not one row per atom.
        var firstMember = SemanticString()
        firstMember.append("var", type: .keyword)
        firstMember.append(" x: Int", type: .standard)
        var secondMember = SemanticString()
        secondMember.append("var", type: .keyword)
        secondMember.append(" y: Int", type: .standard)

        let list = SemanticString {
            MemberList(level: 1) {
                firstMember
                secondMember
            }
        }
        #expect(list.string == "\n    var x: Int\n    var y: Int\n")
    }

    @Test("Rows keeps sub-row boundaries with flat sub-rows")
    func rowsGranularityWithFlatSubRows() {
        var annotation = SemanticString()
        annotation.append("// offset: 0x10", type: .comment)
        var declaration = SemanticString()
        declaration.append("var", type: .keyword)
        declaration.append(" x: Int", type: .standard)

        let list = SemanticString {
            MemberList(level: 1) {
                Rows(level: 1) {
                    annotation
                    declaration
                }
            }
        }
        #expect(list.string == "\n    // offset: 0x10\n    var x: Int\n")
    }

    // MARK: - Codable

    @Test("Decoded strings are flat and re-encode byte-identically")
    func decodedStringsAreFlat() throws {
        let original = buildDeclarationBlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedData = try encoder.encode(original)

        let decoded = try JSONDecoder().decode(SemanticString.self, from: encodedData)
        #expect(decoded._storage.isFlat)
        #expect(decoded == original)

        let reencodedData = try encoder.encode(decoded)
        #expect(reencodedData == encodedData)
    }

    // MARK: - Concurrency

    @Test("Concurrent cold-cache flattening of shared tree storage is consistent")
    func concurrentFlattening() async {
        // Expected values come from a separate, identical tree so that the
        // shared instances under test enter the task group with a cold cache
        // and the racing readers actually exercise the fill path.
        let reference = buildDeclarationBlock()
        let expectedComponents = reference.components
        let expectedString = reference.string

        for _ in 0 ..< 16 {
            let shared = buildDeclarationBlock()
            await withTaskGroup(of: Bool.self) { group in
                for readerIndex in 0 ..< 8 {
                    group.addTask {
                        if readerIndex.isMultiple(of: 2) {
                            return shared.components == expectedComponents
                        } else {
                            return shared.string == expectedString
                        }
                    }
                }
                for await isConsistent in group {
                    #expect(isConsistent)
                }
            }
        }
    }
}
