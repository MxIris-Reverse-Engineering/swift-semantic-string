/// A string composed of semantically typed components.
///
/// `SemanticString` is the primary type for building styled text output.
/// It stores a flat array of atomic components plus an explicit element
/// boundary table; composite components are flattened eagerly when they are
/// appended. See `SemanticString.Storage` in
/// `Storage/SemanticStringStorage.swift` for the representation and its
/// invariants.
///
/// This type implements copy-on-write semantics for efficient copying
/// and caches the concatenated string to avoid redundant work.
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
    @usableFromInline
    var _storage: Storage

    /// Transient identifier-scope stack used while a printer streams content
    /// into this string. The innermost (last) entry stamps the `identifier`
    /// of every string appended via `append(_:type:)` / `write(_:type:)`;
    /// a `nil` entry acts as a barrier that suppresses stamping until a
    /// nested non-nil scope overrides it. Component appends never stamp —
    /// a component that wants an identifier carries its own
    /// (`AtomicComponent(string:type:identifier:)`). This is writer-side
    /// state only: it does not participate in equality, hashing, or coding,
    /// and flattened components keep the stamps they were born with.
    @usableFromInline
    var identifierScopeStack: [String?] = []

    // MARK: - Copy-on-Write

    /// Ensures unique ownership of storage for a mutation, dropping the
    /// string cache instead of copying it.
    ///
    /// Every mutation invalidates the cache immediately afterwards, so
    /// carrying it across the copy would cost a lock round trip for a value
    /// that is discarded on the next line. This is the only copy-on-write
    /// path; it is `@inlinable` because it touches no locking primitive.
    @inlinable
    mutating func makeUniqueForMutation() {
        if isKnownUniquelyReferenced(&_storage) {
            _storage.cachedString = nil
        } else {
            _storage = Storage(copyingContentsOf: _storage)
        }
    }

    // MARK: - Contents

    /// Element-boundary view of the contents. Zero-copy; see
    /// `SemanticStringElements`.
    @usableFromInline
    var elements: SemanticStringElements {
        SemanticStringElements(atoms: _storage.atoms, elementEndOffsets: _storage.elementEndOffsets)
    }

    /// The flattened components. Free: the flat atom array *is* the storage,
    /// so this read allocates nothing, takes no lock, and fills no cache.
    @inlinable
    public var components: [AtomicComponent] {
        _storage.atoms
    }

    /// The number of components.
    @inlinable
    public var count: Int { _storage.atoms.count }

    /// The combined string of all components.
    ///
    /// Lazily computed and cached. The cache is the one piece of state that
    /// may be written while the storage is shared, so both the read and the
    /// publish take the storage's lock stripe — a racing pair of readers may
    /// both compute, the first store wins, and the results are identical.
    public var string: String {
        let stripe = _storage.cacheLock
        CacheLockStripes.lock(stripe)
        if let cached = _storage.cachedString {
            CacheLockStripes.unlock(stripe)
            return cached
        }
        CacheLockStripes.unlock(stripe)

        // Concatenate outside the lock: it can be expensive and must not
        // serialize the other storages sharing this stripe.
        let computed = Self.concatenated(_storage.atoms)

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

    /// Returns `true` if this string has no elements. `O(1)`.
    ///
    /// An element that flattens to nothing — `EmptyComponent`, an appended
    /// `nil` optional, an empty composite — still counts: appending one
    /// records a zero-length element, so `isEmpty` becomes `false` even
    /// though `string` is unchanged. This matches the historical element
    /// tree, where such an element occupied a slot in the element array.
    /// `count` (the number of *components*) is the render-oriented measure.
    @inlinable
    public var isEmpty: Bool {
        _storage.elementCount == 0
    }

    /// Returns the first component, or `nil` if empty.
    @inlinable
    public var first: AtomicComponent? { _storage.atoms.first }

    /// Returns the last component, or `nil` if empty.
    @inlinable
    public var last: AtomicComponent? { _storage.atoms.last }

    // MARK: - Initialization

    @inlinable
    public init() {
        self._storage = Storage()
    }

    @inlinable
    public init(@SemanticStringBuilder builder: () -> SemanticString) {
        self = builder()
    }

    /// Creates a string from components, one element each, flattening them
    /// eagerly. Components that flatten to nothing are recorded as
    /// zero-length elements.
    @inlinable
    public init(components: [any SemanticStringComponent]) {
        self._storage = Storage()
        for component in components {
            append(component)
        }
    }

    /// Creates a string from atomic components.
    ///
    /// Zero-length components are dropped, because they are not observable in
    /// any other construction path: flattening already discards them
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
        self._storage = Storage(
            atoms: Self.droppingZeroLengthComponents(components),
            elementEndOffsets: nil
        )
    }

    /// See `init(components:)`. Zero-length components are dropped.
    @inlinable
    public init(components: AtomicComponent...) {
        self.init(components: components)
    }

    /// Upholds the storage's "no zero-length components" invariant for
    /// caller-supplied arrays. Scans first so the common case — nothing to
    /// drop — keeps the array as is instead of reallocating it.
    @usableFromInline
    internal static func droppingZeroLengthComponents(_ components: [AtomicComponent]) -> [AtomicComponent] {
        if components.contains(where: { $0.string.isEmpty }) {
            return components.filter { !$0.string.isEmpty }
        }
        return components
    }

    /// Creates a string holding one component as one element.
    @inlinable
    public init(_ component: some SemanticStringComponent) {
        self._storage = Storage()
        append(component)
    }

    @inlinable
    public init(stringLiteral value: StringLiteralType) {
        if value.isEmpty {
            self._storage = Storage()
        } else {
            let component = AtomicComponent(string: value, type: .standard)
            self._storage = Storage(atoms: [component], elementEndOffsets: nil)
            _storage.cachedString = value
        }
    }

    // MARK: - SemanticStringComponent Conformance

    @inlinable
    public func buildComponents() -> [AtomicComponent] {
        _storage.atoms
    }
}
