//  BootstrapAdvertiserTests.swift
//  `PPCP-RV` 11.3c and 3.7b over a real socket — the half of D10 that cannot be
//  asserted from a dictionary.
//
//  ⚠ **In the app target because it needs `Network.framework`**, and only for
//  what genuinely needs it: a listener that really binds, a stranger that really
//  dials it, and a port that really stops answering when the window closes. The
//  record, the window state machine and the envelope check are all asserted in
//  `Packages/Core` where they run in milliseconds with no simulator.
//
//  ⛔ **What this file does NOT assert, stated so the green tick is not misread.**
//  3.7b withdraws the service **instance** — a DNS-SD property, checkable only
//  against a responder. These tests dial a TCP port instead, which is a **proxy
//  for that claim and not the claim itself**: an implementation could deregister
//  the record promptly and still hold a socket for a moment, and — the worse
//  direction — one could drop the socket and leave the record up, and nothing
//  here would see it. The proxy is used because observing the record needs the
//  local-network permission an unattended test cannot grant, and discovery on a
//  real network is deliberately held back to #66 where a phone can answer it.
//
//  So what IS asserted is the mechanism underneath the withdrawal: `close(on:)`
//  does not return until the listener has genuinely reached `.cancelled`, which
//  is what deregisters the instance. **RT-22's third assertion is therefore
//  demonstrated at the socket and argued at the record, not measured at the
//  record.** That distinction belongs in the matrix cell.
//
//  Spec: `RV` 3.7b, 3.7d, 3.7f, 11.3c, 11.3d, 11.9a, 11.9b. Plan D10. RT-22.

import Foundation
import Network
import os
import Testing
import CaptureCore
@testable import PinPointCapture

@Suite("RV §3.7 — the bootstrap window on a real socket", .serialized)
struct BootstrapAdvertiserTests {

    static func action(_ name: String = "pair-a-new-host") -> BootstrapWindow.UserAction {
        BootstrapWindow.UserAction(control: name)!
    }

    /// One frame of `ENC` §3: length, channel, flags, reserved, payload.
    static func frame(channel: UInt8, payload: Data) -> Data {
        let n = UInt32(payload.count)
        var out = Data([UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                        UInt8(truncatingIfNeeded: n >> 8),  UInt8(truncatingIfNeeded: n),
                        channel, 0, 0, 0])
        out.append(payload)
        return out
    }

    /// What a dial to the bootstrap endpoint actually met.
    ///
    /// ⛔ **`.ready` is NOT "the endpoint is alive", and assuming it was is what
    /// made the first version of this suite report a false failure.** A listening
    /// socket that has just been cancelled can still complete a TCP handshake
    /// into its accept backlog and reset the connection immediately afterwards —
    /// observed as `SO_ERROR [54: Connection reset by peer]`. That is
    /// indistinguishable from a live endpoint if the test stops at `.ready`, so
    /// these four outcomes are separated by what happens *after* the handshake.
    enum DialOutcome: Equatable {
        /// Refused outright, or accepted and immediately reset — the endpoint is
        /// not there.
        case refused
        /// Connected and stayed connected: an acceptor is holding the connection
        /// waiting for a first frame, which is what 11.3c has it do.
        case heldOpen
        /// 11.3c — closed, and not a byte came back.
        case closedWithoutReply
        /// Anything was sent back. ⚠ 11.3c forbids this for a first frame that is
        /// not a well-formed `bs_offer`.
        case replied(Data)
    }

