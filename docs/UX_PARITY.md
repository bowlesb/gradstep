# Existing UX to preserve

Status: source-derived interaction reference, 2026-10-02. Visual fidelity still needs simulator/device comparison against locally rendered reference screens. The NAS deployment has not been operated or altered.

References: `reference/web/app/page.tsx`, `components/MobileTabBar.tsx`, `MarkdownReader.tsx`, `ChatPanel.tsx`, `LibraryView.tsx`, `ResearchFeed.tsx`, `AllChatsView.tsx`, `AllDiagramsView.tsx`, and `FigureViewer.tsx`.

## Main navigation

| Surface | Existing arrangement | Native requirement |
|---|---|---|
| iPhone | Feed, Library, Paper, Chat, Settings bottom tabs | Same order, naming, and destinations |
| Initial state | Library | Keep Library as the initial destination |
| Paper tab | Inactive until a paper is loaded | Preserve prerequisite and current-paper continuity |
| Larger layouts | Feed, Library, Reader, Browse, General Chat modes | Preserve mode purposes and switches; adapt split sizing to iPad |
| Reader | Paper and chat, with collapsible/resizable panels as applicable | Preserve paper/chat relationship and panel controls |
| Browse | Library alongside paper | Preserve discovery-to-reading flow |
| All chats / All diagrams | Secondary full-screen views/overlays with close behavior | Do not turn them into new primary tabs |
| Figures | Paper-specific viewer with return/jump to figure | Preserve context and return destination |
| Settings | Reading appearance, reports, account/admin utilities | Put new account/credit/device controls here without reorganizing main navigation |

## Interactions

- Opening a paper keeps the current paper available when changing tabs. Preserve library search/sort/filter state on return.
- Preserve separate paper-specific and general chat modes and their history entry points. Starting a new chat cancels the old generation's UI effects so late callbacks cannot replace the new conversation.
- Text selection actions are **Define**, **Relevance**, **Similar**, and **Ingest**. Preserve passage-linked conversations and the ability to jump back to the source passage.
- Mobile/tablet selection actions currently start a new paper conversation and send the action. Preserve that behavior after any required first-use cloud-processing consent; desktop currently prepares the prompt before sending.
- Preserve table of contents, figure opening/jump-back, chat history, diagram browsing, cancel-generation behavior, dark mode, separate paper/chat font scaling, and offline download actions.
- Keep figures/diagrams as separate concepts: figures originate in papers; diagrams originate in conversations and therefore may contain private content.
- Keep existing library/external search and feed-add flows. New duplicate detection should reuse processing without changing where users add papers.

## Authorized refinements

Spacing, typography consistency, formatting, safe-area handling, accessible tap targets, VoiceOver labels, contrast, loading/error wording, and native keyboard behavior may improve. Keep the restrained existing light/dark palette and indigo accent as the starting point. Changes to navigation hierarchy, default actions, or primary layout require a concrete proposal to the user.

New collection/tag/export/account controls should fit existing screens or their menus. Do not replace the library with a new dashboard, merge paper and general chat, or add an onboarding sequence that obscures why recovery is needed. Security enforcement changes to the old backend are required without carrying its auth bypass or global private data into the new app.

## Capture matrix for implementation

Capture and compare iPhone portrait, iPhone landscape, iPad full-screen, and iPad narrow multitasking for: initial library, search, selected paper, paper/chat transition, selection actions, figures, diagrams, chat history, feed, Settings, and internal report composer. Exercise large Dynamic Type and keyboard presentation. Use realistic math/table-heavy fixtures; do not measure parity using empty placeholder screens alone.

## Workflow quality checkpoint, 2026-10-03

The user specifically requested complete workflow simulations and independent review for complex end-to-end designs. The archived implementation is an interaction reference, not an acceptable quality baseline. Preserve useful arrangements while improving speed, reliability, and UX details. All physical iPhone work is paused at the user's request; use local tools and Simulator until resumed.

| Journey | Acceptance checkpoints |
|---|---|
| Find an existing paper | Search title/author/topic; ignore surrounding whitespace; distinguish an empty library from no matches; optional metadata never creates blank rows; preserve query, sort, and reading context on return |
| Discover and add | Distinguish external results from library matches; latest query owns the response; failures are not empty results; add without leaving search; show a durable pending addition alongside existing papers |
| Import and tag | Same operation retries safely; pin source revision; no duplicate paid conversion; progress survives restart; removal fences late completion; readable content survives tagging failure; retry metadata independently; automatic topics do not overwrite private labels |
| Paper and chat | Paper chat requires a paper identity; header matches that identity; Browse opens the chat when requested; drafts remain with their conversations; switching modes preserves reading position |
| Send, leave, and return | Local durable save is independent of slow sync; old completion cannot select a new chat or erase a newly edited draft; account changes reject old work; a new conversation and its first message commit atomically |
| Stream and stop | Stable text metrics for partial/final Markdown, math, tables, and code; follow only near the bottom; user can read earlier text; stop restores controls and retains an interrupted encrypted result; late tokens cannot change another conversation |
| Keyboard and dismissal | Keyboard can be dismissed without discarding input; history/figures return to their origin; repeated contents jumps work; headings, controls, and messages remain usable at large text sizes |

