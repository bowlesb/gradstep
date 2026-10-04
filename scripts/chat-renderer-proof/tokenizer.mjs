// App-owned, deliberately narrow source contract experiment. No Mathpix,
// typesetter, HTML renderer, resource loader or DOM API is reachable here.
import MarkdownIt from '../../workers/reader-renderer/node_modules/markdown-it/index.js';
import paragraph from '../../workers/reader-renderer/node_modules/markdown-it/lib/rules_block/paragraph.js';
import fence from '../../workers/reader-renderer/node_modules/markdown-it/lib/rules_block/fence.js';
import code from '../../workers/reader-renderer/node_modules/markdown-it/lib/rules_block/code.js';
import backticks from '../../workers/reader-renderer/node_modules/markdown-it/lib/rules_inline/backticks.js';

export const sourceLimits = Object.freeze({ sourceBytes: 32768, equationBytes: 12288,
  blocks: 64, equations: 16, nesting: 32 });
const outerEnvironments = new Set(['equation', 'equation*', 'align', 'align*']);
const innerEnvironments = new Set(['aligned', 'alignedat', 'gathered', 'split', 'matrix', 'pmatrix',
  'bmatrix', 'Bmatrix', 'vmatrix', 'Vmatrix', 'smallmatrix', 'cases', 'array']);
const forbiddenCommands = new Set(['require', 'autoload', 'input', 'include', 'includegraphics',
  'usepackage', 'href', 'url', 'class', 'cssId', 'style', 'htmlClass', 'htmlId', 'htmlStyle',
  'htmlData', 'csname', 'endcsname', 'verb']);
const utf8 = text => new TextEncoder().encode(text).length;
const isDigit = char => char >= '0' && char <= '9';
const isSpace = char => char !== undefined && /\s/u.test(char);
const isLetter = char => char !== undefined && /[A-Za-z]/.test(char);
class SourceRefusal extends Error {
  constructor(code) { super('source_formatting_unavailable'); this.code = code; }
}
const refuse = code => { throw new SourceRefusal(code); };

function wellFormed(source) {
  for (let i = 0; i < source.length; i++) {
    const unit = source.charCodeAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = source.charCodeAt(++i);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) return false;
  }
  return true;
}

function environment(source, start) {
  const match = /^\\(begin|end)\{([A-Za-z]+\*?)\}/.exec(source.slice(start));
  if (!match) refuse('environment_syntax');
  return { command: match[1], name: match[2], end: start + match[0].length };
}

