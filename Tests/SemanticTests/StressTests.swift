import Testing
import Foundation
@testable import Semantic

// MARK: - Stress + Baseline Timing Tests
//
// These tests exercise large/deeply-nested inputs to surface regressions and
// record coarse wall-clock numbers. Each test sanity-checks output AND asserts
// a loose upper-bound elapsed time using `ContinuousClock`. Thresholds are
// GENEROUS baselines (≈10× locally observed values) — Task 8 will tighten them
// after the optimizations in the performance design spec land.

// MARK: - Scale

@Suite("Scale")
struct ScaleStressTests {
    @Test("10k atomic components via builder — string + components flatten")
    func tenKAtomicComponentsViaBuilder() {
        let clock = ContinuousClock()
        let semanticString = SemanticString {
            for index in 0..<10_000 {
                Standard("\(index)")
            }
        }

        let buildElapsed = clock.measure {
            _ = semanticString.string
            _ = semanticString.components
        }

        // Sanity: output ends with the last number and has 10k components.
        #expect(semanticString.string.hasSuffix("9999"))
        #expect(semanticString.components.count == 10_000)

        // Generous baseline — Task 8 tightens.
        #expect(buildElapsed < .seconds(5))
    }

    @Test("10k-component Joined with prefix/suffix")
    func tenKJoinedWithPrefixSuffix() {
        let clock = ContinuousClock()
        let joined = Joined(separator: ", ", prefix: "[", suffix: "]") {
            for index in 0..<10_000 {
                Standard("\(index)")
            }
        }
        let semanticString = SemanticString(joined)

        let buildElapsed = clock.measure {
            _ = semanticString.string
            _ = semanticString.components
        }

        // Sanity: starts with "[0, " and ends with ", 9999]".
        #expect(semanticString.string.hasPrefix("[0, "))
        #expect(semanticString.string.hasSuffix(", 9999]"))
        // 10k items + 9,999 separators + 2 (prefix + suffix)
        #expect(semanticString.components.count == 10_000 + 9_999 + 2)

        #expect(buildElapsed < .seconds(10))
    }

    @Test("10k-component Joined without prefix/suffix")
    func tenKJoinedWithoutPrefixSuffix() {
        let clock = ContinuousClock()
        let joined = Joined(separator: ", ") {
            for index in 0..<10_000 {
                Standard("\(index)")
            }
        }
        let semanticString = SemanticString(joined)

        let buildElapsed = clock.measure {
            _ = semanticString.string
            _ = semanticString.components
        }

        // Sanity: starts with "0, " and ends with "9999".
        #expect(semanticString.string.hasPrefix("0, "))
        #expect(semanticString.string.hasSuffix("9999"))
        // 10k items + 9,999 separators
        #expect(semanticString.components.count == 10_000 + 9_999)

        #expect(buildElapsed < .seconds(10))
    }

    @Test("10k-element ForEach with component separator")
    func tenKForEachComponentSeparator() {
        let clock = ContinuousClock()
        let items = Array(0..<10_000)
        let forEach = ForEach(items, separator: Standard(", ")) { item in
            Standard("\(item)")
        }
        let semanticString = SemanticString(forEach)

        let buildElapsed = clock.measure {
            _ = semanticString.string
            _ = semanticString.components
        }

        #expect(semanticString.string.hasSuffix("9999"))
        // 10k items + 9,999 separators
        #expect(semanticString.components.count == 10_000 + 9_999)

        #expect(buildElapsed < .seconds(10))
    }
}

// MARK: - Depth

@Suite("Depth")
struct DepthStressTests {
    @Test("100-level NestedDeclaration wrapping a DeclarationBlock")
    func deepNestedDeclaration() {
        let clock = ContinuousClock()
        let depth = 100

        // Build a tower where each level wraps the next in a NestedDeclaration.
        // The innermost level is a simple DeclarationBlock.
        func build(level: Int) -> SemanticString {
            if level >= depth {
                return SemanticString {
                    DeclarationBlock(level: level) {
                        Keyword("struct")
                        Space()
                        TypeDeclaration(kind: .struct, "Leaf")
                    } body: {
                        Standard("")
                    }
                }
            }
            let inner = build(level: level + 1)
            return SemanticString {
                NestedDeclaration {
                    DeclarationBlock(level: level) {
                        Keyword("struct")
                        Space()
                        TypeDeclaration(kind: .struct, "Level\(level)")
                    } body: {
                        inner
                    }
                }
            }
        }

        let semanticString = build(level: 1)

        let buildElapsed = clock.measure {
            _ = semanticString.string
            _ = semanticString.components
        }

        // Sanity: output is non-empty and closes with a brace.
        #expect(!semanticString.string.isEmpty)
        #expect(semanticString.string.hasSuffix("}"))

        #expect(buildElapsed < .seconds(10))
    }

    @Test("50-level nested DeclarationBlocks, each with a 10-item MemberList")
    func deepNestedDeclarationBlocksWithMemberList() {
        let clock = ContinuousClock()
        let depth = 50

        func build(level: Int) -> SemanticString {
            if level >= depth {
                return SemanticString {
                    DeclarationBlock(level: level) {
                        Keyword("struct")
                        Space()
                        TypeDeclaration(kind: .struct, "Leaf")
                    } body: {
                        MemberList(level: level) {
                            for index in 0..<10 {
                                SemanticString {
                                    Keyword("var")
                                    Space()
                                    Variable("leafVar\(index)")
                                    Standard(": ")
                                    TypeName(kind: .struct, "Int")
                                }
                            }
                        }
                    }
                }
            }
            let inner = build(level: level + 1)
            return SemanticString {
                DeclarationBlock(level: level) {
                    Keyword("struct")
                    Space()
                    TypeDeclaration(kind: .struct, "Level\(level)")
                } body: {
                    MemberList(level: level) {
                        for index in 0..<10 {
                            if index == 0 {
                                inner
                            } else {
                                SemanticString {
                                    Keyword("var")
                                    Space()
                                    Variable("member\(level)_\(index)")
                                    Standard(": ")
                                    TypeName(kind: .struct, "Int")
                                }
                            }
                        }
                    }
                }
            }
        }

        let semanticString = build(level: 1)

        let buildElapsed = clock.measure {
            _ = semanticString.string
            _ = semanticString.components
        }

        #expect(!semanticString.string.isEmpty)
        #expect(semanticString.string.hasSuffix("}"))

        #expect(buildElapsed < .seconds(15))
    }
}

