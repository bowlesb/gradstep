# Learning guide: Study mode, the paper's AI Explainer, visual suggestions

**Status (2026-10-22):** design below (revision 2) is built. Server deployed to staging (chat function, no migration) and
checked live; apps and browser local until a release. Revision 1 (the 2026-10-14 exploratory proposal) is kept at the end as history.
The prompt evaluation is recorded in [Evaluation](#evaluation-of-the-tutor-prompt).

Owner, 2026-10-22 (verbatim): "I think 'Study Mode' is too complex and not a polished enough UX for now — my suggestion
is to have 'Enter Study Mode – Quiz me and help me learn' as an entry in the suggested questions, and then, we have a
mode that asks questions, and backs off a bit if concepts need to be explained a bit first — we need more clever thinking
and a good prompt for this, better than we have right now, I'll let you think through this one more time and try to
improve it one more pass. I'm not necessarily sure if the 'Knowledge Journey' Mermaid plots are well situated right now —
they are sometimes useful actually; my suspicion is that they should be part of a generic 'AI Explainer' feature for the
entire paper, and integrated as an option in the actual paper... why not this: in the Paper Settings, have an option that
takes you to an optional AI Explainer, with background list, and a diagram illustrating how the concepts fit together,
with the opening to a chat if the user wants it (same button icon to chat interface animation as in the figure AI
explainer). In addition to that, in the questions that are sometimes listed in the chat, have options like 'Create a
mermaid diagram explaining the background of X' (and equivalently, you can use html as well sometimes)."

## What was wrong with the first Study (2026-10-14 slice)

- **Too much surface.** A knowledge-map bar above the composer, a sheet or panel with three views (Map, Journey,
  Concepts), state chips and a legend: a second product inside the chat, asking the reader to manage a map while
  learning. The owner found it complex and unpolished.
- **Two requests per turn.** The tutor answered, then a separate Haiku call rebuilt the map from the tutor's reply
  without the paper. It cost a second model call each turn, could disagree with the tutor, lost maps to validation, and
  the map it produced was mainly for display.
- **A weak protocol.** "Judge, then one step, one bold question" had no notion of teaching before asking about a new
  idea, of hints, of spacing earlier ideas back in, of difficulty, or of the reader steering ("just explain it"). The
  first question was often a hard recall question about something the reader had never been shown.
- **The useful part was elsewhere.** A diagram of how a paper's concepts connect is helpful, but as a map of the
  *paper* (prepare me to read this), not as a scoreboard of the reader's answers.

## 1. Study mode, reworked

### What the reader sees

- **Entry.** "Enter Study Mode – Quiz me and help me learn" is always offered in a paper chat whose paper is numbered
  on this device (the tutor cites `[¶N]`), not dependent on the model's suggestions:
  - in an empty paper chat, as a row after the starter questions (the graduation-cap symbol);
  - under the newest answer, as the last item of the suggested questions;
  - in the chat's ⋯ menu as before (**Study mode** / **End study mode**; owner, build 57).
  One tap enters Study mode and sends the opening turn ("Quiz me and help me learn this paper."), with the selected
  passage when there is one. Unlike a suggested question it is a command, not text to edit, so it sends at once
  (reversible decision, [DECISIONS](../DECISIONS.md)).
- **While studying**, one slim row above the message box replaces the old knowledge-map bar: the words **Study mode**,
  then **Hint**, **Explain instead** and **Stop**. Hint and Explain instead send "Give me a hint." / "Explain it to me
  instead." as the reader's turn (disabled while the tutor is answering); Stop leaves Study mode at once, sends
  nothing, and keeps the conversation. The message box reads "Your answer". No map, no states, no legend, no counts.
- **The conversation is the product.** Each tutor turn is short: feedback on the answer, then either a step further,
  or a short explanation with a quick check, ending in exactly one bold question. Everything else (citations, math,
  diagrams on request, Save snippet, copy) works as in any answer. Follow-up suggestions are not shown beside a tutor
  turn (the tutor's question is the follow-up), so the study row is the only extra control.
- **Leaving and coming back.** Study mode lives with the open chat (memory), as before. Reopening the conversation
  later shows it as an ordinary chat; tapping Enter Study Mode again resumes: the tutor reads the earlier turns and
  starts with a quick look back at an idea from before.

### The tutor's loop (server instructions, `STUDY_INSTRUCTIONS`; v6 after the evaluation below)

A calibrated loop, one focused question at a time, grounded in the paper. Each turn has at most three short parts:

1. **Feedback** (when the reader answered): right, partly right or not yet, said plainly, plus one useful detail (the
   missing piece, the precise reason, the paper's own detail, cited `[¶N]`). Paraphrases count. No stock praise ("Spot
   on", "Exactly right") and no exclamation marks.
2. **The next move**, from the answer and the hidden notes:
   - right → one step further on the same idea (why, what if, apply it), or the next idea once this one is solid (two
     good answers, or one good answer to a hard question);
   - partly right → fill the gap in a sentence or two, then the same idea from another angle;
   - wrong, "I don't know", a guess, or a second shaky answer → **back off**: the idea from the ground up in at most five
     plain sentences with a concrete or tiny worked example (illustrative numbers allowed when labelled), then an easier
     check on the same idea (a choice between options, one step, the idea in their words);
   - a **misconception** → name the belief, say why the paper differs, ask a check that tells the two apart; stay on it
     until the reader no longer holds it, and make it the next look back;
   - a new idea → **teach before asking** (two or three sentences, a worked example for math); at intro and core level
     the question must be answerable from what was just said (give the reason before asking why);
   - "hint" → one hint that narrows without answering, then the same question, shorter;
   - "explain instead" → a clear explanation with a short example, then one light check on that idea;
   - a question from the reader → a brief answer, then a question on the same idea.
   An explanation covers one idea: never explain one idea and introduce the next in the same turn.
3. **One question**, the last line, in bold, written once: it asks for one thing (a second fact waits for the next turn),
   is answerable in a sentence or by choosing between options, and carries no citations; guidance goes before it.

**What to ask:** the ideas needed to understand the paper (problem, key method and why it works, main equations in
words, evidence, limits), central idea first, then outward. Retrieval, not recognition. **Spacing within the session:**
from the fourth question, every third or fourth is a "Quick look back:" at an idea already asked that was shaky or not
checked for a while (never a new idea). **Difficulty follows the reader** (intro / core / deep): up after two good
answers, down after a miss or a hint; a hesitant right answer is ok, not solid; at intro, words first and every symbol
said in words. **No trick questions**, nothing ambiguous, nothing the paper doesn't support, no long lists.
**Style:** warm, calm, direct; mistakes are normal; usually 60–120 words, never more than 150; math as `\( \)` and
`\[ \]`; single `[¶N]` markers; never invent the paper's numbers, results or quotes; never describe the method itself
(question counts, levels, schedules). **First turn:** one sentence on how it works, one setting the scene, an
approachable question on the central idea, then on its own line "(If this is new to you, say so and I'll explain it
first.)"; with earlier study in the conversation, a quick question on an idea from before.

### The hidden learner state

- **Written by the tutor itself, in the same reply** (no second request): after its question the tutor appends
  `<study_state>{…}</study_state>` with the turn number, the level the reader is ready for, the concepts taught or asked
  (the paper's term, status `new|shaky|ok|solid`, the turns that asked about it, its paragraphs) and a few words of plan
  ("check the KL term from a new angle; revisit Bradley–Terry around turn 6"). At most 12 concepts, 2 KB.
- **Never shown.** The server removes the block from the stream (a filter that holds back a possible tag prefix and
  swallows everything between the tags, wherever the model puts them), validates it, and relays it once as an SSE
  `study_state {state}` event before `done`. The device keeps it with the open chat (memory) and sends it back as
  `study_state` with the next study turn; the server places it after the tutor's instructions (after the paper, so the
  cached paper is reused). It is never stored on the server, never logged (counts only), never written to history.
- **Lossy by design.** A malformed block is dropped (the answer is unaffected); a lost state (relaunch, another device)
  is re-derived by the tutor from the conversation, which the instructions call the truth. The state is a hint for
  spacing and calibration, not a record of the reader.
- **Old builds** (TestFlight ≤ 81, browser pages loaded before the deploy) still send `study: {map}` and read `study`
  events. The server keeps accepting the old map (validated, ignored), sends the new instructions, strips the hidden
  block for them too, and no longer makes the Haiku map request: their tutoring improves and their map stays empty
  ("Built from your answers as you go"). No `study` event is sent any more.

### Contract changes (`POST functions/v1/chat`)

- `action: "study"` (paper, local context v2, selection optional, `follow_ups` refused) as before; `study` (old map) is
  now optional and ignored; new optional `study_state` object (≤ 4 KB raw, validated as below) only with `action:
  "study"`. Both are in the request digest when sent.
- Event `study_state {state}` with `{turn, level, concepts: [{name, status, asked: [n], paras: [N]}], next}`; the
  `study {map}` event is retired. Quote: no `study_*` fields (no side request). Settlement action `study` unchanged.

## 2. Paper AI Explainer

### What the reader sees

- **Entry:** the paper's ⋯ (Paper options) gains **AI Explainer** after "Ask about this paper" (an arXiv paper on this
  device). If this paper revision already has a kept explanation it opens at once; otherwise the model choice
  (AIChoiceView / the browser's model picker, the paper-chat scenario) and then the request, as the figure explainer
  does.
- **The page** (a sheet on iPhone/iPad, the Mac's sheet, the browser's dialog), in the figure explainer's look:
  1. the top row with the **Open in Chat** symbol (`bubble.left.and.text.bubble.right`, the figure explainer's) on the
     right, which continues this page's conversation in the paper's Chat with the same promotion and transition the
     figure explainer uses (`promoteContextualChat` / `promoteContextual`); the Mac and browser keep their X;
  2. the heading **AI Explainer** with the paper's title under it and the model's name;
  3. **In short**: two or three sentences (problem, what the paper does, main result);
  4. **Background**: 4–8 prerequisite concepts, most fundamental first, each one line ("**Bradley–Terry model** — turns
     pairwise preferences into a probability; DPO's loss starts from it") with its `¶N` links (each closes the page and
     lands on the paragraph, with Back);
  5. **How it fits together**: one Mermaid flowchart drawn on the device from the explainer's structure (background
     concepts in one quiet style, the paper's own ideas in the accent style, labelled arrows); tap for the full-screen
     diagram viewer. This is the useful part of the old Knowledge Journey, now about the paper;
  6. the contextual conversation and its composer at the bottom ("Ask about this explanation"), exactly as on the
     figure explainer.
- **Streamed, with the figure explainer's progress rules**: a stage label always ("Preparing…", "Reading the paper…",
  "Writing the summary…", "Writing background 2 of 6…", "Writing key idea 1 of 3…", "Drawing how it fits together…"), a
  determinate bar only while the announced count is known and not exceeded (10 % summary, then items, each item's share
  filled by its characters against a measured size, capped at 90 % of the item; never backwards; past the estimate it
  turns indeterminate), the skeleton at once, items appended as they arrive (content above never moves), the diagram
  drawn at the end, a fade out, Reduce Motion respected, one accessibility element announcing stage changes only.
- **Kept** per paper revision and model on the device (native: the sealed explanation store, folder `paper-answers`;
  browser: kept explanations, kind `paper`), so reopening shows it without a request. **Settings › Your assets ›
  Paper explanations** (browser: account menu › Your assets) lists them; a row opens the paper and its explainer.

### Request and response

- An ordinary paper-chat request on the chat's cached prefix (same tools and capabilities as the chat, so it reads the
  paper from the cache): `mode: "paper"`, numbered local context v2, one user turn ("Explain this paper"), no
  selection, no figures, `action: "paper_explainer"`, the reader's profile. Effort low when automatic or Gemini (as the
  figure view); an effort chosen for a Claude model stays. Output allowance 3,500 tokens plus the effort's thinking.
