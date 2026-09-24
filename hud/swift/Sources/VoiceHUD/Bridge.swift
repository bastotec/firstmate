// The Swift half of the process boundary. The Python bridge owns the wake
// gate, the decoder and the relay child; this side owns the process handle
// and the event parse. One JSON object per line, the same schema
// hud/fm_voice_hud_bridge.py emits, and a "quit" line back at exit.
//
// Parsing happens on a background thread; drained events are applied on the
// main thread by the panel. The bridge is never asked to do anything the
// events do not announce: state changes come from the engine's callbacks,
// never from a timer guessing.

import Foundation

enum BridgeEvent {
    case state(String)
    case transcript(role: String, text: String)
    case notice(event: String)
}

final class Bridge {
    private let process: Process
    private let queue = DispatchQueue(label: "hud.bridge.events")
    private var pending: [BridgeEvent] = []
    private var lineBuffer = [String]()

    static func launch(repoRoot: String) -> Bridge {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repoRoot + "/hud/fm_voice_hud_bridge.py"]
        process.standardError = FileHandle.standardError
        let outPipe = Pipe()
        process.standardOutput = outPipe
        try! process.run()
        let bridge = Bridge(process: process)
        bridge.readEvents(from: outPipe)
        return bridge
    }

    private init(process: Process) {
        self.process = process
    }

    private func readEvents(from pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: chunk, encoding: .utf8) {
                self.enqueue(lines: text)
            }
        }
    }

    private func enqueue(lines text: String) {
        queue.sync {
            lineBuffer.append(text)
            while let nl = lineBuffer.joined().firstIndex(of: "\n") {
                let all = lineBuffer.joined()
                let line = String(all[all.startIndex..<nl]).trimmingCharacters(in: .whitespaces)
                lineBuffer = [String(all[all.index(after: nl)...])]
                guard !line.isEmpty else { continue }
                if let event = Bridge.parse(line: line) {
                    pending.append(event)
                }
            }
        }
    }

    /// Pull every event that has arrived, main thread only.
    func drainEvents() -> [BridgeEvent] {
        queue.sync {
            let out = pending
            pending = []
            return out
        }
        // not reached
    }

    static func parse(line: String) -> BridgeEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "state":
            return .state(obj["state"] as? String ?? "listening")
        case "transcript":
            return .transcript(role: obj["role"] as? String ?? "user",
                               text: obj["text"] as? String ?? "")
        case "notice":
            return .notice(event: obj["event"] as? String ?? "")
        default:
            return nil
        }
    }

    func quit() {
        if let stdin = process.standardInput as? Pipe {
            try? stdin.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8))
        }
    }
}
