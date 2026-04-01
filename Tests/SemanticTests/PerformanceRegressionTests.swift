import Testing
import Foundation
@testable import Semantic

// MARK: - Builder Accumulation Tests

@Suite("Builder Accumulation")
struct BuilderAccumulationTests {
    @Test("Builder with many elements accumulates correctly")
    func manyElements() {
        let semanticString = SemanticString {
            Keyword("public")
            Space()
            Keyword("static")
            Space()
            Keyword("func")
            Space()
            FunctionDeclaration("doSomething")
            Standard("(")
            Argument("label")
            Standard(": ")
            TypeName(kind: .struct, "Int")
            Standard(")")
        }
        #expect(semanticString.count == 12)
        #expect(semanticString.string == "public static func doSomething(label: Int)")
    }

    @Test("Builder with optional element present")
    func optionalElementPresent() {
        let component: Keyword? = Keyword("override")
        let semanticString = SemanticString {
            component
            Space()
            Keyword("func")
        }
        #expect(semanticString.string == "override func")
    }

    @Test("Builder with optional element nil")
    func optionalElementNil() {
        let component: Keyword? = nil
        let semanticString = SemanticString {
            component
            Keyword("func")
        }
        #expect(semanticString.string == "func")
    }

    @Test("Builder with SemanticString element")
    func semanticStringElement() {
        let prefix = SemanticString {
            Keyword("public")
            Space()
        }
        let semanticString = SemanticString {
            prefix
            Keyword("class")
        }
        #expect(semanticString.string == "public class")
    }

    @Test("Builder with optional SemanticString nil")
    func optionalSemanticStringNil() {
        let prefix: SemanticString? = nil
        let semanticString = SemanticString {
            prefix
            Keyword("class")
        }
        #expect(semanticString.string == "class")
    }

    @Test("Builder with CustomStringConvertible")
    func customStringConvertible() {
        let semanticString = SemanticString {
            42
        }
        #expect(semanticString.string == "42")
        #expect(semanticString.first?.type == .standard)
    }

    @Test("Builder with Void expressions interleaved")
    func voidExpressions() {
        var counter = 0
        let semanticString = SemanticString {
            counter += 1
            Keyword("let")
            counter += 1
            Space()
            counter += 1
            Variable("x")
        }
        #expect(counter == 3)
        #expect(semanticString.string == "let x")
        #expect(semanticString.count == 3)
    }

    @Test("Builder with if-else")
    func ifElse() {
        let isStruct = false
        let semanticString = SemanticString {
            if isStruct {
                Keyword("struct")
            } else {
                Keyword("class")
            }
        }
        #expect(semanticString.string == "class")
    }

    @Test("Builder with for loop producing many items")
    func forLoopManyItems() {
        let semanticString = SemanticString {
            for index in 0..<20 {
                Standard("\(index)")
            }
        }
        #expect(semanticString.count == 20)
        #expect(semanticString.string == (0..<20).map(String.init).joined())
    }

    @Test("Builder with empty block")
    func emptyBlock() {
        let semanticString = SemanticString {
        }
        #expect(semanticString.isEmpty)
        #expect(semanticString.string == "")
    }

    @Test("Builder with array element")
    func arrayElement() {
        let keywords: [any SemanticStringComponent] = [Keyword("public"), Space(), Keyword("func")]
        let semanticString = SemanticString {
            keywords
        }
        #expect(semanticString.string == "public func")
    }
}

// MARK: - TupleComponent Tests

@Suite("TupleComponent")
struct TupleComponentTests {
    @Test("TupleComponent2 builds both components")
    func tupleComponent2() {
        let tuple = TupleComponent2(Keyword("let"), Space())
        let components = tuple.buildComponents()
        #expect(components.count == 2)
        #expect(components[0].string == "let")
        #expect(components[0].type == .keyword)
        #expect(components[1].string == " ")
        #expect(components[1].type == .standard)
    }

    @Test("TupleComponent3 builds all three components")
    func tupleComponent3() {
        let tuple = TupleComponent3(Keyword("var"), Space(), Variable("x"))
        let components = tuple.buildComponents()
        #expect(components.count == 3)
        #expect(components[0].string == "var")
        #expect(components[1].string == " ")
        #expect(components[2].string == "x")
        #expect(components[2].type == .variable)
    }

    @Test("TupleComponent2 with empty first component")
    func tupleComponent2EmptyFirst() {
        let tuple = TupleComponent2(Standard(""), Keyword("func"))
        let components = tuple.buildComponents()
        #expect(components.count == 1)
        #expect(components[0].string == "func")
    }

    @Test("TupleComponent3 with empty middle component")
    func tupleComponent3EmptyMiddle() {
        let tuple = TupleComponent3(Keyword("a"), Standard(""), Keyword("b"))
        let components = tuple.buildComponents()
        #expect(components.count == 2)
        #expect(components[0].string == "a")
        #expect(components[1].string == "b")
    }
}

// MARK: - Atomic Component Tests (BreakLine, Space, Indent)

@Suite("Atomic Components")
struct AtomicComponentTests {
    @Test("BreakLine produces newline")
    func breakLine() {
        let components = BreakLine().buildComponents()
        #expect(components.count == 1)
        #expect(components[0].string == "\n")
        #expect(components[0].type == .standard)
    }

    @Test("Space produces single space")
    func space() {
        let components = Space().buildComponents()
        #expect(components.count == 1)
        #expect(components[0].string == " ")
        #expect(components[0].type == .standard)
    }

    @Test("Indent level 0 produces empty")
    func indentLevel0() {
        let components = Indent(level: 0).buildComponents()
        #expect(components.isEmpty)
    }

    @Test("Indent level 1 produces 4 spaces")
    func indentLevel1() {
        let components = Indent(level: 1).buildComponents()
        #expect(components.count == 1)
        #expect(components[0].string == "    ")
        #expect(components[0].type == .standard)
    }

