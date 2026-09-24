//
//  ReplayScreen.swift
//  PinPointCapture — C2 Replay and markup.
//
//  ⚠ "STILL ARMED" SITS UNDER THE TITLE. It is the single most important string
//  on this screen: reviewing costs nothing, the ring buffer is still filling,
//  and the next shot will still be caught (REQ-STATE-4, REQ-RES-1/2). It is not
//  decoration and must not be moved, shortened or dropped.
//
//  ⚠ THE TIMELINE IS ADDRESSED IN TIME, ZEROED ON IMPACT — never in frame index
//  (REQ-REPLAY-1/2/3). There is deliberately no frame number anywhere in this
//  file. The top-of-backswing anchor is marked separately, as an anchor, not as
//  a second origin.
//
//  ⚠ The frame-step buttons (54pt) and markup tools (48pt) are sized for a
//  gloved hand and MUST NOT SHRINK to make a layout fit.
//
//  *Compare* opens two-shot comparison aligned on impact (REQ-REPLAY-4). That
//  screen is NOT DESIGNED YET — this file surfaces the button and the closure
//  and builds none of the behaviour.
//

import SwiftUI
import CaptureCore

// MARK: - Screen-local model

/// The window C2 is showing, in seconds relative to impact.
///
/// Screen-local on purpose: replay addressing is a C2 concern and nothing in
/// `Core` needs it yet. Every member is a time; there is no frame index here and
/// none should be added (REQ-REPLAY-2).
struct ReplayTimeline: Sendable, Hashable {

    /// Start of the window. Negative — before impact.
    var start: TimeInterval
    /// End of the window. Positive — after impact.
    var end: TimeInterval
    /// The top-of-backswing anchor. Marked separately from the zero point.
    var topOfBackswing: TimeInterval
    /// Where the review is sitting, relative to impact.
    var playhead: TimeInterval

    init(start: TimeInterval = -1.3,
         end: TimeInterval = 1.2,
         topOfBackswing: TimeInterval = -0.7,
         playhead: TimeInterval = -0.0067) {
        self.start = start
        self.end = end
        self.topOfBackswing = topOfBackswing
        self.playhead = playhead
    }

    var span: TimeInterval { max(end - start, 0.0001) }

    func fraction(at time: TimeInterval) -> Double {
        min(max((time - start) / span, 0), 1)
    }

    /// Impact is the zero point, and it is where the accent line sits.
    var impactFraction: Double { fraction(at: 0) }
    var topFraction: Double { fraction(at: topOfBackswing) }
}

/// Replay speed. Slow is the default because the interesting part of a golf
/// swing is over in about eight frames.
enum ReplaySpeed: String, Sendable, CaseIterable {
    case quarter, half, full

    /// `¼×`, `½×`, `1×`.
    var displayText: String {
        switch self {
        case .quarter: "\u{00BC}\u{00D7}"
        case .half: "\u{00BD}\u{00D7}"
        case .full: "1\u{00D7}"
        }
    }

    var spokenText: String {
        switch self {
        case .quarter: "quarter speed"
        case .half: "half speed"
        case .full: "full speed"
        }
    }

    var next: ReplaySpeed {
        switch self {
        case .quarter: .half
        case .half: .full
        case .full: .quarter
        }
    }
}

/// The three markup tools. ⚠ NAMED, NOT DESIGNED — the drawing behaviour, and
/// the round trip of an annotation to Studio (REQ-MARK-1/2), are not in this
/// pass. These are the controls only.
enum MarkupTool: String, Sendable, CaseIterable, Identifiable {
    case line, circle, freehand

    var id: String { rawValue }

    /// SF Symbols only — never a redrawn path.
    var systemImage: String {
        switch self {
        case .line: "line.diagonal"
        case .circle: "circle"
        case .freehand: "scribble"
        }
    }

    var displayName: String {
        switch self {
        case .line: "Line"
        case .circle: "Circle"
        case .freehand: "Freehand"
        }
    }
}

// MARK: - Screen

struct ReplayScreen: View {

    private let shot: Shot
    private let capture: CaptureStatus
    private let timeline: ReplayTimeline
    private let speed: ReplaySpeed
    private let isPlaying: Bool
    private let selectedTool: MarkupTool?

    private let onDone: () -> Void
    /// ⚠ Two-shot comparison aligned on impact is not designed. Surface only.
    private let onCompare: () -> Void
    /// One frame at a time, `-1` or `+1`. The *view* still never names an index.
    private let onStepFrame: (Int) -> Void
    private let onTogglePlayback: () -> Void
    private let onCycleSpeed: () -> Void
    private let onSelectTool: (MarkupTool) -> Void

