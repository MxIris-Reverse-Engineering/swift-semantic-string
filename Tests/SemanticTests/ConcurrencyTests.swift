import Foundation
import Testing
@testable import Semantic

/// Concurrency contract of `SemanticString` and `FrozenSemanticString`.
///
/// `SemanticString` is a `Sendable` value type over a `@unchecked Sendable`
/// storage class, which puts three promises on the implementation:
///
/// 1. Reading a value shared across threads is safe even when its caches are
///    cold, because the lazy `cachedComponents` / `cachedString` fills are
///    serialized by `Storage`'s striped locks.
/// 2. Copying and mutating a shared value is safe and isolated, because
///    `makeUnique()` copies the storage first — including its cache, which is
///    read under the same lock a concurrent filler holds.
/// 3. No lock is ever held while calling back into component code, so
///    flattening a string whose elements are themselves strings cannot
///    deadlock — not even when the two storages hash to the same stripe.
///
/// **Most of these tests pass trivially in a normal run.** What they guard
/// against is data races and lock-ordering bugs, which surface only under
/// instrumentation or an unlucky interleaving. Run the suite under
/// ThreadSanitizer whenever storage, caching, or locking changes:
///
/// ```
/// swift test --sanitize=thread --filter ConcurrencyTests
/// ```
@Suite("Concurrency")
struct ConcurrencyTests {
    // MARK: - Fixtures

    private static let taskCount = 8
    private static let roundCount = 32

    /// One member declaration as its own `SemanticString`, so it becomes a
    /// single element of any string that embeds it — and its own `Storage`,
    /// with its own cache and its own stripe.
    private func memberString(_ name: String) -> SemanticString {
        SemanticString {
            Keyword("var")
            Space()
            Variable(name)
            Standard(": ")
            TypeName(kind: .struct, "Int")
        }
    }

    /// A tree-state string whose elements are whole nested `SemanticString`s.
    /// Flattening it recurses into their storages, which is the shape that
    /// would deadlock if flattening ever moved inside the cache lock.
    private func nestedString(index: Int = 0) -> SemanticString {
        SemanticString {
            DeclarationBlock(level: 0) {
                Keyword("struct")
                Space()
                TypeDeclaration(kind: .struct, "Type\(index)")
            } body: {
                MemberList(level: 1) {
                    memberString("first\(index)")
                    memberString("second\(index)")
                }
            }
        }
    }

    /// A flat-state string, the shape a printer streams. Its `components` read
    /// takes no lock at all, which only holds because mutations happen on
    /// uniquely-referenced storage.
    private func streamedString(index: Int = 0) -> SemanticString {
        var semanticString = SemanticString()
        semanticString.append("var", type: .keyword)
        semanticString.append(" ", type: .standard)
        semanticString.append("value\(index)", type: .variable)
        return semanticString
    }

    /// Expected values come from a separately built instance of the same
    /// content, never from the instance under test — otherwise a divergence
    /// would compare equal to itself and the test would prove nothing.
    private func expectedComponentsAndString(forNestedIndex index: Int = 0) -> ([AtomicComponent], String) {
        let reference = nestedString(index: index)
        return (reference.components, reference.string)
    }

    // MARK: - Reading a Shared Value

    @Test("Every derived read of a shared cold-cache value agrees with the reference")
    func concurrentDerivedReadsAgree() async {
        let (expectedComponents, expectedString) = expectedComponentsAndString()

        for _ in 0 ..< Self.roundCount {
            // A fresh instance per round, so the racing readers actually hit
            // the cold-fill path instead of an already-populated cache.
            let shared = nestedString()

            await withTaskGroup(of: Bool.self) { group in
                group.addTask { shared.string == expectedString }
                group.addTask { shared.components == expectedComponents }
                group.addTask { shared.count == expectedComponents.count }
                group.addTask { shared.isEmpty == false }
                group.addTask { shared.first == expectedComponents.first }
                group.addTask { shared.last == expectedComponents.last }
                group.addTask { shared.buildComponents() == expectedComponents }
                group.addTask { shared.contains("struct") }

                for await isConsistent in group {
                    #expect(isConsistent)
                }
            }
        }
    }

