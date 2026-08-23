// Decode a QR from a screen capture.
// ⛔ RV 4.4c / 7.2b — the payload carries the PSK. It is printed to stdout for the
// caller to consume in-process and is never written to a file by this tool.
import Foundation
import CoreImage

guard CommandLine.arguments.count > 1,
      let image = CIImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    FileHandle.standardError.write("usage: qr <image>\n".data(using: .utf8)!); exit(2)
}
let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                          options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
let found = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
if found.isEmpty { FileHandle.standardError.write("no QR found\n".data(using: .utf8)!); exit(1) }
for message in found { print(message) }
