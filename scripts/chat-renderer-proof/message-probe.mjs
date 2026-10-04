import { renderMessage, messageCSS } from './message.mjs';
let consumed = false;
function run(fixture) {
  if (consumed) return { code: 'realm_consumed', stage: 'admission', converted: false };
  consumed = true;
  try {
    const result = renderMessage(fixture.source, { document, scope: 'proof-message',
      lowerLimits: fixture.lowerLimits, lowerOutputLimits: fixture.lowerOutputLimits });
    if (!result.root) return { code: result.code, stage: result.stage, converted: false };
    const style = document.createElement('style'); style.textContent = messageCSS; document.head.append(style);
    document.body.replaceChildren(result.root);
    const range = document.createRange(); range.selectNodeContents(result.root);
    const selected = range.collapsed ? '' : result.selection(range);
    const exactCopy = result.copy() === fixture.source;
    const expectedEquations = fixture.equations ?? [];
    const exactEquations = result.equations.length === expectedEquations.length && result.equations.every((equation, index) =>
      result.copyEquation(equation.id) === expectedEquations[index]);
    const fullSelection = selected === (fixture.fallback ? fixture.source : fixture.selection);
    let equationSelection = true, textSelection = true, mixedSelection = true, scalarBoundaries = true;
    for (const equation of result.equations) {
      range.selectNode(equation.node);
      equationSelection &&= result.selection(range) === equation.latex;
      const glyph = equation.node.querySelector('path') ?? equation.node.querySelector('svg');
      range.selectNode(glyph);
      equationSelection &&= result.selection(range) === equation.latex;
      range.selectNodeContents(equation.node.querySelector('math'));
      equationSelection &&= result.selection(range) === equation.latex;
    }
    for (const segment of result.segments.filter(item => item.kind === 'text' && item.text.length >= 2)) {
      const scalars = Array.from(segment.text);
      if (scalars.length >= 2) {
        const start = scalars[0].length, end = segment.text.length - scalars.at(-1).length;
        range.setStart(segment.node, start); range.setEnd(segment.node, end);
        textSelection &&= result.selection(range) === (range.collapsed ? null : segment.text.slice(start, end));
      }
      let offset = 0;
      for (const scalar of scalars) {
        if (scalar.length === 2) {
          range.setStart(segment.node, offset + 1); range.setEnd(segment.node, offset + 2);
          scalarBoundaries &&= result.selection(range) === null;
          range.setStart(segment.node, offset); range.setEnd(segment.node, offset + 1);
          scalarBoundaries &&= result.selection(range) === null;
        }
        offset += scalar.length;
      }
    }
    if (result.equations.length >= 2) {
      const first = result.equations[0], last = result.equations.at(-1);
      range.setStart(first.node, 0); range.setEnd(last.node, last.node.childNodes.length);
      const firstIndex = result.segments.indexOf(first), lastIndex = result.segments.indexOf(last);
      mixedSelection = result.selection(range) === result.segments.slice(firstIndex, lastIndex + 1).map(item => item.text ?? item.latex).join('');
    }
    // A boundary touching the next equation does not include its source.
    let edgeSelection = true;
    const firstText = result.segments[0];
    if (firstText?.kind === 'text' && result.segments[1]?.kind === 'equation') {
      range.setStart(firstText.node, 0); range.setEnd(result.root, 1);
      edgeSelection = result.selection(range) === firstText.text;
    }
    range.selectNode(result.root); const outsideRejected = result.selection(range) === null;
    range.selectNodeContents(result.root); range.collapse(true); const collapsedRejected = result.selection(range) === null;
    const ids = [...result.root.querySelectorAll('[id]')].map(node => node.id);
    const uniqueIDs = new Set(ids).size === ids.length && ids.every(id => /^proof-message-e\d+(?:-(?:svg|mathml)-\d+)?$/.test(id));
    const semanticOnce = result.root.querySelectorAll('math').length === expectedEquations.length
      && result.root.querySelectorAll('.proof-visual[aria-hidden="true"]').length === expectedEquations.length;
    const fallbackAtomic = !result.fallback || result.root.childNodes.length === 1
      && result.root.firstChild.nodeType === Node.TEXT_NODE && result.root.textContent === fixture.source;
    let horizontalReachable = true;
    if (fixture.horizontal) {
      const visual = result.root.querySelector('.proof-visual');
      if (!visual || visual.scrollWidth <= visual.clientWidth) horizontalReachable = false;
      else {
        visual.scrollLeft = visual.scrollWidth;
        horizontalReachable = visual.scrollLeft > 0 && Math.abs(visual.scrollWidth - visual.clientWidth - visual.scrollLeft) <= 1;
        visual.scrollLeft = 0;
      }
    }
    const widthContained = result.root.scrollWidth <= result.root.clientWidth + 1;
    const nestedViewports = [...result.root.querySelectorAll('g[data-mml-node="mtable"] > g > svg')];
    const nestedOverflow = nestedViewports.every(node => getComputedStyle(node).overflow === 'visible')
      && (!fixture.labeled || nestedViewports.length > 0);
    const passed = exactCopy && exactEquations && fullSelection && equationSelection && textSelection && mixedSelection
      && edgeSelection && scalarBoundaries && outsideRejected && collapsedRejected && uniqueIDs && semanticOnce && fallbackAtomic
      && horizontalReachable && widthContained && nestedOverflow;
    return { code: passed ? result.code : 'message_verification_failed', componentCode: result.code, stage: result.stage, converted: !result.fallback,
      fallback: result.fallback, equations: result.equations.length, exactCopy, exactEquations, fullSelection,
      equationSelection, textSelection, mixedSelection, edgeSelection, scalarBoundaries, outsideRejected, collapsedRejected,
      uniqueIDs, semanticOnce, fallbackAtomic, horizontalReachable, widthContained, nestedOverflow,
      counts: result.counts ?? null, outputCounts: result.outputCounts ?? null };
  } catch { return { code: 'probe_internal_error', stage: 'verification', converted: false }; }
}
globalThis.ChatMessageProof = Object.freeze({ run });
