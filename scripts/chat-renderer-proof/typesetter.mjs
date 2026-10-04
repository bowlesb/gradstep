// Local component experiment, deliberately outside every application bundle.
// Inputs are already-delimited TeX fixtures, NOT a shipping chat contract.
import { mathjax } from '../../workers/reader-renderer/node_modules/mathjax-full/js/mathjax.js';
import { TeX } from '../../workers/reader-renderer/node_modules/mathjax-full/js/input/tex.js';
import { SVG } from '../../workers/reader-renderer/node_modules/mathjax-full/js/output/svg.js';
import { LiteAdaptor } from '../../workers/reader-renderer/node_modules/mathjax-full/js/adaptors/liteAdaptor.js';
import { RegisterHTMLHandler } from '../../workers/reader-renderer/node_modules/mathjax-full/js/handlers/html.js';
import { MmlFactory } from '../../workers/reader-renderer/node_modules/mathjax-full/js/core/MmlTree/MmlFactory.js';
import { TextNode } from '../../workers/reader-renderer/node_modules/mathjax-full/js/core/MmlTree/MmlNode.js';
import { SerializedMmlVisitor } from '../../workers/reader-renderer/node_modules/mathjax-full/js/core/MmlTree/SerializedMmlVisitor.js';
import { checkCompiledMath, MathRefusal } from './math-policy.mjs';
import '../../workers/reader-renderer/node_modules/mathjax-full/js/input/tex/base/BaseConfiguration.js';
import '../../workers/reader-renderer/node_modules/mathjax-full/js/input/tex/ams/AmsConfiguration.js';
import '../../workers/reader-renderer/node_modules/mathjax-full/js/input/tex/newcommand/NewcommandConfiguration.js';

const bytes = value => new TextEncoder().encode(value).byteLength;
const limits = Object.freeze({ mmlNodes: 2000, mmlTextBytes: 32768,
  liteNodes: 4000, outputEstimate: 1048576 });
class Refusal extends Error {
  constructor(code) { super('local_component_refused'); this.code = code; }
}

// These counters cover selected factory/adaptor operations, not the JS heap,
// all parser intermediates, synchronous CPU time, or WebContent RSS.
class Budget {
  counts = { mmlNodes: 0, mmlTextBytes: 0, liteNodes: 0, outputEstimate: 0 };
  constructor(lowerLimits = {}) {
    this.limits = { ...limits };
    for (const [key, value] of Object.entries(lowerLimits)) {
      if (!(key in limits) || !Number.isSafeInteger(value) || value < 1 || value > limits[key]) {
        throw new Refusal('invalid_test_limit');
      }
      this.limits[key] = value;
    }
  }
  take(key, amount = 1) {
    if (!Number.isSafeInteger(amount) || amount < 0 || this.counts[key] + amount > this.limits[key]) {
      throw new Refusal(`${key}_limit`);
    }
    this.counts[key] += amount;
  }
}

function factories(budget) {
  class CountedText extends TextNode {
    setText(text) {
      budget.take('mmlTextBytes', bytes(text));
      return super.setText(text);
    }
  }
  class CountedFactory extends MmlFactory {
    setNodeClass(kind, NodeClass) {
      super.setNodeClass(kind, kind === 'text' ? CountedText : NodeClass);
      const make = this.node[kind];
      // Counts both factory.create and the exposed factory.MML[kind] route.
      this.node[kind] = (...args) => { budget.take('mmlNodes'); return make(...args); };
    }
  }
  class CountedAdaptor extends LiteAdaptor {
    constructor() {
      super();
      // The trusted LiteWindow scaffold is allocated in the base constructor.
      budget.take('liteNodes', 4); budget.take('outputEstimate', 64);
    }
    parse(text, format) {
      // LiteParser has direct comment constructors; source HTML/XML must never
      // enter this route. Only MathDocument's owned empty scaffold is allowed.
      if (text !== '') throw new Refusal('unexpected_document_parse');
      return super.parse(text, format);
    }
    create(kind, ns) {
      budget.take('liteNodes'); budget.take('outputEstimate', 2 * bytes(kind) + 5);
      return super.create(kind, ns);
    }
    text(text) {
      budget.take('liteNodes'); budget.take('outputEstimate', 6 * bytes(text));
      return super.text(text);
    }
    comment(text) {
      budget.take('liteNodes'); budget.take('outputEstimate', 6 * bytes(text) + 7);
      return super.comment(text);
    }
    createDocument() {
      // LiteDocument constructs document/html/head/body without calling create.
      budget.take('liteNodes', 4); budget.take('outputEstimate', 64);
      return super.createDocument();
    }
    setAttribute(node, name, value, ns) {
      budget.take('outputEstimate', bytes(name) + 6 * bytes(String(value)) + 16);
      return super.setAttribute(node, name, value, ns);
    }
    setStyle(node, name, value) {
      // Includes repeated serialization of existing style properties. Counting
      // mutations cumulatively intentionally overestimates retained bytes.
      budget.take('outputEstimate', 6 * (bytes(this.getAttribute(node, 'style') ?? '')
        + bytes(name) + bytes(value)) + 32);
      return super.setStyle(node, name, value);
    }
    addClass(node, name) {
      budget.take('outputEstimate', 6 * (bytes(this.getAttribute(node, 'class') ?? '') + bytes(name)) + 16);
      return super.addClass(node, name);
    }
    clone(node) {
      if (node.kind === '#text') return this.text(node.value);
      if (node.kind === '#comment') return this.comment(node.value);
      return this.node(node.kind, { ...node.attributes }, node.children.map(child => this.clone(child)));
    }
    split() { throw new Refusal('unsupported_adaptor_split'); }
  }
  return { factory: new CountedFactory(), adaptor: new CountedAdaptor() };
}

