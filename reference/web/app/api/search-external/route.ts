import { NextRequest, NextResponse } from "next/server";
import { searchExternalPapers } from "@/lib/paper-search";

export async function GET(req: NextRequest) {
  const q = req.nextUrl.searchParams.get("q")?.trim();
  if (!q) {
    return NextResponse.json({ results: [] });
  }

  try {
    const results = await searchExternalPapers(q);
    return NextResponse.json({ results });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Search failed";
    console.error("External search error:", message);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