    /// Dial `127.0.0.1:port`, optionally say something, and classify what happened.
    ///
    /// ⛔ **Every path resumes exactly once and nothing is left dangling.** The
    /// previous version raced an `NWConnection.receive` continuation against a
    /// sleeping task inside a `withTaskGroup`. When the acceptor legitimately
    /// held the connection open — which it does for an incomplete first frame —
    /// the receive callback never fired, and `withTaskGroup` implicitly awaits
    /// every child at scope exit, so the group never finished. `cancelAll()`
    /// cannot reach a continuation that ignores cancellation. That deadlocked the
    /// suite for 25 minutes and read as "still running", which is worse than a
    /// failure. The watchdog here **cancels the connection**, which makes the
    /// receive callback fire, rather than trying to out-race it.
    static func dial(port: UInt16,
                     saying bytes: Data? = nil,
                     settle: Duration = .milliseconds(400)) async -> DialOutcome {
        let connection = NWConnection(host: "127.0.0.1",
                                      port: NWEndpoint.Port(rawValue: port)!,
                                      using: .tcp)

        // Phase 1 — did the handshake complete at all?
        let ready = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ value: Bool) {
                let first = resumed.withLock { taken -> Bool in
                    if taken { return false }; taken = true; return true
                }
                if first { c.resume(returning: value) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                // ⚠ `.waiting` as well as `.failed`. A refused loopback port makes
                // `NWConnection` wait and retry rather than fail, so watching only
                // for `.failed` hangs on precisely the withdrawn case this suite
                // exists to assert.
                case .failed, .cancelled, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            Task { try? await Task.sleep(for: .seconds(3)); finish(false) }
        }
        guard ready else { connection.cancel(); return .refused }

        if let bytes {
            connection.send(content: bytes, completion: .contentProcessed { _ in })
        }

        // Phase 2 — reply, close, reset, or still there after `settle`.
        let outcome = await withCheckedContinuation { (c: CheckedContinuation<DialOutcome, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ value: DialOutcome) {
                let first = resumed.withLock { taken -> Bool in
                    if taken { return false }; taken = true; return true
                }
                if first { c.resume(returning: value) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                // A reset after a successful handshake — the backlog case.
                case .failed, .cancelled: finish(.refused)
                default: break
                }
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
                data, _, isComplete, error in
                if let data, data.isEmpty == false {
                    finish(.replied(data))
                } else if isComplete || error != nil {
                    finish(.closedWithoutReply)
                }
            }
            // ⛔ Cancels the connection rather than merely giving up on it, so the
            // receive callback above fires and no continuation is orphaned.
            Task {
                try? await Task.sleep(for: settle)
                finish(.heldOpen)
                connection.cancel()
            }
        }
        connection.cancel()
        return outcome
    }

    // MARK: - 3.7f — a distinct endpoint

    @Test("3.7f — the bootstrap endpoint is not the PPCP listener's")
    func endpointIsDistinct() async throws {
        let advertiser = try BootstrapAdvertiser()
        let opened = try await advertiser.open(on: Self.action(), label: nil,
                                               distinctFrom: 41234)
        #expect(opened.port != 41234)
        #expect(opened.port != 0)
        #expect(opened.instanceName.hasPrefix("PPCP-"))
        await advertiser.close(on: Self.action("close-the-window"))
    }

    @Test("3.7c — bn is fresh per window, so two windows differ")
    func windowIdIsFreshPerWindow() async throws {
        let advertiser = try BootstrapAdvertiser()
        let first = try await advertiser.open(on: Self.action(), label: nil,
                                              distinctFrom: nil)
        await advertiser.close(on: Self.action("close-the-window"))
        let second = try await advertiser.open(on: Self.action(), label: nil,
                                               distinctFrom: nil)
        #expect(first.instanceName != second.instanceName)
        await advertiser.close(on: Self.action("close-the-window"))
    }

    // MARK: - RT-22 — the instance is withdrawn when the window closes

    @Test("RT-22 — the endpoint answers while the window is open and not after")
    func withdrawnOnClose() async throws {
        let advertiser = try BootstrapAdvertiser()
        let opened = try await advertiser.open(on: Self.action(), label: nil,
                                               distinctFrom: nil)

        // Open: an acceptor is there and holds the connection for a first frame.
        let whileOpen = await Self.dial(port: opened.port)
        #expect(whileOpen == .heldOpen, "the bootstrap endpoint should answer while open")

        await advertiser.close(on: Self.action("close-the-window"))
        let window = await advertiser.window
        #expect(window.isOpen == false)
        // ⛔ 3.7d — the advertisement, and `bn` with it, is gone.
        #expect(window.advertisement == nil)

        // Closed. ⚠ **This is the secondary check, not 3.7b's claim.** 3.7b
        // withdraws the service INSTANCE, which is a DNS-SD property; what is
        // asserted here is the mechanism underneath it — `close(on:)` does not
        // return until the listener has actually cancelled, so the endpoint the
        // SRV record named is gone rather than merely on its way out. The record
        // itself is not observed here; see the note at the top of this file.
        let afterClose = await Self.dial(port: opened.port)
        #expect(afterClose == .refused, "the endpoint should be gone once withdrawn")
    }

