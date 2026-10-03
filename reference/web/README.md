# Paper Reader

A self-hosted, AI-powered research paper reader. Upload PDFs, read them in a clean HTML viewer, and chat with Claude about the content — with streaming responses, tool use, and diagram generation.

Works on desktop, tablet, and iPhone.

## Features

- **PDF ingestion** — Upload PDFs directly, paste URLs, or bulk-ingest from a local folder. Papers are converted to HTML via Mathpix and metadata (title, authors, year, abstract) is extracted automatically.
- **AI chat** — Ask Claude about any paper. Streaming responses with agentic tool use: web search (Tavily), library search, paper ingestion, and diagram generation (Mermaid/SVG/LaTeX).
- **Text selection actions** — Select text in a paper and click "Define" or "Relevance" to start a new chat about that passage.
- **Full-text search** — Search your library by title, authors, abstract, or venue using PostgreSQL full-text search with ranking.
- **Responsive UI** — Three-panel desktop layout, resizable panels on tablet, bottom tab bar on mobile.
- **PWA** — Installable as a home screen app on iOS and Android.
- **Diagrams** — Claude can generate Mermaid flowcharts, SVG diagrams, and LaTeX math visualizations, stored and rendered inline in chat.

## Architecture

```
Next.js 14 (React 18, TypeScript)
├── Frontend: react-resizable-panels, react-markdown, KaTeX
├── Backend: Next.js API routes
├── Database: PostgreSQL 16 (FTS with GIN index)
└── External APIs: Anthropic Claude, Mathpix, Tavily, Semantic Scholar, arXiv
```

## Setup

### Prerequisites

- Docker and Docker Compose
- API keys for: [Anthropic](https://console.anthropic.com/), [Mathpix](https://mathpix.com/), [Tavily](https://tavily.com/)

### 1. Create `.env.local`

```bash
ANTHROPIC_API_KEY=sk-ant-...
MATHPIX_APP_ID=your_app_id
MATHPIX_APP_KEY=your_app_key
TAVILY_API_KEY=tvly-...
```

### 2. Start

```bash
docker compose up -d
```

The app will be available at **http://localhost:3321**.

PostgreSQL data persists in a Docker volume (`pgdata`). Tables are created automatically on first request.

### 3. Upload a paper

Click the upload button in the library, select a PDF, and wait for conversion. Once ready, click the paper to open it.

### Bulk ingestion

Place PDFs in an `input/` directory (mounted read-only into the container), then:

```bash
./ingest-local.sh
```

Or ingest by URL via the upload modal.

## API

| Route | Method | Description |
|---|---|---|
| `/api/papers` | GET | List papers (supports `?q=`, `?sort=`, `?order=`, `?id=`) |
| `/api/papers?id=xxx` | DELETE | Delete a paper and all related data |
| `/api/upload` | POST | Upload a PDF (multipart form) |
| `/api/ingest` | GET | Queue status |
| `/api/ingest` | POST | Add URLs, retry failed, clear completed, or ingest local files |
| `/api/chat` | POST | Streaming chat (SSE) with tool use |
| `/api/chats?paperId=xxx` | GET | List chats for a paper |
| `/api/chats/:id/messages` | GET | Get messages for a chat |
| `/api/diagrams/:id` | GET | Render a diagram as HTML |
| `/api/backfill` | POST | Extract metadata for papers missing it |

## AI Chat

The chat uses a two-model strategy:

- **Step 0**: Claude Sonnet with the full paper cached in the system prompt
- **Steps 1+**: Claude Haiku for processing tool results (cost-efficient)
- **Fallback**: If Sonnet is rate-limited, falls back to Haiku

Available tools:

| Tool | Description |
|---|---|
| `tavily_search` | Web search for context not in the paper |
| `search_library` | Full-text search across your paper library |
| `ingest_paper` | Find and queue a paper by title/year (Semantic Scholar + arXiv) |
| `create_diagram` | Generate Mermaid/SVG/LaTeX diagrams saved to the database |

Max 5 agentic steps per response. Prompt caching is logged for cost tracking.

## Project Structure

```
app/
  page.tsx              Main app (state, view modes, mobile tabs)
  layout.tsx            Root layout, PWA meta tags
  globals.css           Theme variables, mobile styles
  api/                  All backend routes
components/
  ChatPanel.tsx         Chat UI with history
  LibraryView.tsx       Paper browser with search
  MarkdownReader.tsx    PDF viewer with text selection
  PaperTable.tsx        Paper list (table on desktop, cards on mobile)
  MobileTabBar.tsx      Bottom tab navigation
  CollapseHandle.tsx    Panel collapse buttons
  UploadModal.tsx       Upload form
hooks/
  useDeviceType.ts      Responsive breakpoint detection
lib/
  db.ts                 PostgreSQL queries, schema, migrations
  ingest.ts             Background queue processor
  mathpix.ts            Mathpix API client
  metadata.ts           Claude metadata extraction
  paper-search.ts       Semantic Scholar + arXiv search
```

## Database

Five tables, auto-created on first use:

- **papers** — Document storage with full-text search vector
- **chats** — Conversation sessions linked to papers
- **chat_messages** — Message history
- **ingestion_queue** — Background processing with retry logic
- **diagrams** — Generated visualizations
- **cache_logs** — Anthropic API usage tracking

## Responsive Design

| Breakpoint | Layout |
|---|---|
| Mobile (< 768px) | Full-screen views with bottom tab bar (Library / Paper / Chat) |
| Tablet (768-1023px) | Side-by-side panels with 24px touch-friendly resize handles |
| Desktop (>= 1024px) | Three layout modes: Library, Reader (PDF + Chat), Browse (Library + PDF) |

## License

Private.
