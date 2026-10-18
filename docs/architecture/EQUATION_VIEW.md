# The equation view (2026-10-15)

Native Local AI prototype (2026-10-17, TestFlight 68): AI Explainer first offers Cloud AI / Local AI. Local sends the exact selected LaTeX and bounded numbered excerpts to MLX, with ordinary formatted prose in the existing explanation view. Local answers have separate model/revision cache keys; saved assets restore that choice. See [LOCAL_AI.md](LOCAL_AI.md).

Build 68 feedback, 2026-10-17: screenshot `AG-KC-bgu7HdtwNQhuQ1LBk` identifies 1805.03662v2, 105 display equations.
The markup scanner lowercased the entire remaining HTML at every opening tag, then repeated that for every equation.
Optimized standalone DPO replay took 23.90 seconds for only 32 equations; the reported paper exceeded a 90-second
timeout. The repaired bulk pass extracts all 105 fragments from the same 730,131-byte page in 0.0417 seconds. Compare only the current tag name and
advance through equation IDs in page order; cancellation must stop abandoned tab work. Retain complete MathML,
formula images, numbers and existing navigation. Before release, verify the reported paper in the actual Contents
sheet, not only a one-equation fixture. The cloud choice must also name/select the actual model in the explainer,
refresh its provider table before use and keep a change-model action available after failure. Billing failure copy
must say the provider account ran out of funds and distinguish it from the reader's own credits.
The actual reported-paper Simulator journey now passes (iPhone 17 Pro, iOS 26.4, release optimization): load the
list, switch tabs, select a row and reopen Contents. Core's long-Unicode-tail regression preserves all 105 complete
MathML fragments and rejects a recurrence of the slow scan. Native build 69 is available in TestFlight on iOS
and Mac (both VALID / IN_BETA_TESTING, 23:46:40 UTC). The source-matching import/session gate passes 13/13 with zero skips.
The cloud failure/recovery journey also passes: cause displayed, model changed in place, successful structured
answer naming the serving model. Evidence: `.artifacts/equations-feedback-20261017/`.
The chooser names and selects the cloud model, waits for the published table and keeps Local AI available. Failed
equation/figure requests offer Change AI in place. Saved cloud answers display the model that wrote them when known,
not a newly selected default. Claude chat/explainer routing is documented in [the funded route](GEMINI_FLASH_CHAT.md).

Release update, 2026-10-16: the build-62 top row, heading menu, equation tiles and saved-explanation lists are in
TestFlight 63 and browser Pages `836089d4`. Platform processing and verification evidence are recorded in
[IMPLEMENTATION_STATUS.md](../IMPLEMENTATION_STATUS.md#claude-takeover-and-build-63-release--2026-10-16-2000-utc).

Owner: "when you click on an equation, you can enter a custom view next to Explain in Chat that allows you to see the
equations much more clearly. You can update the size of the equation, with an optional horizontal scroll option. And
in addition each parameter or symbol is clearly described below. The description can also use AI in case some symbols
are not described fully in the paper. There should be an option to seek more background below, as optional, to help
users understand the equation. It should reuse the same cache as chat. There should be an easy link from that UX to
the chat."

## Where it opens

Tapping an equation already selects it and offers Explain in Chat, Why it matters, Related papers. A new action,
**AI Explainer** (`sparkles` on Apple; it was **Equation** until build 62: owner, "Replace Explain with AI Explainer"),
sits right after Explain in Chat and opens the view explaining the equation at once (choosing it is the request; the
chat's consent comes first). The others are unchanged and keep their order. The browser's selection bar gains the same
button, in the same place, when the selection is one equation.

## What it shows, top to bottom

1. **The equation, large.** The reader's own rendering of that equation (its MathML, or the formula image a device-PDF
   bundle holds), in the reader's colours. A size control (A− / A+, 100 % to 400 % of the reader's text size, starting
   at 160 %) and a **Scroll sideways** toggle: off, the equation is scaled down to fit the width when it is wider; on,
   it keeps the chosen size and scrolls horizontally. The equation number, when it has one, stays beside it.
   **The top row** (owner, build 62; DESIGN.md "Sheet top row"): one glass row, **Explain in Chat** and **AI Explainer**
   (tinted) as glass capsules in its middle, a round **X** on the right; no title, no Done. AI Explainer shows until the explanation
   is asked for (from the menu it is asked at once, so the row is Explain in Chat and the X). Above the equation its
   name is a small menu, **Equation (4) ⌄**, listing the paper's display equations ("Equation · section" for an
   unnumbered one): choosing one shows it, with its kept explanation or AI Explainer (nothing is asked unasked).
   With one display equation the heading is the plain name.
   No credit counts are shown anywhere in the view ("Don't display the number of credits in the response please").
