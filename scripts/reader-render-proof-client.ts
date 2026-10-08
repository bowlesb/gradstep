// Local proof entry only; never part of the deployed app. Uses the production
// verifier, sandbox document and bridge rather than a second rendering path.
import { verifyBundle } from '../apps/web/src/lib/bundle';
import { fromBase64 } from '../apps/web/src/lib/bytes';
import { frameDocument, readFrameMessage } from '../apps/web/src/reader/frame';

const frame = document.createElement('iframe');
frame.title = 'Verified public paper'; frame.setAttribute('sandbox', 'allow-scripts');
document.body.append(frame);
const state = { headings: 0, selection: false, invalid: false };
Object.assign(window, { readerProofState: state });
window.addEventListener('message', event => {
  if (event.source !== frame.contentWindow || event.data?.gradstep !== 'reader') return;
  const message = readFrameMessage(event.data.value);
  if (message?.type === 'headings') state.headings = message.items.length;
  if (message?.type === 'selection') state.selection = !!message.selection;
  if (message?.type === 'invalid') state.invalid = true;
});
Object.assign(window, { loadReaderProof: async (artifact: {
  manifest: string; manifest_sha256: string; members: { path: string; base64: string }[];
}, theme: 'light' | 'dark') => {
  const bundle = await verifyBundle(fromBase64(artifact.manifest), artifact.manifest_sha256,
    new Map(artifact.members.map(member => [member.path, fromBase64(member.base64)])));
  state.headings = 0; state.selection = false; state.invalid = false;
  frame.srcdoc = frameDocument(bundle, { parentOrigin: location.origin, theme });
  return {
    headings: bundle.index.headings.map(item => item.id),
    equations: bundle.index.equations.map(item => item.id),
    figures: bundle.index.figures.map(item => item.id),
    imageMembers: bundle.manifest.members.filter(item => item.role === 'image').length,
  };
} });
