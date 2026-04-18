import Testing
import Foundation
@testable import Semantic

// MARK: - Golden Master Tests
//
// These tests lock down the exact string output and component structure of
// complex compositions against the current implementation. Hardcoded strings
// were captured from current HEAD — changes here mean a behavioral change
// needs explicit review, not a silent regression.

@Suite("Golden Master")
struct GoldenMasterTests {
    @Test("DeclarationBlock level 1 with heterogeneous MemberList")
    func declarationBlockWithMemberList() {
        let semanticString = SemanticString {
            DeclarationBlock(level: 1) {
                Keyword("struct")
                Space()
                TypeDeclaration(kind: .struct, "Foo")
            } body: {
                MemberList(level: 1) {
                    Comment("a helpful note")
                    SemanticString {
                        Keyword("var")
                        Space()
                        Variable("count")
                        Standard(": ")
                        TypeName(kind: .struct, "Int")
                    }
                    SemanticString {
                        Keyword("func")
                        Space()
                        FunctionDeclaration("doWork")
                        Standard("()")
                    }
                    NestedDeclaration {
                        DeclarationBlock(level: 2) {
                            Keyword("struct")
                            Space()
                            TypeDeclaration(kind: .struct, "Inner")
                        } body: {
                            MemberList(level: 2) {
                                SemanticString {
                                    Keyword("var")
                                    Space()
                                    Variable("y")
                                    Standard(": ")
                                    TypeName(kind: .struct, "Int")
                                }
                            }
                        }
                    }
                    BreakLine()
                }
            }
        }

        let expectedString = "struct Foo {\n    // a helpful note\n    var count: Int\n    func doWork()\n    \n    struct Inner {\n        var y: Int\n    }\n    \n\n}"
        #expect(semanticString.string == expectedString)
        #expect(semanticString.components.count == 45)

        // Spot-check selected components and types
        let components = semanticString.components
        #expect(components[0].string == "struct")
        #expect(components[0].type == .keyword)
        #expect(components[2].string == "Foo")
        #expect(components[2].type == .type(.struct, .declaration))
        #expect(components[7].string == "// a helpful note")
        #expect(components[7].type == .comment)
        #expect(components[12].string == "count")
        #expect(components[12].type == .variable)
        #expect(components[19].string == "doWork")
        #expect(components[19].type == .function(.declaration))
        #expect(components[25].string == "struct")
        #expect(components[25].type == .keyword)
        #expect(components[27].string == "Inner")
        #expect(components[27].type == .type(.struct, .declaration))
        #expect(components[34].string == "y")
        #expect(components[34].type == .variable)
        #expect(components[44].string == "}")
        #expect(components[44].type == .standard)
    }

    @Test("BlockList of three protocol declarations separated by empty line")
    func blockListOfProtocols() {
        let protocolOne = DeclarationBlock(level: 0) {
            Keyword("protocol")
            Space()
            TypeDeclaration(kind: .protocol, "Foo")
        } body: {
            MemberList(level: 1) {
                SemanticString {
                    Keyword("func")
                    Space()
                    FunctionDeclaration("fooMethod")
                    Standard("()")
                }
            }
        }
        let protocolTwo = DeclarationBlock(level: 0) {
            Keyword("protocol")
            Space()
            TypeDeclaration(kind: .protocol, "Bar")
        } body: {
            MemberList(level: 1) {
                SemanticString {
                    Keyword("func")
                    Space()
                    FunctionDeclaration("barMethod")
                    Standard("()")
                }
            }
        }
        let protocolThree = DeclarationBlock(level: 0) {
            Keyword("protocol")
            Space()
            TypeDeclaration(kind: .protocol, "Baz")
        } body: {
            MemberList(level: 1) {
                SemanticString {
                    Keyword("func")
                    Space()
                    FunctionDeclaration("bazMethod")
                    Standard("()")
                }
            }
        }
        let semanticString = SemanticString {
            BlockList {
                protocolOne
                protocolTwo
                protocolThree
            }
            .separatedByEmptyLine()
        }

        let expectedString = "\nprotocol Foo {\n    func fooMethod()\n}\n\nprotocol Bar {\n    func barMethod()\n}\n\nprotocol Baz {\n    func bazMethod()\n}\n"
        #expect(semanticString.string == expectedString)

        // Spot-check: verify the count is stable at 45.
        #expect(semanticString.components.count == 45)

        let components = semanticString.components
        // First break from BlockList
        #expect(components[0].string == "\n")
        #expect(components[0].type == .standard)
        // protocol keyword
        #expect(components[1].string == "protocol")
        #expect(components[1].type == .keyword)
        // Foo type declaration
        #expect(components[3].string == "Foo")
        #expect(components[3].type == .type(.protocol, .declaration))
        // Last component is trailing newline
        #expect(components.last?.string == "\n")
    }

