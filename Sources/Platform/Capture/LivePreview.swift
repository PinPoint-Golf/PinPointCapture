//  LivePreview.swift
//  The `preview` Stream, from the moment a host asks for it — which is at
//  connect, and not at arm.
//
//  ⛔ **Preview does not belong to a recording session, and this type exists
//  because it used to.** `RecordingSession` owned the Stream, the producer, the
//  tap and the budget, so a picture could not exist until a golfer pressed
//  Capture — by which time the framing decision it exists to inform has already
//  been made blind. `CORE` 5.11.2 names *"setup and framing"* as preview's main
//  use and 5.11k makes a preview Stream **alone** an independent mode, so
//  nothing about it is downstream of arming: 7.3a's arming governs the *capture*
//  path, and 5.11i has preview degrading *before* transfer and capture, which
//  only means anything if preview can exist without either.
//
//  ⛔ **On the link and nowhere else.** `SessionBundleWriter` refuses a preview
//  Capture (5.11j — live-only, never retained, never written), so this Stream
//  has no counterpart in the bundle by construction rather than by a filter
//  someone has to remember. That is also why `ENC` 7a/7b's ownership argument —
//  which is why this device must originate its *capture* Streams — does not
//  reach here: there is no file to keep consistent.
//
//  ⚠ **Request-driven, never unprompted.** PinPointStudio asks per Source, and
//  asked explicitly not to be sent preview for a Source it never requested.
//
//  Spec: `CORE` §5.11.2 (5.11c3, 5.11f–m), §5.11i, §9.2; `ENC` 2.1d, 6g.
//  PinPointStudio specification, 27 August 2026. Issue #108.

import Foundation
import CaptureCore

/// One live `preview` Stream: its producer, its tap and its accounting.
@MainActor
public final class LivePreview {

    /// How many segments one link may announce.
    ///
    /// ⛔ **A budget, because the library has no way to release a transfer
    /// entry.** `PPCP_TRANSFER_MAX` is 128 and the table only ever grows — every
    /// announced Capture takes a slot for the peer's lifetime, whatever its
    /// transfer state. Preview announces one per segment at ~10 fps, so it fills
    /// the table in about thirteen seconds and the next **shot** announce fails
    /// with `PPCP_ERR_LIMIT`, surfacing as "nothing is being recorded".
    ///
    /// ⛔ That is 5.11i inverted — preview degrades before transfer and transfer
    /// before capture, and here preview was stopping capture outright. Observed
    /// on hardware, 27 Aug ([#107]).
    ///
    /// ⚠ **Half the table, and the number is arbitrary because the fix is not
    /// ours.** libppcp needs to reclaim resolved entries, exactly as
    /// `ppcp_mint_pump` was taught to reclaim resolved mint slots for #103.
    public static let segmentBudget = 64

    private let pump: PeerLinkPump
    private let device: any CaptureDevice
    private let producer: PreviewProducer
    /// The record as the **host** named it — its `stream_id`, not one we chose.
    public let stream: PpcpStreamRecord
    private var segments = 0
    private var stopped = false

    /// Registers the host's Stream on the link peer and starts taking frames.
    ///
    /// ⛔ **Registering emits a redundant `stream_open`, and that is a library
    /// limitation rather than a choice.** `ppcp_peer_stream_open` queues the
    /// frame *and* adds the record (`src/ppcp_peer.c`), with no register-only
    /// entry point — so an owner cannot honour a consumer-originated
    /// `stream_open` without re-announcing a Stream the consumer already named.
    /// PinPointStudio resolves preview Captures by `source_id` whoever opened
    /// the Stream, so it costs a frame and nothing else. Raised as the twin of
    /// #106's `sync_arrival` gap: the library has the accurate path for one
    /// direction and not the other.
    public init(pump: PeerLinkPump, device: any CaptureDevice,
                stream: PpcpStreamRecord) async throws {
        self.pump = pump
        self.device = device
        self.stream = stream
        producer = try await pump.perform { [stream] peer in
            try peer.openStream(stream)
            return try PreviewProducer(peer: peer, stream: stream)
        }
    }

    /// Puts the tap on the capture path.
    ///
    /// ⛔ **Nothing is installed until the far end can actually receive a
    /// frame** — a tap running with no producer would cost the frame callback
    /// for nothing, which is the wrong side of 5.11i's ordering. So this is
    /// separate from `init` only in name: `init` throwing means no tap.
    public func start() {
        let tap = PreviewFrameTap { [weak self] jpeg, atNs in
            // ⚠ On the tap's own queue. The hop to the peer is here and nowhere
            // near the 6.7 ms frame callback.
            Task { @MainActor [weak self] in
                await self?.deliver(jpeg, endingAtNs: atNs)
            }
        }
        device.attachPreviewTap(tap)
    }

    /// One segment, onto the link.
    ///
    /// ⛔ **`shed` is not an error path — it is the accounting** (5.11c3).
    /// Deliberate non-retention is an `absent` segment with `absent_reason:
    /// not_retained`, never a gap: `gaps` mean loss (I11), and a peer that sheds
    /// a frame on purpose and records a gap is reporting a dropout it did not
    /// have.
    ///
    /// ⚠ **This is also how the arm transition is announced.** Arming
    /// reconfigures the camera — 5.11k makes preview *alone* an independent mode
    /// and preview beside a capture Stream a derived view — and frames stop for
    /// as long as that takes. The first frame afterwards finds the interval
    /// unaccounted for and sheds it, so an operator watching a tile go black is
    /// told it went black rather than left to infer it (their spec, §4.5).
    private func deliver(_ jpeg: Data, endingAtNs atNs: Int64) async {
        guard stopped == false else { return }
        guard segments < Self.segmentBudget else {
            // ⚠ Announced as shed once, then silent — and the tap comes off, so
            // the capture path stops paying for a picture nobody can receive.
            if segments == Self.segmentBudget {
                segments += 1
                try? await pump.perform { [producer] _ in
                    _ = try producer.shed(throughNs: atNs)
                }
                stop()
            }
            return
        }
        segments += 1
        try? await pump.perform { [producer] _ in
            if producer.unaccountedNs(asOf: atNs) != nil {
                _ = try producer.shed(throughNs: atNs - PreviewFrameTap.intervalNs)
            }
            _ = try producer.deliver(endingAtNs: atNs, payload: jpeg)
        }
    }

    /// Takes the tap off the capture path and closes the Stream.
    ///
    /// ⚠ Idempotent: called from the budget, from disconnect and from a host
    /// closing the Stream, and none of them coordinate.
    public func stop(reason: String = "not_needed") {
        guard stopped == false else { return }
        stopped = true
        device.attachPreviewTap(nil)
        // 5.1a1 — say why. ⛔ A Stream left open on a peer that has stopped
        // producing is the silence `MSG` E18 1c exists to prevent, one message
        // later.
        Task { [pump, id = stream.id, timebaseId = stream.timebaseId,
                atNs = MachClock.hostTimeNs] in
            try? await pump.perform { peer in
                try peer.closeStream(id: id, timebaseId: timebaseId,
                                     atNs: atNs, reason: reason)
            }
        }
    }

    /// How many segments have been announced — segments and sheds together.
    public var segmentsAnnounced: Int { segments }
    public var isStopped: Bool { stopped }
}
