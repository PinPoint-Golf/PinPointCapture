//  Candidate.swift
//  `CORE` §5.12 — one observer's claim that an event occurred at a time it
//  measured, built through `libppcp` so the shapes the model forbids are
//  unreachable.
//
//  ⚠ **Two corrections, in this order, and both are visible on the wire.**
//
//   1. **Time of flight** (8.1d). At 343 m/s the correction is ~2.9 ms per metre,
//      so a device 2 m from the ball lags 5.8 ms — most of a frame at 150 fps.
//      It is subtracted from the raw instant, and `tof_correction` records what
//      was subtracted **and its dispersion** (5.12d, I29): a correction with no
//      sigma is a point estimate of exactly the kind 5.4a refuses for clock
//      offsets, and for the same reason.
//   2. **The canonical instant** (5.12e, I33), applied by the **nominator**
//      because the conversion needs that frame's exposure and a Candidate
//      carries neither a frame reference nor an exposure. For a microphone
//      Source 6.1d fixes `convention: mid`, so the canonical instant *is* the
//      corrected raw instant — and the library still does the arithmetic, so
//      the day a `motion` candidate arrives from a camera Source the conversion
//      is already in the right place.
//
//  ⛔ **No merge, no rewrite, no second conversion.** A consumer must not apply
//  the canonical-instant conversion again (5.12e); the error that would produce
//  is exposure-dependent, which is why it looks like clock bias.
//
//  Spec: `CORE` §5.12, §6.1, §8.1; `MSG` §7.1. Plan D5.

import Foundation
import CPPCP

/// A Candidate, with its `classifier` bytes owned alongside.
///
/// ⚠ `ppcp_candidate.classifier` is a **borrowed** pointer, so the bytes have to
/// outlive every call that reads them. That is why this is not a plain `struct`
/// with a `var value` a caller can pass around: the pointer is bound inside
/// `withValue` and is never valid outside it.
public struct PpcpCandidate: @unchecked Sendable {

    /// The instants and the corrections, read back for a test or a screen.
    public let id: String
    public let peerId: String
    public let sourceId: String
    public let basis: String
    public let timebaseId: String
    /// 5.12e — the **canonical** instant, already converted.
    public let atNs: Int64
    public let confidence: Double
    /// 8.1d — what was subtracted, and how uncertain it was.
    public let tofCorrectionNs: Int64?
    public let tofSigmaNs: Double?
    /// 5.12f — the canonical-instant correction applied, so a consumer can
    /// recover the raw timestamp. Zero for a microphone under 6.1d, and present
    /// rather than omitted so the arithmetic is visible either way.
    public let canonicalCorrectionNs: Int64?
    public let evidenceCaptureId: String?
    public let classification: AcousticClassification?

    private let stored: ppcp_candidate
    private let classifierBytes: [UInt8]

    /// Runs `body` with a fully-formed `ppcp_candidate`. ⚠ The pointer and every
    /// pointer inside it are valid only for the call.
    public func withValue<T>(_ body: (UnsafeMutablePointer<ppcp_candidate>) throws -> T)
        rethrows -> T {
        var value = stored
        guard classifierBytes.isEmpty == false else { return try body(&value) }
        return try classifierBytes.withUnsafeBufferPointer { buffer in
            value.classifier = buffer.baseAddress
            value.classifier_len = buffer.count
            return try body(&value)
        }
    }

    init(stored: ppcp_candidate, classifierBytes: [UInt8],
         classification: AcousticClassification?) {
        self.stored = stored
        self.classifierBytes = classifierBytes
        self.classification = classification
        id = ppcpString(stored.id)
        peerId = ppcpString(stored.peer_id)
        sourceId = ppcpString(stored.source_id)
        basis = ppcpString(stored.basis)
        timebaseId = ppcpString(stored.at.tb)
        atNs = stored.at.ns
        confidence = stored.confidence
        tofCorrectionNs = stored.has_tof_correction ? stored.tof_correction.value_ns : nil
        tofSigmaNs = stored.has_tof_correction ? stored.tof_correction.sigma_ns : nil
        canonicalCorrectionNs = stored.has_canonical_correction
            ? stored.canonical_correction_ns : nil
        evidenceCaptureId = stored.has_evidence_capture_id
            ? ppcpString(stored.evidence_capture_id) : nil
    }
}

