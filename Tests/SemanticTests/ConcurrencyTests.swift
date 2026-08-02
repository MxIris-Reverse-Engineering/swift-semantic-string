import Foundation
import Testing
@testable import Semantic

/// Concurrency contract of `SemanticString` and `FrozenSemanticString`.
///
/// `SemanticString` is a `Sendable` value type over a `@unchecked Sendable`
/// storage class, which puts three promises on the implementation:
///
/// 1. Reading a value shared across threads is safe even when its string
///    cache is cold, because the lazy `cachedString` fill — the storage's
///    only shared-mutable state — is serialized by the striped locks.
///    `components` reads the storage array directly and needs no lock.
/// 2. Copying and mutating a shared value is safe and isolated, because
///    `makeUniqueForMutation()` copies the contents first; the copy never
///    touches the cache, so it takes no lock.
/// 3. No lock is ever held while concatenating, so a cold `string` read on
///    two storages sharing a stripe cannot deadlock or serialize their
///    concatenation work.
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

    /// A string built from whole nested `SemanticString`s. On the historical
    /// two-state storage, flattening this shape recursed into the nested
    /// storages — the shape that would deadlock if flattening ever moved
    /// inside the cache lock. On flat storage the nesting is expanded at
    /// append time and reading touches exactly one storage; the fixture is
    /// kept as the smoke-test shape (see the Nested Flattening section note).
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
        let stringCount = CacheLockStripes.count * 2

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
        // The copy path (`makeUniqueForMutation()` →
        // `Storage(copyingContentsOf:)`) copies the contents while other
        // tasks may be filling the shared string cache. Each task must still
        // see only its own suffix, and the shared value must come out
        // untouched.
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
        // `appending(_:)`, `+`, and `+=` all copy first, so a shared value
        // must be unaffected by what any of them produce.
        //
        // Note which overloads these actually reach: `Keyword` is a
        // `PlainAtomicSemanticComponent`, so `appending(Keyword(…))` resolves
        // statically to the plain-leaf overload, and the operands built from
        // `SemanticString` reach the `SemanticString` overload. None of them
        // touches the generic `append(_ component: some SemanticStringComponent)`
        // funnel — that entry point is covered separately by
        // `concurrentAppendingThroughTheGenericFunnelIsIsolated` below.
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

    /// The generic `append(_ component: some SemanticStringComponent)` funnel
    /// — the entry point every `@SemanticStringBuilder` child goes through,
    /// and the one that performs the `as? AtomicComponent` / `as? SemanticString`
    /// casts before falling back to eager flattening. Reaching it requires a
    /// component whose static type is *not* a plain leaf, an `AtomicComponent`,
    /// or a `SemanticString`; a composite does that.
    ///
    /// Added in the seventh round: the suite documented this coverage but did
    /// not have it, and `AGENTS.md` makes a clean ThreadSanitizer run of this
    /// suite the gate for storage and locking changes.
    @Test("Concurrent appends through the generic funnel leave the shared value alone")
    func concurrentAppendingThroughTheGenericFunnelIsIsolated() async {
        let (expectedComponents, expectedString) = expectedComponentsAndString()

        for _ in 0 ..< Self.roundCount {
            let shared = nestedString()

            await withTaskGroup(of: Bool.self) { group in
                for taskIndex in 0 ..< Self.taskCount {
                    group.addTask {
                        // A composite: neither an `AtomicComponent`, nor a
                        // `SemanticString`, nor a plain leaf, so both casts in
                        // the funnel miss and the component is flattened.
                        let composite = Group([
                            SemanticString(Keyword("tail")),
                            SemanticString(Standard("\(taskIndex)")),
                        ])
                        var accumulator = shared
                        accumulator.append(composite)
                        return accumulator.string == expectedString + "tail\(taskIndex)"
                    }
                }
                for await isConsistent in group {
                    #expect(isConsistent)
                }
            }

            #expect(shared.components == expectedComponents)
            #expect(shared.string == expectedString)
        }
    }

    /// The same funnel reached through an unspecialized generic parameter,
    /// where the caller's static type is only `some SemanticStringComponent`.
    /// A leaf that would otherwise resolve statically to the plain-leaf
    /// overload arrives here instead.
    @Test("Concurrent appends through an unspecialized generic leave the shared value alone")
    func concurrentAppendingThroughUnspecializedGenericIsIsolated() async {
        func appendThroughGeneric<Component: SemanticStringComponent>(
            _ component: Component,
            into target: inout SemanticString
        ) {
            target.append(component)
        }

        let (expectedComponents, expectedString) = expectedComponentsAndString()

        for _ in 0 ..< Self.roundCount {
            let shared = nestedString()

            await withTaskGroup(of: Bool.self) { group in
                for taskIndex in 0 ..< Self.taskCount {
                    group.addTask {
                        var accumulator = shared
                        appendThroughGeneric(Keyword("tail\(taskIndex)"), into: &accumulator)
                        return accumulator.string == expectedString + "tail\(taskIndex)"
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
            #expect(shared._storage.elementEndOffsets == nil)
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

    // MARK: - Nested Flattening
    //
    // The flat storage removed the recursive locking path this section once
    // guarded: composites flatten eagerly at append time, so computing
    // `string` touches exactly one storage and takes exactly one stripe —
    // never a nested string's. The stripe-collision search that pinned the
    // old "flatten inside a held stripe" deadlock is gone with it; what
    // remains below are smoke tests over the same nested shapes.

    @Test("Deeply nested composite strings flatten without deadlocking")
    func nestedCompositeStringsFlattenWithoutDeadlock() {
        // The realistic shape — `DeclarationBlock` over `MemberList` over
        // per-member `SemanticString`s — built and rendered many times over,
        // enough values to sweep the whole stripe table.
        for index in 0 ..< (CacheLockStripes.count * 4) {
            let subject = nestedString(index: index)
            #expect(subject.string.contains("Type\(index)"))
        }
    }

    @Test("Concurrent reads of nested strings from both ends never deadlock")
    func concurrentNestedReadsFromBothEndsDoNotDeadlock() async {
        // Tasks render the outer string (whose storage copied the member's
        // atoms at build time) and the inner member concurrently. Each read
        // locks only its own storage's stripe; this covers that independence
        // under real contention.
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
        // `frozen()` fills nothing. It reads the atoms directly for the spans
        // and takes the text from `cachedStringIfPresent()`, concatenating
        // locally when the cache is cold rather than publishing the result —
        // `StorageCacheRegressionTests.frozenDoesNotFillTheSourceCache` pins
        // exactly that. So what races here is concurrent *reading* of shared
        // storage with no fill at all, which is the weaker guarantee and
        // still worth holding: every task must derive an identical snapshot.
        // Freezing concurrently with a cold-cache `string` read is the case
        // that actually races a fill, covered below.
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

    /// Freezing raced against the one fill that actually exists. A cold
    /// `string` read publishes `cachedString` under its stripe; `frozen()`
    /// reads the same field through `cachedStringIfPresent()` and must either
    /// see the published value or compute its own — never a torn one.
    ///
    /// Added in the seventh round, to replace a comment that claimed
    /// `frozen()` raced two cache fills. It fills none, so the test above
    /// raced zero; this one races the real thing.
    @Test("Freezing races a concurrent cold-cache string fill safely")
    func concurrentFreezingRacesTheStringCacheFill() async {
        for _ in 0 ..< Self.roundCount {
            let shared = nestedString()
            let expectedString = nestedString().string
            let expectedFrozen = nestedString().frozen()

            await withTaskGroup(of: Bool.self) { group in
                for taskIndex in 0 ..< Self.taskCount {
                    group.addTask {
                        if taskIndex.isMultiple(of: 2) {
                            // Fills the cache under the stripe lock.
                            return shared.string == expectedString
                        } else {
                            // Reads it without filling; must not tear.
                            let frozen = shared.frozen()
                            return frozen.text == expectedString && frozen == expectedFrozen
                        }
                    }
                }
                for await isConsistent in group {
                    #expect(isConsistent)
                }
            }

            #expect(shared.frozen() == expectedFrozen)
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
