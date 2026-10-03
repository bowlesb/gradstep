import { NextRequest, NextResponse } from "next/server";
import { deleteSession } from "@/lib/db";
import { SESSION_COOKIE_NAME } from "@/lib/auth";

export async function POST(req: NextRequest) {
  const token = req.cookies.get(SESSION_COOKIE_NAME)?.value;
  if (token) {
    await deleteSession(token).catch(() => {});
  }

  const response = NextResponse.json({ ok: true });
  response.cookies.set(SESSION_COOKIE_NAME, "", {
    httpOnly: true,
    path: "/",
    maxAge: 0,
  });
  return response;
}
