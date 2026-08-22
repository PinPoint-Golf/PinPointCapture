# PinPointCapture design system

Everything in this directory exists because there is **no system control that
does the job**. That is the entire admission criterion. If you find yourself
about to add a component here, first check the "What not to build" section
below — most of what looks like a component in the mockup is a stock SwiftUI
control with the accent tint applied.

Source of truth: `docs/design/mockup v1/README.md`, sections *Design tokens* and the
`In the HTML | Build it as` table. Where this file and that one disagree, that
one wins.

- Swift 6 language mode, strict concurrency, iOS 18.0.
- Dark appearance only in this pass.
- No third-party dependencies.

---

## 1. The colour rule

> **Green is the only brand tint; orange, red and blue appear only in their
> system meanings. Capture status never turns red.**

Red is reserved for the host and for destructive actions, because *capture
continuing* is the product's core promise. A weak link, a lost host, a full
queue, a thermal warning — none of those turn the capture indicator red, because
none of them stop capture. On B3's **Lost** state the first telemetry row is
`Capture — still armed` in accent, *above* the error; that ordering is the rule
made visible and must not be rearranged to put the failure first.

`StatusTone` encodes this. Pick the tone from what the value *means*:

| Tone | Colour | Means |
|---|---|---|
| `.neutral` | `.secondaryLabel` on `.tertiarySystemFill` | plain information, no opinion — `On device`, `Lens · locked` |
| `.accent` | `#30D158` | retained, synced, in Studio, confirmed, primary action |
| `.warning` | `#FF9F0A` | degraded but still capturing — weak link, marginal light, partial coverage |
| `.error` | `#FF453A` | host gone, permission blocked, destructive action (Disarm) |
| `.progress` | `#5AA9FF` | in flight — sending, catching up, resyncing |

Colour is never the only carrier of meaning: every component folds
`StatusTone.accessibilityDescription` into its VoiceOver label, so a warning
row announces "Warning" and a lost host announces "Problem".

### Colour tokens (`Assets.xcassets`)

Five assets, reachable as `Color.ppAccent`, `.ppWarning`, `.ppError`,
`.ppProgress`, `.ppAccentWash`.

`Accent` is also the **project accent colour asset**: the app target sets
`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = Accent` in `project.yml`.
⚠ Without that setting every stock control ships system blue, which is the one
way to break the colour rule above without touching this directory. Because it
is set, `.borderedProminent` buttons, `Toggle`s, `Picker`s, selection highlights
and `List` chevrons are already green: **do not write `.tint(.ppAccent)` on a
stock control.**

### Colours that are deliberately NOT tokens

Background, grouped background, fill, separator, label, secondary label and
tertiary label are **system semantic colours** and have no assets. Use
`Color(.systemBackground)`, `Color(.secondarySystemBackground)`,
`Color(.tertiarySystemFill)`, `Color(.separator)`, `Color(.label)`,
`Color(.secondaryLabel)`, `Color(.tertiaryLabel)`. They already carry the exact
dark values the handoff lists, they track Increase Contrast, and they need no
maintenance. Do not add assets for any of them.

---

## 2. Typography

Every role is a Dynamic Type text style. The HTML's pixel sizes (34 / 26 / 18 /
16 / 14 / 13 / 12) are **medium fidelity** and must never be reproduced as fixed
point sizes — layouts flow, they are not measured off the 393pt board.

