# The figure view: a walkthrough of a figure, on request (plan, 2026-10-16; server built on staging)

## Zoom out onto the page — 2026-10-24 (apps, branch `figure-zoom-out`; not released)

Owner, 2026-10-24: "in the on device model, when I click on an AI explainers for a figure, I should be able to zoom out
around it and see the actual pdf, that would compensate for an inadequate crop". Decision record:
[DECISIONS](../DECISIONS.md#figures-of-on-device-readings-zoom-out-onto-the-pdf-page-owner-request-2026-10-24-agent-decisions-reversible).

- **Where the crop is.** The on-device converter (port revision 10) adds `figures` to `provenance.json`: one row per
  shown figure, `[id, page (from 0), x0, y0, x1, y1, page width, page height]`, points from the top left of the page as
  shown (crop box turned by `/Rotate`). The image is exactly that rectangle at 150 dpi × the budget's scale.
  `DevicePDFReaderProvenance` reads the rows (a bad row is dropped, never the reading); `ReaderModel.figurePDFPage` finds
  the PDF on this device by the provenance's digest (`DevicePaperStore`); `FigureViewContext.pdfPage` carries both.
  Readings before revision 10, arXiv HTML readings, figures of several images and removed PDFs have none.
- **The canvas** (`FigurePageLayout`, `FigureZoomMath` in ScienceReaderCore, tested): the full-screen figure's canvas,
  in the figure's pixels, holds the page with the image exactly on its crop. Until the reader zooms out past the whole
  figure, the view is held to the figure on its white margin, which looks and pans as before.
- **Zooming out** below the whole figure's fit fades the page in around it; it is drawn then (once, off the main actor,
  with the same CoreGraphics drawing the route cut the crop from, at twice the screen's pixels for the fitted page, at
  least the figure's own density, at most 4,096 px a side) and released when full screen closes. The crop stays outlined
  thinly in the parts' outline colour; a part's own outline and veil behave as before. The zoom stops at the whole page;
  the page pans; a double tap (or the Show part / Whole figure control) returns to the figure and hides the page.
- **Ways in:** a pinch outwards in full screen; a small round control by the X (`doc.viewfinder`, "Show the whole page";
  `crop`, "Back to the figure"); VoiceOver actions of the same names; a pinch outwards on the explainer's card or on the
  figure page opens full screen straight onto the page (the figure page also has the VoiceOver action). The Mac's
  trackpad pinch does the same.
- **Not built:** continuing past the page's edge onto the neighbouring page.
- **Evidence:** `FigurePageZoomTests` (Core), `device-pdf.test.ts` (provenance rows), the opt-in journey
  `FigureViewJourneyTests.testZoomingOutOfAnOnDeviceFigureShowsItsPDFPage` on a real reading of 2305.18290v3 made by
  `DevicePDFRouteTool`, passed on the iPhone 17 Pro and iPad Pro 13-inch (M5) Simulators (iOS 26.4); screenshots
  `.artifacts/figure-zoom-out/`. On the iPad Simulator a synthesized pinch inside the full-screen cover reaches no
  gesture recognizer (the same pinch works on the iPhone Simulator, and on the iPad's card and figure page), so there the
  journey takes the page control; the pinch on an iPad itself is untested. A Mac journey was not run (Catalyst builds).
- **Also:** the card's pinch now opens full screen once the fingers have moved enough to tell its direction; the
  full screen's swipe down closes only for one finger.

## Full screen on touch — 2026-10-22 (apps and browser local, not released)

Owner, 2026-10-22: "I like the changes. The one issue is when you try to click into a subfigure and zoom. The transition
needs to be improved. My suggestion is that whenever you try to interact with it, it becomes a full screen thing, with the
outline fading away so you can see where the subfigure was in relation to the entire figure, but you can easily navigate,
using the entire full screen, the entire extent of the figure, with not really any in-between — because it's awkward to
navigate a small subfigure inside a figure without having the full screen at your disposal on a phone." Replaces "Parts as
viewports"' in-card pinch, pan, − / +, double-tap-to-frame and the fullscreen that opened on the frame and then widened.
Decision record: [DECISIONS](../DECISIONS.md#equation-explainer-streamed-figure-parts-full-screen-on-touch-owner-request-2026-10-22-agent-decisions-with-evidence-reversible).
No server, prompt, framing, storage or spend change.

- **The card never zooms.** A part's card (and, in the apps, the walkthrough's whole-figure card) shows its frame at rest,
  framed by confidence as before; the page scrolls over it. Any interaction opens the full-screen viewer at once (no
  double-tap wait): a tap or click, a double tap, a pinch (a second finger), a sideways drag (mostly horizontal; an up-or-down
  drag is the page's scroll), ⌃/⌘ + wheel (browser), Enter/Space on the focused card (browser), VoiceOver's activate (apps),
  or the **Full screen** button kept under the card.
- **One motion, from the card.** The viewer starts exactly where the card is, showing exactly what the card showed (the
  part's frame mapped onto the card's rectangle, clipped to it), and in one ~350 ms motion becomes the whole screen framed
  on the part, the backdrop fading in; the top row (the name, **Whole figure** / **Show part**, X) fades in with it. Apps:
  `FigureFullscreenStage` (UIKit, in FigureExplainView.swift) inside a `fullScreenCover` presented without the system's
  slide and with a clear background; browser: `FullscreenViewport` (ui/FigureViewport.tsx), a transformed layer clipped
  to the card's rectangle inside the modal `<dialog>`.
- **Then the outline fades.** The part's outline (and the soft veil) is visible as it opens and fades over about a second
  once it has opened, while the whole figure is already the reader's: drag pans, pinch zooms (browser also wheel and − / +,
  +/−/0 and arrow keys), the zoom running from the whole figure fitted to 8× that (at least 3× the part's own frame).
  **Double tap** (or the top row's control) toggles the whole figure and the part; going back to the part shows its outline
  again, then fades it.
- **Close** with X, Escape (or ⌘W on the Mac), the escape gesture (VoiceOver) or a swipe down at the top of the figure
  (touch): the same motion runs back onto the card's current place (the view returns to the card's framing as it shrinks),
  then the viewer goes; the page is where it was (browser: focus returns to the card).
- **Reduce Motion:** a short cross-fade in and out; the outline shows for a second, then disappears without a fade.
- **Mac:** the viewer stays a window-sized sheet (Catalyst), so it fades in framed on the part with the outline fading as
  above, without the motion from the card; X and Escape close it.
- **Local framing record** (`FigureFramingRecord` / `figure-framing-record.ts`, still never sent, stored or logged): adds
  `opened` (how the card was first opened: `tap`, `pinch`, `drag`, `double_tap`, `keyboard`, `button`, `accessibility`)
  and `opens` (how often); `expanded` is set with them; `finalView`, `zoomed` and `panned` now describe the full-screen
  view as last closed (the card itself no longer moves). A double tap on a card is recorded as `tap` in the apps (the first
  tap already opens it).
- **Unchanged:** framing by confidence, chat's figure parts (`FramedFigure` / `FramedPart.renderFrame`), Save snippet (what
  the card shows: its rest framing), the coverage note, the walkthrough's streaming and progress.
- **Evidence:** see IMPLEMENTATION_STATUS.md "Full screen on touch; equation explainer streamed". Screenshots
  `.artifacts/figure-fullscreen/web/` and `.artifacts/figure-fullscreen/native/`.

## Speed: a streamed walkthrough at low effort, with a progress bar — 2026-10-22 (server on staging; apps and browser local, not released)

Owner, 2026-10-22: "I like the experience, but it's very very slow. Can we make it much much faster?" and "it's unusable
at this speed. Also it needs a progress bar." The experience is unchanged (one walkthrough: summary, then part by part,
each part a confidence-framed viewport into the whole figure); it now arrives part by part, sooner, with a progress bar.
Decision record: [DECISIONS](../DECISIONS.md#figure-explainer-streamed-at-low-effort-owner-request-2026-10-22-agent-decision-with-evidence-reversible).

**Where the time went (measured before any change).** The server held the walkthrough back until the whole
`figure_walkthrough` call was written and checked, so nothing showed until the end, and the figures default (Gemini 3.8
Flash, which the profiles fix at medium effort) thought for up to 3,800 tokens first. Gemini also returns a tool call
**whole, in one chunk** at the end of its turn (OpenRouter, Vertex route; measured: 1 chunk of 3,400–5,400 characters),
so streaming the tool call's arguments alone could never show it sooner. Our own server stages are small: the request
reached the model 0.8–1.4 s after it was sent (authentication, admission, balance, the paper's membership, the hold,
the provider attempt) and the reader had `done` 0.2–0.4 s after the model finished. The image is about 1,600 of
37,000–49,000 input tokens (the paper, read from the chat's cache) and was left as it is (it is also what crops and
viewports are cut from).

**What changed (server, `chat.ts`, `chat-figure-view.ts`; deployed to staging 2026-10-22 02:17 UTC).**
- **Written as JSON in the reply.** `FIGURE_INSTRUCTIONS` ask for one JSON object in the reply — `{"parts": N, "summary":
  …, "sections": [{…}, …]}`, the tool's own fields after a count — instead of the tool call (every model streams reply
  text). The tool stays in the chat's tools (the cached prefix is unchanged, test) and a call is still accepted and also
  streamed (Claude streams tool arguments in ~10-character pieces). Escaping is asked for explicitly (`\\(`…`\\)` inside
  JSON strings); a code fence or words around the object are ignored.
- **Read incrementally** (`FigureWalkthroughStream`): a character scanner keeps the open containers and each object's key;
  the summary is relayed when its string closes and each part when its object closes, parsed from its own slice and
  checked by `figureSection` — the one check the final walkthrough uses, so the streamed parts are exactly the final
  parts. A malformed part is left out without swallowing the next one; a cut-off object keeps its complete parts.
- **Events** (action `figure` only; builds that predate them ignore unknown events, test of both parsers'
  `default` branches; the final `figure` event is unchanged):
  ```
  event: figure_progress   data: {"stage":"reading"}                              (the model was asked)
  event: figure_progress   data: {"stage":"writing","characters":615,"parts":4}   (≤ every 400 ms; parts once announced)
  event: figure_summary    data: {"summary":"…"}
  event: figure_section    data: {"index":0,"section":{"label":"(a)","title":"…","text":"…","paragraphs":[…],"box":{…}}}
  …
  event: figure            data: {"format":"figure-walkthrough-v1","summary":"…","sections":[…]}   (as before)
  event: done              data: {…,"profile":"gemini-low-standard","charged":true}
  ```
  The final walkthrough prefers the source that streamed (reply or call); when neither parses whole (cut off at its
  allowance, or a malformed later part) it is the parts that streamed, so `figure` never takes back a part the device
  was shown (cut off: `done {charged:false, reason:"limit"}` as before). An unreadable object is never shown as words.
  Logs add `source`, `streamed` and `first_part_ms` (counts and times only).
- **Low effort** (`figureViewEffort`) for `figure` and `figure_simpler` when the reader chose Gemini Flash or an automatic
  effort; an effort chosen for a Claude model stays. The profile, quote and `done.profile` say so
  (`gemini-low-standard`); `openRouterChatParams` now sends Gemini the request's effort (every chat profile still sends
  medium). The allowance is the walkthrough's 6,000 tokens plus low's thinking.
