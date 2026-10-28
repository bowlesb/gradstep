#!/usr/bin/env python3
"""Research-only matched native gate. Compile/encrypt/team-sign the Swift probe first.

Acquires the shared Mac Core ML lock; refuses occupied locks or prior output dirs.
Stops at >=2x fresh one-lane baseline peak RSS. Timing is attempted only after
exact token/acceptance parity and memory pass, with predeclared quiet-load limits.
No model/app/runtime/pack changes or phone/Simulator work are performed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def manifest(path):
    return {str(f.relative_to(path)): sha(f) for f in sorted(path.rglob('*')) if f.is_file()}


def load_snapshot():
    result = subprocess.run(['ps', '-axo', 'pid=,pcpu=,comm='], capture_output=True, text=True, check=True)
    rows = []
    for line in result.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3:
            rows.append({'pid': int(parts[0]), 'cpu_percent': float(parts[1]), 'name': Path(parts[2]).name})
    rows.sort(key=lambda r: r['cpu_percent'], reverse=True)
    return {'load_average': os.getloadavg(), 'other_cpu_percent': sum(r['cpu_percent'] for r in rows), 'top_processes': rows[:10]}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--tool', type=Path, required=True)
    p.add_argument('--baseline-model', type=Path, required=True)
    p.add_argument('--candidate-model', type=Path, required=True)
    p.add_argument('--compile-report', type=Path, required=True)
    p.add_argument('--samples', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--lock-dir', type=Path, required=True)
    p.add_argument('--quiet-max-load1', type=float, default=5)
    p.add_argument('--quiet-max-total-cpu', type=float, default=75)
    p.add_argument('--quiet-max-process-cpu', type=float, default=20)
    p.add_argument('--timeout', type=float, default=600)
    p.add_argument('--team-id', default='3BJ33TT599')
    args = p.parse_args()
    if platform.system() != 'Darwin':
        raise RuntimeError('native qualification requires macOS')
    if args.out.exists():
        raise FileExistsError(args.out)
    compiled = json.loads(args.compile_report.read_text())
    if compiled.get('encrypted') is not True:
        raise ValueError('requires the exact encrypted compile receipt')
    for name in ['encoder', 'step']:
        if manifest(args.candidate_model / (name + '.mlmodelc')) != compiled['models'][name]['file_sha256']:
            raise ValueError('compiled candidate identity mismatch')
    subprocess.run(['codesign', '--verify', '--strict', str(args.tool)], check=True, capture_output=True)
    signature = subprocess.run(['codesign', '--display', '--verbose=4', str(args.tool)], check=True, capture_output=True, text=True)
    if not re.search(r'^TeamIdentifier=' + re.escape(args.team_id) + r'$', signature.stderr, re.MULTILINE):
        raise ValueError('probe signing team mismatch')
    args.lock_dir.mkdir()  # Atomic; never disturb another user's/agent's lock.
    owner = {'owner': 'qualify_texteller_lean_native', 'pid': os.getpid(), 'created_unix': time.time()}
    try:
        (args.lock_dir / 'owner.json').write_text(json.dumps(owner, indent=2) + '\n')
        args.out.mkdir(parents=True)
        report = {'passed': False, 'memory_parity_passed': False, 'timing_completed': False,
                  'scope': 'research-only Mac one-lane fixed20 whole-batch gate; no shipping qualification',
                  'signature_team': args.team_id, 'signature_verified': True, 'platform': platform.platform(), 'logical_cpus': os.cpu_count(), 'runs': [],
                  'plan': {'batch': 8, 'lanes': 1, 'samples': 20, 'max_length': 512, 'compute_units': 'cpuAndGPU',
                           'exact_tokens': True, 'finite_probabilities': True, 'acceptance_thresholds': {'inline_minimum': 0.8, 'display_second_minimum': 0.95},
                           'memory_ratio_limit_exclusive': 2, 'timed_order': ['baseline', 'lean', 'lean', 'baseline', 'baseline', 'lean'],
                           'quiet_max_load1': args.quiet_max_load1, 'quiet_max_total_cpu': args.quiet_max_total_cpu,
                           'quiet_max_process_cpu': args.quiet_max_process_cpu, 'timeout_seconds': args.timeout},
                  'source': {'runner_sha256': sha(Path(__file__)), 'swift_sha256': sha(Path(__file__).with_name('probe_texteller_lean_native.swift')),
                             'tool_sha256': sha(args.tool), 'baseline_files': manifest(args.baseline_model),
                             'compile_report_sha256': sha(args.compile_report), 'sample_export_sha256': sha(args.samples/'export.json')}}
        report_path = args.out / 'qualification.json'

        def save():
            temporary = report_path.with_suffix('.tmp')
            temporary.write_text(json.dumps(report, indent=2) + '\n')
            temporary.replace(report_path)

        def run(mode, phase, index, limit=0):
            name = f'{index:02}-{mode}-{phase}'
            path = args.out / (name + '.json')
            command = [str(args.tool), '--mode', mode, '--model', str(args.baseline_model if mode == 'baseline' else args.candidate_model),
                       '--samples', str(args.samples), '--out', str(path), '--phase', phase, '--rss-limit', str(limit)]
            if mode == 'lean' or phase == 'trial':
                command += ['--baseline-report', str(args.out/'00-baseline-gate.json')]
            row = {'name': name, 'mode': mode, 'phase': phase, 'before': load_snapshot(), 'observed_rss_bytes_lower_bound': 0}
            report['runs'].append(row); save()
            started = time.monotonic()
            with (args.out/(name+'.log')).open('w') as log:
                child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
                try:
                    while child.poll() is None:
                        observed = subprocess.run(['ps','-o','rss=','-p',str(child.pid)],capture_output=True,text=True)
                        if observed.stdout.strip():
                            rss = int(observed.stdout.strip()) * 1024
                            row['observed_rss_bytes_lower_bound'] = max(row['observed_rss_bytes_lower_bound'], rss)
                            if limit and rss >= limit:
                                row['stopped_reason'] = 'memory_gate'; child.kill(); break
                        if time.monotonic()-started >= args.timeout:
                            row['stopped_reason'] = 'timeout'; child.kill(); break
                        time.sleep(0.25)
                    row['exit_code'] = child.wait()
                finally:
                    if child.poll() is None:
                        child.kill(); child.wait()
            row['after'] = load_snapshot()
            if path.is_file():
                result = json.loads(path.read_text()); row['result'] = result; row['report_sha256'] = sha(path)
                row['observed_rss_bytes_lower_bound'] = max(row['observed_rss_bytes_lower_bound'], result.get('peak_rss_bytes',0))
            else:
                result = {}
            save()
            if row.get('stopped_reason') or row['exit_code'] or result.get('passed') is not True:
                reason = row.get('stopped_reason', result.get('error_domain', 'native_probe_failed'))
                raise RuntimeError(reason)
            if limit and row['observed_rss_bytes_lower_bound'] >= limit:
                raise RuntimeError('memory_gate')
            return result

        save()
        try:
            baseline = run('baseline', 'gate', 0)
            limit = baseline['peak_rss_bytes'] * 2
            report['baseline_peak_rss_bytes'] = baseline['peak_rss_bytes']; report['candidate_rss_limit_exclusive_bytes'] = limit; save()
            candidate = run('lean', 'gate', 1, limit)
            report['memory_parity_passed'] = True
            report['candidate_peak_rss_bytes'] = candidate['peak_rss_bytes']
            report['candidate_memory_ratio'] = candidate['peak_rss_bytes'] / baseline['peak_rss_bytes']
            report['max_probability_delta_vs_baseline'] = candidate['max_probability_delta_vs_baseline']; save()
            for i, mode in enumerate(report['plan']['timed_order'], 2):
                snapshot = load_snapshot()
                if (snapshot['load_average'][0] > args.quiet_max_load1 or snapshot['other_cpu_percent'] > args.quiet_max_total_cpu
                        or snapshot['top_processes'][0]['cpu_percent'] > args.quiet_max_process_cpu):
                    report['quiet_gate_snapshot'] = snapshot
                    raise RuntimeError('quiet_mac_gate_not_met; no timing comparison')
                run(mode, 'trial', i, limit if mode == 'lean' else 0)
            times = {mode: [r['result']['decode_seconds'] for r in report['runs'] if r['mode'] == mode and r['phase'] == 'trial'] for mode in ['baseline', 'lean']}
            report['timing_completed'] = True; report['decode_seconds'] = times
            report['median_decode_seconds'] = {mode: sorted(values)[1] for mode, values in times.items()}
            report['median_time_ratio'] = report['median_decode_seconds']['lean'] / report['median_decode_seconds']['baseline']
            report['passed'] = True; save()
        except Exception as error:
            report['error'] = str(error); save(); raise
    finally:
        owned = args.lock_dir/'owner.json'
        if owned.is_file() and json.loads(owned.read_text()) == owner:
            owned.unlink(); args.lock_dir.rmdir()


if __name__ == '__main__':
    main()
