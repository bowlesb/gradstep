# The equation view (2026-10-15)

## Streamed explanation with a progress bar, symbols at low effort — 2026-10-22 (server on staging; apps and browser local, not released)

Owner, 2026-10-22: "overall, the equations AI explainer needs the same progress with the progress bar." The view is
unchanged (the equation large, what it says, each symbol with its source, background on request); the symbols now arrive
one by one under the same progress bar as the figure walkthrough (FIGURE_VIEW.md "Speed"), and sooner. Decision record:
[DECISIONS](../DECISIONS.md#equation-explainer-streamed-figure-parts-full-screen-on-touch-owner-request-2026-10-22-agent-decisions-with-evidence-reversible).

**Server (`chat-equation.ts`, `chat.ts`, new `json-list-stream.ts`; staging, chat function deployed 2026-10-22 04:46 UTC
after encrypted backup `.artifacts/backups/20261022T044455Z-d8a4cfd1ad90`; deploy suite 19 pass / 0 fail; the study-mode build deployed at 05:12 UTC carries it, and the 05:58 UTC deploy — that build plus the Gemini figures default, after backup `.artifacts/backups/20261022T055356Z-4a3671a898cc` — still streams, read back live).**
- `EQUATION_INSTRUCTIONS` ask for the count first: `{"count": N, "summary": "…", "symbols": [{…}, …]}`, each symbol whole
  before the next, JSON escaping spelled out. The reply's JSON is read as it is written by the reader the figure
  walkthrough now shares (`JsonListStream`: a character scanner keeping only open containers and keys; each value parsed
  from its own slice). Each symbol is checked by `equationSymbol`, the one check the final symbols use, so the streamed
  symbols are exactly the final ones (the final check now keeps the first 24 *usable* rows, as the stream does).
- **Events** (action `equation` only; builds that predate them ignore unknown events; the final `equation` is unchanged):
  ```
  event: equation_progress  data: {"stage":"reading"}                               (the model was asked)
  event: equation_progress  data: {"stage":"writing","characters":420,"symbols":9}  (≤ every 400 ms; symbols once announced)
  event: equation_summary   data: {"summary":"…"}
  event: equation_symbol    data: {"index":0,"symbol":{"symbol":"β","latex":"\\beta","meaning":"…","source":"paper","paragraph":24}}
  …
  event: equation           data: {"format":"equation-symbols-v1","summary":"…","symbols":[…]}   (as before)
  event: done
  ```
  The final `equation` is the whole JSON when it parses, else the symbols that streamed (cut off at its allowance: `done
  {charged:false, reason:"limit"}`), so it never takes back a symbol the device was shown. A summary with no symbol and
  then unreadable JSON delivers nothing and is not charged. Logs add `streamed` and `first_symbol_ms`.
- **Low effort for the symbols** (`equation` only; `equation_background` keeps the chat's effort) when the reader chose
  Gemini Flash or an automatic effort; an effort chosen for a Claude model stays (the figure view's rule). Gemini's
  allowance becomes 2,000 + 2,000 tokens.
- **Default model unchanged**: the equations activity still asks with the chat's default (Gemini Flash, recommended), so
  its requests read the paper the chat already cached; Sonnet at low was as fast but writes its own cache on a paper first
  (~$0.23 on DPO). Evidence below.

**Clients (iPhone/iPad/Mac one SwiftUI path, and the browser; local source, not released).** The three events are parsed
(malformed ones dropped, never fatal; each symbol through the same per-row check as `equation`). The summary shows when it
arrives and each symbol row is appended in order; the final `equation` replaces what streamed and is the only thing kept
(sealed store / session memory, as before). An error drops what streamed and shows the existing failure with Try again; a
`done` without a final `equation` keeps the streamed symbols when there is at least one; cut off at its length the symbols
stay with "Not charged" (apps: "This explanation stopped before the end. Not charged."; browser: "Interrupted · not
charged"). The local Mac model is unchanged (its words stream as before).
- **Progress bar** — the figure walkthrough's bar and rules (one component per client: `FigureProgressBar`,
  `ExplainerProgress.tsx`), driven by `FigureProgress.state(_:kind: .equation)` / `equationProgress`
  (`equation-progress.ts`), fixture `tests/fixtures/equation-progress.json` reproduced by both clients. Stages: "Preparing
  the equation…", "Reading the equation…", "Writing the summary…", then "Explaining symbol k of N…" only once the model
  has announced N, else "Explaining symbol k…". Determinate only while N is known and not exceeded (10 % for the summary,
  each symbol's share filled by its characters against a measured 200, capped at 90 %); never backwards, indeterminate
  past N, never a made-up 99 %. Shown at once with placeholders (summary lines, symbol rows in the symbols' card) where
  the explanation will appear; then below the last row shown (nothing above it moves); fades at the end. One
  accessibility element (label = stage, value = percent when determinate); VoiceOver / `aria-live="polite"` announce
  stage changes only; under Reduce Motion nothing pulses or fades.
- **Older servers** (only `equation`): Preparing → Reading → all symbols at once.
- **Fixtures:** the apps' `--chat-fixture-mode=equation` streams (`--equation-fixture-step-ms=<n>`,
  `--equation-fixture-old-server`); the browser fixture backend's `equationStream` (fast, slow, step, old, error, cut).

**Measured.** Model alone (`node scripts/equation-speed.mjs --equation=6|7 --configs=…`: the server's own request through the
production adapter, straight to OpenRouter; DPO's loss, Eq. 7, and its gradient; cache read unless noted), seconds from
sending:

| Equation | Configuration | First token | Summary | Whole | Out (reasoning) | Symbols | Cost |
|---|---|---|---|---|---|---|---|
| Loss | Gemini medium (cache write) | 16.7 | 22.8 | 26.2 | 1,494 (898) | 10 | $0.0110 |
| Loss | Gemini medium | 2.2 / 3.4 | 2.7 / 8.3 | 6.5 / 12.2 | 683–1,436 (0–782) | 11 | $0.0062–0.0093 |
| Loss | **Gemini low** | 4.7 (one run queued 49 s) | 5.3 | 8.2 | 582–606 | 9 | $0.0059 |
| Loss | Sonnet low (cache write / read) | 2.1 / 1.6 | 2.9 / 2.6 | 7.2 / 7.4 | 987–1,067 | 10–11 | $0.2287 / $0.0193 |
| Gradient | Gemini medium | 3.5 | 9.0 | 12.8 | 1,528 (795) | 12 | $0.0098 |
| Gradient | **Gemini low** | 4.1 | 4.5 | 8.3 | 714 | 11 | $0.0064 |
| Gradient | Sonnet low | 2.2 | 3.0 | 8.4 | 1,174 | 11 | $0.0207 |

Quality side by side (records `.artifacts/equation-speed/*-eq7.json`): all three listed the same symbols with the same
paragraphs ([¶18]–[¶38]); Gemini low cited the paper for 11 of 11, medium 10 of 12; Sonnet low also explained the
per-example weight. Every run's streamed symbols equalled its final symbols.

Through the deployed function on staging (`node scripts/chat-live-smoke.mjs --equation=symbols --equation-runs=2
--profile=…`; disposable accounts; DPO's loss), seconds from the request:

| | Profile (as sent → served) | First visible | First symbol | Whole | Credits |
|---|---|---|---|---|---|
| Before (held back) | `gemini-medium-standard` (the default) | 12.3 / 9.3 (all at once) | 12.3 / 9.3 | 12.3 / 9.3 | 2 / 2 |
| After | `gemini-medium-standard` → `gemini-low-standard` | 5.6 / 2.9 (summary) | 6.0 / 3.3 | 8.8 / 6.5 | 2 / 2 |
| After | `sonnet-low-standard` (cache write / read) | 3.6 / 3.0 | 4.3 / 3.9 | 7.7 / 7.9 | 45 / 4 |

"Reading" shows 0.7–0.9 s after the request. Records: `.artifacts/equation-speed/live-*.json`. Spend for this work: $0.32
direct (ledger `.artifacts/equation-speed/spend.json`) and ~$0.55 on staging (two Sonnet cache writes, $0.23 each: one measured, one a verification run sent without `--profile`, which asks with Sonnet); about
$0.87 in all, within the $1 allowed.

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

Tapping an equation already selects it and offers Chat about Equation, Why it matters, Related papers. **Focus**
(`arrow.up.left.and.arrow.down.right` on Apple; owner, build 78: "Let's change AI explainer to Focus. Because in the
first view you can see the equation up large which is helpful. In the next screen we should not necessarily assume they
need an AI explainer"; it was **AI Explainer** from build 62, and **Equation** before that) sits right after Chat about
Equation and opens the view with the equation large, asking nothing: its top row's **AI Explainer** asks (the model
choice and the chat's consent come first). The others are unchanged and keep their order. The browser's selection bar
has the same button, in the same place, when the selection is one equation.

## What it shows, top to bottom

1. **The equation, large.** The reader's own rendering of that equation (its MathML, or the formula image a device-PDF
   bundle holds), in the reader's colours. A size control (A− / A+, 100 % to 400 % of the reader's text size, starting
   at 160 %) and a **Scroll sideways** toggle: off, the equation is scaled down to fit the width when it is wider; on,
   it keeps the chosen size and scrolls horizontally. The equation number, when it has one, stays beside it.
   **The top row** (owner, build 78; DESIGN.md "Sheet top row"): one glass row of words, **Snippet**, **Chat** (to the
   conversation below) and **AI Explainer**, alike; no title, no Done, no "…", and no X on a touch screen (the sheet
   swipes away; the Mac and the browser keep the X). AI Explainer shows until the explanation is asked for. Above the equation its
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

## Build-69 feedback, 2026-10-18 (TestFlight 70 and browser deployed)

The equation menu starts with **Chat about Equation**, then **AI Explainer** (since build 78: **Focus**, which opens
the view without a generation like Chat about Equation; the view's AI Explainer asks), then Related. Chat about Equation
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
The Mac journey passes (32.38 s): click the equation, select AI Explainer, render its answer, and close the view.
The iPad wide-equation journey also passes; evidence is in `native-mac-7.xcresult` and `native-ipad-final.xcresult`
under `.artifacts/feedback/all-20261018/`.
