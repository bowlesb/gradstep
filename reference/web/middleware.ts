import { NextRequest, NextResponse } from "next/server";

const SESSION_COOKIE_NAME = "sr_session";

/** Check if the host header indicates a local/private network address. */
function isLocalNetwork(host: string | null): boolean {
  if (!host) return false;
  const hostname = host.split(":")[0];
  if (hostname === "localhost" || hostname === "127.0.0.1") return true;
  if (hostname.startsWith("192.168.")) return true;
  if (hostname.startsWith("10.")) return true;
  if (hostname.startsWith("172.")) {
    const second = parseInt(hostname.split(".")[1], 10);
    if (second >= 16 && second <= 31) return true;
  }
  return false;
}

/** Check if a session token looks valid (64-char hex). */
function isValidTokenFormat(token: string): boolean {
  return /^[0-9a-f]{64}$/.test(token);
}

export function middleware(req: NextRequest) {
  const host = req.headers.get("host");

  // Local network: allow everything, add header so client knows
  if (isLocalNetwork(host)) {
    const response = NextResponse.next();
    response.headers.set("x-local-network", "true");
    return response;
  }

  // Public network: check authentication
  const { pathname } = req.nextUrl;

  // Always allow auth endpoints (login needs to be accessible without a session)
  if (pathname.startsWith("/api/auth/")) {
    return NextResponse.next();
  }

  // Check for valid session cookie
  const token = req.cookies.get(SESSION_COOKIE_NAME)?.value;
  if (token && isValidTokenFormat(token)) {
    return NextResponse.next();
  }

  // No valid session — block API routes with 401
  if (pathname.startsWith("/api/")) {
    return NextResponse.json({ error: "Authentication required" }, { status: 401 });
  }

  // For page routes, let the page load — the client-side auth check
  // will show the login form via /api/auth/me
  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|icon.svg|manifest.json).*)"],
};