    @Test("Indent level 2 produces 8 spaces")
    func indentLevel2() {
        let components = Indent(level: 2).buildComponents()
        #expect(components.count == 1)
        #expect(components[0].string == "        ")
    }

    @Test("Indent level 3 produces 12 spaces")
    func indentLevel3() {
        let indent = Indent(level: 3)
        #expect(indent.string == String(repeating: " ", count: 12))
    }

    @Test("All atomic component types")
    func allAtomicTypes() {
        let components: [(any AtomicSemanticComponent, SemanticType)] = [
            (Keyword("kw"), .keyword),
            (Variable("v"), .variable),
            (Numeric("42"), .numeric),
            (Argument("arg"), .argument),
            (Comment("c"), .comment),
            (Error("e"), .error),
            (Standard("s"), .standard),
            (TypeName(kind: .struct, "T"), .type(.struct, .name)),
            (TypeDeclaration(kind: .class, "C"), .type(.class, .declaration)),
            (MemberName("m"), .member(.name)),
            (MemberDeclaration("md"), .member(.declaration)),
            (FunctionName("f"), .function(.name)),
            (FunctionDeclaration("fd"), .function(.declaration)),
        ]
        for (component, expectedType) in components {
            let built = component.buildComponents()
            #expect(built.count == 1, "Component \(Swift.type(of: component)) should produce 1 element")
            #expect(built[0].type == expectedType, "Component \(Swift.type(of: component)) should have type \(expectedType)")
        }
    }
}

// MARK: - Group Tests

@Suite("Group Component")
struct GroupComponentTests {
    @Test("Group without separator flattens children")
    func groupNoSeparator() {
        let group = Group {
            Keyword("a")
            Keyword("b")
            Keyword("c")
        }
        let components = group.buildComponents()
        #expect(components.count == 3)
        #expect(components.map(\.string) == ["a", "b", "c"])
    }

    @Test("Group with separator inserts between items")
    func groupWithSeparator() {
        let group = Group {
            Standard("x")
            Standard("y")
            Standard("z")
        }.separator(Standard(", "))
        let components = group.buildComponents()
        #expect(components.map(\.string) == ["x", ", ", "y", ", ", "z"])
    }

    @Test("Group with string separator")
    func groupWithStringSeparator() {
        let group = Group {
            Keyword("a")
            Keyword("b")
        }.separator(" | ")
        let components = group.buildComponents()
        #expect(components.map(\.string).joined() == "a | b")
    }

    @Test("Group filters out empty components before applying separator")
    func groupFiltersEmpty() {
        let group = Group {
            Standard("a")
            Standard("")
            Standard("b")
        }.separator(Standard(", "))
        let components = group.buildComponents()
        #expect(components.map(\.string).joined() == "a, b")
    }

    @Test("Empty group produces empty")
    func emptyGroup() {
        let group = Group()
        #expect(group.buildComponents().isEmpty)
    }

    @Test("Group with single item no separator added")
    func groupSingleItem() {
        let group = Group {
            Standard("only")
        }.separator(Standard(", "))
        let components = group.buildComponents()
        #expect(components.map(\.string) == ["only"])
    }

    @Test("Group from array of SemanticStrings")
    func groupFromArray() {
        let items = ["one", "two"].map { SemanticString(Standard($0)) }
        let group = Group(items).separator(", ")
        #expect(group.buildComponents().map(\.string).joined() == "one, two")
    }

    @Test("Group from variadic SemanticStrings")
    func groupFromVariadic() {
        let first = SemanticString(Standard("a"))
        let second = SemanticString(Standard("b"))
        let group = Group(first, second).separator(", ")
        #expect(group.buildComponents().map(\.string).joined() == "a, b")
    }
}

// MARK: - Joined Tests

@Suite("Joined Component")
struct JoinedComponentTests {
    @Test("Joined with prefix and suffix")
    func joinedWithPrefixSuffix() {
        let joined = Joined(separator: ", ", prefix: "(", suffix: ")") {
            Standard("a")
            Standard("b")
        }
        let result = joined.buildComponents().map(\.string).joined()
        #expect(result == "(a, b)")
    }

    @Test("Joined filters empty items")
    func joinedFiltersEmpty() {
        let joined = Joined(separator: ", ") {
            Standard("a")
            Standard("")
            Standard("b")
        }
        #expect(joined.buildComponents().map(\.string).joined() == "a, b")
    }

    @Test("Joined all empty items produces nothing")
    func joinedAllEmpty() {
        let joined = Joined(separator: ", ", prefix: "(", suffix: ")") {
            Standard("")
            Standard("")
        }
        #expect(joined.buildComponents().isEmpty)
    }

    @Test("Joined with component separator")
    func joinedComponentSeparator() {
        let joined = Joined(separator: Space()) {
            Keyword("public")
            Keyword("func")
        }
        let components = joined.buildComponents()
        #expect(components.map(\.string).joined() == "public func")
        #expect(components[1].type == .standard)
    }

    @Test("Joined from array")
    func joinedFromArray() {
        let items = ["x", "y", "z"].map { SemanticString(Standard($0)) }
        let joined = Joined(separator: "-", prefix: "[", suffix: "]", items)
        #expect(joined.buildComponents().map(\.string).joined() == "[x-y-z]")
    }

    @Test("Joined single item has prefix/suffix but no separator")
    func joinedSingleItem() {
        let joined = Joined(separator: ", ", prefix: "<", suffix: ">") {
            Standard("only")
        }
        #expect(joined.buildComponents().map(\.string).joined() == "<only>")
    }

    @Test("Array joined extension with string separator")
    func arrayJoinedString() {
        let items: [SemanticString] = [
            SemanticString(Keyword("a")),
            SemanticString(Keyword("b")),
            SemanticString(Keyword("c")),
        ]
        let result = items.joined(separator: ", ")
        #expect(result.string == "a, b, c")
    }

    @Test("Array of components joined with separator")
    func componentArrayJoined() {
        let items: [Keyword] = [Keyword("x"), Keyword("y")]
        let result = items.joined(separator: " & ")
        #expect(result.string == "x & y")
    }
}