// MARK: - Time of flight

/// `CORE` 8.1d / 5.12d — the acoustic correction and its dispersion.
///
/// ⛔ **Both, or neither** (I29). The library's `ppcp_estimate_make` is the only
/// way to obtain the value the setter takes, and it cannot be called with one of
/// the two — so a point estimate with no dispersion is not typeable here either.
public struct AcousticTimeOfFlight: Sendable, Hashable {

    /// ⚠ 343 m/s at 20 °C. It is a **physical** constant and not protocol tuning,
    /// which is why it sits here beside the geometry rather than in `Tuning`.
    public static let speedOfSoundMetresPerSecond = 343.0

    /// Distance from the microphone to the ball, in metres, and its own
    /// uncertainty. `CORE` §5.9: surveyed geometry is tight, an online estimate
    /// is *converging* — wide early in a session, tight late — and the difference
    /// is the whole point of carrying a sigma at all.
    public let distanceMetres: Double
    public let distanceSigmaMetres: Double

    public init(distanceMetres: Double, distanceSigmaMetres: Double) {
        self.distanceMetres = distanceMetres
        self.distanceSigmaMetres = distanceSigmaMetres
    }

    /// Nanoseconds the sound spent in the air — the amount the raw instant lags
    /// the event, and therefore the amount **subtracted** from it.
    public var correctionNs: Int64 {
        Int64((distanceMetres / Self.speedOfSoundMetresPerSecond * 1_000_000_000).rounded())
    }

    public var sigmaNs: Double {
        distanceSigmaMetres / Self.speedOfSoundMetresPerSecond * 1_000_000_000
    }
}

// MARK: - Building one

/// Turns an `AcousticOnset` into a Candidate, through the library.
///
/// ⛔ **I26 is checked by `ppcp_peer_nominate`, not here.** The `source_id` must
/// name a Source *this peer declared*, on a Timebase it declared, with `at`
/// expressed in that timebase — and a record with no peer, no timebase and no
/// clock is not a Candidate at all (8.1b): it is a `shot_link`, and there is no
/// path from this factory to one.
public struct CandidateFactory: Sendable {

    /// `CORE` 5.12 `basis` — an open registry; this device nominates on one.
    public static let acousticBasis = "acoustic"

    private let declaration: PpcpDeclaration
    private let sourceId: String
    /// ⚠ `nil` for a microphone, and that is 6.1d rather than an omission — see
    /// `PpcpDeclaration.withSource`.
    private let profileId: String?
    private let timeOfFlight: AcousticTimeOfFlight?
    private let mintId: @Sendable () -> String

    public init(declaration: PpcpDeclaration,
                sourceId: String,
                profileId: String? = nil,
                timeOfFlight: AcousticTimeOfFlight? = nil,
                mintId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.declaration = declaration
        self.sourceId = sourceId
        self.profileId = profileId
        self.timeOfFlight = timeOfFlight
        self.mintId = mintId
    }

    public enum FactoryError: Error, Sendable, Equatable {
        /// I26 / 5.12a, one step before the library's refusal so the caller gets a
        /// name rather than `PPCP_ERR_INVALID`.
        case undeclaredSource(String)
    }