    @Test("Joined with builder-form prefix and suffix, mixed empty and non-empty items")
    func joinedBuilderPrefixSuffixMixed() {
        let joined = Joined(separator: ", ") {
            Standard("apple")
            Standard("")
            Standard("banana")
            Standard("")
            Standard("cherry")
        } prefix: {
            Standard("[")
            Keyword("items")
            Standard(": ")
        } suffix: {
            Standard("]")
            Space()
            Comment("done")
        }

        let built = joined.buildComponents()
        let resultString = built.map(\.string).joined()

        let expectedString = "[items: apple, banana, cherry] // done"
        #expect(resultString == expectedString)
        #expect(built.count == 11)

        // Spot-check structure
        #expect(built[0].string == "[")
        #expect(built[0].type == .standard)
        #expect(built[1].string == "items")
        #expect(built[1].type == .keyword)
        #expect(built[2].string == ": ")
        #expect(built[3].string == "apple")
        #expect(built[4].string == ", ")
        #expect(built[5].string == "banana")
        #expect(built[6].string == ", ")
        #expect(built[7].string == "cherry")
        #expect(built[8].string == "]")
        #expect(built[9].string == " ")
        #expect(built[10].string == "// done")
        #expect(built[10].type == .comment)
    }

    @Test("Tuple-heavy builder with arrays and optionals interleaved")
    func tupleHeavyBuilder() {
        let optionalKeyword: Keyword? = Keyword("override")
        let nilKeyword: Keyword? = nil
        let items: [any SemanticStringComponent] = [Keyword("final"), Space()]

        let semanticString = SemanticString {
            Keyword("public")
            Space()
            optionalKeyword
            Space()
            nilKeyword
            items
            Keyword("func")
            Space()
            FunctionDeclaration("apply")
            Standard("(")
            Joined(separator: ", ") {
                Standard("x: Int")
                Standard("y: Int")
            }
            Standard(")")
        }

        let expectedString = "public override final func apply(x: Int, y: Int)"
        #expect(semanticString.string == expectedString)
        #expect(semanticString.components.count == 14)

        let components = semanticString.components
        #expect(components[0].string == "public")
        #expect(components[0].type == .keyword)
        #expect(components[2].string == "override")
        #expect(components[2].type == .keyword)
        #expect(components[4].string == "final")
        #expect(components[4].type == .keyword)
        #expect(components[6].string == "func")
        #expect(components[8].string == "apply")
        #expect(components[8].type == .function(.declaration))
        #expect(components[9].string == "(")
        #expect(components[10].string == "x: Int")
        #expect(components[11].string == ", ")
        #expect(components[12].string == "y: Int")
        #expect(components[13].string == ")")
    }
}

// MARK: - Indent All Levels

@Suite("Indent All Levels")
struct IndentAllLevelsTests {
    @Test("Indent string matches 4 spaces per level for levels 0 through 20")
    func indentStringAcrossLevels() {
        for level in 0...20 {
            let indent = Indent(level: level)
            let expectedString = String(repeating: " ", count: level * 4)
            #expect(indent.string == expectedString, "Indent(level: \(level)).string mismatch")
        }
    }

    @Test("Indent level 0 buildComponents returns empty array")
    func indentLevelZeroBuildComponents() {
        let indent = Indent(level: 0)
        let components = indent.buildComponents()
        // Current behavior: Indent(level: 0).string == "" which filters via
        // AtomicSemanticComponent.buildComponents() empty-string check, yielding [].
        #expect(components.isEmpty)
    }

    @Test("Indent buildComponents for levels 1 through 20 produces single atomic component")
    func indentPositiveLevelsBuildComponents() {
        for level in 1...20 {
            let indent = Indent(level: level)
            let components = indent.buildComponents()
            #expect(components.count == 1, "Indent(level: \(level)).buildComponents() should have one element")
            #expect(components[0].string == String(repeating: " ", count: level * 4), "Indent(level: \(level)) string mismatch")
            #expect(components[0].type == .standard, "Indent(level: \(level)) type should be .standard")
        }
    }
}

