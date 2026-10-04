import { tokenize, copyMessage, copyEquation } from './tokenizer.mjs';
import { typesetEquations } from './typesetter.mjs';
import { OutputBudget, validateOutput, materializeOutput } from './output-policy.mjs';
import { byteLength, demand, MathRefusal } from './math-policy.mjs';

// Owned fixture styling only. This does not select the native row layout.
export const messageCSS = `
body { margin: 0; padding: 16px; color: #17212b; background: #fff; }
.proof-message { font: 17px/1.55 system-ui; white-space: pre-wrap; overflow-wrap: anywhere; }
.proof-equation { display: inline-block; max-width: 100%; vertical-align: middle; white-space: normal; }
.proof-equation[data-display] { display: block; margin: .65em 0; }
.proof-visual { display: block; overflow-x: auto; max-width: 100%; padding: 3px 0; }
.proof-visual > svg { display: inline-block; overflow: visible; }
/* Required by pinned SVGmtable for equation bodies/labels in nested viewports.
   The outer .proof-visual still owns horizontal overflow and containment. */
.proof-visual g[data-mml-node="mtable"] > g > svg { overflow: visible; }
.proof-assistive { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
  overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
`;

function pointCompare(document, a, b) {
  const first = document.createRange(), second = document.createRange();
  first.setStart(a.node, a.offset); first.collapse(true);
  second.setStart(b.node, b.offset); second.collapse(true);
  return first.compareBoundaryPoints(0, second); // START_TO_START
}
const startPoint = range => ({ node: range.startContainer, offset: range.startOffset });
const endPoint = range => ({ node: range.endContainer, offset: range.endOffset });
function scalarBoundary(node, offset) {
  if (node.nodeType !== 3 || offset === 0 || offset === node.data.length) return true;
  const before = node.data.charCodeAt(offset - 1), after = node.data.charCodeAt(offset);
  return !(before >= 0xd800 && before <= 0xdbff && after >= 0xdc00 && after <= 0xdfff);
}

// A DOM range is resolved against owned source segments. A partial equation
// intersection contributes its original LaTeX once, never SVG glyph text or a
// second assistive copy. This is a resolver proof, not a native copy handler.
function selectedSource(root, segments, range) {
  if (!range || range.collapsed || !root.contains(range.startContainer) || !root.contains(range.endContainer)) return null;
  if (!scalarBoundary(range.startContainer, range.startOffset) || !scalarBoundary(range.endContainer, range.endOffset)) return null;
  const document = root.ownerDocument;
  const selectedStart = startPoint(range), selectedEnd = endPoint(range);
  let result = '';
  for (const segment of segments) {
    const owned = document.createRange();
    if (segment.kind === 'text') owned.selectNodeContents(segment.node); else owned.selectNode(segment.node);
    const begin = startPoint(owned), end = endPoint(owned);
    if (pointCompare(document, selectedStart, end) >= 0 || pointCompare(document, selectedEnd, begin) <= 0) continue;
    if (segment.kind === 'equation') { result += segment.latex; continue; }
    const start = selectedStart.node === segment.node ? selectedStart.offset : 0;
    const stop = selectedEnd.node === segment.node ? selectedEnd.offset : segment.text.length;
    result += segment.text.slice(start, stop);
  }
  return result;
}

