// Research-only, one-lane encrypted lean-cache qualification. No app/runtime integration.
// Array/logit and baseline decoding logic preserved from the prior explicit-recognizer probe.
import Accelerate
import CoreML
import CryptoKit
import Foundation
import Darwin

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func floats(_ array: MLMultiArray) -> [Float] {
 let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue), n = array.count
 var contiguous = true, expected = 1
 for d in stride(from: shape.count - 1, through: 0, by: -1) { if shape[d] > 1 && strides[d] != expected { contiguous = false }; expected *= shape[d] }
 let storage = contiguous ? n : zip(shape, strides).reduce(1) { $0 + ($1.0 - 1) * $1.1 }
 var raw = [Float](repeating: 0, count: storage)
 switch array.dataType {
 case .float16:
  array.withUnsafeBytes { bytes in
   var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: bytes.baseAddress!), height: 1, width: vImagePixelCount(storage), rowBytes: storage * 2)
   raw.withUnsafeMutableBytes { dst in
    var d = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(storage), rowBytes: storage * 4)
    vImageConvert_Planar16FtoPlanarF(&src, &d, 0)
   }
  }
 case .float32:
  array.withUnsafeBytes { bytes in raw.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: bytes.baseAddress, count: storage * 4)) } }
 default: return (0..<n).map { array[$0].floatValue }
 }
 if contiguous { return raw }
 var out = [Float](repeating: 0, count: n), index = [Int](repeating: 0, count: shape.count)
 for i in 0..<n {
  var offset = 0
  for d in 0..<shape.count { offset += index[d] * strides[d] }
  out[i] = raw[offset]
  var d = shape.count - 1
  while d >= 0 { index[d] += 1; if index[d] < shape[d] { break }; index[d] = 0; d -= 1 }
 }
 return out
}
func best(_ values: [Float], start: Int, count: Int) -> (Int, Double) {
 values.withUnsafeBufferPointer { all in
  let row = all.baseAddress! + start
  var maximum: Float = 0; var index: vDSP_Length = 0
  vDSP_maxvi(row, 1, &maximum, &index, vDSP_Length(count))
  var sum = 0.0
  for i in 0..<count { sum += exp(Double(row[i] - maximum)) }
  return (Int(index), 1 / sum)
 }
}

func fail(_ reason: String) throws -> Never { throw NSError(domain: "lean-probe." + reason, code: 1) }
func peakRSS() -> Int64 { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Int64(usage.ru_maxrss) }
func memoryGate(_ limit: Int64) throws { if limit > 0 && peakRSS() >= limit { try fail("memory_gate") } }
func contract(_ value: MLMultiArray, _ shape: [Int], _ type: MLMultiArrayDataType) throws {
    guard value.shape.map(\.intValue) == shape, value.dataType == type else { try fail("array_contract") }
}

/// Copy only the current token; respect both Core ML output strides and host cache strides.
func commit(_ delta: MLMultiArray, _ cache: MLMultiArray, positions: [Int]) throws {
    try contract(delta, [12,8,16,1,64], .float16)
    try contract(cache, [12,8,16,512,64], .float16)
    guard positions.count == 8, positions.allSatisfy({ (0..<512).contains($0) }) else { try fail("positions") }
    let ds = delta.strides.map(\.intValue), cs = cache.strides.map(\.intValue)
    delta.withUnsafeBytes { source in
        cache.withUnsafeMutableBytes { target, _ in
            let src = source.bindMemory(to: UInt16.self), dst = target.bindMemory(to: UInt16.self)
            for layer in 0..<12 { for row in 0..<8 { for head in 0..<16 {
                let from = layer * ds[0] + row * ds[1] + head * ds[2]
                let to = layer * cs[0] + row * cs[1] + head * cs[2] + positions[row] * cs[3]
                if ds[4] == 1 && cs[4] == 1 {
                    _ = memcpy(dst.baseAddress! + to, src.baseAddress! + from, 64 * 2)
                } else {
                    for channel in 0..<64 { dst[to + channel * cs[4]] = src[from + channel * ds[4]] }
                }
            } } }
        }
    }
}