| `Font` role | Built on | Where |
|---|---|---|
| `.ppLargeTitle` | `.largeTitle.bold()` | A1 app name — but usually you want `.navigationTitle` instead |
| `.ppScreenHeading` | `.title.bold()` | sheet headings: B2 host name, B4, B5 |
| `.ppCardTitle` | `.title3.weight(.semibold)` | A3 choice titles, B3 state title, InfoCard title |
| `.ppRowLabel` | `.body` | left-hand label of any row |
| `.ppSupporting` | `.subheadline` | the sentence under a title |
| `.ppFootnote` | `.footnote` | footnotes, disclaimers, disabled |
| `.ppMeasuredValue` | `.body.weight(.semibold).monospaced()` | telemetry values |
| `.ppMeasuredDetail` | `.footnote.monospaced()` | the mono line under a ProgressRow title, C1 rail |
| `.ppEyebrow` | `.caption.weight(.semibold).monospaced()` | applied for you by `EyebrowLabel` |
| `.ppStatusChip` | `.caption.weight(.semibold)` | applied for you by `StatusChip` |

### `.ppMeasuredValue(tone:)` — the load-bearing modifier

> SF Mono for **any number the user could not have guessed.**

This distinction runs through the whole app and is the reason the telemetry
reads as instrumentation rather than as marketing. Anything the *device
measured* is mono: clock offsets, residuals, drift, frame rates, timestamps,
byte counts, shot counts, exposure, ISO, throughput, storage headroom.

Anything the user already knows or could have written is **not** mono: club
names, session names, host names, button titles, body copy.

```swift
Text("−3.184 ms ± 0.21").ppMeasuredValue()             // measured  -> mono
Text("149.6 fps · 0 drops").ppMeasuredValue(tone: .accent)
Text("1/1600 s · ISO 2200 · 150 fps").ppMeasuredValue(tone: .warning)
Text("Bay 3 — Mac Studio").font(.ppCardTitle)          // a name    -> not mono
```

`.ppMeasuredDetail(tone:)` is the same rule at footnote size, for the line that
sits *underneath* a plain-language title.

Both apply `.monospacedDigit()` so a live-updating number does not jitter.

---

## 3. Metrics (`PPMetrics`)

Radii: `.small` 8 (timeline, chips) · `.control` 12 (inline controls) · `.card`
14 (cards, buttons) · `.choiceCard` 18 · `.sheet` 28 (use
`.presentationCornerRadius(PPMetrics.Radius.sheet)`).

Sizes — **floors, not suggestions. Do not shrink these to make a layout fit:**

| | |
|---|---|
| `minimumTapTarget` | **44pt — every tap target, no exceptions** |
| `primaryButton` | 50pt |
| `markupTool` | 48pt — C2 markup tools, sized for gloved hands |
| `frameStep` | 54pt — C2 frame-step buttons, sized for gloved hands |
| `transportPlay` | 64pt |

Spacing: `screenMargin` 20 · `cardPadding` 16 · `rowPadding` 12 · `itemGap` 12 ·
`groupGap` 24.

---

## 4. Components

Six. Each has a `#Preview` — open the file to see it.

### `StatusChip(_ title: String, tone: StatusTone = .neutral)`
`StatusChip.swift`

A small pill carrying one short phrase.

- **Used by:** C3 per-shot sync state (`In Studio` accent / `Sending 61%`
  progress / `On device` neutral); A3 evidence chips (via `ChoiceCard`); B5
  `LIKELY` / `UNLIKELY`.
- **Three words, not icons.** There is no `systemImage` parameter and one must
  not be added. A golfer glancing at the shot list from the mat has to read a
  *state*; a coloured glyph does not say whether the host has confirmed the shot.
- `In Studio` means **confirmed by the host**, never merely uploaded.

### `TelemetryRow(_ label:, _ value:, tone: StatusTone? = nil, spokenValue: String? = nil)`
`TelemetryRow.swift`

Plain-language label left, measured value in mono right-aligned, optionally
tinted. Built on `LabeledContent`, so it drops straight into a
`List(.insetGrouped)` and reads to VoiceOver like a system row.

- **Used by:** A7's five-row summary; B3's five-row telemetry list in all four
  states; B4's two-row network list.
- `tone` tints only the value, and only when the number itself carries a verdict.
  Most rows leave it `nil`.
- `spokenValue` overrides what VoiceOver says: `"−3.184 ms ± 0.21"` should be
  spoken as `"minus 3.184 milliseconds, plus or minus 0.21"`.
