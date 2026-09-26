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

    func testSuccessfulReconnectClearsTheFailureLine() {
        let model = HUDModel()
        model.transcriptLine(TranscriptLine(
            role: .assistant, text: "that turn failed (TimeoutError: hybrid engine reply timed out) - ask again"))
        XCTAssertNotNil(model.transcript, "a failure line must render over the panel")
        model.applyState("listening")
        model.clearTranscript()
        XCTAssertNil(model.transcript, "a successful (re)connect must clear the stale failure line")
        XCTAssertEqual(model.state, .listening, "the cleared HUD is left listening")
    }

    func testDeniedPermissionIsLoudGrantedClearsIt() {
        let model = HUDModel()
        XCTAssertFalse(model.micBlocked, "an unread verdict must not block the face")
        model.applyPermission(.denied)
        XCTAssertTrue(model.micBlocked, "a denied microphone must be a loud blocked face")
        model.applyPermission(.granted)
        XCTAssertFalse(model.micBlocked, "a granted verdict must clear the blocked face")
        model.applyPermission(.restricted)
        XCTAssertTrue(model.micBlocked, "a restricted microphone is blocked too")
        model.applyPermission(.notDetermined)
        XCTAssertTrue(model.micBlocked,
                      "a not-yet-determined verdict must not unblock a blocked face")
    }

    func testMicDenialNoticeBlocksTheFace() {
        let model = HUDModel()
        model.applyMicDenial()
        XCTAssertTrue(model.micBlocked,
                      "digital silence from the device must be the blocked face, not listening")
        model.applyPermission(.granted)
        XCTAssertFalse(model.micBlocked,
                      "a later granted verdict clears a wire-delivered denial")
    }

    func testMicEventsTrackLevelAndGate() {
        let model = HUDModel()
        model.applyMic(level: 0.42, gate: "in-wake")
        XCTAssertEqual(model.micLevel, 0.42, accuracy: 0.0001, "the live level must be tracked")
        XCTAssertEqual(model.gate, .inWake, "the wake gate's phase must be tracked")
        model.applyMic(level: 1.7, gate: "daydreaming")
        XCTAssertEqual(model.micLevel, 1.0, accuracy: 0.0001, "the level must be clamped to the bar")
        XCTAssertEqual(model.gate, .inWake, "an unknown gate string must leave the phase untouched")
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
        XCTAssertEqual(Bridge.parse(line: #"{"type":"waiting","count":2}"#), .waiting(count: 2))
    }

    func testParseRejectsLinesThatAreNotBridgeEvents() {
        XCTAssertNil(Bridge.parse(line: "not json at all"))
        XCTAssertNil(Bridge.parse(line: #"{"type":"mystery"}"#), "an unknown event type must be dropped")
    }

    func testParseReadsMicLevelEvents() {
        XCTAssertEqual(Bridge.parse(line: #"{"type":"mic","level":0.42,"gate":"in-wake"}"#),
                       .mic(level: 0.42, gate: "in-wake"))
        XCTAssertEqual(Bridge.parse(line: #"{"type":"mic","gate":"in-turn"}"#),
                       .mic(level: 0, gate: "in-turn"),
                       "a missing level must default to silence, not crash the panel")
    }
}
