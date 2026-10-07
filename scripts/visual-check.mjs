#!/usr/bin/env node
// Visual checks (docs/VISUAL_CHECK.md): screenshots of named scenarios across
// devices and appearances, before/after comparison, contact sheets.
//
//   node scripts/visual-check.mjs capture --label=before [--scenarios=chat-keyboard,store|all]
//        [--devices=iphone,ipad,small,max,mini,ipad13] [--variants=light,dark,xxl,xl] [--landscape]
//        [--udids=iphone:<UDID>,ipad:<UDID>] [--derived=/private/tmp/<session>/derived]
//   --udids runs a device name on your own Simulator instead of the shared one (parallel sessions must not share
//   Simulators); --derived keeps the build products apart too.
//   node scripts/visual-check.mjs compare --before=before --after=after
//   node scripts/visual-check.mjs sheet --label=after
//
// Screenshots: .artifacts/visual/<label>/<device>-<variant>[-landscape]/<scenario>.png
// The Simulator status bar is pinned (9:41, full battery) so clocks don't show as changes.
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';

const root = resolve(new URL('..', import.meta.url).pathname);
const [command = 'capture', ...rest] = process.argv.slice(2);
const args = Object.fromEntries(rest.map(a => {
  const option = a.replace(/^--/, ''), at = option.indexOf('=');
  return at < 0 ? [option, 'true'] : [option.slice(0, at), option.slice(at + 1)];
}));
const visual = join(root, '.artifacts/visual');
const DEVICES = { iphone: 'B6CD74CE-CB0C-417E-9E9B-F68175B5094D', small: '20F95B85-3BCE-4930-933C-8DC4E98E6EB1',
  max: '621A934F-8F1D-4410-953A-6D3ECD951CA0', ipad: 'F1371651-051A-4368-8FE7-6878F74781F2', mini: '1D17687F-2188-4025-8570-5A9C905C2D04',
  ipad13: 'B8DEE99E-FCD3-472F-BAFC-E01E5B952A36' };
for (const pair of (args.udids ?? '').split(',').filter(Boolean)) {
  const [name, udid] = pair.split(':');
  if (!DEVICES[name] || !/^[0-9A-F-]{36}$/i.test(udid ?? '')) throw new Error(`--udids expects name:UDID pairs, got ${pair}`);
  DEVICES[name] = udid;
}
// xxl: the largest size below the accessibility sizes (layouts that switch form at accessibility sizes keep theirs).
const VARIANTS = { light: ['light', 'large'], dark: ['dark', 'large'], xxl: ['light', 'extra-extra-extra-large'],
  xl: ['light', 'accessibility-extra-large'] };
const run = (cmd, a, options = {}) => execFileSync(cmd, a, { stdio: ['ignore', 'pipe', 'pipe'], ...options }).toString();
const quiet = (cmd, a) => { try { run(cmd, a); } catch { /* best effort */ } };
const tool = () => {
  execFileSync('swift', ['build', '-c', 'release', '--package-path', join(root, 'tools/visual-check')], { stdio: ['ignore', 'ignore', 'inherit'] });
  return join(root, 'tools/visual-check/.build/release/visual-check');
};

