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
- No external dependencies. The only system imports are the platform locking primitives, confined to `Storage/CacheLockStripes.swift`: `os.lock` on Darwin (`Synchronization.Mutex` would require macOS 15, `NSLock` would drag in Foundation), `SRWLOCK` on Windows, `pthread_mutex_t` elsewhere. **Every one is behind `#if canImport`, and nothing else in the target imports anything** — an unguarded `import os.lock` turns a pure-stdlib package into a Darwin-only one, and `Package.swift`'s `platforms:` only sets minimum versions, it does not stop SwiftPM building for Linux.
- Single library target `Semantic` + single test target `SemanticTests` (Swift Testing `@Suite` / `@Test` / `#expect`, not XCTest).
- Deployment targets: macOS 10.15, iOS 13, macCatalyst 13, tvOS 13, watchOS 6, visionOS 1.
- **watchOS means 32-bit, and no simulator build will tell you.** `arm64_32` / `armv7k` are the only 32-bit Apple targets left, so `UInt` is 32 bits there and a 64-bit literal is a hard compile error — one that `-typecheck` does not catch (it fires during code generation) and that the watchOS *simulator* does not catch either, because on Apple silicon the simulator is `arm64`. There is no CI in this repo. Before touching anything with pointer-width-sensitive arithmetic, check it explicitly:
  ```bash
  xcrun --sdk watchos swiftc -swift-version 6 -wmo -O -c \
    -sdk "$(xcrun --sdk watchos --show-sdk-path)" -target arm64_32-apple-watchos6.0 \
    -module-name Semantic -o /dev/null $(find Sources/Semantic -name '*.swift')
  ```
- Test files: `SemanticStringTests` (core API), `CorrectnessTests` (behavior lock-down), `StressTests` (scale/depth/timing), `PerformanceRegressionTests` (allocation counts), `TwoStateStorageTests` (flat/tree transitions, compaction semantics, container granularity), `StorageDivergenceRegressionTests` (behaviors that must hold in either storage form — written against API that exists on both sides of the two-state change, so it can be run against an older revision for comparison), `TwoStateStorageRegressionTests` (compaction, freezing, fast paths, read-while-mutate concurrency), `ReviewFindingsRegressionTests` (the defects the two-state review turned up: leaf fast-path correctness, element-view boxing, cache publication, frozen decoding validation, type-code uniqueness), `ConcurrencyTests` (the `Sendable` contract: shared reads, copy-on-write isolation, lock ordering, actor boundaries), `FrozenSemanticStringTests`.
- **A test that passes against a reverted design is not a test.** `TwoStateStorageTests`' two container-granularity tests both build their content with a `@SemanticStringBuilder` closure, and `buildFinalResult` makes one element per `SemanticString` no matter which storage state it is in — so they hold even with the two-state change removed wholesale. The assertions that actually depend on it are in `ReviewFindingsRegressionTests`, and they reach into `_storage.isFlat` / `elements.representation` to say so. When adding a test "for" a storage change, check that it fails without the change.
- **Timing assertions and ThreadSanitizer don't mix.** Under `--sanitize=thread` the full suite reports three `StressTests` budget overruns; add `--no-parallel` and only one survives — the 10k-component Codable round trip (~208 ms against a 200 ms budget), which overruns on `main` too. The other two are CPU contention between tests running in parallel, not regressions. Judge timing from an uninstrumented run.
- **Concurrency tests are worthless uninstrumented.** `ConcurrencyTests` passes with the locking deliberately broken: publishing the string cache without its lock leaves all 17 tests green while ThreadSanitizer reports 82 races. After touching storage, caching, or locking, run `swift test --sanitize=thread --filter ConcurrencyTests` — a clean assertion run proves nothing.

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

**Two invariants keep the forms observably identical.** Break either and the same content starts flattening differently depending on how it was built:

1. **Granularity.** The flat form only ever holds content the single-array storage would have kept as individually boxed atomic elements, so the `elements` view has the same per-atom granularity either way. Composites never enter the flat form.
2. **No zero-length components in `flatComponents`.** `components` returns the flat array verbatim, and tree flattening drops empty components (`AtomicComponent.buildComponents()` returns `[]`), so every write entry point into the flat form has to drop them too — `appendAtomicComponent(_:)` and the `[AtomicComponent]` initializers (via `droppingZeroLengthComponents(_:)`). Filtering on *read* instead would make `components` O(n) with an allocation and defeat the whole point of the flat form. When empty components did survive, `MemberList` grew blank indented rows and `Joined` emitted separators around nothing.

