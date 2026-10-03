import { PaperMetadata } from "./db";
import { reportApiError } from "./api-health";

const CLAUDE_API = "https://api.anthropic.com/v1/messages";
const DEEPSEEK_API = "https://api.deepseek.com/chat/completions";

const METADATA_PROMPT = `Extract metadata from this research paper. Return ONLY valid JSON with these fields:
- "title": the paper title (string)
- "authors": comma-separated author names (string)
- "year": publication year as an integer (e.g. 2024). Look for it in the header, date line, copyright notice, or citation info. Never return null if any year appears in the text.
- "abstract": the paper's abstract, first 500 chars (string or null)
- "keywords": array of 5-10 ML/AI keyword terms describing the paper's area (e.g. "transformer", "attention mechanism", "NLP", "language model", "pre-training"). Use established terms from the ML literature, not paper-specific jargon.

Paper text:
`;

function extractTitle(markdown: string): string {
  const match = markdown.match(/^#\s+(.+)$/m);
  if (match) return match[1].trim().slice(0, 200);
  const firstLine = markdown.split("\n").find((l) => l.trim().length > 0);
  return firstLine?.trim().slice(0, 200) || "Untitled Paper";
}

function parseMetadataJson(text: string, markdown: string): ({ title: string } & PaperMetadata) | null {
  const jsonMatch = text.match(/\{[\s\S]*\}/);
  if (!jsonMatch) return null;

  try {
    const parsed = JSON.parse(jsonMatch[0]);
    return {
      title: (parsed.title || extractTitle(markdown)).slice(0, 200),
      authors: Array.isArray(parsed.authors) ? parsed.authors.join(", ") : (parsed.authors || undefined),
      year: typeof parsed.year === "number" ? parsed.year : undefined,
      abstract: parsed.abstract?.slice(0, 1000) || undefined,
      keywords: Array.isArray(parsed.keywords) ? parsed.keywords.join(", ") : undefined,
    };
  } catch {
    return null;
  }
}

async function extractViaDeepSeek(snippet: string): Promise<string | null> {
  const apiKey = process.env.DEEPSEEK_API_KEY;
  if (!apiKey) return null;

  try {
    const res = await fetch(DEEPSEEK_API, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: "deepseek-chat",
        max_tokens: 1024,
        messages: [{ role: "user", content: METADATA_PROMPT + snippet }],
      }),
    });

    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      const msg = body?.error?.message || `HTTP ${res.status}`;
      console.error("[Metadata] DeepSeek extraction failed:", res.status, msg);
      reportApiError("llm", `DeepSeek: ${msg}`);
      return null;
    }

    const data = await res.json();
    const content = data.choices?.[0]?.message?.content || null;
    if (!content) {
      console.error("[Metadata] DeepSeek returned empty content:", JSON.stringify(data).slice(0, 500));
    }
    return content;
  } catch (err) {
    const msg = err instanceof Error ? err.message : "Unknown error";
    console.error("[Metadata] DeepSeek error:", msg);
    reportApiError("llm", `DeepSeek: ${msg}`);
    return null;
  }
}

async function extractViaClaude(snippet: string): Promise<string | null> {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) return null;

  try {
    const res = await fetch(CLAUDE_API, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-haiku-4-5-20251001",
        max_tokens: 1024,
        messages: [{ role: "user", content: METADATA_PROMPT + snippet }],
      }),
    });

    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      const msg = body?.error?.message || `HTTP ${res.status}`;
      console.error("[Metadata] Haiku extraction failed:", res.status, msg);
      reportApiError("llm", `Anthropic: ${msg}`);
      return null;
    }

    const data = await res.json();
    return data.content?.[0]?.text || null;
  } catch (err) {
    const msg = err instanceof Error ? err.message : "Unknown error";
    console.error("[Metadata] Haiku error:", msg);
    reportApiError("llm", `Anthropic: ${msg}`);
    return null;
  }
}

export async function extractMetadata(
  markdown: string
): Promise<{ title: string } & PaperMetadata> {
  const snippet = markdown.slice(0, 8000);
  // Use DeepSeek only for metadata extraction (Anthropic credits depleted)
  const extractors = [extractViaDeepSeek];

  for (const extractor of extractors) {
    const text = await extractor(snippet);
    if (text) {
      const result = parseMetadataJson(text, markdown);
      if (result) return result;
      console.error("[Metadata] No valid JSON from response, raw:", text.slice(0, 300));
    }
  }

  console.error("[Metadata] All LLM providers failed, using title-only fallback");
  return { title: extractTitle(markdown) };
}

export { extractTitle };
