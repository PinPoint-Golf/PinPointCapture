//  PpcpDirectTransport.swift
//  `PPCP-RV` §2's **direct** path: a plaintext TCP link, for the conformance
//  harness and for nothing else.
//
//  ⛔ **THE WHOLE FILE IS `#if DEBUG` AND MUST STAY THAT WAY.** `RV` 5.2f forbids
//  a plaintext fallback on a rendezvous path, including on user instruction, and
//  `PpcpTransport.swift` has no plaintext branch by construction. This is not a
//  fallback and there is no path from a scanned code, a discovered peer or a
//  saved pairing to it: the only caller is `ConformanceHarness`, which is itself
//  `#if DEBUG`, and a release build contains neither.
//
//  ⚠ **Why it exists, and why it is conformant.** `RV` 9a: "a peer connecting
//  only over a tunnel, or handed an established socket, is fully PPCP-conformant
//  with no rendezvous implementation". `CONF` §2c requires a software peer
//  simulator that both sides develop against, and `libppcp`'s `ppcp-sim` speaks
//  plaintext TCP deliberately — "a simulator that spoke TLS would be testing
//  OpenSSL rather than PPCP". The alternative was measured and is closed: Apple's
//  `Network.framework` cannot negotiate a TLS 1.3 external PSK at all, so the
//  simulator's other mode is unreachable from this platform (F-D1-1, F-D6-4).
//
//  ⚠ **A separate channel type rather than `PpcpByteChannel` with TLS switched
//  off.** `PpcpByteChannel.open` refuses a ready connection that carries no TLS
//  metadata, and that refusal is how 5.2f is held by shape rather than by a
//  reviewer noticing. Adding a parameter to it would put a plaintext branch
//  inside the file that must not have one; a second type in a file that compiles
//  out of the product does not.
//
//  ⛔ **A finding, not a licence — see F-D9-1 in `docs/ppcp-conformance.md`.**
//  `RV` 2c is a MUST that the direct path completes the §5 handshake, and this
//  does not. The resolution is that this build's peer does not claim `PPCP-RV`
//  conformance on this link — 9a permits that — and the reason it has to be
//  written down is that the same document makes RV optional in one clause and
//  requires TLS on every path in another.
//
//  Spec: `RV` §2, §9a; `ENC` §2.1; `CONF` §2c. Plan D9.

#if DEBUG

import Foundation
import Network
import Synchronization
import CaptureCore

// MARK: - A plaintext channel

/// One plaintext `NWConnection` presented as a `ByteChannel`.
///
/// ⚠ It carries the same cancellation discipline as `PpcpByteChannel`, and for
/// the same reason: `Network.framework` has no per-call cancel, so an `await`
/// that ignores cancellation makes a structured timeout around it not a slow
/// timeout but no timeout at all (see the note at the end of
/// `docs/ppcp-conformance.md`).
final class PpcpDirectChannel: ByteChannel, @unchecked Sendable {

    let channel: PpcpChannel
    private let connection: NWConnection
    private let closed = Mutex<ChannelCloseReason?>(nil)

    init(connection: NWConnection, channel: PpcpChannel) {
        self.connection = connection
        self.channel = channel
    }

    func send(_ bytes: Data) async throws {
        if let reason = closed.withLock({ $0 }) {
            throw TransportError.channelClosed(reason)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: TransportError.channelClosed(
                            .failed(PpcpByteChannel.describe(error))))
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: { connection.cancel() }
    }

