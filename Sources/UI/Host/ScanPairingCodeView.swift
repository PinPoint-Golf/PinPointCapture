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
    /// 7.4b — offered only where 7.4f permits it.
    private let mayPersist: Bool
    @Binding private var persistPairing: Bool

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

        var title: String {
            switch self {
            case .needsANewerApplication: "This code needs a newer app"
            case .invalidCode: "That is not a PinPoint pairing code"
            case .expired: "This code has expired"
            case .possiblyExpired: "This code may have expired"
            case .couldNotJoinNetwork: "Could not join that network"
            case .noEndpointReachable: "Could not reach the host"
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
            }
        }
    }

    public init(failure: Failure? = nil,
                mayPersist: Bool = false,
                persistPairing: Binding<Bool> = .constant(false),
                onCode: @escaping (String) -> Void,
                onCancel: @escaping () -> Void) {
        self.failure = failure
        self.mayPersist = mayPersist
        _persistPairing = persistPairing
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
                        .frame(height: 260)
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

            if mayPersist {
                Section {
                    Toggle("Remember this Studio", isOn: $persistPairing)
                } footer: {
                    // 7.4b — visible, and the cost stated rather than assumed away
                    // (§7.4's own words).
                    Text("Reconnects next time without a new code. Anyone with this "
                         + "phone's storage keeps that access until you remove it, "
                         + "which you can do at any time in Settings.")
                }
            } else {
                Section {
                    // ⛔ 7.4f. The offer itself would be a lie for a multi-use code.
                    Text("This code can pair several devices, so the connection lasts "
                         + "for this session only.")
                        .font(.ppSupporting)
                        .foregroundStyle(Color(.secondaryLabel))
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
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
                            mayPersist: true,
                            onCode: { _ in }, onCancel: {})
    }
    .preferredColorScheme(.dark)
}