    /// One Candidate from one onset.
    ///
    /// - Parameter evidenceCaptureId: 5.12.1a — the candidate-anchored Capture on
    ///   the `audio` Stream that holds the window explaining why detection fired.
    ///   ⚠ Named **before** the Capture exists: the reference is the Candidate's,
    ///   and 5.12.1c makes an evicted or never-retained window `absent` with a
    ///   reason rather than a dangling id.
    /// - Parameter exposureNs: ignored for a Source whose profile has no `format`
    ///   (6.1d). It exists because the same factory serves a `motion` candidate
    ///   from a camera Source, where it is mandatory (I17).
    public func candidate(from onset: AcousticOnset,
                          evidenceCaptureId: String?,
                          exposureNs: Int64 = 0) throws -> PpcpCandidate {
        // 8.1d — corrected **before** `at` is emitted. The library then treats
        // `raw_ns` as already corrected and records what was applied.
        let corrected = onset.rawNs - (timeOfFlight?.correctionNs ?? 0)
        let classifierBytes = try Self.encode(onset.classification)
        let id = mintId()

        let built: ppcp_candidate? = try declaration.withSource(
            id: sourceId, profileId: profileId
        ) { source, profile in
            var candidate = ppcp_candidate()
            // ⚠ The Estimate is built and consumed inside one scope. `libppcp`
            // takes it by pointer, and a pointer escaped out of
            // `withUnsafeMutablePointer` is dangling the instant the call
            // returns — the kind of bug that works in testing because the stack
            // slot is usually still there.
            if let timeOfFlight {
                var estimate = ppcp_estimate()
                try check(ppcp_estimate_make(&estimate, timeOfFlight.correctionNs,
                                             timeOfFlight.sigmaNs))
                try check(ppcp_candidate_make_canonical(&candidate, id, source, profile,
                                                        Self.acousticBasis, corrected,
                                                        exposureNs, onset.confidence,
                                                        &estimate))
            } else {
                try check(ppcp_candidate_make_canonical(&candidate, id, source, profile,
                                                        Self.acousticBasis, corrected,
                                                        exposureNs, onset.confidence, nil))
            }
            if let evidenceCaptureId {
                try check(ppcp_candidate_set_evidence(&candidate, evidenceCaptureId))
            }
            try classifierBytes.withUnsafeBufferPointer { buffer in
                try check(ppcp_candidate_set_classifier(&candidate, buffer.baseAddress,
                                                        buffer.count))
                try check(ppcp_candidate_validate(&candidate))
            }
            // ⛔ The classifier pointer dies with the buffer above, so it is
            // cleared rather than carried out as a dangling one. `withValue`
            // re-binds it from `classifierBytes`, which this type owns; a stored
            // struct that *looked* complete would work right up until the array
            // moved.
            candidate.classifier = nil
            candidate.classifier_len = 0
            return candidate
        }
        guard let built else { throw FactoryError.undeclaredSource(sourceId) }

        return PpcpCandidate(stored: built, classifierBytes: classifierBytes,
                             classification: onset.classification)
    }

    /// The `classifier` map, as `ENC` §4 deterministic CBOR.
    ///
    /// ⛔ **Written by `libppcp`'s encoder, key ordering included.** `ENC` 4e's
    /// ordering and 4d's duplicate-key rule are the writer's, and a hand-rolled
    /// map here would be the second encoder `CONF` §2c warns about — in the one
    /// place the protocol explicitly says it will not look inside.
    static func encode(_ classification: AcousticClassification) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 256)
        var length = 0
        try buffer.withUnsafeMutableBufferPointer { out in
            var writer = ppcp_cbor_writer()
            ppcp_cbor_writer_init(&writer, out.baseAddress, out.count)
            // ⚠ **Written in `ENC` 4e's deterministic key order — shorter key
            // first, then bytewise** — because the writer *enforces* it rather
            // than sorting for us: `ppcp_cbor_writer_init` is
            // `PPCP_CBOR_ORDER_DETERMINISTIC`, and a key out of order sets the
            // sticky error. That is the right trade (a duplicate key becomes
            // impossible to emit rather than merely forbidden), and it is worth
            // saying here because writing them in the order a reader finds
            // natural — `transient` first — is what fails.
            _ = ppcp_cbor_write_map(&writer, 4)
            _ = ppcp_cbor_write_text_z(&writer, "rise_ns")
            _ = ppcp_cbor_write_int(&writer, classification.riseNs)
            _ = ppcp_cbor_write_text_z(&writer, "decay_ns")
            _ = ppcp_cbor_write_int(&writer, classification.decayNs)
            _ = ppcp_cbor_write_text_z(&writer, "peak_dbfs")
            _ = ppcp_cbor_write_double(&writer, classification.peakDbfs)
            _ = ppcp_cbor_write_text_z(&writer, "transient")
            _ = ppcp_cbor_write_text_z(&writer, classification.transient.rawValue)
            try check(ppcp_cbor_writer_finish(&writer, &length))
        }
        return Array(buffer[0..<length])
    }
}
