import { tokenize, copyMessage, copyEquation } from './tokenizer.mjs';

let consumed = false;
function run(fixture) {
  if (consumed) return { code: 'realm_consumed', stage: 'admission', converted: false };
  consumed = true;
  try {
    const source = Array.isArray(fixture.sourceCodeUnits) ? String.fromCharCode(...fixture.sourceCodeUnits) : fixture.source;
    const result = tokenize(source);
    if (result.code !== 'ok') {
      return { code: Object.keys(result).length === 1 ? result.code : 'partial_refusal', stage: 'admission', converted: false };
    }
    const equations = result.equations;
    const exactCopy = copyMessage(result) === source;
    const exactEquations = equations.length === fixture.equations.length && equations.every((equation, index) =>
      equation.latex === fixture.equations[index] && copyEquation(result, equation.id) === fixture.equations[index]
      && (!fixture.starts || equation.raw.start === fixture.starts[index]));
    const unique = new Set(equations.map(item => item.id)).size === equations.length;
    const ordered = equations.every((item, index) => index === 0 || item.raw.start >= equations[index - 1].raw.end);
    const losslessParts = result.blocks.every(block => block.kind !== 'paragraph'
      || block.parts.map(part => result.source.slice(part.raw.start, part.raw.end)).join('')
        === result.source.slice(block.content.start, block.content.end));
    return { code: exactCopy && exactEquations && unique && ordered && losslessParts ? 'ok' : 'source_verification_failed',
      stage: 'complete', converted: false, equations: equations.length, blocks: result.blocks.length,
      exactCopy, exactEquations, unique, ordered, losslessParts };
  } catch { return { code: 'probe_internal_error', stage: 'verification', converted: false }; }
}
globalThis.ChatSourceProof = Object.freeze({ run });
