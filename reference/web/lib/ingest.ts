import { readFile } from "fs/promises";
import {
  getNextPendingItems,
  updateQueueItemStatus,
  updateQueueItemMetadata,
  savePaper,
  saveFigures,
  recoverStuckItems,
} from "@/lib/db";
import { submitPdf, pollUntilDone, getHtml, getMarkdown } from "@/lib/mathpix";
import { extractMetadata } from "@/lib/metadata";
import { cleanMathpixHtml, cleanMathpixMarkdown, extractToc, embedLatexAttributes } from "@/lib/mathpix-cleanup";
import { extractFigures } from "@/lib/figure-extraction";

let processingLock = false;

function isLocalPath(source: string): boolean {
  return source.startsWith("file://") || source.startsWith("/");
}

function resolveLocalPath(source: string): string {
  return source.startsWith("file://") ? source.slice(7) : source;
}

async function loadPdf(source: string): Promise<Buffer> {
  if (isLocalPath(source)) {
    const filePath = resolveLocalPath(source);
    console.log(`[Ingest] Reading local file: ${filePath}`);
    return readFile(filePath);
  }
  const res = await fetch(source, {
    headers: { "User-Agent": "Mozilla/5.0 (compatible; PaperReader/1.0)" },
    redirect: "follow",
  });
  if (!res.ok) throw new Error(`Download failed (${res.status}): ${source}`);
  const arrayBuffer = await res.arrayBuffer();
  return Buffer.from(arrayBuffer);
}

async function processItem(item: { id: string; source_url: string; filename: string; retry_count: number; max_retries: number; parsed_title?: string; parsed_authors?: string; parsed_year?: number }): Promise<void> {
  try {
    // Load PDF from URL or local file
    console.log(`[Ingest] Loading: ${item.filename}`);
    const buffer = await loadPdf(item.source_url);
    const uint8 = new Uint8Array(buffer);
    const blob = new Blob([uint8], { type: "application/pdf" });

    // Submit to Mathpix
    await updateQueueItemStatus(item.id, "converting");
    console.log(`[Ingest] Converting: ${item.filename}`);
    const pdfId = await submitPdf(blob, item.filename);

    // Poll until done
    await pollUntilDone(pdfId);

    // Get HTML and markdown, then clean up Mathpix artifacts
    const [rawHtml, rawMarkdown] = await Promise.all([
      getHtml(pdfId),
      getMarkdown(pdfId),
    ]);
    let html = cleanMathpixHtml(rawHtml);
    const markdown = cleanMathpixMarkdown(rawMarkdown);
    html = embedLatexAttributes(html, markdown);
    const toc = extractToc(html);

    // Extract metadata via LLM (keywords, abstract) — always run even if we have
    // pre-filled title/authors/year from Semantic Scholar, so keywords get generated
    await updateQueueItemStatus(item.id, "extracting");
    const hasPrefilledMeta = item.parsed_title && item.parsed_authors;
    const llmMeta = await extractMetadata(markdown);
    const metadata = hasPrefilledMeta
      ? { title: item.parsed_title!, authors: item.parsed_authors, year: item.parsed_year, keywords: llmMeta.keywords, abstract: llmMeta.abstract }
      : llmMeta;
    const { title, ...paperMeta } = metadata;
    if (!paperMeta.authors) {
      console.warn(`[Ingest] ⚠ No authors extracted for: ${title} — metadata extraction may have failed`);
    }
    if (!hasPrefilledMeta) {
      await updateQueueItemMetadata(item.id, {
        title,
        authors: paperMeta.authors,
        year: paperMeta.year,
      });
    }

    // Extract figures from HTML
    const figures = extractFigures(html);

    // Save to DB
    await savePaper(pdfId, title, html, markdown, paperMeta, toc);

    // Save extracted figures
    if (figures.length > 0) {
      await saveFigures(pdfId, figures);
      console.log(`[Ingest] Extracted ${figures.length} figures from: ${item.filename}`);
    }

    // Mark complete
    await updateQueueItemStatus(item.id, "complete", undefined, pdfId);
    console.log(`[Ingest] Complete: ${item.filename} → ${title}`);
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unknown error";
    console.error(`[Ingest] Failed: ${item.filename}: ${message}`);

    if (item.retry_count < item.max_retries) {
      await updateQueueItemStatus(item.id, "pending", message);
      console.log(`[Ingest] Will retry (${item.retry_count + 1}/${item.max_retries}): ${item.filename}`);
    } else {
      await updateQueueItemStatus(item.id, "failed", message);
    }
  }
}

const CONCURRENCY = 5;

export async function processQueue(): Promise<void> {
  if (processingLock) {
    return;
  }
  processingLock = true;

  try {
    await recoverStuckItems();
    let processed = 0;
    while (true) {
      const items = await getNextPendingItems(CONCURRENCY);
      if (items.length === 0) break;
      console.log(`[Ingest] Processing batch of ${items.length} items`);
      await Promise.all(items.map((item) => processItem(item)));
      processed += items.length;
    }
    if (processed > 0) {
      console.log(`[Ingest] Queue processor done, processed ${processed} items`);
    }
  } finally {
    processingLock = false;
  }
}

export function isProcessing(): boolean {
  return processingLock;
}