// MARK: - BlockList Tests

@Suite("BlockList Component")
struct BlockListTests {
    @Test("BlockList adds breaks before each item and after last")
    func blockListBasic() {
        let blockList = BlockList {
            Standard("line1")
            Standard("line2")
            Standard("line3")
        }
        let components = blockList.buildComponents()
        let fullString = components.map(\.string).joined()
        #expect(fullString == "\nline1\nline2\nline3\n")
    }

    @Test("Empty BlockList produces nothing")
    func blockListEmpty() {
        let blockList = BlockList {
            Standard("")
        }
        #expect(blockList.buildComponents().isEmpty)
    }

    @Test("BlockList filters empty items")
    func blockListFiltersEmpty() {
        let blockList = BlockList {
            Standard("a")
            Standard("")
            Standard("b")
        }
        let fullString = blockList.buildComponents().map(\.string).joined()
        #expect(fullString == "\na\nb\n")
    }

    @Test("BlockList separatedByEmptyLine adds extra breaks")
    func blockListSeparatedByEmptyLine() {
        let blockList = BlockList {
            Standard("group1")
            Standard("group2")
        }.separatedByEmptyLine()
        let fullString = blockList.buildComponents().map(\.string).joined()
        #expect(fullString == "\ngroup1\n\ngroup2\n")
    }

    @Test("BlockList from array of SemanticStrings")
    func blockListFromArray() {
        let items = ["a", "b"].map { SemanticString(Standard($0)) }
        let blockList = BlockList(items)
        let fullString = blockList.buildComponents().map(\.string).joined()
        #expect(fullString == "\na\nb\n")
    }

    @Test("BlockList single item")
    func blockListSingleItem() {
        let blockList = BlockList {
            Standard("only")
        }
        let fullString = blockList.buildComponents().map(\.string).joined()
        #expect(fullString == "\nonly\n")
    }
}

// MARK: - MemberList Tests

@Suite("MemberList Component")
struct MemberListTests {
    @Test("MemberList adds break and indent before each item")
    func memberListBasic() {
        let memberList = MemberList(level: 1) {
            Standard("var x: Int")
            Standard("var y: String")
        }
        let components = memberList.buildComponents()
        let fullString = components.map(\.string).joined()
        #expect(fullString == "\n    var x: Int\n    var y: String\n")
    }

    @Test("Empty MemberList produces nothing")
    func memberListEmpty() {
        let memberList = MemberList(level: 1) {
            Standard("")
        }
        #expect(memberList.buildComponents().isEmpty)
    }

    @Test("MemberList level 2 indentation")
    func memberListLevel2() {
        let memberList = MemberList(level: 2) {
            Standard("nested")
        }
        let fullString = memberList.buildComponents().map(\.string).joined()
        #expect(fullString == "\n        nested\n")
    }

    @Test("MemberList filters empty items")
    func memberListFiltersEmpty() {
        let memberList = MemberList(level: 1) {
            Standard("a")
            Standard("")
            Standard("b")
        }
        let fullString = memberList.buildComponents().map(\.string).joined()
        #expect(fullString == "\n    a\n    b\n")
    }

    @Test("MemberList from array")
    func memberListFromArray() {
        let items = ["x", "y"].map { SemanticString(Standard($0)) }
        let memberList = MemberList(level: 1, items)
        let fullString = memberList.buildComponents().map(\.string).joined()
        #expect(fullString == "\n    x\n    y\n")
    }
}

// MARK: - DeclarationBlock Tests

@Suite("DeclarationBlock Component")
struct DeclarationBlockTests {
    @Test("DeclarationBlock with members")
    func declarationBlockWithMembers() {
        let block = DeclarationBlock(level: 1) {
            Keyword("struct")
            Space()
            TypeDeclaration(kind: .struct, "Foo")
        } body: {
            MemberList(level: 1) {
                SemanticString {
                    Keyword("var")
                    Space()
                    Variable("x")
                    Standard(": ")
                    TypeName(kind: .struct, "Int")
                }
            }
        }
        let components = block.buildComponents()
        let fullString = components.map(\.string).joined()
        #expect(fullString.contains("struct Foo {"))
        #expect(fullString.contains("var x: Int"))
        #expect(fullString.hasSuffix("}"))
    }

    @Test("DeclarationBlock empty body")
    func declarationBlockEmptyBody() {
        let block = DeclarationBlock(level: 1) {
            Keyword("struct")
            Space()
            TypeDeclaration(kind: .struct, "Empty")
        } body: {
            EmptyComponent()
        }
        let components = block.buildComponents()
        let fullString = components.map(\.string).joined()
        #expect(fullString.contains("struct Empty {"))
        #expect(fullString.contains("}"))
    }

    @Test("DeclarationBlock level 0 no leading indent")
    func declarationBlockLevel0() {
        let block = DeclarationBlock(level: 0) {
            Keyword("class")
            Space()
            TypeDeclaration(kind: .class, "C")
        } body: {
            EmptyComponent()
        }
        let fullString = block.buildComponents().map(\.string).joined()
        #expect(fullString.hasPrefix("class"))
    }

    @Test("DeclarationBlock level 2 nested indent")
    func declarationBlockLevel2() {
        let block = DeclarationBlock(level: 2) {
            Keyword("struct")
            Space()
            TypeDeclaration(kind: .struct, "Inner")
        } body: {
            MemberList(level: 2) {
                Standard("field")
            }
        }
        let components = block.buildComponents()
        let fullString = components.map(\.string).joined()
        // level 2 header indent = level 1 indent = 4 spaces
        #expect(fullString.hasPrefix("    struct Inner {"))
    }
}

// MARK: - NestedDeclaration Tests

@Suite("NestedDeclaration Component")
struct NestedDeclarationTests {
    @Test("NestedDeclaration prepends break line")
    func nestedDeclarationBasic() {
        let nested = NestedDeclaration {
            Standard("content")
        }
        let components = nested.buildComponents()
        #expect(components.count == 2)
        #expect(components[0].string == "\n")
        #expect(components[1].string == "content")
    }