- The model writes one JSON object in its reply: `{"items": N, "summary": "…", "background": [{"id","name","line",
  "paragraphs"}], "ideas": [{…}], "links": [{"from","to","label"}]}`. The server reads it incrementally
  (`PaperExplainerStream`) and relays `paper_progress {stage, characters?, items?}`, `paper_summary {summary}`,
  `paper_item {kind: "background"|"idea", index, item}` (each checked exactly as the final one is), then the final
  `paper_explainer {format: "paper-explainer-v1", summary, background, ideas, links}`. Unusable JSON: the model's words
  as `delta` (shown as the description). No title, no suggestions. Settled as an ordinary answer (`answer` in the settlement record,
  `paper_explainer` in the `chat_answer` log), so it needs no migration: a migration numbered after the parallel usage
  work's 0144 would have broken that work's deploy (the deploy refuses an applied ledger that is not a prefix of the
  source).
- Checks (`paperExplainer`): summary ≤ 600 characters; background 1–10 and ideas 1–6 entries, each a unique slug id,
  name ≤ 60, line ≤ 240 (one line, `[¶N]` markers removed), paragraphs within the paper (≤ 6); links only between known
  ids, no self links or duplicates, label ≤ 40, at most 24. Null when there is no entry.
- Cost: about the figure walkthrough's (one answer of ~800–1,500 output tokens on a cached paper; Sonnet ~2–4 credits,
  Gemini ~1).

