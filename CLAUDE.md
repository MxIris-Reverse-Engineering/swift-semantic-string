# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
swift package update && swift build 2>&1 | xcsift
swift package update && swift test 2>&1 | xcsift
```

- Swift tools version: 6.2 (strict concurrency required — all public types must be `Sendable`)
- No external dependencies
- Single library target: `Semantic`, single test target: `SemanticTests`
- Tests use Swift Testing framework (`@Test`, `#expect`), not XCTest

## Architecture

This is a **semantic string library** for building richly-typed text output (similar to `NSAttributedString` but with semantic meaning). It follows a SwiftUI-like component/builder pattern designed for representing code declarations in reverse engineering tools.

### Core Type Hierarchy

**Protocol chain:** `SemanticStringComponent` (like `View`) → `AtomicSemanticComponent` (leaf nodes with `string` + `type`)

**Key types:**
- `SemanticString` — The main container. Uses copy-on-write (`Storage` class) with cached flattened components and string. Conforms to `Codable`, `Hashable`, `ExpressibleByStringLiteral`, `TextOutputStream`.
- `AtomicComponent` — Type-erased leaf node (like `AnyView`). Stores `string: String` + `type: SemanticType`.
- `SemanticType` — Enum categorizing text: `.keyword`, `.variable`, `.numeric`, `.argument`, `.comment`, `.error`, `.standard`, `.other`, `.type(TypeKind, Context)`, `.member(Context)`, `.function(Context)`. `TypeKind` distinguishes enum/struct/class/protocol. `Context` distinguishes `.declaration` vs `.name`.
- `SemanticStringBuilder` — Result builder using `buildPartialBlock` pattern. Supports `if/else`, `for`, optionals, `Void` expressions, and `CustomStringConvertible`.

### Component Categories

**Atomic** (conform to `AtomicSemanticComponent`): `Keyword`, `Variable`, `Numeric`, `Argument`, `Comment`, `Error`, `TypeName`, `TypeDeclaration`, `MemberName`, `MemberDeclaration`, `FunctionName`, `FunctionDeclaration`, `Standard`, `Space`, `BreakLine`, `Indent`

**Composite** (implement `buildComponents()` directly): `Group` (with `.separator()`), `Joined` (auto-filters empty items, supports prefix/suffix), `ForEach`, `ForEachIndexed`, `IfLet`, `DeclarationBlock`, `NestedDeclaration`, `BlockList`, `MemberList`, `ImportsBlock`, `OffsetComment`, `AddressComment`

**Structural:** `EmptyComponent`, `TupleComponent2`, `TupleComponent3`

### Design Patterns

- All public APIs are `@inlinable` for performance
- `SemanticString` flattens its component tree into `[AtomicComponent]` via `buildComponents()` — composite components recursively expand, atomic components return single-element arrays
- Empty strings are filtered out at the atomic level (`AtomicSemanticComponent.buildComponents()` returns `[]` for empty strings)
- `Indent` uses 4 spaces per level
