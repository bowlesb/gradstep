import Accelerate
import CoreML
import Foundation

/// The three exported models of the device route (docs/architecture/DEVICE_PDF_ROUTE.md) and their contracts, from
/// `device-models.json` beside the compiled models (`scripts/device-models.mjs` writes it from the exports).
public struct DevicePDFModelConfiguration: Decodable, Sendable {
    /// `function`: one function of a multifunction package (the recogniser's `prefill` and `step`, which share one state).
    public struct Model: Decodable, Sendable { public let id: String; public let file: String; public let weightsSHA256: String; public let function: String?
        enum CodingKeys: String, CodingKey { case id, file, function; case weightsSHA256 = "weights_sha256" } }
    public struct Layout: Decodable, Sendable {
        public let model: Model
        public let classes: [String]
        public let thresholds: [String: Double]
        public let nmsIoU: Double
        public let maxDetections: Int
        public let canvasWidth: Int, canvasHeight: Int
        enum CodingKeys: String, CodingKey { case model, classes, thresholds; case nmsIoU = "nms_iou"; case maxDetections = "max_detections"
            case canvasWidth = "canvas_width"; case canvasHeight = "canvas_height" }
    }
    public struct Tagger: Decodable, Sendable { public let model: Model; public let vocabulary: String }
    public struct Recogniser: Decodable, Sendable {
        public let encoder: Model, decoder: Model
        public let bos: Int, eos: Int, maxLength: Int, imageSize: Int
        public let mean: Double, std: Double
        public let vocabulary: String, addedTokens: String
        enum CodingKeys: String, CodingKey { case encoder, decoder, bos, eos, mean, std; case maxLength = "max_len"; case imageSize = "image_size"
            case vocabulary; case addedTokens = "added_tokens" }
    }
    public let layout: Layout
    public let tagger: Tagger
    public let recogniser: Recogniser
}

public enum DevicePDFModelError: Error, Equatable, Sendable {
    case missing(String)
    case unusable(String)
}

/// Loaded models. One instance per conversion thread: Core ML models are thread-safe for prediction, the decoder's
/// state is per crop.
@available(iOS 18.0, macOS 15.0, *)
public final class DevicePDFModels: @unchecked Sendable {
    public let configuration: DevicePDFModelConfiguration
    public let directory: URL
    let layout: MLModel
    let tagger: MLModel
    /// The recogniser, when this device can load it. Without it the route still reads the paper: every formula is
    /// shown as its image (the gate's own fallback), and `recogniserIssue` says why.
    let encoder: MLModel?
    let decoder: MLModel?
    public private(set) var recogniserIssue: String?
    let tokenizer: DevicePDFTokenizer
    /// The tagger's vocabularies and threshold (`vocab.json`), passed to the converter as they are.
    public let taggerVocabulary: Any
    public private(set) var loadSeconds: [String: Double] = [:]

    /// `layoutUnits`/`recogniserUnits`: the Neural Engine cannot load the stateful decoder (Mac, 2026-10-15), so the
    /// recogniser runs on CPU and GPU; the layout and tagger may use the Neural Engine.
    public init(directory: URL, layoutUnits: MLComputeUnits = .cpuAndNeuralEngine, taggerUnits: MLComputeUnits = .cpuOnly,
                recogniserUnits: MLComputeUnits = .cpuAndGPU) throws {
        self.directory = directory
        let configURL = directory.appendingPathComponent("device-models.json")
        guard let data = try? Data(contentsOf: configURL) else { throw DevicePDFModelError.missing("device-models.json") }
        let configuration = try JSONDecoder().decode(DevicePDFModelConfiguration.self, from: data)
        self.configuration = configuration
        var seconds: [String: Double] = [:]
        func load(_ model: DevicePDFModelConfiguration.Model, _ units: MLComputeUnits, _ role: String) throws -> MLModel {
            let url = directory.appendingPathComponent(model.file)
            guard FileManager.default.fileExists(atPath: url.path) else { throw DevicePDFModelError.missing(model.file) }
            let config = MLModelConfiguration(); config.computeUnits = units
            if let function = model.function { config.functionName = function }
            let start = Date()
            do {
                let loaded = try MLModel(contentsOf: url, configuration: config)
                seconds[role] = Date().timeIntervalSince(start)
                return loaded
            } catch { throw DevicePDFModelError.unusable("\(model.file): \(error.localizedDescription)") }
        }
        layout = try load(configuration.layout.model, layoutUnits, "layout")
        tagger = try load(configuration.tagger.model, taggerUnits, "tagger")
        // The stateful decoder does not load everywhere (the Neural Engine on the Mac; the iOS Simulator): the asked
        // units first, then the CPU alone, then none.
        var loaded: (MLModel, MLModel)?, issue: String?
        for units in recogniserUnits == .cpuOnly ? [MLComputeUnits.cpuOnly] : [recogniserUnits, .cpuOnly] {
            do {
                let e = try load(configuration.recogniser.encoder, units, "encoder"), d = try load(configuration.recogniser.decoder, units, "decoder")
                _ = d.makeState()
                loaded = (e, d); issue = nil; break
            } catch { issue = "\(error)" }
        }
        encoder = loaded?.0; decoder = loaded?.1; recogniserIssue = issue
        loadSeconds = seconds
        guard let vocabulary = try? Data(contentsOf: directory.appendingPathComponent(configuration.tagger.vocabulary)),
              let tagger = try? JSONSerialization.jsonObject(with: vocabulary) else { throw DevicePDFModelError.missing(configuration.tagger.vocabulary) }
        taggerVocabulary = tagger
        tokenizer = try DevicePDFTokenizer(vocabulary: directory.appendingPathComponent(configuration.recogniser.vocabulary),
                                           added: directory.appendingPathComponent(configuration.recogniser.addedTokens))
    }

