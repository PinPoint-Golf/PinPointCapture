//  LayerPurityTests.swift
//  Assert that Core is still platform-neutral.
//
//  ⚠ REQ-PORT-3 is the requirement most easily eroded one convenience at a time,
//  and the erosion is invisible: an `import AVFoundation` in a Core file compiles
//  perfectly and nothing goes wrong until someone tries to port the app.
//
//  ⛔ A PACKAGE BOUNDARY DOES NOT ENFORCE THIS. System frameworks come from the
//  SDK, not from declared dependencies, so SPM will happily build a Core target
//  that imports AVFoundation. This was verified, not assumed. The boundary buys
//  real encapsulation of our own types and a test suite that runs on macOS in
//  milliseconds — it does not buy the seam. This test buys the seam.
//
//  Modelled on libwrist's `tests/purity.cmake`, which asserts the sans-I/O rule
//  the same way: as something that fails the build, not as a convention.

import Foundation
import Testing

@Suite("Layer purity")
struct LayerPurityTests {

    /// Every framework whose presence would mean Core had started doing something
    /// the platform layer is supposed to do.
    static let forbidden = [
        "AVFoundation", "VideoToolbox", "CoreMedia", "CoreVideo",
        "CoreMotion", "Network", "Photos", "AudioToolbox",
        "UIKit", "AppKit", "SwiftUI"
    ]

    private static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CaptureCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Core
            .appendingPathComponent("Sources/CaptureCore")
    }

    @Test("Core imports no platform framework")
    func coreIsPlatformNeutral() throws {
        let sources = Self.sourcesDirectory
        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        // A suite that checked nothing must not report success — the same guard
        // libwrist's test harness makes when zero tests register.
        #expect(files.isEmpty == false, "found no Core sources at \(sources.path)")

        var violations: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = trimmed
                    .dropFirst("import ".count)
                    .trimmingCharacters(in: .whitespaces)
                if Self.forbidden.contains(module) {
                    violations.append("\(file.lastPathComponent): import \(module)")
                }
            }
        }

        #expect(violations.isEmpty,
                """
                Core must stay platform-neutral (REQ-PORT-3) but imports:
                \(violations.joined(separator: "\n"))

                Move whatever needed it into Sources/Platform/ and hand Core a \
                neutral value instead. If the type genuinely belongs in Core, it \
                needs a platform-free representation — that is the whole point of \
                the layer, and the reason a later port is a port and not a rewrite.
                """)
    }

    /// Foundation is fine and is the only thing Core should need.
    @Test("Core needs nothing beyond Foundation and Observation")
    func coreDependencyFootprintIsSmall() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: Self.sourcesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        var modules = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                modules.insert(String(trimmed.dropFirst("import ".count))
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        #expect(modules.subtracting(["Foundation", "Observation"]).isEmpty,
                "Core imports more than expected: \(modules.sorted())")
    }
}
