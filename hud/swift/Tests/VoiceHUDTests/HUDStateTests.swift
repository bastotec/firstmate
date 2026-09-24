// The state machine checks the brief requires: transitions on synthetic
// events. Pure Swift, runs anywhere, no GUI session needed.
import XCTest
@testable import VoiceHUD

final class HUDStateTests: XCTestCase {
    func testIdleIsListening() {
        let model = HUDModel()
        XCTAssertEqual(model.state, .listening, "the HUD must start listening, mic local")
    }

    func testTurnLifecycle() {
        let model = HUDModel()
        model.beginTurn()
        XCTAssertEqual(model.state, .thinking, "an open turn must show thinking")
        model.replyAudio()
        XCTAssertEqual(model.state, .speaking, "reply audio must show speaking")
        model.replyEnded()
        XCTAssertEqual(model.state, .listening, "reply_end must return to listening")
    }

    func testStaleAudioDoesNotInventASpeakingState() {
        let model = HUDModel()
        // Audio with no turn open is a stale frame; the model must not
        // reward it with a state change.
        model.replyAudio()
        XCTAssertEqual(model.state, .listening, "audio outside a turn must not speak")
    }

    func testEngineClosedReturnsToListening() {
        let model = HUDModel()
        model.beginTurn()
        model.engineClosed()
        XCTAssertEqual(model.state, .listening, "a closed engine must not claim a live turn")
    }

    func testTranscriptKeepsLatestLine() {
        let model = HUDModel()
        model.transcriptLine(TranscriptLine(role: .user, text: "what time is it"))
        model.transcriptLine(TranscriptLine(role: .assistant, text: "three o'clock"))
        XCTAssertEqual(model.transcript?.role, .assistant, "the latest transcript line must win")
        XCTAssertEqual(model.transcript?.text, "three o'clock")
    }
}