Each check must distinguish source review, deterministic simulation, and live service evidence. Search/import/tag generation/provider streaming are still incomplete; a fixture does not establish those integrations. Review findings and implemented regression checks are recorded in IMPLEMENTATION_STATUS.md. Signed-in drafts now use encrypted device-local checkpoints across process termination; guest drafts remain session-only. Never store drafts in plaintext preferences. Mathpix conversion, durable equation/figure assets, and an equation-heavy actual-paper walkthrough remain required for reader completion; displaying an original PDF alone does not satisfy this gate.

## Earlier implementation history reviewed

The 2026-10-03 read-only review found three retained NAS commits: initial `f39d483`, README `0946ca8`, and broad feature/fix commit `406dbb4` (2026-03-20). Later uncommitted source fixes are also relevant. SHA-256 comparison confirmed the local `page.tsx`, `ChatPanel.tsx`, `MarkdownReader.tsx`, `mathpix-cleanup.ts`, and iOS viewport note match the NAS working files. Reads stayed inside the authorized project; no NAS files were written. Seven project-contained OCR error logs were inspected only for bounded sanitized diagnostic categories. Docker runtime logs and PostgreSQL bug reports were not accessed because they lie outside the permitted project-file scope.

| Historical fix or defect | Regression obligation |
|---|---|
| `406dbb4`: text disappeared between agent/tool steps | Accumulated answer remains visible when tool status changes |
| `406dbb4` and later EOF/timeout changes: partial answers disappeared on errors | Save partial text as interrupted; restore controls; do not silently treat EOF as completed |
| Later generation fencing and stream aborts | New chat/history/paper/account owns its UI; old callbacks cannot mutate it |
| Later Stop handler increments generation before abort but stale catch/finally skip cleanup | Finalize the owning stopped turn before invalidating callbacks; this is a source finding, not a reproduced runtime failure |
| Near-bottom autoscroll and Go to Selection | Earlier text stays still while streaming; return waits for the correct artifact to load and works repeatedly |
| Queue polling avoided overlap, but non-OK response can exit before rescheduling | Bounded polling/reconnect retry survives one transient error and refreshes completed additions |
| Duplicate TOCs, caption detection, tiny figure icons, flat OCR headings, References | Use fixture documents to verify cleanup and navigation without dropping real figures or altering mathematical/text meaning |
| Incomplete live HTML, GFM tables, both LaTeX delimiter conventions | Use a safe partial renderer and identical final metrics; native chat rendering still needs this work |

Do not port the archive's later 11px chat text or hard-coded PWA `screen.height` workaround. Test native Dynamic Type, safe areas, rotation, keyboard, and split view directly. Source locations: `reference/web/app/page.tsx` (chat/queue lifecycle), `components/ChatPanel.tsx` (scroll/rendering), `components/MarkdownReader.tsx` (selection/reader navigation), `lib/mathpix-cleanup.ts`, and `docs/ios-pwa-viewport.md`.

### Application to the current Swift implementation

The callback-ownership lesson applies now to encrypted saves and sync, even before AI streaming exists. `ChatWorkspace` gives each composer and edit its own identity; `ReaderModel` publishes coherent store generations. Native tests force New Chat, history selection, identical replacement drafts, and older snapshot delivery during pending work. New conversation roots and their first messages use one local transaction rather than exposing an empty conversation after a partial failure.

The navigation lesson also applies now: reading locations are remembered per immutable artifact during the session, a contents jump waits for reader readiness, and repeated jumps have distinct request identities. Reader callbacks belong to an account session, document, and artifact; switching artifacts clears old headings, selection actions, and figure presentation without discarding the original artifact's reading position. iPhone and iPad journeys exercise contents → chat → paper. This does not yet implement durable passage anchors or cross-device resume positions.

The near-bottom rule informs the native keyboard/composer tests: verify actual reply frames, deliberately scroll to an earlier passage, grow the composer, dismiss the keyboard, and inspect screenshots for obscured text or misplaced controls. Test scrollback independently from following the newest answer; a passing navigation assertion alone cannot establish usable layout.

An incoming message with role `user` may have been written on another device. It must not be treated as a local send gesture that replaces deliberate scrollback. Accepted local submissions and explicit branch choices carry separate composer-scoped scrolling intents; ordinary synced head changes respect the current reader position. An old composer's intent cannot move the newly selected chat.

Apple documents lazy-stack content size and offsets as estimates, so those values alone cannot establish that the final reply is visible. The SwiftUI transcript experiments repeatedly stalled during the iOS 26.4 keyboard/scrollback fixture. Traces did not establish an exact internal framework cause. [Apple's lazy-stack guidance](https://developer.apple.com/videos/play/wwdc2026/321/).

The transcript now uses reusable, self-sizing `UITableView` cells with the same SwiftUI message renderer in `UIHostingConfiguration`. Native scrolling owns following and deliberate scrollback. A saved visible row ID and its viewport-relative offset survive bounds changes; an unrealized anchor is measured before restoration, and a surviving visible neighbor handles removal. Snapshot updates are serialized; a new account session or composer creates a separate table, and retirement clears the old hosted cells. Actual final-message frames and unchanged older-passage offsets remain the acceptance checks. This changes the scrolling implementation without rearranging navigation or rendering the entire history eagerly. [Apple's table-cell hosting API](https://developer.apple.com/documentation/swiftui/uihostingconfiguration).

Tool-step text retention, partial-stream persistence, Stop settlement, import polling, and OCR cleanup remain required for the corresponding unfinished features. They have not been “ported” by adding a completed-chat fixture. Use the historical failures to construct interrupted-stream, transient HTTP, and math/table/figure fixtures when those services and renderers are connected.