- **Row order is designed.** In B3 Lost, `Capture — still armed` is row one.

### `EyebrowLabel(_ text: String, tone: StatusTone = .neutral)`
`EyebrowLabel.swift`

Upper-cased mono caption with 1.0 tracking.

- **Used by:** B2 `PAIRING` (accent); A1 `THIS DEVICE` (accent, via `InfoCard`);
  B6 `OR CARRY ON WITHOUT IT` (neutral); A6 `GOLFER · IN FRAME`.
- Input is written in normal case and upper-cased for display, so VoiceOver
  speaks words rather than spelling out letters.
- It is a label for a *region*, not a document heading — the real heading beside
  it keeps `.isHeader`.
- Inside a `List`, a plain `Section("…")` header already looks like this. Use the
  section header; reach for `EyebrowLabel` only outside list structure.

### `InfoCard(_ message:, title:, eyebrow:, systemImage:, tone:)`
`InfoCard.swift`

A grouped-background card with one sentence of explanation.

- **Used by:** A1 capability card (`eyebrow: "This device"`, accent); A3
  footnote (neutral); A7 "Not connected to a host" (neutral); B2 "Why the wait"
  (`title:`); B5 orange coverage notice (warning); B6 "To fix it".
- Tone discipline: `.warning` only when something is degraded but capture
  continues; `.error` only when the host is gone or a permission is blocked.
  **"No host" on A7 is a normal state and stays neutral** — it is not a failure.
- `systemImage` takes an SF Symbol name. Never a redrawn glyph.

### `ProgressRow(_ title:, detail:, state:)`
`ProgressRow.swift`

Status glyph + plain-language title + mono detail line. `State` is
`.done` / `.inProgress` / `.pending` / `.failed`.

- **Used by:** B2's four handshake rows.
- The pattern is "a friendly register doing work": the step name is readable by
  anyone, the number that proves it is happening sits below in mono.
- **The detail must reflect real progress.** `14 of 20 exchanges` is the actual
  exchange count from the sync burst, never a fake animation.
- `.inProgress` uses the system `ProgressView` — the one place a spinner is
  correct, and the system already suppresses its motion under Reduce Motion.
- `.failed` is for the *host* handshake only. A capture step never fails to red.

### `ChoiceCard(title:, description:, chips:, isSelected:, action:)`
`ChoiceCard.swift`

A large selectable card. Selected = 2pt accent border + accent wash + filled
checkmark. Radius 18.

- **Used by:** A3 (host vs standalone); B5 (the two reconciliation candidates).
- **The two A3 cards carry equal visual weight and equal copy length by design.**
  Standalone is the normal case, not the consolation prize. Do not style the host
  option as recommended.
- Selection is a routing choice and reversible, which is why this is a tappable
  card and not a `Toggle` or a `Picker` row.
- Announces `.isSelected` to VoiceOver; the selection change animates unless
  Reduce Motion is on.
- Chips wrap onto new lines at large Dynamic Type sizes via a `fileprivate`
  `ChipFlowLayout`. That layout is private on purpose and is **not** a
  general-purpose flow layout for the app to adopt.

---

## 5. What NOT to build

Three more agents will read this file. Everything below is a **system control**.
Building a custom version of any of it is a bug, not a contribution — the
requirement is a 100% native look and feel, so the correct implementation of
every screen in the handoff is the standard system control, not a recreation of
the HTML.

