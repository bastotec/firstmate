// The HUD's whole visible behavior is one state machine with three states
// and a transcript line. Pure Swift, no AppKit: the same file builds on a
// headless CI box and drives the panel on the captain's Mac.
//
// States and their meanings, which the panel renders verbatim:
//   listening  the wake layer owns the mic; nothing streams anywhere
//   thinking   a turn is open; the captain's audio goes to the relay child
//   speaking   reply audio is arriving from the relay
//
// Transitions are event-driven, exactly the events the engine's callbacks
// deliver, so the panel never invents a state the wire did not announce.

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

    /// A turn opened: the engine's begin-turn event.
    public func beginTurn() {
        state = .thinking
    }

    /// Reply audio arrived: the engine's first-audio event.
    public func replyAudio() {
        // Only a turn that is open can be answered. Audio outside a turn is
        // a stale frame the engine already guards against; the model never
        // rewards it with a state change.
        if state == .thinking {
            state = .speaking
        }
    }

    /// The relay's reply_end mark: the turn is over, the mic is local again.
    public func replyEnded() {
        state = .listening
    }

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

    /// The engine died or was closed: no state but listening is truthful,
    /// because with no relay child the mic is not streaming anywhere.
    public func engineClosed() {
        state = .listening
    }
}
