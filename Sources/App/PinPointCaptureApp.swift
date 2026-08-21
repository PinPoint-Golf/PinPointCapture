import SwiftUI

/// Application entry point and composition root.
///
/// This layer owns wiring only: it constructs the platform capture layer, hands
/// the resulting port-surface abstractions to `Core`, and passes observable state
/// to `UI`. It holds no capture logic and no view logic of its own (REQ-PORT-1).
@main
struct PinPointCaptureApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
