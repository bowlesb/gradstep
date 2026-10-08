export function safeLink(raw: string): string | null {
  if (raw.length > 4096 || /[\u0000-\u0020\u007f]/.test(raw)) return null;
  try { const url = new URL(raw); return ['https:', 'http:', 'mailto:'].includes(url.protocol) && !url.username && !url.password ? url.href : null; } catch { return null; }
}
