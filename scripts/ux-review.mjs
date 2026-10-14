#!/usr/bin/env node
// Pre-build UX review (docs/UX_REVIEW.md): captures the browser's main screens and chat states over the local
// fixture backend (desktop and phone, light and dark) and writes a contact sheet to .artifacts/ux/web/index.html.
// Native screens use scripts/visual-check.mjs (Simulator). Neither makes a hosted or paid request.
//
//   node scripts/ux-review.mjs            # capture + sheet
//   node scripts/ux-review.mjs --sheet    # rebuild the sheet from existing captures
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const root = resolve(new URL('..', import.meta.url).pathname);
const out = join(root, '.artifacts/ux/web');
mkdirSync(out, { recursive: true });
if (!process.argv.includes('--sheet')) {
  const extra = process.argv.slice(2).filter(a => a !== '--sheet');
  execFileSync('npx', ['playwright', 'test', '--config', 'ux-review.playwright.config.ts', ...extra],
    { cwd: join(root, 'apps/web'), stdio: 'inherit' });
}
const shots = readdirSync(out).filter(f => f.endsWith('.png')).sort();
const groups = new Map();
for (const file of shots) {
  const [project, scheme, ...rest] = file.replace(/\.png$/, '').split('-');
  const screen = rest.join('-');
  if (!groups.has(screen)) groups.set(screen, []);
  groups.get(screen).push({ file, project, scheme });
}
const order = ['signin', 'library', 'reader-chat-empty', 'chat-consent', 'chat-waiting', 'chat-streaming', 'chat-answer',
  'chat-citation-jump', 'chat-follow-up-filled', 'chat-answer-settings', 'chat-no-credits', 'all-chats'];
const sorted = [...groups.entries()].sort((a, b) => (order.indexOf(a[0]) + 1 || 99) - (order.indexOf(b[0]) + 1 || 99));
const escape = s => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const html = `<!doctype html><meta charset="utf-8"><title>Gradstep browser UX review</title>
<style>body{font:14px -apple-system,system-ui,sans-serif;margin:24px;background:#f4f4f6;color:#222}h1{font-size:20px}h2{font-size:15px;margin:28px 0 8px}
.row{display:flex;gap:14px;flex-wrap:wrap;align-items:flex-start}figure{margin:0}figcaption{font-size:12px;color:#555;margin-top:4px}
img{display:block;max-width:100%;border:1px solid #d6d6dc;border-radius:6px;background:#fff}.desktop img{width:640px}.phone img{width:200px}</style>
<h1>Gradstep browser UX review</h1><p>${shots.length} captures, ${new Date().toISOString()}. Fixture backend; no hosted or paid request.</p>
${sorted.map(([screen, items]) => `<h2>${escape(screen)}</h2><div class="row">${items.map(i => `<figure class="${i.project}"><img src="${escape(i.file)}" loading="lazy"><figcaption>${escape(i.project)} · ${escape(i.scheme)}</figcaption></figure>`).join('')}</div>`).join('\n')}`;
writeFileSync(join(out, 'index.html'), html);
console.log(`${shots.length} screenshots; sheet at ${join(out, 'index.html')}`);
if (!existsSync(join(out, 'index.html'))) process.exitCode = 1;
