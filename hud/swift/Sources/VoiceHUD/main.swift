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
import AVFoundation

// ------------------------------------------------------------------ model

let model = HUDModel()

// The panel reads the microphone permission verdict itself, so a denied
// microphone is a loud blocked face instead of a silent "listening". It is
// re-read on app activation and whenever the panel gains focus, so flipping
// the switch in System Settings is picked up without a relaunch.
func micPermissionNow() -> MicPermission {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return .granted
    case .denied: return .denied
    case .restricted: return .restricted
    default: return .notDetermined
    }
}

final class MicSettingsOpener: NSObject {
    // The one deep link that matters when the mic is blocked: this app's
    // own toggle in System Settings' microphone privacy pane.
    @objc func open(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

let micSettingsOpener = MicSettingsOpener()

// ------------------------------------------------------------------ panel

let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 220, height: 250),
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
let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 250))
container.wantsLayer = true
container.layer?.cornerRadius = 18
container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor

// ------------------------------------------------------------------ glow
//
// The whole panel lights up the instant the wake word is heard, and stays lit
// while Ziggy works and talks: a rotating colour ring around the edge plus a
// breathing halo. Idle listening and mute are dark, so a glow always means
// "Ziggy is on it".

enum GlowMode { case off, awake, speaking }

final class Glow {
    let ring = CAGradientLayer()
    let mask = CAShapeLayer()
    let halo = CALayer()
    private(set) var mode: GlowMode = .off

    init(on host: CALayer, size: CGSize, radius: CGFloat) {
        host.masksToBounds = false
        // The halo: a soft coloured shadow behind the panel.
        halo.frame = CGRect(origin: .zero, size: size)
        halo.cornerRadius = radius
        halo.backgroundColor = NSColor(white: 0.08, alpha: 0.01).cgColor
        halo.shadowRadius = 22
        halo.shadowOffset = .zero
        halo.shadowOpacity = 0
        host.insertSublayer(halo, at: 0)
        // The ring: a conic gradient, larger than the panel so it can spin,
        // masked to a thin rounded stroke along the edge.
        let side = max(size.width, size.height) * 1.6
        ring.type = .conic
        ring.startPoint = CGPoint(x: 0.5, y: 0.5)
        ring.endPoint = CGPoint(x: 0.5, y: 0)
        ring.frame = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                            width: side, height: side)
        let holder = CALayer()
        holder.frame = CGRect(origin: .zero, size: size)
        mask.path = CGPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5),
                           cornerWidth: radius, cornerHeight: radius, transform: nil)
        mask.fillColor = nil
        mask.strokeColor = NSColor.white.cgColor
        mask.lineWidth = 3
        holder.mask = mask
        holder.addSublayer(ring)
        holder.opacity = 0
        host.addSublayer(holder)
        self.holder = holder
    }
    private var holder: CALayer!

    func set(_ next: GlowMode) {
        guard next != mode else { return }
        mode = next
        ring.removeAllAnimations()
        halo.removeAllAnimations()
        holder.removeAllAnimations()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.duration = next == .off ? 0.45 : 0.12
        fade.fromValue = holder.presentation()?.opacity ?? holder.opacity
        let target: Float = next == .off ? 0 : 1
        fade.toValue = target
        holder.opacity = target
        holder.add(fade, forKey: "fade")
        if next == .off {
            halo.shadowOpacity = 0
            return
        }
        let colors: [NSColor] = next == .awake
            ? [.systemPurple, .systemPink, .systemOrange, .systemBlue, .systemPurple]
            : [.systemTeal, .systemBlue, .systemGreen, .systemCyan, .systemTeal]
        ring.colors = colors.map { $0.cgColor }
        halo.shadowColor = (next == .awake ? NSColor.systemPurple : NSColor.systemTeal).cgColor
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = next == .awake ? 1.6 : 3.2
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
        let breathe = CABasicAnimation(keyPath: "shadowOpacity")
        breathe.fromValue = 0.35
        breathe.toValue = 0.95
        breathe.duration = next == .awake ? 0.7 : 1.2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        halo.shadowOpacity = 0.6
        halo.add(breathe, forKey: "breathe")
    }
}

let glow = Glow(on: container.layer!, size: container.frame.size, radius: 18)
// Set on the wake word, cleared once Ziggy has answered or the turn is over.
var glowAwake = false
var lastRenderedState: String = "listening"

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

// The wake gate's own phase, always named while it is not plain listening.
let gateLabel = makeLabel("", size: 11, weight: .regular)
gateLabel.textColor = NSColor(white: 1.0, alpha: 0.55)