    @Test("NestedDeclaration with empty content produces nothing")
    func nestedDeclarationEmpty() {
        let nested = NestedDeclaration {
            Standard("")
        }
        #expect(nested.buildComponents().isEmpty)
    }

    @Test("NestedDeclaration from component")
    func nestedDeclarationFromComponent() {
        let nested = NestedDeclaration(Keyword("test"))
        let components = nested.buildComponents()
        #expect(components.count == 2)
        #expect(components[1].string == "test")
        #expect(components[1].type == .keyword)
    }
}

// MARK: - SemanticString.string Property Tests

@Suite("String Property")
struct StringPropertyTests {
    @Test("String from multiple components")
    func stringMultipleComponents() {
        let semanticString = SemanticString {
            Keyword("let")
            Space()
            Variable("count")
            Standard(": ")
            TypeName(kind: .struct, "Int")
            Standard(" = ")
            Numeric("42")
        }
        #expect(semanticString.string == "let count: Int = 42")
    }

    @Test("String caching returns same result")
    func stringCaching() {
        let semanticString = SemanticString {
            Standard("hello")
            Space()
            Standard("world")
        }
        let first = semanticString.string
        let second = semanticString.string
        #expect(first == second)
        #expect(first == "hello world")
    }

    @Test("Empty SemanticString string is empty")
    func emptyString() {
        #expect(SemanticString().string == "")
    }

    @Test("String literal init caches string")
    func stringLiteralCache() {
        let semanticString: SemanticString = "cached"
        #expect(semanticString.string == "cached")
    }
}

// MARK: - contains(_: String) Tests

@Suite("Contains Substring")
struct ContainsSubstringTests {
    @Test("Contains existing substring")
    func containsExisting() {
        let semanticString = SemanticString {
            Keyword("public")
            Space()
            Keyword("func")
        }
        #expect(semanticString.contains("public"))
        #expect(semanticString.contains("func"))
        #expect(semanticString.contains("c f"))
    }

    @Test("Does not contain missing substring")
    func doesNotContain() {
        let semanticString = SemanticString {
            Keyword("struct")
        }
        #expect(!semanticString.contains("class"))
    }

    @Test("Contains empty string is always true")
    func containsEmptyString() {
        let semanticString = SemanticString(Standard("hello"))
        #expect(semanticString.contains(""))
    }

    @Test("Contains on empty SemanticString")
    func containsOnEmpty() {
        let semanticString = SemanticString()
        #expect(semanticString.contains(""))
        #expect(!semanticString.contains("x"))
    }

    @Test("Contains substring spanning components")
    func containsSpanning() {
        let semanticString = SemanticString {
            Standard("hel")
            Standard("lo")
        }
        #expect(semanticString.contains("hello"))
        #expect(semanticString.contains("ello"))
        #expect(semanticString.contains("ell"))
    }

    @Test("Contains type check")
    func containsType() {
        let semanticString = SemanticString {
            Keyword("var")
            Space()
            Variable("name")
        }
        #expect(semanticString.contains(type: .keyword))
        #expect(semanticString.contains(type: .variable))
        #expect(!semanticString.contains(type: .numeric))
    }
}

// MARK: - Appending & Copy-on-Write Tests

@Suite("Appending and Copy-on-Write")
struct AppendingCopyOnWriteTests {
    @Test("Appending SemanticString")
    func appendSemanticString() {
        let first = SemanticString(Keyword("let"))
        let second = SemanticString(Variable("x"))
        let result = first.appending(Space()).appending(second)
        #expect(result.string == "let x")
        #expect(result.count == 3)
    }

    @Test("Appending component")
    func appendComponent() {
        let base = SemanticString(Keyword("var"))
        let result = base.appending(Space()).appending(Variable("y"))
        #expect(result.string == "var y")
    }

    @Test("Appending string with type")
    func appendStringWithType() {
        let base = SemanticString(Keyword("let"))
        let result = base.appending(" ", type: .standard).appending("x", type: .variable)
        #expect(result.string == "let x")
    }

    @Test("Appending empty string is no-op")
    func appendEmptyString() {
        let base = SemanticString(Keyword("test"))
        let result = base.appending("", type: .standard)
        #expect(result.string == "test")
    }

    @Test("Copy-on-write: mutation does not affect original")
    func copyOnWriteMutation() {
        let original = SemanticString(Keyword("original"))
        var copy = original
        copy.append(Standard(" modified"))
        #expect(original.string == "original")
        #expect(copy.string == "original modified")
    }

    @Test("Copy-on-write: appending returns new value")
    func copyOnWriteAppending() {
        let base = SemanticString(Standard("a"))
        let result = base.appending(Standard("b"))
        #expect(base.string == "a")
        #expect(result.string == "ab")
    }

    @Test("+= operator mutates in place")
    func plusEqualsOperator() {
        var semanticString = SemanticString(Keyword("hello"))
        semanticString += SemanticString(Standard(" world"))
        #expect(semanticString.string == "hello world")
    }

    @Test("+ operator produces new value")
    func plusOperator() {
        let first = SemanticString(Keyword("a"))
        let second = SemanticString(Standard("b"))
        let result = first + second
        #expect(result.string == "ab")
        #expect(first.string == "a")
        #expect(second.string == "b")
    }

    @Test("+ operator with component")
    func plusOperatorComponent() {
        let semanticString = SemanticString(Keyword("x"))
        let result = semanticString + Standard("y")
        #expect(result.string == "xy")
    }

    @Test("Multiple chained appending")
    func chainedAppending() {
        let result = SemanticString(Standard("a"))
            .appending(Standard("b"))
            .appending(Standard("c"))
            .appending(Standard("d"))
            .appending(Standard("e"))
        #expect(result.string == "abcde")
        #expect(result.count == 5)
    }
}

// MARK: - Trimming Tests

