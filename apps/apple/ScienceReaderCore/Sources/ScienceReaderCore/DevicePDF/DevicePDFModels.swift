import Accelerate
import CoreML
import Foundation

/// The three exported models of the device route (docs/architecture/DEVICE_PDF_ROUTE.md) and their contracts, from
/// `device-models.json` beside the compiled models (`scripts/device-models.mjs` writes it from the exports).
public struct DevicePDFModelConfiguration: Decodable, Sendable {
    public struct Model: Decodable, Sendable { public let id: String; public let file: String; public let weightsSHA256: String
        enum CodingKeys: String, CodingKey { case id, file; case weightsSHA256 = "weights_sha256" } }
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
        let c = configuration.recogniser
        return try recognise(pixels: try DevicePDFRaster.recogniserInput(crop, size: c.imageSize, mean: c.mean, std: c.std))
    }

    /// The preprocessed input ([1, 1, 448, 448] float32) to LaTeX; the export's samples are already in this form.
    public func recognise(pixels: MLMultiArray) throws -> Recognition {
        let c = configuration.recogniser
        guard let encoder, let decoder else { throw DevicePDFModelError.unusable("recogniser: \(recogniserIssue ?? "not loaded")") }
        let input = try MLDictionaryFeatureProvider(dictionary: ["pixel_values": pixels])
        let encoded = try encoder.prediction(from: input)
        guard let k16 = encoded.featureValue(for: "cross_k")?.multiArrayValue, let v16 = encoded.featureValue(for: "cross_v")?.multiArrayValue else {
            throw DevicePDFModelError.unusable("encoder outputs")
        }
        let crossK = try Self.float32(k16), crossV = try Self.float32(v16)
        let state = decoder.makeState()
        let token = try MLMultiArray(shape: [1, 1], dataType: .int32), position = try MLMultiArray(shape: [1], dataType: .int32)
        var ids = [c.bos], probabilities: [Double] = []
        for step in 0..<(c.maxLength - 1) {
            token[0] = NSNumber(value: ids[ids.count - 1]); position[0] = NSNumber(value: step)
            let features = try MLDictionaryFeatureProvider(dictionary: ["token": token, "position": position, "cross_k": crossK, "cross_v": crossV])
            guard let logits = try decoder.prediction(from: features, using: state).featureValue(for: "logits")?.multiArrayValue else {
                throw DevicePDFModelError.unusable("decoder output")
            }
            let (best, probability) = Self.argmaxProbability(logits)
            ids.append(best); probabilities.append(probability)
            if best == c.eos { break }
        }
        let generated = Array(ids.dropFirst())
        return Recognition(latex: tokenizer.decode(generated), probabilities: probabilities, tokens: generated)
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
        var maximum: Float = 0; var index: vDSP_Length = 0
        vDSP_maxvi(values, 1, &maximum, &index, vDSP_Length(values.count))
        var sum = 0.0
        for v in values { sum += exp(Double(v - maximum)) }
        return (Int(index), 1 / sum)
    }
}
