// Authored public test strings only. Never point these harnesses at user history.
export const fixtures = [
  { id: 'attention-environment', source: String.raw`\begin{equation}\label{eq:attention}\operatorname{Attention}(Q,K,V)=\operatorname{softmax}\!\left(\frac{QK^{\mathsf T}}{\sqrt{d_k}}\right)V\end{equation}`, expected: 'ok', labeled: true },
  { id: 'align', source: String.raw`\begin{align}x&=1\\y&=2\end{align}`, expected: 'ok', labeled: true },
  { id: 'equation-star', source: String.raw`\begin{equation*}x+1\end{equation*}`, expected: 'ok' },
  { id: 'inline-fraction', source: String.raw`\frac{x_1}{\sqrt{d_k}}`, display: false, expected: 'ok' },
  { id: 'matrix', source: String.raw`\begin{pmatrix}a&b\\c&d\end{pmatrix}`, expected: 'ok' },
  { id: 'macro-owner', source: String.raw`\newcommand{\proofprivate}{x}\proofprivate`, expected: 'ok' },
  { id: 'fresh-macro-absent', source: String.raw`\proofprivate`, expected: 'tex_error' },
  { id: 'unsupported-require', source: String.raw`\require{html}\href{https://example.invalid/private}{x}`, expected: 'tex_error' },
  { id: 'unsupported-href', source: String.raw`\href{https://example.invalid/private}{x}`, expected: 'tex_error' },
  { id: 'unsupported-image', source: String.raw`\includegraphics{https://example.invalid/private}`, expected: 'tex_error' },
  { id: 'unsupported-style', source: String.raw`\style{display:none}{x}`, expected: 'tex_error' },
  { id: 'expansion-loop', source: String.raw`\def\proofloop{\proofloop}\proofloop`, expected: 'expansion_limit' },
  // Previously generated 13.3 MB of SVG before the post-output rejection. The
  // exact same authored case must now stop at the MML factory, before SVG work.
  { id: 'expansion-before-svg', source: String.raw`\def\b{` + 'x'.repeat(256) + String.raw`}\def\a{` + String.raw`\b`.repeat(70) + String.raw`}\a`, expected: 'mmlNodes_limit', expectedStage: 'compile' },
  { id: 'mml-small-budget', source: 'x+y', lowerLimits: { mmlNodes: 4 }, expected: 'mmlNodes_limit', expectedStage: 'compile' },
  { id: 'mml-text-small-budget', source: String.raw`\text{example}`, lowerLimits: { mmlTextBytes: 3 }, expected: 'mmlTextBytes_limit', expectedStage: 'compile' },
  { id: 'svg-small-budget', source: String.raw`\frac{x}{y}`, lowerLimits: { liteNodes: 12 }, expected: 'liteNodes_limit', expectedStage: 'svg' },
  { id: 'output-small-budget', source: String.raw`\frac{x}{y}`, lowerLimits: { outputEstimate: 1200 }, expected: 'outputEstimate_limit', expectedStage: 'svg' },
  { id: 'source-before-conversion', source: 'x'.repeat(12289), expected: 'source_limit', expectedStage: 'admission' },
];
