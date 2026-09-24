// The state machine checks the brief requires: transitions on the events
// the bridge announces. Pure Swift, runs anywhere, no GUI session needed.
import XCTest
@testable import VoiceHUD

final class HUDStateTests: XCTestCase {
    func testIdleIsListening() {
        let model = HUDModel()
        XCTAssertEqual(model.state, .listening, "the HUD must start listening, mic local")
    }

    func testApplyStateFollowsAnnouncedStates() {
        let model = HUDModel()
        model.applyState("thinking")
        XCTAssertEqual(model.state, .thinking, "an announced turn must show thinking")
        model.applyState("speaking")
        XCTAssertEqual(model.state, .speaking, "announced reply audio must show speaking")
        model.applyState("listening")
        XCTAssertEqual(model.state, .listening, "an announced reply_end must return to listening")
    }

    func testApplyStateIgnoresUnknownStrings() {
        let model = HUDModel()
        model.applyState("thinking")
        model.applyState("daydreaming")
        XCTAssertEqual(model.state, .thinking, "an unknown state string must leave the model untouched")
    }

    func testTranscriptKeepsLatestLine() {
        let model = HUDModel()
        model.transcriptLine(TranscriptLine(role: .user, text: "what time is it"))
        model.transcriptLine(TranscriptLine(role: .assistant, text: "three o'clock"))
        XCTAssertEqual(model.transcript?.role, .assistant, "the latest transcript line must win")
        XCTAssertEqual(model.transcript?.text, "three o'clock")
    }
}

final class BridgeEventTests: XCTestCase {
    func testParseReadsTheBridgeSchema() {
        XCTAssertEqual(Bridge.parse(line: #"{"type":"state","state":"speaking"}"#),
                       .state("speaking"))
        XCTAssertEqual(Bridge.parse(line: #"{"type":"transcript","role":"assistant","text":"hi"}"#),
                       .transcript(role: "assistant", text: "hi"))
        XCTAssertEqual(Bridge.parse(line: #"{"type":"notice","event":"wake"}"#),
                       .notice(event: "wake", error: nil))
        XCTAssertEqual(
            Bridge.parse(line: #"{"type":"notice","event":"turn-failed","error":"RuntimeError: the model stream broke"}"#),
            .notice(event: "turn-failed", error: "RuntimeError: the model stream broke"))
    }

    func testParseRejectsLinesThatAreNotBridgeEvents() {
        XCTAssertNil(Bridge.parse(line: "not json at all"))
        XCTAssertNil(Bridge.parse(line: #"{"type":"mystery"}"#), "an unknown event type must be dropped")
    }
}