function checkMml(root) {
  const stack = [[root, 0]];
  while (stack.length) {
    const [node, depth] = stack.pop();
    if (depth > 64) throw new Refusal('mml_depth_limit');
    if (node.kind === 'merror') throw new Refusal('math_error_node');
    if (node.kind === 'XML') throw new Refusal('unexpected_xml');
    for (const child of node.childNodes ?? []) stack.push([child, depth + 1]);
  }
}

// LiteAdaptor.childNodes accepts elements only. The previous probe incorrectly
// called it for label text nodes and misreported verifier TypeErrors as TeX errors.
function inspectOutput(adaptor, root) {
  let outerSVGCount = 0, textNodes = 0, nodes = 0, svgNode;
  const stack = [[root, 0, false]];
  while (stack.length) {
    const [node, depth, insideSVG] = stack.pop();
    if (++nodes > 4000 || depth > 64) throw new Refusal('output_tree_limit');
    const kind = adaptor.kind(node);
    if (kind === '#text' || kind === '#comment') { textNodes++; continue; }
    if (kind === 'svg' && !insideSVG) { outerSVGCount++; svgNode = node; }
    if (adaptor.hasAttribute(node, 'data-mjx-error') || adaptor.getAttribute(node, 'data-mml-node') === 'merror') {
      throw new Refusal('math_error_node');
    }
    for (const child of adaptor.childNodes(node)) stack.push([child, depth + 1, insideSVG || kind === 'svg']);
  }
  if (outerSVGCount !== 1) throw new Refusal('output_shape');
  return { outerSVGCount, textNodes, nodes, svgNode };
}

let consumed = false;
function convert(equations, lowerLimits, withOutput) {
  if (consumed) return { code: 'realm_consumed', stage: 'admission', converted: false };
  consumed = true;
  if (!Array.isArray(equations) || equations.length > 16 || equations.some(eq =>
    !eq || typeof eq.latex !== 'string' || typeof eq.display !== 'boolean')) return { code: 'invalid_input', stage: 'admission', converted: false };
  if (equations.some(eq => eq.latex.length > 12288 || bytes(eq.latex) > 12288)
    || equations.reduce((sum, eq) => sum + bytes(eq.latex), 0) > 32768) return { code: 'source_limit', stage: 'admission', converted: false };
  let stage = 'configuration', budget;
  try {
    budget = new Budget(lowerLimits);
    if (mathjax.asyncLoad !== null) throw new Refusal('unexpected_loader');
    const { factory, adaptor } = factories(budget);
    RegisterHTMLHandler(adaptor);
    const tex = new TeX({ packages: ['base', 'ams', 'newcommand'], tags: 'ams', baseURL: '', useLabelIds: false,
      maxMacros: 1000, maxBuffer: 15360,
      formatError: (_jax, error) => {
        const texCode = ['MaxMacroSub1', 'MaxMacroSub2'].includes(error.id) ? 'expansion_limit'
          : error.id === 'MaxBufferSize' ? 'buffer_limit' : 'tex_error';
        throw new Refusal(texCode);
      } });
    let compiledRoot, semanticEstimate;
    const document = mathjax.document('', { InputJax: tex, OutputJax: new SVG({ fontCache: 'none' }),
      MmlFactory: factory,
      compileError: () => { throw new Refusal('compile_error'); },
      typesetError: () => { throw new Refusal('typeset_error'); },
      renderActions: { proofCheck: [21, () => false, math => {
        checkMml(math.root);
        semanticEstimate = checkCompiledMath(math.root);
        if (withOutput) budget.take('outputEstimate', semanticEstimate);
        compiledRoot = math.root; stage = 'svg'; return false;
      }, true] } });
    const results = []; let outputBytes = 0, lastShape = {};
    for (const equation of equations) {
      stage = 'compile'; compiledRoot = undefined;
      const output = document.convert(equation.latex, { display: equation.display, em: 17, ex: 8.5, containerWidth: 320 });
      stage = 'verification';
      const { svgNode, ...shape } = inspectOutput(adaptor, output); lastShape = shape;
      stage = 'serialization';
      const svg = adaptor.outerHTML(withOutput ? svgNode : output);
      const mathml = withOutput ? new SerializedMmlVisitor().visitTree(compiledRoot) : '';
      if (withOutput && bytes(mathml) > semanticEstimate) throw new Refusal('semantic_estimate_failed');
      outputBytes += bytes(svg) + bytes(mathml);
      if (outputBytes > 1048576) throw new Refusal('output_limit');
      if (withOutput) results.push({ id: equation.id, svg, mathml });
    }
    // Raw generated output is internal to the combined validator. The public
    // test bridge still returns only finite statuses and counters.
    return { code: 'ok', stage: 'complete', converted: equations.length > 0,
      outputBytes, ...lastShape, counts: budget.counts, ...(withOutput ? { equations: results } : {}) };
  } catch (error) {
    return { code: error instanceof Refusal || error instanceof MathRefusal ? error.code : 'internal_error', stage,
      converted: !['configuration', 'admission'].includes(stage), counts: budget?.counts ?? null };
  }
}

export function run({ source, display = true, lowerLimits = {} }) {
  return convert([{ latex: source, display }], lowerLimits, false);
}
export function typesetEquations(equations, lowerLimits = {}) {
  return convert(equations, lowerLimits, true);
}

globalThis.ChatTypesetterProof = Object.freeze({ run });
