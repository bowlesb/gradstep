import { NextRequest, NextResponse } from "next/server";
import { getChatMessages } from "@/lib/db";

// GET /api/chats/[chatId]/messages — load all messages for a chat
export async function GET(
  _req: NextRequest,
  { params }: { params: { chatId: string } }
) {
  try {
    const { chatId } = params;
    const messages = await getChatMessages(chatId);
    return NextResponse.json({ messages });
  } catch (err: unknown) {
    const message =
      err instanceof Error ? err.message : "Failed to load messages";
    console.error("Chat messages error:", message);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