**The element view.** `SemanticString.elements` returns `SemanticStringElements`, not `[any SemanticStringComponent]`. Handing out an array would box every atom of a *flat* string — the exact 40-byte container plus 64-byte heap box per token that the flat form exists to avoid — at every container's prebuilt-`content:` initializer, which is precisely where a printer hands over a streamed string. Measured on 400k atoms through `MemberList(level:content:)`: 0.003 ms / +0 MB as a view, 24 ms / +80 MB as an array, which is more than the whole two-state change saves. Containers walk `indices` and call `appendComponents(ofElementAt:into:)`; `boxed()` exists for the rare caller that genuinely needs the array, and should not appear on a flattening path.

**Cache locking:** the lazy `cachedComponents` / `cachedString` fills — and the matching reads in `Storage.init(copying:)`, which is the cache-preserving copy-on-write path — are guarded by `CacheLockStripes`, a table of 256 platform locks indexed by mixed storage address. The expensive flatten runs *outside* the lock (racing readers may both compute; results are identical, first store wins). Every other mutation happens on uniquely-referenced storage and needs no lock.

**Two copy-on-write paths, and mutations want the cheap one.** `makeUnique()` copies the caches under the stripe lock; `makeUniqueForMutation()` drops them. Every mutation invalidates the cache on its next statement, so the copying variant spends a lock round trip and two array retains on values that are discarded immediately — and `appending` / `+` / `wrapped` / `parenthesized` all reach it, on a path that historically did no copy-on-write work at all. Only `compact()` uses `makeUnique()`, because it reads the cache. Better still, `appending` a single atom builds the result's storage directly (`appendingAtomicComponent`) rather than copying `self` and mutating the copy, which always finds the storage shared.

**Reads that must not publish.** `components` and `string` fill the cache on the storage they are called on — which the value may be *sharing*, so the flattened array and the full text land on every value holding it. For `compact()` and `frozen()`, whose entire purpose is to lower footprint, that inverts the result: measured, a `frozen()` call left the source holding a full `[AtomicComponent]` plus the whole text. Both use `componentsWithoutPublishing()` / `Storage.cachedStringIfPresent()`, which use the caches when already warm and otherwise compute locally. `isEmpty` has the same constraint for a different reason — `ForEach(_:separator:)` calls it once per item — and short-circuits through `elements.flattensToNothing()`.

Two traps this design exists to avoid, both measured (8 threads x 50k transient strings, one cold fill each):

- **One shared lock serializes unrelated strings.** That is the workload this type is built for, and it cost 434.9 ms against 46.6 ms for no lock at all — concurrent was slower than serial.
- **Packed stripes trade lock contention for false sharing.** An `os_unfair_lock` is 4 bytes, so 32 of them share a cache line; threads locking *different* stripes still bounce the same line. Packed: 273 ms, indistinguishable from running the work on one thread. Hence `cacheLockStripeStride = 128` — one cache line per stripe. Spaced, 256 stripes: 44.7 ms.

If you add stripes, keep the count a power of two (the index masks) and keep the stride at a cache line.

**The stripe index must be mixed in `UInt64`, not `UInt`.** The multiplier is a 64-bit constant, so writing the mix in `UInt` is a compile error on 32-bit targets — which means watchOS devices, and see the build section above for why nothing else catches it. Truncating the multiplier to fit is the trap, not the fix: `mixed >> 32` is then always zero, every address lands on stripe 0, and the table degrades into exactly the one shared lock measured at 434.9 ms. `ReviewFindingsRegressionTests.stripeIndicesSpreadForNarrowAddresses` pins the spread.

Writing a test that needs two specific storages to *share* a stripe: don't build many pairs and hope. The index is a multiplicative hash of the address, and multiplication is linear, so two storages allocated a fixed number of bytes apart always land a fixed stripe distance apart — either always colliding or never. Measured: 4096 identically-built nested pairs, zero collisions. Vary how much is allocated *between* the two storages instead, and collisions appear on a fixed period. `ConcurrencyTests.flatteningNestedStringSharingAStripeDoesNotDeadlock` does exactly that, and asserts that it did find one so it cannot silently degrade into testing nothing. `Storage.init(copying:)` is deliberately `@usableFromInline` rather than `@inlinable`: its body takes the lock, and a cross-module inlined body would have to expose the lock primitives.

**`compact()` / `compacted()` are internal.** They collapse a finalized tree to flat, releasing the composites and boxes, and `frozen()` is the public way to get that. They stay internal because compaction changes what one element *means* — one row becomes one token — and nothing in the type system stops a compacted value from later being passed as prebuilt `content:` to a `MemberList`-style container, which would then render one row per token with no diagnostic. Don't re-publish them; extend `FrozenSemanticString` instead.

**File layout.** `SemanticString` is split by functional area so no single file carries the whole type: `SemanticString.swift` (storage plumbing, contents, initializers), `+Mutation` (identifier scopes, `append`, compaction), `+Transformation` (map / trim / slice / filter), `+Query` (prefix, suffix, containment), `+Composition` (`appending`, wrapping, conditionals, operators), `+Conformances` (`Codable` / `Hashable` / `TextOutputStream`). Storage internals live in `Storage/` (`SemanticStringStorage`, `SemanticStringElements`, `CacheLockStripes`) and the frozen form in `Frozen/` (type, `+Freezing`, `+TypeCodes`, `+Codable`). Put new API in the extension file for its area rather than growing the core file.

