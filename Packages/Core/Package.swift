// swift-tools-version: 6.0
import PackageDescription

// CaptureCore — the platform-neutral layer.
//
// ⛔ THIS PACKAGE IMPORTS NO PLATFORM FRAMEWORK, AND MUST NOT.
//
// REQ-PORT-3 forbids any platform type crossing an internal API boundary.
//
// ⚠ Being a package does NOT enforce that, and it is worth knowing why before
// trusting it. System frameworks come from the SDK rather than from declared
// dependencies, so SPM will happily build a target here that imports
// AVFoundation — this was tested, not assumed. What the package boundary
// actually buys is real encapsulation of our own types (anything the app reaches
// for must be deliberately `public`) and a suite that runs on macOS in
// milliseconds with no simulator runtime.
//
// The seam itself is held by `Tests/CaptureCoreTests/LayerPurityTests.swift`,
// which fails the build on a forbidden import — the same way libwrist asserts
// its sans-I/O rule in `tests/purity.cmake` rather than trusting a convention.
//
// Keeping Core platform-free is what will make substituting libppcp for these
// types a substitution rather than a rewrite (§17.1).
let package = Package(
    name: "CaptureCore",
    platforms: [
        .iOS(.v18),
        // macOS is here ONLY so `swift test` runs the suite on the host. Nothing
        // in this package is macOS-specific; if something ever needs to be, it
        // does not belong in Core.
        .macOS(.v14)
    ],
    products: [
        .library(name: "CaptureCore", targets: ["CaptureCore"])
    ],
    targets: [
        .target(
            name: "CaptureCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CaptureCoreTests",
            dependencies: ["CaptureCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
