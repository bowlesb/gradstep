import { NextResponse } from "next/server";
import { getAllPapersForReprocess, updatePaperContent, updatePaperMetadata, saveFigures } from "@/lib/db";
import { getHtml, getMarkdown } from "@/lib/mathpix";
import { cleanMathpixHtml, cleanMathpixMarkdown, extractToc } from "@/lib/mathpix-cleanup";
import { extractFigures } from "@/lib/figure-extraction";
import { extractMetadata } from "@/lib/metadata";

// POST /api/reprocess — re-fetch raw content from Mathpix and re-clean
// Pass ?metadata=true to also backfill missing keywords/abstracts via LLM
// Pass ?refetch=false to skip re-fetching from Mathpix and just re-clean stored content
export async function POST(request: Request) {
  try {
    const url = new URL(request.url);
    const backfillMetadata = url.searchParams.get("metadata") === "true";
    const refetch = url.searchParams.get("refetch") !== "false";
    const papers = await getAllPapersForReprocess();
    let processed = 0;
    let metadataFixed = 0;
    const errors: string[] = [];

    for (const paper of papers) {
      try {
        let rawHtml: string;
        let rawMarkdown: string;

        if (refetch) {
          // Re-fetch raw content from Mathpix (paper.id is the Mathpix PDF ID)
          console.log(`[Reprocess] Re-fetching from Mathpix: ${paper.id}`);
          [rawHtml, rawMarkdown] = await Promise.all([
            getHtml(paper.id),
            getMarkdown(paper.id),
          ]);
        } else {
          // Just re-clean the stored content
          rawHtml = paper.html;
          rawMarkdown = paper.markdown;
        }

        const html = cleanMathpixHtml(rawHtml);
        const markdown = cleanMathpixMarkdown(rawMarkdown);
        const toc = extractToc(html);

        await updatePaperContent(paper.id, html, markdown, toc.length > 0 ? toc : null);

        // Extract and save figures
        const figures = extractFigures(html);
        if (figures.length > 0) {
          await saveFigures(paper.id, figures);
        }

        // Backfill missing metadata via LLM
        if (backfillMetadata && markdown) {
          try {
            const meta = await extractMetadata(markdown);
            if (meta.keywords || meta.abstract) {
              await updatePaperMetadata(paper.id, {
                keywords: meta.keywords,
                abstract: meta.abstract,
              });
              metadataFixed++;
            }
          } catch (err) {
            console.error(`[Reprocess] Metadata backfill failed for ${paper.id}:`, err);
          }
        }

        processed++;
        console.log(`[Reprocess] Done: ${paper.id} (${processed}/${papers.length})`);
      } catch (err) {
        const msg = err instanceof Error ? err.message : "Unknown error";
        console.error(`[Reprocess] Failed ${paper.id}: ${msg}`);
        errors.push(`${paper.id}: ${msg}`);
      }
    }

    return NextResponse.json({ ok: true, processed, total: papers.length, metadataFixed, errors });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Reprocess failed";
    console.error("Reprocess error:", message);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
