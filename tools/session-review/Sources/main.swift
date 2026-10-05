// session-review <session-folder> [--max-frames N]
//
// Turns a recorded test session (screen.mp4 + timeline.jsonl + meta.json from
// the app's Settings › Testing › Record a test session) into a review packet in
// <session-folder>/review/: review.md (signals first, narration, timeline by
// screen, frame links), review.json, frames/*.jpg (touches drawn as rings) and
// transcript.json. See docs/SESSION_REVIEW.md.
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Speech
import UniformTypeIdentifiers
import Vision

struct Event { let t: Double; let kind: String; let fields: [String: String] }
struct Signal: Codable { let t: Double; let kind: String; let detail: String; var frame: String? }
struct Remark: Codable { let t: Double; let end: Double; let text: String; let flagged: Bool; var frame: String? }
struct Frame: Codable { let t: Double; let file: String; let reason: String; var text: String }

enum Priority: Int { case signal = 0, change = 1, periodic = 2 }
struct Candidate { let t: Double; let priority: Priority; let reason: String }

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { print("usage: session-review <session-folder> [--max-frames N]"); exit(2) }
let folder = URL(fileURLWithPath: arguments[1])
let maxFrames = arguments.firstIndex(of: "--max-frames").flatMap { Int(arguments[$0 + 1]) } ?? 90
let out = folder.appendingPathComponent("review", isDirectory: true)
let framesDir = out.appendingPathComponent("frames", isDirectory: true)
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)

// MARK: Inputs

let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json")))) as? [String: Any] ?? [:]
let events: [Event] = (try? String(contentsOf: folder.appendingPathComponent("timeline.jsonl"), encoding: .utf8))?
    .split(separator: "\n").compactMap { line in
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
              let t = object["t"].flatMap(Double.init), let kind = object["kind"] else { return nil }
        var fields = object; fields["t"] = nil; fields["kind"] = nil
        return Event(t: t, kind: kind, fields: fields)
    } ?? []
guard !events.isEmpty else { print("No timeline events in \(folder.path)"); exit(1) }
let sessionEnd = events.last?.t ?? 0
let videoURL = folder.appendingPathComponent("screen.mp4")
let hasVideo = FileManager.default.fileExists(atPath: videoURL.path)

func clock(_ t: Double) -> String { String(format: "%02d:%04.1f", Int(max(t, 0)) / 60, max(t, 0).truncatingRemainder(dividingBy: 60)) }

// MARK: Video helpers

let asset = AVURLAsset(url: videoURL)
var videoDuration = 0.0
if hasVideo { videoDuration = (try? await asset.load(.duration).seconds) ?? 0 }

func generator(maximum: CGSize) -> AVAssetImageGenerator {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = maximum
    generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
    return generator
}

func pixels(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: width * height * 4)
    data.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return data
}

/// A coarse grayscale signature for spotting visually identical frames.
func signature(_ image: CGImage) -> [UInt8] {
    let raw = pixels(image, width: 24, height: 48)
    var gray: [UInt8] = []
    gray.reserveCapacity(raw.count / 4)
    for i in stride(from: 0, to: raw.count, by: 4) {
        let sum: Int = Int(raw[i]) + Int(raw[i + 1]) + Int(raw[i + 2])
        gray.append(UInt8(sum / 3))
    }
    return gray
}
func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 1 }
    var total = 0
    for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
    return Double(total) / Double(a.count * 255)
}

// MARK: Sync: the magenta band the app shows right after recording starts

var offset = 0.0, syncFound = false
let bandOn = events.first { $0.kind == "sync_band" && $0.fields["on"] == "1" }?.t
/// Whether the top rows of a frame show the magenta band.
func showsBand(_ image: CGImage) -> Bool {
    let w = image.width, h = image.height, raw = pixels(image, width: w, height: h)
    // The bitmap's first rows in memory are the top of the frame.
    for row in 0..<max(Int(Double(h) * 0.12), 2) {
        var magenta = 0
        for x in 0..<w {
            let i = (row * w + x) * 4
            if raw[i] > 190 && raw[i + 1] < 90 && raw[i + 2] > 190 { magenta += 1 }
        }
        if Double(magenta) / Double(w) > 0.45 { return true }
    }
    return false
}
if hasVideo, let bandOn {
    // Coarse pass over the whole video (a device recording shows the band at the
    // start; a Simulator recording only once the app has launched), then refine.
    let small = generator(maximum: CGSize(width: 120, height: 260))
    var t = 0.0, coarse: Double?
    while t < videoDuration, coarse == nil {
        if let image = try? await small.image(at: CMTime(seconds: t, preferredTimescale: 600)).image, showsBand(image) { coarse = t }
        t += 0.2
    }
    if let coarse {
        var fine = max(coarse - 0.25, 0)
        while fine <= coarse {
            if let image = try? await small.image(at: CMTime(seconds: fine, preferredTimescale: 600)).image, showsBand(image) { break }
            fine += 1.0 / 30
        }
        offset = fine - bandOn; syncFound = true
    }
}
func videoTime(_ t: Double) -> Double { t + offset }
func timelineTime(_ v: Double) -> Double { v - offset }

