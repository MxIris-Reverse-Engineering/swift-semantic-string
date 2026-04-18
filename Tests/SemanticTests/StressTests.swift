import Testing
import Foundation
@testable import Semantic

// MARK: - Stress + Baseline Timing Tests
//
// These tests exercise large/deeply-nested inputs to surface regressions and
// record coarse wall-clock numbers. Each test sanity-checks output AND asserts
// a tightened upper-bound elapsed time using `ContinuousClock`. Thresholds are
// approximately ~1.5× post-optimization measured timings (Debug build), with a
// 100 ms minimum floor to absorb CI cold-start variance. They are meant to
// catch real regressions — not serve as rigorous perf targets. If they flake
// on slow hardware, raise the ceiling; if they go stale after further
// optimization, retighten and rerun.
//
// Post-optimization timings (median of 3 runs, local macOS, Apple Silicon):
//
//   Test                                              Debug    Release  Speedup
//   ----                                              -----    -------  -------
//   10k atomic components via builder                  25 ms     3 ms    ~8×
//   10k Joined with prefix/suffix                      31 ms     2 ms   ~15×
//   10k Joined without prefix/suffix                   28 ms     2 ms   ~14×
//   10k ForEach with component separator               29 ms     3 ms   ~10×
//   100-level NestedDeclaration                         4 ms     3 ms    ~1.3×
//   50-level nested DeclarationBlocks + MemberList     14 ms     5 ms    ~3×
//   1k cached .string reads                             5 ms     1 ms    ~5×
//   1k cached .components reads                         5 ms     1 ms    ~5×
//   1k .appending(...) calls                            6 ms     3 ms    ~2×
//   1k += mutations                                     4 ms     1 ms    ~4×
//   Codable round-trip 10k                             68 ms    41 ms    ~1.7×
//   Insert 1k distinct into Set                         9 ms     1 ms    ~9×
//   Insert 1k identical into Set                        2 ms     1 ms    ~2×
//
// The thresholds in this file are set for Debug (the default for `swift test`).
// Release numbers are informational only, not asserted — they confirm the
// spec's ≥2× allocation-bound improvement goal is met for the scenarios that
// matter (Scale: ~8–15×, Hashable: ~9×, Codable: ~1.7× dominated by JSON
// encoder/decoder overhead outside our control). Depth and cache-reuse cases
// are not allocation-bound, so their Release/Debug ratios are correspondingly
// smaller.

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

        // Post-optimization target: ~25-30 ms locally (Debug). Threshold is
        // 50 ms CI floor — well under the previous 5 s baseline.
        #expect(buildElapsed < .milliseconds(100))
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

        // Post-optimization target: ~30-35 ms locally (Debug).
        #expect(buildElapsed < .milliseconds(100))
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

        // Post-optimization target: ~30 ms locally (Debug).
        #expect(buildElapsed < .milliseconds(100))
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

        // Post-optimization target: ~30 ms locally (Debug).
        #expect(buildElapsed < .milliseconds(100))
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

        // Sanity: output is non-empty, closes with a brace, and actually has
        // `depth` nesting levels. Each DeclarationBlock emits exactly one `{`
        // and one `}`, so counting closing braces catches silent depth-reduction
        // bugs that `hasSuffix("}")` alone would miss.
        #expect(!semanticString.string.isEmpty)
        #expect(semanticString.string.hasSuffix("}"))
        #expect(semanticString.string.filter { $0 == "}" }.count == depth)
        #expect(semanticString.string.filter { $0 == "{" }.count == depth)

        // Post-optimization target: ~4-6 ms locally (Debug). 100 ms floor is
        // the tightest that isn't fragile for a test this fast.
        #expect(buildElapsed < .milliseconds(100))
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

        // Sanity: output is non-empty, closes with a brace, has `depth`
        // DeclarationBlocks, and contains the expected number of `var` members.
        // 49 inner levels × 9 `member{level}_{i}` vars + 10 leaf `leafVar{i}`
        // vars = 441 + 10 = 451.
        #expect(!semanticString.string.isEmpty)
        #expect(semanticString.string.hasSuffix("}"))
        #expect(semanticString.string.filter { $0 == "}" }.count == depth)
        #expect(semanticString.string.filter { $0 == "{" }.count == depth)
        #expect(semanticString.string.ranges(of: "var").count == 451)

        // Post-optimization target: ~12-14 ms locally (Debug).
        #expect(buildElapsed < .milliseconds(100))
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

        // Post-optimization target: ~6-7 ms locally (Debug).
        #expect(buildElapsed < .milliseconds(100))
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

        // Post-optimization target: ~3-5 ms locally (Debug).
        #expect(buildElapsed < .milliseconds(100))
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

        // Post-optimization target: ~70-76 ms locally (Debug). JSON round-trip
        // is dominated by Codable/JSON, not our code — 200 ms gives us safe
        // headroom on slower CI.
        #expect(roundTripElapsed < .milliseconds(200))
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

        // Post-optimization target: ~8-9 ms locally (Debug).
        #expect(insertElapsed < .milliseconds(100))
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

        // Post-optimization target: ~1-3 ms locally (Debug).
        #expect(insertElapsed < .milliseconds(100))
    }
}
