# The equation view (2026-10-15)

Owner: "when you click on an equation, you can enter a custom view next to Explain in Chat that allows you to see the
equations much more clearly. You can update the size of the equation, with an optional horizontal scroll option. And
in addition each parameter or symbol is clearly described below. The description can also use AI in case some symbols
are not described fully in the paper. There should be an option to seek more background below, as optional, to help
users understand the equation. It should reuse the same cache as chat. There should be an easy link from that UX to
the chat."

## Where it opens

Tapping an equation already selects it and offers Explain in Chat, Why it matters, Related papers. A new action,
**Equation** (`function` symbol on Apple), sits right after Explain in Chat and opens the view; the others are unchanged
and keep their order. The browser's selection bar gains the same button, in the same place, when the selection is one
equation.

## What it shows, top to bottom

1. **The equation, large.** The reader's own rendering of that equation (its MathML, or the formula image a device-PDF
   bundle holds), in the reader's colours. A size control (A− / A+, 100 % to 400 % of the reader's text size, starting
   at 160 %) and a **Scroll sideways** toggle: off, the equation is scaled down to fit the width when it is wider; on,
   it keeps the chosen size and scrolls horizontally. The equation number, when it has one, stays beside it.
   Right under it, side by side: **Explain** (prominent, a sparkle) and **Ask in chat** (owner, build 59: "The AI
   explanation should only come if you ask for it… When you enter in there, you should also see the Ask in chat option
   as well"). Nothing is asked of the AI on opening; Explain goes once the explanation is there (or kept from before).
   No credit counts are shown anywhere in the view ("Don't display the number of credits in the response please").
2. **What it says** (after Explain): the one- or two-sentence summary.
3. **Symbols**: one row per symbol, in order of appearance: the symbol (plain Unicode text as the model wrote it,
   e.g. `π_θ(y|x)`), its meaning, and where that comes from — **From the paper ¶N** (a link: closes the view and
   scrolls the reader to that paragraph, with Back to return), or **General meaning** (the paper does not define it;
   worded as usual usage). While the request runs the rows show a quiet loading state; a failure shows the reason and
   Try again.
4. **More background** (a button, offered once the explanation is there; optional, never automatic): streams a short explainer under it (what problem the
   equation solves, the intuition per term, prerequisite concepts, a small example), rendered like a chat answer with
   its `[¶N]` citations working.
5. **Ask in chat** (beside Explain from the start): closes the view and opens the paper's chat with this equation as the selected passage and the
   composer focused, so the reader types their own question (no answer is sent automatically). Explain in Chat stays in
   the tap menu as before.

The view is a sheet on iPhone (large detent), a sheet or inspector-width panel on iPad and Mac, and a right-side dialog
in the browser; Escape / Done closes it.

## The requests: chat actions on the chat's cache

Both are ordinary chat requests (`POST /functions/v1/chat`, hold → answer → settle, credits shown after) with:

| field | value |
|---|---|
| `mode` | `paper` |
| `local_context` | the paper on the device, `reader-local-context-v2` (numbered `[¶N]`), exactly as chat sends it |
| `selection.quote` | the equation's LaTeX (`data-latex`), else its text |
| `messages` | one user turn: `Equation (4)` (its number) or `Equation` |
| `action` | `equation` (symbols) or `equation_background` |
| `profile`, `capabilities`, `consent_version` | the reader's chat defaults and this device's capabilities, as its chat would send them |
| `topic_title`, `follow_ups`, `figures` | absent (rejected) |

The server keeps the chat's prefix byte-identical — same model, tools, shared instructions and cached paper — and puts
only the action's own instructions after the paper, so an equation request right after chatting reads the paper from
the prompt cache, and chatting after the equation view does too (`tests/backend/chat.test.ts`). `equation` holds the
model's text back, checks it (`chat-equation.ts`) and relays one event:

```
event: equation
data: {"format":"equation-symbols-v1","summary":"…","symbols":[{"symbol":"β","latex":"\\beta","meaning":"…","source":"paper","paragraph":2},
       {"symbol":"σ","meaning":"…","source":"general"}]}
```

then `done` (credits). A paragraph number outside the paper turns the symbol into `general`. When the model wrote no
usable JSON the words come as one `delta` instead: show them as the description. `equation_background` streams
`delta`s like any answer, then `done`. No tool result is relayed for either.

## On the device

Results are kept on the device per paper revision (manifest), equation id, action and chat profile (model, effort,
length: a different length writes a different background), in the app's cache (not synced, not in chat history):
reopening an equation shows them without a new request. Apple apps: sealed with the account's local key in
`<environment>/<account>/equation-answers` (complete file protection, excluded from backup, at most 400;
`EquationResultStore`). Since build 59 (apps) and the browser of 2026-10-16, the symbols request starts only on
Explain and background only on its button; until 2026-10-16 the symbols were asked as the view opened. Nothing is
sent without chat consent: Explain asks for it first, as chat does.

## Contents › Equations and Your assets (apps, owner build 62)

- **Rows** name each display equation as printed, "Equation (4)", or, without a number, by its section: "Equation ·
  3.2 Method" (`PaperContentsSheet.label`, the heading last seen before its block). No flattened LaTeX under it
  (owner: "remove the equation text from this view and instead put Equation 1, Equation 2"). A row goes to the
  equation in the paper with Back.
- **View as tiles** (as Figures has): one web page (`EquationTilesView`), not a web view per tile, with the bundle's
  own stylesheet and each equation's element from the page (`EquationMarkup.element`): a grid of tiles named by their
  number, each equation scaled down to its tile, light and dark. Page scripts are off; a layout script in its own world
  fits the equations and posts a tapped tile's id, which goes where its row goes.
- **Your assets › Equation explanations / Figure explanations**: a kept answer (`EquationAnswer`, `FigureAnswer`)
  carries its `ExplanationSubject` (paper id and title, bundle manifest, equation or figure id, its label, the action,
  when), sealed inside the answer like the rest; file names still name nothing. `EquationResultStore.all(as:)` opens
  every file by its own name. Settings lists each equation or figure once, newest first, "None" when empty; a row opens
  the paper (`ReaderModel.openExplanation`) and then its equation view or figure page, where the kept answer shows
  without a request. A paper no longer in the library on this device says so; a paper prepared again since (a new
  bundle without that id) asks to explain it again. Answers kept before this change have no subject and aren't listed.

## Proof

- Server: `tests/backend/chat.test.ts` (validation, identical cached prefix, checked symbols, fallback, background).
- Live: `node scripts/chat-live-smoke.mjs --equation` on DPO's loss.
- Apps: a fixture mode `--chat-fixture-mode=equation` and a journey that opens the view from a tapped equation.
- Browser: `e2e/equation-view.spec.ts` against the fixture backend's `equation` event.