@Suite("Trimming")
struct TrimmingTests {
    @Test("Trimming leading whitespace")
    func trimmingLeading() {
        let semanticString = SemanticString {
            Space()
            Space()
            Keyword("func")
            Space()
        }
        let trimmed = semanticString.trimmingLeadingWhitespace()
        #expect(trimmed.string == "func ")
    }

    @Test("Trimming trailing whitespace")
    func trimmingTrailing() {
        let semanticString = SemanticString {
            Space()
            Keyword("func")
            Space()
            Space()
        }
        let trimmed = semanticString.trimmingTrailingWhitespace()
        #expect(trimmed.string == " func")
    }

    @Test("Trimming both whitespace")
    func trimmingBoth() {
        let semanticString = SemanticString {
            Space()
            Keyword("func")
            Space()
        }
        let trimmed = semanticString.trimmingWhitespace()
        #expect(trimmed.string == "func")
        #expect(trimmed.count == 1)
    }

    @Test("Trimming leading newlines")
    func trimmingLeadingNewlines() {
        let semanticString = SemanticString {
            BreakLine()
            BreakLine()
            Standard("content")
        }
        let trimmed = semanticString.trimmingLeadingNewlines()
        #expect(trimmed.string == "content")
    }

    @Test("Trimming trailing newlines")
    func trimmingTrailingNewlines() {
        let semanticString = SemanticString {
            Standard("content")
            BreakLine()
            BreakLine()
        }
        let trimmed = semanticString.trimmingTrailingNewlines()
        #expect(trimmed.string == "content")
    }

    @Test("Trimming both newlines")
    func trimmingBothNewlines() {
        let semanticString = SemanticString {
            BreakLine()
            Standard("content")
            BreakLine()
        }
        let trimmed = semanticString.trimmingNewlines()
        #expect(trimmed.string == "content")
    }

    @Test("Trimming no-op when nothing to trim")
    func trimmingNoOp() {
        let semanticString = SemanticString(Keyword("clean"))
        let trimmed = semanticString.trimmingWhitespace()
        #expect(trimmed.string == "clean")
    }

    @Test("Trimming all whitespace produces empty")
    func trimmingAllWhitespace() {
        let semanticString = SemanticString {
            Space()
            Space()
        }
        let trimmed = semanticString.trimmingWhitespace()
        #expect(trimmed.isEmpty)
    }
}

// MARK: - Codable Tests

@Suite("Codable")
struct CodableTests {
    @Test("Encode and decode round-trip")
    func roundTrip() throws {
        let original = SemanticString {
            Keyword("public")
            Space()
            Keyword("struct")
            Space()
            TypeDeclaration(kind: .struct, "Foo")
        }
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SemanticString.self, from: data)
        #expect(decoded.string == original.string)
        #expect(decoded.components == original.components)
    }

    @Test("Encode and decode empty string")
    func emptyRoundTrip() throws {
        let original = SemanticString()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SemanticString.self, from: data)
        #expect(decoded.isEmpty)
    }

    @Test("Encode and decode preserves semantic types")
    func preservesTypes() throws {
        let original = SemanticString {
            Keyword("kw")
            Variable("v")
            Numeric("42")
            TypeName(kind: .protocol, "P")
            MemberName("m")
            FunctionName("f")
        }
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SemanticString.self, from: data)
        #expect(decoded.components.count == original.components.count)
        for (decodedComponent, originalComponent) in zip(decoded.components, original.components) {
            #expect(decodedComponent.type == originalComponent.type)
            #expect(decodedComponent.string == originalComponent.string)
        }
    }
}

// MARK: - Hashable Tests

@Suite("Hashable")
struct HashableTests {
    @Test("Equal strings have same hash")
    func equalHash() {
        let first = SemanticString {
            Keyword("let")
            Variable("x")
        }
        let second = SemanticString {
            Keyword("let")
            Variable("x")
        }
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
    }

    @Test("Different strings are not equal")
    func differentNotEqual() {
        let first = SemanticString(Keyword("let"))
        let second = SemanticString(Keyword("var"))
        #expect(first != second)
    }

    @Test("Same text different types are not equal")
    func sameTextDifferentType() {
        let first = SemanticString(Keyword("x"))
        let second = SemanticString(Variable("x"))
        #expect(first != second)
    }

    @Test("Can be used as dictionary key")
    func dictionaryKey() {
        let key = SemanticString(Keyword("key"))
        var dictionary: [SemanticString: Int] = [:]
        dictionary[key] = 42
        #expect(dictionary[key] == 42)
    }

    @Test("Can be used in Set")
    func setMembership() {
        let first = SemanticString(Standard("a"))
        let second = SemanticString(Standard("a"))
        let third = SemanticString(Standard("b"))
        let collection: Set<SemanticString> = [first, second, third]
        #expect(collection.count == 2)
    }
}

// MARK: - Subscript / Drop / Prefix / Suffix / Filter Tests

@Suite("Collection Operations")
struct CollectionOperationsTests {
    @Test("Subscript by index")
    func subscriptIndex() {
        let semanticString = SemanticString {
            Keyword("a")
            Variable("b")
            Standard("c")
        }
        #expect(semanticString[0]?.string == "a")
        #expect(semanticString[1]?.string == "b")
        #expect(semanticString[2]?.string == "c")
        #expect(semanticString[3] == nil)
        #expect(semanticString[-1] == nil)
    }

    @Test("Subscript by range")
    func subscriptRange() {
        let semanticString = SemanticString {
            Keyword("a")
            Variable("b")
            Standard("c")
            Numeric("d")
        }
        let slice = semanticString[1..<3]
        #expect(slice.count == 2)
        #expect(slice.string == "bc")
    }

    @Test("dropFirst")
    func dropFirst() {
        let semanticString = SemanticString {
            Space()
            Keyword("func")
            Space()
            Variable("name")
        }
        let dropped = semanticString.dropFirst(2)
        #expect(dropped.string == " name")
    }

    @Test("dropLast")
    func dropLast() {
        let semanticString = SemanticString {
            Keyword("func")
            Space()
            Variable("name")
            Standard(";")
        }
        let dropped = semanticString.dropLast(1)
        #expect(dropped.string == "func name")
    }

