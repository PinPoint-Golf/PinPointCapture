//  DevicePeer.swift
//  The device as a PPCP peer: the clock the library reads, the health it reports,
//  and the sans-I/O engine that turns both into messages.
//
//  ⚠ **The engine owns no socket, no thread, no timer and no clock** (`peer.h`).
//  This file is the embedding: it pushes bytes in with `ppcp_peer_feed`, pulls
//  frames out with `ppcp_peer_drain`, and reads what happened with
//  `ppcp_peer_next_event`. Every message it originates goes through a library
//  entry point that checks C2 first — a peer cannot originate a message its
//  declared profiles do not confer, so the wire never carries the violation.
//
//  ⛔ **Nothing here re-implements a rule the library holds.** Version selection,
//  channel checking, the profile boundary, the transfer table and `link_bind`
//  ordering are all `libppcp`'s; this file allocates the engine's storage, keeps
//  the C strings alive, and translates result codes into Swift errors.
//
//  ⚠ `ppcp_peer_sizeof()` is about 460 KB and the caller owns it (ground rule 7:
//  the library allocates nothing). It is heap storage held by this object, freed
//  in `deinit`, and it is emphatically not a stack value.
//
//  Spec: `CORE` §5.15 (Readiness), §6.4, §7.4b; `MSG` §3–§5, §8; `ENC` §2.1.
//  Plan D2.

import Foundation
import CPPCP

// MARK: - The clock the library reads

/// `CORE` I1, one layer above the wire: "the library never asks 'what time is
/// it' without saying which clock it means."
///
/// ⚠ **The library owns no clock** (plan ground rule 7) and this is how it gets
/// one. A `ppcp_clock` is a C function pointer and a context pointer, so the
/// Swift closure has to be kept alive by something — this class — for as long as
/// the library holds the interface. ⛔ A `ppcp_clock` built from a temporary
/// would be a dangling context pointer the moment the expression ended, and it
/// would work in testing, because the memory is usually still there.
public final class PpcpDeviceClock: @unchecked Sendable {

    /// Reads the named timebase, or `nil` where the peer does not declare it.
    public typealias Reader = @Sendable (String) -> Int64?

    private let reader: Reader

    public init(_ reader: @escaping Reader) {
        self.reader = reader
    }

    /// The C interface. ⚠ Valid only while this object is alive.
    public var interface: ppcp_clock {
        ppcp_clock(now: { ctx, timebaseId, out in
            guard let ctx, let timebaseId, let out else { return PPCP_ERR_INVALID }
            let clock = Unmanaged<PpcpDeviceClock>.fromOpaque(ctx).takeUnretainedValue()
            guard let value = clock.reader(String(cString: timebaseId)) else {
                // ⚠ `NOT_FOUND` rather than `INVALID`: a timebase this peer does
                // not declare is a caller's mistake about *which clock*, not a
                // malformed argument, and 5.3a's rule ("a peer declares every
                // Timebase any of its Sources references") is what it violates.
                return PPCP_ERR_NOT_FOUND
            }
            out.pointee = value
            return PPCP_OK
        }, ctx: Unmanaged.passUnretained(self).toOpaque())
    }

    /// Read one clock as an `Instant` — through the library, so the `tb` comes
    /// back attached (I1) rather than being reattached by the caller.
    public func instant(_ timebaseId: String) throws -> (tb: String, ns: Int64) {
        var interface = self.interface
        var instant = ppcp_instant()
        try check(ppcp_clock_read(&interface, timebaseId, &instant))
        var id = instant.tb
        let tb = withUnsafeBytes(of: &id.v) { raw in
            String(decoding: raw.prefix(Int(id.len)), as: UTF8.self)
        }
        return (tb, instant.ns)
    }
}

// MARK: - Health

/// What `heartbeat_ack` carries (`CORE` 7.4b): "the peer's current
/// `ThermalLevel`, free storage and battery state, so a host reports degradation
/// rather than silently accepting worse data."
///
/// ⚠ Gathered by the platform layer and passed as a value. `ProcessInfo`,
/// `URLResourceValues` and `UIDevice` stay behind `Sources/Platform`
/// (REQ-PORT-3); what crosses is three numbers and an ordinal.
public struct DeviceHealth: Sendable, Hashable {
    public var thermal: ThermalState
    public var storageFreeBytes: UInt64
    /// `nil` where the platform will not say — battery reporting is opt-in on
    /// iOS and simply absent on a simulator. ⛔ Absence means "not known", never
    /// 100 (`CORE` 5.1: "absence never means zero").
    public var batteryPercent: Int?
    /// `MSG` 5.4 — optional beside `battery_pct`, and `nil` for the same reason:
    /// a simulator has no battery to be charging.
    public var isCharging: Bool?

    public init(thermal: ThermalState, storageFreeBytes: UInt64,
                batteryPercent: Int? = nil, isCharging: Bool? = nil) {
        self.thermal = thermal
        self.storageFreeBytes = storageFreeBytes
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
    }

    /// `CORE` §5.8 — the ordinal protocol spelling, not the platform's.
    public var ppcpThermalLevel: String { thermal.ppcpLevel }
}

public extension ThermalState {

    /// `CORE` §5.8 — "an ordinal protocol vocabulary, not a platform passthrough".
    ///
    /// ⚠ The mapping is **this application's**, and the one non-obvious row is
    /// `fair → elevated`: `ProcessInfo.ThermalState` has four values and so does
    /// the protocol, but they are not the same four words, and a peer that passed
    /// `"fair"` through would be inventing a fifth level.
    var ppcpThermalLevel: ppcp_thermal_level {
        switch self {
        case .nominal: PPCP_THERMAL_NOMINAL
        case .fair: PPCP_THERMAL_ELEVATED
        case .serious: PPCP_THERMAL_SERIOUS
        case .critical: PPCP_THERMAL_CRITICAL
        }
    }
}

/// `CORE` §5.15 — "readiness as a measurement; no state name crosses the wire"
/// (5.15a). Built through `libppcp`, so the shapes it forbids are unreachable.
///
/// ⚠ **`Readiness` is not `CaptureState`.** The application has a state machine
/// with names in it — `cold`, `warm`, `armed` — and none of those names is
/// allowed on the wire. What crosses is whether the device has *settled*, how
/// long until it will, and what is blocking it if anything. D4 owns the
/// measurement; this is the encoding of it.
public enum PpcpReadiness {

