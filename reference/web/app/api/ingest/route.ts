import { NextRequest, NextResponse } from "next/server";
import {
  addBatchToQueue,
  getQueueItems,
  retryFailedItems,
  clearCompletedItems,
  pool,
} from "@/lib/db";
import { isProcessing } from "@/lib/ingest";
import { getActiveErrors, dismissErrors } from "@/lib/api-health";

// POST /api/ingest — add URLs or local paths to the ingestion queue
// Body: { urls: string[] } or { urls: {url: string, filename: string}[] }
// Also accepts: { action: "ingest-local" } to queue all PDFs from /app/input/
export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    const action = body.action as string | undefined;

    // Handle retry action
    if (action === "retry") {
      const count = await retryFailedItems();
      return NextResponse.json({ message: `Retrying ${count} items`, count });
    }

    // Handle clear action
    if (action === "clear") {
      const count = await clearCompletedItems();
      return NextResponse.json({ message: `Cleared ${count} completed items`, count });
    }

    // Handle ingest-local: scan /app/input/ for PDFs and queue them all
    if (action === "ingest-local") {
      const { readdir } = await import("fs/promises");
      const inputDir = "/app/input";
      let files: string[];
      try {
        files = (await readdir(inputDir)).filter((f) =>
          f.toLowerCase().endsWith(".pdf")
        );
      } catch {
        return NextResponse.json(
          { error: "No /app/input directory found. Is the volume mounted?" },
          { status: 400 }
        );
      }
      if (files.length === 0) {
        return NextResponse.json(
          { error: "No PDF files found in /app/input/" },
          { status: 400 }
        );
      }
      const items = files.map((f) => ({
        url: `${inputDir}/${f}`,
        filename: f,
      }));
      const queued = await addBatchToQueue(items);
      return NextResponse.json({
        message: `Queued ${queued.length} local PDFs for ingestion`,
        count: queued.length,
        items: queued,
      });
    }

    // Add URLs to queue
    const urls = body.urls as (string | { url: string; filename: string })[];
    if (!urls || !Array.isArray(urls) || urls.length === 0) {
      return NextResponse.json(
        { error: "urls array required" },
        { status: 400 }
      );
    }

    const items = urls.map((u, i) => {
      if (typeof u === "string") {
        // Local path: extract filename from path
        if (u.startsWith("/") || u.startsWith("file://")) {
          const filePath = u.startsWith("file://") ? u.slice(7) : u;
          const filename = filePath.split("/").pop() || `paper-${i + 1}.pdf`;
          return { url: u, filename };
        }
        // URL: extract filename from URL
        const urlPath = new URL(u).pathname;
        const filename = urlPath.split("/").pop() || `paper-${i + 1}.pdf`;
        return { url: u, filename };
      }
      return u;
    });

    const queued = await addBatchToQueue(items);
    console.log(`[Ingest] Queued ${queued.length} papers:`, items.map(i => i.filename).join(", "));

    return NextResponse.json({
      message: `Added ${queued.length} papers to queue`,
      count: queued.length,
      items: queued,
    });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Ingest failed";
    console.error("[Ingest] Error:", message);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}

// GET /api/ingest — get queue status
export async function GET() {
  try {
    const items = await getQueueItems();
    const summary = {
      total: items.length,
      pending: items.filter((i) => i.status === "pending").length,
      downloading: items.filter((i) => i.status === "downloading").length,
      converting: items.filter((i) => i.status === "converting").length,
      extracting: items.filter((i) => i.status === "extracting").length,
      complete: items.filter((i) => i.status === "complete").length,
      failed: items.filter((i) => i.status === "failed").length,
      processing: isProcessing(),
    };
    const apiErrors = getActiveErrors();
    return NextResponse.json({ items, summary, apiErrors });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Failed to get queue";
    return NextResponse.json({ error: message }, { status: 500 });
  }
}

// DELETE /api/ingest?id=xxx — delete a queue item
export async function DELETE(req: NextRequest) {
  try {
    const id = req.nextUrl.searchParams.get("id");
    if (!id) {
      return NextResponse.json({ error: "id parameter required" }, { status: 400 });
    }
    const res = await pool.query(`DELETE FROM ingestion_queue WHERE id = $1`, [id]);
    if ((res.rowCount ?? 0) === 0) {
      return NextResponse.json({ error: "Queue item not found" }, { status: 404 });
    }
    return NextResponse.json({ ok: true });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Delete failed";
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
