import Testing
@testable import Semantic

/// Tests for `DefinitionRegion`, the region table, taking a region out, and
/// removing indentation. The contract they pin: wrapping content in regions
/// never changes what is printed; separating the regions gives back exactly
/// the string printed without them, in either order with visibility
/// regions; and a nested definition taken out of its parent's print, with
/// its nesting indentation removed, is exactly the definition's own print —
/// text, spans, identifiers, and the tables its separations produce.
@Suite("DefinitionRegion")
struct DefinitionRegionTests {
    // MARK: - A printer in miniature

    /// A definition laid out the way a declaration printer lays one out: a
    /// header, the nested definitions, then the members.
    private struct Definition {
        var name: String

        var members: [String] = []

        /// Members only some options show.
        var conditionalMembers: [(text: String, condition: VisibilityCondition)] = []

        /// The lines of a comment printed as ONE atom whose lines after the
        /// first carry their own indentation — the shape of a per-case enum
        /// layout comment.
        var multilineCommentLines: [String] = []

        var nestedDefinitions: [Definition] = []

        func definition(named name: String) -> Definition? {
            if self.name == name {
                return self
            }
            for nestedDefinition in nestedDefinitions {
                if let found = nestedDefinition.definition(named: name) {
                    return found
                }
            }
            return nil
        }
    }

    /// `definition` printed at `level`, each nested definition one level
    /// deeper; `marksDefinitions` wraps each nested one in a region named
    /// after it, `marksVisibility` wraps each conditional member in a
    /// visibility region instead of printing it unconditionally.
    private static func render(_ definition: Definition, level: Int, marksDefinitions: Bool, marksVisibility: Bool) -> SemanticString {
        SemanticString {
            DeclarationBlock(level: level) {
                Keyword("struct")
                Space()
                AtomicComponent(string: definition.name, type: .type(.struct, .declaration), identifier: "$s4Main\(definition.name.count)\(definition.name)V")
            } body: {
                for nestedDefinition in definition.nestedDefinitions {
                    NestedDeclaration {
                        if marksDefinitions {
                            DefinitionRegion(nestedDefinition.name, content: render(nestedDefinition, level: level + 1, marksDefinitions: true, marksVisibility: marksVisibility))
                        } else {
                            render(nestedDefinition, level: level + 1, marksDefinitions: false, marksVisibility: marksVisibility)
                        }
                    }
                }
                if !definition.nestedDefinitions.isEmpty && !definition.members.isEmpty {
                    BreakLine()
                }
                MemberList(level: level) {
                    for member in definition.members {
                        SemanticString {
                            Keyword("var")
                            Space()
                            Variable(member)
                            Standard(": ")
                            AtomicComponent(string: "Int", type: .type(.struct, .name), identifier: "$sSiD")
                        }
                    }
                    for conditionalMember in definition.conditionalMembers {
                        if marksVisibility {
                            VisibilityRegion(conditionalMember.condition) {
                                Comment(conditionalMember.text)
                            }
                        } else {
                            Comment(conditionalMember.text)
                        }
                    }
                    if !definition.multilineCommentLines.isEmpty {
                        AtomicComponent(string: definition.multilineCommentLines.joined(separator: "\n" + String(repeating: " ", count: level * 4)), type: .comment)
                    }
                }
            }
        }
    }

    private static let outer = Definition(
        name: "Outer",
        members: ["first", "second"],
        conditionalMembers: [
            (text: "offset: 0x0", condition: .enabled("offsets")),
            (text: "layout", condition: .all([.enabled("layouts"), .disabled("compact")])),
        ],
        nestedDefinitions: [
            Definition(
                name: "Inner",
                members: ["inner"],
                conditionalMembers: [(text: "offset: 0x8", condition: .enabled("offsets"))],
                multilineCommentLines: ["// case a: 0x0", "// case b: 0x1", "// case c: 0x2"],
                nestedDefinitions: [
                    Definition(name: "Innermost", members: ["deepest"], conditionalMembers: [(text: "offset: 0x10", condition: .enabled("offsets"))]),
                ]
            ),
            // Every member conditional: the member list's trailing line break
            // and the block's closing indentation carry "some member is
            // visible".
            Definition(name: "Sibling", conditionalMembers: [(text: "only when not compact", condition: .disabled("compact"))]),
        ]
    )

    // MARK: - Encoding

