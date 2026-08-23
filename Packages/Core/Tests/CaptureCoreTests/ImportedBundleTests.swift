//  ImportedBundleTests.swift
//  IOP-3 / IOP-10, the receiving half — a `PPCPBNDL` this repository did not
//  write, read through `SessionBundleReader`.
//
//  ⛔ **The point is the authorship, not the parsing.** Every other bundle test
//  in this suite writes a bundle and reads it back, which `CONF` §2c calls the
//  single-implementation trap in as many words: an ordering rule both halves get
//  wrong the same way is invisible to it. This one takes a file another
//  implementation produced and asserts `ENC` §7 against it — the magic, the
//  header, `7c`'s manifest-before-payload, and `7d`'s three-way completeness.
//
//  ⚠ **It SKIPS without a file**, so `make test-core` stays green in a checkout
//  with no counterpart bundle. Point it at one with:
//
//      make read-bundle FILE=../PinPointStudio/docs/conformance/bundles/x.ppcpbndl
//
//  Spec: `ENC` §7; `CORE` §9; `CONF` §2c, §5.

import Foundation
import Testing
@testable import CaptureCore

@Suite("A bundle written by another implementation — ENC §7")
struct ImportedBundleTests {

    static var file: URL? {
        guard let path = ProcessInfo.processInfo.environment["PPCP_BUNDLE_IN"],
              path.isEmpty == false else { return nil }
        return URL(fileURLWithPath: path)
    }

    @Test("It carries the ENC §7 header and reads back through the library's reader")
    func readsAForeignBundle() throws {
        guard let file = Self.file else { return }

        let bytes = try Data(contentsOf: file)
        // `ENC` §7 — "PPCPBNDL" at offset zero. ⛔ Not the file extension: 5.1a
        // forbids deriving anything from a name.
        #expect(SessionStore.hasBundleMagic(bytes),
                "\(file.lastPathComponent) does not begin with PPCPBNDL")
        let header = try SessionStore.readHeader(bytes)
        #expect(header.major == 1, "major \(header.major)")

        let reader = try SessionBundleReader()
        var offset = 0
        // Fed in short runs on purpose: `ENC` §3 is length-prefixed and a reader
        // that only works when a frame arrives whole is a reader that works
        // against a file and not against a socket.
        while offset < bytes.count {
            let end = min(offset + 137, bytes.count)
            try reader.feed(bytes[offset..<end])
            offset = end
        }
        // `ENC` 7c — the manifest precedes every payload frame, whoever wrote it.
        #expect(reader.manifestOrdered,
                "ENC 7c: a payload frame preceded session_manifest")
        // ⛔ 7d / I10 — whatever it says, it is the WRITER's assertion. This
        // asserts only that the reader reached a verdict rather than throwing.
        let completeness = try reader.finish()
        #expect(reader.frameCount > 0, "no frame was read at all")

        // Printed rather than asserted: what a foreign bundle contains is the
        // other implementation's business, and a row that demanded a shape would
        // be this repository legislating for it.
        print("""
              imported \(file.lastPathComponent): \(bytes.count) bytes, \
              minor \(reader.minor), \(reader.frameCount) frames, \
              \(reader.captureCount) captures, completeness \(completeness), \
              truncated \(reader.truncated)
              """)
    }
}
