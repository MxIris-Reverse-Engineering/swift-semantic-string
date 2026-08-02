#if canImport(Darwin)
import os.lock
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Bionic)
import Bionic
#elseif canImport(WinSDK)
import WinSDK
#endif

/// Process-wide table of small locks guarding the lazy cache fills of
/// `SemanticString.Storage`, indexed by storage address.
///
/// A single process-wide lock serializes the cache fills of unrelated strings,
/// which is the dominant cost when several threads each build masses of
/// transient strings — the exact workload `SemanticString` is optimized for. A
/// lock per instance would instead add an allocation to every transient
/// string. Striping by storage address gets both: no per-instance allocation,
/// and contention only between the rare pair of live storages that land on the
/// same stripe.
///
/// This is the only place in the target that touches a platform locking
/// primitive. Everything above it is platform-agnostic.
@usableFromInline
enum CacheLockStripes {
    /// The platform's cheapest non-recursive mutual-exclusion primitive.
    ///
    /// `os_unfair_lock` on Darwin (`Synchronization.Mutex` would require
    /// macOS 15 against a macOS 10.15 deployment target, and `NSLock` would
    /// drag in Foundation), `SRWLOCK` on Windows, and `pthread_mutex_t`
    /// everywhere else.
    #if canImport(Darwin)
    @usableFromInline
    typealias Primitive = os_unfair_lock_s
    #elseif canImport(WinSDK)
    @usableFromInline
    typealias Primitive = SRWLOCK
    #else
    @usableFromInline
    typealias Primitive = pthread_mutex_t
    #endif

    /// Number of stripes. Must be a power of two so `stripeIndex` can mask
    /// instead of divide.
    @usableFromInline
    static let count = 256

    /// Bytes between adjacent stripes. Locking primitives are small — an
    /// `os_unfair_lock` is 4 bytes — so packing the stripes would put dozens
    /// of them on one cache line: threads locking *different* stripes would
    /// still bounce the same line between cores, and the table would serialize
    /// as badly as a single lock (measured: as slow as running the same work on
    /// one thread). One cache line per stripe removes that false sharing.
    ///
    /// Derived rather than hard-coded, so it cannot be wrong. 128 covers a
    /// cache line on every target this package builds for, but `Primitive` is
    /// `pthread_mutex_t` off Darwin and Windows — an opaque platform-defined
    /// block (40 bytes on glibc, no guarantee elsewhere) that nothing here
    /// bounds. A hard-coded 128 with a runtime `precondition` traded a
    /// compile-clean build for a trap inside `swift_once` on the first
    /// `SemanticString.string` read anywhere in the process — and under
    /// `-Ounchecked`, where preconditions are removed, for adjacent stripes
    /// silently overlapping and mutual exclusion vanishing outright. Taking
    /// the max here makes both outcomes unreachable instead of merely loud.
    ///
    /// Doubling (rather than rounding up to a multiple of 128) keeps the
    /// result a power of two, which `allocate(byteCount:alignment:)` requires
    /// of its alignment — 384 would be a legal cache-line multiple and an
    /// illegal alignment.
    @usableFromInline
    static let stride: Int = {
        var candidate = 128
        while candidate < MemoryLayout<Primitive>.stride {
            candidate *= 2
        }
        return candidate
    }()

    /// `nonisolated(unsafe)` because the pointer itself is immutable after the
    /// one-time allocation; what it points at is mutable precisely so the
    /// locking primitive can do its job, and that memory is only ever touched
    /// through `lock` / `unlock`.
    @usableFromInline
    nonisolated(unsafe) static let base: UnsafeMutableRawPointer = {
        // `stride` is derived as `max(128, next power of two ≥ the
        // primitive's stride)`, so it fits the platform's locking primitive
        // by construction — a stripe can no longer overlap its neighbour, on
        // any platform, in any optimization mode. The assertion that used to
        // stand here was a runtime check in a lazily-initialized `static let`:
        // it would have fired inside `swift_once` on the first cache fill
        // rather than at build time, and `-Ounchecked` would have removed it
        // entirely. Kept as a debug-only restatement of the invariant.
        assert(
            MemoryLayout<Primitive>.stride <= stride && stride.nonzeroBitCount == 1,
            "CacheLockStripes.stride must fit the platform's locking primitive and stay a power of two"
        )
        let table = UnsafeMutableRawPointer.allocate(byteCount: count * stride, alignment: stride)
        for stripeIndex in 0 ..< count {
            let stripe = table.advanced(by: stripeIndex * stride)
                .initializeMemory(as: Primitive.self, repeating: Primitive(), count: 1)
            #if !canImport(Darwin)
            initializePrimitive(stripe)
            #endif
        }
        return table
    }()

    /// The stripe an object at `address` serializes on.
    ///
    /// Object addresses are at least 16-byte aligned, so the low bits carry no
    /// entropy — shift them out, then mix so that consecutive allocations
    /// (which a printer produces by the thousand) spread across the table
    /// instead of marching through it in lockstep.
    ///
    /// The mix runs in `UInt64` regardless of the platform's pointer width.
    /// Doing it in `UInt` would not compile on 32-bit targets — the multiplier
    /// does not fit — and truncating the multiplier instead would leave the
    /// high half of the product unpopulated, collapsing every 32-bit address
    /// onto stripe 0 and degrading the table into the single global lock this
    /// design exists to avoid.
    @usableFromInline
    static func stripe(forAddress address: UInt) -> UnsafeMutablePointer<Primitive> {
        let mixed = (UInt64(address) >> 4) &* 0x9E37_79B9_7F4A_7C15
        let stripeIndex = Int((mixed >> 32) & UInt64(count - 1))
        return base.advanced(by: stripeIndex * stride)
            .assumingMemoryBound(to: Primitive.self)
    }

    @usableFromInline
    static func lock(_ stripe: UnsafeMutablePointer<Primitive>) {
        #if canImport(Darwin)
        os_unfair_lock_lock(stripe)
        #elseif canImport(WinSDK)
        AcquireSRWLockExclusive(stripe)
        #else
        pthread_mutex_lock(stripe)
        #endif
    }

    @usableFromInline
    static func unlock(_ stripe: UnsafeMutablePointer<Primitive>) {
        #if canImport(Darwin)
        os_unfair_lock_unlock(stripe)
        #elseif canImport(WinSDK)
        ReleaseSRWLockExclusive(stripe)
        #else
        pthread_mutex_unlock(stripe)
        #endif
    }

    #if !canImport(Darwin)
    /// Darwin's `os_unfair_lock` is usable zero-initialized; the other
    /// primitives need an explicit initializer call. The table is never torn
    /// down, so there is no matching destroy.
    @usableFromInline
    static func initializePrimitive(_ stripe: UnsafeMutablePointer<Primitive>) {
        #if canImport(WinSDK)
        InitializeSRWLock(stripe)
        #else
        pthread_mutex_init(stripe, nil)
        #endif
    }
    #endif
}
