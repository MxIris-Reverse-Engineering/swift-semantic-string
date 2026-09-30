/// The `accumulated` parameter of every `buildPartialBlock(accumulated:next:)`
/// is `consuming`, deliberately. Borrowed (the default), `var result =
/// accumulated` holds a second reference to the array, so the `append` that
/// follows copies the whole accumulation — once per statement in the block.
/// The builder transform hands each partial result straight to the next call
/// and never touches it again, so ownership can move and the append runs in
/// place. These methods are not `@inlinable`, so nothing else removes that
/// copy for a caller in another module (measured 199 ms → 141 ms for 100k
/// eight-statement blocks on its own, 199 ms → 92 ms together with the
/// `_appendAsElement(into:)` dispatch; `docs/AppendPathPerformance.md`).
@resultBuilder
public enum SemanticStringBuilder {
    public typealias Element = any SemanticStringComponent

    public static func buildBlock() -> [Element] { [] }

    public static func buildPartialBlock(first: Void) -> [Element] { [] }

    public static func buildPartialBlock(first: Never) -> [Element] {}

    public static func buildPartialBlock(first: Element) -> [Element] { [first] }

    public static func buildPartialBlock(first: [Element]) -> [Element] { first }

    public static func buildPartialBlock(first: Element?) -> [Element] { first.map { [$0] } ?? [] }

    public static func buildPartialBlock(first: [Element]?) -> [Element] { first ?? [] }

    public static func buildPartialBlock(first: SemanticString) -> [Element] { [first] }

    public static func buildPartialBlock(first: SemanticString?) -> [Element] { first.map { [$0] } ?? [] }

    public static func buildPartialBlock(first: some CustomStringConvertible) -> [Element] { [Standard(first.description)] }

    public static func buildPartialBlock(accumulated: consuming [Element], next: Element) -> [Element] {
        var result = accumulated
        result.append(next)
        return result
    }

    public static func buildPartialBlock(accumulated: consuming [Element], next: [Element]) -> [Element] {
        var result = accumulated
        result.append(contentsOf: next)
        return result
    }

    public static func buildPartialBlock(accumulated: consuming [Element], next: Element?) -> [Element] {
        guard let next else { return accumulated }
        var result = accumulated
        result.append(next)
        return result
    }

    public static func buildPartialBlock(accumulated: consuming [Element], next: [Element]?) -> [Element] {
        guard let next else { return accumulated }
        var result = accumulated
        result.append(contentsOf: next)
        return result
    }

    public static func buildPartialBlock(accumulated: consuming [Element], next: SemanticString) -> [Element] {
        var result = accumulated
        result.append(next)
        return result
    }

    public static func buildPartialBlock(accumulated: consuming [Element], next: SemanticString?) -> [Element] {
        guard let next else { return accumulated }
        var result = accumulated
        result.append(next)
        return result
    }

    public static func buildPartialBlock(accumulated: consuming [Element], next: some CustomStringConvertible) -> [Element] {
        var result = accumulated
        result.append(Standard(next.description))
        return result
    }

    public static func buildPartialBlock(accumulated: consuming [Element], next: Void) -> [Element] { accumulated }

    public static func buildOptional(_ components: [Element]?) -> [Element] { components ?? [] }

    public static func buildEither(first: [Element]) -> [Element] { first }

    public static func buildEither(second: [Element]) -> [Element] { second }

    public static func buildArray(_ components: [[Element]]) -> [Element] { components.flatMap { $0 } }

    public static func buildFinalResult(_ components: [Element]) -> SemanticString { .init(components: components) }
}