    /// The provenance rows the converter writes (role, id, weights digest).
    public var provenance: [[String: String]] {
        [["role": "layout", "id": configuration.layout.model.id, "sha256": configuration.layout.model.weightsSHA256],
         ["role": "equations-encoder", "id": configuration.recogniser.encoder.id, "sha256": configuration.recogniser.encoder.weightsSHA256],
         ["role": "equations-decoder", "id": configuration.recogniser.decoder.id, "sha256": configuration.recogniser.decoder.weightsSHA256],
         ["role": "inline-tagger", "id": configuration.tagger.model.id, "sha256": configuration.tagger.model.weightsSHA256]]
    }

    // MARK: Layout

    public struct Detection: Sendable, Equatable { public let cls: String; public let score: Double; public let box: [Double] }

    /// The page (150 dpi RGB) on the fixed canvas, then the app-side decoding: per-class thresholds, greedy NMS per
    /// class at the export's IoU, the best `max_detections` by score. Boxes in canvas pixels, rounded like the
    /// reference (`coreml_layout.detect`: boxes to 0.1, scores to 4 places). Returns the canvas scale too.
    public func detect(page: CGImage) throws -> (detections: [Detection], scale: Double) {
        let c = configuration.layout
        let (buffer, scale) = try DevicePDFRaster.canvas(page, width: c.canvasWidth, height: c.canvasHeight)
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
        let output = try layout.prediction(from: input)
        guard let boxes = output.featureValue(for: "boxes")?.multiArrayValue, let scores = output.featureValue(for: "scores")?.multiArrayValue,
              boxes.shape.count == 2, scores.shape.count == 2, boxes.shape[0] == scores.shape[0], scores.shape[1].intValue == c.classes.count else {
            throw DevicePDFModelError.unusable("layout outputs")
        }
        let n = boxes.shape[0].intValue, k = c.classes.count
        let b = Self.floats(boxes), s = Self.floats(scores)
        return (Self.decode(boxes: b, scores: s, points: n, classes: c.classes, thresholds: c.thresholds, iou: c.nmsIoU, maximum: c.maxDetections, k: k), scale)
    }

