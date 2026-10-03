import { NextResponse } from "next/server";
import { getPapersNeedingMetadata, updatePaperMetadata } from "@/lib/db";
import { extractMetadata } from "@/lib/metadata";

// POST /api/backfill — extract metadata for papers that have none
export async function POST() {
  try {
    const papers = await getPapersNeedingMetadata();
    if (papers.length === 0) {
      return NextResponse.json({ message: "No papers need backfill", count: 0 });
    }

    let filled = 0;
    for (const paper of papers) {
      const metadata = await extractMetadata(paper.markdown);
      const { title, ...meta } = metadata;
      // Only update if we got at least authors
      if (meta.authors) {
        await updatePaperMetadata(paper.id, meta);
        console.log(`[Backfill] ${paper.id}: authors=${meta.authors}, year=${meta.year}, venue=${meta.venue}`);
        filled++;
      } else {
        console.log(`[Backfill] ${paper.id}: no metadata extracted`);
      }
    }

    return NextResponse.json({ message: `Backfilled ${filled}/${papers.length} papers`, count: filled });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Backfill failed";
    console.error("Backfill error:", message);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
