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
//
//  ⚠ `CPPCP` — libppcp, the MIT C reference implementation — is ALLOWED here and
//  is not a hole in the seam. It is the opposite of a platform framework: a
//  platform-free C library with no socket, thread, timer, clock or file in it
//  (implementation plan ground rule 7), which is exactly what makes one
//  implementation serve both ends. Plan A5 says Core gains a dependency on it and
//  wraps it in Swift, and the README has always said that most of what lives here
//  will end up owned by it. The forbidden list below is unchanged.

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

    /// ⛔ **Recursive, and it has to be.** This walked one directory until
    /// `Sources/CaptureCore/Ppcp/` was added, at which point every file in it was
    /// silently outside the seam — a purity test that quietly checks less is
    /// worse than none, because the green tick is what stops anyone looking. The
    /// enumerator, and the `files.isEmpty` guard below, are the two halves of
    /// "this suite must not report success having checked nothing".
    private static func swiftSources() throws -> [URL] {
        guard let walk = FileManager.default.enumerator(
            at: sourcesDirectory, includingPropertiesForKeys: nil) else { return [] }
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test("Core imports no platform framework")
    func coreIsPlatformNeutral() throws {
        let files = try Self.swiftSources()

        // A suite that checked nothing must not report success — the same guard
        // libwrist's test harness makes when zero tests register.
        #expect(files.isEmpty == false,
                "found no Core sources under \(Self.sourcesDirectory.path)")

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

    /// Foundation, Observation and the protocol library. Nothing else.
    @Test("Core needs nothing beyond Foundation, Observation and libppcp")
    func coreDependencyFootprintIsSmall() throws {
        let files = try Self.swiftSources()
        #expect(files.isEmpty == false, "found no Core sources to check")

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
        // ⚠ `CPPCP` joins the list, and nothing else does. Every addition here is
        // a decision about what Core is allowed to depend on, which is why the
        // set is written out rather than derived.
        #expect(modules.subtracting(["Foundation", "Observation", "CPPCP"]).isEmpty,
                "Core imports more than expected: \(modules.sorted())")
    }
}
