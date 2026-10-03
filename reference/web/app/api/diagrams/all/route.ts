import { NextResponse } from "next/server";
import { listAllDiagrams } from "@/lib/db";

export async function GET() {
  try {
    const diagrams = await listAllDiagrams();
    return NextResponse.json({ diagrams });
  } catch (err) {
    console.error("Failed to list all diagrams:", err);
    return NextResponse.json({ error: "Failed to list diagrams" }, { status: 500 });
  }
}
