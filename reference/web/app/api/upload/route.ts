import { NextRequest, NextResponse } from "next/server";
import { savePaper } from "@/lib/db";
import { extractMetadata } from "@/lib/metadata";
import { submitPdf, pollUntilDone, getHtml, getMarkdown } from "@/lib/mathpix";
import { cleanMathpixHtml, cleanMathpixMarkdown, extractToc } from "@/lib/mathpix-cleanup";

export async function POST(req: NextRequest) {
  const t0 = Date.now();
  try {
    const formData = await req.formData();
    const file = formData.get("file") as File | null;

    if (!file || file.type !== "application/pdf") {
      return NextResponse.json({ error: "PDF file required" }, { status: 400 });
    }

    console.log(`[Upload] Processing PDF: ${file.name} (${(file.size / 1024).toFixed(0)}KB)`);

    const pdfId = await submitPdf(file);
    console.log(`[Upload] Submitted to Mathpix: ${pdfId} (${Date.now() - t0}ms)`);
    await pollUntilDone(pdfId);
    console.log(`[Upload] Mathpix conversion done (${Date.now() - t0}ms)`);

    const [rawHtml, rawMarkdown] = await Promise.all([
      getHtml(pdfId),
      getMarkdown(pdfId),
    ]);

    const html = cleanMathpixHtml(rawHtml);
    const markdownText = cleanMathpixMarkdown(rawMarkdown);
    const toc = extractToc(html);

    console.log(`[Upload] Extracting metadata...`);
    const metadata = await extractMetadata(markdownText);
    const { title, ...paperMeta } = metadata;

    await savePaper(pdfId, title, html, markdownText, paperMeta, toc);

    console.log(`[Upload] Complete: "${title}" (${Date.now() - t0}ms)`);
    return NextResponse.json({ html, documentId: pdfId, title, toc });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Upload failed";
    console.error(`[Upload] Error (${Date.now() - t0}ms):`, message);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
