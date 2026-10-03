// ─── Authentication Utilities ────────────────────────────────────────
// Password hashing, session tokens, and network detection.
// Uses Node.js built-in crypto — no external dependencies.

import { randomBytes, pbkdf2Sync, timingSafeEqual } from "crypto";

export const SESSION_COOKIE_NAME = "sr_session";
export const SESSION_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000; // 30 days
const PBKDF2_ITERATIONS = 100_000;
const PBKDF2_KEY_LENGTH = 32;
const PBKDF2_DIGEST = "sha256";

/** Hash a plaintext password. Returns "salt:hash" in hex. */
export function hashPassword(plain: string): string {
  const salt = randomBytes(16).toString("hex");
  const hash = pbkdf2Sync(plain, salt, PBKDF2_ITERATIONS, PBKDF2_KEY_LENGTH, PBKDF2_DIGEST).toString("hex");
  return `${salt}:${hash}`;
}

/** Verify a plaintext password against a stored "salt:hash" string. */
export function verifyPassword(plain: string, stored: string): boolean {
  const [salt, storedHash] = stored.split(":");
  if (!salt || !storedHash) return false;
  const hash = pbkdf2Sync(plain, salt, PBKDF2_ITERATIONS, PBKDF2_KEY_LENGTH, PBKDF2_DIGEST).toString("hex");
  try {
    return timingSafeEqual(Buffer.from(hash, "hex"), Buffer.from(storedHash, "hex"));
  } catch {
    return false;
  }
}

/** Generate a random 64-char hex session token. */
export function generateSessionToken(): string {
  return randomBytes(32).toString("hex");
}

/**
 * Determine if a request is coming from the local network.
 * Checks the Host header for private IPs / localhost.
 */
export function isLocalNetwork(host: string | null): boolean {
  if (!host) return false;
  // Strip port if present
  const hostname = host.split(":")[0];

  if (hostname === "localhost" || hostname === "127.0.0.1") return true;
  if (hostname.startsWith("192.168.")) return true;
  if (hostname.startsWith("10.")) return true;
  // 172.16.0.0 – 172.31.255.255
  if (hostname.startsWith("172.")) {
    const second = parseInt(hostname.split(".")[1], 10);
    if (second >= 16 && second <= 31) return true;
  }

  return false;
}

/** Check if a session token looks valid (64-char hex). */
export function isValidTokenFormat(token: string): boolean {
  return /^[0-9a-f]{64}$/.test(token);
}
