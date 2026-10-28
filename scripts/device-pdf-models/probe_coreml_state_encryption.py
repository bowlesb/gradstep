"""Reproduce Core ML encryption support for a tiny FP16 cache, without private weights.

Generate matched stateful/stateless/explicit-cache MLPrograms, compile plaintext and
Apple-encrypted versions, and run a team-signed CPU/GPU matrix. All use iOS18,
Float32 input/output and Float16 arithmetic; explicit-cache adds a Float16 tensor
input. Only the stateful variant uses MLState. This records observed platform
behavior, not a promise about other OS versions or release configurations.

Requires the existing coremltools export environment, Xcode, an Apple-generated
private .mlmodelkey outside the checkout and a signing identity for its team.
Key contents are never opened by this script, copied, or written to evidence.
"""
import argparse
import hashlib
import json
import platform
from pathlib import Path
import re
import stat
import subprocess
import sys

SWIFT_PROBE = r'''
import CoreML
import Foundation
@available(macOS 15.0, *)
func predictions(_ model: MLModel, stateful: Bool, explicit: Bool = false) throws -> [Double] {
 let x = try MLMultiArray(shape:[1],dataType:.float32);x[0] = 1
 let cache = try MLMultiArray(shape:[1],dataType:.float16); cache[0] = 0
 let input = try MLDictionaryFeatureProvider(dictionary:explicit ? ["x":x,"cache":cache] : ["x":x])
 let state: MLState? = stateful ? model.makeState() : nil
 var values: [Double] = []
 for _ in 0..<2 {
  let result: MLFeatureProvider
  if let state { result = try model.prediction(from:input,using:state) } else { result = try model.prediction(from:input) }
  guard let y = result.featureValue(for:"y")?.multiArrayValue,y.count == 1 else { throw NSError(domain:"probe.output",code:1) }
  values.append(y[0].doubleValue); if explicit { cache[0] = y[0] }
 }
 return values
}
@main struct Probe {
 static func main() async {
  guard #available(macOS 15.0, *), (3...4).contains(CommandLine.arguments.count) else { exit(2) }
  let root = URL(fileURLWithPath:CommandLine.arguments[1]), out = URL(fileURLWithPath:CommandLine.arguments[2])
  let names = CommandLine.arguments.count == 4 ? ["explicit-cache"] : ["stateless","stateful"]
  var rows: [[String:Any]] = []
  func save() {try? JSONSerialization.data(withJSONObject:["passed":rows.count == names.count * 2 && rows.allSatisfy {$0["passed"] as? Bool == true},"cases":rows],options:[.prettyPrinted,.sortedKeys]).write(to:out,options:.atomic)}
  save()
  for name in names {
   for units in [MLComputeUnits.cpuOnly,.cpuAndGPU] {
    var row: [String:Any] = ["model":name,"compute_units":units == .cpuOnly ? "cpu" : "gpu","passed":false]
    do {
     let config = MLModelConfiguration();config.computeUnits = units
     let model = try await MLModel.load(contentsOf:root.appendingPathComponent(name+".mlmodelc"),configuration:config)
     row["loaded"] = true
     let values = try predictions(model,stateful:name == "stateful",explicit:name == "explicit-cache")
     row["outputs"] = values; row["passed"] = values == (name != "stateless" ? [1,2] : [2,2])
    } catch {
     let ns = error as NSError
     let detail = ns.localizedDescription.replacingOccurrences(of:#"https?://\S+|/\S+|[A-Za-z0-9+/=]{24,}"#,with:"[redacted]",options:.regularExpression)
     row["domain"] = String(ns.domain.prefix(80));row["code"] = ns.code;row["detail"] = String(detail.prefix(300))
    }
    rows.append(row);save()
   }
  }
  if !rows.allSatisfy({$0["passed"] as? Bool == true}) {exit(1)}
 }
}
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def tree_sha(directory):
    rows = []
    for path in sorted(directory.rglob('*')):
        if path.is_symlink():
            raise ValueError('model artifact symlinks are forbidden')
        if path.is_file():
            rows.append('/' + path.relative_to(directory).as_posix() + ':' + sha(path.read_bytes()))
    return sha('\n'.join(rows).encode())


def export_models(out):
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.mil import types

    @mb.program(input_specs=[mb.TensorSpec((1,), dtype=types.fp32),
                            mb.StateTensorSpec((1,), dtype=types.fp16)], opset_version=ct.target.iOS18)
    def stateful(x, cache):
        value = mb.add(x=mb.cast(x=x, dtype='fp16'), y=mb.read_state(input=cache))
        value = mb.coreml_update_state(state=cache, value=value)
        return mb.cast(x=value, dtype='fp32', name='y')

    @mb.program(input_specs=[mb.TensorSpec((1,), dtype=types.fp32)], opset_version=ct.target.iOS18)
    def stateless(x):
        return mb.add(x=x, y=1.0, name='y')

    @mb.program(input_specs=[mb.TensorSpec((1,), dtype=types.fp32),
                            mb.TensorSpec((1,), dtype=types.fp16)], opset_version=ct.target.iOS18)
    def explicit_cache(x, cache):
        return mb.cast(x=mb.add(x=mb.cast(x=x, dtype='fp16'), y=cache), dtype='fp32', name='y')

    for name, program in [('stateful', stateful), ('stateless', stateless), ('explicit-cache', explicit_cache)]:
        model = ct.convert(program, convert_to='mlprogram', minimum_deployment_target=ct.target.iOS18,
                           skip_model_load=True)
        spec = model.get_spec()
        if spec.specificationVersion != 9 or spec.description.functions:
            raise ValueError('unexpected synthetic model contract')
        model.save(str(out / (name + '.mlpackage')))
    return ct.__version__


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path, help='New evidence directory; never overwrite a prior run')
    parser.add_argument('--encryption-key', type=Path, help='Private Apple-generated .mlmodelkey, outside this checkout')
    parser.add_argument('--signing-identity', help='Existing Apple Development signing identity or certificate SHA')
    parser.add_argument('--team-id', default='3BJ33TT599')
    parser.add_argument('--export-only', action='store_true', help='Generate synthetic models without compiling or signing')
    args = parser.parse_args()
    if args.out.exists():
        raise FileExistsError(args.out)
    key = args.encryption_key.resolve() if args.encryption_key else None
    if not args.export_only:
        checkout = Path(__file__).resolve().parents[2]
        if not key or key.suffix != '.mlmodelkey' or not key.is_file() or checkout in key.parents:
            raise ValueError('an Apple model key outside this checkout is required')
        if key.stat().st_mode & (stat.S_IRWXG | stat.S_IRWXO):
            raise ValueError('model key permissions must be private to its owner')
        if not args.signing_identity or args.signing_identity == '-' or not re.fullmatch(r'[A-Z0-9]{10}', args.team_id):
            raise ValueError('a team signing identity and valid team ID are required')
    args.out.mkdir(parents=True)
    report = {'format': 'science-reader-coreml-state-encryption-probe-v1', 'probe_completed': False,
              'script_sha256': sha(Path(__file__).read_bytes()), 'platform': platform.platform(),
              'python_version': platform.python_version(), 'models': {}, 'matrix': {}}
    report_path = args.out / 'report.json'

    def save():
        report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')

    def run(command, name, allow_failure=False):
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        output = result.stdout.replace(str(key), '[private-key]') if key else result.stdout
        (args.out / (name + '.log')).write_text(output)
        if result.returncode and not allow_failure:
            raise RuntimeError(name + ' failed; inspect its local log')
        return result.returncode, output

    save()
    report['coremltools_version'] = export_models(args.out)
    names = ['stateful', 'stateless', 'explicit-cache']
    for name in names:
        report['models'][name] = {'source_sha256': tree_sha(args.out / (name + '.mlpackage'))}
    if args.export_only:
        report['export_only'] = True
        save()
        return
    report['compiler_version'] = run(['xcrun', 'coremlcompiler', 'version'], 'compiler-version')[1].strip()
    report['xcode_version'] = run(['xcodebuild', '-version'], 'xcode-version')[1].strip()
    for mode in ['plaintext', 'encrypted']:
        for name in names:
            command = ['xcrun', 'coremlcompiler', 'compile', str(args.out / (name + '.mlpackage')), str(args.out / mode)]
            if mode == 'encrypted':
                command.extend(['--encrypt', str(key)])
            run(command, mode + '-' + name + '-compile')
            report['models'][name][mode + '_compiled_sha256'] = tree_sha(args.out / mode / (name + '.mlmodelc'))
    source = args.out / 'probe.swift'
    source.write_text(SWIFT_PROBE)
    tool = args.out / 'probe'
    run(['xcrun', 'swiftc', '-parse-as-library', '-O', str(source), '-o', str(tool)], 'swift-build')
    run(['codesign', '--force', '--sign', args.signing_identity, '--options', 'runtime',
         '--identifier', 'com.sciencereader.coreml-state-encryption-probe', str(tool)], 'sign')
    run(['codesign', '--verify', '--strict', str(tool)], 'signature-verify')
    identity = run(['codesign', '--display', '--verbose=4', str(tool)], 'signature-metadata')[1]
    match = re.search(r'^TeamIdentifier=(\S+)$', identity, re.MULTILINE)
    if not match or match.group(1) != args.team_id:
        raise ValueError('probe signature does not match the requested Apple team')
    report.update(signature_team=args.team_id, signature_verified=True, tool_sha256=sha(tool.read_bytes()))
    for mode in ['plaintext', 'encrypted']:
        for explicit in [False, True]:
            label = mode + ('-explicit-cache' if explicit else '-state-pair')
            path = args.out / (label + '.json')
            command = [str(tool), str(args.out / mode), str(path)] + (['explicit'] if explicit else [])
            code, _ = run(command, label, allow_failure=True)
            evidence = json.loads(path.read_text())
            if code not in (0, 1) or len(evidence.get('cases', [])) != (2 if explicit else 4):
                raise RuntimeError('native probe did not complete its matrix')
            report['matrix'][label] = evidence
            save()
    matrix = report['matrix']
    encrypted = matrix['encrypted-state-pair']['cases']
    report['state_encryption_failure_isolated'] = (
        matrix['plaintext-state-pair']['passed'] and matrix['plaintext-explicit-cache']['passed'] and
        matrix['encrypted-explicit-cache']['passed'] and
        all(row['passed'] for row in encrypted if row['model'] == 'stateless') and
        all(not row['passed'] and row.get('domain') == 'com.apple.CoreML' and row.get('code') == 0 and
            '-14' in row.get('detail', '') for row in encrypted if row['model'] == 'stateful'))
    report['probe_completed'] = True
    save()
    print(json.dumps({'report': str(report_path), 'probe_completed': True,
                      'state_encryption_failure_isolated': report['state_encryption_failure_isolated']}))


if __name__ == '__main__':
    main()