// MARK: - Joined Ordering

@Suite("Joined Ordering")
struct JoinedOrderingTests {
    @Test("Joined prefix-only with non-empty content")
    func joinedPrefixOnly() {
        let joined = Joined(separator: ", ", prefix: "<", suffix: nil) {
            Standard("a")
            Standard("b")
        }
        let result = joined.buildComponents().map(\.string).joined()
        #expect(result == "<a, b")
    }

    @Test("Joined suffix-only with non-empty content")
    func joinedSuffixOnly() {
        let joined = Joined(separator: ", ", prefix: nil, suffix: ">") {
            Standard("a")
            Standard("b")
        }
        let result = joined.buildComponents().map(\.string).joined()
        #expect(result == "a, b>")
    }

    @Test("Joined with both prefix and suffix")
    func joinedBothPrefixSuffix() {
        let joined = Joined(separator: ", ", prefix: "[", suffix: "]") {
            Standard("a")
            Standard("b")
        }
        let result = joined.buildComponents().map(\.string).joined()
        #expect(result == "[a, b]")
    }

    @Test("Joined with neither prefix nor suffix")
    func joinedNeitherPrefixSuffix() {
        let joined = Joined(separator: ", ") {
            Standard("a")
            Standard("b")
        }
        let result = joined.buildComponents().map(\.string).joined()
        #expect(result == "a, b")
    }

    @Test("Joined with string separator produces single separator component between items")
    func joinedStringSeparator() {
        let joined = Joined(separator: " | ") {
            Standard("x")
            Standard("y")
            Standard("z")
        }
        let components = joined.buildComponents()
        #expect(components.count == 5)
        #expect(components[0].string == "x")
        #expect(components[1].string == " | ")
        #expect(components[1].type == .standard)
        #expect(components[2].string == "y")
        #expect(components[3].string == " | ")
        #expect(components[4].string == "z")
    }

    @Test("Joined with component separator propagates component type")
    func joinedComponentSeparator() {
        let joined = Joined(separator: Keyword("&")) {
            Standard("a")
            Standard("b")
        }
        let components = joined.buildComponents()
        #expect(components.count == 3)
        #expect(components[0].string == "a")
        #expect(components[1].string == "&")
        #expect(components[1].type == .keyword)
        #expect(components[2].string == "b")
    }

    @Test("Joined with all empty items returns empty components array")
    func joinedAllEmpty() {
        let joined = Joined(separator: ", ", prefix: "(", suffix: ")") {
            Standard("")
            Standard("")
            Standard("")
        }
        #expect(joined.buildComponents().isEmpty)
    }

    @Test("Joined with single non-empty item emits no separator")
    func joinedSingleNonEmptyItem() {
        let joined = Joined(separator: ", ") {
            Standard("only")
        }
        let components = joined.buildComponents()
        #expect(components.count == 1)
        #expect(components[0].string == "only")
    }

    @Test("Joined separator appears only between non-empty items")
    func joinedSeparatorBetweenNonEmpty() {
        let joined = Joined(separator: ", ") {
            Standard("a")
            Standard("")
            Standard("b")
            Standard("")
            Standard("c")
        }
        let components = joined.buildComponents()
        // Expect: a, sep, b, sep, c  — 5 components
        #expect(components.count == 5)
        #expect(components[0].string == "a")
        #expect(components[1].string == ", ")
        #expect(components[2].string == "b")
        #expect(components[3].string == ", ")
        #expect(components[4].string == "c")
    }

    @Test("Joined with single non-empty preserves prefix and suffix")
    func joinedSingleItemWithPrefixSuffix() {
        let joined = Joined(separator: ", ", prefix: "<", suffix: ">") {
            Standard("only")
        }
        let components = joined.buildComponents()
        #expect(components.count == 3)
        #expect(components[0].string == "<")
        #expect(components[1].string == "only")
        #expect(components[2].string == ">")
    }
}

// MARK: - Flatten Order

