#!/usr/bin/env node
// Visual checks (docs/VISUAL_CHECK.md): screenshots of named scenarios across
// devices and appearances, before/after comparison, contact sheets.
//
//   node scripts/visual-check.mjs capture --label=before [--scenarios=chat-keyboard,store|all]
//        [--devices=iphone,ipad,small,max,mini,ipad13,mac] [--variants=light,dark,xxl,xl,rt] [--landscape]
//   mac: the Mac Catalyst app on this Mac (light and dark only; the window opens at --window=1280x820), built into
//   <derived>-mac and launched with fixture arguments; it renders its own window (VisualCapture.swift), so no UI
//   automation permission is needed. Mac scenarios are the launch-argument ones in MAC_SCENARIOS below.
//        [--udids=iphone:<UDID>,ipad:<UDID>] [--derived=/private/tmp/<session>/derived] [--skip-build]
//   --udids runs a device name on your own Simulator instead of the shared one (parallel sessions must not share
//   Simulators); --derived keeps the build products apart too; --skip-build reuses that folder's last build.
//   node scripts/visual-check.mjs compare --before=before --after=after
//   node scripts/visual-check.mjs sheet --label=after
//
// Screenshots: .artifacts/visual/<label>/<device>-<variant>[-landscape]/<scenario>.png
// The Simulator status bar is pinned (9:41, full battery) so clocks don't show as changes.
import { execFileSync, spawnSync } from 'node:child_process';
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
// rt: Reduce Transparency (light), set through the Simulator's accessibility preferences.
const VARIANTS = { light: ['light', 'large'], dark: ['dark', 'large'], xxl: ['light', 'extra-extra-extra-large'],
  xl: ['light', 'accessibility-extra-large'], rt: ['light', 'large', 'reduce-transparency'] };
const setReduceTransparency = (id, on) => quiet('xcrun', ['simctl', 'spawn', id, 'defaults', 'write', 'com.apple.Accessibility',
  'EnhancedBackgroundContrastEnabled', '-bool', on ? 'true' : 'false']);

// Mac scenarios: the UI-test catalogue's states that launch arguments alone can set up (VisualCapture.swift stages
// the few steps a test would tap). Names match the iOS scenarios so sheets line the platforms up.
const chatFixture = ['--chat-fixture', '--chat-fixture-consented', '--reset-draft-fixture'];
const metadataFixture = ['--workflow-fixture', '--library-metadata-fixture'];
const feedTableFixture = [...metadataFixture, '--feed-fixture', '--feed-layout=table'];
const mathpixFixture = ['--offline-reader-fixture', '--reset-offline-reader-fixture', '--mathpix-reader-fixture'];
const historyFixture = [...chatFixture, '--chat-history-fixture'];
const MAC_SCENARIOS = {
  'library': { args: ['--workflow-fixture'] },
  'library-table': { args: [...metadataFixture, '--library-layout=table'] },
  'library-metadata-list': { args: metadataFixture },
  'library-filter-failed': { args: [...metadataFixture, '--library-layout=table', '--library-filter=failed'] },
  'library-filter-tag': { args: [...metadataFixture, '--library-layout=table', '--library-tag=Language'] },
  'library-slow-import': { args: [...metadataFixture, '--slow-import-fixture'] },
  'library-import-progress': { args: [...metadataFixture, '--import-progress-fixture'] },
  'library-add': { args: ['--workflow-fixture', '--visual-show-import'] },
  'feed': { args: ['--workflow-fixture', '--start-tab=feed'] },
  'feed-results': { args: ['--workflow-fixture', '--library-metadata-fixture', '--feed-fixture', '--start-tab=feed'] },
  'feed-table': { args: [...feedTableFixture, '--start-tab=feed'] },
  'paper': { args: ['--workflow-fixture', '--start-tab=paper'], delay: 8 },
  'browse': { args: ['--workflow-fixture', '--wide-mode=browse'], delay: 8 },
  'paper-chat-hidden': { args: ['--workflow-fixture', '--start-tab=paper', '--reader-chat-hidden'], delay: 8 },
  'paper-top': { args: [...mathpixFixture, '--visual-open-paper'], delay: 10 },
  'paper-tags-edit': { args: [...mathpixFixture, '--visual-open-paper', '--visual-edit-tags'], delay: 10 },
  'chat-conversation': { args: ['--workflow-fixture', '--start-tab=chat'] },
  'chat-answer': { args: [...chatFixture, '--chat-fixture-mode=answer', '--visual-ask=Why scale by the square root of d_k?'], delay: 8 },
  'chat-sources': { args: [...chatFixture, '--chat-fixture-mode=sources', '--visual-ask=What do recent sources say?'], delay: 8 },
  'chat-credits': { args: [...chatFixture, '--chat-fixture-mode=insufficient_credits', '--visual-ask=Summarize the method'], delay: 8 },
  'chat-diagram': { args: [...chatFixture, '--chat-fixture-mode=diagram', '--visual-ask=Draw the attention computation'], delay: 10 },
  'chat-history-table': { args: [...historyFixture, '--visual-show-all-chats'] },
  'store': { args: [...chatFixture, '--visual-show-store'] },
  'settings': { args: ['--workflow-fixture', '--start-tab=settings'] },
  'settings-account': { args: [...chatFixture, '--start-tab=settings'] },
  'signin': { args: ['--authentication-fixture', '--reset-authentication-fixture', '--visual-show-signin'] },
};
const run = (cmd, a, options = {}) => execFileSync(cmd, a, { stdio: ['ignore', 'pipe', 'pipe'], ...options }).toString();
const quiet = (cmd, a) => { try { run(cmd, a); } catch { /* best effort */ } };
/** Copies the scenario screenshots out of a result bundle into the capture folder; returns how many. */
const saveAttachments = (result, folder) => {
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
  return saved;
};
const tool = () => {
  execFileSync('swift', ['build', '-c', 'release', '--package-path', join(root, 'tools/visual-check')], { stdio: ['ignore', 'ignore', 'inherit'] });
  return join(root, 'tools/visual-check/.build/release/visual-check');
};

