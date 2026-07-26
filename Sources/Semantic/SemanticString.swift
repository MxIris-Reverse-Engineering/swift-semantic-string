import Foundation

/// A string composed of semantically typed components.
///
/// `SemanticString` is the primary type for building styled text output.
/// It stores a list of semantic components that can be flattened into
/// atomic components for rendering.
///
/// This type implements copy-on-write semantics for efficient copying
/// and caches computed components to avoid redundant calculations.
///
/// Example:
/// ```swift
/// @SemanticStringBuilder
/// var declaration: SemanticString {
///     Keyword("public")
///     Space()
///     Keyword("struct")
///     Space()
///     TypeName(kind: .struct, "MyType")
/// }
/// ```
public struct SemanticString: Sendable, ExpressibleByStringLiteral, SemanticStringComponent {
    /// Internal storage class for copy-on-write semantics.
    ///
    /// Storage is two-state. Exactly one of the two arrays is populated at any
    /// time; the other is empty:
    ///
    /// - **Flat** (`isFlat == true`, contents in `flatComponents`): a typed
    ///   array of atomic components with no existential boxing. This is the
    ///   representation for streamed content (`append(_:type:)` /
    ///   `write(_:)`), for strings built directly from `[AtomicComponent]`
    ///   (decoding, transformation), and for finalized strings after
    ///   `compact()`. An `AtomicComponent` is 40 bytes — larger than the
    ///   24-byte inline buffer of an existential container — so storing it as
    ///   `any SemanticStringComponent` costs a 40-byte container *plus* a
    ///   64-byte heap box per token; the typed array costs 40 bytes total.
    /// - **Tree** (`isFlat == false`, contents in `treeElements`): the
    ///   construction-time form that preserves element boundaries. Composite
    ///   components (`DeclarationBlock`, `MemberList`, `Joined`, …) must stay
    ///   whole here because `elements` granularity is semantic: containers
    ///   like `MemberList` treat each element as one row.
    ///
    /// The invariant that keeps both forms observably identical to the
    /// original single-array storage: the flat form only ever holds content
    /// the old storage would have kept as individually boxed
    /// `AtomicComponent` elements, so the `elements` view has the same
    /// per-atom granularity in both representations. Composites never enter
    /// the flat form; appending one to a flat string first converts the
    /// existing atoms into tree elements (`convertToTree`).
    @usableFromInline
    final class Storage: @unchecked Sendable {
        /// Discriminates which of the two content arrays is authoritative.
        @usableFromInline
        var isFlat: Bool

        /// Authoritative contents when `isFlat == true`; empty otherwise.
        @usableFromInline
        var flatComponents: [AtomicComponent]

        /// Authoritative contents when `isFlat == false`; empty otherwise.
        @usableFromInline
        var treeElements: [any SemanticStringComponent]

        /// Flattened-components cache; only meaningful in the tree state
        /// (the flat state's contents *are* the flattened components).
        @usableFromInline
        var cachedComponents: [AtomicComponent]?

        @usableFromInline
        var cachedString: String?

        /// Single lock shared by all `Storage` instances, guarding the lazy
        /// cache fills (`cachedComponents` / `cachedString`) that can race
        /// when two threads read the same shared storage concurrently. A
        /// per-instance lock would add an allocation to every transient
        /// string a printer creates; fills are rare (once per string) and
        /// the expensive flatten work happens outside the lock, so one
        /// shared lock is uncontended in practice. All other mutations only
        /// happen on uniquely-referenced storage (guarded by `makeUnique`)
        /// and need no lock.
        @usableFromInline
        static let sharedCacheLock = NSLock()

        @inlinable
        init(flatComponents: [AtomicComponent]) {
            self.isFlat = true
            self.flatComponents = flatComponents
            self.treeElements = []
        }

        @inlinable
        init(treeElements: [any SemanticStringComponent]) {
            self.isFlat = false
            self.flatComponents = []
            self.treeElements = treeElements
        }

        @inlinable
        init(copying other: Storage) {
            self.isFlat = other.isFlat
            self.flatComponents = other.flatComponents
            self.treeElements = other.treeElements
            self.cachedComponents = other.cachedComponents
            self.cachedString = other.cachedString
        }

