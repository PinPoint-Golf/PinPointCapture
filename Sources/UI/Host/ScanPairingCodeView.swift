//
//  ScanPairingCodeView.swift
//  B1a — Scan the code on the Studio screen.
//
//  ⚠ **Three failures, three sentences**, because `PPCP-RV` makes them three
//  different things a user can act on:
//
//   - 4.2b — "This code needs a newer version of PinPoint Capture." ⛔ Never
//     "could not pair": the version marker exists precisely so the application
//     can say which end is stale.
//   - 4.4b — "That is not a PinPoint pairing code." No connection is attempted.
//   - 4.4a — "This code has expired." And, when the clock cannot be trusted
//     (4.4a1), "This code may have expired" — with the pairing attempted anyway,
//     because the host holds the authoritative clock.
//
//  ⛔ **No native dialogs.** The camera scanner is in-screen and the paste field
//  is beside it, for a simulator and for a code that arrives as a link. There is
//  no document picker anywhere in this application.
//
//  ⛔ **This screen says NOTHING about remembering the Studio, in either
//  direction, and that is deliberate** (#96, 25 August 2026). It carried a
//  *Remember this Studio* toggle until then, and the toggle could not be honest:
//  at the moment it is shown the code has not been decoded, so `mu` is unknown,
//  and 7.4f may yet forbid keeping the pairing at all. A promise made before the
//  scan is a promise the scan can invalidate. The sentence moved to B2, where the
//  pairing exists and `mu` has been read — and where it is a statement of what
//  happened rather than an offer.
//
//  ⚠ **`dn` is untrusted display text** (4.4d): it is shown before anything has
//  been authenticated, so it is escaped and truncated by `PpcpPairingCode` and is
//  never used as an identifier or a trust signal. The screen says "the code says"
//  rather than presenting it as a fact.
//
//  Spec: `RV` §4.1, §4.2, §4.4, §6, §7.4. Plan D7.

import SwiftUI
import AVFoundation
import CaptureCore

public struct ScanPairingCodeView: View {

    /// What the scanner or the field produced.
    private let onCode: (String) -> Void
    private let onCancel: () -> Void
    /// The failure to show, if a previous attempt produced one.
    private let failure: Failure?
    @State private var typed = ""
    @State private var cameraAuthorised = AVCaptureDevice
        .authorizationStatus(for: .video) == .authorized

    /// The three sentences of `RV` §4, plus the network one.
    public enum Failure: Sendable, Hashable {
        case needsANewerApplication
        case invalidCode
        case expired
        case possiblyExpired
        case couldNotJoinNetwork(String)
        case noEndpointReachable(triedCount: Int)
        /// ⛔ The host answered and would not accept the code. A different
        /// sentence from ``noEndpointReachable`` because it is a different problem
        /// with a different remedy — and telling someone their host is unreachable
        /// when it answered sends them to debug a working network.
        case hostRefusedTheCode

        var title: String {
            switch self {
            case .needsANewerApplication: "This code needs a newer app"
            case .invalidCode: "That is not a PinPoint pairing code"
            case .expired: "This code has expired"
            case .possiblyExpired: "This code may have expired"
            case .couldNotJoinNetwork: "Could not join that network"
            case .noEndpointReachable: "Could not reach the host"
            case .hostRefusedTheCode: "Studio would not accept this code"
            }
        }

        var detail: String {
            switch self {
            case .needsANewerApplication:
                "Update PinPoint Capture from the App Store, then scan it again."
            case .invalidCode:
                "Scan the square code shown on the Studio screen."
            case .expired:
                "Ask Studio for a new code — they expire so a photograph of one "
                + "cannot be used later."
            case .possiblyExpired:
                // 4.4a1 — attempted anyway, and the user is told why.
                "This device's clock may be wrong, so we tried anyway. Studio will "
                + "refuse it if the code really has expired."
            case .couldNotJoinNetwork:
                "The network in the code could not be joined. Join it in Settings "
                + "and scan again, or stay on this Wi-Fi and try the cable."
            case .noEndpointReachable(let count):
                "Tried \(count) address\(count == 1 ? "" : "es") from the code and "
                + "none answered. Check Studio is running and on this network."
            case .hostRefusedTheCode:
                // ⚠ Names the likely cause and the remedy, and says the network is
                // fine — because the failure this replaced sent people to check it.
                "Studio is running and this device reached it — it refused the "
                + "code. That usually means the code has already been used, or it "
                + "expired. Ask Studio for a new one."
            }
        }
    }

    public init(failure: Failure? = nil,
                onCode: @escaping (String) -> Void,
                onCancel: @escaping () -> Void) {
        self.failure = failure
        self.onCode = onCode
        self.onCancel = onCancel
    }

