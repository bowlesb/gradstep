import { NextRequest, NextResponse } from "next/server";
import { listUsers, createUser, deleteUser, getUserByUsername } from "@/lib/db";
import { isLocalNetwork, hashPassword } from "@/lib/auth";

function requireLocal(req: NextRequest): NextResponse | null {
  const host = req.headers.get("host");
  if (!isLocalNetwork(host)) {
    return NextResponse.json({ error: "Admin access requires local network" }, { status: 403 });
  }
  return null;
}

// GET /api/auth/users — list all users (local network only)
export async function GET(req: NextRequest) {
  const denied = requireLocal(req);
  if (denied) return denied;

  const users = await listUsers();
  return NextResponse.json({ users });
}

// POST /api/auth/users — create a new user (local network only)
export async function POST(req: NextRequest) {
  const denied = requireLocal(req);
  if (denied) return denied;

  try {
    const { username, password } = await req.json();
    if (!username || typeof username !== "string" || !username.trim()) {
      return NextResponse.json({ error: "Username is required" }, { status: 400 });
    }
    if (!password || typeof password !== "string" || password.length < 6) {
      return NextResponse.json({ error: "Password must be at least 6 characters" }, { status: 400 });
    }

    // Check for duplicate
    const existing = await getUserByUsername(username.trim());
    if (existing) {
      return NextResponse.json({ error: "Username already exists" }, { status: 409 });
    }

    const passwordHash = hashPassword(password);
    const id = await createUser(username.trim(), passwordHash);
    return NextResponse.json({ id, username: username.trim() });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Failed to create user";
    return NextResponse.json({ error: message }, { status: 500 });
  }
}

// DELETE /api/auth/users?id=xxx — delete a user (local network only)
export async function DELETE(req: NextRequest) {
  const denied = requireLocal(req);
  if (denied) return denied;

  const id = req.nextUrl.searchParams.get("id");
  if (!id) {
    return NextResponse.json({ error: "User id required" }, { status: 400 });
  }

  const deleted = await deleteUser(id);
  if (!deleted) {
    return NextResponse.json({ error: "User not found" }, { status: 404 });
  }
  return NextResponse.json({ ok: true });
}
