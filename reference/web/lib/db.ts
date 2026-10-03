import { Pool } from "pg";

export const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

// Auto-create tables on first use
let initialized = false;
async function ensureTable() {
  if (initialized) return;

  // Papers table (base schema for fresh installs)
  await pool.query(`
    CREATE TABLE IF NOT EXISTS papers (
      id TEXT PRIMARY KEY,
      title TEXT,
      html TEXT NOT NULL,
      markdown TEXT NOT NULL,
      authors TEXT,
      year INTEGER,
      venue TEXT,
      abstract TEXT,
      keywords TEXT,
      search_vec tsvector,
      created_at TIMESTAMPTZ DEFAULT NOW(),
      last_opened_at TIMESTAMPTZ
    )
  `);

  // Migration: add columns if they don't exist (for existing DBs)
  // This MUST run before trigger/index setup since old tables lack these columns
  const cols = ['authors TEXT', 'year INTEGER', 'venue TEXT', 'abstract TEXT', 'search_vec tsvector', 'last_opened_at TIMESTAMPTZ', 'keywords TEXT', 'toc JSONB'];
  for (const col of cols) {
    await pool.query(`
      DO $$ BEGIN
        ALTER TABLE papers ADD COLUMN ${col};
      EXCEPTION WHEN duplicate_column THEN NULL;
      END $$
    `);
  }

  // FTS trigger function and trigger (safe now that search_vec column exists)
  await pool.query(`
    CREATE OR REPLACE FUNCTION papers_search_vec_update() RETURNS trigger AS $$
    BEGIN
      NEW.search_vec :=
        setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(NEW.authors, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(NEW.abstract, '')), 'C') ||
        setweight(to_tsvector('english', coalesce(NEW.keywords, '')), 'C') ||
        setweight(to_tsvector('english', coalesce(NEW.venue, '')), 'D');
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
  `);

  await pool.query(`
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'papers_search_vec_trigger'
      ) THEN
        CREATE TRIGGER papers_search_vec_trigger
          BEFORE INSERT OR UPDATE ON papers
          FOR EACH ROW EXECUTE FUNCTION papers_search_vec_update();
      END IF;
    END $$
  `);

  // GIN index for FTS
  await pool.query(`
    CREATE INDEX IF NOT EXISTS idx_papers_search_vec ON papers USING GIN (search_vec)
  `);

  // Backfill search_vec for existing rows that have null search_vec
  await pool.query(`
    UPDATE papers SET title = title WHERE search_vec IS NULL
  `);

  // Chats table - links to papers, optionally to a highlighted text region
  await pool.query(`
    CREATE TABLE IF NOT EXISTS chats (
      id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
      paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
      title TEXT,
      highlight_text TEXT,
      highlight_anchor TEXT,
      created_at TIMESTAMPTZ DEFAULT NOW(),
      updated_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  // Chat messages
  await pool.query(`
    CREATE TABLE IF NOT EXISTS chat_messages (
      id SERIAL PRIMARY KEY,
      chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  // Cache usage logs for observability
  await pool.query(`
    CREATE TABLE IF NOT EXISTS cache_logs (
      id SERIAL PRIMARY KEY,
      paper_id TEXT REFERENCES papers(id) ON DELETE SET NULL,
      chat_id TEXT REFERENCES chats(id) ON DELETE SET NULL,
      cache_creation_input_tokens INTEGER DEFAULT 0,
      cache_read_input_tokens INTEGER DEFAULT 0,
      input_tokens INTEGER DEFAULT 0,
      output_tokens INTEGER DEFAULT 0,
      created_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  // Ingestion queue for bulk/URL-based paper ingestion
  await pool.query(`
    CREATE TABLE IF NOT EXISTS ingestion_queue (
      id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
      source_url TEXT NOT NULL,
      filename TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending',
      error TEXT,
      paper_id TEXT,
      retry_count INTEGER NOT NULL DEFAULT 0,
      max_retries INTEGER NOT NULL DEFAULT 3,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);

  // Add metadata columns if they don't exist (migration for existing DBs)
  for (const col of [
    ["parsed_title", "TEXT"],
    ["parsed_authors", "TEXT"],
    ["parsed_year", "INTEGER"],
  ]) {
    await pool.query(`
      ALTER TABLE ingestion_queue ADD COLUMN IF NOT EXISTS ${col[0]} ${col[1]}
    `);
  }

  // Startup recovery: reset items stuck in active states back to pending
  await pool.query(`
    UPDATE ingestion_queue
    SET status = 'pending', updated_at = NOW()
    WHERE status IN ('downloading', 'converting', 'extracting')
  `);

  // Diagrams table — stores generated HTML diagrams linked to papers/chats
  await pool.query(`
    CREATE TABLE IF NOT EXISTS diagrams (
      id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
      paper_id TEXT REFERENCES papers(id) ON DELETE CASCADE,
      chat_id TEXT REFERENCES chats(id) ON DELETE SET NULL,
      title TEXT NOT NULL,
      description TEXT,
      body_html TEXT NOT NULL,
      created_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  // Migration: make paper_id nullable on chats and diagrams (for generic chat mode)
  await pool.query(`
    DO $$ BEGIN
      ALTER TABLE chats ALTER COLUMN paper_id DROP NOT NULL;
    EXCEPTION WHEN others THEN NULL;
    END $$
  `);
  await pool.query(`
    DO $$ BEGIN
      ALTER TABLE diagrams ALTER COLUMN paper_id DROP NOT NULL;
    EXCEPTION WHEN others THEN NULL;
    END $$
  `);

  // Research feed — discovered papers from Semantic Scholar
  await pool.query(`
    CREATE TABLE IF NOT EXISTS research_feed (
      id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
      topic TEXT NOT NULL,
      title TEXT NOT NULL,
      authors TEXT,
      year INTEGER,
      publication_date TEXT,
      pdf_url TEXT NOT NULL,
      abstract TEXT,
      citation_count INTEGER DEFAULT 0,
      source TEXT NOT NULL DEFAULT 'semantic_scholar',
      external_id TEXT,
      fetched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE(pdf_url, topic)
    )
  `);

  // Feed metadata — tracks per-topic refresh timestamps
  await pool.query(`
    CREATE TABLE IF NOT EXISTS feed_metadata (
      topic TEXT PRIMARY KEY,
      last_refreshed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      paper_count INTEGER DEFAULT 0
    )
  `);

  // Paper figures — extracted images with captions from paper HTML
  await pool.query(`
    CREATE TABLE IF NOT EXISTS paper_figures (
      id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
      paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
      figure_number TEXT,
      src TEXT NOT NULL,
      caption TEXT,
      context TEXT,
      sort_index INTEGER NOT NULL DEFAULT 0,
      created_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);
  await pool.query(`
    CREATE INDEX IF NOT EXISTS idx_paper_figures_paper_id ON paper_figures (paper_id, sort_index)
  `);

  // Bug reports — user-submitted issues with screenshots
  await pool.query(`
    CREATE TABLE IF NOT EXISTS bug_reports (
      id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      screenshots JSONB DEFAULT '[]'::jsonb,
      status TEXT NOT NULL DEFAULT 'open',
      page_url TEXT,
      user_agent TEXT,
      created_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  // Auth users — simple username/password authentication
  await pool.query(`
    CREATE TABLE IF NOT EXISTS auth_users (
      id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
      username TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      created_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);

  // Auth sessions — cookie-based session tokens
  await pool.query(`
    CREATE TABLE IF NOT EXISTS auth_sessions (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES auth_users(id) ON DELETE CASCADE,
      created_at TIMESTAMPTZ DEFAULT NOW(),
      expires_at TIMESTAMPTZ NOT NULL
    )
  `);

  initialized = true;
}

// ─── Papers ───────────────────────────────────────────────────────────

export interface PaperMetadata {
  authors?: string;
  year?: number;
  venue?: string;
  abstract?: string;
  keywords?: string;
}

export async function savePaper(
  id: string,
  title: string,
  html: string,
  markdown: string,
  metadata?: PaperMetadata,
  toc?: { level: number; id: string; title: string }[] | null
) {
  await ensureTable();
  await pool.query(
    `INSERT INTO papers (id, title, html, markdown, authors, year, venue, abstract, keywords, toc)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
     ON CONFLICT (id) DO UPDATE SET
       html = EXCLUDED.html,
       markdown = EXCLUDED.markdown,
       title = EXCLUDED.title,
       authors = COALESCE(EXCLUDED.authors, papers.authors),
       year = COALESCE(EXCLUDED.year, papers.year),
       venue = COALESCE(EXCLUDED.venue, papers.venue),
       abstract = COALESCE(EXCLUDED.abstract, papers.abstract),
       keywords = COALESCE(EXCLUDED.keywords, papers.keywords),
       toc = COALESCE(EXCLUDED.toc, papers.toc)`,
    [
      id,
      title,
      html,
      markdown,
      metadata?.authors ?? null,
      metadata?.year ?? null,
      metadata?.venue ?? null,
      metadata?.abstract ?? null,
      metadata?.keywords ?? null,
      toc ? JSON.stringify(toc) : null,
    ]
  );
}

export async function getPaperHtml(id: string): Promise<string | null> {
  await ensureTable();
  const res = await pool.query("SELECT html FROM papers WHERE id = $1", [id]);
  return res.rows[0]?.html ?? null;
}

export async function getPaperDetail(id: string): Promise<{ html: string; toc: TocEntry[] | null } | null> {
  await ensureTable();
  const res = await pool.query("SELECT html, markdown, toc FROM papers WHERE id = $1", [id]);
  if (!res.rows[0]) return null;
  let html: string = res.rows[0].html;
  // Embed LaTeX attributes for existing papers that don't have them yet
  if (html && res.rows[0].markdown && !html.includes('data-latex=')) {
    const { embedLatexAttributes } = await import("@/lib/mathpix-cleanup");
    html = embedLatexAttributes(html, res.rows[0].markdown);
  }
  return {
    html,
    toc: res.rows[0].toc ?? null,
  };
}

export type TocEntry = { level: number; id: string; title: string };

export async function getPaperMarkdown(id: string): Promise<string | null> {
  await ensureTable();
  const res = await pool.query("SELECT markdown FROM papers WHERE id = $1", [id]);
  return res.rows[0]?.markdown ?? null;
}

export interface PaperRow {
  id: string;
  title: string;
  authors: string | null;
  year: number | null;
  venue: string | null;
  abstract: string | null;
  keywords: string | null;
  created_at: string;
  last_opened_at: string | null;
}

export async function listPapers(
  sort: string = "created_at",
  order: string = "desc"
): Promise<PaperRow[]> {
  await ensureTable();
  const allowedSorts: Record<string, string> = {
    created_at: "created_at",
    title: "title",
    year: "year",
    authors: "authors",
    venue: "venue",
    last_opened_at: "last_opened_at",
  };
  const sortCol = allowedSorts[sort] || "created_at";
  const sortOrder = order === "asc" ? "ASC" : "DESC";
  const res = await pool.query(
    `SELECT id, title, authors, year, venue, abstract, keywords, created_at, last_opened_at
     FROM papers ORDER BY ${sortCol} ${sortOrder} NULLS LAST`
  );
  return res.rows;
}

export interface PaperWithQueueRow extends PaperRow {
  ingestion_status?: 'pending' | 'downloading' | 'converting' | 'extracting' | 'failed' | null;
  ingestion_error?: string | null;
}

export async function listPapersWithQueue(
  sort: string = "created_at",
  order: string = "desc"
): Promise<PaperWithQueueRow[]> {
  await ensureTable();
  const allowedSorts: Record<string, string> = {
    created_at: "created_at",
    title: "title",
    year: "year",
    authors: "authors",
    venue: "venue",
    last_opened_at: "last_opened_at",
  };
  const sortCol = allowedSorts[sort] || "created_at";
  const sortOrder = order === "asc" ? "ASC" : "DESC";
  const t0 = Date.now();
  const res = await pool.query(
    `SELECT id, title, authors, year, venue, abstract, keywords, created_at, last_opened_at,
            NULL::text AS ingestion_status, NULL::text AS ingestion_error
     FROM papers
     UNION ALL
     SELECT id, COALESCE(parsed_title, filename) AS title,
            parsed_authors AS authors, parsed_year AS year,
            NULL AS venue, NULL AS abstract, NULL AS keywords, created_at, NULL::timestamptz AS last_opened_at,
            status AS ingestion_status, error AS ingestion_error
     FROM ingestion_queue
     WHERE status != 'complete'
     ORDER BY ${sortCol} ${sortOrder} NULLS LAST`
  );
  console.log(`[DB] listPapersWithQueue → ${res.rows.length} rows (${Date.now() - t0}ms)`);
  return res.rows;
}

export async function searchPapers(query: string): Promise<PaperRow[]> {
  await ensureTable();
  const t0 = Date.now();
  try {
    const res = await pool.query(
      `SELECT id, title, authors, year, venue, abstract, keywords, created_at, last_opened_at,
              NULL::text AS ingestion_status, NULL::text AS ingestion_error,
              CASE WHEN search_vec @@ websearch_to_tsquery('english', $1)
                   THEN ts_rank(search_vec, websearch_to_tsquery('english', $1))
                   ELSE 0
              END AS rank
       FROM papers
       ORDER BY rank DESC, created_at DESC`,
      [query]
    );
    console.log(`[DB] searchPapers("${query}") → ${res.rows.length} rows (${Date.now() - t0}ms)`);
    return res.rows;
  } catch (err) {
    // websearch_to_tsquery can fail on malformed queries — fall back to ILIKE
    console.warn(`[DB] searchPapers tsquery failed for "${query}" (${Date.now() - t0}ms):`, err instanceof Error ? err.message : err);
    const fallback = await pool.query(
      `SELECT id, title, authors, year, venue, abstract, keywords, created_at, last_opened_at,
              NULL::text AS ingestion_status, NULL::text AS ingestion_error,
              0::float AS rank
       FROM papers
       WHERE title ILIKE $1 OR authors ILIKE $1 OR abstract ILIKE $1 OR keywords ILIKE $1
       ORDER BY created_at DESC`,
      [`%${query}%`]
    );
    console.log(`[DB] searchPapers ILIKE fallback → ${fallback.rows.length} rows (${Date.now() - t0}ms)`);
    return fallback.rows;
  }
}

export async function updatePaperMetadata(
  id: string,
  metadata: PaperMetadata
): Promise<void> {
  await ensureTable();
  await pool.query(
    `UPDATE papers SET
       authors = COALESCE($2, authors),
       year = COALESCE($3, year),
       venue = COALESCE($4, venue),
       abstract = COALESCE($5, abstract),
       keywords = COALESCE($6, keywords)
     WHERE id = $1`,
    [id, metadata.authors ?? null, metadata.year ?? null, metadata.venue ?? null, metadata.abstract ?? null, metadata.keywords ?? null]
  );
}

export async function touchPaperOpened(id: string): Promise<void> {
  await ensureTable();
  await pool.query(
    `UPDATE papers SET last_opened_at = NOW() WHERE id = $1`,
    [id]
  );
}

export async function deletePaper(id: string): Promise<boolean> {
  await ensureTable();
  const res = await pool.query(`DELETE FROM papers WHERE id = $1`, [id]);
  return (res.rowCount ?? 0) > 0;
}

export async function getAllPapersForReprocess(): Promise<
  { id: string; html: string; markdown: string }[]
> {
  await ensureTable();
  const res = await pool.query(`SELECT id, html, markdown FROM papers`);
  return res.rows;
}

export async function updatePaperContent(
  id: string,
  html: string,
  markdown: string,
  toc: { level: number; id: string; title: string }[] | null
): Promise<void> {
  await ensureTable();
  await pool.query(
    `UPDATE papers SET html = $2, markdown = $3, toc = $4 WHERE id = $1`,
    [id, html, markdown, toc ? JSON.stringify(toc) : null]
  );
}

export async function getPapersNeedingMetadata(): Promise<
  { id: string; markdown: string }[]
> {
  await ensureTable();
  const res = await pool.query(
    `SELECT id, markdown FROM papers WHERE authors IS NULL OR year IS NULL OR keywords IS NULL LIMIT 20`
  );
  return res.rows;
}

// ─── Chats ────────────────────────────────────────────────────────────

export interface ChatRow {
  id: string;
  paper_id: string;
  title: string | null;
  highlight_text: string | null;
  highlight_anchor: string | null;
  message_count: number;
  created_at: string;
  updated_at: string;
}

export interface AllChatRow extends ChatRow {
  paper_title: string | null;
}

export async function listAllChats(): Promise<AllChatRow[]> {
  await ensureTable();
  const res = await pool.query(
    `SELECT c.id, c.paper_id, c.title, c.highlight_text, c.highlight_anchor,
            c.created_at, c.updated_at,
            COUNT(m.id)::int AS message_count,
            p.title AS paper_title
     FROM chats c
     LEFT JOIN chat_messages m ON m.chat_id = c.id
     LEFT JOIN papers p ON p.id = c.paper_id
     GROUP BY c.id, p.title
     ORDER BY c.updated_at DESC`
  );
  return res.rows;
}

export async function createChat(
  paperId: string | null,
  title: string,
  highlightText?: string,
  highlightAnchor?: string
): Promise<string> {
  await ensureTable();
  const res = await pool.query(
    `INSERT INTO chats (id, paper_id, title, highlight_text, highlight_anchor)
     VALUES (gen_random_uuid()::text, $1, $2, $3, $4)
     RETURNING id`,
    [paperId, title, highlightText ?? null, highlightAnchor ?? null]
  );
  return res.rows[0].id;
}

export async function listChats(paperId: string): Promise<ChatRow[]> {
  await ensureTable();
  const res = await pool.query(
    `SELECT c.id, c.paper_id, c.title, c.highlight_text, c.highlight_anchor,
            c.created_at, c.updated_at,
            COUNT(m.id)::int AS message_count
     FROM chats c
     LEFT JOIN chat_messages m ON m.chat_id = c.id
     WHERE c.paper_id = $1
     GROUP BY c.id
     ORDER BY c.updated_at DESC`,
    [paperId]
  );
  return res.rows;
}

export async function listGenericChats(): Promise<ChatRow[]> {
  await ensureTable();
  const res = await pool.query(
    `SELECT c.id, c.paper_id, c.title, c.highlight_text, c.highlight_anchor,
            c.created_at, c.updated_at,
            COUNT(m.id)::int AS message_count
     FROM chats c
     LEFT JOIN chat_messages m ON m.chat_id = c.id
     WHERE c.paper_id IS NULL
     GROUP BY c.id
     ORDER BY c.updated_at DESC`
  );
  return res.rows;
}

export async function getChatMessages(
  chatId: string
): Promise<{ id: number; role: string; content: string; created_at: string }[]> {
  await ensureTable();
  const res = await pool.query(
    `SELECT id, role, content, created_at FROM chat_messages
     WHERE chat_id = $1 ORDER BY created_at ASC, id ASC`,
    [chatId]
  );
  return res.rows;
}

export async function addChatMessage(
  chatId: string,
  role: string,
  content: string
): Promise<void> {
  await ensureTable();
  await pool.query(
    `INSERT INTO chat_messages (chat_id, role, content) VALUES ($1, $2, $3)`,
    [chatId, role, content]
  );
  await pool.query(
    `UPDATE chats SET updated_at = NOW() WHERE id = $1`,
    [chatId]
  );
}

// ─── Ingestion Queue ──────────────────────────────────────────────────

export interface QueueItem {
  id: string;
  source_url: string;
  filename: string;
  status: string;
  error: string | null;
  paper_id: string | null;
  retry_count: number;
  max_retries: number;
  created_at: string;
  updated_at: string;
}

export async function addToQueue(
  sourceUrl: string,
  filename: string,
  meta?: { title?: string; authors?: string; year?: number }
): Promise<QueueItem> {
  await ensureTable();
  const res = await pool.query(
    `INSERT INTO ingestion_queue (source_url, filename, parsed_title, parsed_authors, parsed_year)
     VALUES ($1, $2, $3, $4, $5) RETURNING *`,
    [sourceUrl, filename, meta?.title ?? null, meta?.authors ?? null, meta?.year ?? null]
  );
  return res.rows[0];
}

export async function addBatchToQueue(
  items: { url: string; filename: string }[]
): Promise<QueueItem[]> {
  await ensureTable();
  if (items.length === 0) return [];
  // Build a single multi-row INSERT
  const values: string[] = [];
  const params: string[] = [];
  items.forEach((item, i) => {
    const offset = i * 2;
    values.push(`($${offset + 1}, $${offset + 2})`);
    params.push(item.url, item.filename);
  });
  const res = await pool.query(
    `INSERT INTO ingestion_queue (source_url, filename)
     VALUES ${values.join(", ")} RETURNING *`,
    params
  );
  return res.rows;
}

export async function getNextPendingItem(): Promise<QueueItem | null> {
  const items = await getNextPendingItems(1);
  return items[0] ?? null;
}

export async function getNextPendingItems(limit: number): Promise<QueueItem[]> {
  await ensureTable();
  const res = await pool.query(
    `UPDATE ingestion_queue
     SET status = 'downloading', updated_at = NOW()
     WHERE id = ANY(
       SELECT id FROM ingestion_queue
       WHERE status = 'pending'
       ORDER BY created_at ASC
       LIMIT $1
       FOR UPDATE SKIP LOCKED
     )
     RETURNING *`,
    [limit]
  );
  return res.rows;
}

export async function updateQueueItemStatus(
  id: string,
  status: string,
  error?: string,
  paperId?: string
): Promise<void> {
  await ensureTable();
  if (status === "pending" && error) {
    // Retry: increment retry_count, keep the error message
    await pool.query(
      `UPDATE ingestion_queue
       SET status = 'pending', error = $2, retry_count = retry_count + 1, updated_at = NOW()
       WHERE id = $1`,
      [id, error]
    );
  } else {
    await pool.query(
      `UPDATE ingestion_queue
       SET status = $2, error = $3, paper_id = COALESCE($4, paper_id), updated_at = NOW()
       WHERE id = $1`,
      [id, status, error ?? null, paperId ?? null]
    );
  }
}

export async function updateQueueItemMetadata(
  id: string,
  meta: { title?: string; authors?: string; year?: number }
): Promise<void> {
  await ensureTable();
  await pool.query(
    `UPDATE ingestion_queue
     SET parsed_title = COALESCE($2, parsed_title),
         parsed_authors = COALESCE($3, parsed_authors),
         parsed_year = COALESCE($4, parsed_year),
         updated_at = NOW()
     WHERE id = $1`,
    [id, meta.title ?? null, meta.authors ?? null, meta.year ?? null]
  );
}

export async function getQueueItems(): Promise<QueueItem[]> {
  await ensureTable();
  const res = await pool.query(
    `SELECT * FROM ingestion_queue ORDER BY created_at DESC`
  );
  return res.rows;
}

export async function retryFailedItems(): Promise<number> {
  await ensureTable();
  const res = await pool.query(
    `UPDATE ingestion_queue
     SET status = 'pending', updated_at = NOW()
     WHERE status = 'failed' AND retry_count < max_retries
     RETURNING id`
  );
  return res.rows.length;
}

export async function clearCompletedItems(): Promise<number> {
  await ensureTable();
  const res = await pool.query(
    `DELETE FROM ingestion_queue WHERE status = 'complete' RETURNING id`
  );
  return res.rows.length;
}

export async function recoverStuckItems(): Promise<number> {
  await ensureTable();
  const res = await pool.query(
    `UPDATE ingestion_queue
     SET status = 'pending', updated_at = NOW()
     WHERE status IN ('downloading', 'converting', 'extracting')
       AND updated_at < NOW() - INTERVAL '10 minutes'
     RETURNING id`
  );
  if (res.rows.length > 0) {
    console.log(`[Ingest] Recovered ${res.rows.length} stuck items`);
  }
  return res.rows.length;
}

// ─── Diagrams ─────────────────────────────────────────────────────────

export async function saveDiagram(
  paperId: string | null,
  chatId: string | null,
  title: string,
  description: string,
  bodyHtml: string
): Promise<string> {
  await ensureTable();
  const res = await pool.query(
    `INSERT INTO diagrams (paper_id, chat_id, title, description, body_html)
     VALUES ($1, $2, $3, $4, $5) RETURNING id`,
    [paperId, chatId, title, description, bodyHtml]
  );
  return res.rows[0].id;
}

export interface DiagramRow {
  id: string;
  paper_id: string | null;
  chat_id: string | null;
  title: string;
  description: string | null;
  created_at: string;
  paper_title: string | null;
  chat_title: string | null;
}

export async function listAllDiagrams(): Promise<DiagramRow[]> {
  await ensureTable();
  const res = await pool.query(
    `SELECT d.id, d.paper_id, d.chat_id, d.title, d.description, d.created_at,
            p.title AS paper_title,
            c.title AS chat_title
     FROM diagrams d
     LEFT JOIN papers p ON p.id = d.paper_id
     LEFT JOIN chats c ON c.id = d.chat_id
     ORDER BY d.created_at DESC`
  );
  return res.rows;
}

export async function getDiagram(
  id: string
): Promise<{
  id: string;
  title: string;
  description: string;
  body_html: string;
  paper_id: string;
} | null> {
  await ensureTable();
  const res = await pool.query(
    `SELECT id, title, description, body_html, paper_id FROM diagrams WHERE id = $1`,
    [id]
  );
  return res.rows[0] ?? null;
}

// ─── Paper Figures ────────────────────────────────────────────────

export interface FigureRow {
  id: string;
  paper_id: string;
  figure_number: string | null;
  src: string;
  caption: string | null;
  context: string | null;
  sort_index: number;
}

export async function saveFigures(
  paperId: string,
  figures: {
    figureNumber: string | null;
    src: string;
    caption: string | null;
    context: string | null;
    index: number;
  }[]
): Promise<void> {
  await ensureTable();
  // Clear existing figures for this paper (idempotent re-extraction)
  await pool.query(`DELETE FROM paper_figures WHERE paper_id = $1`, [paperId]);
  for (const fig of figures) {
    await pool.query(
      `INSERT INTO paper_figures (paper_id, figure_number, src, caption, context, sort_index)
       VALUES ($1, $2, $3, $4, $5, $6)`,
      [paperId, fig.figureNumber, fig.src, fig.caption, fig.context, fig.index]
    );
  }
}

export async function getFigures(paperId: string): Promise<FigureRow[]> {
  await ensureTable();
  const res = await pool.query(
    `SELECT id, paper_id, figure_number, src, caption, context, sort_index
     FROM paper_figures WHERE paper_id = $1 ORDER BY sort_index`,
    [paperId]
  );
  return res.rows;
}

export async function getFigureCount(paperId: string): Promise<number> {
  await ensureTable();
  const res = await pool.query(
    `SELECT COUNT(*)::int AS count FROM paper_figures WHERE paper_id = $1`,
    [paperId]
  );
  return res.rows[0]?.count ?? 0;
}

// ─── Cache Logs ───────────────────────────────────────────────────────

export async function logCacheUsage(
  paperId: string | null,
  chatId: string | null,
  cacheCreationInputTokens: number,
  cacheReadInputTokens: number,
  inputTokens: number,
  outputTokens: number
): Promise<void> {
  await ensureTable();
  await pool.query(
    `INSERT INTO cache_logs (paper_id, chat_id, cache_creation_input_tokens, cache_read_input_tokens, input_tokens, output_tokens)
     VALUES ($1, $2, $3, $4, $5, $6)`,
    [paperId, chatId, cacheCreationInputTokens, cacheReadInputTokens, inputTokens, outputTokens]
  );
}

// ─── Research Feed ────────────────────────────────────────────────

export async function getTopKeywords(limit: number = 8): Promise<string[]> {
  await ensureTable();
  const res = await pool.query(
    `SELECT TRIM(kw) AS keyword, COUNT(*) AS cnt
     FROM papers, UNNEST(STRING_TO_ARRAY(keywords, ',')) AS kw
     WHERE keywords IS NOT NULL AND TRIM(kw) != ''
     GROUP BY TRIM(kw)
     ORDER BY cnt DESC
     LIMIT $1`,
    [limit]
  );
  return res.rows.map((r: { keyword: string }) => r.keyword);
}

export interface FeedResult {
  id: string;
  topic: string;
  title: string;
  authors: string | null;
  year: number | null;
  publication_date: string | null;
  pdf_url: string;
  abstract: string | null;
  citation_count: number;
  source: string;
  external_id: string | null;
  fetched_at: string;
}

export async function saveFeedResults(
  results: {
    topic: string;
    title: string;
    authors?: string | null;
    year?: number | null;
    publicationDate?: string | null;
    pdfUrl: string;
    abstract?: string | null;
    citationCount?: number | null;
    source?: string | null;
    externalId?: string | null;
  }[]
): Promise<void> {
  await ensureTable();
  if (results.length === 0) return;
  for (const r of results) {
    await pool.query(
      `INSERT INTO research_feed (topic, title, authors, year, publication_date, pdf_url, abstract, citation_count, source, external_id)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
       ON CONFLICT (pdf_url, topic) DO UPDATE SET
         title = EXCLUDED.title,
         authors = EXCLUDED.authors,
         year = EXCLUDED.year,
         publication_date = EXCLUDED.publication_date,
         abstract = EXCLUDED.abstract,
         citation_count = EXCLUDED.citation_count,
         fetched_at = NOW()`,
      [
        r.topic,
        r.title,
        r.authors ?? null,
        r.year ?? null,
        r.publicationDate ?? null,
        r.pdfUrl,
        r.abstract ?? null,
        r.citationCount ?? 0,
        r.source ?? "semantic_scholar",
        r.externalId ?? null,
      ]
    );
  }
}

export async function getFeedResults(topics?: string[]): Promise<FeedResult[]> {
  await ensureTable();
  let query = `
    SELECT rf.*
    FROM research_feed rf
    LEFT JOIN papers p ON LOWER(rf.title) = LOWER(p.title)
    WHERE p.id IS NULL
  `;
  const params: (string | string[])[] = [];
  if (topics && topics.length > 0) {
    params.push(topics);
    query += ` AND rf.topic = ANY($${params.length})`;
  }
  query += ` ORDER BY rf.publication_date DESC NULLS LAST, rf.fetched_at DESC`;
  const res = await pool.query(query, params);
  return res.rows;
}

export async function updateFeedMetadata(
  topic: string,
  count: number
): Promise<void> {
  await ensureTable();
  await pool.query(
    `INSERT INTO feed_metadata (topic, last_refreshed_at, paper_count)
     VALUES ($1, NOW(), $2)
     ON CONFLICT (topic) DO UPDATE SET
       last_refreshed_at = NOW(),
       paper_count = $2`,
    [topic, count]
  );
}

export async function getStaleTopics(
  maxAgeHours: number,
  topics: string[]
): Promise<string[]> {
  await ensureTable();
  if (topics.length === 0) return [];
  const res = await pool.query(
    `SELECT t.topic
     FROM UNNEST($1::text[]) AS t(topic)
     LEFT JOIN feed_metadata fm ON fm.topic = t.topic
     WHERE fm.topic IS NULL
        OR fm.last_refreshed_at < NOW() - INTERVAL '1 hour' * $2`,
    [topics, maxAgeHours]
  );
  return res.rows.map((r: { topic: string }) => r.topic);
}

// ─── Bug Reports ──────────────────────────────────────────────────

export interface BugReport {
  id: string;
  title: string;
  description: string;
  screenshots: string[]; // base64 data URLs
  status: "open" | "in_progress" | "resolved";
  page_url: string | null;
  user_agent: string | null;
  created_at: string;
}

export async function saveBugReport(
  title: string,
  description: string,
  screenshots: string[],
  pageUrl: string | null,
  userAgent: string | null
): Promise<string> {
  await ensureTable();
  const res = await pool.query(
    `INSERT INTO bug_reports (title, description, screenshots, page_url, user_agent)
     VALUES ($1, $2, $3, $4, $5) RETURNING id`,
    [title, description, JSON.stringify(screenshots), pageUrl, userAgent]
  );
  return res.rows[0].id;
}

export async function listBugReports(status?: string): Promise<BugReport[]> {
  await ensureTable();
  let query = `SELECT id, title, description, screenshots, status, page_url, user_agent, created_at FROM bug_reports`;
  const params: string[] = [];
  if (status) {
    params.push(status);
    query += ` WHERE status = $1`;
  }
  query += ` ORDER BY created_at DESC`;
  const res = await pool.query(query, params);
  return res.rows.map((r: Record<string, unknown>) => ({
    ...r,
    screenshots: typeof r.screenshots === "string" ? JSON.parse(r.screenshots as string) : (r.screenshots || []),
  })) as BugReport[];
}

export async function getBugReport(id: string): Promise<BugReport | null> {
  await ensureTable();
  const res = await pool.query(
    `SELECT id, title, description, screenshots, status, page_url, user_agent, created_at
     FROM bug_reports WHERE id = $1`,
    [id]
  );
  if (res.rows.length === 0) return null;
  const r = res.rows[0];
  return {
    ...r,
    screenshots: typeof r.screenshots === "string" ? JSON.parse(r.screenshots) : (r.screenshots || []),
  };
}

export async function updateBugReportStatus(id: string, status: string): Promise<void> {
  await ensureTable();
  await pool.query(`UPDATE bug_reports SET status = $1 WHERE id = $2`, [status, id]);
}

export async function clearOldFeedResults(days: number): Promise<number> {
  await ensureTable();
  const res = await pool.query(
    `DELETE FROM research_feed
     WHERE fetched_at < NOW() - INTERVAL '1 day' * $1
     RETURNING id`,
    [days]
  );
  return res.rows.length;
}

// ─── Auth Users ──────────────────────────────────────────────────

export interface AuthUser {
  id: string;
  username: string;
  password_hash: string;
  created_at: string;
}

export async function createUser(username: string, passwordHash: string): Promise<string> {
  await ensureTable();
  const res = await pool.query(
    `INSERT INTO auth_users (username, password_hash) VALUES ($1, $2) RETURNING id`,
    [username, passwordHash]
  );
  return res.rows[0].id;
}

export async function getUserByUsername(username: string): Promise<AuthUser | null> {
  await ensureTable();
  const res = await pool.query(
    `SELECT id, username, password_hash, created_at FROM auth_users WHERE username = $1`,
    [username]
  );
  return res.rows[0] ?? null;
}

export async function listUsers(): Promise<{ id: string; username: string; created_at: string }[]> {
  await ensureTable();
  const res = await pool.query(
    `SELECT id, username, created_at FROM auth_users ORDER BY created_at`
  );
  return res.rows;
}

export async function deleteUser(id: string): Promise<boolean> {
  await ensureTable();
  const res = await pool.query(`DELETE FROM auth_users WHERE id = $1`, [id]);
  return (res.rowCount ?? 0) > 0;
}

export async function getUserCount(): Promise<number> {
  await ensureTable();
  const res = await pool.query(`SELECT COUNT(*)::int AS count FROM auth_users`);
  return res.rows[0]?.count ?? 0;
}

// ─── Auth Sessions ───────────────────────────────────────────────

export async function createSession(token: string, userId: string, expiresAt: Date): Promise<void> {
  await ensureTable();
  await pool.query(
    `INSERT INTO auth_sessions (id, user_id, expires_at) VALUES ($1, $2, $3)`,
    [token, userId, expiresAt.toISOString()]
  );
}

export async function getSession(token: string): Promise<{ user_id: string; username: string; expires_at: string } | null> {
  await ensureTable();
  const res = await pool.query(
    `SELECT s.user_id, u.username, s.expires_at
     FROM auth_sessions s
     JOIN auth_users u ON u.id = s.user_id
     WHERE s.id = $1 AND s.expires_at > NOW()`,
    [token]
  );
  return res.rows[0] ?? null;
}

export async function deleteSession(token: string): Promise<void> {
  await ensureTable();
  await pool.query(`DELETE FROM auth_sessions WHERE id = $1`, [token]);
}

export async function deleteExpiredSessions(): Promise<void> {
  await ensureTable();
  await pool.query(`DELETE FROM auth_sessions WHERE expires_at < NOW()`);
}
