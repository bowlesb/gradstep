# The figure view: a walkthrough of a figure, on request (plan, 2026-10-16)

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
| `profile`, `capabilities`, `consent_version` | as the chat sends them (consent v3+ names figures) |

`figure` has the model call one tool, `figure_walkthrough` (forced), whose input the server checks
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

1. **Server** — `figure` and `figure_simpler` actions with the checked tool, tests (cached prefix byte-identical,
   validation, fallback), staging deploy, live smoke on DPO Figure 1, a multi-panel plot (2610.16784 InfoVis Figure 4) and
   a table, recording cost and time.
2. **Apps** — the buttons on the figure page, the walkthrough view with inline crops and the section menu, the local
   store, a fixture mode (`--chat-fixture-mode=figure_walkthrough`) and journeys (iPhone, iPad, Mac).
3. **Browser** — the same in the figure dialog; journeys on desktop and phone.
4. **Evaluation** — ten figures across recent papers (plots, diagrams, tables): are the details right, are boxes on
   the right regions, does every panel get a section; adjust the instructions; record per-figure cost.

## Choices made by default (owner may change)

- Entry from the figure page only (not a separate menu item on a tapped figure, which already opens that page).
- Up to 4 crops, chosen by the model; none is fine.
- "Back up a bit" = Explain more simply, inline under the section (the walkthrough stays in place); deeper questions go
  to chat.