    @Test("Interleaved string-first and components-first fills reach the same result")
    func concurrentCrossOrderedCacheFills() async {
        // `string` fills its own cache *and* goes through `components`, so the
        // two fills can interleave in either order on the same storage.
        let (expectedComponents, expectedString) = expectedComponentsAndString()

        for _ in 0 ..< Self.roundCount {
            let shared = nestedString()

            await withTaskGroup(of: Bool.self) { group in
                for taskIndex in 0 ..< Self.taskCount {
                    group.addTask {
                        if taskIndex.isMultiple(of: 2) {
                            let text = shared.string
                            let components = shared.components
                            return text == expectedString && components == expectedComponents
                        } else {
                            let components = shared.components
                            let text = shared.string
                            return components == expectedComponents && text == expectedString
                        }
                    }
                }
                for await isConsistent in group {
                    #expect(isConsistent)
                }
            }
        }
    }

    @Test("Equality and hashing of a shared cold-cache value are stable under concurrency")
    func concurrentEqualityAndHashing() async {
        for _ in 0 ..< Self.roundCount {
            let shared = nestedString()
            let reference = nestedString()
            let expectedHashValue = reference.hashValue

            await withTaskGroup(of: Bool.self) { group in
                for taskIndex in 0 ..< Self.taskCount {
                    group.addTask {
                        if taskIndex.isMultiple(of: 2) {
                            return shared == reference
                        } else {
                            return shared.hashValue == expectedHashValue
                        }
                    }
                }
                for await isConsistent in group {
                    #expect(isConsistent)
                }
            }
        }
    }

    @Test("Distinct storages fill their caches concurrently across the whole stripe table")
    func concurrentColdFillsOfDistinctStorages() async {
        // Exercises the stripe index arithmetic over many addresses at once,
        // rather than hammering one storage. A miscomputed index would show up
        // here as a wrong result or a crash, not as a slowdown.
        let stringCount = SemanticString.Storage.cacheLockStripeCount * 2

        await withTaskGroup(of: Bool.self) { group in
            for index in 0 ..< stringCount {
                group.addTask {
                    let (expectedComponents, expectedString) = self.expectedComponentsAndString(forNestedIndex: index)
                    let subject = self.nestedString(index: index)
                    return subject.string == expectedString && subject.components == expectedComponents
                }
            }
            for await isConsistent in group {
                #expect(isConsistent)
            }
        }
    }

    // MARK: - Copying and Mutating a Shared Value

    @Test("Concurrent copy-on-write mutations of a shared value are isolated")
    func concurrentCopyOnWriteMutationsAreIsolated() async {
        // The copy path (`makeUnique()` → `Storage(copying:)`) reads the shared
        // cache while other tasks may be filling it. Each task must still see
        // only its own suffix, and the shared value must come out untouched.
        let (expectedComponents, expectedString) = expectedComponentsAndString()

        for _ in 0 ..< Self.roundCount {
            let shared = nestedString()

            await withTaskGroup(of: Bool.self) { group in
                for taskIndex in 0 ..< Self.taskCount {
                    group.addTask {
                        var mutatedCopy = shared
                        mutatedCopy.append("suffix\(taskIndex)", type: .standard)
                        return mutatedCopy.string == expectedString + "suffix\(taskIndex)"
                            && mutatedCopy.count == expectedComponents.count + 1
                    }
                }
                // Readers of the original run alongside the mutating copies.
                group.addTask { shared.string == expectedString }
                group.addTask { shared.components == expectedComponents }

                for await isConsistent in group {
                    #expect(isConsistent)
                }
            }

            #expect(shared.string == expectedString)
            #expect(shared.components == expectedComponents)
        }
    }