        /// Rehouses flat atoms as boxed tree elements so a composite can be
        /// appended. Granularity is unchanged: the old storage kept streamed
        /// atoms as individually boxed elements anyway. Must only be called
        /// on uniquely-referenced storage.
        @usableFromInline
        func convertToTree() {
            guard isFlat else { return }
            treeElements = flatComponents.map { $0 as any SemanticStringComponent }
            flatComponents = []
            isFlat = false
        }
    }

    @usableFromInline
    var _storage: Storage

    /// Transient identifier-scope stack used while a printer streams content
    /// into this string. The innermost (last) entry stamps every appended
    /// atomic component's `identifier`; a `nil` entry acts as a barrier that
    /// suppresses stamping until a nested non-nil scope overrides it. This is
    /// writer-side state only: it does not participate in equality, hashing,
    /// or coding, and flattened components keep the stamps they were born
    /// with.
    @usableFromInline
    var identifierScopeStack: [String?] = []

    /// Ensures unique ownership of storage for mutation (copy-on-write)
    @inlinable
    mutating func makeUnique() {
        if !isKnownUniquelyReferenced(&_storage) {
            _storage = Storage(copying: _storage)
        }
    }

    /// Invalidates cached values when elements are modified
    @inlinable
    mutating func invalidateCache() {
        _storage.cachedComponents = nil
        _storage.cachedString = nil
    }

    /// Element-boundary view of the contents. In the tree state each element
    /// may be a whole composite; in the flat state every atom is its own
    /// element (matching what the pre-two-state storage kept for streamed or
    /// decoded strings, where each atom was appended as an individual boxed
    /// element).
    @usableFromInline
    internal var elements: [any SemanticStringComponent] {
        if _storage.isFlat {
            return _storage.flatComponents.map { $0 as any SemanticStringComponent }
        } else {
            return _storage.treeElements
        }
    }

    public var components: [AtomicComponent] {
        if _storage.isFlat {
            return _storage.flatComponents
        }

        Storage.sharedCacheLock.lock()
        if let cached = _storage.cachedComponents {
            Storage.sharedCacheLock.unlock()
            return cached
        }
        Storage.sharedCacheLock.unlock()

        // Flatten outside the lock: composite expansion can be expensive and
        // must not serialize unrelated strings behind the shared lock. Two
        // racing readers may both compute; the store below keeps the winner
        // and both results are identical.
        var computed: [AtomicComponent] = []
        computed.reserveCapacity(_storage.treeElements.count)
        for element in _storage.treeElements {
            computed.append(contentsOf: element.buildComponents())
        }

        Storage.sharedCacheLock.lock()
        if _storage.cachedComponents == nil {
            _storage.cachedComponents = computed
        }
        let result = _storage.cachedComponents ?? computed
        Storage.sharedCacheLock.unlock()
        return result
    }

    /// The number of components.
    @inlinable
    public var count: Int { components.count }

    /// The combined string of all components.
    public var string: String {
        Storage.sharedCacheLock.lock()
        if let cached = _storage.cachedString {
            Storage.sharedCacheLock.unlock()
            return cached
        }
        Storage.sharedCacheLock.unlock()

        let atomicComponents = components
        var total = 0
        for atomicComponent in atomicComponents {
            total += atomicComponent.string.utf8.count
        }
        var computed = ""
        computed.reserveCapacity(total)
        for atomicComponent in atomicComponents {
            computed += atomicComponent.string
        }

        Storage.sharedCacheLock.lock()
        if _storage.cachedString == nil {
            _storage.cachedString = computed
        }
        let result = _storage.cachedString ?? computed
        Storage.sharedCacheLock.unlock()
        return result
    }

    // MARK: - Collection-like Properties

    /// Returns `true` if the semantic string has no components.
    @inlinable
    public var isEmpty: Bool {
        _storage.isFlat ? _storage.flatComponents.isEmpty : _storage.treeElements.isEmpty
    }

    /// Returns the first component, or `nil` if empty.
    @inlinable
    public var first: AtomicComponent? { components.first }

    /// Returns the last component, or `nil` if empty.
    @inlinable
    public var last: AtomicComponent? { components.last }

    // MARK: - Initialization

    @inlinable
    public init() {
        // Start flat: a string that only ever receives streamed atomic
        // appends (the printer hot path) never boxes a single component.
        self._storage = Storage(flatComponents: [])
    }

    @inlinable
    public init(@SemanticStringBuilder builder: () -> SemanticString) {
        self = builder()
    }

    @inlinable
    public init(components: [any SemanticStringComponent]) {
        self._storage = Storage(treeElements: components)
    }

