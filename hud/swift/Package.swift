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
        .executableTarget(name: "VoiceHUD", path: "Sources/VoiceHUD"),
        .testTarget(name: "VoiceHUDTests", dependencies: ["VoiceHUD"],
                    path: "Tests/VoiceHUDTests"),
    ]
)
