//  BootstrapWindowTests.swift
//  `PPCP-RV` §3.7 and RT-22, on the host, with no simulator and no responder.
//
//  ⚠ **RT-22 is a `paired` row and two thirds of it is not.** "A bootstrap
//  instance carries `bs`, no `rn` and no `rid`" is a statement about a TXT record
//  and "an instance carrying both `bs` and `rid` is ignored" is a statement about
//  a reader — both are decided over a dictionary and are asserted here. Only "the
//  instance is withdrawn when the window closes" needs a responder, and that half
//  is `BootstrapAdvertiserTests` in the app target.
//
//  Spec: `RV` 3.2c, 3.3f, 3.3g, 3.7a-3.7d, 11.3c, 11.3d, 11.9b. Plan D10.

import Foundation
import Testing
@testable import CaptureCore

@Suite("RV 3.7 — the bootstrap window")
struct BootstrapWindowTests {

    static let bn = Data([0x9B, 0x1D, 0x2D, 0xF9])
    static func action(_ name: String = "pair-a-new-host") -> BootstrapWindow.UserAction {
        BootstrapWindow.UserAction(control: name)!
    }
    static func advert(label: BootstrapLabel? = nil) throws -> BootstrapAdvertisement {
        try BootstrapAdvertisement(bn: bn, label: label)
    }

    static let second: Int64 = 1_000_000_000

    // MARK: - 3.2c — the instance name

    @Test("3.2c — PPCP- and the eight uppercase hex characters of bn")
    func instanceName() throws {
        #expect(try Self.advert().instanceName == "PPCP-9B1D2DF9")
    }

    @Test("3.2c — indistinguishable in form from a reconnection instance name")
    func sameFormAsReconnection() throws {
        let name = try Self.advert().instanceName
        #expect(name.hasPrefix("PPCP-"))
        #expect(name.count == 13)
        #expect(name.dropFirst(5).allSatisfy { "0123456789ABCDEF".contains($0) })
    }