    @inlinable
    public init(components: [AtomicComponent]) {
        self._storage = Storage(flatComponents: components)
    }

    @inlinable
    public init(components: AtomicComponent...) {
        self._storage = Storage(flatComponents: components)
    }

    @inlinable
    public init(_ component: some SemanticStringComponent) {
        self._storage = Storage(treeElements: [component])
    }

    @inlinable
    public init(stringLiteral value: StringLiteralType) {
        if value.isEmpty {
            self._storage = Storage(flatComponents: [])
        } else {
            let component = AtomicComponent(string: value, type: .standard)
            self._storage = Storage(flatComponents: [component])
            _storage.cachedString = value
        }
    }

    // MARK: - SemanticStringComponent Conformance

    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        components
    }

    // MARK: - Identifier Scopes

    /// Pushes an identifier scope. While the innermost scope is non-nil,
    /// every string appended via `append(_:type:)` / `write(_:type:)` is
    /// stamped with that identifier. Push `nil` to open a barrier scope that
    /// suppresses stamping (e.g. punctuation between independent spans).
    @inlinable
    public mutating func pushIdentifierScope(_ identifier: String?) {
        identifierScopeStack.append(identifier)
    }

    /// Pops the innermost identifier scope. Unbalanced pops are ignored.
    @inlinable
    public mutating func popIdentifierScope() {
        if !identifierScopeStack.isEmpty {
            identifierScopeStack.removeLast()
        }
    }

    // MARK: - Mutation

    /// Appends a single atomic component, staying in the flat representation
    /// when possible. Shared implementation for the stamping and
    /// non-stamping public entry points.
    @usableFromInline
    internal mutating func appendAtomicComponent(_ atomicComponent: AtomicComponent) {
        makeUnique()
        invalidateCache()
        if _storage.isFlat {
            _storage.flatComponents.append(atomicComponent)
        } else {
            _storage.treeElements.append(atomicComponent)
        }
    }

    @inlinable
    public mutating func append(_ string: String, type: SemanticType) {
        if !string.isEmpty {
            appendAtomicComponent(AtomicComponent(string: string, type: type, identifier: identifierScopeStack.last ?? nil))
        }
    }

    @inlinable
    public mutating func append(_ component: some SemanticStringComponent) {
        // Atomic components keep the flat fast path; composites force the
        // tree form because their element boundary is semantic (one element
        // may become one row in `MemberList`-style containers).
        if let atomicComponent = component as? AtomicComponent {
            appendAtomicComponent(atomicComponent)
            return
        }
        makeUnique()
        invalidateCache()
        _storage.convertToTree()
        _storage.treeElements.append(component)
    }

    @inlinable
    public mutating func append(_ semanticString: SemanticString) {
        makeUnique()
        invalidateCache()
        let otherStorage = semanticString._storage
        if _storage.isFlat {
            if otherStorage.isFlat {
                _storage.flatComponents.append(contentsOf: otherStorage.flatComponents)
            } else {
                _storage.convertToTree()
                _storage.treeElements.append(contentsOf: otherStorage.treeElements)
            }
        } else {
            if otherStorage.isFlat {
                // Splice per atom — identical to the pre-two-state behavior,
                // where a decoded/streamed string held each atom as its own
                // boxed element.
                _storage.treeElements.append(contentsOf: otherStorage.flatComponents.map { $0 as any SemanticStringComponent })
            } else {
                _storage.treeElements.append(contentsOf: otherStorage.treeElements)
            }
        }
    }

    // MARK: - Compaction

    /// Collapses the construction-time element tree into the flat typed
    /// representation, releasing every composite component and existential
    /// box the tree held.
    ///
    /// Call this when a string is **finalized** — fully built, about to be
    /// stored, rendered, or encoded — and will never again be consumed
    /// through its element boundaries (e.g. passed as prebuilt `content:` to
    /// a `MemberList`-style container, where one element means one row).
    /// After compaction the `elements` view exposes one element per atomic
    /// component, which is also exactly what flattening produces, so
    /// `components`, `string`, equality, hashing, and `Codable` output are
    /// unchanged.
    ///
    /// Copies of this value made **before** compaction keep their own tree
    /// (copy-on-write); compacting one value never mutates another.
    ///
    /// No-op when the storage is already flat.
    public mutating func compact() {
        if _storage.isFlat {
            return
        }
        let flattened = components
        makeUnique()
        _storage.flatComponents = flattened
        _storage.treeElements = []
        _storage.isFlat = true
        _storage.cachedComponents = nil
    }

    /// Returns a copy of this string with its storage compacted.
    /// See `compact()`.
    public func compacted() -> SemanticString {
        var copy = self
        copy.compact()
        return copy
    }

    // MARK: - Enumeration

    @inlinable
    public func enumerate(using block: (String, SemanticType) -> Void) {
        components.forEach { block($0.string, $0.type) }
    }

    // MARK: - Transformation

    @inlinable
    public func map(_ modifier: (AtomicComponent) -> AtomicComponent) -> SemanticString {
        SemanticString(components: components.map(modifier))
    }

    @inlinable
    public func replacing(_ transform: (SemanticType) -> SemanticType) -> SemanticString {
        map { AtomicComponent(string: $0.string, type: transform($0.type), identifier: $0.identifier) }
    }

    @inlinable
    public func replacing(from types: SemanticType..., to newType: SemanticType) -> SemanticString {
        map { component in
            if types.contains(component.type) {
                return AtomicComponent(string: component.string, type: newType, identifier: component.identifier)
            } else {
                return component
            }
        }
    }

    // MARK: - Prefix and Suffix Checking

    /// Returns `true` if the combined string starts with the given prefix.
    @inlinable
    public func hasPrefix(_ prefix: String) -> Bool {
        string.hasPrefix(prefix)
    }

    /// Returns `true` if the combined string ends with the given suffix.
    @inlinable
    public func hasSuffix(_ suffix: String) -> Bool {
        string.hasSuffix(suffix)
    }

    /// Returns `true` if the first component has the given semantic type.
    @inlinable
    public func starts(with type: SemanticType) -> Bool {
        first?.type == type
    }

    /// Returns `true` if the last component has the given semantic type.
    @inlinable
    public func ends(with type: SemanticType) -> Bool {
        last?.type == type
    }

    /// Returns `true` if the first component's string starts with the given prefix.
    @inlinable
    public func firstComponentHasPrefix(_ prefix: String) -> Bool {
        first?.string.hasPrefix(prefix) ?? false
    }

    /// Returns `true` if the last component's string ends with the given suffix.
    @inlinable
    public func lastComponentHasSuffix(_ suffix: String) -> Bool {
        last?.string.hasSuffix(suffix) ?? false
    }

    // MARK: - Trimming

    /// Returns a new semantic string with leading whitespace-only components removed.
    @inlinable
    public func trimmingLeadingWhitespace() -> SemanticString {
        let items = components
        var startIndex = items.startIndex
        while startIndex < items.endIndex,
              items[startIndex].string.allSatisfy(\.isWhitespace) {
            startIndex += 1
        }
        return SemanticString(components: Array(items[startIndex...]))
    }

    /// Returns a new semantic string with trailing whitespace-only components removed.
    @inlinable
    public func trimmingTrailingWhitespace() -> SemanticString {
        let items = components
        var endIndex = items.endIndex
        while endIndex > items.startIndex,
              items[endIndex - 1].string.allSatisfy(\.isWhitespace) {
            endIndex -= 1
        }
        return SemanticString(components: Array(items[..<endIndex]))
    }

    /// Returns a new semantic string with both leading and trailing whitespace-only components removed.
    @inlinable
    public func trimmingWhitespace() -> SemanticString {
        let items = components
        var startIndex = items.startIndex
        while startIndex < items.endIndex,
              items[startIndex].string.allSatisfy(\.isWhitespace) {
            startIndex += 1
        }
        var endIndex = items.endIndex
        while endIndex > startIndex,
              items[endIndex - 1].string.allSatisfy(\.isWhitespace) {
            endIndex -= 1
        }
        return SemanticString(components: Array(items[startIndex..<endIndex]))
    }

    /// Returns a new semantic string with leading newline-only components removed.
    @inlinable
    public func trimmingLeadingNewlines() -> SemanticString {
        let items = components
        var startIndex = items.startIndex
        while startIndex < items.endIndex,
              items[startIndex].string.allSatisfy(\.isNewline) {
            startIndex += 1
        }
        return SemanticString(components: Array(items[startIndex...]))
    }

    /// Returns a new semantic string with trailing newline-only components removed.
    @inlinable
    public func trimmingTrailingNewlines() -> SemanticString {
        let items = components
        var endIndex = items.endIndex
        while endIndex > items.startIndex,
              items[endIndex - 1].string.allSatisfy(\.isNewline) {
            endIndex -= 1
        }
        return SemanticString(components: Array(items[..<endIndex]))
    }

    /// Returns a new semantic string with both leading and trailing newline-only components removed.
    @inlinable
    public func trimmingNewlines() -> SemanticString {
        let items = components
        var startIndex = items.startIndex
        while startIndex < items.endIndex,
              items[startIndex].string.allSatisfy(\.isNewline) {
            startIndex += 1
        }
        var endIndex = items.endIndex
        while endIndex > startIndex,
              items[endIndex - 1].string.allSatisfy(\.isNewline) {
            endIndex -= 1
        }
        return SemanticString(components: Array(items[startIndex..<endIndex]))
    }

    // MARK: - Subscript Access

    /// Access a component by index.
    @inlinable
    public subscript(index: Int) -> AtomicComponent? {
        let items = components
        guard index >= 0, index < items.count else { return nil }
        return items[index]
    }

    /// Access a range of components.
    @inlinable
    public subscript(range: Range<Int>) -> SemanticString {
        let items = components
        let validRange = range.clamped(to: 0 ..< items.count)
        return SemanticString(components: Array(items[validRange]))
    }

    // MARK: - Dropping

    /// Returns a new semantic string with the first `n` components removed.
    @inlinable
    public func dropFirst(_ n: Int = 1) -> SemanticString {
        SemanticString(components: Array(components.dropFirst(n)))
    }

    /// Returns a new semantic string with the last `n` components removed.
    @inlinable
    public func dropLast(_ n: Int = 1) -> SemanticString {
        SemanticString(components: Array(components.dropLast(n)))
    }

    /// Returns a new semantic string with components while the predicate is true.
    @inlinable
    public func drop(while predicate: (AtomicComponent) -> Bool) -> SemanticString {
        SemanticString(components: Array(components.drop(while: predicate)))
    }

    // MARK: - Prefix/Suffix Extraction

    /// Returns a semantic string containing the first `n` components.
    @inlinable
    public func prefix(_ n: Int) -> SemanticString {
        SemanticString(components: Array(components.prefix(n)))
    }

    /// Returns a semantic string containing the last `n` components.
    @inlinable
    public func suffix(_ n: Int) -> SemanticString {
        SemanticString(components: Array(components.suffix(n)))
    }

    // MARK: - Filtering

    /// Returns a semantic string containing only components of the specified type.
    @inlinable
    public func filter(byType type: SemanticType) -> SemanticString {
        SemanticString(components: components.filter { $0.type == type })
    }

    /// Returns a semantic string containing only components matching the predicate.
    @inlinable
    public func filter(_ predicate: (AtomicComponent) -> Bool) -> SemanticString {
        SemanticString(components: components.filter(predicate))
    }

    // MARK: - Containment

    /// Returns `true` if any component has the specified semantic type.
    @inlinable
    public func contains(type: SemanticType) -> Bool {
        components.contains { $0.type == type }
    }

    /// Returns `true` if the combined string contains the specified substring.
    @inlinable
    public func contains(_ substring: String) -> Bool {
        guard !substring.isEmpty else { return true }
        let source = string.utf8
        let pattern = substring.utf8
        guard source.count >= pattern.count else { return false }
        var sourceIndex = source.startIndex
        let searchEnd = source.index(source.endIndex, offsetBy: -pattern.count)
        while sourceIndex <= searchEnd {
            if source[sourceIndex...].starts(with: pattern) {
                return true
            }
            source.formIndex(after: &sourceIndex)
        }
        return false
    }

    // MARK: - Conditional Operations

    /// Returns the semantic string with the prefix prepended, only if the condition is true.
    @inlinable
    public func prefixed(with prefix: String, if condition: Bool) -> SemanticString {
        condition ? SemanticString(Standard(prefix)).appending(self) : self
    }

    /// Returns the semantic string with the prefix prepended, only if the condition is true.
    @inlinable
    public func prefixed(with prefix: SemanticString, if condition: Bool) -> SemanticString {
        condition ? prefix.appending(self) : self
    }

    /// Returns the semantic string with the prefix prepended, only if the condition is true.
    @inlinable
    public func prefixed(with prefix: some SemanticStringComponent, if condition: Bool) -> SemanticString {
        condition ? SemanticString(prefix).appending(self) : self
    }

    /// Returns the semantic string with the suffix appended, only if the condition is true.
    @inlinable
    public func suffixed(with suffix: String, if condition: Bool) -> SemanticString {
        condition ? appending(SemanticString(Standard(suffix))) : self
    }

    /// Returns the semantic string with the suffix appended, only if the condition is true.
    @inlinable
    public func suffixed(with suffix: SemanticString, if condition: Bool) -> SemanticString {
        condition ? appending(suffix) : self
    }

    /// Returns the semantic string with the suffix appended, only if the condition is true.
    @inlinable
    public func suffixed(with suffix: some SemanticStringComponent, if condition: Bool) -> SemanticString {
        condition ? appending(SemanticString(suffix)) : self
    }

    /// Returns self if the condition is true, otherwise returns an empty semantic string.
    @inlinable
    public func `if`(_ condition: Bool) -> SemanticString {
        condition ? self : SemanticString()
    }

    /// Returns self if the value is non-nil, otherwise returns an empty semantic string.
    /// The closure receives the unwrapped value.
    @inlinable
    public func ifLet<T>(_ value: T?, @SemanticStringBuilder then: (T) -> SemanticString) -> SemanticString {
        if let value {
            return appending(then(value))
        }
        return self
    }

    // MARK: - Appending

    /// Returns a new semantic string with the other string appended.
    ///
    /// Matches the historical semantics of building a fresh string: the
    /// result carries no identifier scopes, regardless of any scopes open
    /// on `self`.
    @inlinable
    public func appending(_ other: SemanticString) -> SemanticString {
        var copy = self
        copy.identifierScopeStack = []
        copy.append(other)
        return copy
    }

    /// Returns a new semantic string with the component appended.
    @inlinable
    public func appending(_ component: some SemanticStringComponent) -> SemanticString {
        var copy = self
        copy.identifierScopeStack = []
        copy.append(component)
        return copy
    }

    /// Returns a new semantic string with the string appended.
    ///
    /// Unlike the mutating `append(_:type:)`, this never stamps identifier
    /// scopes — matching its historical behavior of assembling a fresh
    /// unscoped `AtomicComponent`.
    @inlinable
    public func appending(_ string: String, type: SemanticType = .standard) -> SemanticString {
        guard !string.isEmpty else { return self }
        var copy = self
        copy.identifierScopeStack = []
        copy.appendAtomicComponent(AtomicComponent(string: string, type: type))
        return copy
    }

    // MARK: - Wrapping

    /// Returns a new semantic string wrapped with the given prefix and suffix.
    @inlinable
    public func wrapped(prefix: String, suffix: String) -> SemanticString {
        SemanticString(Standard(prefix))
            .appending(self)
            .appending(Standard(suffix))
    }

    /// Returns a new semantic string wrapped with the given prefix and suffix, only if condition is true.
    @inlinable
    public func wrapped(prefix: String, suffix: String, if condition: Bool) -> SemanticString {
        condition ? wrapped(prefix: prefix, suffix: suffix) : self
    }

    /// Returns a new semantic string wrapped in parentheses.
    @inlinable
    public func parenthesized() -> SemanticString {
        wrapped(prefix: "(", suffix: ")")
    }

    /// Returns a new semantic string wrapped in brackets.
    @inlinable
    public func bracketed() -> SemanticString {
        wrapped(prefix: "[", suffix: "]")
    }

    /// Returns a new semantic string wrapped in braces.
    @inlinable
    public func braced() -> SemanticString {
        wrapped(prefix: "{", suffix: "}")
    }

    /// Returns a new semantic string wrapped in angle brackets.
    @inlinable
    public func angleBracketed() -> SemanticString {
        wrapped(prefix: "<", suffix: ">")
    }
}

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

// MARK: - Operators

extension SemanticString {
    @inlinable
    public static func + (lhs: SemanticString, rhs: SemanticString) -> SemanticString {
        lhs.appending(rhs)
    }

    @inlinable
    public static func + (lhs: SemanticString, rhs: some SemanticStringComponent) -> SemanticString {
        lhs.appending(rhs)
    }

    @inlinable
    public static func += (lhs: inout SemanticString, rhs: SemanticString) {
        lhs.append(rhs)
    }

    @inlinable
    public static func += (lhs: inout SemanticString, rhs: some SemanticStringComponent) {
        lhs.append(rhs)
    }
}