let consumed = false;
export function renderMessage(source, { document, scope, lowerLimits = {}, lowerOutputLimits = {} }) {
  if (consumed) return { code: 'realm_consumed', stage: 'admission' };
  consumed = true;
  if (typeof source !== 'string' || source.length > 32768 || byteLength(source) > 32768
    || !/^proof-[a-z0-9-]{1,60}$/.test(scope)) return { code: 'invalid_message_input', stage: 'admission' };
  let stage = 'source', typesetting, outputBudget;
  const fallback = code => {
    const root = document.createElement('div'); root.className = 'proof-message';
    const node = document.createTextNode(source); root.append(node);
    const segments = [{ kind: 'text', node, text: source }];
    return { code, stage, fallback: true, root, segments, equations: [], copy: () => source,
      selection: range => selectedSource(root, segments, range),
      counts: typesetting?.counts, outputCounts: outputBudget?.counts };
  };
  try {
    const parsed = tokenize(source);
    if (parsed.code !== 'ok') return fallback(parsed.code);
    stage = 'typeset'; typesetting = typesetEquations(parsed.equations, lowerLimits);
    if (typesetting.code !== 'ok') return fallback(typesetting.code);
    stage = 'validate'; outputBudget = new OutputBudget(lowerOutputLimits);
    // Reserve source plus an overestimate for our fixed wrappers/owned attrs.
    // SVG and MathML bytes are then charged by the parser across all equations.
    outputBudget.take('bytes', 6 * byteLength(source) + byteLength(messageCSS) + 4096 + parsed.equations.length * 2048);
    let proseNodes = 0, proseBytes = 0, sourceCursor = 0;
    for (const equation of parsed.equations) {
      if (equation.raw.start > sourceCursor) { proseNodes++; proseBytes += byteLength(source.slice(sourceCursor, equation.raw.start)); }
      sourceCursor = equation.raw.end;
    }
    if (sourceCursor < source.length) { proseNodes++; proseBytes += byteLength(source.slice(sourceCursor)); }
    // Root + all source text nodes + three wrappers per equation. Two more
    // nodes cover the probe's single owned style element and its text node.
    outputBudget.take('nodes', 3 + proseNodes + 3 * parsed.equations.length);
    outputBudget.take('attributes', 1 + 5 * parsed.equations.length + parsed.equations.filter(eq => eq.display).length);
    outputBudget.take('textBytes', proseBytes + byteLength(messageCSS));
    demand(typesetting.equations.length === parsed.equations.length, 'equation_association');
    const prepared = parsed.equations.map((equation, index) => {
      const generated = typesetting.equations[index];
      demand(generated.id === equation.id, 'equation_association');
      const prefix = `${scope}-e${index}`;
      return { equation, prefix,
        svg: validateOutput(generated.svg, 'svg', prefix, outputBudget),
        mathml: validateOutput(generated.mathml, 'mathml', prefix, outputBudget) };
    });
    // Every equation is checked before real DOM allocation or publication.
    stage = 'materialize';
    const root = document.createElement('div'); root.className = 'proof-message';
    const segments = [], equations = []; let cursor = 0;
    const text = value => {
      if (!value) return;
      const node = document.createTextNode(value); root.append(node); segments.push({ kind: 'text', node, text: value });
    };
    for (const { equation, prefix, svg, mathml } of prepared) {
      text(source.slice(cursor, equation.raw.start));
      const node = document.createElement('span'); node.className = 'proof-equation'; node.id = prefix;
      if (equation.display) node.setAttribute('data-display', 'true');
      const visual = document.createElement('span'); visual.className = 'proof-visual'; visual.setAttribute('aria-hidden', 'true');
      visual.append(materializeOutput(svg, document));
      const assistive = document.createElement('span'); assistive.className = 'proof-assistive';
      assistive.append(materializeOutput(mathml, document));
      node.append(visual, assistive); root.append(node);
      const segment = { kind: 'equation', node, latex: equation.latex, id: equation.id };
      segments.push(segment); equations.push(segment); cursor = equation.raw.end;
    }
    text(source.slice(cursor));
    return { code: 'ok', stage: 'complete', fallback: false, root, segments, equations,
      copy: () => copyMessage(parsed), copyEquation: id => copyEquation(parsed, id),
      selection: range => selectedSource(root, segments, range), counts: typesetting.counts, outputCounts: outputBudget.counts };
  } catch (error) { return fallback(error instanceof MathRefusal ? error.code : 'message_internal_error'); }
}
