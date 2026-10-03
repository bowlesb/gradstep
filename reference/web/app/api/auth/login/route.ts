import { NextRequest, NextResponse } from "next/server";
import { getUserByUsername, createSession, deleteExpiredSessions } from "@/lib/db";
import { verifyPassword, generateSessionToken, SESSION_COOKIE_NAME, SESSION_MAX_AGE_MS } from "@/lib/auth";

export async function POST(req: NextRequest) {
  try {
    const { username, password } = await req.json();
    if (!username || !password) {
      return NextResponse.json({ error: "Username and password required" }, { status: 400 });
    }

    const user = await getUserByUsername(username);
    if (!user || !verifyPassword(password, user.password_hash)) {
      return NextResponse.json({ error: "Invalid username or password" }, { status: 401 });
    }

    // Clean up expired sessions opportunistically
    deleteExpiredSessions().catch(() => {});

    const token = generateSessionToken();
    const expiresAt = new Date(Date.now() + SESSION_MAX_AGE_MS);
    await createSession(token, user.id, expiresAt);

    const isSecure = req.headers.get("x-forwarded-proto") === "https";
    const response = NextResponse.json({ ok: true, username: user.username });
    response.cookies.set(SESSION_COOKIE_NAME, token, {
      httpOnly: true,
      secure: isSecure,
      sameSite: "lax",
      path: "/",
      maxAge: SESSION_MAX_AGE_MS / 1000,
    });

    return response;
  } catch (err) {
    const message = err instanceof Error ? err.message : "Login failed";
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