- **One round trip fewer:** the paper's membership is read alongside the price-card and balance checks.

**Clients (iPhone/iPad/Mac one SwiftUI path, and the browser; local source, not released).**
- **Progressive.** The three events are parsed (malformed ones dropped, never fatal; parts checked by the same per-part
  check as `figure`); the summary shows when it arrives and each part card is appended in order when it arrives, framed
  by confidence with the parts so far and **without the count check** (`countCheck: false`, new in `FigureFraming` /
  `figure-framing.ts`), which applies once the final `figure` gives the count. A card keeps the frame it was first shown
  with until the end; at the end the walkthrough is framed again and only a card whose framing changed is redrawn. The
  final `figure` replaces the streamed walkthrough and is the only thing kept (sealed store / session memory, as before).
  On an error the streamed parts are dropped and the existing failure with Try again shows; a walkthrough cut off at its
  allowance keeps its parts with "Not charged". Part menus work once the walkthrough is done. The coverage note now sits
  after the parts (shown at the end above them it would push every card down).
- **Progress bar** (owner: "it needs a progress bar"). Rules shared by both clients: `figure-progress.ts` /
  `FigureProgress.swift`, fixture `tests/fixtures/figure-progress.json`. A stage label always — "Preparing the figure…"
  (until the stream opens), "Reading the figure…", "Writing the summary…", "Writing part 2 of 3…", "Writing part 4…" — and
  a determinate value only while the number of parts is known (announced by the model, else the figure's own sub-figures,
  else the caption's lettered panels) and not exceeded: 10 % for the summary, then parts, each part's share filled by
  its characters against a measured 1,500 (capped at 90 % of the part); the value never goes back and never waits at a
  made-up 99 %: past the estimate it turns indeterminate until done. It sits where the walkthrough will appear, with a
  skeleton (summary lines and one part card) shown at once, then below the last part shown (content above never moves),
  and fades out at the end. Accessibility: one element (label = stage, value = percent when determinate); VoiceOver /
  an `aria-live="polite"` region announce stage changes only; under Reduce Motion nothing pulses, shimmers or fades.
- **Older servers** (only `figure`): Preparing → Reading → the whole walkthrough at once, as before.
- *Since the owner's "Let's try Gemini instead of Sonnet for Figures then" (2026-10-22, later; [DECISIONS](../DECISIONS.md#figures-default-gemini-flash-again-owner-decision-2026-10-22-deployed-to-staging-clients-local)):
  `default_figures` is `gemini-medium-standard` (run at low effort), the clients fall back to Gemini where offered, a saved
  `sonnet-low-standard` figures choice is let go once (`ai.figuresDefaultGemini.migrated` / `figuresDefaultV3`), and the ⓘ
  reads "… Gemini Flash is the default: it reads plots closely at a low cost, and its walkthrough starts appearing within
  seconds. Sonnet is a little quicker to start and also careful, at about three times the cost. …". The bullet below is
  the morning's state.*
- **Figures default** (owner, below): the table's `default_figures` (Sonnet, low, standard) for the figures-and-tables
  activity, else Sonnet low when offered, else the general default; the activity no longer inherits the reader's general
  chat default; a saved figures choice stays, except the old recommended `gemini-medium-standard`, migrated once. Its ⓘ
  text (both clients, word for word): "Figures and tables: the model looks at the figure’s image as well as its caption,
  so it must read images (every cloud model listed does). Sonnet is the default: it reads dense plots carefully and its
  walkthrough starts appearing within seconds. Speed differs by model: DeepSeek writes more slowly, and much more slowly
  at a higher effort."
- **Fixtures:** the browser fixture backend and the apps' `--chat-fixture-mode=figure_walkthrough` stream like the server
  (`figureStream` fast/slow/step/old; `--figure-fixture-step-ms`, `--figure-fixture-old-server`).

**Measured.** Model alone (`scripts/figure-speed.mjs`: the server's own request through the production adapter, straight
to OpenRouter; cache read unless noted), seconds from sending:

| Figure | Configuration | First token | Summary | Whole | Out (reasoning) | Parts / boxes | Cost |
|---|---|---|---|---|---|---|---|
| DPO 2 | Gemini medium, tool (before) | 6.3 | 18.8 (all at once) | 19.0 | 2,294 (984) | 2 / 2 | $0.0155 |
| DPO 2 | Gemini low, tool | 10.0 | 10.0 (all at once) | 10.0 | 1,288 | 2 / 2 | $0.0099 |
| DPO 2 | **Gemini low, JSON reply** | 2.3–2.4 | 2.8 | 9.6–11.3 | 1,005–1,414 | 2 / 2 | $0.0089–0.0105 |
| DPO 2 | Gemini minimal, JSON reply | 1.6–2.2 | 2.3–3.1 | 10.5–11.7 | 1,213–1,243 | 2 / 2 | $0.0098 |
| DPO 2 | Gemini medium, JSON reply | 3.4 | 8.4 | 14.1 | 2,011 (952) | 2 / 2 | $0.0129 |
| DPO 2 | Haiku 5.5 low, tool | 1.2 | 2.0 | 6.2 | 1,218 | 2 / **0** | $0.0015 |
| DPO 2 | Haiku 5.5 medium, tool | 3.0 | 9.2 | 13.8 | 2,832 (1,319) | 2 / 2 | $0.0024 |
| DPO 2 | Sonnet 5.5 low, tool | 1.7 | 2.7 | 9.4 | 1,221 | 2 / 2 | $0.0242 (cold $0.23, no usable part) |
| DPO 1 | Gemini medium, tool (before) | 17.4 | 32.6 | 32.6 | 2,297 (1,415) | 2 / 2 | $0.0155 |
| DPO 1 | **Gemini low, JSON reply** | 3.2 | 3.7 | 8.5 | 691 | 2 / 2 | $0.0074 |
| DPO 1 | Haiku low, tool | 3.0 | 8.1 | 10.0 | 1,710 (957) | 2 / **0** | $0.0017 |
| PRISM 5 (3 images) | Gemini medium, tool (before) | 6.3 | 45.2 | 45.4 | 5,256 (3,821) | 3 / 3 | $0.0258 |
| PRISM 5 | **Gemini low, JSON reply** | 2.6 | 3.1 | 11.2 | 1,383 | 3 / 3 | $0.0091 |
| PRISM 5 | Haiku low, tool | 2.5 | 3.3 | 9.9 | 1,632 | 4 / **0** | $0.0075 |
| Subspace opt. 1 (3 images) | Gemini medium, tool (before) | 24.5 | 24.5 | 24.6 | 1,215 | 3 / 3 | $0.0125 |
| Subspace opt. 1 | **Gemini low, JSON reply** | 3.8 | 4.5 | 11.0 | 1,144 | 3 / 3 | $0.0103 |
| Subspace opt. 1 | Haiku low, tool | 3.1 | 3.9 | 5.7 | 649 | **0** (malformed box) | $0.0162 (cold) |

The "before" Gemini-medium rows each wrote the cache (first request on that paper); a Gemini cache write alone adds
4–8 s to the first token (DPO 2 at low: 10.4 s written, 2.0 s read). Quality, side by side (records under
`.artifacts/figure-speed/`): at low, Gemini read the same panels, axes, ranges, values and legend entries as at medium,
with a box on every panel part, the sub-figure labels the structure note gave and `[¶N]` citations in every part; its
texts are a little shorter (700–1,300 characters). Two low runs under a first JSON-reply wording (without the escaping
line) wrote some `$…$` math; with the deployed wording the three later records hold 52 `\(…\)` and no `$`. Haiku at low drew no boxes on three figures and wrote a
malformed box that ended its turn on the fourth; Sonnet at low was as fast as Gemini at 2–3× the cost, and its one cold
run returned no usable part. On this evidence Gemini at low was the measured pick; the owner then made **Sonnet 5.5 at low the figures default** (later the same day back to Gemini at low: "Let's try Gemini instead of Sonnet for Figures then"; below, and [DECISIONS](../DECISIONS.md#figure-explainer-streamed-at-low-effort-owner-request-2026-10-22-agent-decision-with-evidence-reversible)); Gemini readers get low effort.

Through the deployed function on staging (`node scripts/chat-live-smoke.mjs --figure-view=2,1 --figure-walkthrough-only
--profile=gemini-medium-standard`, as the apps send it; disposable accounts; server stages from the database: the
quote, the provider attempt's dispatch and finish, the settlement), seconds from the request:

| Figure | | Reading shown | First visible (summary) | First part | Whole walkthrough | Model dispatched → finished | Cost |
|---|---|---|---|---|---|---|---|
| DPO 2 | before | – | 24.1 (all at once) | 24.1 | 24.1 | 1.40 → 23.72 | $0.0167 |
| DPO 2 | after | 0.8 | 7.2 | 11.3 | 15.4 | 0.89 → 15.26 | $0.0118 |
| DPO 1 | before | – | 13.8 (all at once) | 13.8 | 13.8 | 0.92 → 13.48 | $0.0115 |
| DPO 1 | after | 0.7 | 4.6 | 6.8 | 9.4 | 0.78 → 9.11 | $0.0081 |
| PRISM 5 (four parts) | after | 0.9 | 6.7 | 8.8 | 15.6 | 0.97 → 15.35 | $0.0098 |

**By model, live on staging** after the owner's "I tried Sonnet, it was much faster than DeepSeek" (same command with
`--profile=…`; the second deploy, 02:50 UTC, adds DeepSeek without thinking at low; Sonnet's first run wrote the paper to
its one-hour cache):

| Profile sent | Figure | First visible (summary) | Parts | Whole | Out tokens | Cost |
|---|---|---|---|---|---|---|
| `sonnet-low-standard` (figures default since this change) | DPO 2 (cache write) | 4.5 | 8.4, 11.9 | 12.3 | 1,300 | $0.2374 |
| | DPO 1 | 3.6 | 6.8, 9.6 | 10.0 | 1,036 | $0.0220 |
| `gemini-medium-standard` → low | DPO 2 | 7.2 | 11.3, 15.1 | 15.4 | 1,347 | $0.0118 |
| | DPO 1 | 4.6 | 6.8, 8.8 | 9.4 | 805 | $0.0081 |
| `deepseek-auto-standard` → low, no thinking | DPO 2 | 3.5 | 9.8, 13.4, 18.3 | 18.8 | 1,796 | $0.0039 |
| | DPO 1 | 3.9 | 7.6, 11.2, 15.0 | 15.4 | 1,217 | $0.0005 |
| `deepseek-medium-standard` (thinking) | DPO 2 | 23.3 | 28.5, 32.9, 37.6 | 38.1 | 3,171 | $0.0043 |
| | DPO 1 | 14.0 | 19.2, 23.4, 27.3 | 28.6 | 2,151 | $0.0008 |

The owner's own walkthroughs on staging before this change (database, durations only): 12 with
`deepseek-medium-standard`, the model taking 19–97 s each (median ~33 s) with nothing shown until the end, and one with
`sonnet-low-standard`, 16 s. **DeepSeek on its pinned route is inherently the slowest here**: DeepInfra FP8 writes ~40–65
tokens a second, and at any thinking effort it thinks first ("low" still spent 1,600–1,850 reasoning tokens: 23 s before
the first word of a walkthrough). The figure view therefore sends DeepSeek at low without thinking (`reasoning:
{enabled: false}`, which OpenRouter passes: 0 reasoning tokens; same panels and values read); a reader's explicit medium
or high keeps thinking and stays slow.

**DeepSeek's route (measured; a proposal, not switched).** Direct to OpenRouter, the server's own requests, DPO Figure 2
walkthrough / a paper-chat answer ("Why does the DPO objective need a reference model…"), seconds to first text / whole:

| Host (deepseek-v4.1-flash-1017) | Walkthrough, thinking low | Walkthrough, no thinking | Chat answer, low | Chat answer, no thinking | Price $/M in/out |
|---|---|---|---|---|---|
| DeepInfra FP8 (pinned today) | 24.5 / 37.5 (1,846 reasoning) | 2.8 / 14.8 | 7.5 / 16.9 | 1.1 / 10.5 | 0.098 / 0.294 |
| Together | 8.2 / 12.1 (1,603 reasoning) | 1.6 / 7.1 | 1.6 / 4.7 (cache read) | 1.1 / 5.4 | 0.30 / 1.20 |
| Baseten | – | 2.5 / 5.4 | – | – | 0.30 / 1.20 |
| inference.net FP8 | – | 2.9 / 11.1 | – | – | 0.08 / 0.50 |
| Fireworks | – | 2.4 / 12.4 | – | – | 0.30 / 1.20 |
| DeepSeek (the maker) | refused: not a zero-data-retention endpoint (HTTP 404 under `zdr: true`) | | | | 0.30 / 1.20 |

PRISM Figure 5 without thinking: DeepInfra 2.9 / 19.8 s, Together 1.3 / 8.8 s; both split the middle strip into (b) and
(c) with their own boxes (Gemini grouped them). Baseten misread one axis range on DPO 2. Each costs well under a cent a
walkthrough. The DeepInfra pin (2026-10-18) was chosen because the maker's endpoint is not in OpenRouter's ZDR inventory
(still true) and consent v6 names DeepInfra as the processor; Together is offered under OpenRouter's ZDR filter at about
three times DeepInfra's price and was 2–3.5× faster in every comparison. **Proposal:** move DeepSeek's pin to Together
(`together`), which needs a consent text naming Together AI (a new consent version and client release), a reviewed
tariff card and a check that its revision stays `-1017`; until then DeepSeek stays on DeepInfra.

Gemini's own first-token time varied 3.3–5.7 s on staging against 2–4 s in the direct runs; in every run the streamed parts
equalled the final walkthrough. Records: `.artifacts/figure-view/2026-10-22T02-02-00-800Z-2305.18290v3.json` (before),
`…T02-18-42-277Z-2305.18290v3.json`, `…T02-20-46-434Z-2610.14704v1.json` (after). Spend for this work: $0.59 direct
(ledger `.artifacts/figure-speed/spend.json`) and $0.33 on staging (Sonnet's cache write on DPO $0.24 of it); about $0.92 in all.

**Open.** Gemini's five-minute prompt cache: a walkthrough more than five minutes after the paper's last request writes
the paper again (4–8 s more before the first token and ~$0.03); a longer Gemini cache TTL would change every Gemini chat's
cost and is left for a separate decision. Not measured on a phone (paused).

## Structure first and the count check — 2026-10-21 (local source; not released, not deployed)

Integration steps 1 and 3 of [subfigure detector round 3](../reviews/SUBFIGURE_DETECTOR_20261023.md): 15.7 % of arXiv
HTML figures already hold two or more images (9.6 % with sub-captions), so their parts are exact without a model; and a
second opinion on the *number* of parts separates good splits from bad ones (offline 87 % vs 21 % perfect). Both clients
(iPhone/iPad/Mac one SwiftUI path, and the browser) do the same, from the same rules and fixtures. No server, prompt,
schema, storage or spend change; the image a request carries is unchanged.

- **The structure** (`ScienceReaderCore/FigureStructure.swift`, `apps/web/src/lib/figure-structure.ts`). Read on the
  device from the reader bundle: the figure block's markup in the page (`<figure data-reader-figure>`), its `asset_paths`
  and the images' sizes in the manifest. Panel images are the `<img>`s outside a paragraph (a legend symbol inside words is
  not one); a run of images followed by sub-captions — paragraphs "(a) …" / "a) …", the compiler's form of a panel's own
  caption — gets one sub-caption for the run or one per image; otherwise the caption's letters in order when it names
  exactly as many panels as there are images; otherwise the images are unlettered ("Image 2"). A sub-figure is one image or
  one sub-caption's images. Fewer than two sub-figures in the composed image: no structure.
- **Geometry kept.** The composed image is unchanged (every image scaled to the widest one's width, stacked top to bottom
  with 2 % of the width of white between them; the first four images: `ChatFigureFinder.composite`, `composeFigure`), so
  each sub-figure is a full-width band of it, computed with the composite's own arithmetic (`stackLayout`), and stored chat
  parts and kept walkthroughs still map to the same pixels. A structure is used only when its composite's aspect is within
  2 % of the image actually sent (`fits` / `structureFits`).
- **Told to the model.** The walkthrough's `selection.quote` is the caption, a blank line, then (for a figure with a
  structure, when both fit the 4,000-character selection):
  ```
  The image stacks this figure's 3 sub-figures top to bottom, each across its full width (y: fractions of the image's height):
  - (a) Routing criticality: y 0.00–0.33
  - (b) Expert variance: y 0.34–0.66
  - (c) Router variance: y 0.67–1.00
  Give each its own panel card, labelled as listed, in this order.
  ```
  ("Only the first 4 of its 6 images are in the image." when the figure has more.) The quote follows the cached paper, so
  the cache is unchanged; `figure_simpler` still quotes the part's text; kept answers keep their keys.
- **Matching a walkthrough's sections** (`matchSections` / `FigureStructure.match`, panel cards only, each sub-figure
  once): by letter (the label's, else the title's) or by the note's label ("Image 2"); then a box whose IoU with one band
  is at least 0.6 (a section lettered otherwise is not moved); then, when there are exactly as many panel cards as
  sub-figures, the unboxed rest in order. A label naming two panels ("(a) and (b)") matches none of these and stops the
  order step. A matched section gets a card even without a box.
- **Exact parts** (`exact` in the framing): the band is the part's region, tight (score 1, high), with the background
  margin; it is always kept (never an extra) and shapes completion as a box. Others are framed as before.
- **Count check** (both surfaces, `FigureFraming.frame` / `frameParts`): when there are two or more parts and their number
  is neither the caption's lettered panels (L ≥ 2) nor the figure's own sub-figures (S ≥ 2), whichever are stated, every
  part that isn't exact scores at most `countCap` 0.3: the whole figure with the part outlined (reason `count`). One part
  is not a split and is not checked. This replaces "more parts than the caption: −0.3" (those parts now show the whole
  figure; the extras are still outlines); a part lettered outside the caption is still −0.3 when the count agrees.
- **Where:** walkthrough cards, and chat's figure parts (inline, strip, overview, full view) when the parts were cut from
  the figure's own composite (`figureFacts` / `ReaderModel.figurePartCrops`).
- **Coverage note** counts an exact part's band as shown.
- **Browser fullscreen:** a tall figure (every multi-image composite) kept its width and was squeezed into the window's
  height; the viewport is now narrower instead (`--aspect`).
- **Fixtures.** `tests/fixtures/figure-crops/structure.json` (11 markup cases from real figures — 2610.22353v1 Figures 3
  and 4, 2610.14704v1 Figure 5 — and edge cases; 13 section-matching cases; sub-captions; layouts) and six new
  `framing.json` cases on `stacked-subfigures.png` (DPO Figures 1, 4, 2 composed as a request composes them,
  `scripts/figure-structure-fixture.py`): exact sub-figures, a detail beside exact parts, the count disagreeing with the
  structure or the caption, agreeing with the structure but not the caption, and one part (not checked); two existing
  cases changed (more parts than the caption, a caption naming two of four → the whole figure). Browser
  `figure-structure.test.ts` writes the expectations (`UPDATE_STRUCTURE_FIXTURE=1`); Swift `FigureStructureTests` and
  `FigureFramingTests` reproduce them.
- **Known limits.** Stacking is how the image has always been composed: a 2 × 2 grid of images reaches the model as four
  bands, not the paper's layout. Only the first four images are composed. Unlettered sub-captions are not read (the images
  are "Image N"). A sub-figure image that itself holds several plots is one exact part; the AI's boxes inside it are framed
  as usual. Matching trusts the model's labels; a wrong letter shows the wrong sub-figure, exactly (the card still expands
  to the whole figure).