    @Test("identities survive the identifier encoding, and a visibility tag stays outermost")
    func identityEncodingRoundTrip() {
        let inner = DefinitionTag.adding("Inner", to: "$s4Main3FooV")
        #expect(inner == "\u{6}Inner\u{6}$s4Main3FooV")
        let outer = DefinitionTag.adding("Outer", to: inner)
        let decomposition = DefinitionTag.decompose(outer)
        #expect(decomposition.identities == ["Outer", "Inner"])
        #expect(decomposition.original == "$s4Main3FooV")
        #expect(decomposition.identifier(keepingIdentitiesFrom: 1) == inner)
        #expect(decomposition.identifier(keepingIdentitiesFrom: 2) == "$s4Main3FooV")
        #expect(DefinitionTag.decompose(DefinitionTag.adding("Only", to: nil)).identifier(keepingIdentitiesFrom: 1) == nil)
        #expect(DefinitionTag.decompose("$s4Main3FooV").identities.isEmpty)

        let encodedCondition = VisibilityTag.encode(.enabled("comments"))
        let visibilityTagged = VisibilityTag.adding(encodedCondition, to: "$s4Main3FooV")
        let definitionAddedInside = DefinitionTag.adding("Outer", to: visibilityTagged)
        #expect(VisibilityTag.isTag(definitionAddedInside))
        #expect(VisibilityTag.decode(definitionAddedInside)?.originalIdentifier == DefinitionTag.adding("Outer", to: "$s4Main3FooV"))
        #expect(VisibilityTag.adding(encodedCondition, to: DefinitionTag.adding("Outer", to: "$s4Main3FooV")) == definitionAddedInside)
        #expect(DefinitionTag.decompose(definitionAddedInside).identifier(keepingIdentitiesFrom: 1) == visibilityTagged)
    }

    @Test("both nesting orders with a visibility region produce the same atoms")
    func nestingOrderDoesNotMatter() {
        let content = SemanticString {
            Keyword("var")
            Space()
            AtomicComponent(string: "Int", type: .type(.struct, .name), identifier: "$sSiD")
        }
        let definitionOutside = SemanticString {
            DefinitionRegion("Owner") {
                VisibilityRegion(.enabled("option")) {
                    content
                }
            }
        }
        let visibilityOutside = SemanticString {
            VisibilityRegion(.enabled("option")) {
                DefinitionRegion("Owner") {
                    content
                }
            }
        }
        #expect(definitionOutside.components == visibilityOutside.components)
    }

    // MARK: - Regions change nothing

    @Test("a region prints its content unchanged and keeps its element structure")
    func regionIsTransparent() {
        let plain = SemanticString {
            MemberList(level: 1) {
                Standard("first")
                Standard("second")
                Standard("third")
            }
        }
        let regioned = SemanticString {
            MemberList(level: 1) {
                Standard("first")
                DefinitionRegion("Owner") {
                    Standard("second")
                    Standard("third")
                }
            }
        }
        #expect(regioned.string == plain.string)
        #expect(regioned.components.map(\.string) == plain.components.map(\.string))
    }

    @Test("an async-built region is the same as a sync-built one")
    func asyncRegionMatchesSyncRegion() async throws {
        @Sendable func asyncContent() async throws -> SemanticString {
            SemanticString {
                Keyword("let")
                Space()
                Variable("value")
            }
        }
        let asyncRegion = try await DefinitionRegion("Owner") {
            try await asyncContent()
        }
        let syncRegion = DefinitionRegion("Owner") {
            Keyword("let")
            Space()
            Variable("value")
        }
        #expect(asyncRegion.buildComponents() == syncRegion.buildComponents())
    }

    // MARK: - Separating

    @Test("separating gives back the string printed without regions and finds every region, nested ones included")
    func separationRestoresThePlainPrintAndFindsEveryRegion() throws {
        let marked = Self.render(Self.outer, level: 1, marksDefinitions: true, marksVisibility: true).frozen()
        let unmarked = Self.render(Self.outer, level: 1, marksDefinitions: false, marksVisibility: true).frozen()
        let separation = marked.separatingDefinitionRegions()
        #expect(separation.text == unmarked)

        let regions = separation.definitions.regions
        #expect(regions.map(\.identity) == ["Inner", "Innermost", "Sibling"])
        #expect(regions.map(\.depth) == [0, 1, 0])
        #expect(regions.map(\.enclosingRegionIndex) == [nil, 0, nil])
        let utf8Bytes = Array(marked.text.utf8)
        for region in regions {
            let regionText = String(decoding: utf8Bytes[Int(region.utf8Offset) ..< Int(region.utf8Offset + region.utf8Length)], as: UTF8.self)
            let indentation = String(repeating: " ", count: (region.depth + 1) * 4)
            #expect(regionText.hasPrefix(indentation + "struct " + region.identity + " {"), "\(regionText)")
            #expect(regionText.hasSuffix(indentation + "}"), "\(regionText)")
            // The line break in front of a nested declaration belongs to the
            // enclosing text.
            #expect(utf8Bytes[Int(region.utf8Offset) - 1] == UInt8(ascii: "\n"))
        }
        let innermost = try #require(separation.definitions.regions(withIdentity: "Innermost").first)
        let inner = try #require(separation.definitions.regions(withIdentity: "Inner").first)
        #expect(innermost.utf8Offset > inner.utf8Offset)
        #expect(innermost.utf8Offset + innermost.utf8Length < inner.utf8Offset + inner.utf8Length)

        let plain = Self.render(Self.outer, level: 1, marksDefinitions: false, marksVisibility: false).frozen()
        let plainSeparation = plain.separatingDefinitionRegions()
        #expect(plainSeparation.text == plain)
        #expect(plainSeparation.definitions.isEmpty)
    }

