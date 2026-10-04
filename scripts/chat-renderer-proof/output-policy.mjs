// Rejecting XML parser for generated output. This is deliberately a smaller
// profile than the paper renderer. No source markup goes through this parser.
import { SaxesParser } from '../../node_modules/saxes/saxes.js';
import { demand, byteLength, finiteNumber, finiteLength, mathAttribute, mmlTags,
  MathRefusal, MML_NS, SVG_NS } from './math-policy.mjs';

const number = '[+-]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][+-]?\\d+)?';
const tokenPattern = new RegExp(`[MmZzLlHhVvCcSsQqTtAa]|${number}`, 'g');
const svgTags = new Set(['svg', 'g', 'path', 'rect', 'text', 'line', 'ellipse', 'circle', 'polygon', 'polyline']);
const numberAttrs = new Set(['x', 'y', 'x1', 'x2', 'y1', 'y2', 'cx', 'cy', 'r', 'rx', 'ry', 'stroke-width']);
const metadata = new Set(['data-table', 'data-labels', 'data-idbox', 'data-id-align']);
const texClasses = new Set(['NONE', 'ORD', 'OP', 'BIN', 'REL', 'OPEN', 'CLOSE', 'PUNCT', 'INNER', 'VCENTER']);

function numbers(value, min, max = min) {
  const parts = value.trim().split(/[\s,]+/);
  return parts.length >= min && parts.length <= max && parts.every(part => finiteNumber(part));
}
function pathData(value) {
  if (value === '') return true; // MathJax's space glyph is a path with no ink.
  if (value.length > 32768) return false;
  const tokens = [...value.matchAll(tokenPattern)];
  if (!tokens.length || tokens.length > 8192 || !['M', 'm'].includes(tokens[0][0])) return false;
  let end = 0, command, count = 0;
  const arity = { M: 2, L: 2, H: 1, V: 1, C: 6, S: 4, Q: 4, T: 2, A: 7, Z: 0 };
  const complete = () => command && (command === 'Z' ? count === 0 : count >= arity[command] && count % arity[command] === 0);
  for (const item of tokens) {
    if (!/^[\s,]*$/.test(value.slice(end, item.index))) return false;
    end = item.index + item[0].length;
    if (/^[A-Za-z]$/.test(item[0])) {
      if (command && !complete()) return false;
      command = item[0].toUpperCase(); count = 0;
    } else {
      if (!command || command === 'Z' || !finiteNumber(item[0])) return false;
      if (command === 'A' && [3, 4].includes(count % 7) && !['0', '1'].includes(item[0])) return false;
      count++;
    }
  }
  return complete() && /^[\s,]*$/.test(value.slice(end));
}
function transform(value) {
  const matches = [...value.matchAll(/(translate|scale|matrix|rotate)\(([^()]*)\)/g)];
  if (!matches.length || matches.length > 8) return false;
  let end = 0;
  for (const item of matches) {
    if (!/^\s*$/.test(value.slice(end, item.index))) return false;
    end = item.index + item[0].length;
    if (item[1] === 'matrix' ? !numbers(item[2], 6)
      : item[1] === 'rotate' ? !(numbers(item[2], 1) || numbers(item[2], 3)) : !numbers(item[2], 1, 2)) return false;
  }
  return /^\s*$/.test(value.slice(end));
}
function layoutStyle(value) {
  const entries = value.split(';').map(item => item.trim()).filter(Boolean);
  if (!entries.length || entries.length > 2) return false;
  const seen = new Set();
  return entries.every(item => {
    const pair = item.split(':').map(part => part.trim());
    if (pair.length !== 2 || seen.has(pair[0]) || !['vertical-align', 'min-width'].includes(pair[0])) return false;
    seen.add(pair[0]);
    return /^-?(?:\d+(?:\.\d*)?|\.\d+)ex$/.test(pair[1]) && finiteLength(pair[1], 2000)
      && (pair[0] !== 'min-width' || !pair[1].startsWith('-'));
  });
}
function svgAttribute(tag, name, value) {
  if (name === 'd') return tag === 'path' && pathData(value);
  if (value.length > 1024 || /[\u0000-\u001f\u007f]/.test(value)) return false;
  if (name === 'xmlns') return tag === 'svg' && value === SVG_NS;
  if (name === 'id') return tag === 'g' && /^mjx-eqn:[A-Za-z0-9_.:-]{1,200}$/.test(value);
  if (name === 'style') return tag === 'svg' && layoutStyle(value);
  if (name === 'viewBox') return tag === 'svg' && numbers(value, 4)
    && value.trim().split(/[\s,]+/).slice(2).every(part => Number(part) > 0);
  if (name === 'width' || name === 'height') return ['svg', 'rect'].includes(tag) && finiteLength(value) && parseFloat(value) >= 0;
  if (numberAttrs.has(name)) return finiteNumber(value);
  if (name === 'transform') return transform(value);
  if (name === 'fill' || name === 'stroke') return ['none', 'currentColor'].includes(value);
  if (name === 'stroke-linecap') return ['butt', 'round', 'square'].includes(value);
  if (name === 'stroke-linejoin') return ['miter', 'round', 'bevel'].includes(value);
  if (name === 'points') return ['polygon', 'polyline'].includes(tag) && numbers(value, 4, 256)
    && value.trim().split(/[\s,]+/).length % 2 === 0;
  if (name === 'preserveAspectRatio') return tag === 'svg' && ['xMidYMid', 'xMinYMid', 'xMaxYMid'].includes(value);
  if (name === 'role') return tag === 'svg' && value === 'img';
  if (name === 'focusable') return tag === 'svg' && value === 'false';
  if (name === 'data-mml-node') return mmlTags.has(value) || value === 'TeXAtom';
  if (name === 'data-mjx-texclass') return texClasses.has(value);
  if (name === 'data-c') return /^[0-9A-F]{1,6}$/.test(value) && Number.parseInt(value, 16) <= 0x10ffff;
  if (metadata.has(name)) return value === 'true';
  return false;
}