    @Test("3.7c — bn is four bytes and nothing else is accepted")
    func windowIdWidth() {
        #expect(throws: TransportError.self) {
            _ = try BootstrapAdvertisement(bn: Data([0, 1, 2]), label: nil)
        }
        #expect(throws: TransportError.self) {
            _ = try BootstrapAdvertisement(bn: Data(repeating: 0, count: 8), label: nil)
        }
    }

    // MARK: - RT-22, first half — 3.3f / 3.3g, the record this peer publishes

    @Test("RT-22 — a bootstrap instance carries bs, no rn and no rid")
    func recordCarriesBsAndNeitherIdentifier() throws {
        let txt = try Self.advert().txtRecord
        #expect(txt["bs"] == "1")
        #expect(txt["rn"] == nil)
        #expect(txt["rid"] == nil)
    }

    @Test("3.3f — exactly txtvers, pv, role, bs, and dl only when set")
    func recordIsAClosedList() throws {
        #expect(try Set(Self.advert().txtRecord.keys) == ["txtvers", "pv", "role", "bs"])
        let labelled = try Self.advert(label: BootstrapLabel(operatorEntered: "Bay 3"))
        #expect(Set(labelled.txtRecord.keys) == ["txtvers", "pv", "role", "bs", "dl"])
        #expect(labelled.txtRecord["dl"] == "Bay 3")
    }

    @Test("3.3b — no device name, no session count, no capability, in either form")
    func recordCarriesNothingIdentifying() throws {
        let txt = try Self.advert(label: BootstrapLabel(operatorEntered: "Bay 3")).txtRecord
        for key in ["dn", "id", "name", "model", "sessions", "cap", "peer"] {
            #expect(txt[key] == nil)
        }
    }

    @Test("3.3c — the whole record stays under 200 bytes")
    func recordFitsOneResponse() throws {
        let longest = BootstrapLabel(operatorEntered: String(repeating: "W", count: 200))
        #expect(try Self.advert(label: longest).txtRecordBytes < 200)
    }

    // MARK: - RT-22, second half — 3.3g, what a reader does

    @Test("RT-22 — an instance carrying both bs and rid is ignored")
    func bootstrapWithRidIsMalformed() {
        let txt = ["txtvers": "1", "pv": "1.0", "role": "host",
                   "bs": "1", "rid": String(repeating: "a", count: 16)]
        #expect(DiscoveredInstance.classify(txt: txt) == .ignored(.bootstrapCarriesRid))
    }

    @Test("3.3g — and one carrying bs with rn is ignored too")
    func bootstrapWithRnIsMalformed() {
        let txt = ["txtvers": "1", "pv": "1.0", "role": "host",
                   "bs": "1", "rn": String(repeating: "b", count: 16)]
        #expect(DiscoveredInstance.classify(txt: txt) == .ignored(.bootstrapCarriesRn))
    }

    @Test("3.3f — a bs that is not 1 is ignored")
    func bootstrapFlagIsExactlyOne() {
        for value in ["0", "2", "true", "", "1 "] {
            let txt = ["txtvers": "1", "pv": "1.0", "role": "host", "bs": value]
            #expect(DiscoveredInstance.classify(txt: txt)
                    == .ignored(.malformedBootstrapFlag),
                    "bs=\(value)")
        }
    }

    @Test("3.3f — a well-formed bootstrap instance classifies as one")
    func bootstrapClassifies() {
        let txt = ["txtvers": "1", "pv": "1.0-1.2", "role": "host",
                   "bs": "1", "dl": "Bay 3"]
        guard case .bootstrap(let found) = DiscoveredInstance.classify(txt: txt) else {
            Issue.record("expected a bootstrap instance"); return
        }
        #expect(found.role == .host)
        #expect(found.label?.text == "Bay 3")
    }

    @Test("3.3d — a pv this reader cannot parse means ignore, not guess")
    func unparseableVersionRangeIsIgnored() {
        let txt = ["txtvers": "1", "pv": "one-point-oh", "role": "host", "bs": "1"]
        #expect(DiscoveredInstance.classify(txt: txt)
                == .ignored(.unparseableVersionRange))
    }

    @Test("3.3g — an instance with rn and rid and no bs is the reconnection form")
    func reconnectionStillClassifies() {
        let txt = ["txtvers": "1", "pv": "1.0", "role": "capture",
                   "rn": String(repeating: "a", count: 16),
                   "rid": String(repeating: "b", count: 16)]
        #expect(DiscoveredInstance.classify(txt: txt) == .reconnection)
    }

    // MARK: - The C1 gate: a real foreign advertisement, told apart

    /// ⚠ **Observed, not invented.** This is the exact TXT record PinPointStudio
    /// (H9, `8ed4259`) had on the network at 17:23 on 24 August 2026, read with
    /// `dns-sd -L PPCP-11121314 _ppcp._tcp local.` — `PPCP-11121314` at
    /// `Marks-Mac-mini.local.:47788`. It is here so the classifier is exercised
    /// against another implementation's bytes rather than only against this
    /// one's idea of them.
    @Test("3.3g — the host's live reconnection instance is told apart from a window")
    func theObservedHostAdvertisementClassifies() {
        let observed = ["txtvers": "1", "pv": "1.0", "role": "host",
                        "rn": "05060708090a0b0c", "rid": "e1629a8860e0386c"]
        #expect(DiscoveredInstance.classify(txt: observed) == .reconnection)

        // The two halves the fields have to survive for §3.4 to reach them.
        #expect(DiscoveryResolver.hexField(observed["rn"], bytes: 8)?.count == 8)
        #expect(DiscoveryResolver.hexField(observed["rid"], bytes: 8)?.count == 8)
        #expect(DiscoveryRole(rawValue: observed["role"]!) == .host)
        #expect(PpcpVersionRange.advertises(observed["pv"]!, major: 1))

        // ⛔ And it is NOT a bootstrap instance: no `bs`, so §3.7 does not reach
        // it and 3.4c governs instead — this peer may not dial what it cannot
        // resolve.
        #expect(observed["bs"] == nil)
    }

    // MARK: - 3.3f / 3.3g / 4.4d — dl

    @Test("4.4d — dl is truncated to 32 bytes on a scalar boundary")
    func labelTruncates() {
        let label = BootstrapLabel(operatorEntered: String(repeating: "é", count: 40))
        #expect(label != nil)
        #expect(label!.text.utf8.count <= BootstrapLabel.maximumBytes)
        // é is two UTF-8 bytes, so sixteen fit and the seventeenth does not.
        #expect(label!.text.count == 16)
    }

    @Test("4.4d — dl is escaped for display: controls and bidi overrides go")
    func labelIsEscaped() {
        let nasty = "Bay\u{0007}3\u{202E}xyz"
        #expect(BootstrapLabel(operatorEntered: nasty)?.text == "Bay3xyz")
    }

    @Test("3.3g — an empty or whitespace dl is absent, not present and empty")
    func emptyLabelIsAbsent() throws {
        #expect(BootstrapLabel(operatorEntered: "   ") == nil)
        #expect(BootstrapLabel(operatorEntered: "\u{202E}") == nil)
        #expect(try Self.advert(label: nil).txtRecord["dl"] == nil)
    }

    // MARK: - 3.7a — the window opens only on an explicit user action

    @Test("3.7a — a new window is closed, and nothing has opened it")
    func startsClosed() throws {
        let window = try BootstrapWindow()
        #expect(window.isOpen == false)
        #expect(window.advertisement == nil)
    }

    @Test("3.7a — a user action with no control named is not a user action")
    func userActionNeedsAControl() {
        #expect(BootstrapWindow.UserAction(control: "") == nil)
        #expect(BootstrapWindow.UserAction(control: "  \n ") == nil)
        #expect(BootstrapWindow.UserAction(control: "pair-a-new-host") != nil)
    }

    @Test("3.7d — at most one bootstrap instance at a time")
    func openIsRefusedWhileOpen() throws {
        var window = try BootstrapWindow()
        try window.open(on: Self.action(), advertising: try Self.advert(), atNs: 0)
        #expect(throws: BootstrapWindow.Failure.alreadyOpen) {
            try window.open(on: Self.action(), advertising: try Self.advert(), atNs: 1)
        }
    }

    // MARK: - 3.7b — the four ways it closes, and the bound on the timeout

    @Test("3.7b — the timeout MUST NOT exceed 180 seconds, and is refused not clamped")
    func timeoutIsBounded() throws {
        #expect(BootstrapAdvertisement.maximumTimeoutNs == 180 * Self.second)
        #expect(throws: BootstrapWindow.Failure.self) {
            _ = try BootstrapWindow(timeoutNs: 181 * Self.second)
        }
        #expect(throws: BootstrapWindow.Failure.self) {
            _ = try BootstrapWindow(timeoutNs: 0)
        }
        #expect(try BootstrapWindow(timeoutNs: 180 * Self.second).timeoutNs
                == 180 * Self.second)
    }

    @Test("3.7b — the peer's own timeout closes it")
    func closesOnTimeout() throws {
        var window = try BootstrapWindow(timeoutNs: 30 * Self.second)
        try window.open(on: Self.action(), advertising: try Self.advert(), atNs: 0)
        #expect(window.tick(nowNs: 29 * Self.second) == nil)
        #expect(window.isOpen)
        #expect(window.tick(nowNs: 30 * Self.second) == .timedOut)
        #expect(window.isOpen == false)
        #expect(window.lastClose?.reason == .timedOut)
    }

    @Test("3.7b — one completed pairing closes it")
    func closesOnCompletion() throws {
        var window = try BootstrapWindow()
        try window.open(on: Self.action(), advertising: try Self.advert(), atNs: 0)
        try window.beginAttempt(atNs: Self.second)
        try window.endAttempt(.completed, atNs: 2 * Self.second)
        #expect(window.isOpen == false)
        #expect(window.lastClose?.reason == .pairingCompleted)
    }

    @Test("3.7b / 11.9a — one abort or rejection closes it")
    func closesOnAbort() throws {
        var window = try BootstrapWindow()
        try window.open(on: Self.action(), advertising: try Self.advert(), atNs: 0)
        try window.beginAttempt(atNs: Self.second)
        try window.endAttempt(.abortedOrRejected(.rejected), atNs: 2 * Self.second)
        #expect(window.isOpen == false)
        #expect(window.lastClose?.reason == .attemptAbortedOrRejected)
    }

    @Test("3.7b — a further user action closes it")
    func closesOnUserAction() throws {
        var window = try BootstrapWindow()
        try window.open(on: Self.action(), advertising: try Self.advert(), atNs: 0)
        // ⚠ Not inside `#expect`: the macro captures the receiver immutably and
        // `close` is `mutating`.
        let closed = window.close(on: Self.action("close-the-window"), atNs: Self.second)
        #expect(closed)
        #expect(window.lastClose?.reason == .userClosed)
    }

    @Test("3.7b — the FIRST cause wins; a later one does not rewrite the record")
    func firstCauseWins() throws {
        var window = try BootstrapWindow(timeoutNs: 10 * Self.second)
        try window.open(on: Self.action(), advertising: try Self.advert(), atNs: 0)
        // ⚠ Not inside `#expect`: the macro captures the receiver immutably and
        // `close` is `mutating`.
        let closed = window.close(on: Self.action("close-the-window"), atNs: Self.second)
        #expect(closed)
        #expect(window.tick(nowNs: 100 * Self.second) == nil)
        #expect(window.lastClose?.reason == .userClosed)
        #expect(window.lastClose?.atNs == Self.second)
    }

    @Test("3.7d — the advertisement, and bn with it, is dropped on close")
    func advertisementDiesWithTheWindow() throws {
        var window = try BootstrapWindow()
        try window.open(on: Self.action(), advertising: try Self.advert(), atNs: 0)
        #expect(window.advertisement?.instanceName == "PPCP-9B1D2DF9")
        window.close(reason: .timedOut, atNs: Self.second)
        #expect(window.advertisement == nil)
    }

    // MARK: - 11.9b — it does not reopen without a further user action

    @Test("11.9b — a tick can close a window and can never open one")
    func tickNeverOpens() throws {
        var window = try BootstrapWindow(timeoutNs: 10 * Self.second)
        try window.open(on: Self.action(), advertising: try Self.advert(), atNs: 0)
        #expect(window.tick(nowNs: 10 * Self.second) == .timedOut)
        // A timer that goes on running finds nothing to reopen, at any time.
        for now in stride(from: Int64(11), through: 10_000, by: 137) {
            #expect(window.tick(nowNs: now * Self.second) == nil)
            #expect(window.isOpen == false)
        }
    }

    @Test("11.9b — after an abort, only a further user action opens it again")
    func reopeningNeedsAFurtherUserAction() throws {
        var window = try BootstrapWindow()
        try window.open(on: Self.action(), advertising: try Self.advert(), atNs: 0)
        try window.beginAttempt(atNs: Self.second)
        try window.endAttempt(.abortedOrRejected(.rejected), atNs: 2 * Self.second)
        #expect(window.isOpen == false)
        // Nothing an attempt can do reopens it.
        #expect(throws: BootstrapWindow.Failure.windowClosed) {
            try window.beginAttempt(atNs: 3 * Self.second)
        }
        // The one path back, and it needs a named control and a fresh `bn`.
        let second = try BootstrapAdvertisement(bn: Data([1, 2, 3, 4]), label: nil)
        try window.open(on: Self.action(), advertising: second, atNs: 4 * Self.second)
        #expect(window.isOpen)
        #expect(window.advertisement?.instanceName == "PPCP-01020304")
    }

    @Test("11.9c — a mismatch or MAC failure is not reported as an ordinary failure")
    func abortDoesNotInviteARetry() {
        #expect(BootstrapWindow.CloseReason.attemptAbortedOrRejected
                    .mayBeReportedAsAnOrdinaryFailure == false)
        #expect(BootstrapWindow.CloseReason.timedOut.mayBeReportedAsAnOrdinaryFailure)
    }

    /// ⛔ **The half D10 could not answer, and it is the half 11.9c turns on.**
    /// `attemptAbortedOrRejected` covers a mismatch, a MAC failure, a timeout and
    /// a malformed frame. A screen reading only the close reason has to either
    /// suppress *try again* after an ordinary network failure or invite it after
    /// an attack; neither is what the clause asks for.
    @Test("11.9c — the close carries WHY the attempt aborted, so a mismatch and a timeout read differently")
    func closeCarriesTheAbortReason() throws {
        func closed(after why: BootstrapAbortReason) throws -> BootstrapWindow.Close {
            var window = try BootstrapWindow()
            try window.open(on: Self.action(), advertising: try Self.advert(), atNs: 0)
            try window.beginAttempt(atNs: Self.second)
            try window.endAttempt(.abortedOrRejected(why), atNs: 2 * Self.second)
            return window.lastClose!
        }

        // ⛔ The one signal this path produces that an attack is under way.
        let mismatch = try closed(after: .rejected)
        #expect(mismatch.reason == .attemptAbortedOrRejected)
        #expect(mismatch.abortReason == .rejected)
        #expect(mismatch.advice == .doNotRetry)

        // The ordinary failure it is (11.9c's own words).
        let timedOut = try closed(after: .timeout)
        #expect(timedOut.reason == .attemptAbortedOrRejected)
        #expect(timedOut.advice == .ordinaryFailure)

        // 11.9d1 — the pairing code on the FIRST abort, because a second attempt
        // is guaranteed to fail identically.
        #expect(try closed(after: .unsupportedVersion).advice == .offerThePairingCode)

        // A window that closed with no attempt running carries no abort reason,
        // and answers on the close alone.
        var window = try BootstrapWindow()
        try window.open(on: Self.action(), advertising: try Self.advert(), atNs: 0)
        window.close(on: Self.action("close-the-window"), atNs: Self.second)
        #expect(window.lastClose?.abortReason == nil)
        #expect(window.lastClose?.advice == .ordinaryFailure)
    }

    // MARK: - 11.3d — one attempt at a time

    @Test("11.3d — a concurrent attempt is refused")
    func oneAttemptAtATime() throws {
        var window = try BootstrapWindow()
        try window.open(on: Self.action(), advertising: try Self.advert(), atNs: 0)
        try window.beginAttempt(atNs: Self.second)
        #expect(throws: BootstrapWindow.Failure.attemptAlreadyRunning) {
            try window.beginAttempt(atNs: Self.second + 1)
        }
    }

    @Test("11.3d — an attempt on a closed window is refused")
    func noAttemptWithoutAWindow() throws {
        var window = try BootstrapWindow()
        #expect(throws: BootstrapWindow.Failure.windowClosed) {
            try window.beginAttempt(atNs: 0)
        }
    }

    @Test("3.7b — an attempt starting past the deadline closes the window instead")
    func attemptPastTheDeadlineIsRefused() throws {
        var window = try BootstrapWindow(timeoutNs: 10 * Self.second)
        try window.open(on: Self.action(), advertising: try Self.advert(), atNs: 0)
        #expect(throws: BootstrapWindow.Failure.windowClosed) {
            try window.beginAttempt(atNs: 11 * Self.second)
        }
        #expect(window.isOpen == false)
        #expect(window.lastClose?.reason == .timedOut)
    }

    @Test("11.3d — an attempt that ends, ends the window with it")
    func attemptEndEndsTheWindow() throws {
        var window = try BootstrapWindow()
        try window.open(on: Self.action(), advertising: try Self.advert(), atNs: 0)
        try window.beginAttempt(atNs: Self.second)
        try window.endAttempt(.completed, atNs: 2 * Self.second)
        // ⛔ There is no state in which an attempt has finished and the window is
        // still open — that state is the one an attacker gets a second draw from.
        #expect(window.isOpen == false)
        #expect(window.attemptInProgress == false)
    }
}

