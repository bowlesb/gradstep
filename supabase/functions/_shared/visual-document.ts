// The document a device wraps a visual answer in (chat-visual.ts), dependency-free so the browser uses this exact
// function rather than a copy (D8). No scripts, no network, system type, the platform's colours.
export function visualDocument(html: string, options: { dark?: boolean; fontSize?: number; scheme?: 'light' | 'dark' } = {}): string {
  const size = Math.min(26, Math.max(12, options.fontSize ?? 16));
  // An app's forced appearance (`scheme`) wins; otherwise dark when asked, else the system's.
  const scheme = options.scheme ?? (options.dark ? 'dark' : 'light dark');
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=4">`
    + `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">`
    + `<style>:root{color-scheme:${scheme}}html,body{margin:0;padding:0}body{padding:16px;font:${size}px/1.45 -apple-system,system-ui,sans-serif;`
    + `background:Canvas;color:CanvasText;overflow-wrap:anywhere}table{border-collapse:collapse;max-width:100%}td,th{border:1px solid rgba(128,128,128,.45);padding:4px 8px;vertical-align:top}`
    + `th{text-align:left}svg{max-width:100%;height:auto}pre,code{font-family:ui-monospace,Menlo,monospace;font-size:.92em}pre{white-space:pre-wrap}h1,h2,h3{line-height:1.25}h1{font-size:1.35em}h2{font-size:1.2em}h3{font-size:1.05em}`
    + `img,iframe,object,embed,video{display:none !important}</style></head><body>${html}</body></html>`;
}
