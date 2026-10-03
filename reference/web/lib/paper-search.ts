import { addToQueue } from "@/lib/db";

interface SemanticScholarPaper {
  paperId: string;
  title: string;
  year?: number;
  authors?: { name: string }[];
  externalIds?: { ArXiv?: string; DOI?: string };
  openAccessPdf?: { url: string };
  publicationDate?: string;
  abstract?: string;
  citationCount?: number;
}

interface ArxivEntry {
  title: string;
  authors: string;
  year: number;
  arxivId: string;
  pdfUrl: string;
}

interface SearchResult {
  success: boolean;
  title?: string;
  year?: number;
  authors?: string;
  pdfUrl?: string;
  message: string;
}

export interface ExternalPaperResult {
  title: string;
  authors: string;
  year: number | null;
  pdfUrl: string;
}

// ─── Semantic Scholar ──────────────────────────────────────────────────

async function searchSemanticScholar(
  title: string,
  year?: number
): Promise<SearchResult | null> {
  const params = new URLSearchParams({
    query: title,
    fields: "title,authors,year,externalIds,openAccessPdf",
    limit: "5",
  });
  if (year) params.set("year", String(year));

  // Retry up to 2 times with short backoff for transient 429s
  for (let attempt = 0; attempt < 3; attempt++) {
    const res = await fetch(
      `https://api.semanticscholar.org/graph/v1/paper/search?${params}`,
      { headers: { "User-Agent": "PaperReader/1.0" } }
    );

    if (res.ok) {
      const data = await res.json();
      const papers: SemanticScholarPaper[] = data.data || [];
      return matchSemanticScholarResult(papers, title);
    }

    if (res.status === 429 && attempt < 2) {
      console.warn(`[PaperSearch] Semantic Scholar 429, retry ${attempt + 1}/2`);
      await new Promise((r) => setTimeout(r, 2000 * (attempt + 1)));
      continue;
    }

    console.warn(`[PaperSearch] Semantic Scholar failed (${res.status})`);
    return null; // signal to try fallback
  }

  return null;
}

function matchSemanticScholarResult(
  papers: SemanticScholarPaper[],
  query: string
): SearchResult | null {
  if (papers.length === 0) return null;

  for (const paper of papers) {
    let pdfUrl: string | undefined;

    if (paper.openAccessPdf?.url) {
      pdfUrl = paper.openAccessPdf.url;
    } else if (paper.externalIds?.ArXiv) {
      pdfUrl = `https://arxiv.org/pdf/${paper.externalIds.ArXiv}.pdf`;
    }

    if (pdfUrl) {
      const authors = paper.authors?.map((a) => a.name).join(", ");
      return {
        success: true,
        title: paper.title,
        year: paper.year,
        authors: authors || undefined,
        pdfUrl,
        message: `Found and queued "${paper.title}"${paper.year ? ` (${paper.year})` : ""}. It will appear in your Library shortly.`,
      };
    }
  }

  return null;
}

// ─── arXiv fallback ────────────────────────────────────────────────────

async function searchArxiv(
  title: string,
  year?: number
): Promise<SearchResult | null> {
  // arXiv API uses Atom XML; search by title
  const query = encodeURIComponent(`ti:"${title}"`);
  const url = `https://export.arxiv.org/api/query?search_query=${query}&max_results=5&sortBy=relevance`;

  console.log(`[PaperSearch] Falling back to arXiv: ${title}`);

  const res = await fetch(url, {
    headers: { "User-Agent": "PaperReader/1.0" },
  });

  if (!res.ok) {
    console.warn(`[PaperSearch] arXiv API failed (${res.status})`);
    return null;
  }

  const xml = await res.text();
  const entries = parseArxivEntries(xml);

  if (entries.length === 0) return null;

  // If year specified, prefer matching year
  const match = year
    ? entries.find((e) => e.year === year) || entries[0]
    : entries[0];

  return {
    success: true,
    title: match.title,
    year: match.year,
    authors: match.authors,
    pdfUrl: match.pdfUrl,
    message: `Found and queued "${match.title}" (${match.year}) via arXiv. It will appear in your Library shortly.`,
  };
}