// A lexical, explicitly limited TeX boundary recognizer, not a TeX evaluator.
// Comments and escaped control symbols cannot end a formula. Group and
// environment stacks prevent a delimiter inside a group from shortening it.
function mathAt(source, start) {
  let open, close, form = 'body', display, firstEnvironment;
  if (source.startsWith('$$', start)) { open = close = '$$'; display = true; }
  else if (source[start] === '$') {
    if (isSpace(source[start + 1]) || start + 1 === source.length) return null;
    open = close = '$'; display = false;
  } else if (source.startsWith('\\(', start)) { open = '\\('; close = '\\)'; display = false; }
  else if (source.startsWith('\\[', start)) { open = '\\['; close = '\\]'; display = true; }
  else if (source.startsWith('\\begin', start) && !isLetter(source[start + 6])) {
    firstEnvironment = environment(source, start);
    if (!outerEnvironments.has(firstEnvironment.name)) refuse('unsupported_environment');
    open = source.slice(start, firstEnvironment.end); form = 'environment'; display = true;
  } else return null;

  let pos = start + open.length, groups = 0;
  const stack = firstEnvironment ? [{ name: firstEnvironment.name, groups: 0 }] : [];
  function finish(end, bodyEnd) {
    const bodyStart = form === 'environment' ? start : start + open.length;
    const contentEnd = form === 'environment' ? end : bodyEnd;
    const body = source.slice(bodyStart, contentEnd);
    if (!body.trim() || (form === 'environment' && !source.slice(start + open.length, bodyEnd).trim())) refuse('empty_math');
    if (utf8(body) > sourceLimits.equationBytes) refuse('equation_limit');
    return { start, end, bodyStart, bodyEnd: contentEnd, form, display, latex: body };
  }
  while (pos < source.length) {
    const char = source[pos];
    if (char === '%') {
      const newline = source.indexOf('\n', pos + 1);
      pos = newline < 0 ? source.length : newline + 1;
      continue;
    }
    if (!groups && !stack.length && close && source.startsWith(close, pos)) {
      if (close === '$' && (isSpace(source[pos - 1]) || isDigit(source[pos + 1]))) {
        // Do not skip this boundary and accidentally swallow a later formula
        // into a price, e.g. "Cost $5; then $x$".
        if (isDigit(source[start + 1])) return null;
        refuse('ambiguous_dollar');
      }
      return finish(pos + close.length, pos);
    }
    if (char === '\\') {
      const word = /^\\([A-Za-z]+)/.exec(source.slice(pos));
      if (!word) {
        // Any other unescaped math closer/opening is a mismatch at top level.
        if (!groups && !stack.length && ['(', ')', '[', ']'].includes(source[pos + 1])) {
          if (open === '$' && isDigit(source[start + 1]) && ['(', '['].includes(source[pos + 1])) return null;
          refuse('mismatched_delimiter');
        }
        pos += Math.min(2, source.length - pos); continue;
      }
      const command = word[1];
      if (forbiddenCommands.has(command)) refuse('unsupported_command');
      if (command === 'begin' || command === 'end') {
        const marker = environment(source, pos);
        if (command === 'begin') {
          if (open === '$' && isDigit(source[start + 1]) && !groups && !stack.length && outerEnvironments.has(marker.name)) return null;
          if (!innerEnvironments.has(marker.name)) refuse('unsupported_environment');
          stack.push({ name: marker.name, groups });
          if (stack.length + groups > sourceLimits.nesting) refuse('nesting_limit');
        } else {
          const active = stack.pop();
          if (!active || active.name !== marker.name || active.groups !== groups) refuse('mismatched_environment');
          if (!stack.length && firstEnvironment) return finish(marker.end, pos);
        }
        pos = marker.end; continue;
      }
      pos += word[0].length; continue;
    }
    if (char === '{') {
      if (++groups + stack.length > sourceLimits.nesting) refuse('nesting_limit');
    } else if (char === '}') {
      if (groups === 0) refuse('mismatched_group');
      groups--;
      if (stack.length && groups < stack[stack.length - 1].groups) refuse('mismatched_environment');
    } else if (char === '$' && !groups && !stack.length && close !== '$') {
      refuse('mismatched_delimiter');
    }
    pos++;
  }
  // Bare prices are ordinary text. Other incomplete math requests a full
  // source fallback. This is intentionally more conservative than Mathpix.
  if (open === '$' && isDigit(source[start + 1]) && !groups && !stack.length) return null;
  refuse('unclosed_math');
}

function range(start, end) { return { start, end }; }
function blockRange(state, map) {
  return range(state.bMarks[map[0]], map[1] < state.lineMax ? state.bMarks[map[1]] : state.src.length);
}
function countBlock(state) {
  if (++state.env.proofBlockCount > sourceLimits.blocks) refuse('block_limit');
}
function countEquation(state) {
  if (++state.env.proofEquationCount > sourceLimits.equations) refuse('equation_count_limit');
}
function trackedBackticks(state, silent) {
  const start = state.pos, before = state.tokens.length;
  if (!backticks(state, silent)) return false;
  if (!silent) {
    const token = state.tokens.slice(before).find(item => item.type === 'code_inline');
    if (token) token.meta = { start, end: state.pos,
      bodyStart: start + token.markup.length, bodyEnd: state.pos - token.markup.length };
  }
  return true;
}