    /// The device is settled and would capture now.
    public static func settled(blockedBy reason: String? = nil) throws -> ppcp_readiness {
        var readiness = ppcp_readiness()
        try check(ppcp_readiness_settled(&readiness))
        if let reason { try check(ppcp_readiness_set_blocked(&readiness, reason)) }
        try check(ppcp_readiness_validate(&readiness))
        return readiness
    }

    /// Not settled, with the peer's own estimate of how long it needs.
    public static func notSettled(readyInMilliseconds: UInt32,
                                  blockedBy reason: String? = nil) throws -> ppcp_readiness {
        var readiness = ppcp_readiness()
        try check(ppcp_readiness_not_settled(&readiness, readyInMilliseconds))
        if let reason { try check(ppcp_readiness_set_blocked(&readiness, reason)) }
        try check(ppcp_readiness_validate(&readiness))
        return readiness
    }

    /// `CORE` 5.14g1 / REQ-OFF-2 — "refuse to arm under storage pressure rather
    /// than shed". ⛔ The *threshold* is not here and must not be: I14 and 5.7d
    /// keep every threshold out of the protocol, and this application's own floor
    /// belongs beside its storage estimate, not beside its encoder.
    public static let blockedStorageFull = "storage_full"
    public static let blockedThermalLimit = "thermal_limit"
}

// MARK: - C string storage

/// Keeps a `[String]` alive as a NULL-terminated-free `char *` array for as long
/// as the library holds the pointer.
///
/// ⚠ **The reason this type exists rather than a `withArrayOfCStrings` closure.**
/// `ppcp_peer_config.profiles` is read by `ppcp_peer_new` *and* stored: the
/// engine consults the declared profile list on every origination, to answer C2.
/// A closure-scoped array would be a dangling pointer the moment `init` returned,
/// and it would work in testing because the memory is usually still there.
final class CStringArray {
    private let storage: [UnsafeMutablePointer<CChar>]
    private let pointers: UnsafeMutableBufferPointer<UnsafePointer<CChar>?>

    var count: Int { storage.count }
    var base: UnsafePointer<UnsafePointer<CChar>?> { UnsafePointer(pointers.baseAddress!) }

    init(_ values: [String]) {
        storage = values.map { strdup($0)! }
        pointers = .allocate(capacity: max(values.count, 1))
        for (index, pointer) in storage.enumerated() {
            pointers[index] = UnsafePointer(pointer)
        }
    }

    deinit {
        storage.forEach { free($0) }
        pointers.deallocate()
    }
}

// MARK: - Records the peer originates

/// `CORE` §5.10 — the Session this peer opens.
///
/// ⛔ **Hostless only, and that is structural rather than a limitation.** 5.10e
/// makes the two arbitration parameters present if and only if a host is in the
/// roster, and `ppcp_session_make_hostless` cannot be given them — there is no
/// setter. A device recording its own bundle is `CORE` 4.1b's case: it records a
/// `session_open` with no arbitration, and that absence *is* the statement that
/// no arbitration occurred (7.3b).
public struct PpcpSessionRecord: Sendable, Hashable {

    public var id: String
    /// ⛔ I16 — immutable once set. There is no `ppcp_session_set_timebase_ref`.
    public var timebaseRef: String
    /// `CORE` 6.5b — `Session.epoch` is a wall-clock **label** beside an instant
    /// in a timebase that measures (I15). Both or neither.
    public var epochWallUtcNs: Int64?
    public var epochAtNs: Int64?
    public var epochTimebaseId: String?

    public init(id: String, timebaseRef: String,
                epochWallUtcNs: Int64? = nil,
                epochAtNs: Int64? = nil,
                epochTimebaseId: String? = nil) {
        self.id = id
        self.timebaseRef = timebaseRef
        self.epochWallUtcNs = epochWallUtcNs
        self.epochAtNs = epochAtNs
        self.epochTimebaseId = epochTimebaseId
    }

    /// The Session **a host opened**, as this device records it in its own bundle.
    ///
    /// ⛔ **The two arbitration parameters are deliberately dropped, and cannot be
    /// carried.** `ppcp_peer_session_open` refuses `has_arbitration` from any peer
    /// that is not `role: host` (`libppcp/src/ppcp_peer.c:1015`) — 5.10e and 7.3a
    /// made structural — and `ENC` 7a/7b make a bundle the *owner's outbound*
    /// frames, so the only `session_open` this device could ever have sent is a
    /// hostless one. What crosses into the bundle is the host's `Session.id` and
    /// its `timebase_ref`, which is what every Stream, Capture and Shot in the
    /// file has to agree with.
    ///
    /// ⚠ **Known consequence, raised rather than hidden:**
    /// `SessionBundleWriter.isHostless` then reads `true` for a Session a host
    /// arbitrated. Arbitration is still recoverable from the file — the Shots
    /// inside it carry `authority: host` — but the flag's name is wider than its
    /// meaning. Either it means "this peer did not arbitrate", or `ENC` §7 needs
    /// a way to record a Session a peer participated in without opening.
    ///
    /// ⚠ The epoch is **not** taken from `session_open` either. The host's epoch
    /// instant is on the host's clock, and this device's own `WallClockAnchor` is
    /// the only label it can honestly put beside a local instant.
    public init(_ parameters: PpcpSessionParameters,
                epochWallUtcNs: Int64? = nil,
                epochAtNs: Int64? = nil,
                epochTimebaseId: String? = nil) {
        self.init(id: parameters.sessionId,
                  timebaseRef: parameters.timebaseRefId,
                  epochWallUtcNs: epochWallUtcNs,
                  epochAtNs: epochAtNs,
                  epochTimebaseId: epochTimebaseId)
    }
}

/// `CORE` §5.11 — one Stream this peer owns.
public struct PpcpStreamRecord: Sendable, Hashable {

    /// `CORE` 5.11 `continuity`.
    public enum Continuity: Sendable, Hashable { case continuous, shotWindowed }

    public var id: String
    public var sessionId: String
    public var sourceId: String
    /// Open registry (10.3): `video`, `preview`, `audio`, `imu`, …
    public var kind: String
    public var profileId: String
    public var timebaseId: String
    public var continuity: Continuity
    public var openedAtNs: Int64