function parseArxivEntries(xml: string): ArxivEntry[] {
  const entries: ArxivEntry[] = [];
  // Match each <entry>...</entry> block
  const entryRegex = /<entry>([\s\S]*?)<\/entry>/g;
  let entryMatch;

  while ((entryMatch = entryRegex.exec(xml)) !== null) {
    const block = entryMatch[1];

    const titleMatch = block.match(/<title>([\s\S]*?)<\/title>/);
    const title = titleMatch
      ? titleMatch[1].replace(/\s+/g, " ").trim()
      : "";

    // Extract all author names
    const authorNames: string[] = [];
    const authorRegex = /<author>\s*<name>([\s\S]*?)<\/name>/g;
    let authorMatch;
    while ((authorMatch = authorRegex.exec(block)) !== null) {
      authorNames.push(authorMatch[1].trim());
    }

    // Extract published date for year
    const publishedMatch = block.match(/<published>(\d{4})/);
    const year = publishedMatch ? parseInt(publishedMatch[1]) : 0;

    // Extract arXiv ID from the <id> tag (URL like http://arxiv.org/abs/XXXX.XXXXX)
    const idMatch = block.match(/<id>https?:\/\/arxiv\.org\/abs\/([\S]+)<\/id>/);
    const arxivId = idMatch ? idMatch[1].replace(/v\d+$/, "") : "";

    if (title && arxivId) {
      entries.push({
        title,
        authors: authorNames.join(", "),
        year,
        arxivId,
        pdfUrl: `https://arxiv.org/pdf/${arxivId}.pdf`,
      });
    }
  }

  return entries;
}

// ─── Main search function ──────────────────────────────────────────────

export async function searchAndIngestPaper(
  title: string,
  year?: number
): Promise<SearchResult> {
  // Try Semantic Scholar first (better metadata + open access PDFs)
  const ssResult = await searchSemanticScholar(title, year);
  if (ssResult?.success) {
    await queueResult(ssResult);
    return ssResult;
  }

  // Fall back to arXiv
  const arxivResult = await searchArxiv(title, year);
  if (arxivResult?.success) {
    await queueResult(arxivResult);
    return arxivResult;
  }

  // Both failed
  const reason = ssResult === null
    ? "Both Semantic Scholar and arXiv search failed."
    : `No papers found matching "${title}" with accessible PDFs.`;

  return { success: false, message: reason };
}

async function queueResult(result: SearchResult): Promise<void> {
  const filename = `${result.title!.replace(/[^a-zA-Z0-9 ]/g, "").slice(0, 60).trim()}.pdf`;
  await addToQueue(result.pdfUrl!, filename, {
    title: result.title,
    authors: result.authors,
    year: result.year,
  });
}

// ─── Recent paper search (for feed discovery) ───────────────────────

export interface FeedSearchResult {
  title: string;
  authors: string;
  year: number | null;
  pdfUrl: string;
  abstract: string;
  publicationDate: string | null;
  citationCount: number;
  source: string;
  externalId: string | null;
}

