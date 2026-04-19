# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

## Architecture

A **semantic string library** for building richly-typed text output (like `NSAttributedString`, but the attribute *is* a semantic role rather than a visual style). Originally designed for representing code declarations in reverse engineering tools. Follows a SwiftUI-like component/builder pattern.

### Core Type Hierarchy

**Protocol chain:** `SemanticStringComponent` (like `View`) → `AtomicSemanticComponent` (leaf nodes with `string` + `type`).

**Key types:**
- `SemanticString` (`Sources/Semantic/SemanticString.swift`) — the main container. Uses copy-on-write via an internal `Storage` class (`@unchecked Sendable`) that caches both the flattened `[AtomicComponent]` and the combined `String`. Mutations go through `makeUnique()` + `invalidateCache()`. Conforms to `Codable` (encodes as `[AtomicComponent]`), `Hashable`, `ExpressibleByStringLiteral`, `TextOutputStream`, and itself `SemanticStringComponent`.
- `AtomicComponent` (`Components/AnyComponent.swift`) — type-erased leaf (like `AnyView`). Holds `string: String` + `type: SemanticType`. `AnyComponent` is a deprecated typealias kept for source compatibility.
- `SemanticType` (`SemanticType.swift`) — enum categorizing text: `.standard`, `.comment`, `.keyword`, `.variable`, `.numeric`, `.argument`, `.error`, `.other`, `.type(TypeKind, Context)`, `.member(Context)`, `.function(Context)`. `TypeKind` ∈ {`.enum`, `.struct`, `.class`, `.protocol`, `.other`}; `Context` ∈ {`.declaration`, `.name`}.
- `SemanticStringBuilder` (`SemanticStringBuilder.swift`) — result builder using the `buildPartialBlock` pattern. Accepts components, arrays, optionals, `Void`, `SemanticString`, and any `CustomStringConvertible` (auto-wrapped in `Standard`). Supports `if`/`else`, `for`, and `buildArray`.

### Component Categories

**Atomic** (conform to `AtomicSemanticComponent`): `Keyword`, `Variable`, `Numeric`, `Argument`, `Comment`, `Error`, `TypeName`, `TypeDeclaration`, `MemberName`, `MemberDeclaration`, `FunctionName`, `FunctionDeclaration`, `Standard`, `Space`, `BreakLine`, `Indent`.

**Composite** (implement `buildComponents()` directly — in `Components/`): `Group` (with `.separator(...)`), `Joined` (auto-filters empty items, supports prefix/suffix as strings or builder closures), `ForEach` / `ForEachIndexed`, `IfLet`, `DeclarationBlock`, `NestedDeclaration`, `BlockList` (with `.separatedByEmptyLine()`), `MemberList`.

**Structural:** `EmptyComponent`, `TupleComponent2`, `TupleComponent3`.

**Protocol conformances that aren't obvious from filenames:** `Optional<Wrapped>`, `Array<Element>`, and `Never` all conform to `SemanticStringComponent` when `Wrapped`/`Element` do — this is how the builder swallows nil and iterates arrays cleanly.

### Design Patterns & Invariants

- **All public APIs are `@inlinable`** for performance. When adding public API, match this convention — the test target includes `PerformanceRegressionTests.swift` that guards allocation counts.
- **Flattening happens once per mutation.** `SemanticString.components` lazily computes `_storage.elements.flatMap { $0.buildComponents() }` and caches it; `string` caches the concatenation. Don't bypass the cache by reaching into `_storage` directly.
- **Empty strings are filtered at the atomic level** — `AtomicSemanticComponent.buildComponents()` returns `[]` for empty `string`, so composite components can assume their children produce no empty noise.
- **`Indent` uses 4 spaces per level.** `DeclarationBlock` and `MemberList` both compute their own indentation using this 4-space rule (see `Components/Block.swift`); keep new layout components consistent.
- **Pre-computed singletons in `CommonAtomicComponents`** (`Components/Other.swift`) — reuse `CommonAtomicComponents.space` / `.breakLine` in new composite components instead of allocating new `AtomicComponent` values each time.
- **Composite components own their own whitespace.** `NestedDeclaration` prepends a `BreakLine`; `MemberList` emits `BreakLine + indent` before each item plus a trailing `BreakLine`; `BlockList` emits a leading `BreakLine` before each item and a trailing one. When composing these, don't double-add newlines.
- **Most composite initializers come in sync + async variants** (e.g. `DeclarationBlock`, `NestedDeclaration`, `BlockList`, `MemberList`). The async form uses `@SemanticStringBuilder (…) async throws -> SemanticString`. Keep this pairing when adding new block-like components.
