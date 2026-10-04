import test from 'node:test';
import assert from 'node:assert/strict';
import { validateOutput, OutputBudget } from './output-policy.mjs';
import { SVG_NS, MML_NS, MathRefusal, mathAttribute } from './math-policy.mjs';
const svg = body => `<svg xmlns="${SVG_NS}">${body}</svg>`;
const math = body => `<math xmlns="${MML_NS}">${body}</math>`;
const validate = (xml, kind = 'svg', budget = new OutputBudget()) => validateOutput(xml, kind, 'proof-unit-e0', budget);
const fail = (xml, kind = 'svg', expected) => assert.throws(() => validate(xml, kind), error => error instanceof MathRefusal && (!expected || error.code === expected));

test('ordinary nested SVG, geometry and owned IDs survive validation', () => {
  const tree = validate(svg('<g id="mjx-eqn:1" transform="scale(1,-1) translate(20, 0)" fill="currentColor"><svg viewBox="0 -10 100 30"><path d="M0 0L10 10Q20 30 40 50Z" data-c="41"/></svg></g>'));
  assert.equal(tree.children[0].attributes[0][1], 'proof-unit-e0-svg-1');
  assert.equal(tree.children[0].children[0].tag, 'svg');
});
test('one semantic tree preserves significant token spaces and rewrites IDs separately', () => {
  const tree = validate(math('<mtable><mlabeledtr><mtd id="mjx-eqn:1"><mtext>two words</mtext><mtext> </mtext></mtd></mlabeledtr></mtable>'), 'mathml');
  const cell = tree.children[0].children[0].children[0];
  assert.equal(cell.attributes[0][1], 'proof-unit-e0-mathml-1');
  assert.equal(cell.children[1].children[0].text, ' ');
});
test('exact MathML named spacing supports base AMS bmod', () => {
  assert.equal(mathAttribute('mo', 'lspace', 'thickmathspace', { compiled: true }), true);
  assert.equal(mathAttribute('mo', 'lspace', 'url(https://example.invalid)'), false);
});
test('generated space glyph has an empty, harmless path', () => {
  const tree = validate(svg('<path d="" data-c="20"/>'));
  assert.equal(tree.children[0].attributes[0][1], '');
});

const forbidden = [
  ['svg-link', svg('<a href="https://example.invalid"><path d="M0 0L1 1"/></a>')],
  ['svg-image', svg('<image href="https://example.invalid"/>')],
  ['svg-use', svg('<use href="#local"/>')],
  ['svg-foreign-object', svg('<foreignObject><p>text</p></foreignObject>')],
  ['svg-script', svg('<script>void 0</script>')],
  ['svg-animation', svg('<animate attributeName="x"/>')],
  ['svg-href-attribute', svg('<g href="https://example.invalid"/>')],
  ['svg-xlink', svg('<g xmlns:xlink="http://www.w3.org/1999/xlink" xlink:href="https://example.invalid"/>')],
  ['svg-event', svg('<g onclick="void 0"/>')],
  ['svg-css-url', `<svg xmlns="${SVG_NS}" style="background:url(https://example.invalid)"></svg>`],
  ['svg-css-duplicate', `<svg xmlns="${SVG_NS}" style="vertical-align: 1ex;vertical-align: 2ex;"></svg>`],
  ['svg-fill-url', svg('<path d="M0 0L1 1" fill="url(https://example.invalid)"/>')],
  ['svg-number-limit', svg('<g transform="scale(1e100)"/>')],
  ['svg-path-injection', svg('<path d="M0 0 alert(1)"/>')],
  ['svg-path-incomplete', svg('<path d="M0 0L1"/>')],
  ['svg-class', svg('<g class="hidden"/>')],
  ['duplicate-id', svg('<g id="mjx-eqn:1"/><g id="mjx-eqn:1"/>')],
  ['duplicate-attribute', svg('<g fill="none" fill="currentColor"/>')],
  ['namespace-reset', svg('<g xmlns=""><path d="M0 0L1 1"/></g>')],
  ['namespace-switch', svg(`<math xmlns="${MML_NS}"/>`)],
  ['prefixed-root', `<s:svg xmlns:s="${SVG_NS}"/>`],
  ['missing-namespace', '<svg/>'],
  ['namespaced-attribute', svg('<g xml:base="https://example.invalid"/>')],
  ['malformed-xml', svg('<g>')],
  ['extra-root', svg('') + svg('')],
  ['xml-declaration', '<?xml version="1.0"?>' + svg('')],
  ['dtd', '<!DOCTYPE svg [<!ENTITY test "text">]>' + svg('&test;')],
  ['processing-instruction', '<?probe value?>' + svg('')],
  ['comment', svg('<!-- ignored -->')],
  ['cdata', svg('<text><![CDATA[text]]></text>')],
  ['unexpected-text', svg('text')],
  ['mml-href', math('<mi href="https://example.invalid">x</mi>'), 'mathml'],
  ['mml-style', math('<mi style="display:none">x</mi>'), 'mathml'],
  ['mml-mglyph', math('<mglyph src="https://example.invalid"/>'), 'mathml'],
  ['mml-action', math('<maction><mi>x</mi></maction>'), 'mathml'],
  ['mml-annotation', math('<semantics><annotation-xml>text</annotation-xml></semantics>'), 'mathml'],
  ['mml-id-spoof', math('<mi id="mjx-eqn:1">x</mi>'), 'mathml'],
  ['non-xml-whitespace', math('<mrow>&#xA0;</mrow>'), 'mathml'],
];
for (const [name, xml, kind] of forbidden) test(name, () => fail(xml, kind));
test('node and attribute bounds are cumulative across outputs', () => {
  const budget = new OutputBudget({ nodes: 3 });
  validate(svg('<g/>'), 'svg', budget);
  assert.throws(() => validate(svg('<g/>'), 'svg', budget), error => error.code === 'validated_nodes_limit');
  assert.throws(() => validate(svg('<g fill="none"/>'), 'svg', new OutputBudget({ attributes: 1 })), error => error.code === 'validated_attributes_limit');
});
test('large token refused before XML parsing and deep tree before AST construction', () => {
  assert.throws(() => validate(svg('<g/>'), 'svg', new OutputBudget({ bytes: 5 })), error => error.code === 'validated_bytes_limit');
  fail(svg('<g>'.repeat(64) + '</g>'.repeat(64)), 'svg', 'validated_depth_limit');
});
test('budgets and identity cannot be raised or injected', () => {
  assert.throws(() => new OutputBudget({ nodes: 6001 }), error => error.code === 'invalid_output_limit');
  assert.throws(() => validateOutput(svg(''), 'svg', 'bad:id', new OutputBudget()), error => error.code === 'invalid_output_input');
});
test('rewritten identity growth counts against the aggregate byte bound', () => {
  const xml = svg('<g id="mjx-eqn:1"/>');
  assert.throws(() => validateOutput(xml, 'svg', 'proof-' + 'a'.repeat(60), new OutputBudget({ bytes: Buffer.byteLength(xml) })),
    error => error.code === 'validated_bytes_limit');
});