    @Test("drop while")
    func dropWhile() {
        let semanticString = SemanticString {
            Space()
            Space()
            Keyword("func")
        }
        let dropped = semanticString.drop { $0.type == .standard }
        #expect(dropped.string == "func")
    }

    @Test("prefix")
    func prefixTest() {
        let semanticString = SemanticString {
            Keyword("a")
            Keyword("b")
            Keyword("c")
        }
        let result = semanticString.prefix(2)
        #expect(result.string == "ab")
    }

    @Test("suffix")
    func suffixTest() {
        let semanticString = SemanticString {
            Keyword("a")
            Keyword("b")
            Keyword("c")
        }
        let result = semanticString.suffix(2)
        #expect(result.string == "bc")
    }

    @Test("filter by type")
    func filterByType() {
        let semanticString = SemanticString {
            Keyword("let")
            Space()
            Variable("x")
            Standard(": ")
            TypeName(kind: .struct, "Int")
        }
        let keywordsOnly = semanticString.filter(byType: .keyword)
        #expect(keywordsOnly.string == "let")
    }

    @Test("filter by predicate")
    func filterByPredicate() {
        let semanticString = SemanticString {
            Keyword("let")
            Space()
            Variable("x")
        }
        let nonSpaces = semanticString.filter { $0.string != " " }
        #expect(nonSpaces.string == "letx")
    }

    @Test("first and last properties")
    func firstAndLast() {
        let semanticString = SemanticString {
            Keyword("first")
            Space()
            Variable("last")
        }
        #expect(semanticString.first?.string == "first")
        #expect(semanticString.first?.type == .keyword)
        #expect(semanticString.last?.string == "last")
        #expect(semanticString.last?.type == .variable)
    }

    @Test("first and last on empty")
    func firstAndLastEmpty() {
        let semanticString = SemanticString()
        #expect(semanticString.first == nil)
        #expect(semanticString.last == nil)
    }

    @Test("count property")
    func countProperty() {
        let semanticString = SemanticString {
            Keyword("a")
            Keyword("b")
            Keyword("c")
        }
        #expect(semanticString.count == 3)
        #expect(SemanticString().count == 0)
    }
}

// MARK: - Wrapping Tests

@Suite("Wrapping")
struct WrappingTests {
    @Test("wrapped with prefix and suffix")
    func wrappedBasic() {
        let semanticString = SemanticString(Standard("content"))
        let wrapped = semanticString.wrapped(prefix: "<<", suffix: ">>")
        #expect(wrapped.string == "<<content>>")
    }

    @Test("wrapped with condition true")
    func wrappedConditionTrue() {
        let semanticString = SemanticString(Standard("x"))
        let wrapped = semanticString.wrapped(prefix: "(", suffix: ")", if: true)
        #expect(wrapped.string == "(x)")
    }

    @Test("wrapped with condition false")
    func wrappedConditionFalse() {
        let semanticString = SemanticString(Standard("x"))
        let wrapped = semanticString.wrapped(prefix: "(", suffix: ")", if: false)
        #expect(wrapped.string == "x")
    }

    @Test("parenthesized")
    func parenthesized() {
        let semanticString = SemanticString(Standard("args"))
        #expect(semanticString.parenthesized().string == "(args)")
    }

    @Test("bracketed")
    func bracketed() {
        let semanticString = SemanticString(Standard("0"))
        #expect(semanticString.bracketed().string == "[0]")
    }

    @Test("braced")
    func braced() {
        let semanticString = SemanticString(Standard("body"))
        #expect(semanticString.braced().string == "{body}")
    }

    @Test("angleBracketed")
    func angleBracketed() {
        let semanticString = SemanticString(TypeName(kind: .other, "T"))
        #expect(semanticString.angleBracketed().string == "<T>")
    }
}

// MARK: - Conditional Operations Tests

@Suite("Conditional Operations")
struct ConditionalOperationsTests {
    @Test("if true returns self")
    func ifTrue() {
        let semanticString = SemanticString(Standard("content"))
        #expect(semanticString.if(true).string == "content")
    }

    @Test("if false returns empty")
    func ifFalse() {
        let semanticString = SemanticString(Standard("content"))
        #expect(semanticString.if(false).isEmpty)
    }

    @Test("prefixed with SemanticString")
    func prefixedWithSemanticString() {
        let semanticString = SemanticString(Keyword("func"))
        let prefix = SemanticString {
            Keyword("public")
            Space()
        }
        let result = semanticString.prefixed(with: prefix, if: true)
        #expect(result.string == "public func")
    }

    @Test("prefixed with component")
    func prefixedWithComponent() {
        let semanticString = SemanticString(Standard("body"))
        let result = semanticString.prefixed(with: Keyword("@"), if: true)
        #expect(result.string == "@body")
    }

    @Test("suffixed with SemanticString")
    func suffixedWithSemanticString() {
        let semanticString = SemanticString(Keyword("func"))
        let suffix = SemanticString(Standard(";"))
        let result = semanticString.suffixed(with: suffix, if: true)
        #expect(result.string == "func;")
    }

    @Test("suffixed with component")
    func suffixedWithComponent() {
        let semanticString = SemanticString(Standard("x"))
        let result = semanticString.suffixed(with: Standard("!"), if: true)
        #expect(result.string == "x!")
    }

    @Test("ifLet with value")
    func ifLetWithValue() {
        let semanticString = SemanticString(Keyword("class"))
        let superclass: String? = "NSObject"
        let result = semanticString.ifLet(superclass) { name in
            Standard(": ")
            TypeName(kind: .class, name)
        }
        #expect(result.string == "class: NSObject")
    }

    @Test("ifLet without value")
    func ifLetWithoutValue() {
        let semanticString = SemanticString(Keyword("class"))
        let superclass: String? = nil
        let result = semanticString.ifLet(superclass) { name in
            Standard(": ")
            TypeName(kind: .class, name)
        }
        #expect(result.string == "class")
    }

