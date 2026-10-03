import { NextResponse } from "next/server";
import { pool } from "@/lib/db";
import { extractMetadata } from "@/lib/metadata";

// POST /api/reprocess/metadata — re-extract metadata for papers missing authors
export async function POST() {
  try {
    const res = await pool.query(
      `SELECT id, title, markdown FROM papers WHERE authors IS NULL OR authors = '' ORDER BY created_at DESC`
    );

    if (res.rows.length === 0) {
      return NextResponse.json({ ok: true, processed: 0, message: "No papers missing metadata" });
    }

    let processed = 0;
    const errors: string[] = [];

    for (const paper of res.rows) {
      try {
        const metadata = await extractMetadata(paper.markdown);
        const updates: string[] = [];
        const values: (string | number)[] = [];
        let paramIdx = 1;

        if (metadata.authors) {
          updates.push(`authors = $${paramIdx++}`);
          values.push(metadata.authors);
        }
        if (metadata.year) {
          updates.push(`year = $${paramIdx++}`);
          values.push(metadata.year);
        }
        if (metadata.abstract) {
          updates.push(`abstract = $${paramIdx++}`);
          values.push(metadata.abstract);
        }
        if (metadata.keywords) {
          updates.push(`keywords = $${paramIdx++}`);
          values.push(metadata.keywords);
        }
        // Update title only if current one looks bad (e.g. starts with ##)
        if (metadata.title && paper.title.startsWith("##")) {
          updates.push(`title = $${paramIdx++}`);
          values.push(metadata.title);
        }

        if (updates.length > 0) {
          values.push(paper.id);
          await pool.query(
            `UPDATE papers SET ${updates.join(", ")} WHERE id = $${paramIdx}`,
            values
          );
          console.log(`[Reprocess] Updated metadata for: ${metadata.title || paper.title}`);
          processed++;
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : "Unknown error";
        errors.push(`${paper.title}: ${msg}`);
        console.error(`[Reprocess] Failed for ${paper.title}: ${msg}`);
      }
    }

    return NextResponse.json({
      ok: true,
      found: res.rows.length,
      processed,
      errors: errors.length > 0 ? errors : undefined,
    });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Reprocess failed";
    console.error("[Reprocess] Metadata error:", message);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