    static func decode(boxes b: [Float], scores s: [Float], points n: Int, classes: [String], thresholds: [String: Double],
                       iou: Double, maximum: Int, k: Int) -> [Detection] {
        var found: [(cls: Int, score: Float, point: Int)] = []
        for ci in 0..<k {
            let threshold = Float(thresholds[classes[ci]] ?? 1)
            var candidates: [Int] = []
            for p in 0..<n where s[p * k + ci] >= threshold { candidates.append(p) }
            if candidates.isEmpty { continue }
            // Greedy NMS: highest score first (stable for ties, as numpy's argsort of the negated scores is not;
            // ties between distinct boxes are vanishingly rare in fp16 scores).
            candidates.sort { s[$0 * k + ci] > s[$1 * k + ci] }
            var suppressed = [Bool](repeating: false, count: candidates.count)
            for i in 0..<candidates.count where !suppressed[i] {
                let a = candidates[i]
                found.append((ci, s[a * k + ci], a))
                let ax0 = b[a * 4], ay0 = b[a * 4 + 1], ax1 = b[a * 4 + 2], ay1 = b[a * 4 + 3]
                let areaA = (ax1 - ax0) * (ay1 - ay0)
                for j in (i + 1)..<candidates.count where !suppressed[j] {
                    let o = candidates[j]
                    let ix = max(0, min(ax1, b[o * 4 + 2]) - max(ax0, b[o * 4])), iy = max(0, min(ay1, b[o * 4 + 3]) - max(ay0, b[o * 4 + 1]))
                    let inter = ix * iy
                    let areaO = (b[o * 4 + 2] - b[o * 4]) * (b[o * 4 + 3] - b[o * 4 + 1])
                    if Double(inter / (areaA + areaO - inter + 1e-9)) > iou { suppressed[j] = true }
                }
            }
        }
        found.sort { $0.score > $1.score }
        return found.prefix(maximum).map { f in
            let box = (0..<4).map { (Double(b[f.point * 4 + $0]) * 10).rounded() / 10 }
            return Detection(cls: classes[f.cls], score: (Double(f.score) * 10_000).rounded() / 10_000, box: box)
        }
    }

    // MARK: Inline tagger

    /// One line's features (computed by the converter) to one logit per glyph.
    public func tag(x: [Float], font: [Int32], cls: [Int32], char: [Int32]) throws -> [Float] {
        let t = font.count
        guard t >= 2, t <= 400, x.count == t * 10, cls.count == t, char.count == t else { throw DevicePDFModelError.unusable("tagger input") }
        let xs = try MLMultiArray(shape: [1, NSNumber(value: t), 10], dataType: .float32)
        x.withUnsafeBufferPointer { src in xs.withUnsafeMutableBytes { raw, _ in raw.copyMemory(from: UnsafeRawBufferPointer(src)) } }
        func ints(_ values: [Int32]) throws -> MLMultiArray {
            let array = try MLMultiArray(shape: [1, NSNumber(value: t)], dataType: .int32)
            values.withUnsafeBufferPointer { src in array.withUnsafeMutableBytes { raw, _ in raw.copyMemory(from: UnsafeRawBufferPointer(src)) } }
            return array
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["x": xs, "font": try ints(font), "cls": try ints(cls), "char": try ints(char)])
        guard let logits = try tagger.prediction(from: input).featureValue(for: "logits")?.multiArrayValue else { throw DevicePDFModelError.unusable("tagger output") }
        let all = Self.floats(logits)
        guard all.count >= t else { throw DevicePDFModelError.unusable("tagger output") }
        return Array(all.prefix(t))
    }

    // MARK: Recogniser

    public struct Recognition: Sendable { public let latex: String; public let probabilities: [Double]; public let tokens: [Int] }

    /// One crop (RGB, already on white with the 8 px margin) to LaTeX and the probability of every chosen token,
    /// the end token included: TexTeller's own preprocessing, the encoder once, the stateful decoder step by step.
    public func recognise(crop: CGImage) throws -> Recognition {
        try recognise(batch: [recogniserInput(crop: crop)])[0]
    }

    /// The preprocessed input ([1, 1, 448, 448] float32) to LaTeX; the export's samples are already in this form.
    public func recognise(pixels: MLMultiArray) throws -> Recognition {
        let values = Self.floats(pixels)
        return try recognise(batch: [values])[0]
    }

    /// Crops the recogniser reads in one pass: the export's batch size (1 for the port kit's export; the batched
    /// exports of `scripts/device-pdf-models/export_texteller.py` take B crops in every encoder pass and decoder step).
    public var recogniserBatch: Int { encoder.flatMap { Self.batchSize($0) } ?? 1 }
    static func batchSize(_ encoder: MLModel) -> Int? {
        encoder.modelDescription.inputDescriptionsByName["pixel_values"]?.multiArrayConstraint?.shape.first?.intValue
    }
    /// The recogniser is one multifunction package: `prefill` (pixels into the shared state) and `step`.
    var isMultifunction: Bool { configuration.recogniser.encoder.function != nil }
    /// Whether the decoder takes the cross-attention keys and values as float16 (no conversion of the encoder's output).
    var decoderCrossIsHalf: Bool { decoder?.modelDescription.inputDescriptionsByName["cross_k"]?.multiArrayConstraint?.dataType == .float16 }

