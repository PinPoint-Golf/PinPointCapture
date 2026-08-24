//
//  ClipThumbnail.swift
//  E1.2 — one frame out of a clip, for the rows that have been showing a
//  placeholder since the first build.
//
//  ⚠ **Not a PPCP record, and deliberately not in the bundle.** A thumbnail is a
//  UI convenience; PPCP has no record type for one, and putting it inside a
//  `PPCPBNDL` would invent a payload PinPointStudio must ignore and break
//  REQ-CLIP-2's identical-schema-on-wire-and-disk rule for the sake of a
//  picture. It lives beside the bundle, is regenerable from the clip, and losing
//  one is cosmetic.
//
//  Spec: REQ-SHOT-2. Screens: C1's last-shot row (74 pt), C3's shot rows (50 pt).

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ClipThumbnail {

    public enum ThumbnailError: Error, Sendable {
        case noVideoTrack
        case couldNotDecodeFrame
        case couldNotEncodeImage
    }

    /// The longest edge of a stored thumbnail, in pixels.
    ///
    /// ⚠ C1 shows it at 74 pt and C3 at 50 pt, so 320 covers a 3× screen with
    /// room to spare and costs a few kilobytes. ⛔ Not the full frame: a session
    /// is fifty of these, and a 1080p JPEG each would be storage REQ-OFF-2's
    /// floor has to account for.
    public static let maximumEdge: CGFloat = 320

    /// A JPEG of the frame at `atNs` within the clip.
    ///
    /// - Parameter atNs: **relative to the clip's own start**, not the capture
    ///   timebase. The caller knows where `t0` fell inside the extracted window;
    ///   this only knows about the asset.
    public static func jpeg(fromClipAt url: URL, atNs: Int64,
                            quality: CGFloat = 0.8) async throws -> Data {
        let asset = AVURLAsset(url: url)
        guard try await asset.loadTracks(withMediaCharacteristic: .visual)
            .isEmpty == false else {
            throw ThumbnailError.noVideoTrack
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumEdge, height: maximumEdge)

        // ⛔ **Zero tolerance, and this is the whole point of the function.**
        // `AVAssetImageGenerator` defaults to `.positiveInfinity` on both sides,
        // which lets it return the nearest *keyframe* — and REQ-BUF-1 puts an
        // IDR at every 0.5 s fragment boundary, so the default could hand back a
        // frame up to half a second from impact. At 150 fps that is seventy-five
        // frames away: a picture of the follow-through captioned as the strike.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let time = CMTime(value: Swift.max(0, atNs), timescale: 1_000_000_000)
        let image: CGImage
        do {
            image = try await generator.image(at: time).image
        } catch {
            throw ThumbnailError.couldNotDecodeFrame
        }

        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ThumbnailError.couldNotEncodeImage
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ThumbnailError.couldNotEncodeImage
        }
        return bytes as Data
    }
}