// MARK: - 11.3c — refusing a first frame that is not a well-formed bs_offer

@Suite("RV 11.3c — the first frame")
struct BootstrapFirstFrameTests {

    static func frame(channel: UInt8, payload: Data,
                      declaredLength: UInt32? = nil) -> Data {
        let length = declaredLength ?? UInt32(payload.count)
        var out = Data([UInt8(truncatingIfNeeded: length >> 24),
                        UInt8(truncatingIfNeeded: length >> 16),
                        UInt8(truncatingIfNeeded: length >> 8),
                        UInt8(truncatingIfNeeded: length),
                        channel, 0, 0, 0])
        out.append(payload)
        return out
    }

    @Test("ENC §3 — fewer bytes than a header is a wait, not a refusal")
    func shortHeaderIsIncomplete() {
        #expect(BootstrapFirstFrame.classify(Data()) == .incomplete)
        #expect(BootstrapFirstFrame.classify(Data([0, 0, 0, 4, 255, 0, 0]))
                == .incomplete)
    }

    @Test("11.3c — a first frame on a PPCP channel is refused")
    func ppcpFrameIsRefused() {
        for channel: UInt8 in [0, 1, 2, 7] {
            let bytes = Self.frame(channel: channel, payload: Data([0xA1, 0x01, 0x01]))
            #expect(BootstrapFirstFrame.classify(bytes)
                    == .refuse(.notBootstrapChannel(channel)),
                    "channel \(channel)")
        }
    }

    @Test("11.3c — an empty payload cannot be a bs_offer")
    func emptyPayloadIsRefused() {
        #expect(BootstrapFirstFrame.classify(Self.frame(channel: 255, payload: Data()))
                == .refuse(.emptyPayload))
    }

    @Test("ENC 3a — an oversized frame is refused on its length, before allocating")
    func oversizedIsRefusedOnTheLengthAlone() {
        // Eight bytes of header and a declared 64 MiB. Nothing is allocated.
        let bytes = Self.frame(channel: 255, payload: Data(),
                               declaredLength: 64 * 1024 * 1024)
        #expect(BootstrapFirstFrame.classify(bytes)
                == .refuse(.payloadTooLarge(64 * 1024 * 1024)))
    }

    @Test("ENC 3b — a non-zero flags or reserved is ignored, not refused")
    func unknownHeaderBitsAreIgnored() {
        var bytes = Self.frame(channel: 255, payload: Data([0xA1]))
        bytes[5] = 0x80   // flags
        bytes[7] = 0x01   // reserved
        #expect(BootstrapFirstFrame.classify(bytes) == .envelope(payload: Data([0xA1])))
    }

    @Test("11.3c — a complete channel-255 frame yields an envelope and nothing more")
    func envelopeIsNotAnOffer() {
        let payload = Data([0xA2, 0x61, 0x76, 0x01])
        #expect(BootstrapFirstFrame.classify(Self.frame(channel: 255, payload: payload))
                == .envelope(payload: payload))
        // ⛔ And the envelope alone is NOT a well-formed `bs_offer`: without a
        // decoder nothing is, which is 11.3c's refusal and not a stub failing open.
        #expect(BootstrapFirstFrame.isWellFormedOffer(
            Self.frame(channel: 255, payload: payload),
            using: BootstrapDecoderUnavailable()) == false)
    }

    @Test("11.3c — a trailing partial frame is a wait, and the payload is exact")
    func payloadIsCutAtTheDeclaredLength() {
        var bytes = Self.frame(channel: 255, payload: Data([1, 2, 3, 4]))
        bytes.append(contentsOf: [9, 9, 9])   // the start of a second frame
        #expect(BootstrapFirstFrame.classify(bytes)
                == .envelope(payload: Data([1, 2, 3, 4])))

        let short = Self.frame(channel: 255, payload: Data([1, 2]), declaredLength: 4)
        #expect(BootstrapFirstFrame.classify(short) == .incomplete)
    }

    @Test("11.3c — with no decoder, nothing at all is a well-formed offer")
    func nothingIsAnOfferWithoutADecoder() {
        let recogniser = BootstrapDecoderUnavailable()
        for bytes in [Data(), Data([0xA1]),
                      Self.frame(channel: 255, payload: Data([0xA2, 0x61, 0x76, 0x01])),
                      Self.frame(channel: 0, payload: Data([0xA1, 0x01]))] {
            #expect(BootstrapFirstFrame.isWellFormedOffer(bytes, using: recogniser)
                    == false)
        }
    }
}