// The live mic level: a thin bar that always moves with the room, so a
// silent room is never indistinguishable from a microphone not heard.
let levelTrack = NSView()
levelTrack.wantsLayer = true
levelTrack.layer?.cornerRadius = 2
levelTrack.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.14).cgColor
levelTrack.translatesAutoresizingMaskIntoConstraints = false
let levelFill = NSView()
levelFill.wantsLayer = true
levelFill.layer?.cornerRadius = 2
levelFill.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.85).cgColor
levelFill.translatesAutoresizingMaskIntoConstraints = false
var levelFillWidth: NSLayoutConstraint!
let levelTrackWidth: CGFloat = 308

let transcriptLabel = makeLabel("", size: 12, weight: .regular)
transcriptLabel.textColor = NSColor(white: 1.0, alpha: 0.72)
transcriptLabel.lineBreakMode = NSLineBreakMode.byTruncatingTail
transcriptLabel.maximumNumberOfLines = 1
transcriptLabel.cell?.truncatesLastVisibleLine = true
transcriptLabel.cell?.wraps = false

// The blocked face's way out: one button, deep-linking to this app's mic
// toggle in System Settings. Hidden unless the microphone is blocked.
let settingsButton = NSButton(title: "allow the microphone in settings…", target: micSettingsOpener, action: #selector(MicSettingsOpener.open(_:)))
settingsButton.bezelStyle = .rounded
settingsButton.controlSize = .small
settingsButton.font = .systemFont(ofSize: 11, weight: .medium)
settingsButton.translatesAutoresizingMaskIntoConstraints = false
settingsButton.isHidden = true

// Mute: the microphone stops reaching the wake gate, the decoder and the
// relay until unmuted, for meetings and calls. The bridge owns the effect;
// the panel only says which way it is.
final class MuteToggler: NSObject {
    var muted = false
    @objc func toggle(_ sender: NSButton) {
        muted.toggle()
        bridgeProcess.send(muted ? "mute" : "unmute")
        sender.title = muted ? "unmute" : "mute"
        dot.layer?.backgroundColor = muted
            ? NSColor.systemGray.cgColor : NSColor.systemGreen.cgColor
    }
}
let muteToggler = MuteToggler()
let muteButton = NSButton(title: "mute", target: muteToggler, action: #selector(MuteToggler.toggle(_:)))
muteButton.bezelStyle = .rounded
muteButton.controlSize = .small
muteButton.font = .systemFont(ofSize: 11, weight: .medium)
muteButton.translatesAutoresizingMaskIntoConstraints = false

// The face: the blob critter fills the top; state and the last line of
// conversation sit under it; mute floats top-right. The old level bar and
// gate label stay hidden: the critter shows both.
let critter = CritterView(frame: NSRect(x: 0, y: 0, width: 220, height: 170))
critter.translatesAutoresizingMaskIntoConstraints = false
container.addSubview(critter)
container.addSubview(dot)
container.addSubview(muteButton)
container.addSubview(stateLabel)
container.addSubview(gateLabel)
container.addSubview(levelTrack)
levelTrack.addSubview(levelFill)
panel.contentView?.addSubview(container)
container.addSubview(transcriptLabel)
container.addSubview(settingsButton)
gateLabel.isHidden = true
levelTrack.isHidden = true
transcriptLabel.maximumNumberOfLines = 2
transcriptLabel.cell?.wraps = true
transcriptLabel.lineBreakMode = .byWordWrapping
stateLabel.font = .systemFont(ofSize: 13, weight: .semibold)

NSLayoutConstraint.activate([
    container.widthAnchor.constraint(equalToConstant: 220),
    container.heightAnchor.constraint(equalToConstant: 250),

    critter.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
    critter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
    critter.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    critter.heightAnchor.constraint(equalToConstant: 170),

    muteButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
    muteButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

    dot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
    dot.centerYAnchor.constraint(equalTo: stateLabel.centerYAnchor),

    stateLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
    stateLabel.topAnchor.constraint(equalTo: critter.bottomAnchor, constant: 2),

    gateLabel.centerYAnchor.constraint(equalTo: stateLabel.centerYAnchor),
    gateLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

    transcriptLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
    transcriptLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
    transcriptLabel.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 3),

    settingsButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
    settingsButton.centerYAnchor.constraint(equalTo: transcriptLabel.centerYAnchor),

    levelTrack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
    levelTrack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
    levelTrack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
    levelTrack.heightAnchor.constraint(equalToConstant: 4),

    levelFill.leadingAnchor.constraint(equalTo: levelTrack.leadingAnchor),
    levelFill.centerYAnchor.constraint(equalTo: levelTrack.centerYAnchor),
    levelFill.heightAnchor.constraint(equalToConstant: 4),
])
levelFillWidth = levelFill.widthAnchor.constraint(equalToConstant: 0)
levelFillWidth.isActive = true

func render() {
    if model.micBlocked {
        // Never a silent "listening" when the system says no: the blocked
        // face is loud, red, and carries its own way out.
        stateLabel.stringValue = model.blockedLabel
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
    } else {
        stateLabel.stringValue = model.labels[model.state] ?? model.state.rawValue
        switch model.state {
        case .listening: dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        case .thinking: dot.layer?.backgroundColor = NSColor.systemYellow.cgColor
        case .speaking: dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        }
    }
    let stateName = model.state.rawValue
    // The glow stays on through the conversation window after a reply and
    // goes dark on the "stand-by" notice (quiet window over, or stood down).
    lastRenderedState = stateName
    // The critter carries the glow now; the old edge ring stays off.
    glow.set(.off)
    if model.micBlocked {
        critter.mode = .blocked
    } else if muteToggler.muted {
        critter.mode = .muted
    } else if model.state == .speaking {
        critter.mode = .speaking
    } else if model.state == .thinking {
        critter.mode = .thinking
    } else if glowAwake {
        critter.mode = .awake
    } else {
        critter.mode = .idle
    }
    critter.micLevel = model.micLevel
    critter.outLevel = Bridge.outLevel
    gateLabel.stringValue = model.gate == .listening ? "" : "gate: \(model.gate.rawValue)"
    levelFillWidth.constant = levelTrackWidth * CGFloat(model.micLevel)
    transcriptLabel.isHidden = model.micBlocked
    settingsButton.isHidden = !model.micBlocked
    if let line = model.transcript, !model.micBlocked {
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
        y: visible.maxY - 96 - 24
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

// The permission verdict is read once at launch and re-read every time the
// app activates or the panel gains focus, so flipping the mic toggle in
// System Settings is picked up without a relaunch.
model.applyPermission(micPermissionNow())
func recheckMicPermission() {
    model.applyPermission(micPermissionNow())
}
NotificationCenter.default.addObserver(
    forName: NSApplication.didBecomeActiveNotification, object: nil,
    queue: .main) { _ in recheckMicPermission() }
NotificationCenter.default.addObserver(
    forName: NSWindow.didBecomeKeyNotification, object: panel,
    queue: .main) { _ in recheckMicPermission() }

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
            case .mic(let level, let gate):
                model.applyMic(level: level, gate: gate)
            case .notice(let event, let error):
                // Notices the HUD must show rather than just carry: a dead
                // engine or an abandoned turn leaves the mic deaf, and a
                // wake into silence is never swallowed - the panel says
                // what happened instead of rendering listening forever.
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
                case "mic-denied":
                    // The device opened but delivers digital silence: the
                    // same loud blocked face as a denied permission.
                    model.applyMicDenial()
                    model.transcriptLine(TranscriptLine(
                        role: .assistant,
                        text: "the microphone is silent - allow it in settings, then click the HUD"))
                case "mic-status":
                    model.transcriptLine(TranscriptLine(
                        role: .assistant, text: "mic: \(error ?? "capture status")"))
                case "wake":
                    // The wake word fired: light the whole panel at once,
                    // before any model has done anything.
                    glowAwake = true
                    model.applyState("listening")
                    model.transcriptLine(TranscriptLine(
                        role: .assistant, text: "heard you"))
                case "follow-up", "follow-up-turn":
                    // Still in the conversation: no wake word needed.
                    glowAwake = true
                    model.applyState("listening")
                    model.transcriptLine(TranscriptLine(
                        role: .assistant, text: "still listening - just talk"))
                case "not-for-me":
                    // A false wake: nobody said Ziggy. Go dark quietly.
                    glowAwake = false
                    model.applyState("listening")
                case "stand-by":
                    glowAwake = false
                    model.applyState("listening")
                case "no-speech":
                    glowAwake = false
                    // A wake into silence is named, never swallowed: the
                    // turn was never opened, so nothing was spent but the
                    // captain still learns the wake fired and died.
                    model.applyState("listening")
                    model.transcriptLine(TranscriptLine(
                        role: .assistant,
                        text: "nothing after the wake word - pause briefly, then say the command"))
                case "engine-link":
                    // The post-turn send-path check failed: the link is
                    // already marked dead and the next wake renews it, so
                    // the panel says that instead of holding a stale failure
                    // line while the mic looks live.
                    model.applyState("listening")
                    model.transcriptLine(TranscriptLine(
                        role: .assistant, text: "engine link lost - the next wake reconnects"))
                case "renewed":
                    // A successful (re)connect: the failure line this
                    // renewal recovered from is cleared here, never left to
                    // caption a healthy listening HUD.
                    model.applyState("listening")
                    model.clearTranscript()
                case "turn-failed":
                    glowAwake = false
                    model.applyState("listening")
                    var text = "that turn failed - ask again"
                    if let reason = error, !reason.isEmpty {
                        text = "that turn failed (\(reason)) - ask again"
                    }
                    model.transcriptLine(TranscriptLine(role: .assistant, text: text))
                case "session-ended":
                    model.applyState("listening")
                    model.transcriptLine(TranscriptLine(
                        role: .assistant, text: "the relay ended the session - ask again"))
                case "turn-timeout":
                    glowAwake = false
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
