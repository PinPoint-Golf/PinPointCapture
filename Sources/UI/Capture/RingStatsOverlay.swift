//
//  RingStatsOverlay.swift
//  E1.1's instrument, on screen.
//

import SwiftUI
import CaptureCore

/// ⛔ **The readout E1.1's exit criterion needs, and the reason it exists.**
///
/// The criterion is "twenty 0.5 s fragments on disk, rolling, **at the claimed
/// rate**". The first two clauses can be seen in a directory listing; the third
/// cannot be seen at all. Without this panel a device run produces a preview
/// that looks fine and no evidence — which is the failure the counters were
/// built to prevent, arriving one step later.
///
/// ⚠ **`max gap` is the row to read, not `mean`.** A run averaging 150 fps with
/// one 40 ms stall is not 150 fps, and it is the stall that loses the impact
/// frame. The two are shown together, and `max gap` is tinted against the frame
/// period so a bad run is visible without arithmetic.
///
/// ⛔ Debug builds only — the call site in `RootView` is inside `#if DEBUG`.
/// This is an instrument, not a screen: it is deliberately not in the design
/// handoff and must not acquire a place in it.
public struct RingStatsOverlay: View {

    private let stats: RingStats
    private let expectedFPS: Double?
    private let isLive: Bool

    @State private var expanded = false

    /// - Parameters:
    ///   - stats: the live counters while armed, or the last run's afterwards.
    ///   - expectedFPS: the active mode's rate, for judging `max gap`. `nil`
    ///     leaves the gap untinted — ⛔ never judged against a guessed rate.
    ///   - isLive: whether this is the running retention or a finished one. The
    ///     distinction matters: a finished run's numbers are complete, a live
    ///     one's are a sample.
    public init(stats: RingStats, expectedFPS: Double?, isLive: Bool) {
        self.stats = stats
        self.expectedFPS = expectedFPS
        self.isLive = isLive
    }

    /// The frame period the device claims, in nanoseconds.
    private var expectedPeriodNs: Int64? {
        guard let expectedFPS, expectedFPS > 0 else { return nil }
        return Int64(1_000_000_000.0 / expectedFPS)
    }

    /// ⚠ Two frame periods is the threshold, because one whole missed frame is
    /// the smallest gap that costs an image. It is a display hint and nothing
    /// reads a verdict back off it — the number is the measurement.
    private var gapIsBad: Bool {
        guard let expectedPeriodNs, stats.maxInterArrivalNs > 0 else { return false }
        return stats.maxInterArrivalNs > expectedPeriodNs * 2
    }

    private var droppedAnything: Bool {
        stats.framesDroppedEncoderBusy > 0
            || stats.framesDroppedNotRetaining > 0
            || stats.fragmentsDroppedWriteFailed > 0
            || stats.fragmentsDroppedEmpty > 0
            || stats.monotonicityViolations > 0
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if expanded {
                Divider().overlay(.white.opacity(0.25))
                grid
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { withAnimation(.snappy(duration: 0.15)) { expanded.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ring buffer counters")
        .accessibilityHint(expanded ? "Tap to collapse" : "Tap to expand")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isLive ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(isLive ? "RING" : "RING · last run").fontWeight(.semibold)
            Spacer(minLength: 12)
            Text("\(stats.fragmentsInRing(capacity: 20))/20")
            Text(Self.rate(fromPeriodNs: stats.meanInterArrivalNs))
            Text("↕\(Self.ms(stats.maxInterArrivalNs))")
                .foregroundStyle(gapIsBad ? Color.orange : Color.white)
            if droppedAnything {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
            row("frames", "\(stats.framesAppended)")
            row("mean gap", Self.ms(stats.meanInterArrivalNs))
            // ⛔ The one that matters. An average hides the stall that loses the
            // impact frame; this does not.
            row("max gap", Self.ms(stats.maxInterArrivalNs), warn: gapIsBad)
            row("frags written", "\(stats.fragmentsWritten)")
            row("frags evicted", "\(stats.fragmentsEvicted)")
            row("drop: encoder", "\(stats.framesDroppedEncoderBusy)",
                warn: stats.framesDroppedEncoderBusy > 0)
            row("drop: not retaining", "\(stats.framesDroppedNotRetaining)",
                warn: stats.framesDroppedNotRetaining > 0)
            row("frag: write failed", "\(stats.fragmentsDroppedWriteFailed)",
                warn: stats.fragmentsDroppedWriteFailed > 0)
            row("frag: empty", "\(stats.fragmentsDroppedEmpty)",
                warn: stats.fragmentsDroppedEmpty > 0)
            row("non-monotonic", "\(stats.monotonicityViolations)",
                warn: stats.monotonicityViolations > 0)
        }
    }

    private func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.white.opacity(0.7))
            Text(value)
                .foregroundStyle(warn ? Color.orange : Color.white)
                .gridColumnAlignment(.trailing)
        }
    }

    // MARK: Formatting

    /// ⚠ Rate derived from the measured inter-arrival period, never from a frame
    /// count over a wall clock (REQ-FPS-2, REQ-TIME-5).
    static func rate(fromPeriodNs periodNs: Int64) -> String {
        guard periodNs > 0 else { return "—" }
        return String(format: "%.0f fps", 1_000_000_000.0 / Double(periodNs))
    }

    static func ms(_ ns: Int64) -> String {
        guard ns > 0 else { return "—" }
        return String(format: "%.1f ms", Double(ns) / 1_000_000.0)
    }
}

public extension RingStats {
    /// How many fragments the ring is holding, derived from what it wrote and
    /// what it threw away. ⚠ Never more than the capacity, whatever the counters
    /// say — a display that showed 23/20 would be reporting on itself.
    func fragmentsInRing(capacity: Int) -> Int {
        Swift.min(Swift.max(fragmentsWritten - fragmentsEvicted, 0), capacity)
    }
}

#if DEBUG
#Preview("Ring — healthy") {
    ZStack {
        Color.gray
        RingStatsOverlay(stats: .previewHealthy, expectedFPS: 150, isLive: true)
    }
}

#Preview("Ring — stalled") {
    ZStack {
        Color.gray
        RingStatsOverlay(stats: .previewStalled, expectedFPS: 150, isLive: false)
    }
}

extension RingStats {
    static var previewHealthy: RingStats {
        var stats = RingStats()
        stats.framesAppended = 2_250
        stats.fragmentsWritten = 30
        stats.fragmentsEvicted = 10
        stats.maxInterArrivalNs = 6_700_000
        stats.spanNs = 14_993_300_000
        return stats
    }

    static var previewStalled: RingStats {
        var stats = previewHealthy
        stats.maxInterArrivalNs = 41_000_000
        stats.framesDroppedEncoderBusy = 17
        return stats
    }
}
#endif
