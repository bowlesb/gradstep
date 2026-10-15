import Foundation
import ScienceReaderCore
import CoreML

// The device route on this Mac, for evaluation (docs/architecture/DEVICE_PDF_ROUTE.md):
//   swift run -c release DevicePDFRouteTool <paper.pdf> <out-dir> --models <dir> --compiler <device-pdf-reader.js>
//       [--trace] [--title "…"] [--max-pages N] [--layout ne|gpu|cpu|all] [--recogniser gpu|cpu|all] [--tagger cpu|ne]
// Writes the bundle's members and manifest.json; with --trace also index.json (the Python route's shape, for the
// desktop's bundle_conformance.py) and conversion.json (summary and timings).
@main
struct Tool {
    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            let value = args[i + 1]; args.removeSubrange(i...(i + 1)); return value
        }
        func flag(_ name: String) -> Bool { if let i = args.firstIndex(of: name) { args.remove(at: i); return true }; return false }
        guard let models = option("--models"), let compiler = option("--compiler") else {
            FileHandle.standardError.write(Data("usage: DevicePDFRouteTool <pdf> <out> --models <dir> --compiler <js> [--trace]\n".utf8)); exit(2)
        }
        let detectionsPath = option("--detections"), concurrency = Int(option("--concurrency") ?? "2") ?? 2
        let title = option("--title"), maxPages = Int(option("--max-pages") ?? "0") ?? 0, trace = flag("--trace")
        func units(_ name: String?, _ fallback: MLUnits) -> MLUnits { name.flatMap(MLUnits.init(rawValue:)) ?? fallback }
        let layoutUnits = units(option("--layout"), .ne), recogniserUnits = units(option("--recogniser"), .gpu), taggerUnits = units(option("--tagger"), .cpu)
        guard args.count == 2 else { FileHandle.standardError.write(Data("need <pdf> <out>\n".utf8)); exit(2) }
        let pdf = URL(fileURLWithPath: args[0]), out = URL(fileURLWithPath: args[1])
        guard #available(macOS 15.0, *) else { FileHandle.standardError.write(Data("needs macOS 15\n".utf8)); exit(2) }
        let loaded = try DevicePDFModels(directory: URL(fileURLWithPath: models), layoutUnits: layoutUnits.compute,
                                         taggerUnits: taggerUnits.compute, recogniserUnits: recogniserUnits.compute)
        let route = DevicePDFRoute(models: loaded, compilerSource: try String(contentsOfFile: compiler, encoding: .utf8))
        let data = try Data(contentsOf: pdf)
        var lastFormulaReport = 0
        // --detections <file.jsonl>: each page's decoded layout detections (evaluation).
        final class Lines: @unchecked Sendable { var text = "" }
        let lines = Lines()
        var observe: (@Sendable (Int, [DevicePDFModels.Detection], Double) -> Void)? = nil
        if detectionsPath != nil {
            observe = { page, found, scale in
                var rows: [[String: Any]] = []
                for d in found { rows.append(["cls": d.cls, "score": d.score, "box": d.box]) }
                let object: [String: Any] = ["page": page, "scale": scale, "detections": rows]
                if let data = try? JSONSerialization.data(withJSONObject: object) { lines.text += String(decoding: data, as: UTF8.self) + "\n" }
            }
        }
        let output = try route.convert(pdf: data, name: pdf.lastPathComponent, options: { var o = DevicePDFRoute.Options(title: title, trace: trace, maxPages: maxPages, observeDetections: observe); o.recogniserConcurrency = concurrency; return o }(), progress: { stage in
            switch stage {
            case .layout(let page, let of): if page == of || page % 10 == 0 { FileHandle.standardError.write(Data("layout \(page)/\(of)\n".utf8)) }
            case .reading(let done, let of): FileHandle.standardError.write(Data("read \(done)/\(of)\n".utf8)); lastFormulaReport = 0
            case .formulas(let done, let of):
                if done - lastFormulaReport >= 50 { lastFormulaReport = done; FileHandle.standardError.write(Data("  formulas \(done)/\(of)\n".utf8)) }
            }
        })
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try output.manifest.write(to: out.appendingPathComponent("manifest.json"))
        for (path, bytes) in output.members {
            let url = out.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        try output.summary.write(to: out.appendingPathComponent("conversion.json"))
        if let detectionsPath { try lines.text.write(toFile: detectionsPath, atomically: true, encoding: .utf8) }
        if let trace = output.trace { try trace.write(to: out.appendingPathComponent("index.json")) }
        // The app's own verification of the bundle, as the reader would admit it.
        do {
            _ = try VerifiedReaderBundle.verify(manifest: output.manifest, expectedSHA256: output.manifestSHA256, members: output.members)
            print("verified \(output.manifestSHA256)")
        } catch { print("NOT VERIFIED: \(error)") }
        print(String(decoding: output.summary, as: UTF8.self))
    }
}

enum MLUnits: String {
    case ne, gpu, cpu, all
    var compute: MLComputeUnits {
        switch self { case .ne: return .cpuAndNeuralEngine; case .gpu: return .cpuAndGPU; case .cpu: return .cpuOnly; case .all: return .all }
    }
}