struct Answer { var ids: [[Int]]; var probabilities: [[Double]] }
func decisions(_ probabilities: [[Double]], display: Bool) -> [Bool] {
    probabilities.map { row in
        let sorted = row.sorted()
        let confidence = sorted.isEmpty ? 0 : sorted[display && sorted.count > 1 ? 1 : 0]
        return confidence >= (display ? 0.95 : 0.8)
    }
}
func compare(_ actual: Answer, _ expected: Answer) throws -> Double {
    guard actual.ids == expected.ids else { try fail("token_parity") }
    guard actual.probabilities.count == expected.probabilities.count else { try fail("probability_count") }
    var delta = 0.0
    for (a,b) in zip(actual.probabilities, expected.probabilities) {
        guard a.count == b.count, a.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1 }),
              b.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1 }) else { try fail("probability_finite") }
        delta = max(delta, zip(a,b).map { abs($0 - $1) }.max() ?? 0)
    }
    for display in [false,true] {
        guard decisions(actual.probabilities, display: display) == decisions(expected.probabilities, display: display)
        else { try fail("acceptance_parity") }
    }
    return delta
}

@available(macOS 15.0, *)
func recognize(_ encoder: MLModel, _ decoder: MLModel, _ inputs: [[Float]], lean: Bool, rssLimit: Int64) throws -> Answer {
    let b = 8, plane = 448 * 448, n = inputs.count
    let pixels = try MLMultiArray(shape:[8,1,448,448], dataType:.float32)
    pixels.withUnsafeMutableBytes { raw, _ in
        let p = raw.bindMemory(to: Float.self)
        for i in 0..<(b * plane) { p[i] = 0 }
        for (i, input) in inputs.enumerated() {
            input.withUnsafeBufferPointer { src in _ = memcpy(p.baseAddress! + i * plane, src.baseAddress!, plane * 4) }
        }
    }
    let state = lean ? nil : decoder.makeState()
    let pixelInput = try MLDictionaryFeatureProvider(dictionary:["pixel_values":pixels])
    var cache: [String:MLMultiArray] = [:]
    if let state { _ = try encoder.prediction(from:pixelInput,using:state) }
    else {
        let encoded = try encoder.prediction(from:pixelInput)
        for name in ["cross_k","cross_v"] {
            guard let value = encoded.featureValue(for:name)?.multiArrayValue else { try fail("cross_output") }
            try contract(value, [12,8,16,785,64], .float16); cache[name] = value
        }
        for name in ["self_k","self_v"] {
            let value = try MLMultiArray(shape:[12,8,16,512,64],dataType:.float16)
            value.withUnsafeMutableBytes { raw,_ in _ = raw.initializeMemory(as:UInt8.self,repeating:0) }
            cache[name] = value
        }
    }
    try memoryGate(rssLimit)
    let token = try MLMultiArray(shape:[8,1],dataType:.int32)
    let position = try MLMultiArray(shape: lean ? [8] : [1],dataType:.int32)
    var ids = [[Int]](repeating:[0], count:n), probabilities = [[Double]](repeating:[], count:n)
    var done = [Bool](repeating:false,count:n)
    for step in 0..<511 {
        try autoreleasepool {
            for row in 0..<b { token[row] = NSNumber(value: row < n ? ids[row].last! : 2) }
            for row in 0..<(lean ? b : 1) { position[row] = NSNumber(value:step) }
            var fields = cache; fields["token"] = token; fields["position"] = position
            let features = try MLDictionaryFeatureProvider(dictionary:fields), result: MLFeatureProvider
            if let state { result = try decoder.prediction(from:features,using:state) }
            else {
                result = try decoder.prediction(from:features)
                for (output,input) in [("new_k","self_k"),("new_v","self_v")] {
                    guard let delta = result.featureValue(for:output)?.multiArrayValue else { try fail("delta_output") }
                    try commit(delta, cache[input]!, positions:[Int](repeating:step,count:b))
                }
            }
            guard let logits = result.featureValue(for:"logits")?.multiArrayValue else { try fail("logits_output") }
            if lean { try contract(logits, [8,15000], .float32) }
            let values = floats(logits), vocabulary = values.count / b
            guard values.allSatisfy(\.isFinite), vocabulary == 15000, values.count == b * vocabulary else { try fail("logits_finite") }
            for row in 0..<n where !done[row] {
                let (id,p) = best(values,start:row * vocabulary,count:vocabulary)
                ids[row].append(id); probabilities[row].append(p); if id == 2 { done[row] = true }
            }
            try memoryGate(rssLimit)
        }
        if done.allSatisfy({ $0 }) { break }
    }
    guard done.allSatisfy({ $0 }) else { try fail("sequence_limit") }
    return Answer(ids: ids.map { Array($0.dropFirst()) }, probabilities: probabilities)
}