    @Test("Concurrent appending operators leave the shared value alone")
    func concurrentAppendingOperatorsAreIsolated() async {
        // `appending(_:)`, `+`, and `+=` all copy first. They also route
        // components through the existential fallback in the generic `append`
        // overload, so they exercise a different entry point than `append`.
        let (expectedComponents, expectedString) = expectedComponentsAndString()

        for _ in 0 ..< Self.roundCount {
            let shared = nestedString()

            await withTaskGroup(of: Bool.self) { group in
                for taskIndex in 0 ..< Self.taskCount {
                    group.addTask {
                        switch taskIndex % 4 {
                        case 0:
                            return shared.appending("tail", type: .standard).string == expectedString + "tail"
                        case 1:
                            return shared.appending(Keyword("tail")).string == expectedString + "tail"
                        case 2:
                            return (shared + SemanticString(Keyword("tail"))).string == expectedString + "tail"
                        default:
                            var accumulator = shared
                            accumulator += Keyword("tail")
                            return accumulator.string == expectedString + "tail"
                        }
                    }
                }
                for await isConsistent in group {
                    #expect(isConsistent)
                }
            }

            #expect(shared.components == expectedComponents)
        }
    }

    @Test("Flat storage is safe to read while copies of it are mutated")
    func concurrentReadsOfFlatStorageDuringCopyMutation() async {
        // In the flat state `components` returns the array with no lock, which
        // is only sound because the array is never mutated in place on shared
        // storage. Mutating copies concurrently is the case that would break
        // that assumption.
        for _ in 0 ..< Self.roundCount {
            let shared = streamedString()
            #expect(shared._storage.isFlat)
            let reference = streamedString()
            let expectedComponents = reference.components
            let expectedString = reference.string

            await withTaskGroup(of: Bool.self) { group in
                for taskIndex in 0 ..< Self.taskCount {
                    group.addTask {
                        if taskIndex.isMultiple(of: 2) {
                            return shared.components == expectedComponents && shared.string == expectedString
                        } else {
                            var mutatedCopy = shared
                            mutatedCopy.append(Keyword("extra"))
                            return mutatedCopy.count == expectedComponents.count + 1
                        }
                    }
                }
                for await isConsistent in group {
                    #expect(isConsistent)
                }
            }

            #expect(shared.components == expectedComponents)
        }
    }

    @Test("Concurrent transformations of a shared value agree with the reference")
    func concurrentTransformationsAgree() async {
        // Every one of these reads `components` and builds a new value from it,
        // so they all run through the cold-fill path on the shared storage.
        for _ in 0 ..< Self.roundCount {
            let shared = nestedString()
            let reference = nestedString()

            let expectedMapped = reference.map { AtomicComponent(string: $0.string.uppercased(), type: $0.type) }.string
            let expectedReplaced = reference.replacing(from: .keyword, to: .comment).components
            let expectedFiltered = reference.filter(byType: .keyword).count
            let expectedTrimmed = reference.trimmingNewlines().string
            let expectedPrefix = reference.prefix(3).string
            let expectedDropped = reference.dropFirst(2).string
            let expectedSubscript = reference[1]

            await withTaskGroup(of: Bool.self) { group in
                for taskIndex in 0 ..< Self.taskCount {
                    group.addTask {
                        switch taskIndex % 7 {
                        case 0:
                            return shared.map { AtomicComponent(string: $0.string.uppercased(), type: $0.type) }.string == expectedMapped
                        case 1:
                            return shared.replacing(from: .keyword, to: .comment).components == expectedReplaced
                        case 2:
                            return shared.filter(byType: .keyword).count == expectedFiltered
                        case 3:
                            return shared.trimmingNewlines().string == expectedTrimmed
                        case 4:
                            return shared.prefix(3).string == expectedPrefix
                        case 5:
                            return shared.dropFirst(2).string == expectedDropped
                        default:
                            return shared[1] == expectedSubscript
                        }
                    }
                }
                for await isConsistent in group {
                    #expect(isConsistent)
                }
            }
        }
    }

