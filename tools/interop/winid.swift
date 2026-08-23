// Print the window id of the frontmost window whose owner matches a name.
// ⚠ Window-targeted capture beats full-screen for three reasons: the window can be
// behind others, nothing else on the display is captured, and the Simulator taking
// focus mid-run stops mattering.
import Foundation
import CoreGraphics

let match = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "PinPoint"
guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] else { exit(1) }
for w in windows {
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
    guard owner.localizedCaseInsensitiveContains(match) else { continue }
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (bounds["Width"] as? Double) ?? 0
    let height = (bounds["Height"] as? Double) ?? 0
    guard width > 200, height > 200 else { continue }   // skip tiny panels
    if let id = w[kCGWindowNumber as String] as? Int {
        print("\(id)\t\(owner)\t\(Int(width))x\(Int(height))")
    }
}
