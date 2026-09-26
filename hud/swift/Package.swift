// swift-tools-version:5.9
// The spoken HUD's native overlay. Zero external dependencies on purpose:
// the stack constraint is a light native AppKit panel, not a bundle that
// ships a runtime. The state machine and transcript model are pure Swift
// so they build and test everywhere Swift does; the panel layer needs a
// GUI session and is verified on the captain's Mac.
import PackageDescription

let package = Package(
    name: "VoiceHUD",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VoiceHUD",
            path: "Sources/VoiceHUD",
            linkerSettings: [
                // Embed the app's Info.plist into the executable's __TEXT
                // segment, so even a bare `swift run` binary carries
                // NSMicrophoneUsageDescription and macOS raises the real
                // microphone prompt for this app instead of silently
                // denying it.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ]),
            ]),
        // The microphone and speaker in one voice-processing unit, for echo
        // cancellation; the Python bridge runs it as a child.
        .executableTarget(name: "VoiceAudio", path: "Sources/VoiceAudio"),
        // On-device OCR of a screenshot, for Ziggy's mac_control tool.
        .executableTarget(name: "ScreenText", path: "Sources/ScreenText"),
        .testTarget(name: "VoiceHUDTests", dependencies: ["VoiceHUD"],
                    path: "Tests/VoiceHUDTests"),
    ]
)
