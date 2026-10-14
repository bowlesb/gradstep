# Pre-build UX review

How a screen is judged before the owner installs a build (owner request, 2026-10-14: "how to accelerate testing,
and work out UX issues… before I even try a new build"). The review is a fixed set of deterministic captures of
both surfaces, a written pass over them against the heuristics below, and the fixes made before any build or
deployment. It complements [visual checks](VISUAL_CHECK.md) (native before/after comparison) and the recorded
[test sessions](SESSION_REVIEW.md); it replaces neither owner acceptance on the device nor the slow suites.

## Commands

| Surface | Command | Output |
|---|---|---|
| Browser | `node scripts/ux-review.mjs` | `.artifacts/ux/web/index.html`: sign-in, library, reader, the chat states (consent, waiting, streaming, answer with citations and follow-ups, citation jump, follow-up filled, answer settings, no credits) and All chats, desktop and phone, light and dark; 48 captures, about 35 s |
| Native | `node scripts/visual-check.mjs capture --label=<name> --scenarios=chat-answer,chat-conversation,chat-sources,paper,library --devices=iphone,ipad --variants=light,dark` | `.artifacts/visual/<name>/…` plus `sheet` and `compare` (see VISUAL_CHECK.md); about 5 minutes including the build |

Both run on the local fixture backends: no hosted request, no paid provider call, no account. A capture that fails
is a product or fixture defect, not something to retry.

## Heuristics (the pass)

Judge each capture on, in order: what the reader is trying to do on that screen, whether the primary action is
obvious and reachable with the thumb or keyboard, whether every visible word earns its place (no caveats that repeat
on every screen, no labels that say nothing), whether the state is honest (what was sent, saved, paid), whether a
wait explains itself, whether text and math stay readable at phone width and in dark, and whether the same idea
reads the same on both surfaces. Write the findings with the capture name and fix what can be fixed before
building; the rest becomes a dated row in [owner feedback](OWNER_FEEDBACK.md) or a decision proposal.

## 2026-10-14 pass: the agent

Captures: `.artifacts/ux/web/` (browser) and `.artifacts/visual/agent-v2/` (iPhone). Findings and what changed:

- **Answers pointed nowhere.** "See Section 3.2" cost the reader a search. Answers about device-prepared papers now
  cite `[¶N]` and the marker is a control that lands on the block, with Back; the same on iPhone, iPad, Mac and
  the browser ([contract](architecture/CHAT.md#agent-v2-2026-10-14-numbered-context-grounded-citations-follow-ups)).
- **Dead end after an answer.** Nothing suggested what to ask next. Two or three one-tap follow-ups now sit under the
  newest answer on both surfaces; a tap fills the message box and leaves sending to the reader.
- **Caveat on every keystroke (browser).** The composer repeated a two-sentence storage warning under the message
  box at all times. It now shows one short status ("Saved on this device.", "Saving draft…", a failed save, a
  stopped tab, or the non-durable warning) and keeps "Shift+Enter for a new line" as the box's tooltip.
- **A frozen "Thinking…" (browser).** A long first wait gave no sense of time. After five seconds it shows the
  seconds elapsed; server status lines (searching, reading, adding a paper) still replace it.
- **Phone width.** Citation chips and follow-ups wrap cleanly at 390 pt in light and dark; math stays legible.
- Still open for the owner: the native chat header density ("Chat top is too cluttered", build 15) needs a
  comparison on the current build; the 1-hour prompt cache is a cost choice (see IMPLEMENTATION_STATUS.md).
