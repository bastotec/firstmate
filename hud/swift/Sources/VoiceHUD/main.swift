// The overlay panel: always visible, always on top, draggable anywhere.
// An NSPanel at .floating level with .nonactivatingPanel style, so it never
// steals focus from whatever the captain is doing and never appears in the
// Dock. Dragging is whole-panel (mouseDownCanMoveWindow) with no title bar.
//
// What this file can prove headlessly: nothing - it needs a GUI session and
// a live mic, both of which live on the captain's Mac. What it must never
// do: touch the network, hold the mic outside the wake layer, or invent a
// state the engine did not announce. The state machine it renders is the
// same headlessly-tested HUDModel.
//
// Launch: build the package, run the binary with the firstmate repo root as
// the working directory; the panel finds the engine and wake layer from it.

import AppKit

// ------------------------------------------------------------------ model

let model = HUDModel()

// ------------------------------------------------------------------ panel

let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 340, height: 84),
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
panel.isMovableByWindowBackground = true
panel.hasShadow = true
panel.titleVisibility = .hidden
panel.titlebarAppearsTransparent = true
panel.backgroundColor = NSColor.windowBackgroundColor
panel.isOpaque = false
panel.appearance = NSAppearance(named: .vibrantDark)

// A rounded background view that is also the drag surface.
let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 84))
container.wantsLayer = true
container.layer?.cornerRadius = 18
container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor

// ------------------------------------------------------------------ text

func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = .white
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}

let stateLabel = makeLabel(model.labels[model.state] ?? "listening", size: 15, weight: .semibold)
let dot = NSView()
dot.wantsLayer = true
dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
dot.layer?.cornerRadius = 5
dot.translatesAutoresizingMaskIntoConstraints = false

let transcriptLabel = makeLabel("", size: 12, weight: .regular)
transcriptLabel.textColor = NSColor(white: 1.0, alpha: 0.72)
transcriptLabel.lineBreakMode = NSLineBreakMode.byTruncatingTail
transcriptLabel.maximumNumberOfLines = 1
transcriptLabel.cell?.truncatesLastVisibleLine = true
transcriptLabel.cell?.wraps = false

container.addSubview(dot)
container.addSubview(stateLabel)
panel.contentView?.addSubview(container)
container.addSubview(transcriptLabel)

// Layout: dot left, state beside it, transcript below, inset margins.
NSLayoutConstraint.activate([
    container.widthAnchor.constraint(equalToConstant: 340),
    container.heightAnchor.constraint(equalToConstant: 84),

    dot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
    dot.centerYAnchor.constraint(equalTo: stateLabel.centerYAnchor),

    stateLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
    stateLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),

    transcriptLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
    transcriptLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
    transcriptLabel.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 6),
])

func render() {
    stateLabel.stringValue = model.labels[model.state] ?? model.state.rawValue
    switch model.state {
    case .listening: dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
    case .thinking: dot.layer?.backgroundColor = NSColor.systemYellow.cgColor
    case .speaking: dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
    }
    if let line = model.transcript {
        transcriptLabel.stringValue = "\(line.role == .user ? "you" : "ziggy"): \(line.text)"
    } else {
        transcriptLabel.stringValue = ""
    }
}

render()

// Place near the top-right of the main screen, away from the notch and Dock.
if let screen = NSScreen.main {
    let visible = screen.visibleFrame
    let origin = NSPoint(
        x: visible.maxX - 340 - 24,
        y: visible.maxY - 84 - 24
    )
    panel.setFrameOrigin(origin)
}

panel.orderFrontRegardless()

// ------------------------------------------------------------------ app

// An accessory app: no Dock icon, no menu bar, no focus stealing. The panel
// is the whole product surface.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// The bridge is told to quit when the app terminates, so the mic thread, the
// decoder child and the relay child all come down with the panel instead of
// being orphaned holding the microphone.
final class HUDAppDelegate: NSObject, NSApplicationDelegate {
    let bridge: Bridge

    init(bridge: Bridge) {
        self.bridge = bridge
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        bridge.quit()
        return .terminateNow
    }
}

// ------------------------------------------------------------------ engine

// The engine and wake layer are Python in this repo. The bridge is the
// Python half of this process: it owns the wake gate, the decoder child and
// the relay child, and reports state as one JSON object per line on stdout.
// The panel sends nothing back except "quit" at exit. Launching the bridge
// needs the repo root, which is the working directory at launch.
let bridgeProcess = Bridge.launch(repoRoot: FileManager.default.currentDirectoryPath)
app.delegate = HUDAppDelegate(bridge: bridgeProcess)

Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    // Bridge events arrive on a background thread; AppKit drawing happens
    // on the main thread only.
    DispatchQueue.main.async {
        for event in bridgeProcess.drainEvents() {
            switch event {
            case .state(let s):
                model.applyState(s)
            case .transcript(let role, let text):
                model.transcriptLine(TranscriptLine(
                    role: role == "user" ? .user : .assistant, text: text))
            case .notice(let event):
                // Notices the HUD must show rather than just carry: a dead
                // engine or an abandoned turn leaves the mic deaf, and the
                // panel says so instead of rendering listening forever.
                switch event {
                case "engine-fault":
                    model.applyState("listening")
                    model.transcriptLine(TranscriptLine(
                        role: .assistant, text: "voice engine failed - restart the HUD"))
                case "decoder-fault":
                    model.applyState("listening")
                    model.transcriptLine(TranscriptLine(
                        role: .assistant, text: "the decoder died - restart the HUD"))
                case "mic-fault":
                    model.applyState("listening")
                    model.transcriptLine(TranscriptLine(
                        role: .assistant, text: "no microphone - restart the HUD"))
                case "turn-timeout":
                    model.applyState("listening")
                    model.transcriptLine(TranscriptLine(
                        role: .assistant, text: "that turn got no reply - ask again"))
                case "output-unavailable":
                    model.transcriptLine(TranscriptLine(
                        role: .assistant, text: "no output device - replies are text only"))
                default:
                    break
                }
            }
        }
        render()
    }
}

NSApplication.shared.run()
