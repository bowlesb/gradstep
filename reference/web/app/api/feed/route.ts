import { NextRequest, NextResponse } from "next/server";
import { refreshFeed } from "@/lib/feed-discovery";

export async function GET(req: NextRequest) {
  try {
    const { searchParams } = new URL(req.url);
    const topic = searchParams.get("topic");
    const forceRefresh = searchParams.get("refresh") === "1";

    const data = await refreshFeed({ forceRefresh });

    // Filter by topic if specified
    const results = topic
      ? data.results.filter((r) => r.topic === topic)
      : data.results;

    // Deduplicate by pdf_url (a paper may appear under multiple topics)
    const seen = new Set<string>();
    const dedupedResults = results.filter((r) => {
      if (seen.has(r.pdf_url)) return false;
      seen.add(r.pdf_url);
      return true;
    });

    // Build topic counts
    const topicCounts: Record<string, number> = {};
    for (const r of data.results) {
      topicCounts[r.topic] = (topicCounts[r.topic] || 0) + 1;
    }

    return NextResponse.json({
      topics: data.topics.map((t) => ({ name: t, count: topicCounts[t] || 0 })),
      results: dedupedResults,
      lastRefreshed: data.lastRefreshed,
    });
  } catch (err) {
    console.error("[Feed API] Error:", err);
    return NextResponse.json(
      { error: "Failed to fetch feed" },
      { status: 500 }
    );
  }
}