// MARK: - Cache Reuse

@Suite("Cache Reuse")
struct CacheReuseStressTests {
    @Test("1k reads of .string on a 1k-component SemanticString — cache is O(1)")
    func repeatedStringReadsAreCached() {
        let clock = ContinuousClock()
        let semanticString = SemanticString {
            for index in 0..<1_000 {
                Standard("\(index)")
            }
        }

        // First read builds and caches.
        let buildElapsed = clock.measure {
            _ = semanticString.string
        }

        // 1,000 subsequent reads must hit the cache.
        let readElapsed = clock.measure {
            for _ in 0..<1_000 {
                _ = semanticString.string
            }
        }

        // Sanity.
        #expect(semanticString.string.hasSuffix("999"))

        // Relative multiplier: 1,000 cached reads must stay within 2× of the
        // one initial build. If the cache is broken, readElapsed would be
        // ~1000× buildElapsed, not <2×.
        #expect(readElapsed < buildElapsed * 2)
    }

    @Test("1k reads of .components on a 1k-component SemanticString — cache is O(1)")
    func repeatedComponentsReadsAreCached() {
        let clock = ContinuousClock()
        let semanticString = SemanticString {
            for index in 0..<1_000 {
                Standard("\(index)")
            }
        }

        let buildElapsed = clock.measure {
            _ = semanticString.components
        }

        let readElapsed = clock.measure {
            for _ in 0..<1_000 {
                _ = semanticString.components
            }
        }

        #expect(semanticString.components.count == 1_000)

        #expect(readElapsed < buildElapsed * 2)
    }
}

// MARK: - Chained Appending

@Suite("Chained Appending")
struct ChainedAppendingStressTests {
    @Test("1k sequential .appending(...) calls — COW does not balloon cost")
    func thousandAppendingCalls() {
        let clock = ContinuousClock()
        let iterations = 1_000

        let buildElapsed = clock.measure {
            var accumulator = SemanticString(Standard("base"))
            for index in 0..<iterations {
                accumulator = accumulator.appending(Standard("\(index)"))
            }
            // Keep a live reference so the optimizer can't drop the work.
            #expect(accumulator.count == iterations + 1)
            #expect(accumulator.string.hasSuffix("\(iterations - 1)"))
        }

        #expect(buildElapsed < .seconds(10))
    }

    @Test("1k += mutations on a var — in-place growth")
    func thousandPlusEqualsMutations() {
        let clock = ContinuousClock()
        let iterations = 1_000

        var accumulator = SemanticString(Standard("base"))
        let buildElapsed = clock.measure {
            for index in 0..<iterations {
                accumulator += Standard("\(index)")
            }
        }

        #expect(accumulator.count == iterations + 1)
        #expect(accumulator.string.hasSuffix("\(iterations - 1)"))

        #expect(buildElapsed < .seconds(5))
    }
}

// MARK: - Codable at Scale

@Suite("Codable at Scale")
struct CodableAtScaleStressTests {
    @Test("Round-trip encode/decode a 10k-component SemanticString")
    func roundTripTenK() throws {
        let clock = ContinuousClock()
        let original = SemanticString {
            for index in 0..<10_000 {
                Standard("\(index)")
            }
        }

        // Prime caches so the timing measures the codable path, not flattening.
        _ = original.components

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        var roundTripped: SemanticString?
        let roundTripElapsed = try clock.measure {
            let data = try encoder.encode(original)
            roundTripped = try decoder.decode(SemanticString.self, from: data)
        }

        let decoded = try #require(roundTripped)
        #expect(decoded.components.count == original.components.count)
        #expect(decoded.string == original.string)

        #expect(roundTripElapsed < .seconds(30))
    }
}

// MARK: - Hashable at Scale

@Suite("Hashable at Scale")
struct HashableAtScaleStressTests {
    @Test("Insert 1k distinct SemanticStrings into a Set — all unique")
    func insertThousandDistinctIntoSet() {
        let clock = ContinuousClock()
        let items = (0..<1_000).map { index in
            SemanticString {
                Keyword("var")
                Space()
                Variable("item\(index)")
            }
        }

        var set: Set<SemanticString> = []
        let insertElapsed = clock.measure {
            for item in items {
                set.insert(item)
            }
        }

        #expect(set.count == 1_000)

        #expect(insertElapsed < .seconds(10))
    }

    @Test("Insert 1k copies of the same content into a Set — count is 1")
    func insertThousandIdenticalIntoSet() {
        let clock = ContinuousClock()
        let shared = SemanticString {
            Keyword("let")
            Space()
            Variable("shared")
            Standard(" = ")
            Numeric("42")
        }

        var set: Set<SemanticString> = []
        let insertElapsed = clock.measure {
            for _ in 0..<1_000 {
                set.insert(shared)
            }
        }

        #expect(set.count == 1)

        #expect(insertElapsed < .seconds(5))
    }
}
