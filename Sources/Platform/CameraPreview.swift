//  CameraPreview.swift
//  The live camera preview.
//
//  ⚠ This is the ONLY UIKit touchpoint in the app. SwiftUI has no way to host an
//  AVCaptureVideoPreviewLayer, so one UIViewRepresentable is unavoidable — and it
//  lives here, in Platform, rather than in UI, so that `AVCaptureSession` never
//  becomes reachable from a view or a view model (REQ-PORT-3).

import AVFoundation
import SwiftUI
import UIKit

/// A `UIView` whose backing layer *is* the preview layer, so the layer resizes
/// with the view for free. Doing this with a sublayer instead means resizing it
/// by hand in `layoutSubviews` and getting it wrong on rotation.
public final class CameraPreviewUIView: UIView {
    public override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // Safe: `layerClass` above guarantees the type.
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            preconditionFailure("layerClass is AVCaptureVideoPreviewLayer")
        }
        return layer
    }
}

/// Live preview for a capture device.
///
/// Renders a labelled placeholder when the device has no live session — the
/// simulator, or a mock device in review mode (REQ-STANDALONE-6). It never fails
/// to a blank rectangle, because "black screen" and "camera not running" look
/// identical on a tripod at two metres.
public struct CameraPreview: View {
    private let device: (any CaptureDevice)?
    private let placeholderLabel: String

    public init(device: (any CaptureDevice)?, placeholderLabel: String = "CAMERA PREVIEW") {
        self.device = device
        self.placeholderLabel = placeholderLabel
    }

    public var body: some View {
        if let avDevice = device as? AVFoundationCaptureDevice {
            PreviewLayerHost(device: avDevice)
                .accessibilityLabel("Live camera preview")
        } else {
            PreviewPlaceholder(label: placeholderLabel)
        }
    }
}

private struct PreviewLayerHost: UIViewRepresentable {
    let device: AVFoundationCaptureDevice

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        device.attachPreview(to: view.previewLayer)
        // Fill the frame. The golfer must be judged in frame or out of it, and a
        // letterboxed preview makes that judgement on the wrong rectangle.
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: CameraPreviewUIView, context: Context) {}
}

private struct PreviewPlaceholder: View {
    let label: String

    var body: some View {
        ZStack {
            Color.black
            Text(label)
                .font(.footnote.monospaced())
                .foregroundStyle(.tertiary)
        }
        .accessibilityLabel("Camera preview unavailable")
    }
}
