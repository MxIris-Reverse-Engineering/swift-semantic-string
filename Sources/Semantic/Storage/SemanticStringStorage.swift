extension SemanticString {
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
    ///   whole here because element granularity is semantic: containers like
    ///   `MemberList` treat each element as one row.
    ///
    /// The invariant that keeps both forms observably identical to the
    /// original single-array storage: the flat form only ever holds content
    /// the old storage would have kept as individually boxed
    /// `AtomicComponent` elements, so the element view has the same per-atom
    /// granularity in both representations. Composites never enter the flat
    /// form; appending one to a flat string first converts the existing atoms
    /// into tree elements (`convertToTree`).
    ///
    /// The second invariant, which lets `components` hand out
    /// `flatComponents` directly instead of re-filtering it on every read:
    /// **`flatComponents` never contains a zero-length component.** Tree
    /// flattening drops those (`AtomicComponent.buildComponents()` returns
    /// `[]` for an empty string), so every entry point into the flat form has
    /// to drop them as well or the two representations would disagree on
    /// component counts, equality, and container layout. The entry points are
    /// `appendAtomicComponent(_:)`, the `[AtomicComponent]` initializers, and
    /// `compact()` — which is fed already-filtered flattening output.
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

        /// The stripe this instance's cache fills serialize on.
        ///
        /// All mutations other than the cache fills happen on
        /// uniquely-referenced storage (guarded by `makeUnique`) and need no
        /// lock.
        @usableFromInline
        var cacheLock: UnsafeMutablePointer<CacheLockStripes.Primitive> {
            CacheLockStripes.stripe(forAddress: UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        }

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

        /// Copies contents *and* the caches. Deliberately not `@inlinable`:
        /// the body touches the cache under `other`'s stripe lock, and a
        /// cross-module inlined body would have to expose the locking
        /// primitives too.
        ///
        /// Only for callers that go on to *read* the caches. Every mutation
        /// path wants `init(copyingContentsOf:)` instead, which skips the lock
        /// and the two cache copies the caller would throw away.
        @usableFromInline
        init(copying other: Storage) {
            // `isFlat` and the two content arrays are only ever mutated on
            // uniquely-referenced storage, and `other` is shared by definition
            // here, so they need no lock. The cache fields are the exception:
            // a concurrent reader may be filling them right now.
            self.isFlat = other.isFlat
            self.flatComponents = other.flatComponents
            self.treeElements = other.treeElements
            let stripe = other.cacheLock
            CacheLockStripes.lock(stripe)
            self.cachedComponents = other.cachedComponents
            self.cachedString = other.cachedString
            CacheLockStripes.unlock(stripe)
        }

        /// Copies contents only, leaving the caches empty.
        ///
        /// This is the copy-on-write path for *mutations*, which is every
        /// `append` and therefore every `appending` / `+` / `wrapped` /
        /// `parenthesized`. Those callers invalidate the cache as their next
        /// statement, so copying it under a lock is pure waste: two array
        /// retains and a lock round trip per call, on a path that used to be
        /// neither. Being `@inlinable` matters here for the same reason —
        /// it touches no locking primitive, so it can cross module boundaries.
        @inlinable
        init(copyingContentsOf other: Storage) {
            self.isFlat = other.isFlat
            self.flatComponents = other.flatComponents
            self.treeElements = other.treeElements
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

        /// Reads the flattened-components cache without publishing anything.
        /// Used by the paths that must not inflate a storage they may be
        /// sharing (`compact()`, `frozen()`).
        @usableFromInline
        func cachedComponentsIfPresent() -> [AtomicComponent]? {
            let stripe = cacheLock
            CacheLockStripes.lock(stripe)
            let cached = cachedComponents
            CacheLockStripes.unlock(stripe)
            return cached
        }

        /// Reads the string cache without publishing anything. See
        /// `cachedComponentsIfPresent()`.
        @usableFromInline
        func cachedStringIfPresent() -> String? {
            let stripe = cacheLock
            CacheLockStripes.lock(stripe)
            let cached = cachedString
            CacheLockStripes.unlock(stripe)
            return cached
        }
    }
}
