import { NextRequest, NextResponse } from "next/server";
import { saveBugReport, listBugReports, updateBugReportStatus } from "@/lib/db";

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    const { title, description, screenshots, pageUrl, userAgent } = body;

    if (!description) {
      return NextResponse.json({ error: "Description is required" }, { status: 400 });
    }

    // Validate screenshots aren't too large (limit each to ~5MB base64)
    const validScreenshots = (screenshots || []).filter(
      (s: string) => typeof s === "string" && s.length < 7_000_000
    );

    const autoTitle = title || description.split(/[.\n]/)[0]?.trim().slice(0, 80) || "Bug report";
    const id = await saveBugReport(
      autoTitle.slice(0, 200),
      description.slice(0, 10000),
      validScreenshots.slice(0, 5), // max 5 screenshots
      pageUrl || null,
      userAgent || null
    );

    return NextResponse.json({ id });
  } catch (err) {
    console.error("[Bug Reports] Error creating report:", err);
    return NextResponse.json({ error: "Failed to create bug report" }, { status: 500 });
  }
}

export async function GET(req: NextRequest) {
  try {
    const status = req.nextUrl.searchParams.get("status") || undefined;
    const reports = await listBugReports(status);
    return NextResponse.json(reports);
  } catch (err) {
    console.error("[Bug Reports] Error listing reports:", err);
    return NextResponse.json({ error: "Failed to list bug reports" }, { status: 500 });
  }
}

export async function PATCH(req: NextRequest) {
  try {
    const body = await req.json();
    const { id, status } = body;

    if (!id || !status || !["open", "in_progress", "resolved"].includes(status)) {
      return NextResponse.json({ error: "Invalid id or status" }, { status: 400 });
    }

    await updateBugReportStatus(id, status);
    return NextResponse.json({ ok: true });
  } catch (err) {
    console.error("[Bug Reports] Error updating report:", err);
    return NextResponse.json({ error: "Failed to update bug report" }, { status: 500 });
  }
}
