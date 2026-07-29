import Foundation
import Testing
@testable import Semantic

// MARK: - Tests

/// Regression tests for the fourth review round: two `FrozenSemanticString`
/// consistency defects, each written fail-first against the unfixed code.
///
/// Both stem from the same shape — a field the *readers* of the type treat as
/// "unknown/out-of-range → graceful default", but that one other code path
/// treats as raw storage:
///
/// - **Codable round trip is not idempotent.** The unchecked initializer
///   documents that an out-of-range `identifierIndex` resolves to `nil` — a
///   usable value — and the encoder writes it out, but the decoder rejected
///   it, so the type refused its own encoder's output.
/// - **Equality/hashing compared the raw `typeCode`.** `enumerateSpans`,
///   `components`, and rendering all resolve an unknown `typeCode` to `.other`,
///   but `==`/`hash` compared the stored byte, so two snapshots every reader
///   renders identically compared unequal and hashed apart.
@Suite("Fourth review round regressions")
struct FourthReviewRegressionTests {
    // MARK: F1 — Codable round trip accepts what the unchecked init accepts

    @Test("A frozen value with an out-of-range identifier index survives its own Codable round trip")
    func codableRoundTripAcceptsOutOfRangeIdentifierIndex() throws {
        // `init(text:spans:identifierTable:)` documents that an out-of-range
        // `identifierIndex` "resolves to nil", and this value is fully usable:
        // `identifier(at:)` returns nil and `enumerateSpans` walks it fine.
        // The encoder serializes it, so the decoder must accept it — rejecting
        // the encoder's own output makes the round trip non-idempotent.
        let original = FrozenSemanticString(
            text: "abc",
            spans: [.init(length: 3, typeCode: 0, identifierIndex: 5)],
            identifierTable: []
        )
        #expect(original.identifier(at: 5) == nil)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FrozenSemanticString.self, from: encoded)

        #expect(decoded == original)
        #expect(decoded.identifier(at: 5) == nil)
        #expect(decoded.components == original.components)
        // Idempotent to the byte: re-encoding the decoded value reproduces the
        // same payload, so the index is preserved verbatim, exactly as the
        // unchecked init keeps it.
        #expect(try JSONEncoder().encode(decoded) == encoded)
    }

    // MARK: F2 — equality/hashing normalize unknown type codes like every reader

    @Test("Frozen equality and hashing resolve unknown type codes to .other")
    func frozenEqualityNormalizesUnknownTypeCodes() {
        // A payload from a newer encoder can carry a `typeCode` this version
        // does not know; the decoder preserves it (forward compatibility) and
        // every reader resolves it to `.other`. A snapshot carrying that
        // unknown code and one carrying `.other`'s code therefore render
        // byte-identically, so `==`/`hash` must agree too — otherwise a value
        // decoded from a newer payload silently misses `Set`/`Dictionary`
        // lookup against its own rendered-equal twin.
        let unknownCode: UInt8 = 99
        #expect(SemanticType(frozenTypeCode: unknownCode) == nil, "precondition: 99 is not an assigned code")

        let fromFutureEncoder = FrozenSemanticString(
            text: "x",
            spans: [.init(length: 1, typeCode: unknownCode, identifierIndex: 0)],
            identifierTable: []
        )
        let asOther = FrozenSemanticString(
            text: "x",
            spans: [.init(length: 1, typeCode: SemanticType.other.frozenTypeCode, identifierIndex: 0)],
            identifierTable: []
        )

        // Every reader renders them identically.
        #expect(fromFutureEncoder.string == asOther.string)
        #expect(fromFutureEncoder.components == asOther.components)

        // So equality and hashing must too.
        #expect(fromFutureEncoder == asOther)
        #expect(fromFutureEncoder.hashValue == asOther.hashValue)
        #expect(Set([fromFutureEncoder]).contains(asOther))
    }
}
