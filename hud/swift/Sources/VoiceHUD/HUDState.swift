// The HUD's whole visible behavior is one state machine with three states
// and a transcript line. Pure Swift, no AppKit: the same file builds on a
// headless CI box and drives the panel on the captain's Mac.
//
// States and their meanings, which the panel renders verbatim:
//   listening  the wake layer owns the mic; nothing streams anywhere
//   thinking   a turn is open; the captain's audio goes to the relay child
//   speaking   reply audio is arriving from the relay
//
// Two facts the panel renders alongside the state are its own, not the
// wire's: the macOS microphone-permission verdict (the blocked face below)
// and the live mic level. The model has exactly one way in per thing it
// owns: a state string the bridge announced, a transcript line the bridge
// delivered, a permission verdict the panel read, so the panel never invents
// a state the wire did not announce.

import Foundation

public enum HUDState: String, Equatable, CaseIterable {
    case listening
    case thinking
    case speaking
}

/// The macOS microphone permission verdict, as AVCaptureDevice reports it.
/// The panel reads it itself and re-reads it on activation and focus, so a
/// denied microphone is never mistaken for a quiet room.
public enum MicPermission: String, Equatable, CaseIterable {
    case notDetermined
    case granted
    case denied
    case restricted
}

/// The wake gate's own phase, as the bridge's mic events carry it.
public enum GatePhase: String, Equatable, CaseIterable {
    case listening
    case inWake = "in-wake"
    case inTurn = "in-turn"
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

/// The machine the panel renders. `state` and `transcript` are the main
/// things drawn; the mic facts below keep the debug surface truthful: the
/// level bar always moves, the gate phase is always named, and a blocked
/// microphone is loud instead of a silent "listening".
public final class HUDModel {
    public private(set) var state: HUDState = .listening
    public private(set) var transcript: TranscriptLine?
    public private(set) var micBlocked = false
    public private(set) var micLevel: Double = 0
    public private(set) var gate: GatePhase = .listening

    /// Labels the panel shows, one per state, overridable for tests.
    public var labels: [HUDState: String] = [
        .listening: "listening",
        .thinking: "thinking",
        .speaking: "speaking",
    ]

    /// What the loud blocked face says, overridable for tests.
    public var blockedLabel = "microphone blocked"

    public init() {}

    /// A transcript line arrived from the relay's TEXT frames.
    public func transcriptLine(_ line: TranscriptLine) {
        transcript = line
    }

    /// The rendered line is cleared here, on a successful (re)connect: the
    /// panel must not keep showing the failure line the reconnect recovered
    /// from - a stale "that turn failed" over a healthy listening HUD reads
    /// as a broken HUD.
    public func clearTranscript() {
        transcript = nil
    }

    /// A state string from the bridge, applied only if it names a real state.
    /// Unknown strings leave the model untouched: the panel never renders a
    /// state the wire did not announce.
    public func applyState(_ raw: String) {
        if let s = HUDState(rawValue: raw) {
            state = s
        }
    }

    /// The macOS permission verdict: denied or restricted is loud (the
    /// blocked face), granted clears it. notDetermined changes nothing -
    /// the verdict has not arrived yet.
    public func applyPermission(_ permission: MicPermission) {
        switch permission {
        case .denied, .restricted:
            micBlocked = true
        case .granted:
            micBlocked = false
        case .notDetermined:
            break
        }
    }

    /// The bridge's mic-denied notice: the device opened but delivered
    /// digital silence, which is the denied signature the panel must not
    /// render as a working listening face.
    public func applyMicDenial() {
        micBlocked = true
    }

    /// A mic event from the bridge: the live level and the wake gate's own
    /// phase. An unknown gate string leaves the phase untouched.
    public func applyMic(level: Double, gate raw: String) {
        micLevel = max(0, min(1, level))
        if let g = GatePhase(rawValue: raw) {
            gate = g
        }
    }
}
