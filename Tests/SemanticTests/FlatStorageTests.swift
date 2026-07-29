import Foundation
import Testing
@testable import Semantic

/// Tests for the flat storage: one typed atom array plus an explicit element
/// boundary table (`nil` = every atom is its own element), with composites
/// flattened eagerly on append.
///
/// The contract under test: every observable behavior — `components`,
/// `string`, equality, hashing, `Codable` output, element granularity for
/// container components — matches the historical element tree, and the
/// boundary table is only materialized when an element is not exactly one
/// atom.
@Suite("Flat Storage")
struct FlatStorageTests {
    // MARK: - Representation

    @Test("Empty init holds nothing")
    func emptyInitHoldsNothing() {
        let semanticString = SemanticString()
        #expect(semanticString._storage.atoms.isEmpty)
        #expect(semanticString._storage.elementEndOffsets == nil)
        #expect(semanticString.isEmpty)
    }

    @Test("Streamed atomic appends never materialize the boundary table")
    func streamedAppendsStayOneToOne() {
        var semanticString = SemanticString()
        semanticString.append("public", type: .keyword)
        semanticString.append(" ", type: .standard)
        semanticString.append("struct", type: .keyword)
        #expect(semanticString._storage.atoms.count == 3)
        #expect(semanticString._storage.elementEndOffsets == nil)
        #expect(semanticString.string == "public struct")
    }

    @Test("String literal init is one atom, no boundary table")
    func stringLiteralInitIsOneToOne() {
        let semanticString: SemanticString = "Hello"
        #expect(semanticString._storage.atoms.count == 1)
        #expect(semanticString._storage.elementEndOffsets == nil)
        #expect(semanticString.string == "Hello")
    }

    @Test("Init from [AtomicComponent] is one-to-one")
    func atomicComponentArrayInitIsOneToOne() {
        let semanticString = SemanticString(components: [
            AtomicComponent(string: "let", type: .keyword),
            AtomicComponent(string: " value", type: .variable),
        ])
        #expect(semanticString._storage.elementEndOffsets == nil)
        #expect(semanticString.components.count == 2)
    }

    @Test("Builder init of plain leaves is one-to-one, exactly like streaming")
    func builderInitOfLeavesIsOneToOne() {
        let semanticString = SemanticString {
            Keyword("public")
            Space()
            Keyword("struct")
        }
        #expect(semanticString._storage.atoms.count == 3)
        #expect(semanticString._storage.elementEndOffsets == nil)
        #expect(semanticString.string == "public struct")
    }

    @Test("Appending a composite records one multi-atom element")
    func compositeAppendRecordsOneElement() {
        var semanticString = SemanticString()
        semanticString.append("prefix", type: .standard)
        #expect(semanticString._storage.elementEndOffsets == nil)

        semanticString.append(Joined(separator: ", ") {
            Keyword("a")
            Keyword("b")
        })
        // "prefix" then one element covering ["a", ", ", "b"].
        #expect(semanticString._storage.elementEndOffsets == [1, 4])
        #expect(semanticString._storage.elementCount == 2)
        #expect(semanticString.string == "prefixa, b")
    }

    @Test("A composite that flattens to nothing records a zero-length element")
    func emptyCompositeRecordsZeroLengthElement() {
        var semanticString = SemanticString()
        semanticString.append("x", type: .keyword)
        semanticString.append(EmptyComponent())
        #expect(semanticString._storage.atoms.count == 1)
        #expect(semanticString._storage.elementEndOffsets == [1, 1])
        #expect(semanticString.isEmpty == false)
        #expect(semanticString.string == "x")

        // Streaming afterwards appends one-atom elements to the table.
        semanticString.append("y", type: .keyword)
        #expect(semanticString._storage.elementEndOffsets == [1, 1, 2])
        #expect(semanticString.string == "xy")
    }

    @Test("Appending a nil optional component records a zero-length element")
    func nilOptionalAppendRecordsZeroLengthElement() {
        var semanticString = SemanticString()
        semanticString.append("a", type: .keyword)
        semanticString.append(nil as Keyword?)
        semanticString.append("b", type: .keyword)
        #expect(semanticString._storage.atoms.count == 2)
        #expect(semanticString._storage.elementCount == 3)
        #expect(semanticString.string == "ab")
    }

    @Test("Appending an AtomicComponent through the generic overload stays one-to-one")
    func genericAtomicAppendStaysOneToOne() {
        var semanticString = SemanticString()
        semanticString.append(AtomicComponent(string: "x", type: .variable))
        #expect(semanticString._storage.elementEndOffsets == nil)
        #expect(semanticString.components == [AtomicComponent(string: "x", type: .variable)])
    }

