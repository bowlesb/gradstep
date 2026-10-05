#!/usr/bin/env node
// Records a test session in the Simulator end to end, to exercise the review
// pipeline without a phone: runs SessionCaptureTests while the Simulator's
// screen is recorded, takes the session the app packaged, uses the Simulator
// recording as its video when ReplayKit produced none, and runs the review.
// Usage: node scripts/simulator-session.mjs [--device=SIM-ID]
import { execFileSync, spawn } from 'node:child_process';
import { copyFileSync, existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { review, unpack } from './session-review.mjs';

const root = resolve(new URL('..', import.meta.url).pathname);
const args = Object.fromEntries(process.argv.slice(2).map(a => { const [k, v] = a.replace(/^--/, '').split('='); return [k, v ?? 'true']; }));
const device = args.device ?? 'B6CD74CE-CB0C-417E-9E9B-F68175B5094D';
const video = join(root, `.artifacts/simulator-session-${Date.now()}.mp4`);

execFileSync('xcodegen', ['generate'], { cwd: join(root, 'apps/apple'), stdio: 'ignore' });
const recorder = spawn('xcrun', ['simctl', 'io', device, 'recordVideo', '--codec=h264', '--force', video], { stdio: 'ignore' });
await new Promise(r => setTimeout(r, 3000));
let status = 0;
try {
  execFileSync('xcodebuild', ['-project', 'ScienceReader.xcodeproj', '-scheme', 'ScienceReader', '-configuration', 'Debug',
    '-destination', `platform=iOS Simulator,id=${device}`, '-derivedDataPath', '../../.artifacts/lead-derived',
    '-only-testing:ScienceReaderUITests/SessionCaptureTests', 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'test'],
    { cwd: join(root, 'apps/apple'), stdio: ['ignore', 'ignore', 'inherit'] });
} catch { status = 1; }
recorder.kill('SIGINT');
await new Promise(r => recorder.on('close', r));
if (status) { console.error('SessionCaptureTests failed'); process.exit(1); }

const container = execFileSync('xcrun', ['simctl', 'get_app_container', device, 'com.sciencereader.ios', 'data']).toString().trim();
const dir = join(container, 'Library/Application Support/TestSessions');
const zip = readdirSync(dir).filter(n => n.endsWith('.zip')).map(n => join(dir, n)).sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0];
if (!zip) { console.error('The app produced no session'); process.exit(1); }
const folder = unpack(zip);
if (!existsSync(join(folder, 'screen.mp4'))) { copyFileSync(video, join(folder, 'screen.mp4')); console.log('Using the Simulator recording as the session video'); }
console.log(review(folder));
// The journey contains a known error message and a repeated tap: the pipeline must find both, in sync.
const packet = JSON.parse(readFileSync(join(folder, 'review/review.json'), 'utf8'));
const kinds = new Set(packet.signals.map(s => s.kind));
const problems = [!packet.syncFound && 'sync marker not found', !kinds.has('message_shown') && 'error message not detected',
  !kinds.has('repeated_taps') && 'repeated taps not detected', packet.frames.length < 8 && `only ${packet.frames.length} frames`].filter(Boolean);
if (problems.length) { console.error('FAIL', problems.join('; ')); process.exit(1); }
console.log(`PASS simulator session: ${packet.signals.length} signals, ${packet.frames.length} frames, offset ${packet.offset.toFixed(2)} s`);
