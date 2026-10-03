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
