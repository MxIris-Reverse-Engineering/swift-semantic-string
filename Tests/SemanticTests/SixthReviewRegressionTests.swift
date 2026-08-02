import Foundation
import Testing
@testable import Semantic

// MARK: - Fixtures

/// A component whose flattening consists of nothing but a zero-length atom.
/// `AtomicComponent.buildComponents()` filters empties itself, so exercising
/// the array-initializer filter requires a component that hands one out
/// directly.
private struct BlankEmittingComponent: SemanticStringComponent {
    func buildComponents() -> [AtomicComponent] {
        [AtomicComponent(string: "", type: .standard)]
    }
}

/// A component whose flattening mixes a real atom with a zero-length one.
private struct MixedEmittingComponent: SemanticStringComponent {
    let string: String

    func buildComponents() -> [AtomicComponent] {
        [
            AtomicComponent(string: string, type: .standard),
            AtomicComponent(string: "", type: .standard),
        ]
    }
}

// MARK: - Tests

/// Regression tests for the sixth review round — the post-merge-review
/// verification pass. Each pin was confirmed failing against the unfixed
/// code (or, for the two invariant pins, against a hand-mutated build that
/// the rest of the suite failed to catch); the themes:
///
/// - **Invariant coverage.** Mutation testing showed the two storage
///   invariants (`appendContents(of:)` splices element boundaries;
///   zero-length atoms never enter `atoms`) could both be corrupted while
///   every existing test still passed. The container pins here fail against
///   those mutants.
/// - **Zero-width appends.** Appending a component that renders nothing
///   (`Indent(level: 0)`, `Standard("")`, `EmptyComponent`, an empty
///   `SemanticString`) used to drop the string cache and permanently
///   materialize the whole 1:1 boundary table. It is now a complete no-op,
///   matching `append("", type:)`.
/// - **CRLF-terminated bodies.** `DeclarationBlock`'s "body already ends
///   with a newline" test used grapheme-based `hasSuffix("\n")`, which is
///   false for a body ending in `"\r\n"` (one `Character`), producing a
///   spurious blank line before the closing brace.
/// - **Frozen `==` undercover enforcement.** The resolving walk never
///   checked that it reached `text.endIndex`, so undercovering (malformed)
///   values compared equal, entered hashed containers, and trapped later in
///   an unrelated read.
@Suite("Sixth review round regressions")
struct SixthReviewRegressionTests {
    // MARK: S1 — appendContents(of:) splices element boundaries

    @Test("Appending a string with its own boundary table keeps every element boundary")
    func appendSplicesMaterializedBoundaryTable() {
        var receiver = SemanticString()
        receiver.append("a", type: .standard)
        // A two-atom element materializes the receiver's boundary table.
        receiver.append(Group([SemanticString(Standard("g1")), SemanticString(Standard("g2"))]))

        var operand = SemanticString()
        operand.append(Group([SemanticString(Standard("x1")), SemanticString(Standard("x2"))]))
        operand.append("y", type: .standard)

        receiver.append(operand)

        let rendered = SemanticString(MemberList(level: 1, content: receiver)).string
        #expect(rendered == "\n    a\n    g1g2\n    x1x2\n    y\n")
    }

    @Test("Appending a streamed (1:1) string onto a table-carrying receiver keeps per-atom elements")
    func appendSplicesStreamedOperandOntoMaterializedReceiver() {
        var receiver = SemanticString()
        receiver.append(Group([SemanticString(Standard("g1")), SemanticString(Standard("g2"))]))

        var streamedOperand = SemanticString()
        streamedOperand.append("m", type: .standard)
        streamedOperand.append("n", type: .standard)

        receiver.append(streamedOperand)

        let rendered = SemanticString(MemberList(level: 1, content: receiver)).string
        #expect(rendered == "\n    g1g2\n    m\n    n\n")
    }

    // MARK: S2 — zero-length atoms never escape the [Component] array initializers