@Suite("Flatten Order")
struct FlattenOrderTests {
    @Test("Mixed Group/Joined/ForEach/BlockList/MemberList/NestedDeclaration flatten order")
    func mixedComposition() {
        let items = ["a", "b"]
        let semanticString = SemanticString {
            Group {
                Joined(separator: ", ") {
                    ForEach(items) { item in
                        BlockList {
                            MemberList(level: 1) {
                                NestedDeclaration {
                                    Keyword("nested")
                                    Space()
                                    Standard(item)
                                }
                            }
                        }
                    }
                }
            }
        }

        // Manually construct the expected atomic component sequence. The Joined
        // and Group each wrap a single ForEach item; the ForEach produces two
        // full BlockLists concatenated. Each BlockList -> MemberList ->
        // NestedDeclaration produces: [\n (BlockList break), \n (MemberList
        // break), "    " (MemberList indent), \n (NestedDeclaration break),
        // Keyword, Space, Standard(item), \n (MemberList trailing), \n
        // (BlockList trailing)].
        let expectedComponents: [AtomicComponent] = [
            // First iteration (item "a")
            AtomicComponent(string: "\n", type: .standard),
            AtomicComponent(string: "\n", type: .standard),
            AtomicComponent(string: "    ", type: .standard),
            AtomicComponent(string: "\n", type: .standard),
            AtomicComponent(string: "nested", type: .keyword),
            AtomicComponent(string: " ", type: .standard),
            AtomicComponent(string: "a", type: .standard),
            AtomicComponent(string: "\n", type: .standard),
            AtomicComponent(string: "\n", type: .standard),
            // Second iteration (item "b")
            AtomicComponent(string: "\n", type: .standard),
            AtomicComponent(string: "\n", type: .standard),
            AtomicComponent(string: "    ", type: .standard),
            AtomicComponent(string: "\n", type: .standard),
            AtomicComponent(string: "nested", type: .keyword),
            AtomicComponent(string: " ", type: .standard),
            AtomicComponent(string: "b", type: .standard),
            AtomicComponent(string: "\n", type: .standard),
            AtomicComponent(string: "\n", type: .standard),
        ]

        #expect(semanticString.components == expectedComponents)
        #expect(semanticString.string == "\n\n    \nnested a\n\n\n\n    \nnested b\n\n")
    }
}

// MARK: - Cache Coherence

@Suite("Cache Coherence")
struct CacheCoherenceTests {
    @Test("Reading string twice returns identical results")
    func stringReadTwice() {
        let semanticString = SemanticString {
            Keyword("let")
            Space()
            Variable("count")
            Standard(" = ")
            Numeric("42")
        }
        let firstString = semanticString.string
        let secondString = semanticString.string
        #expect(firstString == secondString)
        #expect(firstString == "let count = 42")
    }

    @Test("Reading components twice returns identical results")
    func componentsReadTwice() {
        let semanticString = SemanticString {
            Keyword("var")
            Space()
            Variable("x")
        }
        let firstComponents = semanticString.components
        let secondComponents = semanticString.components
        #expect(firstComponents == secondComponents)
        #expect(firstComponents.count == 3)
    }

    @Test("Cache is invalidated after append(_:type:)")
    func cacheInvalidatedAfterAppendStringType() {
        var semanticString = SemanticString {
            Keyword("let")
        }
        let preString = semanticString.string
        let preComponents = semanticString.components
        #expect(preString == "let")
        #expect(preComponents.count == 1)

        semanticString.append(" x", type: .standard)

        // Explicitly assert internal cache was cleared so that a future bug
        // removing invalidateCache() cannot be masked by coincidence.
        #expect(semanticString._storage.cachedString == nil)
        #expect(semanticString._storage.cachedComponents == nil)

        let postString = semanticString.string
        let postComponents = semanticString.components
        #expect(postString == "let x")
        #expect(postString != preString)
        #expect(postComponents.count == 2)
        #expect(postComponents != preComponents)
    }

    @Test("Cache is invalidated after append(_: SemanticStringComponent)")
    func cacheInvalidatedAfterAppendComponent() {
        var semanticString = SemanticString {
            Keyword("var")
        }
        let preString = semanticString.string
        let preComponents = semanticString.components

        semanticString.append(Variable("y"))

        // Explicitly assert internal cache was cleared.
        #expect(semanticString._storage.cachedString == nil)
        #expect(semanticString._storage.cachedComponents == nil)

        let postString = semanticString.string
        let postComponents = semanticString.components
        #expect(postString == "vary")
        #expect(postString != preString)
        #expect(postComponents.count == preComponents.count + 1)
    }

