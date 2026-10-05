#!/usr/bin/env node
// Prepares a recorded test session for review (docs/SESSION_REVIEW.md).
// Usage: node scripts/session-review.mjs [path/to/paperstep-session-*.zip | session-folder]
// With no path, takes the newest paperstep-session-*.zip in ~/Downloads (where
// AirDrop puts it). Unzips into .artifacts/sessions/<id>/, builds the Swift
// review tool if needed and writes <id>/review/review.md.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, join, resolve } from 'node:path';

const root = resolve(new URL('..', import.meta.url).pathname);
const sessions = join(root, '.artifacts/sessions');
mkdirSync(sessions, { recursive: true });

export function newestDownload() {
  const downloads = join(homedir(), 'Downloads');
  const zips = readdirSync(downloads).filter(n => /^paperstep-session-.*\.zip$/.test(n))
    .map(n => join(downloads, n)).sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
  return zips[0];
}

export function unpack(zip) {
  const id = basename(zip).replace(/^paperstep-session-/, '').replace(/\.zip$/, '');
  const folder = join(sessions, id);
  if (!existsSync(join(folder, 'timeline.jsonl'))) {
    execFileSync('ditto', ['-x', '-k', zip, sessions]);
    if (!existsSync(join(folder, 'timeline.jsonl'))) throw new Error(`No session folder ${id} in ${zip}`);
  }
  return folder;
}

export function review(folder) {
  const tool = join(root, 'tools/session-review/.build/release/session-review');
  execFileSync('swift', ['build', '-c', 'release', '--package-path', join(root, 'tools/session-review')], { stdio: ['ignore', 'ignore', 'inherit'] });
  execFileSync(tool, [folder], { stdio: 'inherit' });
  return join(folder, 'review/review.md');
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const input = process.argv[2] ? resolve(process.argv[2]) : newestDownload();
  if (!input) { console.error('No paperstep-session-*.zip in ~/Downloads; AirDrop one from Settings › Testing › Recorded sessions.'); process.exit(1); }
  const folder = statSync(input).isDirectory() ? input : unpack(input);
  review(folder);
}