// MARK: Narration (on-device transcription)

var remarks: [Remark] = []
let problemWords = ["bug", "broken", "wrong", "weird", "slow", "stuck", "why", "can't", "cannot", "doesn't", "didn't", "isn't",
                    "should", "expected", "hmm", "annoying", "confus", "hard to", "missing", "cut off", "overlap", "not working",
                    "nothing happen", "again", "error", "crash", "frozen", "freez", "lag", "ugly", "off"]
if hasVideo, (meta["voice"] as? Bool) == true, !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty {
    do {
        let audio = out.appendingPathComponent("audio.m4a")
        if let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
            try await export.export(to: audio, as: .m4a)
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
                let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let collector = Task { () -> [Remark] in
                    var found: [Remark] = []
                    for try await result in transcriber.results {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { continue }
                        let lower = text.lowercased()
                        found.append(Remark(t: timelineTime(result.range.start.seconds), end: timelineTime(result.range.end.seconds), text: text,
                                            flagged: problemWords.contains { lower.contains($0) }))
                    }
                    return found
                }
                let file = try AVAudioFile(forReading: audio)
                if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
                else { await analyzer.cancelAndFinishNow() }
                remarks = try await collector.value
            }
        }
    } catch { print("Narration could not be transcribed: \(error)") }
}

// MARK: Signals from the timeline

var signals: [Signal] = []
let messageKeys = ["error", "chat_issue", "chat_draft_issue", "reader_issue", "library_issue", "offline_issue", "credits_issue",
                   "account_issue", "store_notice"]
let waitLimits: [String: Double] = ["busy": 10, "opening_paper": 8, "library_refreshing": 10, "answering": 60, "imports_active": 120]
var waitStarts: [String: Double] = [:]
var chrome: CGRect?
for event in events {
    switch event.kind {
    case "state":
        for key in messageKeys { if let value = event.fields[key], !value.isEmpty { signals.append(Signal(t: event.t, kind: "message_shown", detail: "\(key): \(value)")) } }
        for (key, limit) in waitLimits {
            guard let value = event.fields[key] else { continue }
            if value.isEmpty, let start = waitStarts.removeValue(forKey: key), event.t - start > limit {
                signals.append(Signal(t: start, kind: "long_wait", detail: "\(key) for \(Int(event.t - start)) s"))
            } else if !value.isEmpty, waitStarts[key] == nil { waitStarts[key] = event.t }
        }
    case "request":
        let status = event.fields["status"] ?? "", ms = Int(event.fields["ms"] ?? "") ?? 0, path = event.fields["path"] ?? ""
        if status == "failed" || (Int(status) ?? 0) >= 400 { signals.append(Signal(t: event.t, kind: "request_failed", detail: "\(event.fields["method"] ?? "") \(path) → \(status)")) }
        else if ms > 4000, !path.contains("functions/v1/chat") { signals.append(Signal(t: event.t, kind: "slow_request", detail: "\(path) \(ms) ms")) }
    case "hang": signals.append(Signal(t: event.t - (Double(event.fields["ms"] ?? "") ?? 0) / 1000, kind: "hang", detail: "main thread stalled \(event.fields["ms"] ?? "?") ms"))
    case "memory_warning": signals.append(Signal(t: event.t, kind: "memory_warning", detail: "memory warning"))
    case "mark": signals.append(Signal(t: event.t, kind: "mark", detail: "marked by the tester"))
    case "chrome":
        if let x = Double(event.fields["x"] ?? ""), let y = Double(event.fields["y"] ?? ""), let w = Double(event.fields["width"] ?? ""), let h = Double(event.fields["height"] ?? "") {
            chrome = CGRect(x: x, y: y, width: w, height: h)
        }
    default: break
    }
}
for (key, start) in waitStarts where sessionEnd - start > (waitLimits[key] ?? 10) {
    signals.append(Signal(t: start, kind: "long_wait", detail: "\(key) still on at the end (\(Int(sessionEnd - start)) s)"))
}
// Repeated taps: 3+ touches within 1.5 s and 44 pt of each other (something did not respond).
let touches = events.filter { $0.kind == "touch" && $0.fields["phase"] == "began" }
var lastCluster = -10.0
for (index, touch) in touches.enumerated() where touch.t > lastCluster + 1.5 {
    guard let x = Double(touch.fields["x"] ?? ""), let y = Double(touch.fields["y"] ?? "") else { continue }
    if let chrome, chrome.insetBy(dx: -6, dy: -6).contains(CGPoint(x: x, y: y)) { continue }
    let near = touches[index...].prefix { $0.t - touch.t <= 1.5 }.filter {
        guard let ox = Double($0.fields["x"] ?? ""), let oy = Double($0.fields["y"] ?? "") else { return false }
        return hypot(ox - x, oy - y) <= 44
    }
    if near.count >= 3 { signals.append(Signal(t: touch.t, kind: "repeated_taps", detail: "\(near.count) taps near (\(Int(x)), \(Int(y)))")); lastCluster = touch.t }
}
for remark in remarks where remark.flagged { signals.append(Signal(t: remark.t, kind: "narration", detail: "“\(remark.text)”")) }
signals.sort { $0.t < $1.t }

