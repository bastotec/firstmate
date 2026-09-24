// The HUD's whole visible behavior is one state machine with three states
// and a transcript line. Pure Swift, no AppKit: the same file builds on a
// headless CI box and drives the panel on the captain's Mac.
//
// States and their meanings, which the panel renders verbatim:
//   listening  the wake layer owns the mic; nothing streams anywhere
//   thinking   a turn is open; the captain's audio goes to the relay child
//   speaking   reply audio is arriving from the relay
//
// The model has exactly one way in per thing it owns: a state string the
// bridge announced, and a transcript line the bridge delivered, so the
// panel never invents a state the wire did not announce.

import Foundation

public enum HUDState: String, Equatable, CaseIterable {
    case listening
    case thinking
    case speaking
}

/// One line of transcript: who said it and what. The HUD shows the latest
/// line only, so the model is deliberately minimal.
public struct TranscriptLine: Equatable {
    public let role: TranscriptRole
    public let text: String

    public init(role: TranscriptRole, text: String) {
        self.role = role
        self.text = text
    }
}

public enum TranscriptRole: String, Equatable {
    case user
    case assistant
}

/// The machine the panel renders. `state` and `transcript` are the only
/// things drawn; everything else here exists to keep them truthful.
public final class HUDModel {
    public private(set) var state: HUDState = .listening
    public private(set) var transcript: TranscriptLine?

    /// Labels the panel shows, one per state, overridable for tests.
    public var labels: [HUDState: String] = [
        .listening: "listening",
        .thinking: "thinking",
        .speaking: "speaking",
    ]

    public init() {}

    /// A transcript line arrived from the relay's TEXT frames.
    public func transcriptLine(_ line: TranscriptLine) {
        transcript = line
    }

    /// A state string from the bridge, applied only if it names a real state.
    /// Unknown strings leave the model untouched: the panel never renders a
    /// state the wire did not announce.
    public func applyState(_ raw: String) {
        if let s = HUDState(rawValue: raw) {
            state = s
        }
    }
}