    public init(id: String, sessionId: String, sourceId: String, kind: String,
                profileId: String, timebaseId: String,
                continuity: Continuity, openedAtNs: Int64) {
        self.id = id
        self.sessionId = sessionId
        self.sourceId = sourceId
        self.kind = kind
        self.profileId = profileId
        self.timebaseId = timebaseId
        self.continuity = continuity
        self.openedAtNs = openedAtNs
    }
}

/// `CORE` §5.14 — one Capture.
///
/// ⚠ **`anchor` is exactly one of three things** (I27). The library has three
/// constructors and one tagged union, so zero keys and two keys are both
/// unrepresentable; this enum is the same shape one layer up.
public enum PpcpCaptureAnchor: Sendable, Hashable {
    case shot(String)
    case candidate(String)
    /// A segment of the Capture's own continuous Stream. ⛔ Its interval is
    /// mandatory (5.14d): for a segment the interval *is* the claim.
    case segment(startNs: Int64, endNs: Int64)
}

/// `CORE` 5.14 `transfer` — the **owner's** view of where the payload is.
///
/// ⛔ **`confirmed` is deliberately not a case here.** 5.14f/8.4b: only the
/// *receiver* can say it holds the payload durably, and it says so with a
/// `capture_committed`. The library agrees structurally —
/// `ppcp_capture_set_transfer` refuses `PPCP_TRANSFER_CONFIRMED` and the only
/// route to it is `ppcp_transfer_on_committed`, which needs a message that
/// arrived. An owner that could type `.confirmed` here would be marking its own
/// homework.
public enum PpcpTransferState: Sendable, Hashable {
    /// Held locally, unsent.
    case pending
    case inFlight
    case present
    case failed

    var cValue: ppcp_transfer_state {
        switch self {
        case .pending: PPCP_TRANSFER_PENDING
        case .inFlight: PPCP_TRANSFER_IN_FLIGHT
        case .present: PPCP_TRANSFER_PRESENT
        case .failed: PPCP_TRANSFER_FAILED
        }
    }
}

public struct PpcpCaptureRecord: Sendable, Hashable {

    /// `CORE` 5.14 / I10 — asserted by the owner, never inferred.
    public enum Completeness: Sendable, Hashable { case complete, partial, absent }

    public var id: String
    public var anchor: PpcpCaptureAnchor
    public var streamId: String
    public var timebaseId: String
    public var completeness: Completeness
    /// Present on a shot- or candidate-anchored Capture; mandatory on a segment,
    /// where it is carried by the anchor instead.
    ///
    /// ⚠ **Half-open `[start, end)`** (`CORE` §5.1). It was a `ClosedRange` until
    /// D4 and that was wrong in a way nothing had yet noticed: two abutting
    /// segments would have shared their boundary instant, which 5.14e forbids
    /// outright — "segments abut or leave a declared gap; they do not overlap".
    public var intervalNs: Range<Int64>?
    /// ⛔ 5.14 — mandatory when `completeness == .absent`, and an open registry.
    public var absentReason: String?
    /// `CORE` 5.14 `gaps` — data **lost** inside a segment that otherwise exists.
    ///
    /// ⛔ I11: meaningful only on a `continuous` Stream, and never the way to
    /// record deliberate non-retention (5.11c3). The library refuses gaps on a
    /// `shot_windowed` Stream, so a shot-anchored clip's holes make it `partial`
    /// and are reported no other way.
    public var gapsNs: [Range<Int64>]
    /// `CORE` §5.8 — rides on `capture_announce`, on the control channel.
    /// ⛔ The per-frame series does **not** (I30); it has nowhere to go on this
    /// type, because `ppcp_capture` has no member for it.
    public var achievedSummary: PpcpAchievedSummary?
    public var transfer: PpcpTransferState
    public var digest: Data?
    public var bytes: UInt64?

    public init(id: String, anchor: PpcpCaptureAnchor, streamId: String,
                timebaseId: String, completeness: Completeness,
                intervalNs: Range<Int64>? = nil,
                absentReason: String? = nil,
                gapsNs: [Range<Int64>] = [],
                achievedSummary: PpcpAchievedSummary? = nil,
                transfer: PpcpTransferState = .pending,
                digest: Data? = nil, bytes: UInt64? = nil) {
        self.id = id
        self.anchor = anchor
        self.streamId = streamId
        self.timebaseId = timebaseId
        self.completeness = completeness
        self.intervalNs = intervalNs
        self.absentReason = absentReason
        self.gapsNs = gapsNs
        self.achievedSummary = achievedSummary
        self.transfer = transfer
        self.digest = digest
        self.bytes = bytes
    }
}

// MARK: - The engine

/// The device peer: `role: capture`, the profile set of `CORE` §2.2.3, the
/// declaration of D2, and the callbacks above.
///
/// ⚠ **One engine serves both ends** (`CORE` A.3, `peer.h`). The same object is
/// a dialler on a live link and the frame source for a bundle; what differs is
/// whether anything is fed into it and where the drained frames go. That is what
/// makes "live bytes are bundle bytes" a fact rather than a claim, and it is why
/// `SessionBundleWriter` holds one of these rather than a second encoder.
public final class DevicePeer: @unchecked Sendable {

    /// `ENC` §8 — 1 MiB on control, 8 MiB on bulk. The drain buffer is sized to
    /// the control limit, so a whole frame always fits and `PPCP_ERR_NOSPACE`
    /// means a bug rather than a large frame.
    private static let drainCapacity = 1 << 20

    private let storage: UnsafeMutableRawPointer
    private let storageBytes: Int
    private let clock: PpcpDeviceClock?
    private let profileStrings: CStringArray
    private let peerIdString: UnsafeMutablePointer<CChar>
    private let health: (@Sendable () -> DeviceHealth)?
    private let ingest: (@Sendable (String) -> String?)?
    /// Kept alive because `ppcp_peer_config.sync_timebase` is a borrowed `char *`
    /// the engine reads on every `sync_probe` that arrives, not only at `new`.
    private let syncTimebaseString: UnsafeMutablePointer<CChar>?

    private var peer: OpaquePointer?

