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
///
/// Storage is two-state (flat / tree); see `SemanticString.Storage` in
/// `Storage/SemanticStringStorage.swift`.
public struct SemanticString: Sendable, ExpressibleByStringLiteral, SemanticStringComponent {
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

    // MARK: - Copy-on-Write

    /// Ensures unique ownership of storage, preserving the caches.
    ///
    /// Only for callers that go on to *read* the caches — currently just
    /// `compact()`. Mutations want `makeUniqueForMutation()`.
    @usableFromInline
    mutating func makeUnique() {
        if !isKnownUniquelyReferenced(&_storage) {
            _storage = Storage(copying: _storage)
        }
    }

    /// Ensures unique ownership of storage for a mutation, dropping the
    /// caches instead of copying them.
    ///
    /// Every mutation invalidates the cache immediately afterwards, so
    /// carrying it across the copy costs a lock round trip and two array
    /// retains for a value that is discarded on the next line. This path is
    /// `@inlinable` and touches no locking primitive.
    @inlinable
    mutating func makeUniqueForMutation() {
        if isKnownUniquelyReferenced(&_storage) {
            _storage.cachedComponents = nil
            _storage.cachedString = nil
        } else {
            _storage = Storage(copyingContentsOf: _storage)
        }
    }

    /// Invalidates cached values when elements are modified.
    ///
    /// Callers that reached here through `makeUniqueForMutation()` have
    /// already had this done for them.
    @inlinable
    mutating func invalidateCache() {
        _storage.cachedComponents = nil
        _storage.cachedString = nil
    }

    // MARK: - Contents

    /// Element-boundary view of the contents.
    ///
    /// Returns a view rather than an array so that reading elements out of a
    /// flat string does not box every atom. See `SemanticStringElements`.
    @usableFromInline
    var elements: SemanticStringElements {
        if _storage.isFlat {
            return SemanticStringElements(flat: _storage.flatComponents)
        } else {
            return SemanticStringElements(tree: _storage.treeElements)
        }
    }

    public var components: [AtomicComponent] {
        if _storage.isFlat {
            return _storage.flatComponents
        }

        let stripe = _storage.cacheLock
        CacheLockStripes.lock(stripe)
        if let cached = _storage.cachedComponents {
            CacheLockStripes.unlock(stripe)
            return cached
        }
        CacheLockStripes.unlock(stripe)

        // Flatten outside the lock: composite expansion can be expensive and
        // must not serialize the other storages sharing this stripe. Two
        // racing readers may both compute; the store below keeps the winner
        // and both results are identical.
        let computed = flattenedTreeElements()

        CacheLockStripes.lock(stripe)
        if _storage.cachedComponents == nil {
            _storage.cachedComponents = computed
        }
        let result = _storage.cachedComponents ?? computed
        CacheLockStripes.unlock(stripe)
        return result
    }

    /// Expands the tree elements. Callers are responsible for publishing the
    /// result into the cache (or deliberately not publishing it).
    @usableFromInline
    internal func flattenedTreeElements() -> [AtomicComponent] {
        var computed: [AtomicComponent] = []
        computed.reserveCapacity(_storage.treeElements.count)
        for element in _storage.treeElements {
            computed.append(contentsOf: element.buildComponents())
        }
        return computed
    }

    /// The flattened components without publishing them into a possibly
    /// shared cache.
    ///
    /// Uses the cache when it is already populated — that is free — but never
    /// fills it. For callers whose whole purpose is to *reduce* footprint
    /// (`compact()`, `frozen()`), where inflating the source, and every value
    /// sharing its storage, would defeat the exercise.
    @usableFromInline
    internal func componentsWithoutPublishing() -> [AtomicComponent] {
        if _storage.isFlat {
            return _storage.flatComponents
        }
        return _storage.cachedComponentsIfPresent() ?? flattenedTreeElements()
    }

    /// The number of components.
    @inlinable
    public var count: Int { components.count }

    /// The combined string of all components.
    public var string: String {
        let stripe = _storage.cacheLock
        CacheLockStripes.lock(stripe)
        if let cached = _storage.cachedString {
            CacheLockStripes.unlock(stripe)
            return cached
        }
        CacheLockStripes.unlock(stripe)

        let computed = Self.concatenated(components)

        CacheLockStripes.lock(stripe)
        if _storage.cachedString == nil {
            _storage.cachedString = computed
        }
        let result = _storage.cachedString ?? computed
        CacheLockStripes.unlock(stripe)
        return result
    }

    /// Concatenates component strings in a single reserved allocation.
    @usableFromInline
    internal static func concatenated(_ atomicComponents: [AtomicComponent]) -> String {
        var utf8ByteCount = 0
        for atomicComponent in atomicComponents {
            utf8ByteCount += atomicComponent.string.utf8.count
        }
        var computed = ""
        computed.reserveCapacity(utf8ByteCount)
        for atomicComponent in atomicComponents {
            computed += atomicComponent.string
        }
        return computed
    }

    // MARK: - Collection-like Properties

    /// Returns `true` if this string flattens to no components.
    ///
    /// In the flat state this is `O(1)`: the flat form never holds zero-length
    /// components, so an empty array is the only way to flatten to nothing. In
    /// the tree state the element count alone is not enough — an element can
    /// flatten to nothing (`EmptyComponent`, a composite with no items) — so a
    /// non-empty tree consults the elements, stopping at the first one that
    /// produces output. Deciding this from element counts instead makes
    /// `compact()` observably flip `isEmpty` from `false` to `true`.
    ///
    /// Deliberately does *not* go through `components`: that would flatten the
    /// entire tree and publish the result into storage that may be shared,
    /// leaving values that never asked for it holding a full
    /// `[AtomicComponent]`. `ForEach(_:separator:)` calls this once per item,
    /// so the difference is per-item, not per-string.
    @inlinable
    public var isEmpty: Bool {
        if _storage.isFlat {
            return _storage.flatComponents.isEmpty
        }
        return elements.flattensToNothing()
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

    /// Creates a string from atomic components.
    ///
    /// Zero-length components are dropped, because they are not observable in
    /// any other construction path: tree flattening already discards them
    /// (`AtomicComponent.buildComponents()` returns `[]` for an empty string),
    /// so keeping them here would make the same content compare, hash, and
    /// count differently depending on how it was built.
    ///
    /// This is observable to callers that construct components by hand: a
    /// zero-length entry does not survive into `count`, `components`,
    /// subscripting, `Codable` round trips, or equality. It never affected
    /// `string`.
    @inlinable
    public init(components: [AtomicComponent]) {
        self._storage = Storage(flatComponents: Self.droppingZeroLengthComponents(components))
    }

    /// See `init(components:)`. Zero-length components are dropped.
    @inlinable
    public init(components: AtomicComponent...) {
        self._storage = Storage(flatComponents: Self.droppingZeroLengthComponents(components))
    }

    /// Upholds the flat form's "no zero-length components" invariant for
    /// caller-supplied arrays. Scans first so the common case — nothing to
    /// drop — keeps the array as is instead of reallocating it.
    @usableFromInline
    internal static func droppingZeroLengthComponents(_ components: [AtomicComponent]) -> [AtomicComponent] {
        if components.contains(where: { $0.string.isEmpty }) {
            return components.filter { !$0.string.isEmpty }
        }
        return components
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
}