const limits = Object.freeze({ bytes: 1048576, nodes: 6000, attributes: 24000, textBytes: 65536 });
export class OutputBudget {
  counts = { bytes: 0, nodes: 0, attributes: 0, textBytes: 0 };
  constructor(lower = {}) {
    this.limits = { ...limits };
    for (const [key, value] of Object.entries(lower)) {
      demand(key in limits && Number.isSafeInteger(value) && value > 0 && value <= limits[key], 'invalid_output_limit');
      this.limits[key] = value;
    }
  }
  take(key, amount) {
    demand(Number.isSafeInteger(amount) && amount >= 0 && this.counts[key] + amount <= this.limits[key], `validated_${key}_limit`);
    this.counts[key] += amount;
  }
}

export function validateOutput(xml, kind, prefix, budget) {
  demand(['svg', 'mathml'].includes(kind) && /^proof-[a-z0-9-]{1,80}$/.test(prefix), 'invalid_output_input');
  demand(typeof xml === 'string', 'invalid_output_input');
  budget.take('bytes', byteLength(xml)); // Before SAX can accumulate a token.
  const namespace = kind === 'svg' ? SVG_NS : MML_NS;
  const tags = kind === 'svg' ? svgTags : mmlTags;
  const stack = [], ids = new Set(); let root;
  const parser = new SaxesParser({ xmlns: true, fragment: false, defaultXMLVersion: '1.0', forceXMLVersion: true });
  for (const event of ['xmldecl', 'doctype', 'processinginstruction', 'comment', 'cdata']) {
    parser.on(event, () => { throw new MathRefusal('unsupported_xml_construct'); });
  }
  parser.on('error', () => { throw new MathRefusal('invalid_xml'); });
  parser.on('opentagstart', () => {
    demand(stack.length < 64, 'validated_depth_limit'); budget.take('nodes', 1);
  });
  parser.on('attribute', attribute => {
    budget.take('attributes', 1);
    demand(attribute.name.length <= 64 && attribute.value.length <= 32768, 'output_attribute_limit');
  });
  parser.on('opentag', tag => {
    demand(!tag.prefix && tag.uri === namespace && tags.has(tag.local), 'output_namespace_or_tag');
    demand(stack.length > 0 || !root && tag.local === (kind === 'svg' ? 'svg' : 'math'), 'output_root');
    const node = { tag: tag.local, namespace, attributes: [], children: [] };
    for (const attribute of Object.values(tag.attributes)) {
      const { name, value, prefix: attributePrefix, uri } = attribute;
      if (name === 'xmlns') {
        demand(stack.length === 0 && value === namespace, 'output_namespace_or_tag');
        continue; // createElementNS supplies the owned namespace.
      }
      demand(!attributePrefix && !uri && !name.includes(':'), 'output_namespace_or_tag');
      demand(kind === 'svg' ? svgAttribute(tag.local, name, value) : mathAttribute(tag.local, name, value), 'output_attribute');
      if (name === 'id') {
        demand(!ids.has(value), 'duplicate_output_id'); ids.add(value);
        const ownedID = `${prefix}-${kind}-${ids.size}`;
        budget.take('bytes', Math.max(0, byteLength(ownedID) - byteLength(value)));
        node.attributes.push(['id', ownedID]);
      } else node.attributes.push([name, value]);
    }
    if (stack.length) stack.at(-1).children.push(node); else root = node;
    stack.push(node);
  });
  parser.on('text', value => {
    budget.take('textBytes', byteLength(value));
    const parent = stack.at(-1);
    const token = parent && (kind === 'svg' ? parent.tag === 'text' : ['mi', 'mn', 'mo', 'mtext', 'ms'].includes(parent.tag));
    if (token && value) { budget.take('nodes', 1); parent.children.push({ text: value }); }
    else demand(/^[\t\n\r ]*$/.test(value), 'output_text_position');
  });
  parser.on('closetag', () => stack.pop());
  parser.write(xml).close();
  demand(root && stack.length === 0, 'output_root');
  return root;
}

export function materializeOutput(ast, document) {
  if ('text' in ast) return document.createTextNode(ast.text);
  const node = document.createElementNS(ast.namespace, ast.tag);
  for (const [name, value] of ast.attributes) node.setAttribute(name, value);
  for (const child of ast.children) node.append(materializeOutput(child, document));
  return node;
}