    @Test("Cache is invalidated after append(_: SemanticString)")
    func cacheInvalidatedAfterAppendSemanticString() {
        var semanticString = SemanticString {
            Keyword("start")
        }
        let preString = semanticString.string
        let preComponents = semanticString.components

        semanticString.append(SemanticString {
            Space()
            Keyword("end")
        })

        // Explicitly assert internal cache was cleared.
        #expect(semanticString._storage.cachedString == nil)
        #expect(semanticString._storage.cachedComponents == nil)

        let postString = semanticString.string
        let postComponents = semanticString.components
        #expect(postString == "start end")
        #expect(postString != preString)
        #expect(postComponents.count > preComponents.count)
    }

    @Test("Cache is invalidated after += with SemanticString")
    func cacheInvalidatedAfterPlusEqualsSemanticString() {
        var semanticString = SemanticString {
            Keyword("lhs")
        }
        let preString = semanticString.string
        let preComponents = semanticString.components
        #expect(preString == "lhs")
        #expect(preComponents.count == 1)

        semanticString += SemanticString {
            Space()
            Keyword("rhs")
        }

        // Explicitly assert internal cache was cleared.
        #expect(semanticString._storage.cachedString == nil)
        #expect(semanticString._storage.cachedComponents == nil)

        let postString = semanticString.string
        let postComponents = semanticString.components
        #expect(postString == "lhs rhs")
        #expect(postString != preString)
        #expect(postComponents.count > preComponents.count)
    }

    @Test("Cache is invalidated after write(_:)")
    func cacheInvalidatedAfterWrite() {
        var semanticString = SemanticString {
            Keyword("initial")
        }
        let preString = semanticString.string
        let preComponents = semanticString.components
        #expect(preString == "initial")
        #expect(preComponents.count == 1)

        semanticString.write(" next")

        // Explicitly assert internal cache was cleared.
        #expect(semanticString._storage.cachedString == nil)
        #expect(semanticString._storage.cachedComponents == nil)

        let postString = semanticString.string
        let postComponents = semanticString.components
        #expect(postString == "initial next")
        #expect(postString != preString)
        #expect(postComponents.count == preComponents.count + 1)
    }
}

// MARK: - Copy-on-Write Semantics

@Suite("COW Semantics")
struct COWSemanticsTests {
    @Test("append(_:type:) does not mutate original")
    func appendStringTypeDoesNotMutate() {
        let original = SemanticString(Keyword("original"))
        var copy = original
        copy.append(" added", type: .standard)
        #expect(original.string == "original")
        #expect(original.components.count == 1)
        #expect(copy.string == "original added")
    }

    @Test("append(_: some SemanticStringComponent) does not mutate original")
    func appendComponentDoesNotMutate() {
        let original = SemanticString(Keyword("base"))
        var copy = original
        copy.append(Standard(" extra"))
        #expect(original.string == "base")
        #expect(original.components.count == 1)
        #expect(copy.string == "base extra")
    }

    @Test("append(_: SemanticString) does not mutate original")
    func appendSemanticStringDoesNotMutate() {
        let original = SemanticString(Keyword("base"))
        var copy = original
        copy.append(SemanticString {
            Space()
            Keyword("add")
        })
        #expect(original.string == "base")
        #expect(original.components.count == 1)
        #expect(copy.string == "base add")
    }

    @Test("+= with SemanticString does not mutate original")
    func plusEqualsSemanticStringDoesNotMutate() {
        let original = SemanticString(Keyword("lhs"))
        var copy = original
        copy += SemanticString(Standard(" rhs"))
        #expect(original.string == "lhs")
        #expect(original.components.count == 1)
        #expect(copy.string == "lhs rhs")
    }

    @Test("+= with SemanticStringComponent does not mutate original")
    func plusEqualsComponentDoesNotMutate() {
        let original = SemanticString(Keyword("lhs"))
        var copy = original
        copy += Standard(" side")
        #expect(original.string == "lhs")
        #expect(original.components.count == 1)
        #expect(copy.string == "lhs side")
    }

    @Test("write(_:) does not mutate original")
    func writeDoesNotMutate() {
        let original = SemanticString(Keyword("initial"))
        var copy = original
        copy.write(" next")
        #expect(original.string == "initial")
        #expect(original.components.count == 1)
        #expect(copy.string == "initial next")
    }

