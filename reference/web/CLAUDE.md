# Science Reader

AI-powered research paper reader running on a Synology NAS.

## Live Site

**URL:** https://science-reader.bowles.host/

**IMPORTANT:** After every code change, verify the site is still up:
1. Wait ~60s for the Docker container to rebuild and restart
2. Run: `docker logs pdf-research-reader --tail 10` to check for startup errors
3. Run: `curl -s -o /dev/null -w '%{http_code}' https://science-reader.bowles.host/` to verify 200 OK

## Architecture

- **Framework:** Next.js 14 (standalone output)
- **Database:** PostgreSQL 16 (Alpine)
- **Deployment:** Docker Compose (`docker-compose.yml`)
  - Container name: `pdf-research-reader` (app on port 3321 -> 3000)
  - Container name: `pdf-reader-db` (Postgres)
  - Reverse proxy: nginx-proxy-manager -> port 3321
- **LLM:** Configurable via `lib/llm-provider.ts` (Anthropic primary, with fallback)
- **Search:** Tavily API for web search

## Key Commands

```bash
# Check container status
docker ps | grep pdf-re

# View app logs
docker logs pdf-research-reader --tail 50

# Rebuild and restart (after code changes)
cd /volume1/@home/selfhost/science-reader && docker compose up -d --build

# Check if site is up
curl -s -o /dev/null -w '%{http_code}' https://science-reader.bowles.host/
```

## Project Structure

- `app/page.tsx` — Main page component (all view modes, mobile/tablet/desktop)
- `app/api/chat/route.ts` — LLM chat endpoint (agentic tool loop)
- `app/api/papers/route.ts` — Paper CRUD
- `app/api/upload/route.ts` — PDF upload + Mathpix conversion
- `components/ChatPanel.tsx` — Chat UI component
- `components/LibraryView.tsx` — Paper library
- `components/MarkdownReader.tsx` — Paper viewer
- `lib/db.ts` — Database queries (PostgreSQL)
- `lib/llm-provider.ts` — LLM provider abstraction
- `lib/ingest.ts` — Paper ingestion pipeline
- `lib/paper-search.ts` — External paper search (Semantic Scholar)

## Bug Reports

Users submit bug reports via the in-app bug report form. Reports are stored in the `bug_reports` table in PostgreSQL.

**IMPORTANT:** After fixing a bug report, mark it as resolved:
```bash
docker exec pdf-reader-db psql -U paperreader -d paperreader -c "UPDATE bug_reports SET status = 'resolved' WHERE id = '<bug-report-id>';"
```

To list open bug reports:
```bash
docker exec pdf-reader-db psql -U paperreader -d paperreader -c "SELECT id, title, description, created_at FROM bug_reports WHERE status = 'open' ORDER BY created_at DESC;"
```

Screenshots can be extracted from the `screenshots` JSONB column (base64-encoded images).
