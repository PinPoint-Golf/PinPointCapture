// DeviceProfiles.json — per-model facts no API reports.
//
// PLAN A13 / REQ-PORT-10: device profile data is DATA keyed by device model,
// loaded by the app and validated by the library's provenance rules. Everything
// PPCP needs that AVFoundation will not tell us lives in this file, so that
// calibrating a new model is an edit HERE and nowhere in the code.
//
// ============================================================================
// NOTHING IN THIS FILE HAS BEEN MEASURED. EVERY `provenance` IS `assumed`.
// ============================================================================
//
// Plan A12: "every timing constant nobody has measured is declared `assumed` …
// no exception until the rig exists." Both quantities PPCP asks for come from an
// LED timecode rig, per device model (REQ-TEST-1/2), and no model has been
// through one. PPCP-CORE 5.7f forbids declaring `measured` for a value taken
// from a vendor document, a sibling model or a table — which is all this file
// could ever be — so `measured` must never appear here. CT-S7 assertion 2 tests
// exactly that.
//
// FIELDS
//
//   frameStartToExposureOffsetNs
//     CORE 5.7a/5.7b. Present because and only because the convention is
//     `nominal_frame_start`, which is what every AVFoundation source declares.
//     Declared explicitly AT ZERO rather than omitted: "a declared zero is a
//     checkable claim; an omitted field is not — but a declared zero with no
//     provenance is indistinguishable from an unmeasured one" (5.7b).
//
//   geometry[].readout
//     Exactly one of:
//       { "measuredNs": N }                        — from the rig, on THIS model
//       { "vendorNs": N }                          — a vendor document or API
//       { "assumedFractionOfFrameInterval": F }    — a RULE, not a number
//
//     The third form is deliberate and is what every entry uses today. A
//     placeholder written as a number is indistinguishable from a rig number
//     once it is in the file, and the next person to edit this cannot tell which
//     they are looking at. A rule can only ever produce `assumed`.
//
//     F = 1.0 means "the whole nominal frame interval". That is the LARGEST
//     readout physically consistent with the declared rate, and the direction of
//     the error is chosen on purpose: an over-large assumed readout shows up as
//     a systematic tilt across the image in fused output, where somebody
//     notices it. An under-small one hides. Neither is right; one is findable.
//
//     Replacing an entry with { "measuredNs": N } is the entire cost of a rig
//     measurement. No code changes.
//
//   geometry[].direction
//     CORE 6.2. ⚠ A FINDING: `readout_ns` carries a mandatory provenance and
//     `direction` carries none, so this guess — from the physical orientation of
//     every rear iPhone sensor, not from a rig — is indistinguishable on the
//     wire from a measurement. Reported; there is no field to be honest in.
//
//   geometry[].rows
//     CORE 6.2b, "rows in the delivered image, R". OMITTED, and omission means
//     "the format's own height", which is what 6.2b defines R to be. Present
//     only as an override for a model that delivers a row count its format
//     description does not report. No model does.
//
//   geometry[] matching
//     An entry with `width`/`height`/`fps` applies to profiles matching all the
//     keys it sets; an entry with none of them is the model's default. Most
//     specific wins. A rig measurement of one mode is one narrow entry added
//     above the default — CORE 5.7c: "1080p240 and 1080p120 are separate
//     self-tests with separate results", and separate readouts.
//
//   _default
//     Used for a model identifier this file does not list. An unprofiled device
//     still captures — capability is enumerated, not looked up — and its timing
//     is `assumed` by the same rule as everything else rather than absent, which
//     would refuse the declaration outright.
//
// ⛔ There is no `measured` anywhere below and there must never be one. A
// self-test result (CORE 5.8 MeasuredCapability) is a different thing entirely,
// belongs to the running device, and never to this file.