if (command === 'capture') {
  const label = args.label ?? 'current', scenarios = args.scenarios ?? 'all';
  const devices = (args.devices ?? 'iphone,ipad').split(','), variants = (args.variants ?? 'light,dark').split(',');
  const derived = args.derived ? resolve(args.derived) : join(root, '.artifacts/visual-derived');
  if (args['skip-build']) console.log(`Reusing the build in ${derived}`); // --skip-build: a later variant of the same build
  else {
    execFileSync('xcodegen', ['generate'], { cwd: join(root, 'apps/apple'), stdio: 'ignore' });
    console.log('Building for testing…');
    run('xcodebuild', ['-project', 'ScienceReader.xcodeproj', '-scheme', 'ScienceReader', '-configuration', 'Debug',
      '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', derived, 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'build-for-testing'],
      { cwd: join(root, 'apps/apple'), maxBuffer: 1 << 28 });
  }
  for (const device of devices) {
    const id = DEVICES[device]; if (!id) throw new Error(`unknown device ${device}`);
    quiet('xcrun', ['simctl', 'boot', id]);
    quiet('xcrun', ['simctl', 'status_bar', id, 'override', '--time', '9:41', '--batteryState', 'charged', '--batteryLevel', '100',
      '--cellularMode', 'active', '--cellularBars', '4', '--wifiBars', '3']);
    for (const variant of variants) {
      const [appearance, size] = VARIANTS[variant] ?? []; if (!appearance) throw new Error(`unknown variant ${variant}`);
      quiet('xcrun', ['simctl', 'ui', id, 'appearance', appearance]);
      quiet('xcrun', ['simctl', 'ui', id, 'content_size', size]);
      const folder = join(visual, label, `${device}-${variant}${args.landscape ? '-landscape' : ''}`);
      const result = join(root, `.artifacts/visual-${label}-${device}-${variant}-${Date.now()}.xcresult`);
      process.stdout.write(`${device} ${variant}: `);
      try {
        run('xcodebuild', ['-project', 'ScienceReader.xcodeproj', '-scheme', 'ScienceReader', '-configuration', 'Debug',
          '-destination', `platform=iOS Simulator,id=${id}`, '-derivedDataPath', derived, '-resultBundlePath', result,
          '-only-testing:ScienceReaderUITests/VisualScenarioTests/testCaptureScenarios', 'test-without-building'],
          { cwd: join(root, 'apps/apple'), maxBuffer: 1 << 28, env: { ...process.env, TEST_RUNNER_SCIENCE_READER_VISUAL_SCENARIOS: scenarios,
            ...(args.landscape ? { TEST_RUNNER_SCIENCE_READER_VISUAL_ORIENTATION: 'landscape' } : {}) } });
      } catch { process.stdout.write('(some steps failed; see the result bundle) '); }
      const exported = `${result}-attachments`;
      quiet('xcrun', ['xcresulttool', 'export', 'attachments', '--path', result, '--output-path', exported]);
      rmSync(folder, { recursive: true, force: true }); mkdirSync(folder, { recursive: true });
      let saved = 0;
      if (existsSync(join(exported, 'manifest.json'))) {
        for (const test of JSON.parse(readFileSync(join(exported, 'manifest.json'), 'utf8'))) for (const a of test.attachments) {
          const name = /^visual__([a-z0-9-]+)_\d+_/.exec(a.suggestedHumanReadableName ?? '')?.[1];
          if (name) { copyFileSync(join(exported, a.exportedFileName), join(folder, `${name}.png`)); saved += 1; }
        }
      }
      console.log(`${saved} screens → ${folder.replace(root + '/', '')}`);
    }
    quiet('xcrun', ['simctl', 'ui', id, 'appearance', 'light']);
    quiet('xcrun', ['simctl', 'ui', id, 'content_size', 'large']);
    quiet('xcrun', ['simctl', 'status_bar', id, 'clear']);
  }
  execFileSync(tool(), ['sheet', join(visual, label), join(visual, `${label}-sheet.png`)], { stdio: 'inherit' });
} else if (command === 'compare') {
  const before = join(visual, args.before ?? 'before'), after = join(visual, args.after ?? 'after');
  execFileSync(tool(), ['compare', before, after, join(visual, `compare-${args.before ?? 'before'}-${args.after ?? 'after'}`)], { stdio: 'inherit' });
} else if (command === 'sheet') {
  const label = args.label ?? 'current';
  execFileSync(tool(), ['sheet', join(visual, label), join(visual, `${label}-sheet.png`)], { stdio: 'inherit' });
} else {
  console.error('commands: capture | compare | sheet'); process.exit(2);
}
