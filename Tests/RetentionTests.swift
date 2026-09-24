//  RetentionTests.swift
//  #122 — nothing stays on the phone longer than the session and the shot.
//
//  ⚠ What a simulator can reach: the hostless arm with the stub camera (the path
//  `CapturePathAppTests` already drives), which opens a real session folder on
//  disk. The hosted half — deleting a clip once the host confirms or declines
//  it, and the drain after the host's Stop — is `ShotDispositionAppTests`, on
//  every run against an in-process host, and `DeviceSessionTests` against the
//  real PinPointStudio.

import Foundation
import Testing
import CaptureCore
@testable import PinPointCapture

@Suite("#122 — nothing kept on the phone past its session")
@MainActor
struct RetentionTests {

    private func model() -> (AppModel, URL) {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                 isDirectory: true)
        let model = AppModel(device: StubCaptureDevice(), store: SessionStore(root: root))
        model.refreshCapability()
        // ⚠ A simulator never grants these, and `warmUp` gates on them.
        model.permissions = Permissions(camera: .allowed, microphone: .allowed,
                                        localNetwork: .allowed, motion: .allowed)
        return (model, root)
    }

    private func children(of root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    @Test("A session writes into a folder of its own, and disarming deletes it")
    func disarmDeletesTheSession() async throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }

        await model.arm()
        let recording = try #require(model.recording, "the stub arm opened no session")
        // ⛔ One folder per arm: a hosted session's bundle is named from the
        // host's id, so two arms in one host session used to share — and
        // truncate — one folder.
        let folder = recording.bundle.directory.deletingLastPathComponent()
        #expect(folder.lastPathComponent.hasPrefix("arm-"))
        #expect(model.bundlesOnDevice().count == 1)

        model.disarm()

        #expect(model.recording == nil)
        #expect(model.bundlesOnDevice().isEmpty, "the session outlived its disarm")
        #expect(children(of: root).isEmpty, "\(children(of: root))")
    }

    @Test("The sweep deletes what an earlier run left, and never the live session")
    func sweepSparesTheLiveSession() async throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }

        // An older build's layout (a bundle straight under the root) and an arm
        // folder a crash left behind.
        let legacy = root.appendingPathComponent("peer:old~ses:old", isDirectory: true)
        let orphan = root.appendingPathComponent("arm-orphan", isDirectory: true)
        for folder in [legacy, orphan] {
            try FileManager.default.createDirectory(at: folder,
                                                    withIntermediateDirectories: true)
        }

        await model.arm()
        let live = try #require(model.recording).bundle.directory
            .deletingLastPathComponent().lastPathComponent

        model.sweepLeftovers()

        #expect(children(of: root) == [live], "\(children(of: root))")
        model.disarm()
        #expect(children(of: root).isEmpty)
    }

    @Test("A sweep with nothing live empties the store")
    func sweepEmptiesTheStore() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("arm-orphan/peer:x~ses:x/clips", isDirectory: true),
            withIntermediateDirectories: true)

        model.sweepLeftovers()

        #expect(children(of: root).isEmpty)
        #expect(model.bundlesOnDevice().isEmpty)
    }
}