if (command === 'capture') {
  const label = args.label ?? 'current', scenarios = args.scenarios ?? 'all';
  const devices = (args.devices ?? 'iphone,ipad').split(','), variants = (args.variants ?? 'light,dark').split(',');
  const derived = args.derived ? resolve(args.derived) : join(root, '.artifacts/visual-derived');
  const simulators = devices.filter(d => d !== 'mac'), mac = devices.includes('mac');
  const macDerived = `${derived}-mac`, macDestination = 'platform=macOS,variant=Mac Catalyst';
  if (args['skip-build']) console.log(`Reusing the build in ${derived}`); // --skip-build: a later variant of the same build
  else {
    execFileSync('xcodegen', ['generate'], { cwd: join(root, 'apps/apple'), stdio: 'ignore' });
    if (simulators.length) {
      console.log('Building for testing…');
      run('xcodebuild', ['-project', 'ScienceReader.xcodeproj', '-scheme', 'ScienceReader', '-configuration', 'Debug',
        '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', derived, 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'build-for-testing'],
        { cwd: join(root, 'apps/apple'), maxBuffer: 1 << 28 });
    }
    if (mac) {
      console.log('Building the Mac app for testing…');
      run('xcodebuild', ['-project', 'ScienceReader.xcodeproj', '-scheme', 'ScienceReader', '-configuration', 'Debug',
        '-destination', macDestination, '-derivedDataPath', macDerived, 'build'], { cwd: join(root, 'apps/apple'), maxBuffer: 1 << 28 });
    }
  }
  if (mac) {
    // The Mac app launched directly with fixture arguments renders its own window (VisualCapture.swift): no UI
    // automation, so no automation permission. Scenario state comes from launch arguments alone.
    const app = join(macDerived, 'Build/Products/Debug-maccatalyst/Gradstep.app/Contents/MacOS/Gradstep');
    if (!existsSync(app)) throw new Error(`no Mac build at ${app}`);
    const container = join(process.env.HOME ?? '', 'Library/Containers/com.sciencereader.ios/Data/tmp/visual-capture');
    const wanted = scenarios === 'all' ? Object.keys(MAC_SCENARIOS) : scenarios.split(',');
    for (const variant of variants) {
      if (!['light', 'dark'].includes(variant)) { console.log(`mac ${variant}: skipped (only light and dark on the Mac)`); continue; }
      const folder = join(visual, label, `mac-${variant}`);
      rmSync(folder, { recursive: true, force: true }); mkdirSync(folder, { recursive: true });
      process.stdout.write(`mac ${variant}: `);
      let saved = 0; const failed = [];
      for (const name of wanted) {
        const scenario = MAC_SCENARIOS[name];
        if (!scenario) { failed.push(`${name} (not a Mac scenario)`); continue; }
        rmSync(container, { recursive: true, force: true });
        const result = spawnSync(app, [...scenario.args, `--appearance=${variant}`, `--window-size=${args.window ?? '1280x820'}`,
          `--visual-capture=${name}`, `--visual-capture-delay=${scenario.delay ?? 5}`], { timeout: 120_000, stdio: 'ignore' });
        const png = join(container, `${name}.png`);
        if (result.status === 0 && existsSync(png)) { copyFileSync(png, join(folder, `${name}.png`)); saved += 1; }
        else failed.push(`${name} (exit ${result.status ?? result.signal})`);
      }
      console.log(`${saved} screens → ${folder.replace(root + '/', '')}${failed.length ? `; failed: ${failed.join(', ')}` : ''}`);
    }
  }
  for (const device of simulators) {
    const id = DEVICES[device]; if (!id) throw new Error(`unknown device ${device}`);
    quiet('xcrun', ['simctl', 'boot', id]);
    quiet('xcrun', ['simctl', 'status_bar', id, 'override', '--time', '9:41', '--batteryState', 'charged', '--batteryLevel', '100',
      '--cellularMode', 'active', '--cellularBars', '4', '--wifiBars', '3']);
    for (const variant of variants) {
      const [appearance, size, setting] = VARIANTS[variant] ?? []; if (!appearance) throw new Error(`unknown variant ${variant}`);
      quiet('xcrun', ['simctl', 'ui', id, 'appearance', appearance]);
      quiet('xcrun', ['simctl', 'ui', id, 'content_size', size]);
      setReduceTransparency(id, setting === 'reduce-transparency');
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
      console.log(`${saveAttachments(result, folder)} screens → ${folder.replace(root + '/', '')}`);
    }
    quiet('xcrun', ['simctl', 'ui', id, 'appearance', 'light']);
    quiet('xcrun', ['simctl', 'ui', id, 'content_size', 'large']);
    setReduceTransparency(id, false);
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
