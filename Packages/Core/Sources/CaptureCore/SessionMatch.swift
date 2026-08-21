//  SessionMatch.swift
//  Reconciling a device session against one the host already holds.
//
//  ⛔ REQ-OFF-12: DO NOT AUTO-MERGE. The host may already hold partial data for
//  the same session — a launch monitor record, or an online portion captured
//  before WiFi failed. Candidate matches are surfaced with their evidence and
//  require confirmation.
//
//  Matching itself is tractable: ~50 ordered shots with inter-shot intervals is a
//  well-determined sequence-alignment problem. The confirmation requirement is
//  about the cost of being wrong, not the difficulty of being right — a silent
//  mis-merge corrupts the session record in a way that is hard to notice and
//  harder to undo.

import Foundation

/// Screen-local model: B5 is the only screen that reconciles, so this is not a
/// Core type and not a shared component.
public struct SessionMatchCandidate: Identifiable, Sendable, Hashable {

    /// A measured fact supporting or undermining the match. Both sides are mono
    /// — they are numbers the user could not have guessed.
    public struct Evidence: Sendable, Hashable {
        public let label: String
        public let value: String
        /// What VoiceOver should say when the value contains symbols.
        public let spokenValue: String?

        public init(label: String, value: String, spokenValue: String? = nil) {
            self.label = label
            self.value = value
            self.spokenValue = spokenValue
        }
    }

    public enum Likelihood: String, Sendable, Hashable {
        case likely, unlikely

        /// Upper case here because these are the badges as designed.
        public var chipTitle: String {
            switch self {
            case .likely: "LIKELY"
            case .unlikely: "UNLIKELY"
            }
        }
    }

    public let id: UUID
    /// "Wednesday range · 18:20" — a name and a time the user recognises.
    public let title: String
    /// "Studio holds 29 shots from a launch monitor".
    public let detail: String
    public let likelihood: Likelihood
    public let evidence: [Evidence]

    public init(id: UUID = UUID(), title: String, detail: String,
                likelihood: Likelihood, evidence: [Evidence] = []) {
        self.id = id
        self.title = title
        self.detail = detail
        self.likelihood = likelihood
        self.evidence = evidence
    }
}