    func receive() async throws -> Data? {
        if let reason = closed.withLock({ $0 }) {
            throw TransportError.channelClosed(reason)
        }
        while true {
            typealias Arrival = CheckedContinuation<(Data?, Bool), any Error>
            let arrival = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: Arrival) in
                    connection.receive(minimumIncompleteLength: 1,
                                       maximumLength: 65_536) { data, _, isComplete, error in
                        if let error {
                            continuation.resume(throwing: TransportError.channelClosed(
                                .failed(PpcpByteChannel.describe(error))))
                        } else {
                            continuation.resume(returning: (data, isComplete))
                        }
                    }
                }
            } onCancel: { connection.cancel() }
            if let data = arrival.0, data.isEmpty == false { return data }
            if arrival.1 {
                closed.withLock { if $0 == nil { $0 = .peerClosed } }
                return nil
            }
        }
    }

    func close(_ reason: ChannelCloseReason) async {
        closed.withLock { if $0 == nil { $0 = reason } }
        connection.cancel()
    }

    /// Dial and return once the socket is up. ⛔ There is no handshake to wait
    /// for and the type says so — `NegotiatedSecurity.directPathPlaintext`
    /// reports "no TLS, none — no forward secrecy" rather than an unknown mode.
    static func open(host: String, port: UInt16, channel: PpcpChannel,
                     on queue: DispatchQueue) async throws -> PpcpDirectChannel {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.endpointUnreachable("port")
        }
        // ⚠ `.tcp` with no TLS options at all, rather than options with security
        // disabled: there is no object here that could be misconfigured back on.
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let resumed = Mutex(false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                connection.stateUpdateHandler = { state in
                    let outcome: Result<Void, any Error>?
                    switch state {
                    case .ready: outcome = .success(())
                    case .failed(let error):
                        outcome = .failure(TransportError.endpointUnreachable(
                            PpcpByteChannel.describe(error)))
                    case .waiting(let error):
                        outcome = .failure(TransportError.endpointUnreachable(
                            PpcpByteChannel.describe(error)))
                    case .cancelled:
                        outcome = .failure(TransportError.channelClosed(.cancelled))
                    default: outcome = nil
                    }
                    // ⚠ Resume exactly once: the state handler fires many times
                    // and a second resume traps.
                    guard let outcome,
                          resumed.withLock({ taken -> Bool in
                              if taken { return false }
                              taken = true
                              return true
                          }) else { return }
                    continuation.resume(with: outcome)
                }
                connection.start(queue: queue)
            }
        } onCancel: { connection.cancel() }
        return PpcpDirectChannel(connection: connection, channel: channel)
    }
}

// MARK: - Dialling the direct path

/// Dials a plaintext link, `link_bind` first on every stream.
///
/// ⚠ **The `ENC` §2.1 bind is not skipped because the transport is plaintext.**
/// 2.1a makes `link_bind` the first frame of *every* stream whatever carries it,
/// and the counterpart — `ppcp-sim` — refuses a first frame that is not one. That
/// is the point: the harness exercises the same bind the TLS path does, over a
/// transport a simulator can speak.
struct PpcpDirectConnector: PeerTransportConnector {

    private let queue = DispatchQueue(label: "org.pinpointstudio.capture.ppcp.direct")

    /// ⛔ `credentials` is ignored, and the parameter stays because the protocol
    /// is the port surface. Passing a key to a plaintext dial and having it used
    /// would be worse than passing one and having it visibly not be.
    func connect(to endpoint: PeerEndpoint,
                 credentials: any PpcpCredentials,
                 channels: [PpcpChannel] = PpcpChannel.required) async throws
        -> any PeerTransport {
        try await connect(to: endpoint, channels: channels)
    }

    func connect(to endpoint: PeerEndpoint,
                 channels: [PpcpChannel] = PpcpChannel.required) async throws
        -> any PeerTransport {
        // 2.1a — one `link_id` for the whole link, minted by the dialler.
        let linkId = try PpcpLinkIdSource.mint()
        var opened: [PpcpChannel: PpcpDirectChannel] = [:]
        do {
            // ⚠ **Sequential, unlike the TLS path.** `ppcp-sim` accepts its two
            // connections one after the other and expects the first to be the one
            // it reads first; a concurrent dial is a race the simulator has no
            // reason to tolerate, and the time saved is time nobody is waiting.
            for channel in channels {
                let stream = try await PpcpDirectChannel.open(
                    host: endpoint.host, port: endpoint.port, channel: channel, on: queue)
                try await stream.send(PpcpLinkBind.frame(linkId: linkId, channel: channel))
                opened[channel] = stream
            }
        } catch {
            for stream in opened.values { await stream.close(.cancelled) }
            throw error
        }
        // ⛔ `dial: nil` — the direct path opens no further stream. 2.1d lets a
        // dialler add a `preview` channel later; the harness has no preview to
        // send and a dialler that could would be untested code in a debug build.
        var assembled: [PpcpChannel: any ByteChannel] = [:]
        for (channel, stream) in opened { assembled[channel] = stream }
        return try PpcpPeerLink.assemble(linkId: linkId, channels: assembled,
                                         security: .directPathPlaintext,
                                         dial: nil)
    }
}

#endif