- **Evidence:** IMPLEMENTATION_STATUS.md "Structure first and the count check".

## Extract the subfigure removed — 2026-10-21 (local source; not released, not deployed)

Owner: "Let's not do extract the subfigure, users can always go to the original feature and just zoom in if they want.
Let's simplify our life by trying to consistently create one good product experience in the AI result that comes back."

- **One figure result.** The walkthrough (summary, then part by part, each part a viewport into the whole figure, below)
  is the only AI result. To look closer, the reader pinches/zooms a part's card, taps it (or Full screen / Open
  fullscreen) to expand to the whole figure with the part outlined, or uses the figure page itself.
- **Removed from every client** (iPhone/iPad/Mac one SwiftUI path, and the browser): the part menu's "Extract the
  subfigure and more context", its loader ("Extracting this part…"), the "Up close" block with its own viewport card,
  "Couldn't crop this part; here is the closer reading", Try again for it, the detail framing and framing-record surface
  (`detail`), its Save snippet source, the request (`ChatAction.figureDetail` / `'figure_detail'`), the stream event
  (`figure_detail` is now ignored like any unknown event), `FigureDetail` / `parseFigureDetail` / `detailQuote`, the
  fixtures' detail answers and the journeys' extract steps. The live smoke (`scripts/chat-live-smoke.mjs`) no longer
  asks for it.
