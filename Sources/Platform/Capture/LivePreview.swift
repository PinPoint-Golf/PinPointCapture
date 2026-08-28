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

    // ⛔ **THE 64-SEGMENT BUDGET IS GONE, AND THE LIBRARY IS WHY IT CAN BE.**
    //
    // Until 27 Aug this type stopped itself after 64 segments — 6.4 seconds of
    // picture — because `ppcp_transfer_observe_announce` never released a
    // transfer slot: every announced Capture held one for the peer's lifetime,
    // so preview at ~10 fps spent all 128 in about thirteen seconds and the
    // next **shot** announce failed with `PPCP_ERR_LIMIT`. That is 5.11i
    // exactly inverted — preview degrades before transfer and transfer before
    // capture, and here preview was stopping capture outright (#107).
    //
    // libppcp now reclaims the entries 5.14g has released, and a preview
    // segment is `shed_permitted` on arrival (exit 4, 5.11j — it was never
    // going to be transferred), so a preview Stream no longer consumes the
    // table at all. The cap was containment for a library defect; the defect is
    // fixed, so the containment goes rather than being tuned.
    //
    // ⚠ A preview that stops on its own is indistinguishable at the host from
    // one that never worked — this cap cost an operator an evening of looking
    // at a black rectangle, which is the second reason not to keep a quieter
    // version of it.

    private let pump: PeerLinkPump
    private let device: any CaptureDevice
    private let producer: PreviewProducer
    /// The record as the **host** named it — its `stream_id`, not one we chose.
    public let stream: PpcpStreamRecord
    private var segments = 0
    private var stopped = false

    // ⛔ **WHY THERE IS NO PICTURE, ANSWERED ON THE DEVICE.**  Delivery used to
    // be `try?` from end to end: a frame that never arrived, one that failed to
    // encode and one the producer refused were all the same silence, and a host
    // seeing `capt=0` could not tell which of the three it had.  That cost two
    // evenings on 27-28 Aug 2026.  Counted per stage, so the FIRST zero names
    // the break.
    public private(set) var framesTapped = 0
    public private(set) var segmentsSent = 0
    public private(set) var lastError: String?
    private var reported: Set<String> = []

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
            // ⛔ **ADOPTED WHERE THE HOST ALREADY NAMED IT.**  A consumer's
            // `stream_open` is registered by the engine itself
            // (`peer_on_stream_open` → `peer_stream_add`) and acked `opened`
            // before this application sees the request at all — so opening it
            // again here is a duplicate, and 5.1a makes the engine refuse it.
            //
            // ⚠ That is exactly what happened, on every connect, for two days:
            // this `try` threw `PPCP_ERR_INVALID`, `openPreview` returned
            // `stream_open_failed`, and no preview was ever produced — while
            // PinPointStudio, having been told `opened` BY THE LIBRARY, showed a
            // Stream it believed was live, zero refusals and zero errors.
            if peer.hasStream(id: stream.id) == false {
                try peer.openStream(stream)
            }
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
        print("[preview] tap attached source=\(stream.sourceId) openedAtNs=\(stream.openedAtNs)")
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
        framesTapped += 1
        if framesTapped == 1 {
            // ⚠ THE ONE NUMBER THAT SETTLES "no frames" vs "frames refused".
            // `opened_at` is `MachClock.hostTimeNs`; a frame's instant is its
            // PRESENTATION timestamp.  If those are not the same clock every
            // segment ends before the Stream began, StreamCoverage refuses the
            // lot, and until now it did so silently.
            print("[preview] first frame ptsNs=\(atNs) openedAtNs=\(stream.openedAtNs) "
                  + "deltaMs=\((atNs - stream.openedAtNs) / 1_000_000) bytes=\(jpeg.count)")
        }
        segments += 1
        do {
            try await pump.perform { [producer] _ in
                // ⚠ **Only where a WHOLE interval is genuinely unaccounted
                // for.** `atNs - intervalNs` reaches back before `opened_at`
                // when the first frame lands less than one interval after the
                // Stream opened — which is the ordinary case, because the tap
                // goes on immediately and frames arrive ~19 ms later — and
                // `StreamCoverage` rightly refuses a segment that ends before
                // it starts.  The shed is for a real gap, not for the moment
                // the Stream was born.
                let shedThrough = atNs - PreviewFrameTap.intervalNs
                if producer.unaccountedNs(asOf: atNs) != nil,
                   shedThrough > producer.accountedThroughNs {
                    _ = try producer.shed(throughNs: shedThrough)
                }
                _ = try producer.deliver(endingAtNs: atNs, payload: jpeg)
            }
            segmentsSent += 1
            if segmentsSent == 1 || segmentsSent % 100 == 0 {
                print("[preview] sent=\(segmentsSent) tapped=\(framesTapped)")
            }
        } catch {
            // ⛔ Recorded, and named ONCE per distinct failure.  A per-frame log
            // at 10 fps is its own kind of silence.
            let text = String(describing: error)
            lastError = text
            if reported.insert(text).inserted {
                print("[preview] REFUSED after \(framesTapped) frame(s): \(text)")
            }
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
