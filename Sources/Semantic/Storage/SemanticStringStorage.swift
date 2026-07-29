extension SemanticString {
    /// Internal storage class for copy-on-write semantics.
    ///
    /// Storage is a single flat representation:
    ///
    /// - `atoms` — every atomic component, in order, with **no existential
    ///   boxing**. An `AtomicComponent` is 40 bytes, larger than the 24-byte
    ///   inline buffer of an existential container, so storing it as
    ///   `any SemanticStringComponent` would cost a 40-byte container *plus* a
    ///   64-byte heap box per token. The typed array costs 40 bytes total.
    /// - `elementEndOffsets` — element boundaries, as end offsets into
    ///   `atoms`. Element granularity is semantic (containers like
    ///   `MemberList` treat one element as one row), so it is recorded
    ///   explicitly instead of being implied by a boxed element tree.
    ///   Composite components are flattened **eagerly** on append; their
    ///   structure is never retained, because `buildComponents()` takes no
    ///   context and the flattening can only ever be done once.
    ///
    /// `elementEndOffsets == nil` means the boundaries are 1:1 — every atom is
    /// its own element. This is the streaming representation:
    /// `append(_:type:)` / `write(_:)` never allocate a boundary table, and a
    /// string that only ever receives streamed appends carries zero overhead
    /// beyond the atoms themselves. The table is materialized on the first
    /// append whose element is not exactly one non-empty atom, at 8 bytes per
    /// element.
    ///
    /// When the table is materialized, element `i` covers
    /// `atoms[start ..< elementEndOffsets[i]]` with
    /// `start = i == 0 ? 0 : elementEndOffsets[i - 1]`. Offsets are
    /// monotonically non-decreasing and the last one equals `atoms.count`.
    /// A **zero-length element** (`elementEndOffsets[i] ==
    /// elementEndOffsets[i - 1]`) records an appended component that
    /// flattened to nothing — `EmptyComponent`, a `nil` optional, an empty
    /// composite. It contributes no atoms and no text, but it *does* count as
    /// an element, so `isEmpty` and per-element containers observe it exactly
    /// as the historical element tree did.
    ///
    /// **`atoms` never contains a zero-length component**, on any construction
    /// path. Tree flattening historically dropped empty atomics
    /// (`AtomicComponent.buildComponents()` returns `[]` for an empty string);
    /// the flat storage upholds the same rule at every write entry point, so
    /// `components` can hand out `atoms` verbatim with no filtering read and
    /// the same content always compares, hashes, counts, and encodes the same
    /// way regardless of how it was built.
    ///
    /// The only mutable-under-sharing state is `cachedString`, guarded by
    /// `CacheLockStripes`. Everything else is only mutated on
    /// uniquely-referenced storage (`makeUniqueForMutation()`), which needs no
    /// lock.
    @usableFromInline
    final class Storage: @unchecked Sendable {
        /// Every atomic component, flattened, in order. Never contains a
        /// zero-length component.
        @usableFromInline
        var atoms: [AtomicComponent]

        /// Element end offsets into `atoms`; `nil` means every atom is its
        /// own element.
        @usableFromInline
        var elementEndOffsets: [Int]?

        /// Lazy concatenation cache. The single piece of state that may be
        /// written while the storage is shared; every access goes through
        /// `cacheLock`, with one audited exception:
        /// `makeUniqueForMutation()` clears it without the lock *after
        /// proving unique ownership* via `isKnownUniquelyReferenced` — see
        /// the soundness argument there.
        @usableFromInline
        var cachedString: String?

        /// The stripe this instance's cache fills serialize on.
        ///
        /// All mutations other than the cache fill happen on
        /// uniquely-referenced storage (guarded by `makeUniqueForMutation`)
        /// and need no lock.
        @usableFromInline
        var cacheLock: UnsafeMutablePointer<CacheLockStripes.Primitive> {
            CacheLockStripes.stripe(forAddress: UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        }

        @inlinable
        init(atoms: [AtomicComponent], elementEndOffsets: [Int]?) {
            self.atoms = atoms
            self.elementEndOffsets = elementEndOffsets
        }

        @inlinable
        convenience init() {
            self.init(atoms: [], elementEndOffsets: nil)
        }

        /// Copies contents only, leaving the string cache empty.
        ///
        /// This is the copy-on-write path for mutations — every `append`, and
        /// therefore every `appending` / `+` / `wrapped` / `parenthesized`.
        /// Mutations invalidate the cache as their next effect, so copying it
        /// (which would require taking `other`'s stripe lock) would be pure
        /// waste. Being `@inlinable` is safe precisely because the body
        /// touches no locking primitive.
        @inlinable
        init(copyingContentsOf other: Storage) {
            self.atoms = other.atoms
            self.elementEndOffsets = other.elementEndOffsets
        }

        /// The number of elements. `O(1)` in both representations.
        @inlinable
        var elementCount: Int {
            elementEndOffsets?.count ?? atoms.count
        }

        /// Expands the implicit 1:1 boundary table so a non-1:1 element can
        /// be recorded. Must only be called on uniquely-referenced storage.
        @usableFromInline
        func materializeElementEndOffsets() {
            guard elementEndOffsets == nil else { return }
            let atomCount = atoms.count
            if atomCount == 0 {
                elementEndOffsets = []
            } else {
                elementEndOffsets = Array(1 ... atomCount)
            }
        }

        /// Records that the atoms appended since the previous element
        /// boundary form one element. No-op while the table is `nil` and the
        /// element is exactly one atom — that is what 1:1 means.
        ///
        /// Must only be called on uniquely-referenced storage. The
        /// materialization below runs *after* the atoms were appended, so it
        /// must exclude them from the 1:1 prefix — hence the explicit count.
        @usableFromInline
        func closeElement(appendedAtomCount: Int) {
            if elementEndOffsets == nil {
                if appendedAtomCount == 1 {
                    return
                }
                let previousAtomCount = atoms.count - appendedAtomCount
                if previousAtomCount == 0 {
                    elementEndOffsets = []
                } else {
                    elementEndOffsets = Array(1 ... previousAtomCount)
                }
            }
            elementEndOffsets?.append(atoms.count)
        }

        /// Appends another storage's contents, element boundaries included.
        /// Must only be called on uniquely-referenced storage; `other` is
        /// only read.
        @usableFromInline
        func appendContents(of other: Storage) {
            if elementEndOffsets == nil, other.elementEndOffsets == nil {
                // Both 1:1 — the concatenation stays 1:1.
                atoms.append(contentsOf: other.atoms)
                return
            }
            materializeElementEndOffsets()
            let baseAtomCount = atoms.count
            atoms.append(contentsOf: other.atoms)
            if let otherEndOffsets = other.elementEndOffsets {
                for endOffset in otherEndOffsets {
                    elementEndOffsets?.append(baseAtomCount + endOffset)
                }
            } else {
                var endOffset = baseAtomCount + 1
                let finalAtomCount = atoms.count
                while endOffset <= finalAtomCount {
                    elementEndOffsets?.append(endOffset)
                    endOffset += 1
                }
            }
        }

        /// Reads the string cache under its lock. Shared storages may be
        /// filling it concurrently.
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
