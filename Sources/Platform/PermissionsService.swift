//  PermissionsService.swift
//  Platform permission acquisition, reduced to the neutral readiness state the
//  rest of the app consumes.
//
//  ⚠ REQ-PORT-13: permission acquisition and its failure handling stay in the
//  platform layer. Core and UI see `Permissions`, never an
//  `AVAuthorizationStatus`, because the permission models differ materially
//  between platforms and that difference must not reach a view model.

import AVFoundation
import Foundation

public struct PermissionsService: Sendable {

    public init() {}

    /// Read what the platform will tell us.
    ///
    /// ⚠ Local network is **absent from this** on purpose. iOS exposes no API to
    /// read it back (REQ-DISC-6), so it is inferred from a failed connection and
    /// carried separately — see `inferredLocalNetwork(after:)`.
    public func current(localNetwork: PermissionState = .unknown) -> Permissions {
        Permissions(
            camera: Self.map(AVCaptureDevice.authorizationStatus(for: .video)),
            microphone: Self.microphoneState(),
            localNetwork: localNetwork,
            // Device motion and attitude need no authorisation; only activity and
            // pedometer data do, and this app wants neither (REQ-META-1).
            motion: .allowed
        )
    }

    public func requestCamera() async -> PermissionState {
        await AVCaptureDevice.requestAccess(for: .video) ? .allowed : .denied
    }

    public func requestMicrophone() async -> PermissionState {
        await AVAudioApplication.requestRecordPermission() ? .allowed : .denied
    }

    /// ⛔ The only honest way to learn about local network permission on iOS.
    ///
    /// There is no API to query it, and a single "Don't Allow" makes the app look
    /// permanently broken. A connection that fails without ever reaching the host
    /// is the evidence, and B6 is what the user sees — not a generic error.
    public func inferredLocalNetwork(afterConnectionFailure failed: Bool) -> PermissionState {
        failed ? .denied : .unknown
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .allowed
        case .denied, .restricted: .denied
        case .notDetermined: .notRequested
        @unknown default: .notRequested
        }
    }

    private static func microphoneState() -> PermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .allowed
        case .denied: .denied
        case .undetermined: .notRequested
        @unknown default: .notRequested
        }
    }
}