    /// Up to `recogniserBatch` preprocessed crops (448 × 448 floats each) to LaTeX, greedily, every crop to its end
    /// token or the cache's length. Unused rows of a batch are blank input whose output is ignored; a crop's tokens are
    /// those of a one-crop decode (each row's attention sees only its own cache and cross keys).
    public func recognise(batch inputs: [[Float]]) throws -> [Recognition] {
        let c = configuration.recogniser
        guard let encoder, let decoder else { throw DevicePDFModelError.unusable("recogniser: \(recogniserIssue ?? "not loaded")") }
        let b = recogniserBatch, side = c.imageSize, plane = side * side
        guard !inputs.isEmpty, inputs.count <= b, inputs.allSatisfy({ $0.count == plane }) else { throw DevicePDFModelError.unusable("recogniser input") }
        let pixels = try MLMultiArray(shape: [NSNumber(value: b), 1, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        pixels.withUnsafeMutableBytes { raw, _ in
            let p = raw.bindMemory(to: Float.self)
            for (i, input) in inputs.enumerated() { input.withUnsafeBufferPointer { src in _ = memcpy(p.baseAddress! + i * plane, src.baseAddress!, plane * 4) } }
            // Blank rows: the normalised white page (the preprocessing's padding value is 0, the mean grey).
            if inputs.count < b { for i in (inputs.count * plane)..<(b * plane) { p[i] = 0 } }
        }
        let state = decoder.makeState()
        // The multifunction package's `prefill` writes the cross keys and values into the shared state; the two-package
        // exports pass them into every step.
        var cross: [String: MLMultiArray] = [:]
        if isMultifunction {
            _ = try encoder.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["pixel_values": pixels]), using: state)
        } else {
            let encoded = try encoder.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["pixel_values": pixels]))
            guard let k16 = encoded.featureValue(for: "cross_k")?.multiArrayValue, let v16 = encoded.featureValue(for: "cross_v")?.multiArrayValue else {
                throw DevicePDFModelError.unusable("encoder outputs")
            }
            let half = decoderCrossIsHalf
            cross = ["cross_k": half ? k16 : try Self.float32(k16), "cross_v": half ? v16 : try Self.float32(v16)]
        }
        let token = try MLMultiArray(shape: [NSNumber(value: b), 1], dataType: .int32), position = try MLMultiArray(shape: [1], dataType: .int32)
        let n = inputs.count
        var ids = [[Int]](repeating: [c.bos], count: n), probabilities = [[Double]](repeating: [], count: n), done = [Bool](repeating: false, count: n)
        for step in 0..<(c.maxLength - 1) {
            for row in 0..<b { token[row] = NSNumber(value: row < n ? ids[row][ids[row].count - 1] : c.eos) }
            position[0] = NSNumber(value: step)
            var inputs: [String: MLMultiArray] = cross
            inputs["token"] = token; inputs["position"] = position
            let features = try MLDictionaryFeatureProvider(dictionary: inputs)
            guard let logits = try decoder.prediction(from: features, using: state).featureValue(for: "logits")?.multiArrayValue else {
                throw DevicePDFModelError.unusable("decoder output")
            }
            let values = Self.floats(logits), vocabulary = values.count / b
            for row in 0..<n where !done[row] {
                let (best, probability) = Self.argmaxProbability(values, from: row * vocabulary, count: vocabulary)
                ids[row].append(best); probabilities[row].append(probability)
                if best == c.eos { done[row] = true }
            }
            if !done.contains(false) { break }
        }
        return (0..<n).map { row in
            let generated = Array(ids[row].dropFirst())
            return Recognition(latex: tokenizer.decode(generated), probabilities: probabilities[row], tokens: generated)
        }
    }

    /// Evaluation: median milliseconds of the encoder pass, the cross keys' conversion and one decoder step at this
    /// export's batch size (blank input; `steps` steps after two warm-ups).
    public func stepTimes(steps: Int) throws -> [(String, Double)] {
        let c = configuration.recogniser
        guard let encoder, let decoder else { throw DevicePDFModelError.unusable("recogniser") }
        let b = recogniserBatch, side = c.imageSize
        let pixels = try MLMultiArray(shape: [NSNumber(value: b), 1, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        func ms(_ body: () throws -> Void) rethrows -> Double { let t = DispatchTime.now().uptimeNanoseconds; try body(); return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 }
        func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        let state = decoder.makeState()
        var encoded: MLFeatureProvider?
        var encode: [Double] = []
        let pixelInput = try MLDictionaryFeatureProvider(dictionary: ["pixel_values": pixels])
        for _ in 0..<5 {
            encode.append(try ms { encoded = isMultifunction ? try encoder.prediction(from: pixelInput, using: state) : try encoder.prediction(from: pixelInput) })
        }
        var cross: [String: MLMultiArray] = [:]
        var convert = 0.0
        if !isMultifunction, let k16 = encoded?.featureValue(for: "cross_k")?.multiArrayValue, let v16 = encoded?.featureValue(for: "cross_v")?.multiArrayValue {
            convert = try ms { cross = decoderCrossIsHalf ? ["cross_k": k16, "cross_v": v16] : ["cross_k": try Self.float32(k16), "cross_v": try Self.float32(v16)] }
        }
        let token = try MLMultiArray(shape: [NSNumber(value: b), 1], dataType: .int32), position = try MLMultiArray(shape: [1], dataType: .int32)
        for row in 0..<b { token[row] = NSNumber(value: c.bos) }
        var step: [Double] = []
        for t in 0..<(steps + 2) {
            position[0] = NSNumber(value: t)
            var values = cross; values["token"] = token; values["position"] = position
            let features = try MLDictionaryFeatureProvider(dictionary: values)
            let time = try ms { _ = try decoder.prediction(from: features, using: state) }
            if t >= 2 { step.append(time) }
        }
        return [("batch", Double(b)), ("encoder", median(encode)), ("encoder per crop", median(encode) / Double(b)), ("convert", convert),
                ("step", median(step)), ("step per crop", median(step) / Double(b))]
    }

    /// One crop (RGB, already on white with the 8 px margin) to the recogniser's preprocessed input.
    public func recogniserInput(crop: CGImage) -> [Float] {
        let c = configuration.recogniser
        return DevicePDFRaster.recogniserPixels(DevicePDFRaster.rgb(crop), size: c.imageSize, mean: c.mean, std: c.std)
    }

    // MARK: Arrays

    /// The array's values in row-major order. Core ML pads rows (the layout's [30704, 11] scores come with strides
    /// [32, 1]), so the storage is read through the strides, never as one flat run.
    static func floats(_ array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        let n = shape.reduce(1, *)
        var contiguous = true, expected = 1
        for d in stride(from: shape.count - 1, through: 0, by: -1) { if shape[d] > 1, strides[d] != expected { contiguous = false }; expected *= shape[d] }
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
        default:
            return (0..<n).map { array[$0].floatValue }
        }
        if contiguous { return raw }
        var out = [Float](repeating: 0, count: n)
        var index = [Int](repeating: 0, count: shape.count)
        for i in 0..<n {
            var offset = 0
            for d in 0..<shape.count { offset += index[d] * strides[d] }
            out[i] = raw[offset]
            var d = shape.count - 1
            while d >= 0 { index[d] += 1; if index[d] < shape[d] { break }; index[d] = 0; d -= 1 }
        }
        return out
    }

    /// The encoder returns float16; the decoder step takes float32 (as `coreml_latency.py` passes it).
    static func float32(_ array: MLMultiArray) throws -> MLMultiArray {
        let out = try MLMultiArray(shape: array.shape, dataType: .float32)
        let values = floats(array)
        values.withUnsafeBytes { src in out.withUnsafeMutableBytes { raw, _ in raw.copyMemory(from: src) } }
        return out
    }

    /// The greedy token and its softmax probability over the step's logits.
    static func argmaxProbability(_ logits: MLMultiArray) -> (Int, Double) {
        let values = floats(logits)
        return argmaxProbability(values, from: 0, count: values.count)
    }
    static func argmaxProbability(_ values: [Float], from start: Int, count: Int) -> (Int, Double) {
        values.withUnsafeBufferPointer { all in
            let row = all.baseAddress! + start
            var maximum: Float = 0; var index: vDSP_Length = 0
            vDSP_maxvi(row, 1, &maximum, &index, vDSP_Length(count))
            var sum = 0.0
            for i in 0..<count { sum += exp(Double(row[i] - maximum)) }
            return (Int(index), 1 / sum)
        }
    }
}