    @Test("Concurrent encoding of a shared value is byte-identical")
    func concurrentEncodingIsByteIdentical() async throws {
        let reference = nestedString()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expectedData = try encoder.encode(reference)

        for _ in 0 ..< Self.roundCount {
            let shared = nestedString()

            await withTaskGroup(of: Bool.self) { group in
                for _ in 0 ..< Self.taskCount {
                    group.addTask {
                        let taskEncoder = JSONEncoder()
                        taskEncoder.outputFormatting = [.sortedKeys]
                        return (try? taskEncoder.encode(shared)) == expectedData
                    }
                }
                for await isConsistent in group {
                    #expect(isConsistent)
                }
            }
        }
    }

    // MARK: - Lock Ordering

    @Test("Flattening a nested string that shares its stripe never deadlocks")
    func flatteningNestedStringSharingAStripeDoesNotDeadlock() {
        // Flattening a string reads the `components` of every nested string it
        // holds, and each of those takes its own stripe lock. `os_unfair_lock`
        // is not recursive, so if flattening ever ran *inside* the lock, this
        // self-deadlocks as soon as an outer storage and one of its nested
        // storages land on the same stripe. A regression hangs rather than
        // fails, which is the intended signal.
        //
        // Such a collision cannot be reached by building many pairs and hoping.
        // The stripe index is a multiplicative hash of the storage address, and
        // multiplication is linear: two storages allocated a *fixed* number of
        // bytes apart — which is exactly what a loop building identical pairs
        // produces — always differ by the same stripe delta, so they either
        // always collide or never do. Measured: 4096 identical pairs, zero
        // collisions. Varying how much is allocated *between* the two storages
        // moves that delta, and collisions appear on a fixed period (186, 373,
        // 560, … with the current stripe count).
        //
        // So search for a colliding gap, then flatten. `collisionWasExercised`
        // keeps the test honest: without it, a future change to the stripe
        // function could make collisions unreachable and this would silently
        // pass while testing nothing.
        var retainedValues: [Any] = []
        var collisionWasExercised = false

        for allocationGap in 0 ..< 1024 {
            let nestedMember = memberString("value\(allocationGap)")

            var filler: [SemanticString] = []
            filler.reserveCapacity(allocationGap)
            for fillerIndex in 0 ..< allocationGap {
                filler.append(SemanticString(components: [AtomicComponent(string: "f\(fillerIndex)", type: .standard)]))
            }

            let outer = SemanticString {
                nestedMember
            }

            if outer._storage.cacheLock == nestedMember._storage.cacheLock {
                // Both flattening paths recurse into `nestedMember` while the
                // shared stripe would already be held.
                let expectedString = memberString("value\(allocationGap)").string
                #expect(outer.string == expectedString)
                #expect(outer.components == memberString("value\(allocationGap)").components)
                collisionWasExercised = true
            }

            retainedValues.append(nestedMember)
            retainedValues.append(filler)
            retainedValues.append(outer)
        }

        #expect(collisionWasExercised, "no stripe collision was reachable, so the recursive lock path went untested")
    }

    @Test("Deeply nested composite strings flatten without deadlocking")
    func nestedCompositeStringsFlattenWithoutDeadlock() {
        // The realistic shape — `DeclarationBlock` over `MemberList` over
        // per-member `SemanticString`s — flattened many times over. This does
        // not guarantee a stripe collision (see above); it covers the recursion
        // through the real composite components instead.
        for index in 0 ..< (SemanticString.Storage.cacheLockStripeCount * 4) {
            let subject = nestedString(index: index)
            #expect(subject.string.contains("Type\(index)"))
        }
    }

