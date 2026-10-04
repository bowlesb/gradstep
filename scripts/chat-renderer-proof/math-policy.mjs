// Closed semantic profile for the completed-message fixture renderer.
export class MathRefusal extends Error {
  constructor(code) { super('math_formatting_unavailable'); this.code = code; }
}
export const demand = (condition, code) => { if (!condition) throw new MathRefusal(code); };
export const byteLength = value => new TextEncoder().encode(value).length;
export const SVG_NS = 'http://www.w3.org/2000/svg';
export const MML_NS = 'http://www.w3.org/1998/Math/MathML';
export const mmlTags = new Set(['math', 'mrow', 'mi', 'mo', 'mn', 'mtext', 'mspace', 'ms',
  'msub', 'msup', 'msubsup', 'munder', 'mover', 'munderover', 'mfrac', 'msqrt', 'mroot',
  'mfenced', 'mtable', 'mtr', 'mlabeledtr', 'mtd', 'mstyle', 'mpadded', 'mphantom', 'menclose']);
const booleans = new Set(['displaystyle', 'stretchy', 'fence', 'separator', 'symmetric', 'largeop',
  'movablelimits', 'accent', 'accentunder', 'equalrows', 'equalcolumns']);
const lengths = new Set(['mathsize', 'lspace', 'rspace', 'minsize', 'maxsize', 'width', 'height', 'depth',
  'voffset', 'linethickness', 'rowspacing', 'columnspacing', 'framespacing', 'minlabelspacing']);
const semantics = new Set(['form', 'numalign', 'denomalign', 'rowalign', 'columnalign', 'groupalign', 'align',
  'rowlines', 'columnlines', 'frame', 'side', 'notation', 'open', 'close', 'separators', 'columnwidth']);
const variants = new Set(['normal', 'bold', 'italic', 'bold-italic', 'double-struck', 'fraktur', 'bold-fraktur',
  'script', 'bold-script', 'sans-serif', 'bold-sans-serif', 'sans-serif-italic', 'sans-serif-bold-italic',
  'monospace', '-tex-calligraphic', '-tex-bold-calligraphic', '-tex-oldstyle', '-tex-bold-oldstyle',
  '-tex-mathit', '-tex-variant']);
const namedSpaces = new Set(['veryverythinmathspace', 'verythinmathspace', 'thinmathspace', 'mediummathspace',
  'thickmathspace', 'verythickmathspace', 'veryverythickmathspace']);

export function finiteNumber(value, maximum = 1000000) {
  return /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(value)
    && Number.isFinite(Number(value)) && Math.abs(Number(value)) <= maximum;
}
export function finiteLength(value, maximum = 10000) {
  const match = /^([+-]?(?:\d+(?:\.\d*)?|\.\d+))(em|ex|px|pt|pc|in|cm|mm|mu|%)?$/.exec(value);
  return !!match && finiteNumber(match[1], maximum);
}
export function mathAttribute(tag, name, raw, { compiled = false } = {}) {
  const value = String(raw);
  if (value.length > 1024 || /[\u0000-\u001f\u007f]/.test(value)) return false;
  if (name === 'id') return tag === 'mtd' && /^mjx-eqn:[A-Za-z0-9_.:-]{1,200}$/.test(value);
  if (name === 'xmlns') return !compiled && tag === 'math' && value === MML_NS;
  if (name === 'display') return tag === 'math' && ['block', 'inline'].includes(value);
  if (name === 'mathvariant') return variants.has(value);
  if (booleans.has(name)) return ['true', 'false'].includes(value);
  if (name === 'scriptlevel') return finiteNumber(value, 8) && Number.isInteger(Number(value));
  if (name === 'rowspan' || name === 'columnspan') return /^\d{1,2}$/.test(value) && Number(value) > 0;
  if (lengths.has(name)) return value.trim().split(/ +/).every(part => finiteLength(part)
    || ['lspace', 'rspace'].includes(name) && namedSpaces.has(part));
  if (semantics.has(name)) return /^[A-Za-z0-9 .,(){}|+%_-]{0,256}$/.test(value);
  if (!compiled && name === 'data-mjx-texclass') return ['NONE', 'ORD', 'OP', 'BIN', 'REL', 'OPEN', 'CLOSE', 'PUNCT', 'INNER', 'VCENTER'].includes(value);
  if (!compiled && name === 'data-mjx-variant') return variants.has(value);
  if (!compiled && name === 'data-mjx-alternate') return value === '1';
  if (!compiled && ['data-mjx-pseudoscript', 'data-mjx-smallmatrix'].includes(name)) return value === 'true';
  if (!compiled && name === 'data-mjx-auto-op') return value === 'false';
  if (!compiled && name === 'data-mjx-script-align') return ['left', 'right', 'center'].includes(value);
  return false;
}

export function checkCompiledMath(root) {
  let serializationEstimate = 0;
  const stack = [[root, 0]];
  while (stack.length) {
    const [node, depth] = stack.pop();
    demand(depth <= 64, 'mml_depth_limit');
    demand(mmlTags.has(node.kind) || ['text', 'TeXAtom', 'inferredMrow'].includes(node.kind), 'unsupported_mml_node');
    // Conservative final-serialization bound for this pinned visitor: tags,
    // generated attributes, default namespace, indentation and separators.
    // Explicit values/text are charged separately at the worst escaping ratio.
    // This does not bound the visitor's temporary strings or the JS heap.
    serializationEstimate += 512 + depth * 4 + 6 * byteLength(node.kind);
    if (node.kind === 'text') serializationEstimate += 6 * byteLength(node.getText());
    for (const [name, value] of Object.entries(node.attributes?.getAllAttributes() ?? {})) {
      demand(mathAttribute(node.kind, name, value, { compiled: true }), 'author_math_attributes');
      serializationEstimate += byteLength(name) + 6 * byteLength(String(value)) + 4;
    }
    for (const child of node.childNodes ?? []) stack.push([child, depth + 1]);
  }
  return serializationEstimate;
}