    @Test("the definition and visibility separations run in either order with the same results")
    func separationsCommute() {
        let marked = Self.render(Self.outer, level: 1, marksDefinitions: true, marksVisibility: true).frozen()

        let visibilityFirst = marked.separatingVisibilityRegions()
        let definitionsSecond = visibilityFirst.text.separatingDefinitionRegions()

        let definitionsFirst = marked.separatingDefinitionRegions()
        let visibilitySecond = definitionsFirst.text.separatingVisibilityRegions()

        #expect(definitionsSecond.text == visibilitySecond.text)
        #expect(definitionsSecond.definitions == definitionsFirst.definitions)
        #expect(visibilitySecond.regions == visibilityFirst.regions)
        #expect(visibilitySecond.text == Self.render(Self.outer, level: 1, marksDefinitions: false, marksVisibility: false).frozen())
        // Unmarked definitions do not disturb the visibility separation.
        #expect(visibilityFirst.regions == Self.render(Self.outer, level: 1, marksDefinitions: false, marksVisibility: true).frozen().separatingVisibilityRegions().regions)
    }

    @Test("two regions with the same identity directly next to each other read back as one")
    func adjacentRegionsWithOneIdentityMerge() {
        let marked = SemanticString {
            DefinitionRegion("Twice") {
                Keyword("first")
            }
            DefinitionRegion("Twice") {
                Keyword("second")
            }
            Standard(" ")
            DefinitionRegion("Twice") {
                Keyword("third")
            }
        }.frozen()
        let regions = marked.separatingDefinitionRegions().definitions.regions
        #expect(regions.map(\.utf8Offset) == [0, 12])
        #expect(regions.map(\.utf8Length) == [11, 5])
    }

    // MARK: - Taking a region out

    @Test("a nested definition taken out of its parent's print, indentation removed, is the definition's own print", arguments: [true, false])
    func regionContentIsTheDefinitionsOwnPrint(marksVisibility: Bool) throws {
        let marked = Self.render(Self.outer, level: 1, marksDefinitions: true, marksVisibility: marksVisibility).frozen()
        let visibilitySeparated = marked.separatingVisibilityRegions().text
        let regions = marked.separatingDefinitionRegions().definitions.regions
        #expect(regions.count == 3)
        for region in regions {
            let definition = try #require(Self.outer.definition(named: region.identity))
            let ownPrint = Self.render(definition, level: 1, marksDefinitions: true, marksVisibility: marksVisibility).frozen()

            let takenOut = try #require(marked.content(ofDefinitionRegion: region).removingIndentation(levels: region.depth + 1))
            #expect(takenOut == ownPrint, "\(region.identity)")
            #expect(takenOut.separatingVisibilityRegions().regions == ownPrint.separatingVisibilityRegions().regions, "\(region.identity)")
            #expect(takenOut.separatingVisibilityRegions().text == ownPrint.separatingVisibilityRegions().text, "\(region.identity)")
            #expect(takenOut.separatingDefinitionRegions().definitions == ownPrint.separatingDefinitionRegions().definitions, "\(region.identity)")

            // The same region read off the visibility-separated text.
            let takenOutOfSeparated = try #require(visibilitySeparated.content(ofDefinitionRegion: region).removingIndentation(levels: region.depth + 1))
            #expect(takenOutOfSeparated == ownPrint.separatingVisibilityRegions().text, "\(region.identity)")
        }
    }

    @Test("the README example holds")
    func readmeExample() throws {
        func printStruct(_ name: String, level: Int, nested: [String] = []) -> SemanticString {
            SemanticString {
                DeclarationBlock(level: level) {
                    Keyword("struct")
                    Space()
                    TypeDeclaration(kind: .struct, name)
                } body: {
                    for nestedName in nested {
                        NestedDeclaration {
                            DefinitionRegion(nestedName, content: printStruct(nestedName, level: level + 1))
                        }
                    }
                }
            }
        }

        let printed = printStruct("Outer", level: 1, nested: ["Inner"]).frozen()
        let (text, definitions) = printed.separatingDefinitionRegions()
        #expect(text.string == "struct Outer {\n    struct Inner {}\n}")
        let inner = try #require(definitions.regions(withIdentity: "Inner").first)
        let innerOnItsOwn = printed.content(ofDefinitionRegion: inner).removingIndentation(levels: inner.depth + 1)
        #expect(innerOnItsOwn == printStruct("Inner", level: 1).frozen())
    }

