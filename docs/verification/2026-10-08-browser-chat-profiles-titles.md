# Browser answer settings, titles and durable passage bindings

Status: independently reviewed local candidate on `codex/web-journal-20261008`, based on the reviewed journal checkpoint
`c2147cc`. Not deployed. This adapts the web-only donor changes `338e628` / `c286bdf` to the
durable journal; the shared contract was read from `chat-controls-titles` / `50d88d9`.
The public profile and labelled-event fixtures are copied verbatim from that branch's `3286b43`
into web-owned test fixtures. No backend or shared native source is changed.

## Behavior

- The existing composer has Model / Effort / Length, server-published estimates, Reset, a browser
  default and a retryable unavailable-table state. Selection actions carry the visible choice.
  A server returning 405 for the profile table receives the original default request shape.
- Send and Get answer capture their choice before any history/capability suspension. The sealed
  draft binds the latest local question to that choice; the active turn records its exact requested
  profile. Later controls, consent, text edits, lost append acknowledgement, cold restore and
  fresh-ID rebase cannot change that captured request. An unknown other-device question visibly
  offers a new explicit choice; recovery never requests an answer automatically.
- Discuss seals its bounded passage anchor with the draft and copies it to a new conversation
  root on Send. Failed save retains accessible text and anchor; retry does not prepend twice.
- Discard transfers an existing question binding into a fresh, already-owned empty composer in
  the same transaction as the old draft tombstone. Pending refused-turn cleanup disables Discard,
  keeping Retry device save reachable. A queued pre-rebase checkpoint resolves every event
  reference against the canonical mapping before it can write.
- Cloud message `model` / `profile` remain actual serving metadata. A complete answer and its
  generated title commit together. Title planning rechecks the latest journal revision: an
  existing topic title/rename omits a delayed generated title; an explicit rename supersedes all
  current conversation revisions. Lost-save retries retain exact identities and never buy another
  answer. Default requests and diagram repair omit unsupported profile/title fields.
- These optional sealed fields belong to the first, still-unshipped journal format. Earlier
  development records without them remain readable. This does not claim that an older writer
  preserves unknown future fields; changed write invariants require a format/admission gate.

## Local validation

- `npm test`: **265 tests / 21 files** pass on the final source. `npm run build` passes with the existing chunk-size
  warning. Real WebCrypto / spec IndexedDB tests cover anchors, malformed fields, lost-ack profile
  restore, canonical rebase, same-question choice immutability, discard transfer and peer-title
  races. Controller tests cover freeze-before-await, consent, late capabilities, missing captured
  options and reservation of the three-stream bound across capability waits. A real-AES peer-history
  regression also forces a rename to arrive during answer encryption in a deferred version-1 tab;
  its title write compares current conversation revision IDs and replans before publication.
- Production-CSP `chat-controls.spec.ts`, desktop + phone: **7 passed / 3 viewport skips**.
  Light/dark controls, keyboard choice navigation, estimates, labels, generated titles, both Rename
  entry points, defaults, selection actions, reload and 405 fallback pass. The durable lost-ack
  journey reloads a saved Opus / High / Detailed question with a newer draft, changes the next
  question's control to Haiku, then explicitly requests exactly one answer using the saved choice.
- Full production-CSP suite: **86 passed / 67 expected skips**, 153 cases, 5.2 minutes, on isolated
  loopback ports 54349 / 4337. The production build includes the profile/title/anchor/discard-transfer
  and rebase changes. Two narrow guards were added after this run's build: unresolved refused-turn
  cleanup disables Discard, and deferred version-1 title writes recheck their conversation heads.
  Both pass the final unit suite/build above. The root integration run will test these together
  with the App/navigation/Reader changes; this record does not claim the earlier 86-case run used
  those final two guards.
- Locally inspected screenshots:
  `.artifacts/visual/chat-controls-20261008/web/phone-light-controls.png` and
  `desktop-dark-answer-title.png`. The panel fits the narrow chat drawer; the dark answer retains
  the existing workspace and renderer, title, actual profile label and cost line.

The root's independent review cleared final title replanning, canonical journal references and
bindings, and unresolved-turn Discard guards with no new blocker. By integration-owner direction,
no separate full browser rerun was duplicated here after those guards: exact integrated-source
browser acceptance remains the root's next validation step. The App hooks in this candidate are
limited to Chat defaults and carrying the visible profile into a selection action; root owns
merging them with its newer navigation, Discuss/anchor and podcast integration.

No hosted/backend/provider request, migration, deployment or physical-phone work was performed.
The shared migration 047 and updated chat function remain a separate rollout prerequisite for
nondefault choices and generated titles. Gate 2 (durable library/reader copies), gate 3 (cold
offline startup), and Safari non-extractable X25519 persistence remain separate incomplete gates.
