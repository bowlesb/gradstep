// Offline Mac Vision text bounds for the scientific-crop experiment.
// Uses public corpus images, never the reader's private library or cloud models.
import Foundation
import Vision
import ImageIO
import CryptoKit

struct Input: Decodable { let id: String; let image: String; let sha256: String; let width: Int; let height: Int }
struct TextBox: Codable { let text: String; let confidence: Float; let box: [Double] }
struct Output: Codable {
    let id: String; let imageSHA256: String; let width: Int; let height: Int
    let requestRevision: Int; let osVersion: String; let milliseconds: Double; let text: [TextBox]
}
enum Failure: Error { case usage, outsideRoot, hashMismatch, imageInvalid, dimensionsChanged }

guard CommandLine.arguments.count == 4 else { throw Failure.usage }
let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
let manifest = URL(fileURLWithPath: CommandLine.arguments[2])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
let rows = try String(contentsOf: manifest, encoding: .utf8).split(separator: "\n").map {
    try JSONDecoder().decode(Input.self, from: Data($0.utf8))
}
var completed: Set<String> = []
if let existing = try? String(contentsOf: outputURL, encoding: .utf8) {
    for line in existing.split(separator: "\n") {
        let row = try JSONDecoder().decode(Output.self, from: Data(line.utf8))
        guard row.osVersion == ProcessInfo.processInfo.operatingSystemVersionString,
              row.requestRevision == VNRecognizeTextRequest.currentRevision else { throw Failure.usage }
        completed.insert(row.id + ":" + row.imageSHA256)
    }
} else {
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
}
let output = try FileHandle(forWritingTo: outputURL)
try output.seekToEnd()
defer { try? output.close() }
for (index, row) in rows.enumerated() {
    if completed.contains(row.id + ":" + row.sha256) { continue }
    try autoreleasepool {
        let url = root.appendingPathComponent(row.image).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { throw Failure.outsideRoot }
        let bytes = try Data(contentsOf: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == row.sha256 else { throw Failure.hashMismatch }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.imageInvalid }
        guard image.width == row.width, image.height == row.height else { throw Failure.dimensionsChanged }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.003
        let start = CFAbsoluteTimeGetCurrent()
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let boxes = (request.results ?? []).compactMap { observation -> TextBox? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.2 else { return nil }
            let b = observation.boundingBox
            // Vision's bottom-left coordinates become original-image top-left pixel bounds.
            return TextBox(text: candidate.string, confidence: candidate.confidence, box: [
                Double(b.minX) * Double(row.width), (1 - Double(b.maxY)) * Double(row.height),
                Double(b.maxX) * Double(row.width), (1 - Double(b.minY)) * Double(row.height)])
        }
        let result = Output(id: row.id, imageSHA256: digest, width: row.width, height: row.height,
            requestRevision: request.revision, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000, text: boxes)
        var line = try JSONEncoder().encode(result); line.append(0x0A)
        try output.write(contentsOf: line)
        if index % 20 == 0 { print("OCR \(index + 1)/\(rows.count)") }
    }
}
