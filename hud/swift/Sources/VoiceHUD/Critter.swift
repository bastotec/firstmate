// The HUD's face: a blob critter that lives on the audio.
//
// Idle, it breathes, blinks and wobbles with whatever the room is saying, like
// something that hears but isn't listening. When the wake word lands it perks
// up and glows; thinking, its eyes drift up and around; speaking, its mouth
// follows Ziggy's own voice level; muted, it closes its eyes under earmuffs.
// Waiting on the first mate, it turns calm blue and watches little dots
// orbit its head - one per question still out - in any mode but muted.
// Drawn with Core Graphics at 30 fps, no assets.

import AppKit

enum CritterMode: Equatable { case idle, awake, thinking, speaking, muted, blocked, waiting }

final class CritterView: NSView {
    var mode: CritterMode = .idle
    /// Microphone level 0...1 (the room), set ~10x a second.
    var micLevel: Double = 0 { didSet { targetMic = min(1, micLevel * 1.6) } }
    /// Ziggy's own output level 0...1, set while it speaks.
    var outLevel: Double = 0 { didSet { targetOut = min(1, outLevel * 1.8) } }
    /// Questions the first mate has not answered yet.
    var waitingCount = 0

    private var targetMic = 0.0, mic = 0.0
    private var targetOut = 0.0, out = 0.0
    private var t = 0.0
    private var perk = 0.0          // 0 idle ... 1 awake, eased
    private var timer: Timer?

    override var isFlipped: Bool { true }
    // The window has no background left to grab, so the critter is the handle.
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func tick() {
        t += 1.0 / 30.0
        // Ease levels so the body moves smoothly between 10 Hz updates.
        mic += (targetMic - mic) * 0.35
        out += (targetOut - out) * 0.5
        targetOut *= 0.9
        let wantPerk: Double = (mode == .idle || mode == .muted || mode == .blocked) ? 0 : 1
        perk += (wantPerk - perk) * 0.2
        needsDisplay = true
    }