    /// ⛔ **Not defaulted.** A caller has to state whether this shot has frames.
    /// A screen that worked it out for itself would quietly start lying the day
    /// one of the two facts changed.
    private let hasVideo: Bool

    init(shot: Shot,
         hasVideo: Bool,
         capture: CaptureStatus,
         timeline: ReplayTimeline = ReplayTimeline(),
         speed: ReplaySpeed = .quarter,
         isPlaying: Bool = false,
         selectedTool: MarkupTool? = .line,
         onDone: @escaping () -> Void,
         onCompare: @escaping () -> Void,
         onStepFrame: @escaping (Int) -> Void,
         onTogglePlayback: @escaping () -> Void,
         onCycleSpeed: @escaping () -> Void,
         onSelectTool: @escaping (MarkupTool) -> Void) {
        self.shot = shot
        self.hasVideo = hasVideo
        self.capture = capture
        self.timeline = timeline
        self.speed = speed
        self.isPlaying = isPlaying
        self.selectedTool = selectedTool
        self.onDone = onDone
        self.onCompare = onCompare
        self.onStepFrame = onStepFrame
        self.onTogglePlayback = onTogglePlayback
        self.onCycleSpeed = onCycleSpeed
        self.onSelectTool = onSelectTool
    }

    /// ⛔ Specific about **which half** is missing. The shot's time is real and
    /// measured; only its frames are absent. "No video" alone would read as a
    /// failure, and this is not one — nothing records video yet (E1.1).
    private var noVideoPanel: some View {
        VStack(spacing: PPMetrics.itemGap) {
            EyebrowLabel("No video")
            Text("This shot was timed, not filmed.")
                .font(.ppCardTitle)
                .foregroundStyle(Color(.label))
            Text("Video recording is not connected yet. The impact time below is "
                 + "real — it came from the microphone.")
                .font(.ppSupporting)
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PPMetrics.screenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasVideo {
                // ⚠ Substitution point — see CapturePlaceholders.swift.
                ReplayFramePlaceholder(caption: frameCaption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                noVideoPanel
            }

            controls
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done", action: onDone)
            }
            ToolbarItem(placement: .principal) {
                titleStack
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Compare", action: onCompare)
                    .accessibilityHint(Text("Compares two shots aligned on impact"))
            }
        }
    }

    /// The title and, under it, the promise.
    private var titleStack: some View {
        VStack(spacing: 2) {
            Text("Shot \(shot.displayTitle)")
                .font(.headline)
                .foregroundStyle(Color(.label))
            Text(reviewPromise)
                .font(.caption)
                .foregroundStyle(Color(.secondaryLabel))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Shot \(shot.displayTitle), \(reviewPromise)"))
        .accessibilityAddTraits(.isHeader)
    }

    /// ⚠ Reviewing never disarms capture, so while the device is armed this says
    /// so — in those two words, under the title, where it is read without being
    /// looked for.
    private var reviewPromise: String {
        capture.state == .armed ? "still armed" : capture.state.displayName.lowercased()
    }

    private var frameCaption: String {
        "FRAME AT IMPACT \(CaptureScreenStyle.impactRelativeText(timeline.playhead))"
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: PPMetrics.groupGap) {
            timelineBlock
            transport
            markupRow
        }
        .padding(.horizontal, PPMetrics.screenMargin)
        .padding(.top, PPMetrics.screenMargin)
        .padding(.bottom, PPMetrics.itemGap)
    }

    // MARK: Timeline

    private var timelineBlock: some View {
        VStack(spacing: 10) {
            ImpactTimelineTrack(timeline: timeline)
                .accessibilityElement()
                .accessibilityLabel(Text("Replay position, measured from impact"))
                .accessibilityValue(Text(spokenPlayhead))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: onStepFrame(1)
                    case .decrement: onStepFrame(-1)
                    @unknown default: break
                    }
                }

