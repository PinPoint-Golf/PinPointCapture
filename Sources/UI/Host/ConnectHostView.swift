//
//  ConnectHostView.swift
//  B1 — Connect a host.
//
//  ⚠ The QR reticle **is** the screen, not a fallback. The camera is live on
//  entry (REQ-DISC-2) and scanning is the first thing the user sees.
//
//  The three rows underneath are in **descending order of reliability**:
//
//    1. a discovered host  — convenience only, for reconnection (REQ-DISC-1/3).
//       Multicast fails on many consumer access points, so mDNS is never the
//       path a first pairing depends on.
//    2. a typed six-digit code — works wherever the two devices can route.
//    3. a cable — steadier timing, no network at all.
//
//  Every path completes discovery, pairing and authentication in one action
//  (REQ-AUTH-2).
//
//  ⚠ `AVFoundation` appears here, and the reason is the same one that permits it
//  in `ScanPairingCodeView`: this is a *view*, what leaves it is a `String`, and
//  `AVCaptureSession` never becomes reachable from a view model (REQ-PORT-3).
//  The capture stack is still untouched from here — a QR reader is not a capture
//  device, and this screen must never open one.
//

import AVFoundation
import SwiftUI
import CaptureCore

public struct ConnectHostView: View {

    /// A host already known on this network, or `nil` when nothing has been
    /// discovered. mDNS is a convenience for reconnection, never the primary
    /// path — the row is simply absent when there is nothing to show.
    private let discoveredHostName: String?
    /// "On this network · paired yesterday".
    private let discoveredHostDetail: String?

    private let onCancel: () -> Void
    private let onConnectToDiscoveredHost: () -> Void
    private let onEnterCode: () -> Void
    /// ⛔ B3a, reached from here as well as from the host panel. This is where a
    /// golfer arrives when the Studio they expected has not appeared — so it is
    /// where the list of the ones this phone holds belongs. `nil` where nothing
    /// is held: a list of nothing is not a destination.
    private let onOpenRememberedStudios: (() -> Void)?
    /// A code read by the reticle. ⚠ Same handler B1a uses — one rendezvous walk,
    /// not two.
    private let onCode: (String) -> Void
    private let onUseCable: () -> Void
    private let onCaptureWithoutHost: () -> Void

    public init(
        discoveredHostName: String? = nil,
        discoveredHostDetail: String? = nil,
        onCancel: @escaping () -> Void,
        onConnectToDiscoveredHost: @escaping () -> Void = {},
        onEnterCode: @escaping () -> Void,
        onOpenRememberedStudios: (() -> Void)? = nil,
        onCode: @escaping (String) -> Void = { _ in },
        onUseCable: @escaping () -> Void,
        onCaptureWithoutHost: @escaping () -> Void
    ) {
        self.discoveredHostName = discoveredHostName
        self.discoveredHostDetail = discoveredHostDetail
        self.onCancel = onCancel
        self.onConnectToDiscoveredHost = onConnectToDiscoveredHost
        self.onEnterCode = onEnterCode
        self.onOpenRememberedStudios = onOpenRememberedStudios
        self.onCode = onCode
        self.onUseCable = onUseCable
        self.onCaptureWithoutHost = onCaptureWithoutHost
    }

    /// ⚠ Read once at init and refreshed by the `.task`. There is no API to be
    /// told about a change, so the screen asks and then shows what it got.
    @State private var cameraAuthorised = AVCaptureDevice
        .authorizationStatus(for: .video) == .authorized

