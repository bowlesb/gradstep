import { NextRequest, NextResponse } from "next/server";
import { getSession, getUserCount } from "@/lib/db";
import { SESSION_COOKIE_NAME, isLocalNetwork } from "@/lib/auth";

export async function GET(req: NextRequest) {
  const host = req.headers.get("host");
  const local = isLocalNetwork(host);

  const token = req.cookies.get(SESSION_COOKIE_NAME)?.value;
  let authenticated = false;
  let username: string | undefined;

  if (token) {
    const session = await getSession(token);
    if (session) {
      authenticated = true;
      username = session.username;
    }
  }

  // If on local network, always "authenticated" (no login needed)
  if (local) {
    authenticated = true;
  }

  const userCount = await getUserCount();

  return NextResponse.json({
    authenticated,
    isLocal: local,
    username: username ?? null,
    hasUsers: userCount > 0,
  });
}