    @Test("Component if extension")
    func componentIfExtension() {
        let result = Keyword("override").if(true)
        #expect(result.string == "override")

        let empty = Keyword("override").if(false)
        #expect(empty.isEmpty)
    }

    @Test("Component ifNotNil extension")
    func componentIfNotNil() {
        let value: Int? = 5
        let result = Keyword("override").ifNotNil(value)
        #expect(result.string == "override")

        let nilValue: Int? = nil
        let empty = Keyword("override").ifNotNil(nilValue)
        #expect(empty.isEmpty)
    }
}

// MARK: - Prefix/Suffix Checking Tests

@Suite("Prefix and Suffix Checking")
struct PrefixSuffixCheckingTests {
    @Test("hasPrefix on combined string")
    func hasPrefix() {
        let semanticString = SemanticString {
            Keyword("public")
            Space()
            Keyword("func")
        }
        #expect(semanticString.hasPrefix("public"))
        #expect(!semanticString.hasPrefix("func"))
    }

    @Test("hasSuffix on combined string")
    func hasSuffix() {
        let semanticString = SemanticString {
            Keyword("func")
            Standard("()")
        }
        #expect(semanticString.hasSuffix("()"))
        #expect(!semanticString.hasSuffix("func"))
    }

    @Test("starts with type")
    func startsWith() {
        let semanticString = SemanticString {
            Keyword("let")
            Variable("x")
        }
        #expect(semanticString.starts(with: .keyword))
        #expect(!semanticString.starts(with: .variable))
    }

    @Test("ends with type")
    func endsWith() {
        let semanticString = SemanticString {
            Keyword("let")
            Variable("x")
        }
        #expect(semanticString.ends(with: .variable))
        #expect(!semanticString.ends(with: .keyword))
    }

    @Test("firstComponentHasPrefix")
    func firstComponentHasPrefix() {
        let semanticString = SemanticString(Standard("hello world"))
        #expect(semanticString.firstComponentHasPrefix("hello"))
        #expect(!semanticString.firstComponentHasPrefix("world"))
    }

    @Test("lastComponentHasSuffix")
    func lastComponentHasSuffix() {
        let semanticString = SemanticString(Standard("hello world"))
        #expect(semanticString.lastComponentHasSuffix("world"))
        #expect(!semanticString.lastComponentHasSuffix("hello"))
    }
}

// MARK: - TextOutputStream Tests

@Suite("TextOutputStream")
struct TextOutputStreamTests {
    @Test("write standard text")
    func writeStandard() {
        var semanticString = SemanticString()
        semanticString.write("hello")
        #expect(semanticString.string == "hello")
        #expect(semanticString.first?.type == .standard)
    }

    @Test("write with type")
    func writeWithType() {
        var semanticString = SemanticString()
        semanticString.write("func", type: .keyword)
        #expect(semanticString.first?.type == .keyword)
    }

    @Test("multiple writes")
    func multipleWrites() {
        var semanticString = SemanticString()
        semanticString.write("a")
        semanticString.write("b")
        semanticString.write("c")
        #expect(semanticString.string == "abc")
        #expect(semanticString.count == 3)
    }
}

// MARK: - Transformation Tests

@Suite("Transformation")
struct TransformationTests {
    @Test("map transforms components")
    func mapTransform() {
        let semanticString = SemanticString {
            Standard("hello")
            Standard(" ")
            Standard("world")
        }
        let uppered = semanticString.map { AtomicComponent(string: $0.string.uppercased(), type: $0.type) }
        #expect(uppered.string == "HELLO WORLD")
    }

    @Test("replacing with transform")
    func replacingTransform() {
        let semanticString = SemanticString {
            Keyword("x")
            Variable("y")
        }
        let replaced = semanticString.replacing { _ in .error }
        #expect(replaced.components.allSatisfy { $0.type == .error })
    }

    @Test("replacing from types to type")
    func replacingFromTo() {
        let semanticString = SemanticString {
            Keyword("let")
            Space()
            Variable("x")
            Standard(": ")
            TypeName(kind: .struct, "Int")
        }
        let replaced = semanticString.replacing(from: .keyword, .variable, to: .standard)
        #expect(replaced.components[0].type == .standard)
        #expect(replaced.components[2].type == .standard)
        #expect(replaced.components[4].type == .type(.struct, .name))
    }

    @Test("enumerate visits all components")
    func enumerateAll() {
        let semanticString = SemanticString {
            Keyword("a")
            Variable("b")
            Standard("c")
        }
        var visited: [(String, SemanticType)] = []
        semanticString.enumerate { string, type in
            visited.append((string, type))
        }
        #expect(visited.count == 3)
        #expect(visited[0].0 == "a")
        #expect(visited[0].1 == .keyword)
        #expect(visited[2].0 == "c")
    }
}

// MARK: - ForEach Tests

@Suite("ForEach Component")
struct ForEachComponentTests {
    @Test("ForEach without separator")
    func forEachNoSeparator() {
        let items = [1, 2, 3]
        let forEach = ForEach(items) { item in
            Numeric("\(item)")
        }
        #expect(forEach.buildComponents().map(\.string).joined() == "123")
    }

    @Test("ForEach with component separator")
    func forEachComponentSeparator() {
        let items = ["a", "b", "c"]
        let forEach = ForEach(items, separator: Standard(" | ")) { item in
            Standard(item)
        }
        #expect(forEach.buildComponents().map(\.string).joined() == "a | b | c")
    }

    @Test("ForEach with empty collection")
    func forEachEmptyCollection() {
        let items: [String] = []
        let forEach = ForEach(items, separator: ", ") { item in
            Standard(item)
        }
        #expect(forEach.buildComponents().isEmpty)
    }

    @Test("ForEach single item no separator")
    func forEachSingleItem() {
        let forEach = ForEach(["only"], separator: ", ") { item in
            Standard(item)
        }
        #expect(forEach.buildComponents().map(\.string) == ["only"])
    }