// MARK: Keyframes

var frames: [Frame] = []
if hasVideo, videoDuration > 0 {
    var candidates: [Candidate] = signals.map { Candidate(t: $0.t + ($0.kind == "message_shown" ? 0.4 : 0.1), priority: .signal, reason: $0.kind) }
    for event in events {
        switch event.kind {
        case "state": candidates.append(Candidate(t: event.t + 0.6, priority: .change, reason: "after " + event.fields.keys.sorted().joined(separator: ",")))
        case "touch" where event.fields["phase"] == "began": candidates.append(Candidate(t: event.t - 0.03, priority: .change, reason: "touch"))
        case "keyboard", "orientation": candidates.append(Candidate(t: event.t + 0.5, priority: .change, reason: event.kind))
        default: break
        }
    }
    var t = 0.5
    while t < sessionEnd { candidates.append(Candidate(t: t, priority: .periodic, reason: "periodic")); t += 1.5 }
    candidates = candidates.filter { videoTime($0.t) >= 0 && videoTime($0.t) <= videoDuration }.sorted { $0.t < $1.t }

    // Keep every signal frame; keep other frames only when the screen changed visibly.
    let small = generator(maximum: CGSize(width: 96, height: 208))
    var kept: [Candidate] = [], lastSignature: [UInt8] = [], lastSignalTime = -10.0
    for candidate in candidates {
        guard let image = try? await small.image(at: CMTime(seconds: videoTime(candidate.t), preferredTimescale: 600)).image else { continue }
        let current = signature(image)
        let changed = difference(current, lastSignature) > 0.012
        if candidate.priority == .signal ? candidate.t - lastSignalTime > 0.3 : changed {
            kept.append(candidate); lastSignature = current
            if candidate.priority == .signal { lastSignalTime = candidate.t }
        }
    }
    if kept.count > maxFrames {
        let signalsKept = kept.filter { $0.priority == .signal }
        let others = kept.filter { $0.priority != .signal }
        let step = Double(others.count) / Double(max(maxFrames - signalsKept.count, 1))
        let thinned = stride(from: 0.0, to: Double(others.count), by: max(step, 1)).map { others[Int($0)] }
        kept = (signalsKept + thinned).sorted { $0.t < $1.t }
    }

    // Full frames (600 px wide) with touch rings, plus on-screen text.
    let large = generator(maximum: CGSize(width: 600, height: 1400))
    var windowWidth = Double(events.first?.fields["window_width"] ?? "") ?? 0
    for (index, candidate) in kept.enumerated() {
        guard let image = try? await large.image(at: CMTime(seconds: videoTime(candidate.t), preferredTimescale: 600)).image else { continue }
        if let orientation = events.last(where: { $0.kind == "orientation" && $0.t <= candidate.t }), let w = Double(orientation.fields["width"] ?? "") { windowWidth = w }
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let scale = windowWidth > 0 ? Double(w) / windowWidth : 1
        for touch in events where touch.kind == "touch" && abs(touch.t - candidate.t) <= 0.35 {
            guard let x = Double(touch.fields["x"] ?? ""), let y = Double(touch.fields["y"] ?? "") else { continue }
            let point = CGPoint(x: x * scale, y: Double(h) - y * scale)
            context.setStrokeColor(CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 0.9)); context.setLineWidth(3)
            context.strokeEllipse(in: CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32))
        }
        guard let marked = context.makeImage() else { continue }
        let name = String(format: "f%03d-%06.1f.jpg", index, candidate.t)
        let url = framesDir.appendingPathComponent(name)
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, marked, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")
        frames.append(Frame(t: candidate.t, file: "frames/" + name, reason: candidate.reason, text: String(text.prefix(600))))
    }
}
func nearestFrame(_ t: Double) -> String? {
    frames.min { abs($0.t - t) < abs($1.t - t) }.flatMap { abs($0.t - t) < 2 ? $0.file : nil }
}
for index in signals.indices { signals[index].frame = nearestFrame(signals[index].t + 0.3) }
for index in remarks.indices { remarks[index].frame = nearestFrame(remarks[index].t + 0.3) }

