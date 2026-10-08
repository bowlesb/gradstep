// Chat answers as HTML, entirely in this bundle (no CDN): Markdown by markdown-it with raw HTML and images off, math
// (`\(…\)`, `\[…\]`, `$…$`, `$$…$$`, environments) by Temml as MathML with `trust` off, then an allowlist sanitizer
// over the DOM as defense in depth (answers are model output that a paper's text could steer).
import MarkdownIt from 'markdown-it';
import temml from 'temml';
import { segments } from './chat';

const md = new MarkdownIt({ html: false, linkify: true, typographer: false, breaks: false });
md.disable(['image']);
md.validateLink = url => /^(https?:|mailto:)/i.test(url.trim());
const defaultLink = md.renderer.rules.link_open ?? ((tokens, i, options, _env, self) => self.renderToken(tokens, i, options));
md.renderer.rules.link_open = (tokens, i, options, env, self) => {
  tokens[i].attrSet('target', '_blank');
  tokens[i].attrSet('rel', 'noopener noreferrer');
  return defaultLink(tokens, i, options, env, self);
};

const escape = (s: string) => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

export function renderMath(body: string, display: boolean): string {
  try {
    return temml.renderToString(body, { displayMode: display, throwOnError: false, trust: false, annotate: false, maxExpand: 1000, maxSize: [100, 100] });
  } catch { return `<code class="math-source">${escape(body)}</code>`; }
}

/** Prose with math replaced by placeholders, never inside code (fences or backtick spans). */
function extractMath(text: string, maths: string[], streaming: boolean): string {
  let out = '';
  const lines = text.split('\n');
  let fence: string | null = null, chunk = '';
  const flush = () => {
    if (!chunk) return;
    // Inline code spans keep their text; math is taken from the rest.
    const parts = chunk.split(/(`+[^`]*?`+)/g);
    for (const part of parts) {
      if (part.startsWith('`')) { out += part; continue; }
      for (const s of segments(part)) {
        if (s.kind === 'text') { out += s.text; continue; }
        // An unclosed formula while the answer streams stays source text until it closes.
        if (!s.closed && streaming) { out += (s.display ? '\\[' : '\\(') + s.body; continue; }
        const open = s.body.startsWith('\\begin{');
        maths.push(renderMath(s.body, s.display || open));
        out += `${maths.length - 1}`;
      }
    }
    chunk = '';
  };
  for (const [index, line] of lines.entries()) {
    const marker = /^\s{0,3}(`{3,}|~{3,})/.exec(line)?.[1];
    const newline = index < lines.length - 1 ? '\n' : '';
    if (fence) {
      out += line + newline;
      if (marker && marker[0] === fence[0] && marker.length >= fence.length && !line.trim().slice(marker.length).trim()) fence = null;
    } else if (marker) {
      flush(); fence = marker; out += line + newline;
    } else chunk += line + newline;
  }
  flush();
  return out;
}

/** Markdown and math to sanitized HTML (sanitizing needs a DOM; without one it returns the renderer's output). */
export function renderMarkdown(text: string, streaming = false): string {
  const maths: string[] = [];
  const html = md.render(extractMath(text, maths, streaming))
    .replace(/(\d+)/g, (_, n) => maths[Number(n)] ?? '');
  return typeof DOMParser === 'function' ? sanitize(html) : html;
}

// ---------- Allowlist sanitizer ----------

const HTML_TAGS = new Set(['p', 'br', 'hr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'strong', 'em', 'b', 'i', 's', 'del', 'code', 'pre', 'blockquote', 'ul', 'ol',
  'li', 'table', 'thead', 'tbody', 'tr', 'th', 'td', 'a', 'span', 'div', 'sup', 'sub']);
const MATH_TAGS = new Set(['math', 'semantics', 'mrow', 'mi', 'mn', 'mo', 'ms', 'mtext', 'mspace', 'msub', 'msup', 'msubsup', 'mfrac', 'msqrt', 'mroot', 'mover',
  'munder', 'munderover', 'mtable', 'mtr', 'mtd', 'mstyle', 'mpadded', 'mphantom', 'menclose', 'merror', 'mlabeledtr', 'mmultiscripts', 'mprescripts', 'none']);
const MATH_ATTRIBUTES = new Set(['display', 'displaystyle', 'mathvariant', 'mathsize', 'mathcolor', 'mathbackground', 'stretchy', 'fence', 'separator', 'lspace',
  'rspace', 'width', 'height', 'depth', 'voffset', 'columnalign', 'rowalign', 'columnspacing', 'rowspacing', 'columnlines', 'rowlines', 'frame', 'scriptlevel',
  'accent', 'accentunder', 'movablelimits', 'linethickness', 'form', 'symmetric', 'largeop', 'minsize', 'maxsize', 'notation', 'class', 'style']);
const MATHML = 'http://www.w3.org/1998/Math/MathML';

export function sanitize(html: string): string {
  const source = new DOMParser().parseFromString(`<!doctype html><body>${html}`, 'text/html').body;
  const target = document.implementation.createHTMLDocument('');
  const copy = (node: Node, parent: Node) => {
    if (node.nodeType === Node.TEXT_NODE) { parent.appendChild(target.createTextNode(node.textContent ?? '')); return; }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    const element = node as Element, tag = element.localName, math = element.namespaceURI === MATHML;
    if (math ? !MATH_TAGS.has(tag) : !HTML_TAGS.has(tag)) {
      // Unknown containers keep their text; scripts, styles and the like are dropped whole.
      if (!['script', 'style', 'iframe', 'object', 'embed', 'template', 'annotation', 'annotation-xml', 'svg', 'foreignobject'].includes(tag)) for (const child of element.childNodes) copy(child, parent);
      return;
    }
    const out = math ? target.createElementNS(MATHML, tag) : target.createElement(tag);
    for (const attribute of element.attributes) {
      const name = attribute.name.toLowerCase(), value = attribute.value;
      if (math) {
        if (MATH_ATTRIBUTES.has(name) && !(name === 'style' && /url\(|expression|@import|\\/i.test(value))) out.setAttribute(name, value);
      } else if (tag === 'a' && name === 'href') {
        if (/^(https?:|mailto:)/i.test(value.trim())) out.setAttribute('href', value);
      } else if ((name === 'class' && ['code', 'span', 'div'].includes(tag)) || (name === 'start' && tag === 'ol') || (name === 'style' && (tag === 'th' || tag === 'td') && /^text-align:(left|right|center)$/.test(value))) {
        out.setAttribute(name, value);
      }
    }
    if (tag === 'a') { out.setAttribute('target', '_blank'); out.setAttribute('rel', 'noopener noreferrer'); }
    parent.appendChild(out);
    for (const child of element.childNodes) copy(child, out);
  };
  const box = target.createElement('div');
  for (const child of source.childNodes) copy(child, box);
  return box.innerHTML;
}
