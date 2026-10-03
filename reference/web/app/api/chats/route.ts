import { NextRequest, NextResponse } from "next/server";
import { listChats, listGenericChats } from "@/lib/db";

// GET /api/chats?paperId=xxx — list chats for a paper
// GET /api/chats?generic=1 — list chats with no paper (generic mode)
export async function GET(req: NextRequest) {
  try {
    const paperId = req.nextUrl.searchParams.get("paperId");
    const generic = req.nextUrl.searchParams.get("generic");

    if (generic) {
      const chats = await listGenericChats();
      return NextResponse.json({ chats });
    }

    if (!paperId) {
      return NextResponse.json(
        { error: "paperId is required" },
        { status: 400 }
      );
    }

    const chats = await listChats(paperId);
    return NextResponse.json({ chats });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Failed to list chats";
    console.error("Chats error:", message);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