2. **What it says** (once explained): the one- or two-sentence summary.
3. **Symbols**: one row per symbol, in order of appearance: the symbol (plain Unicode text as the model wrote it,
   e.g. `π_θ(y|x)`), its meaning, and where that comes from — **From the paper ¶N** (a link: closes the view and
   scrolls the reader to that paragraph, with Back to return), or **General meaning** (the paper does not define it;
   worded as usual usage). While the request runs the rows show a quiet loading state; a failure shows the reason and
   Try again.
4. **More background** (a button, offered once the explanation is there; optional, never automatic): streams a short explainer under it (what problem the
   equation solves, the intuition per term, prerequisite concepts, a small example), rendered like a chat answer with
   its `[¶N]` citations working.
5. **Explain in Chat** (the top row, from the start; it was "Ask in chat"): closes the view and opens the paper's chat
   with this equation as the selected passage and the composer focused, so the reader types their own question (no
   answer is sent automatically). Explain in Chat stays in the tap menu as before.

The view is a sheet on iPhone (large detent), a sheet or inspector-width panel on iPad and Mac, and a right-side dialog
in the browser; Escape, ⌘W or the X closes it.

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
usable JSON, genuine prose comes as one `delta` instead: show it as the description. Broken or truncated JSON is
not displayed or charged as an explanation. `equation_background` streams
`delta`s like any answer, then `done`. No tool result is relayed for either.

Flash rollout, 2026-10-17: the live DPO symbols request exhausted the old 2,000-token output cap during reasoning
and returned incomplete JSON. The customer was charged zero; the provider cost was $0.011894. Flash now adds the
profile's 4,000-token medium reasoning allowance to the 2,000 answer tokens, in both the request and durable quote.
The repeated symbols-only request completed with 11 symbols and 3,762 output/reasoning tokens, $0.017083 recorded
cost, four credits. Its 34,391-token paper prefix was cached. Regression checks cover the quote, shared prefix,
and no display/charge for malformed JSON even if the provider says `end_turn`. Other models' caps are unchanged.

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

## Build-69 feedback, 2026-10-18 (implementation; release checks pending)

The equation menu starts with **Chat about Equation**, then **AI Explainer**, then Related. Chat about Equation
opens this view without a generation; AI Explainer chooses the engine and requests the structured explanation.
The conversation composer and answers are below that explanation, in the same view. Its actual model name opens
the default/cloud/local choice. There is no top Explain in Chat action that discards the view for the main chat.
Every follow-up includes the original LaTeX and a bounded earlier explanation explicitly labeled as fallible AI
output. The encrypted conversation anchor identifies the paper manifest and equation; reopening resumes it, and
the main chat's earlier draft is restored when the sheet closes. Account retirement fences late view callbacks.

Equation sizing fits at 100% once, then applies zoom; fitting the enlarged width had cancelled zoom on wide math.
Minus, plus and percent remain; overflow scrolls horizontally without a separate switch. Native WebKit and
browser journeys verify actual overflow, not merely a changing percentage. The paper equation menu has one
**Copy as Text** action containing the full LaTeX, with no duplicate Copy LaTeX or Why it matters.

The conversation viewport and its composer are separate children inside the navigation stack. An outer
`safeAreaInset` let the scroll view extend behind the keyboard/composer; a completed answer could be present
but covered. The conversation follows both content and viewport height changes, including attributed-text layout
after the last stream event, while a reader’s manual scroll disables following until the next turn. Acceptance
waits for the second completed assistant answer and checks its visible frame above the composer.

The wide-layout acceptance also exposed a Mac-specific defect: `presentEditMenu(with:)` logs that it is not
supported in Catalyst’s Mac idiom, so clicking an equation produced no actions. The Mac path presents the same
`UIMenu` using a menu control’s public primary action; macOS 14.0–14.3 retains an anchored action sheet.
References use the same repaired presenter. iPhone/iPad retain `UIEditMenuInteraction`. Sources:
[Apple’s editing-interaction documentation](https://developer.apple.com/videos/play/wwdc2022/10071/),
[`performPrimaryAction`](https://developer.apple.com/documentation/uikit/uicontrol/performprimaryaction()).
The Mac journey must click the equation, select AI Explainer, render its answer, and close the view.
