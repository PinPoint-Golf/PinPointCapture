// Read the text out of a window capture.
//
// ⛔ **The client's view is a one-sided oracle.** PPC can complete a handshake and
// believe it settled while the host logged a failure — so a soak that records only
// the client's verdict scores that as a pass. This reads the host's own words back
// so the two can be compared, and a disagreement is the finding.
//
// ⚠ Prints every recognised line. The caller decides what is an error; this tool
// does not, because a classifier here would hide exactly the message nobody
// predicted.
import Foundation
import Vision
import CoreImage

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: ocr <image>\n".data(using: .utf8)!); exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = CIImage(contentsOf: url) else { exit(1) }

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(ciImage: image, options: [:])
try? handler.perform([request])

for observation in (request.results ?? []) {
    if let line = observation.topCandidates(1).first?.string { print(line) }
}