    /// The declaration this peer last sent, held because `ppcp_peer_desc`'s
    /// nested lists are borrowed pointers into it (ground rule 7).
    private var declaration: PpcpDeclaration?

    /// Events moved out of the engine's four-deep ring before it can overflow
    /// (F-L13-1). See `feed(_:on:)`.
    private var events: [HeldEvent] = []

    /// - Parameters:
    ///   - ingestPolicy: `MSG` 3.4 / I14 — the embedding's acceptance decision
    ///     for a counterpart's declaration. Given the counterpart's `Peer.id`,
    ///     it returns `nil` to accept or a machine-readable reason to reject.
    ///     ⛔ There is no threshold in the library and there is none here: this
    ///     application accepts every declaration, because a *capture* peer has no
    ///     ingest floor to apply — PinPointStudio's 120 fps floor is
    ///     PinPointStudio's (plan H2, CT-I14).
    ///   - syncTimebase: `CORE` 6.1b — the timebase this peer stamps `t2`/`t3` on
    ///     when it **answers** a `sync_probe`: whichever clock its network stack
    ///     timestamps with. ⛔ `nil` means this peer does not answer probes, and
    ///     one arriving is answered `error`/`profile_not_supported` rather than
    ///     with a fabricated instant. On iOS the answer is always `tb:hosttime`,
    ///     because that is the only clock `Network.framework` exposes.
    public init(peerId: String,
                profiles: [String] = PpcpProfileSet.device,
                role: Role = .capture,
                listener: Bool = false,
                clock: PpcpDeviceClock? = nil,
                health: (@Sendable () -> DeviceHealth)? = nil,
                syncTimebase: String? = nil,
                ingestPolicy: (@Sendable (String) -> String?)? = nil) throws {
        storageBytes = ppcp_peer_sizeof()
        storage = .allocate(byteCount: storageBytes,
                            alignment: MemoryLayout<UInt64>.alignment)
        profileStrings = CStringArray(profiles)
        peerIdString = strdup(peerId)!
        syncTimebaseString = syncTimebase.map { strdup($0)! }
        self.clock = clock
        self.health = health
        self.ingest = ingestPolicy

        var config = ppcp_peer_config()
        config.role = role.c
        config.peer_id = UnsafePointer(peerIdString)
        config.profiles = profileStrings.base
        config.profile_count = profileStrings.count
        // ⛔ `versions` left NULL: `peer.h` says that defaults to the one wire
        // version this library speaks, and a list written down here would be a
        // second place for it to be wrong. `min_version` likewise.
        config.listener = listener
        if let clock { config.clock = clock.interface }
        config.ctx = Unmanaged.passUnretained(self).toOpaque()
        config.ingest_policy = { ctx, counterpart, reason in
            guard let ctx, let counterpart else { return false }
            let peer = Unmanaged<DevicePeer>.fromOpaque(ctx).takeUnretainedValue()
            guard let policy = peer.ingest else { return true }
            var id = counterpart.pointee.id
            let name = withUnsafeBytes(of: &id.v) { raw in
                String(decoding: raw.prefix(Int(id.len)), as: UTF8.self)
            }
            guard let refusal = policy(name) else { return true }
            // 3.4a — a rejection is machine-readable and does NOT close the
            // connection.
            if let reason { _ = ppcp_id_set_z(reason, refusal) }
            return false
        }
        config.health = { ctx, out in
            guard let ctx, let out else { return PPCP_ERR_INVALID }
            let peer = Unmanaged<DevicePeer>.fromOpaque(ctx).takeUnretainedValue()
            guard let report = peer.health else { return PPCP_ERR_NOT_FOUND }
            let state = report()
            // 5.15a — no device state name crosses the wire, so what a health
            // callback answers is a measurement: settled, and what blocks it.
            var readiness = ppcp_readiness()
            var rc = ppcp_readiness_settled(&readiness)
            if rc != PPCP_OK { return rc }
            if state.thermal >= .serious {
                rc = ppcp_readiness_set_blocked(&readiness,
                                                PpcpReadiness.blockedThermalLimit)
                if rc != PPCP_OK { return rc }
            }
            out.pointee = readiness
            return PPCP_OK
        }
        // `MSG` 5.4 / `CORE` 7.4b — what `heartbeat_ack` carries. ⚠ A **second**
        // callback beside `health`, and the split is the library's: `health`
        // answers `arm` with a Readiness *measurement* (5.15a), and this answers
        // a heartbeat with thermal, storage and battery. The two are different
        // questions and D2 conflated them because there was only one field.
        config.health_report = { ctx, out in
            guard let ctx, let out else { return PPCP_ERR_INVALID }
            let peer = Unmanaged<DevicePeer>.fromOpaque(ctx).takeUnretainedValue()
            guard let report = peer.health else { return PPCP_ERR_NOT_FOUND }
            let state = report()
            var health = ppcp_health()
            health.thermal = state.thermal.ppcpThermalLevel
            health.storage_free_bytes = state.storageFreeBytes
            // ⛔ `CORE` 5.1 — absence never means zero. A simulator reports no
            // battery at all, and `has_battery_pct: false` is the honest answer;
            // writing 100 would be a reading nobody took.
            if let percent = state.batteryPercent {
                health.has_battery_pct = true
                health.battery_pct = UInt32(max(0, min(100, percent)))
            }
            if let charging = state.isCharging {
                health.has_charging = true
                health.charging = charging
            }
            out.pointee = health
            return PPCP_OK
        }
        if let syncTimebaseString { config.sync_timebase = UnsafePointer(syncTimebaseString) }

        var handle: OpaquePointer?
        do {
            try check(ppcp_peer_new(storage, storageBytes, &config, &handle))
        } catch {
            // ⛔ **Nothing is deallocated here, and that is the fix for a double
            // free.** A class initialiser that throws AFTER every stored property
            // has a value still runs `deinit` — so a `catch` that released the
            // storage and a `deinit` that released it again freed the same pointer
            // twice, which libmalloc aborts on. Found by SIGABRT in the one test
            // that exercises a refused construction (`libppcp` refuses a Mint
            // engine on a peer that has not declared Mint, 8.3d).
            throw error
        }
        peer = handle
    }

    deinit {
        if let peer { ppcp_peer_free(peer) }
        storage.deallocate()
        free(peerIdString)
        if let syncTimebaseString { free(syncTimebaseString) }
    }

