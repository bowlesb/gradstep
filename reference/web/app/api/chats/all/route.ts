import { NextResponse } from "next/server";
import { listAllChats } from "@/lib/db";

export async function GET() {
  try {
    const chats = await listAllChats();
    return NextResponse.json({ chats });
  } catch (err) {
    console.error("Failed to list all chats:", err);
    return NextResponse.json({ error: "Failed to list chats" }, { status: 500 });
  }
}