function parser() {
  const codeOnly = new MarkdownIt('zero').enable(['escape', 'backticks']);
  codeOnly.inline.ruler.at('backticks', trackedBackticks);
  function codeCovers(state, position) {
    // A block rule runs before inline parsing. Preview only code spans up to
    // the existing paragraph's real blank-line/fence boundary, so an apparent
    // display equation inside multiline inline code cannot interrupt it.
    let preview = state.env.proofCodePreview;
    if (preview?.line !== state.line) {
      const first = state.bMarks[state.line];
      let last = state.line + 1;
      while (last < state.lineMax && !state.isEmpty(last) && !fence(state, last, state.lineMax, true)) last++;
      const end = last < state.lineMax ? state.bMarks[last] : state.src.length;
      const tokens = [];
      codeOnly.inline.parse(state.src.slice(first, end), codeOnly, {}, tokens);
      preview = { line: state.line, spans: tokens.filter(token => token.type === 'code_inline')
        .map(token => range(first + token.meta.start, first + token.meta.end)) };
      state.env.proofCodePreview = preview;
    }
    return preview.spans.some(span => span.start < position && position < span.end);
  }
  const md = new MarkdownIt('zero', { html: false, linkify: false, typographer: false, maxNesting: 32 });
  md.enable(['fence', 'code', 'newline', 'escape', 'backticks']);
  // Refused CR/NUL are never normalized; these rules see the original string.
  md.core.ruler.disable('normalize');
  md.block.ruler.at('paragraph', (state, start, end, silent) => {
    const first = state.tokens.length;
    const accepted = paragraph(state, start, end, silent);
    if (!accepted || silent) return accepted;
    countBlock(state);
    const token = state.tokens.slice(first).find(item => item.type === 'inline');
    if (!token || state.blkIndent !== 0) refuse('source_mapping');
    const raw = blockRange(state, token.map);
    const original = state.src.slice(raw.start, state.eMarks[token.map[1] - 1]);
    const offset = original.length - original.trimStart().length;
    if (original.trim() !== token.content) refuse('source_mapping');
    token.meta = { raw, content: range(raw.start + offset, raw.start + offset + token.content.length) };
    return true;
  });
  for (const [name, rule] of [['fence', fence], ['code', code]]) {
    md.block.ruler.at(name, (state, start, end, silent) => {
      const accepted = rule(state, start, end, silent);
      if (accepted && !silent) {
        countBlock(state);
        const token = state.tokens[state.tokens.length - 1];
        token.meta = { raw: blockRange(state, token.map) };
      }
      return accepted;
    }, { alt: name === 'fence' ? ['paragraph'] : [] });
  }
  md.block.ruler.before('paragraph', 'proof_math_block', (state, startLine, _endLine, silent) => {
    if (state.sCount[startLine] >= 4) return false;
    const start = state.bMarks[startLine] + state.tShift[startLine];
    if (!(state.src.startsWith('$$', start) || state.src.startsWith('\\[', start) || state.src.startsWith('\\begin', start))) return false;
    if (silent && state.parentType === 'paragraph' && codeCovers(state, start)) return false;
    const found = mathAt(state.src, start);
    if (!found) return false;
    let lastLine = startLine;
    while (lastLine < state.lineMax && state.eMarks[lastLine] < found.end) lastLine++;
    if (lastLine >= state.lineMax) refuse('source_mapping');
    if (state.src.slice(found.end, state.eMarks[lastLine]).trim()) return false;
    if (silent) return true;
    countBlock(state);
    countEquation(state);
    const token = state.push('proof_math_block', '', 0);
    token.map = [startLine, lastLine + 1]; token.meta = { raw: blockRange(state, token.map), math: found };
    state.line = lastLine + 1;
    return true;
  }, { alt: ['paragraph'] });
  md.inline.ruler.before('escape', 'proof_math', (state, silent) => {
    const found = mathAt(state.src, state.pos);
    if (!found) return false;
    if (!silent) { countEquation(state); const token = state.push('proof_math', '', 0); token.meta = found; }
    state.pos = found.end;
    return true;
  });
  md.inline.ruler.at('backticks', trackedBackticks);
  md.inline.ruler.before('escape', 'proof_unsupported', state => {
    const rest = state.src.slice(state.pos);
    if (/^<(?:[A-Za-z!/?])/.test(rest) || rest.startsWith('![')) refuse('unsupported_markup');
    if (/^\\(?:end\b|[)\]])/.test(rest)) refuse('orphan_math_end');
    const command = /^\\([A-Za-z]+)/.exec(rest)?.[1];
    if (forbiddenCommands.has(command)) refuse('unsupported_command');
    return false;
  });
  return md;
}