    /// `CORE` 5.2a — fixed for the Session's lifetime.
    public enum Role: Sendable, Hashable {
        case host, capture, observer
        var c: ppcp_role {
            switch self {
            case .host: PPCP_ROLE_HOST
            case .capture: PPCP_ROLE_CAPTURE
            case .observer: PPCP_ROLE_OBSERVER
            }
        }
    }

    private func handle() throws -> OpaquePointer {
        guard let peer else { throw PpcpLibraryError(PPCP_ERR_INVALID) }
        return peer
    }

    /// ⚠ For `DevicePeerLive` and the other files in this module that extend the
    /// peer. Deliberately not `public`: nothing outside `CaptureCore` gets a raw
    /// pointer to the engine, which is what keeps every rule the engine holds
    /// unreachable from the app layer.
    var peerHandle: OpaquePointer? { peer }

    // MARK: State

    public var state: ppcp_peer_state { peer.map(ppcp_peer_get_state) ?? PPCP_PEER_CLOSED }

    /// The agreed wire version, or `nil` before `hello_accept`.
    public var negotiatedVersion: String? {
        guard let peer, let text = ppcp_peer_version(peer) else { return nil }
        return String(cString: text)
    }

    public func declares(_ profile: String) -> Bool {
        guard let peer else { return false }
        return ppcp_peer_declares(peer, profile)
    }

    // MARK: ENC §2.1 — the dialler half

    /// `ENC` 2.1a — 16 bytes from a CSPRNG, minted by the **embedding**: the
    /// library has no random source (ground rule 8).
    public func setLinkId(_ linkId: PpcpLinkId) throws {
        var bytes = [UInt8](linkId.bytes)
        try check(ppcp_peer_set_link_id(try handle(), &bytes))
    }

    /// Queues `link_bind` as the first frame on `channel` (2.1d). ⚠ Channel 0's
    /// must precede its `hello`, and `ppcp_peer_hello()` emits it itself — so a
    /// dialler calls this for the *bulk* channels only.
    public func openChannel(_ channel: PpcpChannel) throws {
        try check(ppcp_peer_open_channel(try handle(), channel.rawValue))
    }

    // MARK: Origination

    public func hello() throws { try check(ppcp_peer_hello(try handle())) }

    /// `MSG` 3.3a — a complete snapshot, never a delta. ⚠ The declaration is
    /// retained: `ppcp_peer_desc`'s Sources and profiles are borrowed pointers
    /// into its storage and the engine reads them while queueing the frame.
    public func declare(_ declaration: PpcpDeclaration) throws {
        let peer = try handle()
        try declaration.withPeerDesc { try check(ppcp_peer_declare(peer, $0)) }
        self.declaration = declaration
    }

    /// `CORE` 4.1b — the hostless `session_open` a capture peer records in its
    /// own bundle.
    ///
    /// ⛔ **Hostless is the only shape available here, and not by choice.**
    /// `ppcp_session_make_hosted` exists (`model.h:465`) but
    /// `ppcp_peer_session_open` refuses `has_arbitration` from a peer that is not
    /// `role: host` (`src/ppcp_peer.c:1015`). A capture device therefore never
    /// originates a hosted `session_open`, on the wire or into a file, and
    /// `PpcpSessionRecord.init(_ parameters:)` documents what that costs when a
    /// host is holding the Session.
    public func openSession(_ record: PpcpSessionRecord) throws {
        var session = ppcp_session()
        try check(ppcp_session_make_hostless(&session, record.id, record.timebaseRef))
        if let wall = record.epochWallUtcNs, let atNs = record.epochAtNs,
           let tb = record.epochTimebaseId {
            var at = ppcp_instant()
            try check(ppcp_instant_make_z(&at, tb, atNs))
            try check(ppcp_session_set_epoch(&session, wall, &at))
        }
        try check(ppcp_peer_session_open(try handle(), &session))
    }

    public func openStream(_ record: PpcpStreamRecord) throws {
        var stream = ppcp_stream()
        var openedAt = ppcp_instant()
        try check(ppcp_instant_make_z(&openedAt, record.timebaseId, record.openedAtNs))
        try check(ppcp_stream_make(&stream, record.id, record.sessionId, record.sourceId,
                                   record.kind, record.profileId, record.timebaseId,
                                   record.continuity == .continuous
                                       ? PPCP_CONTINUOUS : PPCP_SHOT_WINDOWED,
                                   &openedAt))
        try check(ppcp_peer_stream_open(try handle(), &stream))
    }

    /// `CORE` 5.2a / 7.3c — emitted in response to `arm` and whenever `settled`
    /// changes. ⚠ Conferred by **Capture**, not Live, which is why a hostless
    /// peer records it in a bundle nobody armed (7.3b).
    public func reportReadiness(_ readiness: ppcp_readiness, streamIds: [String] = []) throws {
        var readiness = readiness
        let ids = try Self.ids(streamIds)
        try ids.withUnsafeBufferPointer { buffer in
            try check(ppcp_peer_readiness(try handle(), &readiness,
                                          buffer.baseAddress, buffer.count))
        }
    }

    /// `MSG` §8.1 — `capture_announce`, on the control channel.
    ///
    /// - Parameter isPreview: 5.11j / 8.1i. The engine refuses a preview Capture
    ///   announced `transfer: pending` here rather than noticing it later, which
    ///   is CT-I36a's second assertion held by the library.
    ///
    /// ⛔ There is no `achievedFrames` parameter and there cannot be one: I30
    /// puts the per-frame series on the payload, and `ppcp_capture` has no member
    /// to carry it. See `payloadBegin`.
    public func announce(_ record: PpcpCaptureRecord, isPreview: Bool = false) throws {
        let peer = try handle()
        try Self.withCapture(record) { capture in
            try check(ppcp_peer_capture_announce(peer, capture, isPreview, nil, nil, 0))
        }
    }

