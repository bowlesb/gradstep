// Test-only host for Reader's async draft callback. Not an entry in the production build.
import { useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { verifyBundle } from '../src/lib/bundle';
import type { Item } from '../src/lib/library';
import { Reader, type ReaderCommands } from '../src/ui/Reader';
import '../src/style.css';

document.documentElement.dataset.theme = new URLSearchParams(location.search).has('dark') ? 'dark' : 'light';
const readSample = async (path: string) => new Uint8Array(await (await fetch(`/__reader_sample/${path}`)).arrayBuffer());
const manifest = await readSample('manifest.json');
const metadata = JSON.parse(new TextDecoder().decode(manifest)) as { members: { path: string }[] };
const contents = new Map(await Promise.all(metadata.members.map(async member => [member.path, await readSample(member.path)] as const)));
const bundle = await verifyBundle(manifest, 'cd902bcdeeda373f6612f00221010f3fba918dcafbd500142d46ee53b2178a71', contents);
const account = '11111111-2222-4333-8444-555555555555';
const item: Item = { kind: 'item', id: 'aaaaaaaa-0000-4000-8000-000000000001', document_id: 'dddddddd-0000-4000-8000-000000000001', artifact_id: 'bbbbbbbb-0000-4000-8000-000000000001',
  created_seq: 1, state_seq: 1, membership_revision: 1, visible: true, added_at: 0, last_remove_seq: 0, scope: 'shared_catalog', page_count: 1, readiness: 'ready', render_availability: 'available', render_availability_revision: 1,
  metadata: { title: bundle.index.title, authors: [], categories: [] } };
const cache = new Map([[JSON.stringify([account, item.id, item.artifact_id, item.readiness, item.render_availability, item.render_availability_revision,item.source_id,item.source_revision]), bundle]]);
function Host() {
  const commands = useRef<ReaderCommands | null>(null), [text, setText] = useState('Existing unsent draft'), [fail, setFail] = useState(false);
  return <div style={{ height: '100dvh', display: 'flex', flexDirection: 'column' }}>
    <label><input type="checkbox" checked={fail} onChange={e => setFail(e.target.checked)} data-testid="fail-draft" />Fail draft save</label>
    <textarea aria-label="Test composer" value={text} onChange={e => setText(e.target.value)} />
    <Reader cache={cache} account={account} item={item} theme={new URLSearchParams(location.search).has('dark') ? 'dark' : 'light'} contentsSlot={null} commands={commands}
      marks={[]} passage={null} onPassageHandled={() => {}} onMarkedChat={() => {}} onActivity={() => {}} onKey={() => {}} onContents={() => {}}
      onSelection={() => { throw new Error('Discuss must never send a selection'); }}
      onDiscuss={async quote => { await new Promise(resolve => setTimeout(resolve, 50)); if (fail) return false; setText(`About “${quote}”: ${text}`); return true; }} />
  </div>;
}
createRoot(document.getElementById('root')!).render(<Host />);
