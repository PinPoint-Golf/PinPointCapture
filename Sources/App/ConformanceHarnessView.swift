//  ConformanceHarnessView.swift
//  The debug-only screen that runs D9's harness from inside the app.
//
//  ⛔ DEBUG ONLY, beside `DebugScreenGallery` and reachable the same way:
//
//      -ppcpScreen D9 -ppcpConformPort 51423
//
//  ⚠ **In-app controls, no native dialogs.** The port is typed into the screen
//  or handed in on the launch command line; there is no file picker and no
//  document browser anywhere in this application.
//
//  ⚠ It exists because a conformance failure on a phone is otherwise a wall of
//  console output: the transcript is the first thing anyone asks for, so it is
//  the thing the screen is.

#if DEBUG

import SwiftUI
import CaptureCore

struct ConformanceHarnessView: View {

    @State private var host: String
    @State private var port: String
    @State private var isRunning = false
    @State private var report: ConformanceHarness.Report?
    @State private var failure: String?

    private let device: any CaptureDevice
    private let distance: MicToBallDistance

    init(device: any CaptureDevice, distance: MicToBallDistance,
         host: String = "127.0.0.1", port: UInt16? = nil) {
        self.device = device
        self.distance = distance
        _host = State(initialValue: host)
        _port = State(initialValue: port.map(String.init) ?? "")
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Host") {
                    TextField("127.0.0.1", text: $host)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent("Port") {
                    TextField("0", text: $port)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
            } header: {
                EyebrowLabel("ppcp-sim")
            } footer: {
                // ⛔ Said on the screen, not only in a comment: this link has no
                // TLS, and `RV` 5.2f means it can never be a shipping path.
                Text("Plaintext loopback — `PPCP-RV` §2's direct path. Debug builds only; "
                     + "the rendezvous path has no plaintext branch.")
            }

            Section {
                Button(isRunning ? "Running…" : "Run against ppcp-sim") {
                    Task { await run() }
                }
                .disabled(isRunning || UInt16(port) == nil)
            }

            if let failure {
                Section {
                    Text(failure)
                        .font(.ppSupporting)
                        .foregroundStyle(Color.ppError)
                } header: { EyebrowLabel("Failed") }
            }

            if let report {
                Section {
                    TelemetryRow("Security", report.security)
                    TelemetryRow("Wire version", report.negotiatedVersion ?? "—")
                    TelemetryRow("Counterpart", report.counterpartPeerId ?? "—")
                    TelemetryRow("Session", report.sessionId ?? "—")
                    TelemetryRow("Streams", "\(report.streamsOpened.count)")
                    TelemetryRow("Candidates", "\(report.candidatesNominated)")
                    TelemetryRow("Shots", "\(report.shotsMinted)")
                    TelemetryRow("Captures", "\(report.capturesAnnounced)")
                    TelemetryRow("Arms answered", "\(report.armsAnswered)")
                    TelemetryRow("Sync events", "\(report.syncEvents)")
                    TelemetryRow("Dropped events", "\(report.droppedEvents)",
                                 tone: report.droppedEvents == 0 ? nil : .error)
                    TelemetryRow("Errors", report.errorCodes.isEmpty
                                 ? "none" : report.errorCodes.joined(separator: ", "),
                                 tone: report.errorCodes.isEmpty ? nil : .error)
                } header: { EyebrowLabel("Result") }

                Section {
                    ForEach(Array(report.transcript.enumerated()), id: \.offset) { line in
                        Text(line.element)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                } header: { EyebrowLabel("Transcript") }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("Conformance harness")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() async {
        guard let value = UInt16(port) else { return }
        isRunning = true
        failure = nil
        report = nil
        let harness = ConformanceHarness(device: device, distance: distance)
        do {
            report = try await harness.run(
                against: PeerEndpoint(host: host, port: value))
        } catch {
            failure = String(describing: error)
        }
        isRunning = false
    }
}

#endif