See `docs/TwoStateStorage.md`, `docs/FrozenSemanticString.md`, and `docs/StorageCorrectnessAndLockRework.md` for the design records and measurements.

### Design Patterns & Invariants

- **All public APIs are `@inlinable`** for performance. When adding public API, match this convention — the test target includes `PerformanceRegressionTests.swift` that guards allocation counts.
- **Flattening happens once per mutation.** In the tree state `SemanticString.components` lazily expands `_storage.treeElements` and caches it; in the flat state it returns `flatComponents` directly (no flatten, no cache needed). `string` caches the concatenation. Don't bypass the cache by reaching into `_storage` directly.
- **`SemanticType` ↔ `UInt8` codes are append-only, and written out per case.** `SemanticType.frozenTypeCode` (`Frozen/FrozenSemanticString+TypeCodes.swift`) is a storage/wire format: new cases — including new `TypeKind` cases — take `SemanticType.nextFreeFrozenTypeCode`, existing assignments are **never** renumbered, or previously encoded frozen strings decode with the wrong styling. The inverse `init?(frozenTypeCode:)` returns `nil` for unknown codes and callers resolve those to `.other` rather than crashing. The codes are spelled out one per case rather than derived arithmetically: the previous `8 + typeKindOffset * 2` form put the `.type` block's growth edge against `.member`'s fixed 18, so adding a sixth `TypeKind` would have compiled and silently collided. `ReviewFindingsRegressionTests` pins uniqueness and round-tripping across every case.
- **Span lengths are `UInt16`.** A token over 65535 UTF-8 bytes is split into consecutive spans with identical type and identifier, at Unicode scalar boundaries. Consumers that concatenate or attribute runs see no difference, but a test comparing token counts one-by-one against `SemanticString.components` will.
- **Empty strings are filtered at the atomic level** — `AtomicSemanticComponent.buildComponents()` returns `[]` for empty `string`, so composite components can assume their children produce no empty noise. The flat storage form upholds the same rule at its write entry points; see invariant 2 above.
- **`isEmpty` means "flattens to nothing", not "has no elements".** Flat state: `flatComponents.isEmpty`, O(1) by invariant 2. Tree state: a non-empty element array still consults the flattened form, because an element can flatten to nothing (`EmptyComponent`, an empty composite). Deciding it from element counts makes compaction flip `isEmpty` from `false` to `true`.
- **The flat fast path is opt-in via `PlainAtomicSemanticComponent`.** `append` has four overloads: exact `AtomicComponent` (keeps `identifier`), `some PlainAtomicSemanticComponent` (statically resolved, reads `string` / `type` straight into the flat array, so `Keyword` / `Space` / `Indent` / `TypeName` never box or allocate), `some AtomicSemanticComponent` (goes through `buildComponents()`), and `some SemanticStringComponent` for composites, which still routes leaves arriving through an existential to `buildComponents()`.

  Conforming to `PlainAtomicSemanticComponent` **promises that `buildComponents()` is the inherited default**, because the fast path does not call it. Conform a leaf that overrides `buildComponents()` and the same value renders one way through `append` / `+` and another through a `@SemanticStringBuilder`, with no diagnostic — and `AtomicComponent`, which overrides it to carry `identifier` through, would silently lose that identifier. New library leaves go in `Components/PlainAtomicComponentConformances.swift`; leaves that customize `buildComponents()` stay on `AtomicSemanticComponent` alone and take the slightly slower correct path. A new *composite* must not accidentally satisfy `AtomicSemanticComponent`.
- **`Indent` uses 4 spaces per level.** `DeclarationBlock` and `MemberList` both compute their own indentation using this 4-space rule (see `Components/Block.swift`); keep new layout components consistent.
- **Pre-computed singletons in `CommonAtomicComponents`** (`Components/Other.swift`) — reuse `CommonAtomicComponents.space` / `.breakLine` in new composite components instead of allocating new `AtomicComponent` values each time.
- **Composite components own their own whitespace.** `NestedDeclaration` prepends a `BreakLine`; `MemberList` emits `BreakLine + indent` before each item plus a trailing `BreakLine`; `BlockList` emits a leading `BreakLine` before each item and a trailing one. When composing these, don't double-add newlines.
- **Most composite initializers come in sync + async variants** (e.g. `DeclarationBlock`, `NestedDeclaration`, `BlockList`, `MemberList`). The async form uses `@SemanticStringBuilder (…) async throws -> SemanticString`. Keep this pairing when adding new block-like components.