    @Test("Concurrent reads of nested strings from both ends never deadlock")
    func concurrentNestedReadsFromBothEndsDoNotDeadlock() async {
        // Tasks enter from the outside (flattening the outer string, which
        // locks the nested storages) and from the inside (locking a nested
        // storage directly) at the same time. Unlike the collision search
        // above this makes no claim about sharing a stripe; it covers the
        // two-level ordering under real contention.
        for index in 0 ..< Self.roundCount {
            let nestedMember = memberString("shared\(index)")
            let outer = SemanticString {
                MemberList(level: 1) {
                    nestedMember
                    nestedMember
                }
            }
            let expectedMemberString = memberString("shared\(index)").string

            await withTaskGroup(of: Bool.self) { group in
                for taskIndex in 0 ..< Self.taskCount {
                    group.addTask {
                        if taskIndex.isMultiple(of: 2) {
                            return outer.string.contains(expectedMemberString)
                        } else {
                            return nestedMember.string == expectedMemberString
                        }
                    }
                }
                for await isConsistent in group {
                    #expect(isConsistent)
                }
            }
        }
    }

    // MARK: - Freezing

    @Test("Concurrent freezing of a shared value produces identical snapshots")
    func concurrentFreezingProducesIdenticalSnapshots() async {
        // `frozen()` reads both caches — `components` for the spans and
        // `string` for the text arena — so freezing a cold shared value races
        // two fills at once.
        for _ in 0 ..< Self.roundCount {
            let shared = nestedString()
            let expectedFrozen = nestedString().frozen()

            await withTaskGroup(of: Bool.self) { group in
                for taskIndex in 0 ..< Self.taskCount {
                    group.addTask {
                        if taskIndex.isMultiple(of: 2) {
                            return shared.frozen() == expectedFrozen
                        } else {
                            let frozen = shared.frozen()
                            return frozen.text == expectedFrozen.text
                                && frozen.spans == expectedFrozen.spans
                                && frozen.identifierTable == expectedFrozen.identifierTable
                        }
                    }
                }
                for await isConsistent in group {
                    #expect(isConsistent)
                }
            }
        }
    }

    @Test("A frozen value is safe for unrestricted concurrent use")
    func frozenValueIsSafeForConcurrentUse() async {
        // `FrozenSemanticString` is all-`let`, so it claims `Sendable` with no
        // lock and no copy-on-write. This pins that claim: every read path at
        // once, on one shared instance, with no synchronization of any kind.
        var identifierScoped = SemanticString()
        identifierScoped.pushIdentifierScope("$s6Module4TypeV")
        identifierScoped.append("Type", type: .type(.struct, .name))
        identifierScoped.popIdentifierScope()
        identifierScoped.append(".", type: .standard)
        identifierScoped.append("member", type: .member(.name))

        let shared = identifierScoped.frozen()
        let expectedText = shared.text
        let expectedSpanCount = shared.spans.count
        let expectedComponents = shared.components
        let expectedHashValue = shared.hashValue

        await withTaskGroup(of: Bool.self) { group in
            for taskIndex in 0 ..< (Self.taskCount * 4) {
                group.addTask {
                    switch taskIndex % 5 {
                    case 0:
                        return shared.string == expectedText
                    case 1:
                        var walkedText = ""
                        var walkedSpanCount = 0
                        shared.enumerateSpans { spanText, _, _ in
                            walkedText += spanText
                            walkedSpanCount += 1
                        }
                        return walkedText == expectedText && walkedSpanCount == expectedSpanCount
                    case 2:
                        return shared.components == expectedComponents
                    case 3:
                        return shared.hashValue == expectedHashValue
                    default:
                        return shared.count == expectedSpanCount && !shared.isEmpty
                    }
                }
            }
            for await isConsistent in group {
                #expect(isConsistent)
            }
        }
    }