    @Test("BlockList/MemberList/Rows array initializers filter zero-length atoms")
    func arrayInitializersFilterZeroLengthAtoms() {
        // All-blank input renders nothing — under the unfiltered mutant the
        // zero-length atoms count as content and every separator leaks out.
        let blankBlockList = BlockList([BlankEmittingComponent(), BlankEmittingComponent()])
        #expect(blankBlockList.buildComponents().isEmpty)
        #expect(SemanticString(blankBlockList).string == "")

        // Mixed input keeps the real atoms only, and no zero-length atom
        // reaches the public output of any of the three containers.
        let mixedItems = [MixedEmittingComponent(string: "m1"), MixedEmittingComponent(string: "m2")]
        let memberListComponents = MemberList(level: 1, mixedItems).buildComponents()
        #expect(memberListComponents.allSatisfy { !$0.string.isEmpty })
        #expect(memberListComponents.map(\.string).joined() == "\n    m1\n    m2\n")

        let blockListComponents = BlockList(mixedItems).buildComponents()
        #expect(blockListComponents.allSatisfy { !$0.string.isEmpty })
        #expect(blockListComponents.map(\.string).joined() == "\nm1\nm2\n")

        let rowsComponents = Rows(level: 0, mixedItems).buildComponents()
        #expect(rowsComponents.allSatisfy { !$0.string.isEmpty })
        #expect(rowsComponents.map(\.string).joined() == "m1\nm2")
    }

    // MARK: S3 — zero-width appends are complete no-ops

    @Test("Appending components that render nothing keeps the cache and the 1:1 boundary table")
    func zeroWidthAppendIsACompleteNoOp() {
        var streamed = SemanticString()
        for index in 0 ..< 100 {
            streamed.append("token\(index) ", type: .standard)
        }
        let expectedString = streamed.string // warm the cache

        var subject = streamed
        subject.append(Indent(level: 0))
        subject.append(Standard(""))
        subject.append(EmptyComponent())
        subject.append(SemanticString())

        // No boundary table materialized, no cache dropped, no copy made.
        #expect(subject._storage.elementEndOffsets == nil)
        #expect(subject._storage.cachedStringIfPresent() == expectedString)
        #expect(subject == streamed)
        #expect(subject.count == streamed.count)
        #expect(subject.string == expectedString)
    }

    // MARK: S4 — DeclarationBlock recognizes a CRLF-terminated body

    @Test("A body ending in CRLF gets no spurious blank line before the closing brace")
    func declarationBlockTreatsCarriageReturnLineFeedAsNewline() {
        let carriageReturnBody = SemanticString(components: [
            AtomicComponent(string: "  var x: Int\r\n", type: .standard),
        ])
        let lineFeedBody = SemanticString(components: [
            AtomicComponent(string: "  var x: Int\n", type: .standard),
        ])

        let carriageReturnBlock = SemanticString(
            DeclarationBlock(level: 0) {
                TypeDeclaration(kind: .struct, "struct S")
            } body: {
                carriageReturnBody
            }
        )
        let lineFeedBlock = SemanticString(
            DeclarationBlock(level: 0) {
                TypeDeclaration(kind: .struct, "struct S")
            } body: {
                lineFeedBody
            }
        )

        #expect(carriageReturnBlock.string == "struct S {  var x: Int\r\n}")
        #expect(lineFeedBlock.string == "struct S {  var x: Int\n}")
    }

    // MARK: S5 — frozen == enforces span coverage on the resolving path

    @Test("Undercovering spans trap in == instead of comparing equal")
    func frozenEqualityTrapsOnUndercoveringSpans() async {
        // Different identifier tables force the resolving walk (the
        // byte-identical fast path requires identical tables). Both values
        // undercover "abc" with a single 1-byte span; before the fix they
        // compared equal, entered hashed containers, and trapped later in an
        // unrelated read.
        await #expect(processExitsWith: .failure) {
            let first = FrozenSemanticString(
                text: "abc",
                spans: [.init(length: 1, typeCode: 0, identifierIndex: 1)],
                identifierTable: ["x"]
            )
            let second = FrozenSemanticString(
                text: "abc",
                spans: [.init(length: 1, typeCode: 0, identifierIndex: 2)],
                identifierTable: ["y", "x"]
            )
            _ = first == second
        }
    }
}