export async function searchRecentPapers(
  topic: string,
  daysBack: number = 30
): Promise<FeedSearchResult[]> {
  const now = new Date();
  const from = new Date(now.getTime() - daysBack * 24 * 60 * 60 * 1000);
  const formatDate = (d: Date) => d.toISOString().split("T")[0];

  const params = new URLSearchParams({
    query: topic,
    fields:
      "title,authors,year,externalIds,openAccessPdf,publicationDate,abstract,citationCount",
    limit: "20",
    publicationDateOrYear: `${formatDate(from)}:${formatDate(now)}`,
  });

  for (let attempt = 0; attempt < 3; attempt++) {
    const res = await fetch(
      `https://api.semanticscholar.org/graph/v1/paper/search?${params}`,
      { headers: { "User-Agent": "PaperReader/1.0" } }
    );

    if (res.ok) {
      const data = await res.json();
      const papers: SemanticScholarPaper[] = data.data || [];
      return papers
        .filter((p) => {
          return (
            p.openAccessPdf?.url ||
            p.externalIds?.ArXiv
          );
        })
        .map((p) => {
          const pdfUrl =
            p.openAccessPdf?.url ||
            `https://arxiv.org/pdf/${p.externalIds!.ArXiv}.pdf`;
          return {
            title: p.title,
            authors: p.authors?.map((a) => a.name).join(", ") || "",
            year: p.year ?? null,
            pdfUrl,
            abstract: p.abstract || "",
            publicationDate: p.publicationDate || null,
            citationCount: p.citationCount || 0,
            source: "semantic_scholar",
            externalId: p.paperId || null,
          };
        });
    }

    if (res.status === 429 && attempt < 2) {
      console.warn(
        `[PaperSearch] Semantic Scholar 429 for topic "${topic}", retry ${attempt + 1}/2`
      );
      await new Promise((r) => setTimeout(r, 2000 * (attempt + 1)));
      continue;
    }

    // Non-retryable error or exhausted retries
    if (res.status === 429) {
      throw new Error("rate_limited");
    }
    console.warn(
      `[PaperSearch] Semantic Scholar feed search failed (${res.status}) for "${topic}"`
    );
    return [];
  }

  return [];
}

// ─── External search (returns all results without ingesting) ─────────

function semanticScholarToExternal(
  papers: SemanticScholarPaper[]
): ExternalPaperResult[] {
  const results: ExternalPaperResult[] = [];
  for (const paper of papers) {
    let pdfUrl: string | undefined;
    if (paper.openAccessPdf?.url) {
      pdfUrl = paper.openAccessPdf.url;
    } else if (paper.externalIds?.ArXiv) {
      pdfUrl = `https://arxiv.org/pdf/${paper.externalIds.ArXiv}.pdf`;
    }
    if (pdfUrl) {
      results.push({
        title: paper.title,
        authors: paper.authors?.map((a) => a.name).join(", ") || "",
        year: paper.year ?? null,
        pdfUrl,
      });
    }
  }
  return results;
}

function arxivEntriesToExternal(entries: ArxivEntry[]): ExternalPaperResult[] {
  return entries.map((e) => ({
    title: e.title,
    authors: e.authors,
    year: e.year || null,
    pdfUrl: e.pdfUrl,
  }));
}

export async function searchExternalPapers(
  query: string
): Promise<ExternalPaperResult[]> {
  const results: ExternalPaperResult[] = [];

  // Semantic Scholar
  try {
    const params = new URLSearchParams({
      query,
      fields: "title,authors,year,externalIds,openAccessPdf",
      limit: "10",
    });
    const res = await fetch(
      `https://api.semanticscholar.org/graph/v1/paper/search?${params}`,
      { headers: { "User-Agent": "PaperReader/1.0" } }
    );
    if (res.ok) {
      const data = await res.json();
      results.push(...semanticScholarToExternal(data.data || []));
    }
  } catch {
    console.warn("[PaperSearch] Semantic Scholar search failed");
  }

  // arXiv
  try {
    const arxivQuery = encodeURIComponent(`all:"${query}"`);
    const url = `https://export.arxiv.org/api/query?search_query=${arxivQuery}&max_results=10&sortBy=relevance`;
    const res = await fetch(url, {
      headers: { "User-Agent": "PaperReader/1.0" },
    });
    if (res.ok) {
      const xml = await res.text();
      results.push(...arxivEntriesToExternal(parseArxivEntries(xml)));
    }
  } catch {
    console.warn("[PaperSearch] arXiv search failed");
  }

  // Deduplicate by pdfUrl
  const seen = new Set<string>();
  return results.filter((r) => {
    if (seen.has(r.pdfUrl)) return false;
    seen.add(r.pdfUrl);
    return true;
  });
}