    public var body: some View {
        List {
            Section {
                scannerArea
                instruction
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: PPMetrics.itemGap,
                                      leading: PPMetrics.screenMargin,
                                      bottom: PPMetrics.itemGap,
                                      trailing: PPMetrics.screenMargin))

            Section {
                if let discoveredHostName {
                    discoveredHostRow(name: discoveredHostName,
                                      detail: discoveredHostDetail)
                }
                HostDisclosureRow(
                    title: "Enter the six-digit code",
                    systemImage: "number.square",
                    action: onEnterCode
                )
                HostDisclosureRow(
                    title: "Use a cable instead",
                    detail: "Steadier timing, no network at all",
                    systemImage: "cable.connector",
                    action: onUseCable
                )
                if let onOpenRememberedStudios {
                    HostDisclosureRow(
                        title: "Remembered Studios",
                        detail: "The ones this phone can reconnect to",
                        systemImage: "clock.arrow.circlepath",
                        action: onOpenRememberedStudios
                    )
                }
            }

            Section {
                // A plain green text action: `.borderless` so it inherits the
                // app accent rather than being tinted by hand.
                Button("Capture without a host", action: onCaptureWithoutHost)
                    .buttonStyle(.borderless)
                    .font(.ppRowLabel.weight(.semibold))
                    .frame(maxWidth: .infinity,
                           minHeight: PPMetrics.Size.minimumTapTarget)
                    .accessibilityHint(Text("Capture on this device only. "
                                            + "You can send to Studio later."))
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("Connect a host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
        }
    }

    // MARK: - The scanner

    /// ⛔ **The camera is live on entry, which is what REQ-DISC-2 actually asks
    /// for.** This was a dashed box captioned "Camera preview" — so the screen
    /// whose own header says "the QR reticle **is** the screen" showed no camera
    /// at all, and read as a broken one. The scanner it now uses is the same
    /// `PairingCodeScannerView` B1a has always used, ninety lines away in this
    /// directory.
    private var scannerArea: some View {
        ZStack {
            if cameraAuthorised {
                PairingCodeScannerView(onCode: onCode)
                    .clipShape(RoundedRectangle(cornerRadius: PPMetrics.Radius.card,
                                                style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: PPMetrics.Radius.card, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .overlay {
                        Text("The camera is not available")
                            .font(.ppFootnote)
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
            }

            // Four accent corner brackets — the reticle. Not a full rectangle:
            // the code has to be *seen*, so the frame stays out of the way.
            QRReticle()
                .stroke(Color.ppAccent,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .padding(PPMetrics.cardPadding)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(Text("Camera viewfinder"))
        .accessibilityValue(Text("Point the camera at the pairing code shown "
                                 + "in PinPoint Studio."))
        .task {
            guard cameraAuthorised == false else { return }
            cameraAuthorised = await AVCaptureDevice.requestAccess(for: .video)
        }
    }

    private var instruction: some View {
        // One literal, so it stays a `LocalizedStringKey` and the markdown bold
        // on the Studio path actually renders.
        Text("In Studio, open **Devices — Add a device** and point the camera at the code on screen.")
            .font(.ppSupporting)
            .foregroundStyle(Color(.secondaryLabel))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Rows

    /// The mDNS row. Present only as a convenience for reconnecting to a host
    /// that has been paired before (REQ-DISC-3).
    private func discoveredHostRow(name: String, detail: String?) -> some View {
        HStack(spacing: PPMetrics.itemGap) {
            Image(systemName: "desktopcomputer")
                .font(.body)
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: PPMetrics.Size.rowGlyph)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.ppRowLabel)
                    .foregroundStyle(Color(.label))
                if let detail {
                    Text(detail)
                        .font(.ppFootnote)
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button("Connect", action: onConnectToDiscoveredHost)
                .buttonStyle(.plain)
                .font(.ppRowLabel.weight(.semibold))
                .foregroundStyle(Color.ppAccent)
                .frame(minHeight: PPMetrics.Size.minimumTapTarget)
                .accessibilityLabel(Text("Connect to \(name)"))
        }
        .frame(minHeight: PPMetrics.Size.minimumTapTarget)
    }
}

// MARK: - Screen-local pieces

/// Four accent corner brackets. Screen-local: this is B1's reticle and nothing
/// else in the app draws it.
private struct QRReticle: Shape {
    /// Bracket arm length as a fraction of the shorter side.
    var armFraction: CGFloat = 0.22

    func path(in rect: CGRect) -> Path {
        let arm = min(rect.width, rect.height) * armFraction
        var path = Path()

        // Top-leading
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        // Top-trailing
        path.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
        // Bottom-trailing
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        // Bottom-leading
        path.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - arm))

        return path
    }
}

/// A list row that reads as a system disclosure row.
///
/// The design system asks for `NavigationLink` here, but these screens do not
/// own navigation — the action is surfaced as a closure and the destination is
/// wired by the presenting layer, so this is a `Button` wearing the same chrome.
struct HostDisclosureRow: View {
    let title: String
    var detail: String?
    var systemImage: String?
    var titleTone: StatusTone = .neutral
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: PPMetrics.itemGap) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body)
                        .foregroundStyle(Color(.secondaryLabel))
                        .frame(width: PPMetrics.Size.rowGlyph)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.ppRowLabel)
                        .foregroundStyle(titleTone == .neutral
                                         ? Color(.label) : titleTone.foreground)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail)
                            .font(.ppFootnote)
                            .foregroundStyle(Color(.secondaryLabel))
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: PPMetrics.Size.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(detail.map { "\(title). \($0)" } ?? title))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Previews

#Preview("B1 · Connect a host") {
    NavigationStack {
        ConnectHostView(
            discoveredHostName: PreviewFixtures.hostName,
            discoveredHostDetail: "On this network · paired yesterday",
            onCancel: {},
            onConnectToDiscoveredHost: {},
            onEnterCode: {},
            onUseCable: {},
            onCaptureWithoutHost: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("B1 · Nothing discovered") {
    NavigationStack {
        ConnectHostView(
            onCancel: {},
            onEnterCode: {},
            onUseCable: {},
            onCaptureWithoutHost: {}
        )
    }
    .preferredColorScheme(.dark)
}
