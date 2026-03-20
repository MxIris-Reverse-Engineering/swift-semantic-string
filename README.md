# swift-semantic-string

A Swift library for building semantically typed strings using a SwiftUI-like declarative syntax. Each piece of text carries a semantic type (keyword, type name, variable, etc.), enabling downstream consumers to apply syntax highlighting, accessibility annotations, or any type-aware rendering.

## Requirements

- Swift 6.2+
- No external dependencies

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/MxIris-Reverse-Engineering/swift-semantic-string.git", from: "0.1.0")
]
```

Then add `"Semantic"` as a dependency of your target.

## Quick Start

```swift
import Semantic

// Use the result builder to compose semantic strings declaratively
@SemanticStringBuilder
var declaration: SemanticString {
    Keyword("public")
    Space()
    Keyword("struct")
    Space()
    TypeName(kind: .struct, "MyType")
}

// Access the plain text
print(declaration.string) // "public struct MyType"

// Enumerate with semantic info for rendering
declaration.enumerate { text, type in
    switch type {
    case .keyword:
        renderAsKeyword(text)
    case .type:
        renderAsTypeName(text)
    default:
        renderAsPlainText(text)
    }
}
```

## Semantic Types

`SemanticType` categorizes each text fragment:

| Type | Description |
|------|-------------|
| `.keyword` | Language keywords (`public`, `func`, `class`, ...) |
| `.variable` | Variable names |
| `.numeric` | Numeric literals |
| `.argument` | Function argument labels |
| `.comment` | Comments and annotations |
| `.error` | Error indicators |
| `.type(TypeKind, Context)` | Type references — `TypeKind`: `.enum`, `.struct`, `.class`, `.protocol`, `.other`; `Context`: `.declaration` or `.name` |
| `.member(Context)` | Member references (property/method) |
| `.function(Context)` | Function references |
| `.standard` | Plain text with no special meaning |
| `.other` | Uncategorized |

## Components

### Atomic Components

Atomic components are leaf nodes — each holds a single string and its semantic type.

```swift
Keyword("func")                        // .keyword
Variable("count")                      // .variable
Numeric("42")                          // .numeric
Argument("name")                       // .argument
Comment("// TODO")                     // .comment
TypeName(kind: .struct, "Int")         // .type(.struct, .name)
TypeDeclaration(kind: .class, "Foo")   // .type(.class, .declaration)
FunctionName("viewDidLoad")            // .function(.name)
FunctionDeclaration("init")            // .function(.declaration)
MemberName("count")                    // .member(.name)
MemberDeclaration("title")             // .member(.declaration)
Standard("(")                          // .standard
Space()                                // " "
BreakLine()                            // "\n"
Indent(level: 2)                       // "        " (4 spaces per level)
```

### Composite Components

Composite components combine multiple children.

#### Group

Groups components together, with an optional separator:

```swift
let modifiers = Group {
    Keyword("public")
    Keyword("static")
    Keyword("func")
}.separator(Space())
// "public static func"
```

#### Joined

Joins items with a separator, automatically filtering out empty items:

```swift
Joined(separator: ", ", prefix: "(", suffix: ")") {
    if hasLabel {
        Standard("label")
    }
    Standard("value")
}
// With hasLabel=true:  "(label, value)"
// With hasLabel=false: "(value)"
```

#### ForEach / ForEachIndexed

Iterate over collections:

```swift
ForEach(parameters, separator: ", ") { param in
    Standard(param.name)
    Standard(": ")
    TypeName(kind: .other, param.typeName)
}

ForEachIndexed(items) { item, info in
    if !info.isFirst {
        Standard(", ")
    }
    Standard(item.name)
}
```

#### IfLet

Conditional content based on optionals:

```swift
IfLet(superclass) { name in
    Standard(": ")
    TypeName(kind: .class, name)
}
```

#### DeclarationBlock

Structured declaration with header, braces, and indented body:

```swift
DeclarationBlock(level: 0) {
    Keyword("struct")
    Space()
    TypeName(kind: .struct, "Point")
} body: {
    MemberList(level: 1) {
        SemanticString {
            Keyword("var")
            Space()
            Variable("x")
            Standard(": ")
            TypeName(kind: .struct, "Int")
        }
        SemanticString {
            Keyword("var")
            Space()
            Variable("y")
            Standard(": ")
            TypeName(kind: .struct, "Int")
        }
    }
}
// struct Point {
//     var x: Int
//     var y: Int
// }
```

## Result Builder

`@SemanticStringBuilder` supports the full range of Swift result builder features:

```swift
@SemanticStringBuilder
func describe(_ decl: SomeDecl) -> SemanticString {
    // Conditionals
    if decl.isPublic {
        Keyword("public")
        Space()
    }

    // Switch / if-else
    if decl.isStatic {
        Keyword("static")
        Space()
    }

    Keyword("func")
    Space()
    FunctionName(decl.name)

    // For loops
    Joined(separator: ", ", prefix: "(", suffix: ")") {
        for param in decl.parameters {
            Standard(param)
        }
    }

    // Optionals via IfLet
    IfLet(decl.returnType) { ret in
        Standard(" -> ")
        TypeName(kind: .other, ret)
    }
}
```

## Manipulating Semantic Strings

`SemanticString` provides a rich API for transformation and inspection:

```swift
let ss = SemanticString { ... }

// Concatenation
let combined = ss + otherString
ss += moreContent

// Transformation
let uppercased = ss.map { AtomicComponent(string: $0.string.uppercased(), type: $0.type) }
let allStandard = ss.replacing { _ in .standard }

// Wrapping
let wrapped = ss.parenthesized()   // "(content)"
let generic = ss.angleBracketed()  // "<content>"

// Trimming
let trimmed = ss.trimmingWhitespace()

// Conditional operations
let result = ss
    .prefixed(with: "public ", if: isPublic)
    .suffixed(with: "?", if: isOptional)

// Querying
ss.contains(type: .keyword)
ss.hasPrefix("func")
ss.starts(with: .keyword)

// Filtering
let keywords = ss.filter(byType: .keyword)

// Slicing
let first3 = ss.prefix(3)
let rest = ss.dropFirst()
```

## Codable Support

`SemanticString` conforms to `Codable`, serializing as an array of `AtomicComponent` values:

```swift
let data = try JSONEncoder().encode(semanticString)
let decoded = try JSONDecoder().decode(SemanticString.self, from: data)
```

## License

MIT
