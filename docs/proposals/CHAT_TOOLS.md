# Chat tools: HTML answers, Mermaid diagrams, figure crops — proposal (2026-10-15)

Owner, build 42: "The chat needs a html tool. It should be very capable of creating flow charts or other htmls to
explain where it applies, and actually useful. It should also be able to create mermaid diagrams. There should also
be an option for the users to disable these chat features if they wish." And: "the agent has the ability to break
figures into cropped sub sections as part of the response and explain each component."

## What exists

- The chat already renders Mermaid diagrams the model asks for (`ChatDiagramLink`, `mermaid.min.js` bundled on
  the device; the browser's diagram frame), inside the answer's transcript.
- The reader bundle holds every figure as an admitted raster (`assets/<sha>.png|jpg`) with its index entry
  (`figures[]`: block, caption, alt); the chat's paper context cites blocks as `[¶N]`.

## Proposal

1. **HTML answers (`html` tool).** The model may return one HTML document per answer (bounded: 64 KB, no script,
   no external resources, inline CSS only), rendered in a sandboxed frame with the same Content-Security-Policy
   discipline as the reader (`default-src 'none'; style-src 'unsafe-inline'`), sized to its content, with
   "Open full screen" and "Copy". The validator is the reader's own HTML vocabulary extended with layout elements
   (`div`, `table`, `svg` without script or foreign objects), so an answer can draw a flow chart as SVG or a table.
   Where it applies: a step-by-step pipeline, a comparison table, a timeline, a decision tree. The system prompt says
   when a visual helps and when prose is better; the answer still carries prose and `[¶N]` citations.
2. **Mermaid.** Keep the existing path; let the `html` answer embed a Mermaid block (rendered on the device by the
   bundled renderer, never by the frame's own script) so a flow chart and its explanation live together.
3. **Setting: "Visual answers".** Per account (synced private state, like the chat profile): On (default), Off
   (prose only; the tools are not offered to the model). Shown in Settings → Chat and in the chat's model menu.
4. **Figure crops.** A `figure_regions` tool: the model names a figure (`[¶N]` of its block) and regions as
   normalized boxes with a label each; the device crops the stored raster (Core Graphics / canvas), shows each crop
   with its explanation in the answer, and a tap opens the figure at that region. The model sees the figure itself
   only when the owner allows images to be sent (a second setting, "Send figures to the model", default Off on
   the private beta; the crops are then named by caption and the model's reading of the text). Cost: a figure
   image costs about 1,500 tokens at 1024 px; one figure per question by default.
5. **Quality gates.** Fragment tests for the HTML validator (script, external URL, oversized → refused); a recorded
   answer corpus of ten questions rendered on iPhone, iPad, Mac and the browser (visual audit); the spending
   controls unchanged (visual answers are the same model call; the figure image is the only extra cost).

## Order

Setting and HTML answers first (one week), figure crops after the image-sending consent is designed.