            HStack(spacing: PPMetrics.itemGap) {
                Text("TOP")
                    .font(.ppMeasuredDetail)
                    .foregroundStyle(Color(.secondaryLabel))
                Spacer(minLength: 0)
                Text("IMPACT \(CaptureScreenStyle.impactRelativeText(0))")
                    .font(.ppMeasuredDetail)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(Color.ppAccent)
                Spacer(minLength: 0)
                Text(CaptureScreenStyle.impactRelativeText(timeline.end, decimals: 1))
                    .font(.ppMeasuredDetail)
                    .monospacedDigit()
                    .foregroundStyle(Color(.secondaryLabel))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Window: top of backswing to impact to one point two seconds after impact"))
        }
    }

    private var spokenPlayhead: String {
        let seconds = timeline.playhead
        let magnitude = String(format: "%.4f", abs(seconds))
        if seconds == 0 { return "impact" }
        return seconds < 0
            ? "\(magnitude) seconds before impact"
            : "\(magnitude) seconds after impact"
    }

    // MARK: Transport

    /// ⚠ 54pt steps and a 64pt play. Sized for a gloved hand — see `PPMetrics`.
    private var transport: some View {
        HStack(spacing: 10) {
            Button { onStepFrame(-1) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "backward.frame")
                    Text("\u{2212}1").font(.ppMeasuredDetail).fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.frameStep)
            }
            .tint(Color(.label))
            .accessibilityLabel(Text("Back one frame"))

            Button(action: onTogglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(minWidth: PPMetrics.Size.transportPlay,
                           minHeight: PPMetrics.Size.frameStep)
            }
            .tint(Color(.label))
            .accessibilityLabel(Text(isPlaying ? "Pause" : "Play"))

            Button { onStepFrame(1) } label: {
                HStack(spacing: 6) {
                    Text("+1").font(.ppMeasuredDetail).fontWeight(.semibold)
                    Image(systemName: "forward.frame")
                }
                .frame(maxWidth: .infinity, minHeight: PPMetrics.Size.frameStep)
            }
            .tint(Color(.label))
            .accessibilityLabel(Text("Forward one frame"))

            Button(action: onCycleSpeed) {
                Text(speed.displayText)
                    .font(.ppMeasuredDetail)
                    .fontWeight(.semibold)
                    .frame(minWidth: PPMetrics.Size.transportPlay,
                           minHeight: PPMetrics.Size.frameStep)
            }
            .accessibilityLabel(Text("Playback speed"))
            .accessibilityValue(Text(speed.spokenText))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: PPMetrics.Radius.control))
    }

    // MARK: Markup

    private var markupRow: some View {
        HStack(spacing: PPMetrics.itemGap) {
            HStack(spacing: 8) {
                ForEach(MarkupTool.allCases) { tool in
                    Button { onSelectTool(tool) } label: {
                        Image(systemName: tool.systemImage)
                            .font(.title3)
                            .frame(width: PPMetrics.Size.markupTool,
                                   height: PPMetrics.Size.markupTool)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: PPMetrics.Radius.control))
                    .tint(tool == selectedTool ? Color.ppAccent : Color(.label))
                    .accessibilityLabel(Text(tool.displayName))
                    .accessibilityAddTraits(tool == selectedTool ? .isSelected : [])
                }
            }

            Spacer(minLength: 0)

            // Three words, not an icon: the state the host has confirmed.
            StatusChip(shot.syncState.displayText,
                       tone: CaptureScreenStyle.tone(for: shot.syncState))
        }
    }
}

// MARK: - The track

/// The 44pt track: accent wash up to impact, a 2pt accent line *at* impact, and
/// a separate hairline for the top-of-backswing anchor.
///
/// Screen-local to C2 and staying that way — it is a picture of one shot's
/// timing, not a general scrubber.
private struct ImpactTimelineTrack: View {

    let timeline: ReplayTimeline

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color(.tertiarySystemFill))

                // Retained up to impact.
                Rectangle()
                    .fill(Color.ppAccentWash)
                    .frame(width: width * timeline.impactFraction)

                // Top of the backswing: an anchor, not an origin.
                Rectangle()
                    .fill(Color(.tertiaryLabel))
                    .frame(width: 1)
                    .offset(x: width * timeline.topFraction)

                // Zero.
                Rectangle()
                    .fill(Color.ppAccent)
                    .frame(width: 2)
                    .offset(x: max(0, width * timeline.impactFraction - 1))
            }
            .clipShape(RoundedRectangle(cornerRadius: PPMetrics.Radius.small,
                                        style: .continuous))
        }
        .frame(height: PPMetrics.Size.minimumTapTarget)
    }
}

#Preview("C2 Replay and markup") {
    NavigationStack {
        ReplayScreen(
            shot: PreviewFixtures.shots[0],
            hasVideo: true,
            capture: PreviewFixtures.armed,
            onDone: {},
            onCompare: {},
            onStepFrame: { _ in },
            onTogglePlayback: {},
            onCycleSpeed: {},
            onSelectTool: { _ in }
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("C2 Replay · shot still sending") {
    NavigationStack {
        ReplayScreen(
            shot: PreviewFixtures.shots[2],
            hasVideo: true,
            capture: PreviewFixtures.armed,
            timeline: ReplayTimeline(playhead: 0),
            speed: .half,
            isPlaying: true,
            selectedTool: nil,
            onDone: {},
            onCompare: {},
            onStepFrame: { _ in },
            onTogglePlayback: {},
            onCycleSpeed: {},
            onSelectTool: { _ in }
        )
    }
    .preferredColorScheme(.dark)
}