| The mockup shows | Build it as | Not |
|---|---|---|
| Grouped card lists (`#1C1C1E`, 14pt radius, 0.5px separators) — A4 permission cards, A7 summary, B1 host list, B3 settings list, B6 "carry on" list | `List { Section { … } }` + `.listStyle(.insetGrouped)` | a `VStack` of `RoundedRectangle`s |
| 34pt bold headings — A2, A3, A4, A5, B5, B6 | `.navigationTitle("…")` + `.navigationBarTitleDisplayMode(.large)` | a `Text` with `.ppLargeTitle` at the top of a `ScrollView` |
| 50pt green filled buttons — *Get started*, *Continue*, *Join network*, *Try again* | `Button` + `.buttonStyle(.borderedProminent)` + `.controlSize(.large)` | a custom button style |
| Plain green text actions — *I have a pairing code*, *Capture without a host*, *Stay on current Wi-Fi* | `Button` + `.buttonStyle(.plain)` (or `.borderless`), inheriting the accent tint | anything hand-rolled |
| The 4-way pill switcher on B3 | `Picker` + `.pickerStyle(.segmented)` — and note it **ships disabled**: it exists only so a reviewer can flip states | a custom pill row |
| Bottom rounded panel — B4, B3 host sheet | `.sheet` + `.presentationDetents([…])` + `.presentationDragIndicator(.visible)` + `.presentationCornerRadius(PPMetrics.Radius.sheet)` | a custom overlay with a hand-drawn grabber |
| Rows with a trailing chevron — *Enter the six-digit code*, *Connection log*, *Connect by cable* | `NavigationLink` in a `List` | an `HStack` with `Image(systemName: "chevron.right")` |
| Rows with a trailing value — *Send video over · Wi-Fi and cable* | `LabeledContent`, or `TelemetryRow` when the value is a measurement | a custom two-column row |
| Toggles, steppers, sliders | the system control, untinted | — |
| Every glyph | **SF Symbols**: `camera`, `mic`, `wifi`, `wifi.slash`, `checkmark.circle.fill`, `exclamationmark.circle.fill`, `info.circle`, `gyroscope`, `qrcode.viewfinder`, `cable.connector`, `arrow.down.circle`, `chevron.right`, `play.fill`, `backward.frame`, `forward.frame`, `line.diagonal`, `circle`, `scribble` | a redrawn path or an inline SVG port |
| The 393×852 frame, the drawn status bar, the home indicator | the real device — no bezel, no status bar, respect safe areas | — |
| A tab bar | **there is none.** The capture screen is the app root; the C1 host chip opens the B3 sheet, and *Session · 41* opens C3 | a `TabView` |
| Motion | system defaults — sheet presentation, list insertion, a crossfade for connection-state change. The armed pill dot may pulse slowly, honouring Reduce Motion | custom animation in this pass |

Two further "do not build" notes:

- **No general-purpose layout, spacing or button framework.** This is a small set
  of gap-fillers, not a UI framework. Six components is the intended size.
- **Connection-state transitions animate colour and copy only.** The B3 layout
  never reflows between Connected / Weak / Lost / Back — one layout carries all
  four states, so a glance from the mat does not need re-reading.

---

## 6. Accessibility

Not optional, and none of it is visible in the HTML.

- **VoiceOver:** every component sets an explicit label, and combines its
  children so a row is one element rather than three. Tone is folded into the
  spoken label so meaning is never carried by colour alone.
- **Dynamic Type:** every font is a text style. Chip rows wrap. Nothing is
  measured off the 393pt board.
- **Reduce Motion:** honoured in `ChoiceCard`'s selection animation. Anything
  added later that animates must check
  `@Environment(\.accessibilityReduceMotion)`.
- **Tap targets:** 44pt minimum everywhere, enforced by `minHeight` in the
  components that are tappable rows.
- **Numbers:** `spokenValue` on `TelemetryRow` exists so VoiceOver reads
  `"−3.184 ms ± 0.21"` as words. Use it for any value with symbols in it.

---

## 7. Verification

There is no app target in this directory. Type-check the sources directly:

```
xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios18.0 \
  -swift-version 6 -strict-concurrency=complete \
  Sources/UI/DesignSystem/*.swift
```

The asset catalogue is not exercised by that command — `Color("Accent")` and
friends only resolve once `Assets.xcassets` is a member of the app target.
