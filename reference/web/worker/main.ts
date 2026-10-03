// ─── Ingestion Queue Worker ──────────────────────────────────────────
// Standalone process that polls the ingestion queue and processes items.
// Runs in its own Docker container, separate from the Next.js web server.

import { processQueue } from "@/lib/ingest";

const POLL_INTERVAL = 10_000; // 10 seconds

let timer: ReturnType<typeof setTimeout> | null = null;
let shuttingDown = false;

async function poll() {
  if (shuttingDown) return;
  try {
    await processQueue();
  } catch (err) {
    console.error("[Worker] Queue processing error:", err);
  }
  if (!shuttingDown) {
    timer = setTimeout(poll, POLL_INTERVAL);
  }
}

function shutdown(signal: string) {
  console.log(`[Worker] Received ${signal}, shutting down gracefully...`);
  shuttingDown = true;
  if (timer) clearTimeout(timer);
  // Allow in-flight work to finish (processQueue has its own lock)
  setTimeout(() => process.exit(0), 5000);
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

console.log(`[Worker] Ingestion queue worker started (polling every ${POLL_INTERVAL / 1000}s)`);
poll();