    @Test("write(_:type:) does not mutate original")
    func writeWithTypeDoesNotMutate() {
        let original = SemanticString(Keyword("initial"))
        var copy = original
        copy.write("typed", type: .variable)
        #expect(original.string == "initial")
        #expect(original.components.count == 1)
        #expect(copy.string == "initialtyped")
    }
}

// MARK: - Codable Round-trip Deep Equal

@Suite("Codable Round-trip Deep Equal")
struct CodableRoundTripTests {
    @Test("Complex construction round-trips with element-wise component equality")
    func complexRoundTrip() throws {
        let original = SemanticString {
            DeclarationBlock(level: 1) {
                Keyword("public")
                Space()
                Keyword("struct")
                Space()
                TypeDeclaration(kind: .struct, "Foo")
            } body: {
                MemberList(level: 1) {
                    Comment("note")
                    SemanticString {
                        Keyword("var")
                        Space()
                        Variable("x")
                        Standard(": ")
                        TypeName(kind: .struct, "Int")
                    }
                    NestedDeclaration {
                        DeclarationBlock(level: 2) {
                            Keyword("enum")
                            Space()
                            TypeDeclaration(kind: .enum, "Bar")
                        } body: {
                            MemberList(level: 2) {
                                SemanticString {
                                    Keyword("case")
                                    Space()
                                    MemberDeclaration("one")
                                }
                            }
                        }
                    }
                }
            }
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SemanticString.self, from: data)

        #expect(decoded.components.count == original.components.count)
        #expect(decoded.string == original.string)

        for (decodedComponent, originalComponent) in zip(decoded.components, original.components) {
            #expect(decodedComponent == originalComponent)
            #expect(decodedComponent.string == originalComponent.string)
            #expect(decodedComponent.type == originalComponent.type)
        }
    }
}

// MARK: - Hashable Invariants

@Suite("Hashable Invariants")
struct HashableInvariantsTests {
    @Test("Same builder invoked twice produces equal and equal-hashing SemanticStrings")
    func sameBuilderTwice() {
        func build() -> SemanticString {
            SemanticString {
                Keyword("public")
                Space()
                Keyword("func")
                Space()
                FunctionDeclaration("run")
                Standard("()")
            }
        }
        let first = build()
        let second = build()
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
    }

    @Test("Same semantic content via different construction paths compares equal and hashes equally")
    func differentConstructionPathsEqual() {
        // Path A: built from builder
        let builderVariant = SemanticString {
            Keyword("let")
            Space()
            Variable("x")
        }

        // Path B: built from explicit atomic components
        let atomicComponents: [AtomicComponent] = [
            AtomicComponent(string: "let", type: .keyword),
            AtomicComponent(string: " ", type: .standard),
            AtomicComponent(string: "x", type: .variable),
        ]
        let atomicVariant = SemanticString(components: atomicComponents)

        #expect(builderVariant == atomicVariant)
        #expect(builderVariant.hashValue == atomicVariant.hashValue)
        #expect(builderVariant.components == atomicVariant.components)

        // Path C: two builder-built SemanticStrings composed via appending.
        // This path is most likely to drift when the `SemanticString.components`
        // getter is rewritten, so it's called out explicitly.
        let firstHalf = SemanticString {
            Keyword("let")
            Space()
        }
        let secondHalf = SemanticString {
            Variable("x")
        }
        let appendedVariant = firstHalf.appending(secondHalf)

        #expect(builderVariant == appendedVariant)
        #expect(builderVariant.hashValue == appendedVariant.hashValue)
        #expect(appendedVariant.string == "let x")
    }
}

// MARK: - Empty & Boundary

@Suite("Empty & Boundary")
struct EmptyBoundaryTests {
    @Test("Empty builder produces empty SemanticString")
    func emptyBuilder() {
        let semanticString = SemanticString {}
        #expect(semanticString.isEmpty)
        #expect(semanticString.string == "")
        #expect(semanticString.components.isEmpty)
    }

    @Test("Empty Joined (no items) produces empty result")
    func emptyJoined() {
        let joined = Joined(separator: ", ") {}
        #expect(joined.buildComponents().isEmpty)
    }

    @Test("All children Standard(empty) produces empty result")
    func allStandardEmpty() {
        let semanticString = SemanticString {
            Standard("")
            Standard("")
            Standard("")
        }
        // Empty Standard components are filtered at the atomic layer, so
        // flattened output is empty.
        #expect(semanticString.components.isEmpty)
        #expect(semanticString.string == "")
    }