    private var color: NSColor {
        switch mode {
        case .idle: return NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.95, alpha: 1)
        case .awake: return NSColor(calibratedRed: 0.72, green: 0.42, blue: 0.97, alpha: 1)
        case .thinking: return NSColor(calibratedRed: 0.90, green: 0.66, blue: 0.20, alpha: 1)
        case .speaking: return NSColor(calibratedRed: 0.20, green: 0.74, blue: 0.70, alpha: 1)
        case .muted: return NSColor(calibratedWhite: 0.6, alpha: 1)
        case .blocked: return NSColor.systemRed
        case .waiting: return NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.95, alpha: 1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, h = bounds.height
        let cx = w / 2
        let heard = (mode == .muted) ? 0 : mic
        let squish = 1 + heard * 0.30 + (mode == .speaking ? out * 0.12 : 0)
        let bob = sin(t * 2.0) * 3 + (mode == .awake ? sin(t * 9) * 1.5 : 0)
        let cy = h * 0.52 + bob
        let rx = w * 0.30 * squish
        let ry = h * 0.29 / sqrt(squish) * (1 + 0.04 * sin(t * 2.0))

        // Shadow on the "floor".
        g.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.25).cgColor)
        g.fillEllipse(in: CGRect(x: cx - rx * 0.9, y: h * 0.88, width: rx * 1.8, height: 8))

        // Halo when it is paying attention.
        if perk > 0.02 {
            let pulse = 0.5 + 0.3 * sin(t * 6)
            for i in 0..<4 {
                let grow = CGFloat(10 + i * 7)
                g.setFillColor(color.withAlphaComponent(CGFloat(0.10 * perk * pulse) / CGFloat(i + 1)).cgColor)
                g.fillEllipse(in: CGRect(x: cx - rx - grow, y: cy - ry - grow,
                                         width: (rx + grow) * 2, height: (ry + grow) * 2))
            }
        }

        // Body with a soft vertical gradient.
        let body = CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil)
        g.saveGState()
        g.addPath(body)
        g.clip()
        let top = color.blended(withFraction: 0.25, of: .white) ?? color
        let bottom = color.blended(withFraction: 0.2, of: .black) ?? color
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [top.cgColor, bottom.cgColor] as CFArray,
                                 locations: [0, 1]) {
            g.drawLinearGradient(grad, start: CGPoint(x: cx, y: cy - ry),
                                 end: CGPoint(x: cx, y: cy + ry), options: [])
        }
        g.restoreGState()
        // Shine.
        g.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.30).cgColor)
        g.fillEllipse(in: CGRect(x: cx - rx * 0.55, y: cy - ry * 0.72, width: rx * 0.45, height: ry * 0.22))

        // Eyes: sleepy when idle, wide when awake, closed when muted.
        let blink = (t.truncatingRemainder(dividingBy: 3.7) < 0.12) ? 0.1 : 1.0
        var open = (0.62 + 0.38 * perk) * blink
        if mode == .muted { open = 0.08 }
        let look: Double
        switch mode {
        case .thinking: look = sin(t * 2.2) * 7
        case .waiting: look = sin(t * 1.3) * 6      // watching the dots go round
        case .idle: look = sin(t * 0.7) * 2
        default: look = 0
        }
        let lookUp = mode == .thinking ? -5.0 : 0.0
        let eyeY = cy - ry * 0.12 + lookUp
        let eyeDX = rx * 0.36
        let ink = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.16, alpha: 1)
        for side in [-1.0, 1.0] {
            let ex = cx + side * eyeDX + look
            let eh = max(1.5, 16 * open)
            g.setFillColor(ink.cgColor)
            g.fillEllipse(in: CGRect(x: ex - 6.5, y: eyeY - eh / 2, width: 13, height: eh))
            if open > 0.3 {
                g.setFillColor(NSColor.white.cgColor)
                g.fillEllipse(in: CGRect(x: ex - 1, y: eyeY - eh / 2 + 3, width: 4, height: 4))
            }
        }

        // Mouth: follows Ziggy's voice while speaking, a small smile otherwise.
        let mouthY = cy + ry * 0.36
        g.setFillColor(ink.cgColor)
        g.setStrokeColor(ink.cgColor)
        if mode == .speaking {
            let mh = 3 + out * 16
            g.fillEllipse(in: CGRect(x: cx - 9, y: mouthY - mh / 2, width: 18, height: mh))
        } else if mode == .awake {
            g.fillEllipse(in: CGRect(x: cx - 5, y: mouthY - 4, width: 10, height: 8))
        } else {
            g.setLineWidth(3)
            g.setLineCap(.round)
            g.move(to: CGPoint(x: cx - 9, y: mouthY))
            g.addQuadCurve(to: CGPoint(x: cx + 9, y: mouthY),
                           control: CGPoint(x: cx, y: mouthY + 5 + heard * 5))
            g.strokePath()
        }

        // Thinking: little dots rising beside the head.
        if mode == .thinking {
            for i in 0..<3 {
                let phase = (t * 1.5 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1.0)
                g.setFillColor(color.withAlphaComponent(CGFloat(1 - phase)).cgColor)
                let r = CGFloat(3 + i * 2)
                g.fillEllipse(in: CGRect(x: cx + rx * 0.9 + CGFloat(i) * 9 - r,
                                         y: cy - ry - CGFloat(phase) * 22 - r, width: r * 2, height: r * 2))
            }
        }

        // Waiting on the first mate: one dot per open question orbits the head.
        if waitingCount > 0 && mode != .muted && mode != .blocked {
            let dots = min(waitingCount, 3)
            let orbitX = rx + 16, orbitY = ry * 0.35
            let blue = NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.95, alpha: 1)
            for i in 0..<dots {
                let a = t * 1.6 + Double(i) * (2 * .pi / Double(dots))
                let x = cx + orbitX * cos(a)
                let y = cy - ry * 0.95 + orbitY * sin(a)
                let behind = sin(a) < 0
                g.setFillColor(blue.withAlphaComponent(behind ? 0.45 : 0.95).cgColor)
                let r: CGFloat = behind ? 3.5 : 5
                g.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        }

        // Muted: earmuffs.
        if mode == .muted {
            let band = NSColor(calibratedWhite: 0.35, alpha: 1)
            g.setStrokeColor(band.cgColor)
            g.setLineWidth(5)
            g.move(to: CGPoint(x: cx - rx - 2, y: cy - 4))
            g.addQuadCurve(to: CGPoint(x: cx + rx + 2, y: cy - 4),
                           control: CGPoint(x: cx, y: cy - ry * 2.1))
            g.strokePath()
            g.setFillColor(band.cgColor)
            for side in [-1.0, 1.0] {
                g.addPath(CGPath(roundedRect: CGRect(x: cx + side * (rx + 2) - 9, y: cy - 16, width: 18, height: 30),
                                 cornerWidth: 7, cornerHeight: 7, transform: nil))
                g.fillPath()
            }
        }
    }
}
