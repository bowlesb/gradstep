// Owner-device Core ML precision/reliability audit; no training or PDF access.
// swiftc -O audit_tagger_runtime.swift -o audit-tagger-runtime
// audit-tagger-runtime BASELINE.mlmodelc CANDIDATE.mlmodelc INPUTS.json REFERENCE.json OUTDIR
//   [--passes 10] [--warmup 16] [--phase quiet] [--candidate-policy float32|fallback]
// Each pass pairs the same inputs, alternating model order by pass. Every raw
// attempt is logged. An invalid buffer retries once; a prediction throw does not,
// matching DevicePDFModels.readTaggerOutput. No retry success hides the first failure.
import Foundation
import CoreML
import CryptoKit

struct Input: Decodable { let x: [Float]; let font: [Int32]; let cls: [Int32]; let char: [Int32] }
struct Reference: Decodable { let checkpoint_sha256: String; let inputs_sha256: String; let logits: [[Float]] }
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
func writeJSON(_ value: Any, _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
}
func modelHash(_ url: URL) throws -> String {
    let files = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.sorted { $0.path < $1.path }
    guard !files.isEmpty else { throw NSError(domain: "empty model", code: 1) }
    var digest = SHA256()
    for file in files {
        digest.update(data: Data(file.path.dropFirst(url.path.count).utf8)); digest.update(data: Data([0]))
        digest.update(data: try Data(contentsOf: file)); digest.update(data: Data([0]))
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
func offsets(_ shape: [Int], _ strides: [Int]) -> [Int] {
    var index = [Int](repeating: 0, count: shape.count), result = [Int]()
    for _ in 0..<shape.reduce(1, *) {
        result.append(zip(index, strides).reduce(0) { $0 + $1.0 * $1.1 })
        var d = shape.count - 1
        while d >= 0 { index[d] += 1; if index[d] < shape[d] { break }; index[d] = 0; d -= 1 }
    }
    return result
}
func dense(_ shape: [Int], _ strides: [Int]) -> Bool {
    var expected = 1
    for d in stride(from: shape.count - 1, through: 0, by: -1) {
        if shape[d] > 1 && strides[d] != expected { return false }; expected *= shape[d]
    }
    return true
}
func read(_ array: MLMultiArray) -> ([Float], [String: Any]) {
    // Preserve the production reader's pre-access layout, but reject an unsafe
    // storage span instead of reading past its buffer. Record any scope change.
    let shape = array.shape.map(\.intValue), before = array.strides.map(\.intValue)
    let indices = offsets(shape, before)
    var inside = [Int](), bytes = 0, inBounds = false, values = [Float]()
    array.withUnsafeBytes { raw in
        inside = array.strides.map(\.intValue); bytes = raw.count
        let size = array.dataType == .float16 ? 2 : array.dataType == .float32 ? 4 : 8
        inBounds = (indices.max() ?? 0) * size + size <= raw.count
        guard inBounds else { return }
        values = indices.map { i in
            switch array.dataType {
            case .float16: return Float(Float16(bitPattern: raw.load(fromByteOffset: i * 2, as: UInt16.self)))
            case .float32: return raw.load(fromByteOffset: i * 4, as: Float.self)
            case .double: return Float(raw.load(fromByteOffset: i * 8, as: Double.self))
            default: fatalError("unexpected tagger output type")
            }
        }
    }
    return (values, ["shape": shape, "dtype": array.dataType.rawValue, "strides_before": before,
                     "strides_inside": inside, "bytes": bytes, "storage_in_bounds": inBounds])
}
func invalidReason(_ values: [Float], _ expected: Int) -> String? {
    if values.count != expected { return "length" }
    if !values.allSatisfy(\.isFinite) { return "nonfinite" }
    if !values.contains(where: { $0 != 0 }) { return "all_zero" }
    var run = 0
    for v in values { run = v == 0 ? run + 1 : 0; if run >= 8 { return "partial_zero" } }
    return nil
}
func quantiles(_ x: [Double]) -> [String: Any] {
    let sorted = x.sorted()
    func q(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[Int((Double(sorted.count - 1) * p).rounded())] }
    return ["count": x.count, "median": q(0.5), "p95": q(0.95), "p99": q(0.99), "max": sorted.last ?? 0]
}
let threshold = logf(0.65 / 0.35)
struct ErrorMetrics {
    var glyphs = 0, flips = 0, ownGlyphs = 0, ownFlips = 0, sum = 0.0, square = 0.0, maximum = 0.0
    mutating func add(_ a: [Float], _ b: [Float], _ input: Input) -> Int {
        precondition(a.count == b.count && a.count == input.font.count)
        var changed = 0
        for i in a.indices {
            let error = Double(abs(a[i] - b[i])), flip = (a[i] >= threshold) != (b[i] >= threshold)
            glyphs += 1; sum += error; square += error * error; maximum = max(maximum, error)
            if flip { flips += 1; changed += 1 }
            if input.x[i * 12 + 10] == 0 && input.x[i * 12 + 11] == 0 { ownGlyphs += 1; if flip { ownFlips += 1 } }
        }
        return changed
    }
    var json: [String: Any] { ["glyphs": glyphs, "threshold_flips": flips, "own_glyphs": ownGlyphs,
        "own_threshold_flips": ownFlips, "mean_abs": sum / Double(max(1, glyphs)),
        "rmse": sqrt(square / Double(max(1, glyphs))), "max_abs": maximum] }
}
struct Stats {
    var primary = 0, attempts = 0, invalidPrimary = 0, invalidRetry = 0, predictionThrows = 0, recovered = 0, failed = 0
    var layoutChanges = 0, inputNondense = 0, repeatsChanged = 0, repeatDecisionChanges = 0
    var primaryMS = [Double](), effectiveMS = [Double](), retryMS = [Double]()
    var reference = ErrorMetrics(), referenceFirstPass = ErrorMetrics(), repeatErrors = ErrorMetrics()
    var firstInvalid: [String: Any]?
    var json: [String: Any] { ["primary_calls": primary, "raw_attempts": attempts, "invalid_primary": invalidPrimary,
        "invalid_retry": invalidRetry, "prediction_throws": predictionThrows, "recovered": recovered,
        "exhausted_or_thrown": failed, "layout_changes": layoutChanges, "input_nondense": inputNondense,
        "repeat_values_changed": repeatsChanged, "repeat_decisions_changed": repeatDecisionChanges,
        "primary_ms": quantiles(primaryMS), "effective_ms": quantiles(effectiveMS), "retry_ms": quantiles(retryMS),
        "reference": reference.json, "reference_first_pass": referenceFirstPass.json,
        "repeat_errors": repeatErrors.json, "first_invalid": firstInvalid ?? [:]] }
}
final class Arm {
    let name: String, primaryModel: MLModel, retryModel: MLModel
    let primaryRole: String, retryRole: String
    var stats = Stats(), warmup = Stats(), references: [[Float]?]
    init(_ name: String, _ primary: MLModel, _ retry: MLModel, _ primaryRole: String, _ retryRole: String, count: Int) {
        self.name = name; self.primaryModel = primary; self.retryModel = retry
        self.primaryRole = primaryRole; self.retryRole = retryRole
        self.references = .init(repeating: nil, count: count)
    }
}
var args = Array(CommandLine.arguments.dropFirst())
func option(_ key: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: key), i + 1 < args.count else { return fallback }
    let v = args[i+1]; args.removeSubrange(i...i+1); return v
}
let passes = Int(option("--passes", "10"))!, warmupCount = Int(option("--warmup", "16"))!
let phase = option("--phase", "quiet"), policy = option("--candidate-policy", "float32")
guard args.count == 5, passes > 0, warmupCount >= 0, ["float32", "fallback"].contains(policy) else { fatalError("See usage comment") }
let baselineURL = URL(fileURLWithPath: args[0]), candidateURL = URL(fileURLWithPath: args[1])
let inputURL = URL(fileURLWithPath: args[2]), referenceURL = URL(fileURLWithPath: args[3]), out = URL(fileURLWithPath: args[4])
guard !FileManager.default.fileExists(atPath: out.path) else { fatalError("Output directory already exists") }
let inputData = try Data(contentsOf: inputURL), referenceData = try Data(contentsOf: referenceURL)
let inputs = try JSONDecoder().decode([Input].self, from: inputData), reference = try JSONDecoder().decode(Reference.self, from: referenceData)
precondition(!inputs.isEmpty && hash(inputData) == reference.inputs_sha256 && inputs.count == reference.logits.count)
for (i, x) in inputs.enumerated() {
    precondition((2...400).contains(x.font.count) && x.x.count == x.font.count * 12 && x.cls.count == x.font.count && x.char.count == x.font.count)
    precondition(x.x.allSatisfy(\.isFinite) && reference.logits[i].count == x.font.count && reference.logits[i].allSatisfy(\.isFinite))
}
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let started = timestamp(), clock = Date()
var loadMS: [String: Double] = [:]
func load(_ url: URL, _ name: String) throws -> MLModel {
    let c = MLModelConfiguration(); c.computeUnits = .cpuOnly
    let start = Date(), model = try MLModel(contentsOf: url, configuration: c)
    loadMS[name] = Date().timeIntervalSince(start) * 1000; return model
}
let baseline = try load(baselineURL, "baseline"), candidate = try load(candidateURL, "candidate")
let fallbackPrimary = policy == "fallback" ? try load(baselineURL, "fallback_primary") : candidate
let a = Arm("baseline", baseline, baseline, "baseline", "baseline", count: inputs.count)
let b = Arm("candidate", fallbackPrimary, candidate, policy == "fallback" ? "baseline" : "candidate", "candidate", count: inputs.count)
var metadata: [String: Any] = ["started_utc": started, "phase": phase, "candidate_policy": policy, "passes": passes,
    "inputs": inputs.count, "warmup_per_arm": min(warmupCount, inputs.count), "input_sha256": hash(inputData),
    "reference_sha256": hash(referenceData), "checkpoint_sha256": reference.checkpoint_sha256,
    "baseline_model_tree_sha256": try modelHash(baselineURL), "candidate_model_tree_sha256": try modelHash(candidateURL),
    "baseline_model": baselineURL.path, "candidate_model": candidateURL.path, "compute_units": "cpuOnly", "load_ms": loadMS,
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "order": "same input paired; baseline first on even passes, candidate first on odd passes",
    "warmup": "first fixed inputs; invalids/retries logged separately; fallback recovery model not prewarmed",
    "retry": "at most two attempts; buffer-invalid retries, prediction throws do not; no outputs synthesized"]
try writeJSON(metadata, out.appendingPathComponent("manifest.json"))
FileManager.default.createFile(atPath: out.appendingPathComponent("calls.jsonl").path, contents: nil)
let calls = try FileHandle(forWritingTo: out.appendingPathComponent("calls.jsonl"))
func log(_ row: [String: Any]) throws {
    var bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); bytes.append(10); try calls.write(contentsOf: bytes)
}
func inputFeatures(_ x: Input) throws -> (MLFeatureProvider, Int) {
    let n = x.font.count; var nondense = 0
    let xs = try MLMultiArray(shape: [1, NSNumber(value: n), 12], dataType: .float32)
    x.x.withUnsafeBufferPointer { src in xs.withUnsafeMutableBytes { raw, strides in
        if !dense(xs.shape.map(\.intValue), strides) { nondense += 1 }; raw.copyMemory(from: UnsafeRawBufferPointer(src))
    } }
    func ints(_ values: [Int32]) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        values.withUnsafeBufferPointer { src in a.withUnsafeMutableBytes { raw, strides in
            if !dense(a.shape.map(\.intValue), strides) { nondense += 1 }; raw.copyMemory(from: UnsafeRawBufferPointer(src))
        } }; return a
    }
    return (try MLDictionaryFeatureProvider(dictionary: ["x": xs, "font": ints(x.font), "cls": ints(x.cls), "char": ints(x.char)]), nondense)
}
func evaluate(_ arm: Arm, _ index: Int, _ pass: Int, warm: Bool = false) throws -> [Float]? {
    var stats = warm ? arm.warmup : arm.stats
    defer { if warm { arm.warmup = stats } else { arm.stats = stats } }
    let input = inputs[index], (features, nondense) = try inputFeatures(input)
    stats.primary += 1; stats.inputNondense += nondense
    var elapsed = 0.0
    for attempt in 0..<2 {
        stats.attempts += 1
        let start = DispatchTime.now().uptimeNanoseconds
        var values = [Float](), layout: [String: Any] = [:], thrown: String?
        do {
            if let output = try (attempt == 0 ? arm.primaryModel : arm.retryModel).prediction(from: features).featureValue(for: "logits")?.multiArrayValue {
                (values, layout) = read(output)
            }
        } catch { thrown = String(describing: error).prefix(200).description }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6; elapsed += ms
        if attempt == 0 { stats.primaryMS.append(ms) } else { stats.retryMS.append(ms) }
        let invalid = thrown == nil ? invalidReason(values, input.font.count) : "prediction_throw"
        if let before = layout["strides_before"] as? [Int], let inside = layout["strides_inside"] as? [Int], before != inside { stats.layoutChanges += 1 }
        var row: [String: Any] = ["arm": arm.name, "model_role": attempt == 0 ? arm.primaryRole : arm.retryRole,
            "pass": pass, "input_index": index, "attempt": attempt + 1, "warmup": warm, "milliseconds": ms,
            "glyphs": input.font.count, "valid": invalid == nil, "layout": layout,
            "logits_sha256": values.withUnsafeBytes { hash(Data($0)) }]
        if let invalid {
            row["reason"] = invalid; if let thrown { row["error"] = thrown; stats.predictionThrows += 1 }
            if attempt == 0 { stats.invalidPrimary += 1 } else { stats.invalidRetry += 1 }
            if stats.firstInvalid == nil {
                stats.firstInvalid = row
                let parsed = try JSONSerialization.jsonObject(with: inputData) as! [Any]
                try writeJSON([parsed[index]], out.appendingPathComponent("first-invalid-\(arm.name)-\(warm ? "warmup" : "measured").json"))
            }
        } else if !warm {
            row["reference_decision_flips"] = stats.reference.add(values, reference.logits[index], input)
            if pass == 0 { _ = stats.referenceFirstPass.add(values, reference.logits[index], input) }
            if let prior = arm.references[index] {
                let changed = !zip(prior, values).allSatisfy { $0.bitPattern == $1.bitPattern }
                let flips = stats.repeatErrors.add(values, prior, input)
                row["repeat_values_changed"] = changed; row["repeat_decision_flips"] = flips
                if changed { stats.repeatsChanged += 1 }; if flips > 0 { stats.repeatDecisionChanges += 1 }
            } else { arm.references[index] = values }
        }
        try log(row)
        if invalid == nil {
            if attempt == 1 { stats.recovered += 1 }; stats.effectiveMS.append(elapsed); return values
        }
        if thrown != nil { break }
    }
    stats.failed += 1; stats.effectiveMS.append(elapsed); return nil
}
for i in 0..<min(warmupCount, inputs.count) { try autoreleasepool { _ = try evaluate(a, i, -1, warm: true); _ = try evaluate(b, i, -1, warm: true) } }
var comparison = ErrorMetrics(), comparisonFirstPass = ErrorMetrics(), failedPairs = 0, changedPairs = 0
func summary(_ complete: Bool) -> [String: Any] {
    ["completed": complete, "phase": phase, "candidate_policy": policy, "started_utc": started, "updated_utc": timestamp(),
     "seconds": Date().timeIntervalSince(clock), "baseline": a.stats.json, "candidate": b.stats.json,
     "warmup": ["baseline": a.warmup.json, "candidate": b.warmup.json], "paired_logit_error": comparison.json,
     "paired_logit_error_first_pass": comparisonFirstPass.json, "pairs_without_valid_outputs": failedPairs,
     "pairs_with_threshold_flips": changedPairs]
}
try writeJSON(summary(false), out.appendingPathComponent("summary.json"))
for pass in 0..<passes {
    for i in inputs.indices {
        try autoreleasepool {
            let av: [Float]?, bv: [Float]?
            if pass % 2 == 0 { av = try evaluate(a, i, pass); bv = try evaluate(b, i, pass) }
            else { bv = try evaluate(b, i, pass); av = try evaluate(a, i, pass) }
            if let av, let bv {
                if comparison.add(av, bv, inputs[i]) > 0 { changedPairs += 1 }
                if pass == 0 { _ = comparisonFirstPass.add(av, bv, inputs[i]) }
            } else { failedPairs += 1 }
        }
    }
    try writeJSON(summary(false), out.appendingPathComponent("summary.json"))
    print("pass \(pass + 1)/\(passes): baseline invalid \(a.stats.invalidPrimary)/\(a.stats.primary), exhausted \(a.stats.failed); candidate invalid \(b.stats.invalidPrimary)/\(b.stats.primary), exhausted \(b.stats.failed)")
    fflush(stdout)
}
try calls.close(); try writeJSON(summary(true), out.appendingPathComponent("summary.json"))
print("completed \(phase); evidence \(out.path)")