    @Test("Frozen values decoded concurrently from the same payload are equal")
    func concurrentFrozenDecodingIsConsistent() async throws {
        let expectedFrozen = nestedString().frozen()
        let payload = try JSONEncoder().encode(expectedFrozen)

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< (Self.taskCount * 2) {
                group.addTask {
                    guard let decoded = try? JSONDecoder().decode(FrozenSemanticString.self, from: payload) else {
                        return false
                    }
                    return decoded == expectedFrozen
                }
            }
            for await isConsistent in group {
                #expect(isConsistent)
            }
        }
    }

    // MARK: - Actor Isolation

    /// Holds a `SemanticString` in isolation, so values have to cross an actor
    /// boundary to get in and out.
    private actor SemanticStringHolder {
        private var storedString: SemanticString

        init(_ semanticString: SemanticString) {
            self.storedString = semanticString
        }

        func text() -> String {
            storedString.string
        }

        func componentCount() -> Int {
            storedString.count
        }

        func append(_ suffix: String) {
            storedString.append(suffix, type: .standard)
        }

        func snapshot() -> SemanticString {
            storedString
        }
    }

    @Test("Values cross actor boundaries intact and snapshots stay independent")
    func semanticStringCrossesActorBoundariesIntact() async {
        let (expectedComponents, expectedString) = expectedComponentsAndString()
        let holder = SemanticStringHolder(nestedString())

        // Concurrent reads and writes through the actor, then a snapshot taken
        // out of isolation and read concurrently outside it.
        await withTaskGroup(of: Void.self) { group in
            for taskIndex in 0 ..< Self.taskCount {
                group.addTask {
                    if taskIndex.isMultiple(of: 2) {
                        _ = await holder.text()
                    } else {
                        _ = await holder.componentCount()
                    }
                }
            }
            await group.waitForAll()
        }

        let snapshotBeforeAppend = await holder.snapshot()
        #expect(snapshotBeforeAppend.string == expectedString)
        #expect(snapshotBeforeAppend.components == expectedComponents)

        await holder.append("appended")

        // The snapshot was taken by value, so the actor's later mutation must
        // not be visible through it.
        #expect(snapshotBeforeAppend.string == expectedString)
        #expect(await holder.text() == expectedString + "appended")

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< Self.taskCount {
                group.addTask { snapshotBeforeAppend.string == expectedString }
            }
            for await isConsistent in group {
                #expect(isConsistent)
            }
        }
    }

    // MARK: - Sustained Mixed Load

    @Test("Sustained mixed read, copy, mutate, and freeze load stays consistent")
    func sustainedMixedLoad() async {
        // The long-running interleaving test: every access pattern above, all
        // at once, on a cold shared value, repeated. This is the one most
        // likely to surface a rare interleaving under ThreadSanitizer.
        let (expectedComponents, expectedString) = expectedComponentsAndString()
        let expectedFrozenText = nestedString().frozen().text
        let expectedHashValue = nestedString().hashValue
        let expectedTrimmedString = nestedString().trimmingWhitespace().string

        for _ in 0 ..< (Self.roundCount * 2) {
            let shared = nestedString()

            await withTaskGroup(of: Bool.self) { group in
                for taskIndex in 0 ..< (Self.taskCount * 2) {
                    group.addTask {
                        switch taskIndex % 8 {
                        case 0:
                            return shared.string == expectedString
                        case 1:
                            return shared.components == expectedComponents
                        case 2:
                            var mutatedCopy = shared
                            mutatedCopy.append("z", type: .standard)
                            return mutatedCopy.count == expectedComponents.count + 1
                        case 3:
                            var mutatedCopy = shared
                            mutatedCopy.append(Keyword("k"))
                            return mutatedCopy.string == expectedString + "k"
                        case 4:
                            return shared.frozen().text == expectedFrozenText
                        case 5:
                            return shared.hashValue == expectedHashValue
                        case 6:
                            var mutatedCopy = shared
                            mutatedCopy.append(SemanticString(Keyword("s")))
                            return mutatedCopy.string == expectedString + "s"
                        default:
                            return shared.trimmingWhitespace().string == expectedTrimmedString
                        }
                    }
                }
                for await isConsistent in group {
                    #expect(isConsistent)
                }
            }

            #expect(shared.components == expectedComponents)
        }
    }
}