    // MARK: - Removing indentation

    @Test("lines with nothing but their line break, and an empty last line, keep no indentation to remove")
    func blankLinesAreLeftAlone() throws {
        let frozen = SemanticString {
            Standard("    first\n\n    second\r\n\r\n    third\n")
        }.frozen()
        let removed = try #require(frozen.removingIndentation(levels: 1))
        #expect(removed.text == "first\n\nsecond\r\n\r\nthird\n")
        #expect(frozen.removingIndentation(levels: 0) == frozen)
    }

    @Test("a line without the full indentation makes the removal fail")
    func missingIndentationFails() {
        #expect(SemanticString { Standard("    first\n  second") }.frozen().removingIndentation(levels: 1) == nil)
        #expect(SemanticString { Standard("    first\n  \nthird") }.frozen().removingIndentation(levels: 1) == nil)
        #expect(SemanticString { Standard("        first\n    second") }.frozen().removingIndentation(levels: 2) == nil)
        #expect(SemanticString { Standard("\tfirst") }.frozen().removingIndentation(levels: 1) == nil)
    }

    @Test("indentation is removed across span boundaries and inside multi-line atoms")
    func removalCrossesSpansAndReachesInsideAtoms() throws {
        let frozen = SemanticString {
            Standard("  ")
            Standard("  ")
            Keyword("let")
            BreakLine()
            AtomicComponent(string: "    // first\n    // second", type: .comment)
        }.frozen()
        let removed = try #require(frozen.removingIndentation(levels: 1))
        #expect(removed.text == "let\n// first\n// second")
        #expect(removed.components == [
            AtomicComponent(string: "let", type: .keyword),
            AtomicComponent(string: "\n", type: .standard),
            AtomicComponent(string: "// first\n// second", type: .comment),
        ])
    }

    @Test("a span left with nothing is dropped with its identifier, and the table is rebuilt in first-use order")
    func emptiedSpansAreDroppedWithTheirIdentifiers() throws {
        let frozen = SemanticString {
            AtomicComponent(string: "    ", type: .standard, identifier: "indentation")
            AtomicComponent(string: "Int", type: .type(.struct, .name), identifier: "$sSiD")
            BreakLine()
            AtomicComponent(string: "        ", type: .standard, identifier: "indentation")
            AtomicComponent(string: "Bool", type: .type(.struct, .name), identifier: "$sSbD")
        }.frozen()
        let removed = try #require(frozen.removingIndentation(levels: 1))
        #expect(removed.text == "Int\n    Bool")
        #expect(removed.identifierTable == ["$sSiD", "indentation", "$sSbD"])
        #expect(removed.spans.count == 4)

        let fullyRemoved = try #require(SemanticString {
            AtomicComponent(string: "    ", type: .standard, identifier: "indentation")
            AtomicComponent(string: "Int", type: .type(.struct, .name), identifier: "$sSiD")
        }.frozen().removingIndentation(levels: 1))
        #expect(fullyRemoved.identifierTable == ["$sSiD"])
    }

    // MARK: - Misuse traps

    @Test("an empty identity traps")
    func emptyIdentityTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = DefinitionRegion("") {
                Keyword("let")
            }
        }
    }

    @Test("an identity with a control character traps")
    func controlCharacterIdentityTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = DefinitionRegion("Owner\u{6}") {
                Keyword("let")
            }
        }
    }

    @Test("taking out a region read from another string traps")
    func regionFromAnotherStringTraps() async {
        await #expect(processExitsWith: .failure) {
            let marked = SemanticString {
                Keyword("prefix")
                DefinitionRegion("Owner") {
                    Keyword("owned")
                }
            }.frozen()
            let region = marked.separatingDefinitionRegions().definitions.regions[0]
            let other = SemanticString {
                Keyword("prefix")
                Keyword("owned")
            }.frozen()
            _ = other.content(ofDefinitionRegion: region)
        }
    }

    @Test("taking out a region that does not fall on span boundaries traps")
    func regionOffSpanBoundariesTraps() async {
        await #expect(processExitsWith: .failure) {
            let marked = SemanticString {
                Keyword("prefix")
                DefinitionRegion("Owner") {
                    Keyword("owned")
                }
            }.frozen()
            _ = marked.content(ofDefinitionRegion: .init(identity: "Owner", utf8Offset: 3, utf8Length: 5, depth: 0, enclosingRegionIndex: nil))
        }
    }
}
