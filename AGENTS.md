# AGENTS.md
This file provides guidance to coding agents when working with code in this repository.

## Build & Test Commands

```bash
swift package update && swift build 2>&1 | xcsift
swift package update && swift test 2>&1 | xcsift

# Run a single test (Swift Testing filter syntax)
swift test --filter "SemanticString Tests/Empty initialization" 2>&1 | xcsift
# Or by symbol name
swift test --filter SemanticStringTests 2>&1 | xcsift
```

- Swift tools version: **6.2** — strict concurrency is on, so every public type must be `Sendable`.
- No external dependencies.
- Single library target `Semantic` + single test target `SemanticTests` (Swift Testing `@Suite` / `@Test` / `#expect`, not XCTest).
- Deployment targets: macOS 10.15, iOS 13, macCatalyst 13, tvOS 13, watchOS 6, visionOS 1.
- Test files: `SemanticStringTests` (core API), `CorrectnessTests` (behavior lock-down), `StressTests` (scale/depth/timing), `PerformanceRegressionTests` (allocation counts), `TwoStateStorageTests` (flat/tree transitions, `compact()` semantics, container granularity), `FrozenSemanticStringTests`.
- Two timing assertions in `StressTests` exceed their budget under ThreadSanitizer instrumentation (the shared cache lock's cost); they pass uninstrumented. Judge timing regressions from an uninstrumented run.

## Architecture

A **semantic string library** for building richly-typed text output (like `NSAttributedString`, but the attribute *is* a semantic role rather than a visual style). Originally designed for representing code declarations in reverse engineering tools. Follows a SwiftUI-like component/builder pattern.

### Core Type Hierarchy

**Protocol chain:** `SemanticStringComponent` (like `View`) → `AtomicSemanticComponent` (leaf nodes with `string` + `type`).

**Key types:**
- `SemanticString` (`Sources/Semantic/SemanticString.swift`) — the main **builder** container. Copy-on-write via an internal `Storage` class (`@unchecked Sendable`) that is **two-state** (see below) and caches both the flattened `[AtomicComponent]` and the combined `String`. Mutations go through `makeUnique()` + `invalidateCache()`. Conforms to `Codable` (encodes as `[AtomicComponent]`), `Hashable`, `ExpressibleByStringLiteral`, `TextOutputStream`, and itself `SemanticStringComponent`.
- `FrozenSemanticString` (`Sources/Semantic/FrozenSemanticString.swift`) — the immutable **terminal form**, produced one-way by `SemanticString.frozen()`. Stores `text: String` (full UTF-8, exactly once) + `spans: [Span]` (8 bytes per token: `length: UInt16`, `typeCode: UInt8`, `identifierIndex: UInt32`) + `identifierTable: [String]` (interned, 1-based; `0` means none). All-`let`, so unconditionally `Sendable` with no lock and no CoW. Read it via `enumerateSpans(_:)`; `components` exists only as a compatibility view. Its `Codable` is columnar and **deliberately incompatible** with `SemanticString`'s.
- `AtomicComponent` (`Components/AnyComponent.swift`) — type-erased leaf (like `AnyView`). Holds `string: String` + `type: SemanticType` + `identifier: String?`. `AnyComponent` is a deprecated typealias kept for source compatibility.
- `SemanticType` (`SemanticType.swift`) — enum categorizing text: `.standard`, `.comment`, `.keyword`, `.variable`, `.numeric`, `.argument`, `.error`, `.other`, `.type(TypeKind, Context)`, `.member(Context)`, `.function(Context)`. `TypeKind` ∈ {`.enum`, `.struct`, `.class`, `.protocol`, `.other`}; `Context` ∈ {`.declaration`, `.name`}.
- `SemanticStringBuilder` (`SemanticStringBuilder.swift`) — result builder using the `buildPartialBlock` pattern. Accepts components, arrays, optionals, `Void`, `SemanticString`, and any `CustomStringConvertible` (auto-wrapped in `Standard`). Supports `if`/`else`, `for`, and `buildArray`.

### Component Categories

**Atomic** (conform to `AtomicSemanticComponent`): `Keyword`, `Variable`, `Numeric`, `Argument`, `Comment`, `Error`, `TypeName`, `TypeDeclaration`, `MemberName`, `MemberDeclaration`, `FunctionName`, `FunctionDeclaration`, `Standard`, `Space`, `BreakLine`, `Indent`.

**Composite** (implement `buildComponents()` directly — in `Components/`): `Group` (with `.separator(...)`), `Joined` (auto-filters empty items, supports prefix/suffix as strings or builder closures), `ForEach` / `ForEachIndexed`, `IfLet`, `DeclarationBlock`, `NestedDeclaration`, `BlockList` (with `.separatedByEmptyLine()`), `MemberList`.

**Structural:** `EmptyComponent`, `TupleComponent2`, `TupleComponent3`.

**Protocol conformances that aren't obvious from filenames:** `Optional<Wrapped>`, `Array<Element>`, and `Never` all conform to `SemanticStringComponent` when `Wrapped`/`Element` do — this is how the builder swallows nil and iterates arrays cleanly.

### Storage: Two-State (flat / tree)

`SemanticString.Storage` holds two arrays; exactly one is populated, discriminated by `isFlat`:

- **flat** (`flatComponents: [AtomicComponent]`) — typed, zero boxing. Entered by streamed appends (`append(_:type:)` / `write(_:)`), `init(components:)` (decoding, transformation), and `compact()`.
- **tree** (`treeElements: [any SemanticStringComponent]`) — the construction-time form that keeps element boundaries intact, because element granularity is semantic: `MemberList`-style containers treat one element as one row. Appending a composite to a flat string first calls `convertToTree()`.

Why: an `AtomicComponent` is 40 bytes, larger than the 24-byte existential inline buffer, so the tree form costs a 40-byte container **plus** a 64-byte heap box per token.

**Invariant that keeps both forms observably identical:** the flat form only ever holds content the single-array storage would have kept as individually boxed atomic elements, so the `elements` view has the same per-atom granularity either way. Composites never enter the flat form.

**Cache locking:** the lazy `cachedComponents` / `cachedString` fills are guarded by `Storage.sharedCacheLock`, a single `NSLock` shared by all instances. The expensive flatten runs *outside* the lock (racing readers may both compute; results are identical, first store wins). It is shared rather than per-instance so printers creating masses of transient strings don't pay an allocation each. Every other mutation happens on uniquely-referenced storage via `makeUnique()` and needs no lock.

**`compact()` / `compacted()`:** collapses a finalized tree to flat, releasing the composites and boxes. Only call at a storage boundary once the string is final — after compaction the `elements` view is one element per atom, so the value must not later be passed as prebuilt `content:` to a `MemberList`-style container. `components`, `string`, equality, hashing, and `Codable` output are unchanged. CoW copies made before compaction keep their own tree.

For read-only content, prefer `frozen()` over `compact()`: it enforces the same lifecycle through the type system instead of a runtime convention. See `docs/TwoStateStorage.md` and `docs/FrozenSemanticString.md` for the design records and measurements.

### Design Patterns & Invariants

- **All public APIs are `@inlinable`** for performance. When adding public API, match this convention — the test target includes `PerformanceRegressionTests.swift` that guards allocation counts.
- **Flattening happens once per mutation.** In the tree state `SemanticString.components` lazily expands `_storage.treeElements` and caches it; in the flat state it returns `flatComponents` directly (no flatten, no cache needed). `string` caches the concatenation. Don't bypass the cache by reaching into `_storage` directly.
- **`SemanticType` ↔ `UInt8` codes are append-only.** `SemanticType.frozenTypeCode` (`FrozenSemanticString.swift`) is a storage/wire format: new cases take the next free code, existing assignments are **never** renumbered, or previously encoded frozen strings decode with the wrong styling. The inverse `init?(frozenTypeCode:)` returns `nil` for unknown codes and callers resolve those to `.other` rather than crashing.
- **Span lengths are `UInt16`.** A token over 65535 UTF-8 bytes is split into consecutive spans with identical type and identifier, at Unicode scalar boundaries. Consumers that concatenate or attribute runs see no difference, but a test comparing token counts one-by-one against `SemanticString.components` will.
- **Empty strings are filtered at the atomic level** — `AtomicSemanticComponent.buildComponents()` returns `[]` for empty `string`, so composite components can assume their children produce no empty noise.
- **`Indent` uses 4 spaces per level.** `DeclarationBlock` and `MemberList` both compute their own indentation using this 4-space rule (see `Components/Block.swift`); keep new layout components consistent.
- **Pre-computed singletons in `CommonAtomicComponents`** (`Components/Other.swift`) — reuse `CommonAtomicComponents.space` / `.breakLine` in new composite components instead of allocating new `AtomicComponent` values each time.
- **Composite components own their own whitespace.** `NestedDeclaration` prepends a `BreakLine`; `MemberList` emits `BreakLine + indent` before each item plus a trailing `BreakLine`; `BlockList` emits a leading `BreakLine` before each item and a trailing one. When composing these, don't double-add newlines.
- **Most composite initializers come in sync + async variants** (e.g. `DeclarationBlock`, `NestedDeclaration`, `BlockList`, `MemberList`). The async form uses `@SemanticStringBuilder (…) async throws -> SemanticString`. Keep this pairing when adding new block-like components.