    @Test("Single-element collections")
    func singleElementCollections() {
        let single = ["only"]
        let forEach = ForEach(single) { item in
            Standard(item)
        }
        #expect(forEach.buildComponents().map(\.string) == ["only"])

        let blockList = BlockList {
            Standard("only")
        }
        #expect(blockList.buildComponents().map(\.string) == ["\n", "only", "\n"])

        let memberList = MemberList(level: 1) {
            Standard("only")
        }
        #expect(memberList.buildComponents().map(\.string) == ["\n", "    ", "only", "\n"])

        let joined = Joined(separator: ", ") {
            Standard("only")
        }
        #expect(joined.buildComponents().map(\.string) == ["only"])
    }

    @Test("Indent level 0 is filtered")
    func indentLevelZero() {
        let indent = Indent(level: 0)
        #expect(indent.string == "")
        #expect(indent.buildComponents().isEmpty)

        // Indent(level: 0) in a builder should contribute nothing.
        let semanticString = SemanticString {
            Standard("before")
            Indent(level: 0)
            Standard("after")
        }
        #expect(semanticString.string == "beforeafter")
        #expect(semanticString.components.count == 2)
    }

    @Test("Space() within various contexts")
    func spaceInVariousContexts() {
        // At the start
        let leading = SemanticString {
            Space()
            Keyword("after")
        }
        #expect(leading.string == " after")
        #expect(leading.components.count == 2)

        // At the end
        let trailing = SemanticString {
            Keyword("before")
            Space()
        }
        #expect(trailing.string == "before ")
        #expect(trailing.components.count == 2)

        // Between two elements
        let middle = SemanticString {
            Keyword("a")
            Space()
            Keyword("b")
        }
        #expect(middle.string == "a b")
        #expect(middle.components.count == 3)

        // Consecutive
        let consecutive = SemanticString {
            Space()
            Space()
            Space()
        }
        #expect(consecutive.string == "   ")
        #expect(consecutive.components.count == 3)

        // Inside a Joined
        let inJoined = Joined(separator: Space()) {
            Keyword("x")
            Keyword("y")
        }
        let builtInJoined = inJoined.buildComponents()
        #expect(builtInJoined.map(\.string).joined() == "x y")
        #expect(builtInJoined.count == 3)
    }

    @Test("Multi-byte UTF-8 content round-trips through SemanticString.string")
    func multiByteUTF8Content() {
        // Covers any future optimization that pre-reserves capacity using
        // `utf8.count`. If byte count and character count are ever confused,
        // the grinning-face emoji (4 bytes), CJK (3 bytes each), and combining
        // acute-accent variants of "café" will catch it.
        let semanticString = SemanticString {
            Keyword("\u{1F600}")                // 4-byte UTF-8 emoji (grinning face)
            Space()
            Variable("测试")                     // 3-byte UTF-8 CJK each
            Space()
            TypeName(kind: .other, "café")      // includes accented character
        }

        #expect(semanticString.string == "\u{1F600} 测试 café")
        #expect(
            semanticString.string.utf8.count ==
                "\u{1F600}".utf8.count + 1 + "测试".utf8.count + 1 + "café".utf8.count
        )

        // Sanity: confirm byte count is strictly larger than character count.
        #expect(semanticString.string.utf8.count > semanticString.string.count)
    }

    @Test("Nested Joined composes prefix/items-with-separator/suffix correctly")
    func nestedJoined() {
        // Inner: "[a, b]"
        let inner = Joined(separator: ", ", prefix: "[", suffix: "]") {
            Standard("a")
            Standard("b")
        }
        // Outer: "(<inner> | [c])"
        let outer = Joined(separator: " | ", prefix: "(", suffix: ")") {
            inner
            Joined(separator: ", ", prefix: "[", suffix: "]") {
                Standard("c")
            }
        }

        // Expected output discovered from current implementation and locked in
        // here so that any change to Joined.buildComponents (e.g. the spec §3
        // rewrite that eliminates front-insertion) cannot silently drift.
        #expect(SemanticString(outer).string == "([a, b] | [c])")

        // Also pin the atomic component sequence so flattening order is
        // preserved across the upcoming rewrite.
        let components = outer.buildComponents()
        let expectedStrings = ["(", "[", "a", ", ", "b", "]", " | ", "[", "c", "]", ")"]
        #expect(components.map(\.string) == expectedStrings)
        #expect(components.count == 11)
    }
}
