# Learning guide: a product extension (proposal, 2026-10-14)

**Status: exploratory proposal. Nothing here is built, scheduled, deployed or reflected in any schema.** Owner
request (2026-10-14): "a slightly new product extension whereby the product is tailored to help you learn about ML
concepts, in a tailored way that reflects the ongoing state that it maintains about you over time… you are on a
figure, and you have a guide experience where the agent tries in real time to figure out what it needs to teach you
or show you in order for you to fully understand the complex thing that you are looking at, with a possible and
optional quiz component… the product focus would be partly about reading, discovery, but also AI-based acceleration
of ease of understanding, limited to the scope of ML work."

## The angle in one paragraph

Gradstep already reads papers faithfully, answers with citations that land on the passage, and surfaces papers worth
reading. The extension adds one thing: the app keeps a working model of what *you* understand about machine
learning and uses it to make the hard part of a paper teachable in place, on the figure, equation or paragraph you
are looking at, with an optional check that you got it. It is not a course and it never takes over the reader; it
is a guide that rides along with reading and discovery, limited to ML/AI papers.

## What the reader would experience

1. **Guide me on this figure.** Long-press or select a figure (or an equation, or a dense paragraph) and choose
   *Guide me*. The agent sees the caption, the paragraphs that reference the figure, the figure image itself, the
   paper's numbered context, and your learner state. It decides what you need first ("you have seen KL penalties
   in three papers, so the new idea here is the implicit reward") and explains in two to four short steps, each
   citing the passage it draws on (`[¶N]`, already jumpable) and each ending with one check-in: "Does the y-axis
   make sense now?" or "Want the derivation or the intuition?". The steps are a thread inside the existing chat,
   not a new screen, so page arrangement and navigation stay as they are.
2. **Explain at my level.** Every answer honours your level per concept rather than a global "beginner/expert"
   slider: terse where you are solid, deeper where you have a gap, and it says which it is doing.
3. **Optional quiz.** After a guide, or on demand: two or three questions generated from the paper and grounded in
   its blocks, graded by the model with feedback that cites the answer's passage. Results feed the learner state.
   Never unsolicited, never blocking.
4. **What this paper assumes.** Before or while reading: the paper's prerequisites mapped against your state, for
   example "Bradley–Terry model (new to you), KL-regularised RL (seen in 2 papers), LoRA (solid)". Each opens a
   one-minute primer that cites where the paper relies on it.
5. **Discovery that teaches.** A "learn next" lane in the Feed: the canonical paper behind a concept you keep
   asking about, or a paper that fills a gap your quizzes exposed. The server keeps ranking on public signals as
   today; the learner-aware part re-ranks on the device, because the learner state never leaves it.

## The learner state: what the app would know about you

- **Content.** One record per concept from a curated ML vocabulary (start with an authored list of a few hundred
  concepts; grow it by model extraction with `[¶N]` evidence and review): confidence (new, seen, working, solid),
  evidence (asked about, guided, quiz right/wrong, papers read that depend on it), last touched, and a short note
  the model wrote ("confuses the reward model with the reference model").
- **Where it lives.** On the device, end-to-end encrypted like conversations and reading activity, synced between
  your devices as encrypted events through the existing path. The server never reads it and keeps no analytics on
  it; this follows the Feed's standing rule that device-only signals are used only on the device. The model receives
  it from the device as part of the prompt, bounded (a few kilobytes), exactly as the numbered paper context is sent
  today, and the consent copy names it.
- **How it changes.** Explicitly: the model proposes updates through a tool (`update_learner_state`), the device
  applies them and shows "Noted: solid on attention scaling" with Undo. Implicitly: guides completed and quiz
  results. Always inspectable: a "What Gradstep thinks you know" screen lists every concept with its evidence; you
  can edit, reset, or turn the guide off. Confidence decays when a concept goes untouched for months.

## Why this fits the current system

- Numbered context and citations (Agent v2) mean every teaching step can point at the block it is built on, and
  the reader can jump there. Follow-up chips are already the UI for "what next"; guide steps are a structured form
  of the same thing.
- Selection actions (`related`, `relevance`, `ingest`) are the pattern: *Guide me* and *Quiz me* are two more
  actions in the same request contract. The server owns the instructions and the step format; both clients render.
- The reader index already carries figures with captions, alt text and asset paths, and the bridge can locate the
  paragraphs that reference a figure. The one new transport piece is sending the figure image (bounded, about
  1 MiB, from the HTML the reader already fetched to their device) alongside the text.
- Credits apply unchanged: a guide step is an ordinary answer; quiz grading is a small Haiku request like follow-up
  suggestions.
- Podcasts could later voice a guided explanation; out of scope here.

## What is genuinely new

1. **Concept vocabulary and extraction**: an authored seed list; model extraction of "concepts this paper relies
   on" with block evidence; tests on the corpus papers.
2. **Learner state**: an encrypted event type, device store and sync, the inspect/edit/reset screen, prompt
   serialisation, consent copy.
3. **Guide action**: server instructions and a step format (`guide_step {n, of, text, check}` events), a thread
   rendering inside chat on both surfaces, figure image attachment.
4. **Quiz**: grounded question generation, forced-tool grading, results into the state, card rendering in chat.
5. **Learn-next lane**: on-device re-rank of the Feed's list using the state.
6. **Evaluation**: fixture papers plus synthetic learners with golden guides and a rubric, run in the pre-build
   review so a change to the prompts is judged before a build (the UX review process already exists for this).

## Risks and how to bound them

- **Over-tutoring.** Off until the reader taps Guide; no unsolicited quizzes; one check-in per step; a "just
  explain it" escape on every step.
- **A wrong model of the reader.** The state is visible, editable and reversible; every update carries evidence;
  confidence decays; the first explanation after a wrong inference offers "I know this" to correct it in one tap.
- **Hallucinated pedagogy.** Every step and every quiz answer key must cite blocks; a server check rejects
  questions without resolvable citations, as Agent v2 already resolves `[¶N]`.
- **Cost.** A guide session is three to five answers (about $0.10–0.30 on Sonnet with the prompt cache); grading
  is about a cent. Prices show as today; the owner budget rules apply.
- **Privacy.** The learner state is the most personal data in the app; end-to-end encrypted, never on the server in
  the clear, named in consent.
- **Scope.** ML only; no general courses; no spaced repetition in a first version.

## A cheap prototype first (one to two days, no schema)

Build *Guide me on this figure* as a chat action with the caption, the referencing paragraphs and the image, a fixed
step/check-in format, and no learner state beyond a sentence the reader types once in Settings ("I know transformers
and PPO; new to preference optimisation"), stored encrypted on the device. Measure it on the DPO, Attention and Mamba
figures with the UX review captures and three to five paid live runs, and judge one thing: does it find the right
first thing to teach? Only then decide on the learner-state investment.

## Open questions for the owner

1. Learner state in v1: device-local per device, or synced through encrypted events from the start?
2. Quiz grading: model-graded only, or also self-assessment ("got it / not yet") as the cheaper default?
3. Guides as a thread in chat (recommended first: preserves page arrangement) or a stepper over the figure?
4. Sending figure images to the provider needs new consent copy (`cloud-ai-v3`): approve in principle?
5. Concept vocabulary: authored by you, derived from arXiv categories and paper terms, or both?

## How success would be judged

Time to "I get it" (one-tap self-report after a guide), guide completion, quiz accuracy trend per concept, repeat
use per paper, cost per guide session, share of steps whose citations resolve, and state edits or undos (a proxy for
wrong inferences).
