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
//  ⛔ **These dial 127.0.0.1 rather than browsing.** RT-22 says "the instance is
//  withdrawn when the window closes"; observing that with an `NWBrowser` would
//  need the local-network permission, which an unattended test cannot grant, and
//  discovery on a real network is deliberately held back to #66 where a phone can
//  answer it. What is asserted here is the mechanism underneath the withdrawal —
//  the listener is cancelled, so the endpoint the SRV record named stops
//  answering — and that is checkable without a responder and without a prompt.
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

    /// Dial the bootstrap endpoint, optionally say something, and report what
    /// came back.
    ///
    /// - Returns: `.none` where the connection could not be made at all — which
    ///   is what a withdrawn instance's port gives — and otherwise `.some(reply)`,
    ///   where 11.3c requires `reply` to be `nil`: closed, without a byte.
    static func dial(port: UInt16, saying bytes: Data?) async -> Data?? {
        let connection = NWConnection(host: "127.0.0.1",
                                      port: NWEndpoint.Port(rawValue: port)!,
                                      using: .tcp)
        let ready = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let done = OSAllocatedUnfairLock(initialState: false)
            connection.stateUpdateHandler = { state in
                let outcome: Bool?
                switch state {
                case .ready:
                    outcome = true
                // ⚠ `.waiting` and not only `.failed`. A refused loopback port
                // makes `NWConnection` WAIT and retry rather than fail, so a test
                // that watched only for `.failed` would hang on exactly the case
                // it exists to assert — the withdrawn instance.
                case .failed, .cancelled, .waiting:
                    outcome = false
                default:
                    outcome = nil
                }
                guard let outcome else { return }
                let first = done.withLock { taken -> Bool in
                    if taken { return false }; taken = true; return true
                }
                if first { c.resume(returning: outcome) }
            }
            connection.start(queue: .global())
        }
        guard ready else { connection.cancel(); return .none }

        // ⚠ Nothing sent means nothing to wait for: the acceptor is entitled to
        // hold the connection open waiting for a first frame, so waiting for a
        // reply here would hang. Connectivity is the whole assertion.
        guard let bytes else { connection.cancel(); return .some(nil) }

        connection.send(content: bytes, completion: .contentProcessed { _ in })

        // 11.3c — "closes the connection without reply". The expected outcome is
        // end-of-stream carrying nothing, not a `bs_abort`.
        let reply: Data? = await withTaskGroup(of: Data??.self) { group in
            group.addTask {
                await withCheckedContinuation { (c: CheckedContinuation<Data??, Never>) in
                    let done = OSAllocatedUnfairLock(initialState: false)
                    connection.receive(minimumIncompleteLength: 1,
                                       maximumLength: 4096) { data, _, _, _ in
                        let first = done.withLock { taken -> Bool in
                            if taken { return false }; taken = true; return true
                        }
                        if first { c.resume(returning: .some(data)) }
                    }
                }
            }
            // ⚠ A bound, so a far end that neither replies nor closes fails the
            // test rather than hanging the suite.
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return Data??.none
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? Data([0xDE, 0xAD])   // timed out: a non-empty "reply"
        }
        connection.cancel()
        return .some(reply)
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

        // Open: the endpoint the SRV record names accepts a connection.
        let whileOpen = await Self.dial(port: opened.port, saying: nil)
        #expect(whileOpen != .none, "the bootstrap endpoint should answer while open")

        await advertiser.close(on: Self.action("close-the-window"))
        let window = await advertiser.window
        #expect(window.isOpen == false)
        // ⛔ 3.7d — the advertisement, and `bn` with it, is gone.
        #expect(window.advertisement == nil)

        // Closed: the listener is cancelled, so the instance is deregistered and
        // the port stops answering.
        let afterClose = await Self.dial(port: opened.port, saying: nil)
        #expect(afterClose == .none, "the endpoint should be gone once withdrawn")
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
        #expect(reply == .some(nil), "11.3c requires no reply at all")
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
        #expect(reply == .some(nil))
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
        let stillThere = await Self.dial(port: opened.port, saying: nil)
        #expect(stillThere != .none)
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
        let afterWaiting = await Self.dial(port: opened.port, saying: nil)
        #expect(afterWaiting == .none, "nothing may re-register without a user action")
        let window = await advertiser.window
        #expect(window.isOpen == false)
    }
}
