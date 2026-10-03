import { NextRequest } from "next/server";
import { getDiagram } from "@/lib/db";

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  const diagram = await getDiagram(id);

  if (!diagram) {
    return new Response("Diagram not found", { status: 404 });
  }

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>${escapeHtml(diagram.title)}</title>

  <!-- Mermaid -->
  <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>

  <!-- KaTeX -->
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css" />
  <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
  <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"
    onload="renderMathInElement(document.body, {delimiters:[{left:'$$',right:'$$',display:true},{left:'$',right:'$',display:false}]})"></script>

  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      line-height: 1.6;
      padding: 24px;
      max-width: 900px;
      margin: 0 auto;
      background: #ffffff;
      color: #1a1a1a;
    }

    @media (prefers-color-scheme: dark) {
      body { background: #141414; color: #e0e0e0; }
      table, th, td { border-color: #333; }
      th { background: #1e1e1e; }
      tr:nth-child(even) { background: #1a1a1a; }
      code { background: #1e1e1e; }
      blockquote { border-left-color: #444; color: #aaa; }
    }

    h1 { font-size: 1.5rem; margin-bottom: 4px; }
    .description { color: #888; margin-bottom: 20px; font-size: 0.95rem; }

    pre.mermaid { text-align: center; margin: 20px 0; }

    table { border-collapse: collapse; width: 100%; margin: 16px 0; }
    th, td { border: 1px solid #ddd; padding: 8px 12px; text-align: left; }
    th { background: #f5f5f5; font-weight: 600; }

    code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; font-size: 0.9em; }

    svg { max-width: 100%; height: auto; }

    blockquote { border-left: 3px solid #ddd; padding-left: 12px; color: #666; margin: 12px 0; }

    .katex-display { margin: 16px 0; overflow-x: auto; }

    /* Force readable contrast — override LLM-generated inline styles */
    body div, body p, body span, body li, body td, body th, body h2, body h3, body h4, body h5, body h6, body strong, body em, body code, body pre:not(.mermaid) {
      color: #1a1a1a !important;
    }
    @media (prefers-color-scheme: dark) {
      body div, body p, body span, body li, body td, body th, body h2, body h3, body h4, body h5, body h6, body strong, body em, body code, body pre:not(.mermaid) {
        color: #e0e0e0 !important;
      }
    }
  </style>
</head>
<body>
  <h1>${escapeHtml(diagram.title)}</h1>
  <p class="description">${escapeHtml(diagram.description)}</p>
  <hr style="border:none;border-top:1px solid #333;margin:16px 0" />
  ${diagram.body_html}
  <script>
    // Strip LLM-generated inline colors/backgrounds that cause contrast issues
    document.querySelectorAll('[style]').forEach(el => {
      if (el.closest('pre.mermaid') || el.closest('svg')) return;
      el.style.removeProperty('color');
      el.style.removeProperty('background');
      el.style.removeProperty('background-color');
      el.style.removeProperty('background-image');
    });
  </script>
  <script>
    mermaid.initialize({
      startOnLoad: false,
      theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default',
      securityLevel: 'loose',
    });
    document.querySelectorAll('pre.mermaid').forEach(async (el, i) => {
      const src = el.textContent;
      try {
        const { svg } = await mermaid.render('mermaid-' + i, src);
        el.innerHTML = svg;
      } catch (err) {
        console.error('Mermaid parse error:', err);
        el.classList.remove('mermaid');
        el.style.cssText = 'background:#1e1e1e;color:#e06c75;padding:16px;border-radius:8px;white-space:pre-wrap;font-size:0.85em;overflow-x:auto;';
        el.textContent = 'Diagram render error: ' + (err.message || err) + '\\n\\nSource:\\n' + src;
      }
    });
  </script>
</body>
</html>`;

  return new Response(html, {
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

function escapeHtml(str: string): string {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
