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
    dependencies: [
        // libppcp — the MIT C reference implementation of PPCP, and the reason
        // this package exists in the shape it does (see "Relationship to
        // libppcp" in README.md). Plan A5: consumed as a SwiftPM package, never
        // copied. Nothing crosses between the three repositories but this.
        //
        // ⚠ A sibling checkout during co-development. Once libppcp is tagged
        // this becomes:
        //   .package(url: "https://github.com/PinPoint-Golf/libppcp.git", from: "0.1.0")
        // and the path form goes away. The URL is written down here rather than
        // in a commit message because it is the thing a reader needs and the
        // hardest to guess.
        //
        // ⛔ `CPPCP` is a C target, NOT a platform framework. LayerPurityTests
        // permits it by name and still forbids every framework it ever did —
        // importing the protocol is the opposite of importing AVFoundation.
        .package(path: "../../../libppcp")
    ],
    targets: [
        .target(
            name: "CaptureCore",
            dependencies: [
                .product(name: "CPPCP", package: "libppcp")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CaptureCoreTests",
            dependencies: ["CaptureCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
