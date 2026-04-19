# SemanticString Performance Optimization & Stress Tests

**Date:** 2026-04-18
**Status:** Implemented (2026-04-18)

## Goal

Reduce allocation and copy overhead in the `SemanticString` hot path (flattening and string concatenation) without changing any observable behavior. Ship two new test targets alongside the optimization:

1. **Correctness tests** — lock down current behavior so the optimization cannot silently regress output, ordering, caching, or COW semantics.
2. **Stress tests** — exercise large/deeply-nested inputs to surface regressions and provide coarse time/allocation numbers for before/after comparison.

Non-goals:

- No public API changes.
- No new component types.
- No behavioral changes (same `.string`, same `.components` ordering, same Codable payload, same hash).

## Scope

### Files touched

| File | Change |
|---|---|
| `Sources/Semantic/SemanticString.swift` | `components` / `string` getters: replace `flatMap`/`+=` with capacity-reserving loops |
| `Sources/Semantic/Components/Joined.swift` | Build result as `prefix ++ items-with-separators ++ suffix`, drop `insert(contentsOf:at: 0)` |
| `Sources/Semantic/Components/Group.swift` | `reserveCapacity` on result; minor cleanup |
| `Sources/Semantic/Components/Block.swift` | `DeclarationBlock`/`MemberList`/`BlockList`: `reserveCapacity`; cache header indent in a local constant |
| `Sources/Semantic/Components/Other.swift` | `Indent`: static cache of indent strings for levels 0…16; fall back to computed string for larger levels |
| `Tests/SemanticTests/StressTests.swift` | **New.** Scale + depth + caching + encoding stress |
| `Tests/SemanticTests/CorrectnessTests.swift` | **New.** Behavioral lock-down for the optimized paths |

### Files not touched

- `SemanticStringBuilder.swift`, `SemanticStringComponent.swift`, `SemanticType.swift`, atomic component files (`Keyword.swift`, `Variable.swift`, …) — the hot path does not run through them individually enough to matter, and they are already minimal.

## Optimizations

### 1. `SemanticString.components` — drop `flatMap`

Current (`SemanticString.swift:74`):

```swift
let computed = _storage.elements.flatMap { $0.buildComponents() }
```

`flatMap` on `[any SemanticStringComponent]` allocates one intermediate `[AtomicComponent]` per element, then concatenates. Replace with:

```swift
var computed: [AtomicComponent] = []
computed.reserveCapacity(_storage.elements.count)  // lower bound; usually 1:1
for element in _storage.elements {
    computed.append(contentsOf: element.buildComponents())
}
```

The intermediate arrays from each `buildComponents()` call still exist, but the outer array now grows in one go with a sensible lower-bound reserve. Cost is the same in the worst case and strictly lower when elements are atomic (1:1).

### 2. `SemanticString.string` — reserve UTF-8 capacity

Current (`SemanticString.swift:88-92`):

```swift
var computed = ""
for atomicComponent in atomicComponents {
    computed += atomicComponent.string
}
```

Replace with a two-pass loop: first sum `utf8.count`, then reserve, then concatenate. Keeps Unicode correctness (we are not slicing bytes, just preallocating storage).

```swift
var total = 0
for atomicComponent in atomicComponents {
    total += atomicComponent.string.utf8.count
}
var computed = ""
computed.reserveCapacity(total)
for atomicComponent in atomicComponents {
    computed += atomicComponent.string
}
```

### 3. `Joined.buildComponents` — no front insertion

Current (`Joined.swift:155-182`) builds `items-with-separators` first then `insert(contentsOf: prefixComponents, at: 0)` — O(n) shift. Rewrite:

```swift
public func buildComponents() -> [AtomicComponent] {
    // First pass: materialize item component arrays, count empties/non-empties
    var materialized: [[AtomicComponent]] = []
    materialized.reserveCapacity(items.count)
    var totalCount = 0
    for item in items {
        let built = item.buildComponents()
        if !built.isEmpty {
            materialized.append(built)
            totalCount += built.count
        }
    }
    guard !materialized.isEmpty else { return [] }

    let sepComponents = separator.buildComponents()
    let prefixComponents = prefix?.buildComponents() ?? []
    let suffixComponents = suffix?.buildComponents() ?? []

    var result: [AtomicComponent] = []
    result.reserveCapacity(
        prefixComponents.count
        + totalCount
        + sepComponents.count * max(materialized.count - 1, 0)
        + suffixComponents.count
    )
    result.append(contentsOf: prefixComponents)
    for (index, group) in materialized.enumerated() {
        if index > 0 { result.append(contentsOf: sepComponents) }
        result.append(contentsOf: group)
    }
    result.append(contentsOf: suffixComponents)
    return result
}
```

Two passes, but exactly one allocation for `result` and zero O(n) shifts.

### 4. `Indent` — cached strings for levels 0…16

Add to `Other.swift`:

```swift
@usableFromInline
enum CommonAtomicComponents {
    @usableFromInline static let breakLine = AtomicComponent(string: "\n", type: .standard)
    @usableFromInline static let space = AtomicComponent(string: " ", type: .standard)

    /// Cached indent strings for levels 0…16 (common depth for code generation).
    @usableFromInline static let indentStrings: [String] = (0...16).map {
        String(repeating: " ", count: $0 * 4)
    }
}
```

Update `Indent.description` and `Indent.string`:

```swift
public var description: String {
    guard level > 0 else { return "" }
    if level <= 16 { return CommonAtomicComponents.indentStrings[level] }
    return String(repeating: " ", count: level * 4)
}
```

`DeclarationBlock.buildComponents()` also uses `String(repeating:count:)` directly — replace both call sites (header indent + closing brace indent) with a single local constant computed once via the same cache.

### 5. `Group`, `MemberList`, `BlockList`, `DeclarationBlock` — `reserveCapacity`

All of these build a `[AtomicComponent]` result via repeated `append`/`append(contentsOf:)`. Each gets a pre-pass or a conservative lower-bound reserve:

- `Group`: `result.reserveCapacity(items.count)` (most items are atomic, so 1:1 is a good first guess)
- `MemberList`: reserve `items.count * 3 + 1` (break + indent + item + trailing break, rough)
- `BlockList`: reserve `items.count * 2 + 1` (break + item + trailing break)
- `DeclarationBlock`: reserve `header.count + body.count + 5` (header, space, open brace, body, break, indent, close brace)

Reserves are hints — Swift `Array` grows geometrically regardless, so over-reserving is harmless and under-reserving is just "same as before."

## Correctness Tests (`CorrectnessTests.swift`)

New file under `Tests/SemanticTests/`. Suite-per-concern using Swift Testing.

**@Suite("Golden Master")** — hardcoded expected strings for complex constructions:

- A `DeclarationBlock` (level 1) containing a `MemberList` with 5 heterogeneous members (comment, var decl, func decl, nested struct, blank line).
- A `BlockList` of three protocol declarations with `.separatedByEmptyLine()`.
- A `Joined` with builder-form prefix and suffix, mixed empty/non-empty items.
- A tuple-heavy builder (2 and 3 element tuples interleaved with arrays and optionals).

Each test asserts `semanticString.string == <hardcoded>` and spot-checks `components` length and selected types.

**@Suite("Indent All Levels")** — for level in 0…20: `Indent(level: level).string == String(repeating: " ", count: level * 4)` and corresponding `buildComponents()`.

**@Suite("Joined Ordering")** — prefix-only, suffix-only, both, neither; string separator and component separator; all items empty (expect empty result); single non-empty item (no separator emitted).

**@Suite("Flatten Order")** — manually construct the expected `[AtomicComponent]` for mixed `Group { Joined { ForEach { BlockList { MemberList { NestedDeclaration { ... }}}}}}` and compare element-wise using `==` on `AtomicComponent`.

**@Suite("Cache Coherence")** — read `.string` and `.components` twice, expect identity-level equal results; then `append`, expect new values; then assert pre-append cache is no longer returned.

**@Suite("COW Semantics")** — create `original`, copy to `var copy`, mutate `copy` via each of: `append(_:type:)`, `append(_: some SemanticStringComponent)`, `append(_: SemanticString)`, `+=`, `write(_:)`. After each, assert `original` is unchanged.

**@Suite("Codable Round-trip Deep Equal")** — for a complex construction, `JSONEncoder` → `Data` → `JSONDecoder` → `SemanticString`, then element-wise `==` on `components` (already `Hashable`, but also string + type per element).

**@Suite("Hashable Invariants")** — same builder invoked twice → equal + same hash; same semantic content via different construction paths (atomic array init vs builder) → equal + same hash.

**@Suite("Empty & Boundary")** — empty builder, empty `Joined`, all children `Standard("")`, single-element collections, `Indent(level: 0)` returns empty, zero-width `Space` replacements.

## Stress Tests (`StressTests.swift`)

New file under `Tests/SemanticTests/`. Each test sanity-checks output (at least string length or a trailing character) and asserts a loose upper bound on wall-clock time using `ContinuousClock`. Thresholds sized at ~10× the local-measured value so they fail only on clear regressions.

**@Suite("Scale")**:

- 10 000 atomic components via builder → `.string` once, `.components` once.
- 10 000-component `Joined(separator: ", ")` with and without prefix/suffix.
- 10 000-element `ForEach` with component separator.

**@Suite("Depth")**:

- 100 levels of `NestedDeclaration` wrapping a `DeclarationBlock` — exercises recursion.
- 50 `DeclarationBlock`s nested via `body`, each with a 10-item `MemberList`.

**@Suite("Cache Reuse")**:

- Build a 1 000-component `SemanticString`; read `.string` 1 000 times, assert total elapsed < single-build elapsed × 2 (cache must be O(1)).
- Same for `.components`.

**@Suite("Chained Appending")**:

- 1 000 sequential `appending` calls on a base — verify COW does not balloon cost; assert final `count == 1000`.
- 1 000 `+=` mutations on a `var` — verify in-place growth (no per-step reallocation of storage).

**@Suite("Codable at Scale")**:

- Encode + decode a 10 000-component `SemanticString`; assert round-trip `components.count` matches.

**@Suite("Hashable at Scale")**:

- Insert 1 000 distinct `SemanticString`s into a `Set`; assert `count == 1000`.
- Insert 1 000 copies of the same content; assert `count == 1`.

## Implementation Plan (high-level)

Ordered so tests gate every change:

1. Add `CorrectnessTests.swift` against **current** implementation — lock in existing behavior.
2. Add `StressTests.swift` — record baseline numbers (informational, thresholds set later).
3. Apply optimizations in this order, running both suites after each step:
   1. `Indent` cache + `DeclarationBlock` indent dedup (lowest-risk, clearest win).
   2. `Joined` rewrite (highest algorithmic improvement).
   3. `SemanticString.components` getter rewrite.
   4. `SemanticString.string` two-pass reserve.
   5. `reserveCapacity` sprinkle across `Group`/`BlockList`/`MemberList`/`DeclarationBlock`.
4. Tune stress-test thresholds to post-optimization numbers × ~1.5 margin.

## Risks

- **Indent cache size (17 entries)**: If real code generates >16 levels of nesting, fallback path still works but is slower — same as today. No correctness risk.
- **Joined two-pass materialization**: We materialize `[[AtomicComponent]]` which adds one outer array. For very large `items.count`, this is `items.count` extra array headers (~48 bytes each). Still much cheaper than O(n) front-insert. If profiling shows this is the wrong trade-off, a one-pass variant is straightforward (build items first, then copy into a final array with reserved capacity).
- **Stress-test thresholds**: Wall-clock assertions are fragile across machines/CI. Thresholds will be generous; if flaky, drop the timing assertion and keep the test as a pure smoke test (still valuable as a regression canary).

## Success Criteria

- All existing tests pass unchanged.
- New correctness tests pass against unchanged code (baseline) and after every optimization step.
- Stress tests show measurable improvement (≥2× on allocation-bound scenarios; no regression elsewhere).
- No public API diff.

## Implementation Results

All success criteria met. Shipped in 15 commits (2026-04-18, oldest → newest):

| Commit | Change |
|---|---|
| `5c35cc0` | perf: optimize core data structures to eliminate redundant allocations |
| `a68a987` | docs: add detailed documentation for block components |
| `49bb04b` | test: add `CorrectnessTests` locking current behavior |
| `d73a68b` | test: strengthen cache, construction path, and UTF-8 correctness tests |
| `f487313` | test: add `StressTests` with generous baseline thresholds |
| `8417a1c` | test: strengthen depth sanity checks and clarify threshold comment |
| `ec69a48` | perf: cache `Indent` strings for levels 0…16 (optimization #4) |
| `960d074` | refactor: extract `CommonAtomicComponents.indentString(forLevel:)` helper |
| `24b33d1` | perf: rewrite `Joined.buildComponents` to eliminate O(n) prefix insert (optimization #3) |
| `bb6ccb8` | perf: replace `flatMap` in `SemanticString.components` with reserveCapacity loop (optimization #1) |
| `95363ed` | perf: pre-reserve UTF-8 capacity in `SemanticString.string` (optimization #2) |
| `9739f97` | perf: `reserveCapacity` hints in `Group`/`BlockList`/`MemberList`/`DeclarationBlock` (optimization #5) |
| `a51821c` | test: tighten `StressTests` thresholds to 1.5× post-optimization measurements |
| `2176582` | test: document Release-mode stress timings and fix comment consistency |
| `4a6a5db` | perf: replace `flatMap` in `DeclarationBlock` body materialization |

### Measured speedups (Debug vs. pre-optimization baseline, median of 3 runs, Apple Silicon)

| Scenario | Before | After | Speedup |
|---|---:|---:|---:|
| 10k atomic components via builder | 25 ms | 3 ms | ~8× |
| 10k `Joined` with prefix/suffix | 31 ms | 2 ms | ~15× |
| 10k `Joined` without prefix/suffix | 28 ms | 2 ms | ~14× |
| 10k `ForEach` with component separator | 29 ms | 3 ms | ~10× |
| 100-level `NestedDeclaration` | 4 ms | 3 ms | ~1.3× |
| 50-level nested `DeclarationBlock` + `MemberList` | 14 ms | 5 ms | ~3× |
| 1k cached `.string` reads | 5 ms | 1 ms | ~5× |
| 1k cached `.components` reads | 5 ms | 1 ms | ~5× |
| 1k `.appending(...)` calls | 6 ms | 3 ms | ~2× |
| 1k `+=` mutations | 4 ms | 1 ms | ~4× |
| Codable round-trip 10k | 68 ms | 41 ms | ~1.7× (JSON-bound) |
| Insert 1k distinct into `Set` | 9 ms | 1 ms | ~9× |
| Insert 1k identical into `Set` | 2 ms | 1 ms | ~2× |

Allocation-bound scenarios hit 8–15× — well above the ≥2× goal. Depth and cache-reuse benches saw smaller ratios (not allocation-bound, as expected). Public API unchanged; all 250 tests pass in Debug.
