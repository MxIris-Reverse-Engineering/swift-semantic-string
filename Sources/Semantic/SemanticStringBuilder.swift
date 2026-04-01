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

    public static func buildPartialBlock(accumulated: [Element], next: Element) -> [Element] {
        var result = accumulated
        result.append(next)
        return result
    }

    public static func buildPartialBlock(accumulated: [Element], next: [Element]) -> [Element] {
        var result = accumulated
        result.append(contentsOf: next)
        return result
    }

    public static func buildPartialBlock(accumulated: [Element], next: Element?) -> [Element] {
        guard let next else { return accumulated }
        var result = accumulated
        result.append(next)
        return result
    }

    public static func buildPartialBlock(accumulated: [Element], next: [Element]?) -> [Element] {
        guard let next else { return accumulated }
        var result = accumulated
        result.append(contentsOf: next)
        return result
    }

    public static func buildPartialBlock(accumulated: [Element], next: SemanticString) -> [Element] {
        var result = accumulated
        result.append(next)
        return result
    }

    public static func buildPartialBlock(accumulated: [Element], next: SemanticString?) -> [Element] {
        guard let next else { return accumulated }
        var result = accumulated
        result.append(next)
        return result
    }

    public static func buildPartialBlock(accumulated: [Element], next: some CustomStringConvertible) -> [Element] {
        var result = accumulated
        result.append(Standard(next.description))
        return result
    }

    public static func buildPartialBlock(accumulated: [Element], next: Void) -> [Element] { accumulated }

    public static func buildOptional(_ components: [Element]?) -> [Element] { components ?? [] }

    public static func buildEither(first: [Element]) -> [Element] { first }

    public static func buildEither(second: [Element]) -> [Element] { second }

    public static func buildArray(_ components: [[Element]]) -> [Element] { components.flatMap { $0 } }

    public static func buildFinalResult(_ components: [Element]) -> SemanticString { .init(components: components) }
}