    public var body: some View {
        List {
            if let failure {
                Section {
                    VStack(alignment: .leading, spacing: PPMetrics.itemGap / 2) {
                        Text(failure.title)
                            .font(.ppRowLabel.weight(.semibold))
                            .foregroundStyle(Color(.label))
                        Text(failure.detail)
                            .font(.ppSupporting)
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                if cameraAuthorised {
                    PairingCodeScannerView(onCode: onCode)
                        // ⚠ Square, from the row width — a QR reticle is square,
                        // and the width is the dimension a List row knows.
                        // `containerRelativeFrame(.vertical)` resolves against the
                        // row here, not the screen, and collapses it.
                        .aspectRatio(1.0, contentMode: .fit)
                        .frame(maxHeight: 380)
                        // ⚠ Centred once the ceiling bites, so a wide screen does not
                        // leave it hanging off the leading edge.
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.Radius.card))
                        .listRowInsets(EdgeInsets(top: 0, leading: PPMetrics.screenMargin,
                                                  bottom: 0, trailing: PPMetrics.screenMargin))
                } else {
                    InfoCard("Camera access is needed to scan. You can paste the code "
                             + "below instead.", title: "No camera")
                }
            } header: {
                EyebrowLabel("Point at the code on the Studio screen")
            }

            // ⚠ In-screen, not a dialog. A simulator has no camera and a code
            // sometimes arrives as a link.
            Section {
                TextField("ppcp:…", text: $typed, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
                Button("Use this code") { onCode(typed) }
                    .disabled(typed.isEmpty)
            } header: {
                EyebrowLabel("Or paste it")
            }

        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("Scan the pairing code")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.primaryButton)
                .padding(.horizontal, PPMetrics.screenMargin)
                .padding(.top, PPMetrics.itemGap)
                .background(.bar)
        }
        .task {
            guard cameraAuthorised == false else { return }
            cameraAuthorised = await AVCaptureDevice.requestAccess(for: .video)
        }
    }
}

// MARK: - The scanner

/// The QR reader, in-screen.
///
/// ⛔ **`AVFoundation` appears here and nowhere above.** It is a UI file rather
/// than a `Platform/` one because it is a *view*: what leaves it is a `String`,
/// and `AVCaptureSession` never becomes reachable from a view model (REQ-PORT-3).
struct PairingCodeScannerView: UIViewControllerRepresentable {

    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return controller }
        session.addInput(input)

        // ⚠ Force continuous AF/AE/WB explicitly rather than trusting whatever
        // mode the physical device is already in. The same physical back camera
        // is often still `.locked` by the main capture screen's warm
        // `AVFoundationCaptureDevice` (REQ-OPT-2/3/4) — a SwiftUI sheet doesn't
        // remove the presenting screen from the hierarchy, so that warm, locked
        // session keeps running underneath this one. A locked device can never
        // focus on a QR code held at an arbitrary distance. Not restored on
        // teardown: the next real `warmUp()` unconditionally re-locks from
        // scratch, so any change made here is transient and self-healing.
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        }

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return controller }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
        // ⚠ QR only. `RV` 4.1d asks for error-correction level M or higher, which
        // is the publisher's business; what matters here is that nothing else is
        // scanned, so a barcode on a golf glove cannot become a pairing attempt.
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = controller.view.bounds
        controller.view.layer.addSublayer(preview)
        context.coordinator.preview = preview
        context.coordinator.session = session

        // ⚠ `startRunning()` blocks, so it must not run on the main actor — and
        // the session cannot be captured by a `Task.detached` closure without
        // crossing an isolation boundary Swift 6 refuses. A plain dispatch to a
        // background queue is what this is: no isolation to cross, and the object
        // is `AVCaptureSession`, which Apple documents as safe to configure and
        // start off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.preview?.frame = controller.view.bounds
    }

    static func dismantleUIViewController(_ controller: UIViewController,
                                          coordinator: Coordinator) {
        coordinator.session?.stopRunning()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCode: (String) -> Void
        var preview: AVCaptureVideoPreviewLayer?
        var session: AVCaptureSession?
        /// ⛔ One code per presentation. A scanner that fired on every frame would
        /// start a second pairing while the first was still dialling.
        private var delivered = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard delivered == false,
                  let object = objects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }
            delivered = true
            session?.stopRunning()
            onCode(value)
        }
    }
}

#Preview("B1a · Scan the pairing code") {
    NavigationStack {
        ScanPairingCodeView(failure: .needsANewerApplication,
                            onCode: { _ in }, onCancel: {})
    }
    .preferredColorScheme(.dark)
}