    /// `CORE` 7.3d — "a capture peer reports and recovers from platform
    /// interruptions … with the resulting gap recorded explicitly".
    ///
    /// ⚠ `kind` is an open registry: `call`, `background`, `audio_session`. The
    /// interval is the gap itself, in the Stream's timebase, and `recovered` says
    /// whether the peer got back to where it was.
    public func interruption(kind: String, timebaseId: String, intervalNs: Range<Int64>,
                             recovered: Bool, streamIds: [String] = []) throws {
        var interval = ppcp_interval()
        try check(ppcp_interval_make(&interval, timebaseId, timebaseId.utf8.count,
                                     intervalNs.lowerBound, intervalNs.upperBound))
        let ids = try Self.ids(streamIds)
        let peer = try handle()
        try ids.withUnsafeBufferPointer { buffer in
            try check(ppcp_peer_interruption(peer, kind, &interval, recovered,
                                             buffer.baseAddress, buffer.count))
        }
    }

    /// `MSG` §10 — answer an `error`. A fatal code closes the engine after the
    /// frame is queued (10b), which is the library's decision and not this
    /// file's.
    public func sendError(_ code: String, message: String,
                          channel: PpcpChannel = .control,
                          inReplyTo: UInt64? = nil) throws {
        try check(ppcp_peer_error(try handle(), channel.rawValue, code, message,
                                  inReplyTo != nil, inReplyTo ?? 0))
    }

    /// `MSG` 5.1 — the owner's verdict on a Stream a counterpart asked for.
    ///
    /// ⛔ **Answering is a MUST** (erratum E18, clause 1c): a peer receiving a
    /// Request answers it, `stream_open_ack` or `error`, never silence. And the
    /// verdict is the **owner's** — `stream_open` is `any → owner`, so a host
    /// naming a `profile_id` is asking, not telling.
    ///
    /// - Parameter openedAtNs: the owner's own reading, on the Stream's own
    ///   timebase. ⛔ Present only on `opened`. I1 — a requester proposing an
    ///   origin cannot stamp a clock it does not hold, which is exactly why the
    ///   answer carries this and the request's proposal does not survive.
    /// - Parameter reason: present only on `refused`, from the open vocabulary
    ///   `Readiness.blocked_reason` shares (5.11a1).
    public func streamOpenAck(streamId: String,
                              opened: Bool,
                              reason: String? = nil,
                              openedAtNs: Int64? = nil,
                              timebaseId: String? = nil,
                              inReplyTo: UInt64,
                              channel: PpcpChannel = .control) throws {
        var message = ppcp_msg()
        // ⚠ `msg_id` is the engine's to assign (`ENC` 5c); the correlation that
        // matters is `reply_to`, which `MSG` 1a makes how a Response is matched
        // to the Request it answers.
        try check(ppcp_msg_init(&message, PPCP_MT_STREAM_OPEN_ACK, 0))
        try check(ppcp_msg_set_reply_to(&message, inReplyTo))
        try check(ppcp_id_set_z(&message.body.stream_open_ack.stream_id, streamId))
        message.body.stream_open_ack.verdict = opened ? PPCP_STREAM_OPENED
                                                      : PPCP_STREAM_REFUSED
        if let reason, opened == false {
            message.body.stream_open_ack.has_reason = true
            try check(ppcp_id_set_z(&message.body.stream_open_ack.reason, reason))
        }
        if opened, let openedAtNs, let timebaseId {
            var at = ppcp_instant()
            try check(ppcp_instant_make_z(&at, timebaseId, openedAtNs))
            message.body.stream_open_ack.has_opened_at = true
            message.body.stream_open_ack.opened_at = at
        }
        try send(&message, on: channel)
    }

    /// The general form, and what every function above is built on: queue one
    /// message on one channel. ⚠ Still C2-checked and still channel-checked by
    /// the library, so it is the route for messages that have no dedicated entry
    /// point — `session_manifest` — and not a way past the rules. `msg_id` is
    /// assigned by the engine (`ENC` 5c).
    public func send(_ message: UnsafeMutablePointer<ppcp_msg>, on channel: PpcpChannel) throws {
        try check(ppcp_peer_send(try handle(), channel.rawValue, message))
    }

    /// `ENC` §6 — the payload family, on a bulk channel.
    /// - Parameter achievedFrames: `CORE` 5.8 / 8.3g — a camera Capture carries
    ///   it here and **only** here (I30). ⛔ 5.8d makes it a MUST on any camera
    ///   Capture that has frames: without the per-frame exposure durations the
    ///   canonical-instant conversion of §6.1 is impossible (I17), and a consumer
    ///   that falls back to the profile's exposure *range* fails CT-S1
    ///   assertion 3.
    /// - Parameter container: `ENC` 6g / `MSG` 8.3h (erratum E7) — the IANA media
    ///   type of the bytes, REQUIRED whenever they are a container-framed file.
    ///   ⛔ **A receiver may not infer one** from `format.codec`, from
    ///   `Stream.kind`, or by sniffing (6h), and the reason is that it cannot:
    ///   H.264 is QuickTime, fragmented MP4 and Annex B, and those are three
    ///   different files. `nil` is for raw samples the Stream's profile describes
    ///   in full, and a clip is never one of those.
    public func payloadBegin(captureId: String, bytes: UInt64, digest: Data,
                             chunkBytes: UInt32, channel: PpcpChannel = .bulk,
                             container: String? = nil,
                             achievedFrames: PpcpAchievedFrames? = nil) throws {
        var value = try Self.digest(digest)
        let peer = try handle()
        // ⚠ `payload_begin_as` in both arms: the old entry point delegates to it
        // with a NULL container, so there is one code path here rather than two
        // that can drift.
        try withOptionalCString(container) { containerC in
            guard let achievedFrames else {
                try check(ppcp_peer_payload_begin_as(peer, channel.rawValue, captureId,
                                                     bytes, &value, chunkBytes,
                                                     containerC, nil))
                return
            }
            try achievedFrames.withCValue { frames in
                try check(ppcp_peer_payload_begin_as(peer, channel.rawValue, captureId,
                                                     bytes, &value, chunkBytes,
                                                     containerC, frames))
            }
        }
    }

    /// Run `body` with a borrowed C string, or with `nil`.
    private func withOptionalCString(_ text: String?,
                                     _ body: (UnsafePointer<CChar>?) throws -> Void) rethrows {
        guard let text else { return try body(nil) }
        try text.withCString { try body($0) }
    }

