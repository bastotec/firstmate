// ScreenText: the text in a screenshot, read on this Mac with Apple's Vision
// OCR, so Ziggy (whose model cannot take images) can "look" at a window.
//
//   ScreenText <image.png> [...]   one recognized line per output line;
//                                  files separated by a "--- <path>" header

import AppKit
import Foundation
import Vision

let paths = Array(CommandLine.arguments.dropFirst())
if paths.isEmpty {
    FileHandle.standardError.write("usage: ScreenText <image.png> [...]\n".data(using: .utf8)!)
    exit(2)
}
var failed = false
for path in paths {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("ScreenText: cannot read \(path)\n".data(using: .utf8)!)
        failed = true
        continue
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    do {
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
    } catch {
        FileHandle.standardError.write("ScreenText: \(path): \(error)\n".data(using: .utf8)!)
        failed = true
        continue
    }
    if paths.count > 1 { print("--- \(path)") }
    // Top to bottom, then left to right, the way the window reads.
    let lines = (request.results ?? [])
        .compactMap { obs -> (CGRect, String)? in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            return (obs.boundingBox, text)
        }
        .sorted { a, b in
            abs(a.0.midY - b.0.midY) > 0.01 ? a.0.midY > b.0.midY : a.0.minX < b.0.minX
        }
    for (_, text) in lines { print(text) }
}
exit(failed ? 1 : 0)