// Padded and non-unit last-axis strides catch incorrect contiguous row copies.
func selfTest() throws {
    func array(_ shape: [Int], _ strides: [Int], fill: UInt16) throws -> MLMultiArray {
        let count = zip(shape,strides).reduce(1) { $0 + ($1.0 - 1) * $1.1 }
        let pointer = UnsafeMutablePointer<UInt16>.allocate(capacity:count)
        pointer.initialize(repeating:fill,count:count)
        return try MLMultiArray(dataPointer:pointer,shape:shape.map(NSNumber.init),dataType:.float16,
                                strides:strides.map(NSNumber.init),deallocator:{ $0.deallocate() })
    }
    let ds = [8*16*131,16*131,131,131,2], cs = [8*16*512*129,16*512*129,512*129,129,2]
    let delta = try array([12,8,16,1,64],ds,fill:7), cache = try array([12,8,16,512,64],cs,fill:9)
    let positions = [0,511,7,1,255,32,500,16]
    let source = delta.dataPointer.assumingMemoryBound(to:UInt16.self), target = cache.dataPointer.assumingMemoryBound(to:UInt16.self)
    for l in 0..<12 { for r in 0..<8 { for h in 0..<16 { for d in 0..<64 {
        source[l*ds[0]+r*ds[1]+h*ds[2]+d*ds[4]] = UInt16(100 + l*2048 + r*256 + h*16 + d)
    } } } }
    try commit(delta,cache,positions:positions)
    for l in 0..<12 { for r in 0..<8 { for h in 0..<16 { for d in 0..<64 {
        let base = l*cs[0]+r*cs[1]+h*cs[2]
        let index = base + positions[r]*cs[3] + d*cs[4]
        guard target[index] == source[l*ds[0]+r*ds[1]+h*ds[2]+d*ds[4]], target[index+1] == 9,
              target[base + ((positions[r]+1)%512)*cs[3] + d*cs[4]] == 9 else { try fail("stride_selftest") }
    } } } }
    let a = Answer(ids:[[2],[3,2]],probabilities:[[0.8],[0.2,0.95]])
    guard decisions(a.probabilities,display:false) == [true,false], decisions(a.probabilities,display:true) == [false,true] else { try fail("confidence_selftest") }
    _ = try compare(a,a)
    do { _ = try compare(a,Answer(ids:a.ids,probabilities:[[0.7999],[0.2,0.95]])); try fail("missing_acceptance_rejection") }
    catch let error as NSError { guard error.domain == "lean-probe.acceptance_parity" else { throw error } }
}