- **Kept follow-ups (and why).** *Explain more simply* (`figure_simpler`) stays: it returns words only, streamed under
  the same part inside the walkthrough ("More simply"), no crop, no new presentation; it is the owner's original "back
  up a bit". The other part actions are not AI results and stay: Show in the paper, Save snippet (what the card shows),
  Ask about this part (an unsent draft in the walkthrough's own chat). There is no "more parts" request (none was ever
  built; "more parts" in "Parts as viewports" below meant the caption cap on boxed parts). A part's menu is now:
  Explain more simply, Save snippet (when the part has a card), Show in the paper, Ask about this part (native order;
  the browser lists Explain more simply, Show in the paper, Save snippet, Ask in chat about this).
- **Answers kept by older builds.** A native sealed `FigureAnswer` an older build kept for `figure_detail` still decodes
  (the `detail` field is ignored), but no view asks for that key, and Settings › Your assets › Figure explanations
  skips subjects whose action isn't `figure`/`figure_simpler` (`FigureAnswer.isShownFigureAction`): hidden, never
  broken. The browser drops kept `figure_detail` entries when it restores its kept list (`ChatSession.restoreKept`), so
  they are neither shown nor counted against the per-kind bound. No migration.
- **Server: deprecated, still accepted.** `figure_detail` stays valid in `chat.ts` / `chat-figure-view.ts` (with
  `FIGURE_DETAIL_INSTRUCTIONS`, the `figure_detail` event, its allowance and migration 083's settlement value), marked
  DEPRECATED in code, so already-installed builds 63–79 and browser pages loaded before the next deploy keep working.
  **Remove it once no supported build sends it** (then delete the server branch, instructions, event and its backend
  tests; keep 083's value for old ledger rows). No client reads a list of actions from the server, so nothing new
  lists it. The backend tests for it stay until then.
- **Evidence:** see IMPLEMENTATION_STATUS.md "Extract the subfigure removed".

## Parts as viewports — 2026-10-21 (local source; not released, not deployed)

*Since "Full screen on touch" above (2026-10-22): a card no longer pinches, pans or double-taps in place, and full screen
opens framed on the part rather than widening to the whole figure; read those mentions below as history. Since "Extract
the subfigure removed" above: the "Extract" request and its detail card no longer exist; read the mentions below as history. Since "Structure first and the count check" above: a part that is one of the figure's own
sub-figures is exact, and the count rule below ("more were boxed … (0.3)") is replaced by the count check.*

Owner: "in different panels, when we present it, we present it in such a way that if it's inaccurate, the user can just
click and see the whole figure, so we present it as a crop of the whole thing, that they can expand, rather than an
actual crop" — with the parts shown selectively by confidence, the "extract the subfigure / more parts" requests kept, and
never anything misleading. Builds on "Complete crops" below; no server, prompt, schema, storage or spend change.

- **A card is a viewport, not a cropped bitmap.** Walkthrough panel cards and "Extract the subfigure" details render the
  whole figure (on its white margin) scaled and placed so the part's *frame* fills the card; the card's aspect is the
  frame's. Native `FigureViewport` / `FigureViewportScroll` (FigureExplainView.swift); browser `ViewportCard`
  (`ui/FigureViewport.tsx`). Pinch (and the browser's − / + and drag) move the view over the whole figure: out to all
  of it, in to 8× the frame. At the frame a native card doesn't pan, so the page scrolls; once pinched it pans. A double
  tap/click returns to the frame. A tap (or Full screen / Open fullscreen; VoiceOver activate) expands to the existing
  fullscreen viewer, which opens on the part's frame and widens to the whole figure (at once with Reduce Motion) with the
  part outlined; **Show part** / **Whole figure** switch between them. Labels keep their meaning ("Detail of Figure 1:
  Left plot"; "…, whole, for …" when the card shows the whole figure).
- **Framing by confidence** (`ScienceReaderCore/FigureFraming.swift`, `apps/web/src/lib/figure-framing.ts`; every
  threshold in one `Parameters` / `FRAMING`). A score from 1 loses: completion growth beyond 50% of the AI box's area
  (0.6 per unit, at most 0.5); the caption naming L ≥ 2 panels while more were boxed, or a part lettered outside the
  caption (0.3); a neighbour's ink inside the part — the largest share of an ink component another part owns that lies in
  this part's region — above 2% (0.26 + the share, at most 0.4); a sliver (under 8% of a side or 1.5% of the area: 0.3);
  the detector's disagreement (hook, not wired: up to 0.4 below IoU 0.7). A part completion couldn't hold (it still cuts
  ink) or a part beyond the caption's panels scores 0; without decodable pixels, 0.6. **High (≥ 0.75)**: the completed
  crop plus the background margin, the rest of the figure under an opaque white veil — it looks as the crop did.
  **Medium (≥ 0.45)**: each side 18% of the part's size looser (at least the margin), a soft veil (40% white), the part
  outlined. **Low**: the whole figure, no veil, the part outlined (the AI's box where completion couldn't hold it). Once
  the reader zooms or pans, a tight card's veil turns soft and its outline shows. The outline is the light accent in both
  appearances (it sits on the white figure). This replaces "Shown whole: a crop would cut part of this panel off": no
  message, only the outline.
- **Extract / more parts.** "Extract the subfigure and more context", Explain more simply and chat's parts stay; an
  extracted part is framed alone by the same rules. When the caption names its panels, parts beyond them (the lettered
  ones first, then unlettered in order) are never new crops: they show the whole figure with the part outlined
  (`keptParts`; extras are left out of completion so they can't reshape the others). Chat's parts (inline, strip,
  overview, full view) use the same framing at rest (native: rendered by `FramedPart.renderFrame`; browser:
  `FramedFigure`), with the caption looked up from the paper on the device; they are not pinchable in the transcript
  (as before), and the overview and full view outline each part's region.
- **Save snippet** (new item in a part's menu, both clients): what the card shows — the view as the reader left it, with
  its veil and outline — at the figure's resolution or the card's on-screen pixels, whichever is larger, into the
  snippet composer (source: the paper, "Figure 1 · Left plot"; anchor: the figure's block).
- **Coverage note** unchanged in meaning: a part that shows the whole figure covers everything.
- **Fixtures.** `tests/fixtures/figure-crops/framing.json`: the parameters and 12 cases on the real figures of
  `cases.json` (precise plots, a box reaching into its neighbour, a cut panel, a detail slice, a caption that agrees, more
  parts than the caption, a caption naming two of four, a letter outside the caption, a sliver, halves, the detector hook,
  unchecked), plus caption/label letter cases. TypeScript (`tests/figure-framing.test.ts`) and Swift
  (`FigureFramingTests`) reproduce every level, reason, score (±1e-4), frame and region (±1 px). `UPDATE_FRAMING_FIXTURE=1`
  rewrites the expectations from the browser implementation (review the levels in the diff).

### Future opt-in training signal; not collected

Owner, same day: "It can be a good UX compensating and working together with limits of ML, while still pushing ML as far
as possible. Ideally, we could even log the data (later) from zoom behavior and build a training dataset." **Nothing is
collected or sent.** When a part card is shown, zoomed, panned or expanded, both clients keep one geometry-only record per
card in memory — `FigureFramingRecorder` (`ScienceReaderCore/FigureFramingRecord.swift`) and `figure-framing-record.ts`:
the figure's public identity (arXiv id, revision, "Figure N"; nothing for local PDFs or snippets), surface
(walkthrough or chat; the `detail` surface went with Extract), the part's place in its set, confidence tier, the AI box, completed region and first frame, the
reader's final view (all normalized to the figure) and whether they zoomed, panned or expanded. At most 200 records;
cleared on sign-out (`clearAccountView` / `auth.signOut`); never persisted, logged or uploaded. It is the one place a
future, consented upload would attach to; the conditions are the proposal in DECISIONS.md (opt-in only, geometry only,
public arXiv figures only, no account linkage, data layout designed before any collection).

## Complete crops — 2026-10-21 (local source; not released, not deployed)

Owner, TestFlight feedback: "ALWAYS include all pixels of the figure when it breaks it up into subplots", "The crop
dimensions are not good", "Looks like the whole sub figure not included?"; and, 2026-10-21, "when we present user
figures they have some margin around them". Integration step 1 of the
[subfigure detector review](../reviews/SUBFIGURE_DETECTOR_20261021.md): a model-free completeness step on every
AI-written crop, on both clients, with no server, prompt, schema or storage change (boxes are stored as the AI wrote
them; completion is recomputed wherever a crop is shown).

- **Where.** Walkthrough panel cards (all boxes completed together), each "Extract the subfigure" detail (alone), and
  chat figure parts (all parts of one answer together: inline, strip, overview and full view) on iPhone/iPad/Mac and
  in the browser.
- **On what.** The exact image the request carried: the walkthrough's sent JPEG; for chat parts, the paper's figure
  prepared again exactly as it was sent (`ChatFigureFinder.prepare` / `prepareFigure`). Ink is `min(R,G,B) < 235`.
- **Steps** (`scripts/subfigure-detector/app_crops.py`, ported to `ScienceReaderCore/FigureCropCompletion.swift` and
  `apps/web/src/lib/figure-crops.ts`; same parameters as the research `policy.complete`): ink components (dilation
  radius 0.3% of the long side, 4-connected); each box grows over the components it cuts (labels, ticks, its own
  clipped body; never more than 8% into another box; at most 4 passes). Only when the grown boxes hold ≥ 70% of the
  ink (they tile the figure) is unowned ink attached to the nearest box(es) — and only context-sized ink (at most half
  that box), with ink inside a held shared legend staying with it. App additions over the research policy, needed
  because AI boxes include single detail boxes and partial sets: that tiling gate, the size limit and the held
  legend. A box that still cuts a component it may own (not a figure-wide frame/background, not mostly another box's)
  shows **the whole figure** for that card (since "Parts as viewports" above: with the part outlined and no message).
- **Margin.** Every presented crop, and a whole-figure card, is cut exactly and drawn on padding of the figure's white
  background: `max(8, round(2% of the shorter side))` pixels of the sent image, scaled with the crop (never more of the
  image, so a neighbour's ink cannot show at an edge). This replaces the earlier 2% image margin.
- **Coverage note.** "The detail cards do not cover the entire image…" now means the crops leave some of the figure's
  *ink* out (pixel-exact over the presented rectangles; whole-figure cards cover everything), instead of some *area*.
  Without decodable pixels both clients fall back to the AI box with the old 2% context and the old area rule.
- **Off the main thread.** Native: the ink is decoded once per figure view and completion/cutting runs in a detached
  task; chat parts are completed once per answer and kept in a bounded cache. Nothing shows until the crop is
  known, so a crop never appears and then changes size. Browser: on the page thread (tens of ms per figure).
- **Fixtures.** `tests/fixtures/figure-crops/` (`export_crop_fixtures.py`): three DPO figures from the bundled sample
  and one generated lettered grid; cases for clipped axis labels, stray letters with a shared legend, a partial set,
  a box that cannot be completed (whole figure), a detail slice (whole figure), halves, filled panels and a known
  limit (a filled panel background is one figure-wide component, so a box inside it is not checked). Swift and
  TypeScript reproduce every rectangle exactly (tolerance 1 px), the component digest, ink count and coverage.

Known limits: no semantic check that a crop holds *its* legend or letter; ink components joined through a plot's
lines can make a small detail box fall back to the whole figure (by design: no clipped slice is shown); dark-background
figures (everything is ink) are left as the AI drew them.

## Complete image coverage and card types — 2026-10-18 (TestFlight 73; backend/browser deployed)

Owner feedback ALCJLruWVHFOYNzJoULIvSY asks for every pixel to remain represented in the presentation, usually
one card per subfigure but allowing grouped panels. Keep the complete image above the walkthrough. Add optional
`kind` (`panel`, `concept`, `related_work`) to existing v1 sections; absent/unknown kinds remain panel cards for
old answers. Use a consistent type/part label, title, optional image and explanation. Related work is grounded
in citations to the supplied paper, explicitly described as that paper's account, not a claim to have read other
sources. No new automatic retrieval, paid requests, storage schema or conversation is introduced.

Increase the crop limit to the existing 12-section bound. Ask for complete panels and shared axes/legends, with
overlap or grouped panels when useful. Check the union of validated, displayed crop rectangles, including their
bounded context margin. A split with uncovered image area retains the full figure and shows a clear coverage
fallback message. Do not invent coordinates or fill gaps by assigning them to a panel. Pixel bounds round outward
on both clients. Full coverage does not prove semantic panel completeness or that each crop has its required
legend: those are separate model-quality checks. Invalid geometry remains rejected. Single-panel figures need
no crop. Old saved results stay readable without another AI request.

The local detector uses the same acceptance principle: record uncovered area, missed panels and critical-label
loss separately; a whole-image fallback is never scored as a successful split. Regression cases include grids,
overlap, insets, small holes, edge labels, a shared legend and the reported 3DCodeVerse-2M Figure 2 layout.

Verification: backend chat tests 136, Core figure tests 10, browser figure units 14 pass. Desktop/phone journeys
cover all 12 figure cases, including typed cards and crop/fullscreen controls. The first browser run exposed a
fixture still rejecting the new v6 consent; it now mirrors the deployed route instead of rejecting valid clients.
Visual review also found the fullscreen text button inheriting a 32-pixel icon width; its controls now wrap safely.
Live Flash on FDE-Gym Figure 5 returned two panel cards at x=0/w=.5 and x=.5/w=.5, both full-height. The union is
100%; the plotted axes, labels and titles were inspected. Walkthrough + detail cost $0.029884; this is one example,
not a corpus-level quality claim. Records: `.artifacts/feedback/build71-20261018/` and
`.artifacts/figure-view/2026-10-18T20-50-04-799Z-2610.22350v1.json`.
Native build 73 is VALID / IN_BETA_TESTING on iOS/iPadOS and Mac, confirmed at 21:45:12 UTC. Both release notes
were read back. The affected native journeys and the current-source 13-case import gate pass; details and
remaining model/import limitations are in IMPLEMENTATION_STATUS.md.

## Build 70 feedback repair — 2026-10-18 (TestFlight 71 on iOS/iPadOS and Mac; browser/backend deployed)

The earlier instructions explicitly encouraged a “thin slice” or tiny marker crop. They now ask for a complete
panel with axes, tick labels, legend and annotations, and no box when uncertain. Narrative asks for the observed
relationship and authors' interpretation separately from inference; descriptive tables do not invent results.
The deployed Flash/OpenRouter route passed FDE-Gym Figure 5 walkthrough, simpler explanation and detail extraction
on 2026-10-18 at 16:21–16:22 UTC. Actual ledger cost: $0.039627, three successful attempts, nine reader credits,
no held test credits. The reviewed output has complete panels. A remaining edge-label clip led to a 2% display
margin, clamped to the image, in native/browser crop rendering; stored model coordinates remain unchanged. This
margin is not a guarantee of correct geometry. Whole-figure fullscreen remains available.

Explainers now offer fullscreen before zoom, table-specific loading text, a return path after paper citations,
and a Chat button beside Close. Chat promotion retains the composer, draft, selected model, image/caption and
bounded prior explanation context; it does not send another request. Transient presentation context is bounded
to eight conversations and cleared on account/paper retirement; it is not reconstructed after app restart.
Original encrypted answer storage remains unchanged. Browser and native journey evidence is recorded in
`IMPLEMENTATION_STATUS.md`. Per-activity defaults preserve explicit conversation choices and closing a sheet
restores the previous chat's engine.

A separate [local region detector investigation](LOCAL_FIGURE_REGIONS.md) and [measured experiment](../reviews/LOCAL_FIGURE_REGIONS_20261018.md)
are complete. No detector/model weights are included in the client release.

Native Local AI prototype (2026-10-17, TestFlight 68): AI Explainer first offers Cloud AI / Local AI. A vision-capable local model receives this figure bitmap, caption and bounded nearby/relevant paragraphs. The initial local result is prose; structured parts/crop proposals are not implemented. The comparison found numeric-reading errors despite tighter crops. See [LOCAL_AI.md](LOCAL_AI.md).

Current provider verification, 2026-10-17: the deployed OpenRouter route passes the live DPO Figure 1 walkthrough,
simpler explanation and extracted subfigure on both the earlier Flash check and today's Haiku repair check.
Earlier balance-blocked checkpoints below are historical. The build 69 chooser names/selects its cloud model and
keeps Change AI available after a failure; billing failures distinguish the provider's funds from reader credits.
See [route and accounting evidence](GEMINI_FLASH_CHAT.md) and `.artifacts/equations-feedback-20261017/live-figure.log`.

Release update, 2026-10-16: the client work below, including the build-62 top row and subfigure extraction UI,
is in TestFlight 63 and browser Pages `836089d4`. The subfigure extraction's paid live check remains pending after
the earlier Anthropic balance refusal; fixture coverage does not verify provider output. The phase descriptions
below retain their original checkpoints. See
[IMPLEMENTATION_STATUS.md](../IMPLEMENTATION_STATUS.md#claude-takeover-and-build-63-release--2026-10-16-2000-utc).

Owner, TestFlight build 59: "a UX that is quite similar to the one for equations, instead of requesting for a breakdown
of the equations it creates a breakdown of the figures, it knows how to crop the different sections out, but most likely
only does this on specific occasions, because this could be expensive and take a while… maybe if there is a very large
figure and the response wishes to draw attention to a particular detail. The response though, even if it doesn't crop
every subfigure it still walks you through the different sub figures, and explains every little detail. It should have
a similar look and feel to the equations one. In the response that comes back, you should be able to tap on different
parts of the response and ask to back up a bit, or link back into the paper. Definitely a very important feature one
that requires some planning and thought."

Related: the equation view (EQUATION_VIEW.md, explanation on request since build 59), figures in chat and figure parts
(CHAT.md "Figures in chat"), the learning-guide proposal's figure guide (docs/proposals/LEARNING_GUIDE.md).

## Where it opens

Every place a figure is shown on its own already: a tapped figure in the paper, the figure gallery's figure page, and
Contents › Figures › a row (all three show the same figure page: the figure large, its whole caption, Show in paper,
previous/next). That page gains, right under the caption, the equation view's two buttons:

- **Explain** — the walkthrough below (AI; on request only, never on opening).
- **Ask in chat** — closes the page and opens the paper's chat with this figure as the selected passage (its caption) and
  the composer focused; the figure goes with the question (as any question naming it). Nothing is sent automatically.

Tables shown as figures get the same page; a walkthrough of a table explains its columns and what to read from it.

## What the walkthrough shows

In the equation view's look (same sheet, spacing, type and cards):

1. **What it shows** — two or three sentences: the figure's point, in plain words.
2. **Part by part** — one section per sub-figure, panel or region the figure has, in reading order, each headed by its
   label ("(a) Input documents per example", "Left: win rate vs. temperature"). Each section walks through every detail
   that matters: what is plotted against what, units and scales, what colours/markers/arrows encode, what to notice,
   how it supports the paper's claim, with `[¶N]` links to the paragraphs that discuss it.
3. **Crops, only where they help** — a section may carry one box (a fraction of the image) when the explanation needs
   the reader to look at a small detail in a large figure: the crop shows inline at the top of that section, as figure
   parts do in chat. At most 4 boxes in a walkthrough, usually fewer; most sections have none. Crops are cut on the
   device from the paper's own image, so they cost nothing beyond the model writing the box.
4. **Tap a section** — a small menu (the system's, like a selected passage):
   - **Explain more simply** ("back up a bit"): a gentler re-explanation of that section, with whatever background it
     needs, streams in under the section (kept with the walkthrough).
   - **Show in the paper**: closes the page and goes to the paragraph that section cites (with Back), or to the figure.
   - **Ask in chat about this**: as Ask in chat, with the section's text as the selected passage.
5. No credit counts anywhere in the view (owner, build 59).

## The requests: chat actions on the chat's cache

Like the equation view, both are ordinary paper-chat requests (hold → answer → settle) on the chat's cached prefix, so a
walkthrough right after chatting reads the paper from the prompt cache:

| field | value |
|---|---|
| `mode` | `paper` |
| `local_context` | the paper on the device (`reader-local-context-v2`, numbered `[¶N]`) |
| `figures` | this figure's image, prepared as chat prepares it (≤1,568 px, ≤1.15 MP, JPEG on white; panels stacked) |
| `selection.quote` | the caption |
| `messages` | one user turn: `Figure 3` |
| `action` | `figure` (the walkthrough) or `figure_simpler` (one section again, more simply; `selection.quote` = that section's text) |
| `profile`, `capabilities`, `consent_version` | as the chat sends them (consent v3+ names figures), with `figure_view` (as built, below) |

`figure` has the model call one tool, `figure_walkthrough` (asked for by the instructions, not forced: see "Server — as built"), whose input the server checks
(`chat-figure-view.ts`): `{format: "figure-walkthrough-v1", summary, sections: [{label, title, text, paragraphs: [N],
box?: {x, y, w, h}}]}` — 1–12 sections, text ≤ 1,500 characters each with `[¶N]` inside the paper, boxes within the
image and at least 4 % of each side, at most 4 boxes. It relays one `figure` event, then `done`. Unusable output falls
back to the model's words as `delta`s (shown as the description). `figure_simpler` streams `delta`s like the equation's
background.

**Cost (Sonnet, paper cached):** the image is about 1,600 input tokens; a walkthrough about 600–1,500 output tokens:
roughly 5–10 credits; `figure_simpler` 2–4. The first request after opening a paper writes the cache like any first
question. Effort is the chat's automatic effort (a figure walkthrough reads as "explain", usually medium).

## On the device

Kept per paper revision (manifest), figure id, action (and section for `figure_simpler`) and model/length, in the same
local store as equation answers (sealed, not synced, not in chat history), so reopening a figure shows its walkthrough
without a new request. The boxes are kept, never the crops. Nothing is sent without chat consent.

## Phases

1. **Server** (built and live on staging 2026-10-16: "Server — as built" below) — `figure` and `figure_simpler` actions with the checked tool, tests (cached prefix byte-identical,
   validation, fallback), staging deploy, live smoke on DPO Figure 1, a multi-panel plot (2610.16784 InfoVis Figure 4) and
   a table, recording cost and time.
2. **Apps** (built 2026-10-16, fixtures: "Apps — as built" below) — the buttons on the figure page, the walkthrough view with inline crops and the section menu, the local
   store, a fixture mode (`--chat-fixture-mode=figure_walkthrough`) and journeys (iPhone, iPad, Mac).
3. **Browser** (built 2026-10-16, not deployed: "Browser — as built" below) — the same in the figure dialog; journeys on desktop and phone.
4. **Evaluation** — ten figures across recent papers (plots, diagrams, tables): are the details right, are boxes on
   the right regions, does every panel get a section; adjust the instructions; record per-figure cost.

## Choices made by default (owner may change)

- Entry from the figure page only (not a separate menu item on a tapped figure, which already opens that page).
- Up to 4 crops, chosen by the model; none is fine.
- "Back up a bit" = Explain more simply, inline under the section (the walkthrough stays in place); deeper questions go
  to chat.

## Server — as built (phase 1, 2026-10-16; staging)

Deployed to **staging**: migration 082 (after 081, ledger verified) and the `chat` function (deploy suite 20/20 each
time). Code: `supabase/functions/_shared/chat-figure-view.ts`, `chat.ts`; tests in `tests/backend/chat.test.ts` and
`tests/database/figure_view_actions.sql`. Two changes from the plan above, both forced by the cache and the model:

- **A capability, `figure_view`.** `figure` and `figure_simpler` must find the tool `figure_walkthrough` among the
  request's tools, and the tools are the first part of the cached prefix, so the tool has to be in the chat's tools
  too. It is offered in every paper chat (not Add paper, not a repair) whose request says `figure_view` under consent
  v3 or later, whatever the Visual answers setting. Builds without the capability keep exactly the tools (and cache)
  they had. **A build with the figure view sends `figure_view` on every paper chat request and on both actions, with
  the chat's other capabilities and profile unchanged**; otherwise the tools differ and the walkthrough writes the
  paper to the cache again. A figure action without it is `invalid_request`.
- **Not forced.** Sonnet 5.5 and Opus 5.5 answer a forced `tool_choice` (`tool`/`any`) with a 400, and forcing would
  also need thinking off. The request keeps the chat's `tool_choice` (auto) and adaptive thinking; the instructions
  after the paper ask for one `figure_walkthrough` call and nothing else. A model that writes words instead is the
  fallback below (seen once, on a table image that was cut off; the instructions now say to call the tool even then).

### Request

```json
{"operation_id":"…","consent_version":"cloud-ai-v3","mode":"paper",
 "local_context":{"format":"reader-local-context-v2","membership_id":"…","source":"arxiv","source_id":"2305.18290","revision":3,
   "manifest_sha256":"…","source_sha256":"…","text":"[¶1] …"},
 "capabilities":["visual_answers","figure_requests","figure_view","stop_signal"],
 "profile":{"model":"sonnet","effort":"auto","length":"standard"},
 "action":"figure",
 "selection":{"quote":"Figure 1: DPO optimizes for human preferences while avoiding reinforcement learning. …"},
 "messages":[{"role":"user","text":"Figure 1"}],
 "figures":[{"id":"F1","paragraph":7,"caption":"Figure 1: DPO optimizes …","media_type":"image/jpeg","data":"<base64>","width":1376,"height":275}]}
```

- `figure`: `selection.quote` is the caption (a table's caption for a table), the message names the figure.
- `figure_simpler`: the same with `"action":"figure_simpler"`, `selection.quote` = that section's `text`, and the
  message naming the part (`"Figure 1 Right panel"`). The same image goes again (it is what the model reads).
- Rejected (`invalid_request`): no or two figures, consent v1/v2, no `figure_view`, no selection, more than one turn,
  `topic_title`, `follow_ups`, mode general, a server `document_id`, an unnumbered (v1) context.
- `capabilities` and `profile` exactly as the device's chat sends them. Effort `auto` resolves to medium (a figure is
  attached). The walkthrough's output allowance is 6,000 plus the effort's thinking (low 8,000, medium 10,000, high
  14,000), whatever the length; `figure_simpler` uses the reader's length like an answer.

### Response

`figure` relays one event, then `done`:

```
event: figure
data: {"format":"figure-walkthrough-v1","summary":"Figure 1 contrasts the standard RLHF pipeline (left, red panel) with DPO (right, teal panel). …",
       "sections":[{"label":"Left panel","title":"RLHF: preference data, reward model, then RL","text":"The red panel is titled … This is the Bradley-Terry fit of Eq. 2 [¶21]. …","paragraphs":[9,18,21,24,23]},
                   {"label":"(b)","title":"…","text":"…","paragraphs":[13],"box":{"x":0.5,"y":0,"w":0.5,"h":1}}]}

event: done
data: {"stop_reason":"end_turn","credits":4,"usage":{…},"model":"claude-sonnet-5-5","profile":"sonnet-medium-standard","effort":"medium","charged":true}
```

- `summary`: string, at most 800 characters (may be empty). `sections`: 1–12, in the model's order.
- Each section: `label` (at most 60 characters; **may be empty**: a part with no name of its own), `title` (at most 120,
  never empty), `text` (Markdown with `\( \)` math and `[¶N]` markers, at most 1,500 characters), `paragraphs` (the
  `[¶N]` numbers that discuss it, each inside the paper, at most 8; may be empty), `box` (optional).
- `box`: `{x, y, w, h}`, fractions of the image that was sent (x, y its top-left corner), rounded to 4 decimals, inside
  the image, each side at least 0.04, never the whole image; at most 4 in a walkthrough. Crop on the device from the
  same image the request carried (for stacked panels, the composed image).
- The check degrades rather than refuses: a section without text is left out, a box that doesn't fit is dropped (the
  section stays), the first 12 sections and 4 boxes are kept, a `[¶N]` outside the paper is removed, a long text is
  cut at its last sentence before 1,500 characters, a long label or title is shortened with "…".
- **No usable walkthrough**: the words come as one `delta` (the call's own words, summary then each section's text,
  else the model's text), then `done`: show them as the description.
- `figure_simpler` streams `delta`s, then `done`, like the equation's background.
- No other tool result is relayed for either action (parts, diagrams, visuals, figure requests).
- Billing as every chat action (CHAT.md "When an answer stops early"): a walkthrough or words shown is `completed`
  and charged; cut off at its allowance is `done {charged:false, reason:"limit"}`; a finished turn with nothing to
  show is `done {charged:false, reason:"provider"}`; errors as for chat. Builds that predate the view ignore the
  `figure` event (they never send the actions).
- An ordinary chat answer that calls `figure_walkthrough` anyway gets no `figure` event; if it wrote nothing else, its
  words become the answer. Logs: `chat_figure_walkthrough` / `_invalid_output` with `called`, `sections`, `boxes`,
  `boxes_offered` (counts only, never text).
- **Database**: migration 082 adds `figure` and `figure_simpler` to `chat_endings.action` and `worker_settle_chat`
  (079 refused any other action, so a figure-view settlement would have waited for the stale-hold sweep).
- **Browser fixture**: `apps/web/e2e/fixture-backend.mjs` validates both actions like the server and answers `figure`
  with a three-section walkthrough (one boxed) and `figure_simpler` with streamed words.

### Evidence

- `tests/backend/chat.test.ts`: validation; the cached prefix — model, thinking, tools (with `figure_walkthrough`) and
  the system blocks through the paper's one-hour breakpoint — byte-identical across a chat question, a chat question
  with the figure, `figure` and `figure_simpler` (web search on); no `tool_choice`; a build without the capability
  keeps its old tools; visuals off keeps the tool; the checked input (order, bounds, boxes, citations); relay, words
  fallback, nothing shown and `max_tokens` not charged; `figure_simpler`; a stray call in a chat answer.
  `tests/database/figure_view_actions.sql` (with 079's `contained_overruns.sql`, every migration through 082).
  `npm test` passed.
- Live on staging, `node scripts/chat-live-smoke.mjs --figure-view=N [--table-view=N] [--warm]` (new: the image
  prepared as the browser prepares it, the boxes drawn on it, a JSON record under `.artifacts/figure-view/`). Sonnet
  5.5, effort auto → medium. Credits are what the reader paid; the cache numbers are the provider's.

| Figure | Image | Sections | Boxes | Credits | Time | Cache |
|---|---|---|---|---|---|---|
| DPO Figure 1 (after a chat question, `--warm`) | 1376×275 | 2: Left panel (RLHF), Right panel (DPO) | 0 | 4 | 8.8 s | read 49,199 tokens the chat question wrote (that question: 40 credits) |
| → more simply, "Right panel" | | 3,013 characters | | 4 | 11.1 s (text at 2.4 s) | read |
| InfoVis Figure 4, four sunbursts (first request on the paper) | 1200×959 | 5: how to read the rings, then each panel | 0 | 47 | 10.8 s | wrote 54,214 |
| InfoVis Figure 4 (final instructions) | 1200×959 | 5 | 0 | 5 | 10.7 s | read 54,214 |
| → more simply, "Top left T2I" | | 2,513 characters | | 4 | 10.0 s (3.4 s) | read |
| InfoVis Table 1, rendered from the bundle as a device shows it | 1206×953 | 4: how to read it, proprietary, open-source, InfoVis row | 0 | 5 | 10.9 s | read |
| → more simply, "Proprietary" | | 2,460 characters | | 4 | 11.1 s | read |
| InfoVis Figure 13, four failure-case panels | 1140×1009 | 4: (a)–(d) | 0 | 5 | 9.8 s | read |
| Mistral 7B Figure 5, four plots (after the box wording change) | 961×664 | 4: one per panel | 0 | 16 | 9.0 s | wrote 15,581 |

- What the walkthroughs read from the images, not the captions: DPO's example prompt ("write me a poem about the history
  of jazz"), the trophy and the arrow labels ("label rewards", "sample completions"); every Table 1 value quoted
  matched the table (8.42 / 8.01 / 7.02 … 7.94); Figure 13's garbled legend ("Diontspair", "Streamg +HERMEFK") and
  annotations. One slip: a Table 1 sentence mixed Qwen-Image-Edit's SC and PQ columns.
- Cache: the walkthrough after a chat question read the whole paper the chat wrote, at a different effort (low → medium);
  every later walkthrough and explanation read it (4–5 credits, 3–4 for more simply), matching the plan's estimate.
- First runs found two things, both fixed: the walkthrough cited only in `paragraphs` (the instructions now ask for
  `[¶N]` in the text: every section of the 7 later walkthroughs has them), and the smoke's table capture cut the table's right columns (the
  model then wrote words, not the tool: the instructions now say to call it even then).
- Total provider spend for this work on staging: $0.82 (22 chat operations, the deploy suite's included).

### Open

- **Boxes: rare, and placed well when given** (updated 2026-10-16, ~09:55 UTC). The first 8 walkthroughs (33 sections:
  DPO Figure 1, InfoVis Figures 4 and 13, Table 1, Mistral Figure 5) gave none. InfoVis Figure 2, a dense two-column
  pipeline with small print, got two (`1 A (top)` x 0, y 0.04, w 0.5, h 0.42; `2 A (middle)` x 0, y 0.4, w 0.5, h 0.32),
  each on the band its section explains (`.artifacts/figure-view/2610.16784v1-figure2-boxes.png`), 48 credits cold. That
  matches the owner's "most likely only does this on specific occasions": no firmer rule for now. Phase 4 can still
  measure the rate on a set of dense figures.
- Tables in the reader are HTML: the device must make the table's image (as the smoke does from the bundle) before it
  can send one.
- The tool's `box` wording changed after the DPO and InfoVis runs (one paper write per paper on staging since).

## Apps — as built (phase 2, 2026-10-16; iPhone, iPad, Mac; not yet in a build)

- **Every paper chat request sends `figure_view`** (`ChatGenerationRequest.capabilities(…, paper:)`: a paper chat,
  document or local context, never Add paper or a repair; general chat never). Ordinary questions, Study, the equation
  view's two actions and the figure view's two share one capability list, so they share the cached tools:
  `["visual_answers", "figure_requests", "figure_view", "stop_signal"]` with visual answers on and the paper on the
  device. Production ignores the unknown value until its `chat` function has the view.
- **Figure pages.** Every page that shows one figure (Contents › Figures › a row, the gallery's figure page, a tapped
  figure, a figure or table reference) has **Explain** and **Ask in chat** side by side under the figure
  (`figurePageActions`, FigureExplainView.swift). Explain shows only for an arXiv paper on this device (a source
  membership, or a legacy arXiv item named by its library item as legacy chat names it); nothing is requested on
  opening. An algorithm's code block gets neither.
- **The walkthrough** is pushed on the page's own stack (Back returns to the figure); a half-height sheet (Contents, a
  figure reference) takes the full height for it. In the equation view's look: the figure (on white, never more than
  twice its own size) with its caption, Ask in chat, the summary, then one card per part: label and title (a tap opens
  the part's menu; a long press or right-click on the card too), the part's crop when it has a box, its text with
  `[¶N]` links (each closes the sheet and goes to that paragraph). No credit counts anywhere.
- **The part's menu**: *Explain more simply* streams under the part (a "More simply" block, kept); *Show in the paper*
  goes to the part's first cited paragraph, else to the figure; *Ask in chat about this* opens a new chat about the
  paper with the part's text as the passage and "About Figure 1, Left half [¶4]: " in the composer, nothing sent.
  The figure page's Ask in chat does the same with the caption ("About Figure 1 [¶6]: "); the question names the
  figure, so chat attaches its image as it does for any question naming it.
- **The image.** A figure goes exactly as chat sends it (`ChatFigureFinder.image(for:bundle:)`, shared: panels
  stacked, ≤1,568 px, JPEG on white). A table the page draws (an HTML table, from a reference) is drawn on the device:
  its block's markup with the bundle's stylesheet, light, at its natural width (≤1,500 px), printed to PDF by WebKit
  and rendered on white at twice its size (`TableDrawing`), then prepared like a figure. Crops are cut from the same
  composition at full resolution (the box's fractions), or from the table's drawing.
- **Kept on the device** (`FigureResultKey`: manifest, figure, action, a digest of the part's text for
  `figure_simpler`, profile) in the equation view's sealed store (`EquationResultStore`, now generic over the key),
  folder `figure-answers`: reopening shows the walkthrough and any part made simpler with no request. A failure says
  so with Try again; one the server didn't charge for adds "Not charged." Consent, sign-in and an unavailable paper
  are handled as in the equation view.
- **Fixture**: `--chat-fixture-mode=figure_walkthrough` (both actions are answered in every mode): three parts of the
  authored fixture's Figure 1, the first with a box, `[¶4]`/`[¶6]` links; "more simply" streams.
- **Evidence (Simulator and this Mac, fixtures):** core `FigureViewTests` (event checks as the server's, crop
  pixels, request bodies and the shared capability list, sealed answers, a table's caption) and the full core suite
  (329); app `FigureViewAppTests` (a figure's image equals chat's; the fixture's table is drawn with ink) and the app
  unit bundle (460, plus the stale `ChatVisualTests` capability expectation fixed); `FigureViewJourneyTests` (Explain,
  parts, crop, more simply, Show in the paper, kept on reopening, Ask in chat about a part; the page's Ask in chat;
  light and dark) on the iPhone 17 and iPad Pro 13 Simulators and on this Mac (Mac Catalyst); the Contents, gallery,
  figure reference, equation view and figure parts journeys still pass. Screenshots reviewed: iPhone light/dark,
  iPad light/dark, Mac light/dark.
- **Not done in phase 2:** no live walkthrough from the app (fixtures only; the server's live runs are above); on the
  Mac the walkthrough opens inside the Contents or gallery sheet at that sheet's size (it scrolls; a larger minimum
  clipped it instead of growing the sheet); an HTML table can be explained only from a figure reference until
  Contents › Tables opens a table's page.

### Top row (owner, build 62; DESIGN.md "Sheet top row", "Explain actions")

- **One row at the top** of every figure or table page and of the walkthrough, in the sheet's own navigation bar (Liquid
  Glass on iOS 26, a material before): **Explain in Chat** (it was "Ask in chat") and **AI Explainer** (it was
  "Explain"; tinted) as two glass capsules in the bar's middle, a round **X** on the right (`Button(role: .close)` on
  iOS 26, an xmark before; `sheet.close`). No title (the caption names the figure) and no Done; a pushed page keeps the
  system Back on the left and its swipe. The two actions are one bar item (`ViewThatFits`: with symbols, without, a
  step smaller), because iOS 26 moved two text bar buttons and the X into a "More" overflow in a half-height sheet.
  `sheetTopRow(chat:explainer:close:)` and `figurePageActions(figureID:close:)` (SheetChrome.swift,
  FigureExplainView.swift); the bottom bar keeps previous/next and Show in paper (the gallery, Contents) or Go to figure
  (a reference).
- **The walkthrough's row**: Explain in Chat and the X (and AI Explainer while nothing is asked, after switching). Its
  heading is **Figure 3 ⌄**, a menu of the paper's other figures (or tables, from a table), each "Figure 4 — caption…";
  choosing one shows that figure with its kept walkthrough, or AI Explainer to ask (nothing is asked unasked). With
  nothing to switch to the heading is the plain name.
  `FigureViewHost` gained `close` (the X); `FigureExplainSession.start(requesting:)`.

## Browser — as built (phase 3, 2026-10-16)

Built on a branch with fixtures; **not deployed**. Code: `apps/web/src/lib/figure-view.ts` (the event's check, crop
arithmetic, keys), `ChatSession.figure`/`savedFigure` (`chat-session.ts`), `ui/FigureView.tsx` (the panel, loaded with
the first figure page so the Markdown and math typesetter stay out of the reader's bundle), `ui/Figures.tsx` (the
figure page), wired through `Reader` and `App` like the equation view's host.

- **Where:** the browser's figure page (Contents › Figures › a row, the Figures gallery's figure, a tapped figure).
  Under the figure, **Explain** and **Ask in chat** side by side (Ask in chat replaces the page's "Discuss in chat":
  an unsent draft about the caption, the composer focused). Nothing is requested on opening; Explain asks the chat's
  consent first. While a walkthrough is asked for or shown the figure gets smaller (46 % of the window, 38 % on a
  phone) and the page scrolls as one, the words at a reading width (760 px) under the figure. Not on a figure
  *reference* preview (a "Figure 3" link's detail), which keeps Discuss in chat and Go to figure.
- **Request:** exactly the chat's request for the paper (default model, automatic effort, Visual answers setting,
  consent v4, the numbered paper on this device: a source membership or a legacy arXiv item) with `action`, one turn
  ("Figure 1"; "Figure 1 (a)" for a part, its title when it has no label), `selection.quote` (the caption; the part's
  text) and `figures: [F1]`, the figure's image prepared as a chat question naming it prepares it (stacked panels,
  ≤1,568 px, JPEG). **Every browser paper chat now sends `figure_view`** (with `visual_answers`, `figure_requests`,
  `stop_signal` as before), so its chats carry the walkthrough tool and the walkthrough reads their cache; never with
  Add paper, a diagram repair or a general chat. No title, suggestions or conversation; nothing is written to history.
- **Shown:** *What it shows* (the summary; without a walkthrough, the model's words as they stream), then *Part by
  part*: each part's label as a quiet tag, its title, a crop where the model drew a box, and its text (Markdown, math,
  `[¶N]` links that close the page and land on the paragraph with Back). The crop is CSS over the image that was sent
  (`cropStyle`: background size 1/w × 1/h, position x/(1−w), y/(1−h)), sized to the box's shape (at most 560 px wide,
  320 px tall at a square). The event is checked again (`parseFigureWalkthrough`: the server's bounds; an unusable
  part or box is dropped, never the walkthrough).
- **A part's ⋯** (a menu button, keyboard as the chat's ⋯): **Explain more simply** (`figure_simpler`, streamed under
  the part in a quiet box, Try again on failure), **Show in the paper** (its first cited paragraph with Back, else the
  figure), **Ask in chat about this** (an unsent draft with the part's text as the passage).
- **Kept:** per paper revision, figure, action (and part) and the default model, in memory for the browser session
  (as equation answers; never stored in the clear); reopening a figure shows its walkthrough and its simpler parts
  without a request. The image goes with the result, so crops need nothing more.
- **Endings:** a failure says why with Try again (`figure_unavailable`: the image couldn't be prepared in this
  browser); a walkthrough or words that ended early say "Interrupted · not charged" under them (CHAT.md); no credit
  counts anywhere.
- **Evidence:** `apps/web/tests/figure-view.test.ts` (the event's degradation rules and stream event; the request equal
  to the chat's with the action and one figure, `figure_view` with Visual answers off; crop arithmetic; the session's
  request, cache, words fallback, failures and refusals before sending) and the capability expectations in
  `tests/chat.test.ts`; `e2e/figure-view.spec.ts` on desktop and phone (opened with nothing sent; consent; three parts
  and the one crop's CSS; the request; more simply; Show in the paper; reopened from the cache; Ask in chat about this;
  a failed walkthrough tried again; the page's Ask in chat; words without a walkthrough, cut off and "Interrupted · not
  charged"), screenshots light and dark reviewed; the equation-view,
  reader-drafts, chat, chat-redesign and arxiv-html journeys still pass; `npm test`.

## One part extracted (owner, TestFlight 62, 2026-10-16) — removed from the clients 2026-10-21

*Removed from every client and deprecated on the server: see "Extract the subfigure removed" at the top. Kept here as
the record of what older builds (63–79) send.*

Owner, on a walkthrough's part: "a new button for 'Extract the subfigure and more context' where it opens up a loader
below, gets the info, and puts it below". Each part's menu now has **Extract the subfigure and more context**: a loader
under the part, then the region of the figure that part occupies, cropped on the device from the image that was sent,
and a closer reading of it with more of the paper (Up close). Unlike the walkthrough's boxes (rare by design), this one
always asks for a region.

**Server** (`chat-figure-view.ts`, `chat.ts`; staging): action `figure_detail`, validated like `figure_simpler` (paper
chat, numbered local context, consent v3+, `figure_view`, exactly one figure, no title or suggestions). The request is
the figure (F1) and the part as `selection.quote`: its label and title, a line break, its text. It uses the
walkthrough's own tool, `figure_walkthrough`, so the cached prefix (tools, model, thinking, shared instructions, paper)
stays the chat's byte for byte (test); `FIGURE_DETAIL_INSTRUCTIONS` after the paper ask for exactly one section with a
**required** box (tight around the part, not the whole figure), a closer reading of every detail in the region and more
context from the paper with `[¶N]`, 800–1,500 characters. Allowance: 2,500 tokens plus the effort's thinking. The call
is held back and checked (`figureDetail`: the first usable section with a usable box) and relayed once:

```
event: figure_detail
data: {"format":"figure-detail-v1","label":"(a)","title":"The RLHF pipeline","text":"Up close: … [¶12] …","paragraphs":[12,13],
       "box":{"x":0.02,"y":0.1,"w":0.45,"h":0.5}}

event: done
data: {"stop_reason":"end_turn","credits":3,…,"charged":true}
```

Field bounds as a walkthrough section; `box` always present and valid (inside the image, each side at least 0.04, not
the whole figure). Without a usable box (or no call), the words come as one `delta` (the call's words, else the model's
own): show them with "Couldn't crop this part". Billing as `figure`: shown → charged; nothing to show → `done
{charged:false, reason:"provider"}`; cut off → `reason:"limit"`. Logs `chat_figure_detail` / `_invalid_output` with
`called`, `boxes_offered`. **Migration 083** adds `figure_detail` to `chat_endings.action` and `worker_settle_chat`
(as 082 did for the other two); applied to staging 2026-10-16 ~15:45 UTC with the chat function (deploy checks 19 pass,
`chat.smoke` failing only because the Anthropic account was out of credit).

**Apps** (`FigureView.swift` `FigureDetail`, `ChatStream` `.figureDetail`, `FigureViewSession` `details`/`extract`,
`FigureExplainView` `detailBlock`): the menu item, a loader ("Extracting this part…"), then the crop (`figureView.section.N.detailCrop`)
and the reading (`…detail`); without a box, the words and "Couldn't crop this part; here is the closer reading." Kept on
the device with the walkthrough (`FigureAnswer.detail`; answers kept before it read as before); Try again on failure;
"Not charged." when the server says 0 credits; no credit counts. Fixture: the right half boxed; the whole-figure part as
words.

**Browser** (`figure-view.ts` `parseFigureDetail`, `detailQuote`; `chat.ts` event; `ChatSession.figure` with
`figure_detail`; `FigureView.tsx`): the same menu item and block, the crop as CSS over the sent image, kept for the
session. Fixture backend: part (a) boxed (left half), the Legend as words.

**Evidence**: `tests/backend/chat.test.ts` (validation, the cached prefix byte-identical to a chat's, instructions and
allowance, the check, relay, words without a box, billing); `tests/database/figure_view_actions.sql` (083: charged when
finished, not when the provider failed, a replay with another action conflicts); ScienceReaderCore `FigureViewTests`
(event, stream, request, kept answers); iPhone 17 Simulator `FigureViewJourneyTests` 2/2 (extract with crop, the
no-crop part, kept on reopen) with `FigureViewAppTests` and `ChatVisualTests`; browser `figure-view.test.ts`,
`figure-view.spec.ts` desktop and phone 6/6; `npm test`. Live: `node scripts/chat-live-smoke.mjs --figure-view=2
--paper=… --index=…` now also extracts the first part without a box (its box drawn to
`<paper>-<figure>-detail.png`); not yet run (the staging Anthropic account was out of credit).

## Build-69 feedback, 2026-10-18 (TestFlight 70 and browser deployed)

**Chat about Figure** opens the explanation/conversation view without generating; AI Explainer still requests
the walkthrough explicitly. Follow-ups and the walkthrough stay together. A part's Ask action focuses this
composer and fills an unsent draft. Every sent turn names the figure, attaches the same relevant image through
the existing figure resolver, and carries the caption plus bounded earlier explanation. Its encrypted anchored
conversation resumes on reopen without replacing the main chat's draft.

Native full/cropped/Up close images now support pinch, pan and double-tap zoom. Browser crops support two-pointer
pinch, pan, double-click and accessible minus/plus controls. Zoom is bounded to 1–8× and never re-crops a different
source region. Existing no-box behavior and explicit extract requests remain.

Tiny bitmap crops retain a usable minimum gesture area. The native acceptance pinches the actual UIKit view
and verifies the zoom percentage changes; it also checks saved detail recovery and the in-place unsent draft.