function checkedRange(source, value) {
  if (!Number.isSafeInteger(value.start) || !Number.isSafeInteger(value.end)
      || value.start < 0 || value.end < value.start || value.end > source.length) refuse('source_mapping');
  for (const offset of [value.start, value.end]) {
    const unit = source.charCodeAt(offset);
    if (unit >= 0xdc00 && unit <= 0xdfff) refuse('source_mapping');
  }
  return value;
}

export function tokenize(source) {
  try {
    if (typeof source !== 'string') refuse('invalid_input');
    if (source.length > sourceLimits.sourceBytes) refuse('source_limit');
    if (!wellFormed(source)) refuse('invalid_unicode');
    if (utf8(source) > sourceLimits.sourceBytes) refuse('source_limit');
    if (/[\r\0]/.test(source)) refuse('unsupported_line_encoding');
    const tokens = parser().parse(source, { proofBlockCount: 0, proofEquationCount: 0 });
    const equations = [], blocks = [];
    let previousEnd = 0;
    function math(found, offset, owner) {
      if (equations.length === sourceLimits.equations) refuse('equation_count_limit');
      const raw = checkedRange(source, range(found.start + offset, found.end + offset));
      const body = checkedRange(source, range(found.bodyStart + offset, found.bodyEnd + offset));
      if (raw.start < owner.start || raw.end > owner.end || body.start < raw.start || body.end > raw.end
          || source.slice(body.start, body.end) !== found.latex) refuse('source_mapping');
      const equation = { id: `math-${equations.length}`, raw, body,
        form: found.form, display: found.display, latex: found.latex };
      equations.push(equation);
      return { kind: 'math', raw, equationID: equation.id };
    }
    for (const token of tokens) {
      if (token.type === 'paragraph_open' || token.type === 'paragraph_close') continue;
      if (!['inline', 'proof_math_block', 'fence', 'code_block'].includes(token.type) || !token.meta?.raw) refuse('unsupported_block');
      const raw = checkedRange(source, token.meta.raw);
      if (raw.start < previousEnd) refuse('source_mapping');
      previousEnd = raw.end;
      if (token.type === 'proof_math_block') {
        blocks.push({ kind: 'math', raw, parts: [math(token.meta.math, 0, raw)] }); continue;
      }
      if (token.type !== 'inline') { blocks.push({ kind: 'code', raw, parts: [] }); continue; }
      const parts = [], content = checkedRange(source, token.meta.content);
      let cursor = content.start;
      for (const child of token.children) {
        if (!['proof_math', 'code_inline'].includes(child.type)) continue;
        let part;
        if (child.type === 'proof_math') part = math(child.meta, content.start, content);
        else {
          const span = child.meta;
          if (!span) refuse('source_mapping');
          part = { kind: 'code', raw: checkedRange(source, range(content.start + span.start, content.start + span.end)),
            body: checkedRange(source, range(content.start + span.bodyStart, content.start + span.bodyEnd)) };
        }
        if (part.raw.start < cursor || part.raw.end > content.end) refuse('source_mapping');
        if (cursor < part.raw.start) parts.push({ kind: 'text', raw: range(cursor, part.raw.start) });
        parts.push(part); cursor = part.raw.end;
      }
      if (cursor < content.end) parts.push({ kind: 'text', raw: range(cursor, content.end) });
      blocks.push({ kind: 'paragraph', raw, content, parts });
    }
    return { code: 'ok', profile: 'chat-source-proof-v1', source, blocks, equations };
  } catch (error) {
    // Source remains owned by the caller. Refusal never exposes a partial
    // sidecar, private token, exception text or fabricated replacement string.
    return { code: error instanceof SourceRefusal ? error.code : 'internal_error' };
  }
}

export function copyMessage(document) {
  if (document?.code !== 'ok') refuse('unavailable_document');
  return document.source;
}
export function copyEquation(document, equationID) {
  if (document?.code !== 'ok') refuse('unavailable_document');
  const equation = document.equations.find(item => item.id === equationID);
  if (!equation) refuse('unknown_equation');
  return document.source.slice(equation.body.start, equation.body.end);
}