@main struct Probe {
    static func main() async {
        guard #available(macOS 15.0, *) else { exit(2) }
        let argv = Array(CommandLine.arguments.dropFirst())
        if argv == ["--self-test"] {
            do { try selfTest(); print("stride and acceptance tests passed"); return }
            catch { print("native self-test failed"); exit(1) }
        }
        guard argv.count % 2 == 0 else { exit(2) }
        var args: [String:String] = [:]
        for i in stride(from:0,to:argv.count,by:2) { guard args[argv[i]] == nil else { exit(2) }; args[argv[i]] = argv[i+1] }
        guard let mode = args["--mode"], ["baseline","lean"].contains(mode), let modelPath = args["--model"],
              let samplesPath = args["--samples"], let outPath = args["--out"], let phase = args["--phase"],
              ["gate","trial"].contains(phase), let rssLimit = Int64(args["--rss-limit"] ?? "0"), rssLimit >= 0,
              (mode != "lean" || (rssLimit > 0 && args["--baseline-report"] != nil)) else { exit(2) }
        let out = URL(fileURLWithPath:outPath), root = URL(fileURLWithPath:modelPath), samplesRoot = URL(fileURLWithPath:samplesPath)
        guard !FileManager.default.fileExists(atPath:outPath) else { exit(2) }
        var report: [String:Any] = ["passed":false,"mode":mode,"phase":phase,"batch_size":8,"lanes":1,"max_length":512,
            "compute_units":"cpuAndGPU","schedule":"whole_batches","temporary_lifetime":"autoreleasepool per token and batch, both arms",
            "cache_host_copy":mode == "lean","rss_limit_exclusive_bytes":rssLimit,"source":"probe_texteller_lean_native.swift"]
        var stage = "inputs"
        func save() { report["stage"] = stage; report["peak_rss_bytes"] = peakRSS(); try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out,options:.atomic) }
        save()
        do {
            let metadata = try Data(contentsOf:samplesRoot.appendingPathComponent("export.json"))
            let json = try JSONSerialization.jsonObject(with:metadata) as! [String:Any]
            let samples = (json["equivalence"] as! [String:Any])["samples"] as! [[String:Any]]
            guard samples.count == 20 else { try fail("fixed_budget") }
            var hashes: [String] = []
            let inputs: [[Float]] = try samples.map { sample in
                guard let file = sample["file"] as? String, file == URL(fileURLWithPath:file).lastPathComponent else { try fail("sample_path") }
                let data = try Data(contentsOf:samplesRoot.appendingPathComponent("samples").appendingPathComponent(file)); hashes.append(digest(data))
                guard data.count > 10, Array(data.prefix(6)) == [147,78,85,77,80,89], data[6] == 1 else { try fail("npy_header") }
                let header = Int(data[8]) | Int(data[9]) << 8
                guard data.count == 10 + header + 448*448*4,
                      let text = String(data:data.subdata(in:10..<(10+header)),encoding:.ascii), text.contains("'<f4'"), text.contains("False") else { try fail("input_shape") }
                return data.subdata(in:(10+header)..<data.count).withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
            }
            report["input_sha256"] = hashes; report["sample_export_sha256"] = digest(metadata); report["inputs"] = inputs.count
            var baseline: Answer?
            if let path = args["--baseline-report"] {
                let d = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as! [String:Any]
                guard d["passed"] as? Bool == true, d["mode"] as? String == "baseline", d["phase"] as? String == "gate",
                      d["input_sha256"] as? [String] == hashes, d["sample_export_sha256"] as? String == digest(metadata),
                      let ids = d["tokens"] as? [[Int]], let probs = d["probabilities"] as? [[Double]] else { try fail("baseline_report") }
                baseline = Answer(ids:ids,probabilities:probs)
            }
            func load(_ file: String?, _ function: String?) async throws -> MLModel {
                let config = MLModelConfiguration(); config.computeUnits = .cpuAndGPU; config.functionName = function
                return try await MLModel.load(contentsOf:file.map { root.appendingPathComponent($0) } ?? root,configuration:config)
            }
            stage = "load_encoder"; save(); let encoder = try await load(mode == "lean" ? "encoder.mlmodelc" : nil, mode == "lean" ? nil : "prefill")
            try memoryGate(rssLimit)
            stage = "load_step"; save(); let decoder = try await load(mode == "lean" ? "step.mlmodelc" : nil, mode == "lean" ? nil : "step")
            try memoryGate(rssLimit)
            if mode == "lean" {
                guard encoder.modelDescription.stateDescriptionsByName.isEmpty, decoder.modelDescription.stateDescriptionsByName.isEmpty,
                      Set(encoder.modelDescription.inputDescriptionsByName.keys) == ["pixel_values"],
                      Set(encoder.modelDescription.outputDescriptionsByName.keys) == ["cross_k","cross_v"],
                      Set(decoder.modelDescription.inputDescriptionsByName.keys) == ["token","position","self_k","self_v","cross_k","cross_v"],
                      Set(decoder.modelDescription.outputDescriptionsByName.keys) == ["logits","new_k","new_v"] else { try fail("stateless_interface") }
            }
            func run() throws -> Answer {
                var answer = Answer(ids:[],probabilities:[])
                for offset in stride(from:0,to:inputs.count,by:8) {
                    let batch = try autoreleasepool { try recognize(encoder,decoder,Array(inputs[offset..<min(inputs.count,offset+8)]),lean:mode == "lean",rssLimit:rssLimit) }
                    answer.ids += batch.ids; answer.probabilities += batch.probabilities; save()
                }
                return answer
            }
            stage = "warmup"; save(); let warm = try run()
            _ = try compare(warm,warm)
            let recorded = samples.map { Array(($0["ids"] as! [Int]).dropFirst()) }
            guard warm.ids == recorded else { try fail("recorded_tokens") }
            report["max_probability_delta_vs_baseline"] = try baseline.map { try compare(warm,$0) } ?? 0
            if phase == "trial" {
                stage = "trial"; save(); let start = ProcessInfo.processInfo.systemUptime; let answer = try run()
                let seconds = ProcessInfo.processInfo.systemUptime - start
                let delta = try compare(answer,warm)
                guard delta <= 0.000001 else { try fail("repeat_probability_stability") }
                report["max_probability_delta_vs_baseline"] = try baseline.map { try compare(answer,$0) } ?? 0
                report["repeat_max_probability_delta"] = delta; report["decode_seconds"] = seconds
            }
            report["tokens"] = warm.ids; report["probabilities"] = warm.probabilities
            report["inline_acceptance"] = decisions(warm.probabilities,display:false)
            report["display_acceptance"] = decisions(warm.probabilities,display:true)
            report["passed"] = true; stage = "complete"; save()
        } catch {
            let ns = error as NSError
            report["error_domain"] = String(ns.domain.prefix(100)); report["error_code"] = ns.code
            report["error_detail"] = String(ns.localizedDescription.replacingOccurrences(of:#"https?://\S+|/\S+|[A-Za-z0-9+/=]{24,}"#,with:"[redacted]",options:.regularExpression).prefix(300))
            save(); exit(1)
        }
    }
}