## 3. Visual suggestions in the suggested questions

- The follow-up request learns whether Visual answers are on. When they are, its instructions allow **at most one** of
  the two or three questions to ask for a picture of something concrete from this paper or answer: "Create a diagram
  explaining the background of X" (Mermaid), "Draw how X flows step by step", or "Show X as a visual" (the HTML visual
  answer). The server keeps only the first such question (a pattern check) and none when Visual answers are off.
- Clients show the generic "Draw a diagram" / "Create a visual explanation" rows only when the model offered no
  visual question (so the list stays short and specific), then the model's questions, then "Enter Study Mode – Quiz me
  and help me learn" in paper chats. A tap fills the message box as before; the answer draws with the existing
  `create_diagram` / `create_visual` tools.

## What is removed

Browser `StudyPanel.tsx`, the map types and Mermaid map in `lib/study.ts`, its styles; native `StudyMapViews.swift`,
the map in `ChatStudy.swift`, the knowledge-map bar and sheet, the map's fixtures and journeys; the server's
`update_study_map` request, its hold and quote fields. `chat-live-smoke.mjs --study` now prints each turn and the hidden
state.

## Evaluation of the tutor prompt

Method (`scripts/study-eval.mjs`): the server's own request for each tutor turn (runChat with stub dependencies, the
numbered paper from the browser's context builder, the previous hidden notes, the production OpenRouter adapter),
straight to OpenRouter under a spend ledger; the reply goes through the server's own notes filter, so the transcript is
what a reader would see. A simulated learner (Claude Haiku 5.5, no paper, a persona brief) answers each question.
Personas: **strong** (an ML PhD student, answers well with nuance), **weak** (an undergraduate: vague, hesitant; scripted
"Give me a hint." then "Explain it to me instead." for its second and third answers), **wrong** (confident, with
paper-specific misconceptions: for Attention, √d_k scaling is about float16 overflow, heads are stacked layers; for PPO,
clipping clips the gradient norm, PPO is off-policy with a replay buffer, the advantage is the step's reward). Papers:
Attention Is All You Need and PPO (mathpix bundles, 30–42 KB of numbered context). Tutor: Gemini 3.8 Flash at medium
(the recommended chat default) unless noted. Records: `.artifacts/study-eval/<time>-<label>.json` and `.md`
(transcripts and the notes after each turn); the prompt of each iteration is `prompt-v1.txt` … `prompt-v6.txt` there.
**Spend: $0.733 for the whole evaluation (160 calls, ledger `.artifacts/study-eval/spend.json`), under the $1 budget.**

| Iteration | Run | Turns | Notes written / leaked | Median / max words | Stock praise | Compound questions | `$…$` math | Look backs | Cost |
|---|---|---|---|---|---|---|---|---|---|
| v1 | Attention × 3 personas × 4 | 12 | 12 / 0 | 96 / 188 | 5 | 5 | 6 | 0 | $0.057 |
| v2 | Attention × 3 × 5 | 15 | 15 / 0 | 78 / 157 | 0 | 1 | 0 | 2 | $0.077 |
| v3 | Attention and PPO × 3 × 5 | 30 | 30 / 0 | 94 / 150 | 0 | 4 | 0 | 4 | $0.158 |
| v4 | PPO weak, wrong × 5 | 10 | 10 / 0 | 94 / 143 | 0 | 0 | 0 | 1 | $0.058 |
| v4 on Sonnet 5.5 (auto → low) | Attention strong, weak × 5 | 10 | 10 / 0 | 142 / 159 | 0 | 5 | 0 | 1 | $0.231 (incl. a first cache write) |
| v5 | Attention weak, wrong × 5 | 10 | 10 / 0 | 90 / 129 | 0 | 0 | 0 | 1 | $0.059 |
| v6 (shipped) | Attention wrong × 5 | 5 | 5 / 0 | 97 / 123 | 0 | 0 | 0 | 1 | $0.028 |

What each iteration showed and what changed:

- **v1 → v2.** The loop worked from the start (feedback, a step, one bold question; the hidden notes were written on
  every turn and never reached the text). Problems: stock praise on almost every strong answer ("Spot on!", "Exactly
  right. You nailed both…"); compound questions ("what limitation… and how does the Transformer overcome it?");
  citations and the "(If this is new…)" offer inside the bold question; `$…$` math the apps don't typeset; range
  citations "[¶40–¶43]" that don't link; a 180-word turn that explained the weak learner's question *and* introduced
  the next idea; and the misconception persona's float16 belief was corrected once and then marked solid while the
  learner still held it. v2 added: feedback says right/partly/not yet plainly and adds one useful detail, no stock
  praise or exclamation marks; the question asks one thing, has no citations, the offer on its own line; one idea per
  explanation; misconceptions are named and stay in focus until a check is passed; math as `\( \)`, single markers;
  150-word ceiling; look backs from the fourth question.
- **v2 → v3.** One question per turn, no praise, correct math. New problems: "Quick look back:" used for a new idea
  (Table 1 complexity, never asked before); a weak learner asked "why divide by √d_k?" right after the formula was shown
  but not explained, and a path-length question in O(n) notation. v3 added: look backs only to ideas already asked
  (in the notes); at intro and core level a question must be answerable from what was just taught (give the reason, or
  enough of it, before asking why); question form by level (intro: intuition, a choice, a plain prediction; core:
  mechanism; deep: trade-offs, edge cases); a hesitant right answer counts as ok, not solid. Result on both papers:
  the Attention misconception persona was corrected at T2, again at T3, given a look back on scaling at T4 and dropped
  the belief ("I'll drop the float16 idea"); the weak learner got a hint that narrowed without answering, then a worked
  example (token 1 to token 100 through 99 hidden states) and a two-way check it answered.
- **v3 → v4.** Remaining: "…, and why does this help?" questions (4 of 30), a question written twice (plain, then bold),
  and a notation-heavy explanation (`\hat{\mathbb{E}}[\log\pi…]`) for the weak PPO learner who asked for "the mismatch
  part more simply". v4 added: ask for one fact now and the other next turn; write the question once; at intro explain
  in words first and say what each symbol means. Result: PPO weak learner — hint ("compare the numerator and the
  denominator when θ equals θ_old"), then an explanation with an illustrative example (0.30 / 0.20 = 1.5; before any
  update 0.20 / 0.20 = 1), then "0.5, 1.0 or 2.0?", answered correctly; PPO misconception persona — all three beliefs
  named in one turn, the replay-buffer belief revisited as the look back at T4 and given up by the learner.
- **Sonnet 5.5 check (v4).** Same protocol and richer teaching (it derived the variance argument from the footnote for
  the weak learner, step by step), but longer turns (median 142 words, three over 150) and guidance inside the bold
  line ("Why does dividing… help? Think about how…"). v5 added: the bold line is only the question; the 150-word ceiling
  means an explaining turn does not also introduce the next idea at length.
- **v5 → v6.** One Gemini turn described the method ("Since this is our fourth question, let's revisit an earlier
  concept"), and a misconception reappeared after a look back on another idea. v6 (shipped): never mention the method
  (counts, levels, statuses, schedules); a misconception stays until the learner no longer holds it and becomes the
  next look back. v6 check: no method talk; the stacked-heads belief was corrected in the turn it appeared and again
  when the learner repeated it.

Live on staging after the deploy (DPO, Gemini 3.8 Flash medium, disposable account, `chat-live-smoke.mjs --study`):
four turns (opening, a partly right answer, "Give me a hint.", "I'm not sure. Is beta a learning rate?"), each
`delta…, study_state, done`, first text 2.7–4.8 s, 2 credits a turn, notes never in the text, the account deleted.

What the evaluation does not show: real readers (the learners are simulated by a model that has read these papers),
sessions longer than five turns, and DeepSeek or Opus as the tutor. The notes' statuses are the tutor's own judgement;
they are a planning aid, not a measurement of the reader.

**Paper explainer, same harness (`--explainer`).** Gemini 3.8 Flash (low): Attention and PPO, 4–5 background entries,
4–5 ideas, 8–9 links, summary at 2.8–4.5 s, whole 8.4–9.3 s, $0.005 each. Sonnet 5.5 (auto → low): Attention, 6 / 4 / 9,
summary 2.7 s, whole 9.6 s, $0.019. After the first runs the instructions were tightened (the last idea is the main
result with its headline number; short names): Attention's last idea became "28.4 BLEU on English-to-German and 41.8 on
English-to-French", PPO's "a top normalized score of 0.82 on MuJoCo" — both the papers' own numbers. Live on staging
(DPO, `chat-live-smoke.mjs --paper-explainer`): Gemini summary 5.2 s, nine entries 5.6–8.9 s, whole 9.9 s, 2 credits;
Sonnet summary 3.3 s, ten entries (nine announced) 4.0–10.7 s, whole 12.4 s, 5 credits; in both the streamed entries
equalled the final explainer. The follow-up suggestions on a normal DPO answer included "Create a diagram explaining how
the DPO loss turns preference pairs into an implicit reward" (one visual question of three).

---

## History: revision 1 (exploratory proposal, 2026-10-14)

Owner request (2026-10-14): "a slightly new product extension whereby the product is tailored to help you learn about ML
concepts, in a tailored way that reflects the ongoing state that it maintains about you over time… you are on a figure,
and you have a guide experience where the agent tries in real time to figure out what it needs to teach you or show you
in order for you to fully understand the complex thing that you are looking at, with a possible and optional quiz
component… the product focus would be partly about reading, discovery, but also AI-based acceleration of ease of
understanding, limited to the scope of ML work."

The proposal: a learner state kept on the device (a concept vocabulary with confidence and evidence, end-to-end
encrypted and synced as events, inspectable and editable), a *Guide me* action on a figure, equation or passage
(2–4 cited steps, each with a check-in), an optional grounded quiz, "what this paper assumes" mapped against the
learner state, and a learner-aware "learn next" lane in the Feed. Risks named then still hold: over-tutoring (never
unsolicited), a wrong model of the reader (visible, reversible), hallucinated pedagogy (every step cites blocks), cost
and privacy (the learner state is the most personal data in the app). Since then the figure and equation explainers
shipped the *Guide me* idea per element; revision 2 adds the paper-level explainer ("what this paper assumes") and a
simpler Study mode. Still not built: a persistent cross-paper learner state, spaced repetition across sessions, the
learn-next lane.

Open questions carried forward for the owner:

1. Keep the hidden study state with the conversation (a sealed field on the tutor's answers) so Study mode resumes
   across relaunch and devices?
2. A persistent, inspectable learner state across papers (revision 1's core idea): worth building after this?