    public func payloadChunk(captureId: String, index: UInt32, chunkBytes: UInt32,
                             data: Data, channel: PpcpChannel = .bulk) throws {
        let peer = try handle()
        let result: ppcp_result = data.withUnsafeBytes { raw in
            ppcp_peer_payload_chunk(peer, channel.rawValue, captureId, index, chunkBytes,
                                    raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        try check(result)
    }

    public func payloadEnd(captureId: String, digest: Data,
                           channel: PpcpChannel = .bulk) throws {
        var value = try Self.digest(digest)
        try check(ppcp_peer_payload_end(try handle(), channel.rawValue, captureId, &value))
    }

    /// ⚠ The engine handle, for the two library calls that take a `ppcp_peer *`
    /// from outside this file — `ppcp_bundle_reader_new`'s sink. Not public:
    /// nothing outside `CaptureCore` gets a raw pointer to the engine.
    func withHandle<T>(_ body: (OpaquePointer?) -> T) -> T { body(peer) }

    static func digest(_ bytes: Data) throws -> ppcp_digest {
        guard bytes.count == Int(PPCP_SHA256_BYTES) else {
            throw PpcpLibraryError(PPCP_ERR_INVALID)
        }
        var digest = ppcp_digest()
        var raw = [UInt8](bytes)
        try check(ppcp_digest_set(&digest, &raw))
        return digest
    }

    // MARK: Transport

    /// Bytes in, on the channel they arrived on.
    ///
    /// ⚠ **Returns how many bytes it consumed, and the caller keeps the tail.**
    /// The engine buffers nothing (`peer.h`): it takes whole frames out of the
    /// caller's buffer, so a trailing partial frame is re-presented with more
    /// bytes after it. A caller that discarded the tail would desynchronise the
    /// stream and the symptom would appear frames later.
    /// ⛔ **The events are harvested between feeds — F-L13-1, and the library's
    /// fix rather than this application's workaround.** `ppcp_peer_feed` used to
    /// consume unboundedly many whole frames per call over a four-deep event
    /// ring, dropping the **oldest** event on overflow: a 64 KiB socket read is
    /// comfortably more than four control frames, so the first events of a burst
    /// — the `declare`, the `session_open` — were the half that was lost.
    ///
    /// L15 changed the engine to **stop** when the event queue is full and
    /// report what it consumed, so the loop `peer.h` documents is the one below:
    /// feed, drain the events, re-present the remainder. `ppcp_peer_feed_stalled`
    /// is what tells "no room for events" apart from "not a whole frame yet",
    /// which are the only two reasons a feed returns short.
    ///
    /// ⚠ This replaced a hand-written frame walk that fed exactly one frame at a
    /// time — correct, and one more place framing was re-implemented outside the
    /// library. The walk went when the reason for it did.
    @discardableResult
    public func feed(_ bytes: Data, on channel: PpcpChannel) throws -> Int {
        guard bytes.isEmpty == false else { return 0 }
        let peer = try handle()
        var offset = 0

        while offset < bytes.count {
            var consumed = 0
            let result: ppcp_result = bytes.withUnsafeBytes { raw in
                ppcp_peer_feed(peer, channel.rawValue,
                               raw.bindMemory(to: UInt8.self).baseAddress! + offset,
                               raw.count - offset, &consumed)
            }
            offset += consumed
            // ⚠ Before `check`, so a frame the engine refused still yields the
            // events it raised on the way to refusing it.
            harvestEvents()
            try check(result)
            // A trailing partial frame is left for the caller to re-present; a
            // stall means the ring filled and there is more in this buffer.
            if consumed == 0, ppcp_peer_feed_stalled(peer) == false { break }
        }
        return offset
    }

    /// F-L13-1 — how many events the engine dropped because nothing harvested
    /// them in time. ⛔ Non-zero is a defect in this embedding's loop, not a
    /// statistic: it means a `session_open` or a `declare` went missing.
    public var droppedEventCount: UInt64 {
        peer.map(ppcp_peer_events_dropped) ?? 0
    }

    /// Moves whatever the engine raised out of its four-deep ring and into a
    /// Swift queue, before another frame can push it out.
    ///
    /// ⚠ **Each event's `ppcp_msg` is copied onto the heap**, because `peer.h`
    /// gives the borrowed pointer four events' worth of life and this queue is
    /// deliberately longer than that. ⛔ A `declare`'s nested Sources still point
    /// into the engine's declaration arena and are valid only until the
    /// counterpart declares again (3.3a) — copying the union does not deep-copy
    /// them, and nothing here pretends it does.
    private func harvestEvents() {
        guard let peer else { return }
        while true {
            var event = ppcp_event()
            guard ppcp_peer_next_event(peer, &event) == PPCP_OK else { return }
            events.append(HeldEvent(event))
        }
    }

    /// One event, with its message held on the heap for as long as this object is.
    final class HeldEvent {
        let kind: ppcp_event_kind
        let channel: PpcpChannel?
        let status: ppcp_result
        /// `MSG` 4.1a1 / 9.1b (erratum E28) — this frame belongs to an
        /// **imported** Session replayed onto the live link, not to the live one.
        ///
        /// ⛔ An embedding must not feed such a frame to the live Session's
        /// arbiter or mint pump, and must not convert its instants with the live
        /// `timebase_ref`. That is F-S5-3, found by the S5 wave-2 pairing: a host
        /// that ignored it arbitrated two Sessions as one and expressed every
        /// subsequent `t0` in the exporting device's clock.
        let imported: Bool
        private let raw: UnsafeMutableRawPointer?

        var message: UnsafePointer<ppcp_msg>? {
            raw.map { UnsafePointer($0.assumingMemoryBound(to: ppcp_msg.self)) }
        }

        init(_ event: ppcp_event) {
            kind = event.kind
            channel = PpcpChannel(rawValue: event.channel)
            status = event.status
            imported = event.imported
            guard let source = event.msg else { raw = nil; return }
            let bytes = MemoryLayout<ppcp_msg>.stride
            let storage = UnsafeMutableRawPointer.allocate(
                byteCount: bytes, alignment: MemoryLayout<ppcp_msg>.alignment)
            storage.copyMemory(from: UnsafeRawPointer(source), byteCount: bytes)
            raw = storage
        }

        deinit { raw?.deallocate() }
    }

    /// Whole frames out, per channel. Empty when nothing is queued.
    public func drain(_ channel: PpcpChannel) throws -> Data {
        let peer = try handle()
        guard ppcp_peer_pending(peer, channel.rawValue) > 0 else { return Data() }
        var out = [UInt8](repeating: 0, count: Self.drainCapacity)
        var length = 0
        try check(ppcp_peer_drain(peer, channel.rawValue, &out, out.count, &length))
        return Data(out[0..<length])
    }

    public func pending(_ channel: PpcpChannel) -> Int {
        guard let peer else { return 0 }
        return ppcp_peer_pending(peer, channel.rawValue)
    }

    // MARK: Events

    /// What arrived, in the order it arrived.
    ///
    /// ⚠ The decoded message is valid only for the duration of `body` — narrower
    /// than the copy's actual lifetime on purpose, because a `declare`'s nested
    /// Sources point into the engine's arena whatever this queue does.
    @discardableResult
    public func nextEvent<T>(_ body: (ppcp_event_kind, UnsafePointer<ppcp_msg>?) throws -> T)
        rethrows -> T? {
        // Anything the engine raised outside a `feed` — a liveness pump's
        // `link_lost`, a sync burst — is picked up here.
        harvestEvents()
        guard events.isEmpty == false else { return nil }
        let event = events.removeFirst()
        return try body(event.kind, event.message)
    }

    /// The channel an event arrived on. ⚠ `CORE` 5.11h puts preview payload on a
    /// bulk channel **distinct** from shot payload, and without this a receiver
    /// cannot check that it did.
    @discardableResult
    public func nextEventWithChannel<T>(
        _ body: (ppcp_event_kind, PpcpChannel?, UnsafePointer<ppcp_msg>?) throws -> T
    ) rethrows -> T? {
        harvestEvents()
        guard events.isEmpty == false else { return nil }
        let event = events.removeFirst()
        return try body(event.kind, event.channel, event.message)
    }

    /// The same, with `ppcp_event.imported` (`MSG` 4.1a1 / 9.1b, erratum E28).
    ///
    /// ⛔ **This is the overload a live link must use.** Reading an event without
    /// asking whether it is imported is what F-S5-3 was: the frames of an offered
    /// Session go onto the live link by design (`ENC` 7a), and only this flag
    /// tells them apart from the Session actually in progress.
    @discardableResult
    public func nextEventImported<T>(
        _ body: (ppcp_event_kind, PpcpChannel?, Bool, UnsafePointer<ppcp_msg>?) throws -> T
    ) rethrows -> T? {
        harvestEvents()
        guard events.isEmpty == false else { return nil }
        let event = events.removeFirst()
        return try body(event.kind, event.channel, event.imported, event.message)
    }

    public var queuedEventCount: Int {
        harvestEvents()
        return events.count
    }

    // MARK: Building the C structs

    static func ids(_ values: [String]) throws -> [ppcp_id] {
        try values.map { value in
            var id = ppcp_id()
            try check(ppcp_id_set_z(&id, value))
            return id
        }
    }

    /// Build the `ppcp_capture` for a record and hand it to `body`.
    ///
    /// ⚠ **Scoped, and it has to be since D4.** `achieved_summary.thermal` is a
    /// borrowed pointer into caller storage, so a `ppcp_capture` returned by
    /// value would carry a dangling one the instant the Swift array moved. The
    /// old by-value form was safe only because there was no summary on it yet.
    static func withCapture<R>(_ record: PpcpCaptureRecord,
                               _ body: (UnsafeMutablePointer<ppcp_capture>) throws -> R)
        throws -> R {
        var capture = ppcp_capture()
        let completeness: ppcp_completeness = switch record.completeness {
        case .complete: PPCP_COMPLETE
        case .partial: PPCP_PARTIAL
        case .absent: PPCP_ABSENT
        }

        switch record.anchor {
        case .shot(let shotId):
            try check(ppcp_capture_make_shot(&capture, record.id, shotId,
                                             record.streamId, completeness))
        case .candidate(let candidateId):
            try check(ppcp_capture_make_candidate(&capture, record.id, candidateId,
                                                  record.streamId, completeness))
        case .segment(let startNs, let endNs):
            var interval = ppcp_interval()
            try check(ppcp_interval_make(&interval, record.timebaseId,
                                         record.timebaseId.utf8.count, startNs, endNs))
            try check(ppcp_capture_make_segment(&capture, record.id, record.streamId,
                                                completeness, &interval))
        }

        if let range = record.intervalNs {
            var interval = ppcp_interval()
            try check(ppcp_interval_make(&interval, record.timebaseId,
                                         record.timebaseId.utf8.count,
                                         range.lowerBound, range.upperBound))
            try check(ppcp_capture_set_interval(&capture, &interval))
        }
        if let reason = record.absentReason {
            try check(ppcp_capture_set_absent_reason(&capture, reason))
        }
        // I11 — each gap is validated by the library against the Capture's own
        // interval, so a gap outside it is refused here rather than encoded.
        for gap in record.gapsNs {
            var interval = ppcp_interval()
            try check(ppcp_interval_make(&interval, record.timebaseId,
                                         record.timebaseId.utf8.count,
                                         gap.lowerBound, gap.upperBound))
            try check(ppcp_capture_add_gap(&capture, &interval))
        }
        if let bytes = record.bytes, let digestBytes = record.digest {
            guard digestBytes.count == Int(PPCP_SHA256_BYTES) else {
                throw PpcpLibraryError(PPCP_ERR_INVALID)
            }
            var digest = ppcp_digest()
            var raw = [UInt8](digestBytes)
            try check(ppcp_digest_set(&digest, &raw))
            try check(ppcp_capture_set_digest(&capture, &digest, bytes))
        }
        // ⛔ Not reachable for `.confirmed`: `PpcpTransferState` has no such case
        // and `ppcp_capture_set_transfer` refuses it (5.14f, 8.4b).
        try check(ppcp_capture_set_transfer(&capture, record.transfer.cValue))

        guard let summary = record.achievedSummary else {
            try check(ppcp_capture_validate(&capture))
            return try body(&capture)
        }
        return try summary.withCValue { built in
            try check(ppcp_capture_set_summary(&capture, built))
            try check(ppcp_capture_validate(&capture))
            return try body(&capture)
        }
    }
}
