// MARK: - Codable Conformance

extension SemanticString: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let atomicComponents = try container.decode([AtomicComponent].self)
        self.init(components: atomicComponents)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(components)
    }
}

// MARK: - Hashable Conformance

extension SemanticString: Hashable {
    public static func == (lhs: SemanticString, rhs: SemanticString) -> Bool {
        lhs.components == rhs.components
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(components)
    }
}

// MARK: - TextOutputStream Conformance

extension SemanticString: TextOutputStream {
    @inlinable
    public mutating func write(_ string: String) {
        append(string, type: .standard)
    }

    @inlinable
    public mutating func write(_ string: String, type: SemanticType) {
        append(string, type: type)
    }
}
