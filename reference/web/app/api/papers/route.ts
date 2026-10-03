import { NextRequest, NextResponse } from "next/server";
import { listPapersWithQueue, searchPapers, getPaperDetail, touchPaperOpened, deletePaper } from "@/lib/db";
import { extractToc } from "@/lib/mathpix-cleanup";

// GET /api/papers — list all saved papers (with full metadata)
// GET /api/papers?q=attention — full-text search
// GET /api/papers?sort=year&order=desc — sortable
// GET /api/papers?id=xxx — load a specific paper's HTML
export async function GET(req: NextRequest) {
  const t0 = Date.now();
  try {
    const id = req.nextUrl.searchParams.get("id");
    const q = req.nextUrl.searchParams.get("q");
    const keyword = req.nextUrl.searchParams.get("keyword");
    const sort = req.nextUrl.searchParams.get("sort") || "created_at";
    const order = req.nextUrl.searchParams.get("order") || "desc";

    if (id) {
      console.log(`[Papers] GET detail id=${id}`);
      const detail = await getPaperDetail(id);
      if (!detail) {
        console.warn(`[Papers] Paper not found: ${id} (${Date.now() - t0}ms)`);
        return NextResponse.json({ error: "Paper not found" }, { status: 404 });
      }
      // Update last opened timestamp (fire and forget)
      touchPaperOpened(id).catch(() => {});
      console.log(`[Papers] Loaded paper ${id} (${Date.now() - t0}ms)`);
      // Always re-extract TOC from HTML so improvements to extractToc apply retroactively
      const toc = extractToc(detail.html);
      return NextResponse.json({ html: detail.html, documentId: id, toc: toc.length > 0 ? toc : detail.toc });
    }

    let papers;
    if (q && q.trim()) {
      console.log(`[Papers] Search q="${q.trim()}"`);
      papers = await searchPapers(q.trim());
      console.log(`[Papers] Search returned ${papers.length} results (${Date.now() - t0}ms)`);
    } else {
      papers = await listPapersWithQueue(sort, order);
      console.log(`[Papers] List returned ${papers.length} papers (${Date.now() - t0}ms)`);
    }

    if (keyword && keyword.trim()) {
      const kw = keyword.trim().toLowerCase();
      papers = papers.filter((p) => {
        const kws = p.keywords || "";
        return kws.toLowerCase().split(", ").some((k) => k === kw);
      });
    }

    return NextResponse.json({ papers });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Failed to load papers";
    console.error(`[Papers] Error (${Date.now() - t0}ms):`, message);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}

// DELETE /api/papers?id=xxx — delete a paper and all related data
export async function DELETE(req: NextRequest) {
  try {
    const id = req.nextUrl.searchParams.get("id");
    if (!id) {
      return NextResponse.json({ error: "id parameter required" }, { status: 400 });
    }
    console.log(`[Papers] DELETE id=${id}`);
    const deleted = await deletePaper(id);
    if (!deleted) {
      return NextResponse.json({ error: "Paper not found" }, { status: 404 });
    }
    console.log(`[Papers] Deleted ${id}`);
    return NextResponse.json({ ok: true });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Failed to delete paper";
    console.error("[Papers] Delete error:", message);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