    @Test("ForEach filters truly empty results with separator")
    func forEachFiltersEmpty() {
        // SemanticString.isEmpty checks _storage.elements, not flattened output.
        // Standard("") has elements so is not "isEmpty", but buildComponents() returns [].
        // Only truly empty SemanticStrings (no elements) are filtered.
        let forEach = ForEach(["a", "b"], separator: ", ") { item in
            if item == "a" {
                Standard(item)
            }
            if item == "b" {
                Standard(item)
            }
        }
        #expect(forEach.buildComponents().map(\.string).joined() == "a, b")
    }

    @Test("ForEachIndexed provides correct info")
    func forEachIndexedInfo() {
        let items = ["x", "y", "z"]
        var infos: [ForEachIndexed<[String]>.ElementInfo] = []
        let _ = ForEachIndexed(items) { _, info in
            infos.append(info)
            Standard("_")
        }
        #expect(infos.count == 3)
        #expect(infos[0].index == 0)
        #expect(infos[0].isFirst == true)
        #expect(infos[0].isLast == false)
        #expect(infos[1].index == 1)
        #expect(infos[1].isFirst == false)
        #expect(infos[1].isLast == false)
        #expect(infos[2].index == 2)
        #expect(infos[2].isFirst == false)
        #expect(infos[2].isLast == true)
    }
}

// MARK: - Optional/Array Conformance Tests

@Suite("Optional and Array Conformance")
struct OptionalArrayConformanceTests {
    @Test("Optional some builds components")
    func optionalSome() {
        let component: Keyword? = Keyword("test")
        let components = component.buildComponents()
        #expect(components.count == 1)
        #expect(components[0].string == "test")
    }

    @Test("Optional none builds empty")
    func optionalNone() {
        let component: Keyword? = nil
        let components = component.buildComponents()
        #expect(components.isEmpty)
    }

    @Test("Array builds flattened components")
    func arrayBuild() {
        let items: [Keyword] = [Keyword("a"), Keyword("b"), Keyword("c")]
        let components = items.buildComponents()
        #expect(components.count == 3)
        #expect(components.map(\.string) == ["a", "b", "c"])
    }

    @Test("Array with empty elements filters them")
    func arrayWithEmpty() {
        let items: [Standard] = [Standard("a"), Standard(""), Standard("b")]
        let components = items.buildComponents()
        #expect(components.count == 2)
        #expect(components.map(\.string) == ["a", "b"])
    }
}

// MARK: - EmptyComponent & UnknownError Tests

@Suite("Special Components")
struct SpecialComponentTests {
    @Test("EmptyComponent produces nothing")
    func emptyComponent() {
        #expect(EmptyComponent().buildComponents().isEmpty)
    }

    @Test("UnknownError produces error component")
    func unknownError() {
        let components = UnknownError().buildComponents()
        #expect(components.count == 1)
        #expect(components[0].string == "Unknown")
        #expect(components[0].type == .error)
    }
}

// MARK: - Comment Component Tests

@Suite("Comment Components")
struct CommentComponentTests {
    @Test("Comment prepends //")
    func lineComment() {
        let comment = Comment("todo")
        #expect(comment.string == "// todo")
        #expect(comment.type == .comment)
    }

    @Test("InlineComment wraps with /* */")
    func inlineComment() {
        let comment = InlineComment("note")
        #expect(comment.string == "/* note */")
        #expect(comment.type == .comment)
    }

    @Test("MultipleLineComment wraps correctly")
    func multiLineComment() {
        let comment = MultipleLineComment("line1\nline2")
        #expect(comment.string == "/*\nline1\nline2\n*/")
        #expect(comment.type == .comment)
    }
}

// MARK: - Initialization Edge Cases

@Suite("Initialization Edge Cases")
struct InitializationEdgeCaseTests {
    @Test("Init from AtomicComponent array pre-caches")
    func initFromAtomicArray() {
        let atomicComponents = [
            AtomicComponent(string: "a", type: .keyword),
            AtomicComponent(string: "b", type: .variable),
        ]
        let semanticString = SemanticString(components: atomicComponents)
        #expect(semanticString.count == 2)
        #expect(semanticString.string == "ab")
    }

    @Test("Init from variadic AtomicComponents")
    func initFromVariadicAtomic() {
        let semanticString = SemanticString(
            components: AtomicComponent(string: "x", type: .standard),
            AtomicComponent(string: "y", type: .keyword)
        )
        #expect(semanticString.count == 2)
        #expect(semanticString.string == "xy")
    }

    @Test("Empty string literal produces empty SemanticString")
    func emptyStringLiteral() {
        let semanticString: SemanticString = ""
        #expect(semanticString.isEmpty)
        #expect(semanticString.string == "")
    }

    @Test("Init from single component")
    func initSingleComponent() {
        let semanticString = SemanticString(Keyword("test"))
        #expect(semanticString.count == 1)
        #expect(semanticString.first?.type == .keyword)
    }

    @Test("AtomicComponent init from another atomic component")
    func atomicComponentCopy() {
        let original = Keyword("test")
        let copy = AtomicComponent(original)
        #expect(copy.string == "test")
        #expect(copy.type == .keyword)
    }
}

// MARK: - Joined Builder Prefix/Suffix Tests

@Suite("Joined Builder Prefix/Suffix")
struct JoinedBuilderPrefixSuffixTests {
    @Test("Joined with builder prefix")
    func joinedBuilderPrefix() {
        let joined = Joined(separator: ", ") {
            Standard("a")
            Standard("b")
        } prefix: {
            Standard("[")
        }
        let result = joined.buildComponents().map(\.string).joined()
        #expect(result == "[a, b")
    }

    @Test("Joined with builder prefix and suffix")
    func joinedBuilderPrefixSuffix() {
        let joined = Joined(separator: ", ") {
            Standard("a")
            Standard("b")
        } prefix: {
            Standard("(")
        } suffix: {
            Standard(")")
        }
        let result = joined.buildComponents().map(\.string).joined()
        #expect(result == "(a, b)")
    }
}
