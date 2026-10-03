import { NextRequest, NextResponse } from "next/server";
import { getFigures, getPaperHtml, saveFigures } from "@/lib/db";
import { extractFigures } from "@/lib/figure-extraction";

// GET /api/papers/[id]/figures — get extracted figures for a paper
export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;

  let figures = await getFigures(id);

  // If no figures stored yet, extract them on-demand from the paper HTML
  if (figures.length === 0) {
    const html = await getPaperHtml(id);
    if (!html) {
      return NextResponse.json({ error: "Paper not found" }, { status: 404 });
    }
    const extracted = extractFigures(html);
    if (extracted.length > 0) {
      await saveFigures(id, extracted);
      figures = await getFigures(id);
    }
  }

  return NextResponse.json({ figures });
}