    // MARK: - 11.3c — the first frame

    @Test("11.3c — a PPCP frame on the bootstrap endpoint is closed without reply")
    func ppcpFrameIsRefusedWithoutReply() async throws {
        let advertiser = try BootstrapAdvertiser()
        let opened = try await advertiser.open(on: Self.action(), label: nil,
                                               distinctFrom: nil)

        // Channel 0 with a plausible CBOR map — a PPCP peer that dialled the
        // wrong port. 3.7f exists so neither end has to guess.
        let reply = await Self.dial(port: opened.port,
                                    saying: Self.frame(channel: 0,
                                                       payload: Data([0xA1, 0x01, 0x01])))
        #expect(reply == .closedWithoutReply, "11.3c requires no reply at all")
        await advertiser.close(on: Self.action("close-the-window"))
    }

    @Test("11.3c — with no decoder, even a well-formed envelope is refused")
    func envelopeWithoutADecoderIsRefused() async throws {
        let advertiser = try BootstrapAdvertiser()
        let opened = try await advertiser.open(on: Self.action(), label: nil,
                                               distinctFrom: nil)
        // Channel 255, complete, and still not a `bs_offer` as far as this build
        // can tell — because nothing here decodes one. Refusing is correct.
        let reply = await Self.dial(port: opened.port,
                                    saying: Self.frame(channel: 255,
                                                       payload: Data([0xA2, 0x61, 0x76, 0x01])))
        #expect(reply == .closedWithoutReply)
        await advertiser.close(on: Self.action("close-the-window"))
    }

    // MARK: - The reading of 11.9a this implementation took, made visible

    @Test("A refused dial does NOT close the window — otherwise anyone shuts it")
    func aRefusedDialLeavesTheWindowOpen() async throws {
        let advertiser = try BootstrapAdvertiser()
        let opened = try await advertiser.open(on: Self.action(), label: nil,
                                               distinctFrom: nil)

        // ⚠ This is the assertion behind the finding reported with D10. Read so
        // that any arriving connection is an "attempt", 11.9a's "a malformed
        // frame, a closed connection" would close the window here — and 11.9b
        // would then refuse to reopen it without a further user action, so one
        // stranger on the link ends the user's pairing.
        for channel: UInt8 in [0, 1, 255] {
            _ = await Self.dial(port: opened.port,
                                saying: Self.frame(channel: channel, payload: Data([0xA1])))
        }
        _ = await Self.dial(port: opened.port, saying: Data([0xFF, 0xFF, 0xFF]))

        let window = await advertiser.window
        #expect(window.isOpen, "a stranger's junk must not close the user's window")
        #expect(window.attemptInProgress == false, "and must not start an attempt")

        // And the endpoint still answers.
        let stillThere = await Self.dial(port: opened.port)
        #expect(stillThere == .heldOpen)
        await advertiser.close(on: Self.action("close-the-window"))
    }

    // MARK: - 11.9b

    @Test("11.9b — closing withdraws, and nothing reopens it on its own")
    func doesNotReopenItself() async throws {
        let advertiser = try BootstrapAdvertiser()
        let opened = try await advertiser.open(on: Self.action(), label: nil,
                                               distinctFrom: nil)
        await advertiser.close(on: Self.action("close-the-window"))

        // Give anything that might restart a listener a chance to do so.
        try await Task.sleep(for: .milliseconds(300))
        let afterWaiting = await Self.dial(port: opened.port)
        #expect(afterWaiting == .refused, "nothing may re-register without a user action")
        let window = await advertiser.window
        #expect(window.isOpen == false)
    }
}