// MARK: Report

var md = "# Test session \(folder.lastPathComponent)\n\n"
md += "- Build \(meta["version"] ?? "?") (\(meta["build"] ?? "?")), \(meta["device"] ?? "?"), iOS \(meta["system"] ?? "?"), \(meta["idiom"] ?? "?")\n"
md += "- Length \(clock(sessionEnd)); video \(hasVideo ? "yes" : "no"); narration \(remarks.isEmpty ? "none transcribed" : "\(remarks.count) remarks")\n"
md += "- Video/timeline sync: \(syncFound ? String(format: "marker found, offset %.2f s", offset) : hasVideo ? "marker NOT found; times may be off by about a second" : "no video")\n"
md += "- Times below are timeline times (mm:ss.s). Frames are 600 px wide; red rings are touches within 0.35 s. The recorder's own pill (\(chrome.map { "x \(Int($0.minX)) y \(Int($0.minY)) \(Int($0.width))×\(Int($0.height)) pt" } ?? "position unknown")) is not app UI.\n\n"
md += "## Signals (\(signals.count))\n\n"
md += signals.isEmpty ? "None detected from the timeline. Review the screens below for visual problems.\n" :
    signals.map { "- **\(clock($0.t))** \($0.kind): \($0.detail)\($0.frame.map { " → `\($0)`" } ?? "")" }.joined(separator: "\n") + "\n"
if !remarks.isEmpty {
    md += "\n## Narration\n\n" + remarks.map { "- **\(clock($0.t))**\($0.flagged ? " ⚑" : "") \($0.text)\($0.frame.map { " → `\($0)`" } ?? "")" }.joined(separator: "\n") + "\n"
}
md += "\n## Timeline by screen\n"
var screen = "", sheet = ""
var lines: [String] = []
var nextFrame = 0
for event in events {
    // Frames are listed in time order between the events around them.
    while nextFrame < frames.count, frames[nextFrame].t < event.t {
        lines.append("  - frame `\(frames[nextFrame].file)` (\(frames[nextFrame].reason))"); nextFrame += 1
    }
    switch event.kind {
    case "state":
        if let tab = event.fields["tab"] { screen = tab }
        if let value = event.fields["sheet"] { sheet = value }
        if event.fields["tab"] != nil || event.fields["sheet"] != nil {
            lines.append("\n### \(clock(event.t)) · \(screen)\(sheet.isEmpty ? "" : " › \(sheet)")\n")
        }
        let details = event.fields.filter { $0.key != "tab" && $0.key != "sheet" }.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.isEmpty ? "∅" : String($0.value.prefix(120)))" }.joined(separator: ", ")
        if !details.isEmpty { lines.append("- \(clock(event.t)) state: \(details)") }
    case "touch" where event.fields["phase"] == "began":
        lines.append("- \(clock(event.t)) tap (\(event.fields["x"] ?? "?"), \(event.fields["y"] ?? "?"))")
    case "request":
        lines.append("- \(clock(event.t)) \(event.fields["method"] ?? "") \(event.fields["path"] ?? "") → \(event.fields["status"] ?? "") in \(event.fields["ms"] ?? "?") ms")
    case "hang", "keyboard", "orientation", "scene", "memory_warning", "mark", "start", "stop":
        lines.append("- \(clock(event.t)) \(event.kind) \(event.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    default: break
    }
}
while nextFrame < frames.count { lines.append("  - frame `\(frames[nextFrame].file)` (\(frames[nextFrame].reason))"); nextFrame += 1 }
md += lines.joined(separator: "\n") + "\n"
try md.write(to: out.appendingPathComponent("review.md"), atomically: true, encoding: .utf8)

struct Packet: Codable { let signals: [Signal]; let remarks: [Remark]; let frames: [Frame]; let offset: Double; let syncFound: Bool }
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(Packet(signals: signals, remarks: remarks, frames: frames, offset: offset, syncFound: syncFound))
    .write(to: out.appendingPathComponent("review.json"))
print("Review: \(out.appendingPathComponent("review.md").path)")
print("\(signals.count) signals, \(remarks.count) remarks, \(frames.count) frames; sync \(syncFound ? "found" : "not found")")