    @Test("Appending a first-class leaf component stays one-to-one")
    func genericLeafComponentAppendStaysOneToOne() {
        // `Keyword` and friends flatten to exactly one `AtomicComponent`, so
        // appending one is indistinguishable from a streamed append: no
        // boundary table, no boxing, no intermediate structure retained.
        var semanticString = SemanticString()
        semanticString.append("prefix", type: .standard)
        semanticString.append(Keyword("func"))
        #expect(semanticString._storage.elementEndOffsets == nil)
        #expect(semanticString.string == "prefixfunc")
        #expect(semanticString.components.last?.type == .keyword)
    }

    @Test("A custom leaf flattening to several atoms stays one element")
    func multiAtomLeafStaysOneElement() {
        struct TwoAtomLeaf: AtomicSemanticComponent {
            var string: String { "@name" }
            var type: SemanticType { .standard }
            func buildComponents() -> [AtomicComponent] {
                [
                    AtomicComponent(string: "@", type: .keyword),
                    AtomicComponent(string: "name", type: .member(.name)),
                ]
            }
        }
        var semanticString = SemanticString()
        semanticString.append(TwoAtomLeaf())
        #expect(semanticString._storage.atoms.count == 2)
        #expect(semanticString._storage.elementEndOffsets == [2])
        #expect(semanticString._storage.elementCount == 1)
    }

    // MARK: - Append Matrix

    private func streamedString(_ text: String) -> SemanticString {
        var semanticString = SemanticString()
        semanticString.append(text, type: .standard)
        return semanticString
    }

    private func boundedString(_ text: String) -> SemanticString {
        // Give the string a materialized boundary table by appending a
        // composite element.
        var semanticString = SemanticString()
        semanticString.append(Group {
            Keyword(text)
        })
        return semanticString
    }

    @Test("Append matrix preserves component sequences across boundary-table combinations")
    func appendMatrix() {
        let combinations: [(SemanticString, SemanticString)] = [
            (streamedString("left"), streamedString("right")),
            (streamedString("left"), boundedString("right")),
            (boundedString("left"), streamedString("right")),
            (boundedString("left"), boundedString("right")),
        ]
        for (leftHandSide, rightHandSide) in combinations {
            let expectedComponents = leftHandSide.components + rightHandSide.components
            let expectedElementCount = leftHandSide._storage.elementCount + rightHandSide._storage.elementCount
            var merged = leftHandSide
            merged.append(rightHandSide)
            #expect(merged.components == expectedComponents)
            #expect(merged.string == leftHandSide.string + rightHandSide.string)
            #expect(merged._storage.elementCount == expectedElementCount)
        }
    }

    @Test("Non-mutating appending matches mutating append and leaves self untouched")
    func appendingMatchesAppend() {
        let base = streamedString("base")
        let appended = base.appending(boundedString("tail"))
        #expect(base.string == "base")
        #expect(appended.string == "basetail")

        let componentAppended = base.appending(Keyword("k"))
        #expect(componentAppended.string == "basek")
        #expect(base.components.count == 1)
    }

    // MARK: - Identifier Scopes

    @Test("Identifier stamping works on streamed appends")
    func identifierStampingOnStreamedAppends() {
        var semanticString = SemanticString()
        semanticString.pushIdentifierScope("$s7ModuleA4TypeV")
        semanticString.append("Type", type: .type(.struct, .name))
        semanticString.popIdentifierScope()
        semanticString.append(".", type: .standard)

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

    // MARK: - Container Granularity

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

    @Test("MemberList keeps one row per member when members are streamed strings")
    func memberListGranularityWithStreamedMembers() {
        // Each member is a streamed string of several atoms. MemberList
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

    @Test("Rows keeps sub-row boundaries with streamed sub-rows")
    func rowsGranularityWithStreamedSubRows() {
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

    @Test("A builder SemanticString entry is one element")
    func builderSemanticStringEntryIsOneElement() {
        let member = SemanticString {
            Keyword("var")
            Space()
            Variable("x")
        }
        let outer = SemanticString {
            member
        }
        // The nested string contributed one element covering three atoms.
        #expect(outer._storage.elementCount == 1)
        #expect(outer.components.count == 3)
    }

    // MARK: - Codable

    @Test("Decoded strings are one-to-one and re-encode byte-identically")
    func decodedStringsAreOneToOne() throws {
        let original = buildDeclarationBlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedData = try encoder.encode(original)

        let decoded = try JSONDecoder().decode(SemanticString.self, from: encodedData)
        #expect(decoded._storage.elementEndOffsets == nil)
        #expect(decoded == original)

        let reencodedData = try encoder.encode(decoded)
        #expect(reencodedData == encodedData)
    }

    // MARK: - Concurrency

    @Test("Concurrent cold-cache string reads of shared storage are consistent")
    func concurrentStringReads() async {
        // Expected values come from a separate, identical value so that the
        // shared instances under test enter the task group with a cold string
        // cache and the racing readers actually exercise the fill path.
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
