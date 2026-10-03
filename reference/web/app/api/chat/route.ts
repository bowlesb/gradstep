import { NextRequest, NextResponse } from "next/server";
import { tavily } from "@tavily/core";
import { reportApiError } from "@/lib/api-health";
import {
  getPaperMarkdown,
  createChat,
  addChatMessage,
  logCacheUsage,
  searchPapers,
  saveDiagram,
  pool,
} from "@/lib/db";
import { extractMetadata } from "@/lib/metadata";
import mermaid from "mermaid";
import { searchAndIngestPaper } from "@/lib/paper-search";
import {
  getProvider,
  type ContentBlock,
  type LLMUsage,
  type AgentMessage,
  type ToolDefinition,
  type SystemBlock,
} from "@/lib/llm-provider";

const provider = getProvider();
console.log(`[LLM] Using provider: ${provider.name} (primary=${provider.primaryModel}, fallback=${provider.fallbackModel})`);

const MAX_STEPS = 15;

const TAVILY_KEY = process.env.TAVILY_API_KEY;
if (!TAVILY_KEY) {
  console.error("[Tavily] TAVILY_API_KEY is not set!");
} else {
  console.log(
    `[Tavily] API key loaded (${TAVILY_KEY.slice(0, 8)}...${TAVILY_KEY.slice(-4)})`
  );
}
const tvly = tavily({ apiKey: TAVILY_KEY! });

// ---- Mermaid server-side validation ----------------------------------------

let mermaidReady = false;
try {
  mermaid.initialize({ startOnLoad: false, suppressErrorRendering: true });
  mermaidReady = true;
  console.log("[Mermaid] Server-side validation initialized");
} catch (e) {
  console.warn("[Mermaid] Server-side validation unavailable:", e);
}

/**
 * Extract <pre class="mermaid">...</pre> blocks and validate each with mermaid.parse().
 * Returns null on success, or an error object on first failure.
 */
async function validateMermaidBlocks(
  bodyHtml: string
): Promise<{ error: string; block_source: string } | null> {
  if (!mermaidReady) return null;

  const mermaidBlockRegex = /<pre\s+class="mermaid">([\s\S]*?)<\/pre>/gi;
  let match;
  while ((match = mermaidBlockRegex.exec(bodyHtml)) !== null) {
    const raw = match[1]
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&amp;/g, "&")
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .trim();
    try {
      await mermaid.parse(raw);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.warn(`[Mermaid] Validation failed: ${msg}`);
      return {
        error: `Mermaid syntax error: ${msg}`,
        block_source: raw.slice(0, 500),
      };
    }
  }
  return null;
}

// ---- System prompts --------------------------------------------------------

const PAPER_SYSTEM_PROMPT = `You are a rigorous ML Researcher. You have access to the full text of the paper below.

You MUST use the tavily_search tool whenever the user's question involves:
- External context not found in the paper (e.g., "Compare this to LLaMA 3", "Check this citation")
- Any specific year, date, or time period (e.g., "2026", "latest", "recent", "this year", "what's new")
- Current state-of-the-art, recent developments, or follow-up work
- Verifying factual claims, benchmarks, or metrics against external sources
Never say you lack access to recent information — always search first. Never guess specific values.

When searching for related work, recent papers, or state-of-the-art, ALWAYS make multiple targeted searches rather than one broad query. Break the topic into specific angles and search each separately. For example, if the paper is about attention-based image super-resolution, search for:
- "CVPR 2025 image super resolution" (top venue + topic + year)
- "transformer attention super resolution 2025" (method family)
- "diffusion model super resolution 2025" (alternative paradigm)
- "Mamba state space image restoration 2025" (emerging approach)
This ensures comprehensive coverage across methods, venues, and paradigms. Always include the current year in searches about recent work.

If the user asks you to ingest, add, or read papers, use the ingest_paper tool. For multiple papers, use the "papers" array parameter to batch them in a single tool call (up to 10 at once) — do NOT call ingest_paper separately for each paper. The tool searches Semantic Scholar and arXiv for PDFs and queues them automatically. Do NOT use tavily_search to find papers for ingestion — use ingest_paper directly.

You can search the user's paper library using the search_library tool. Use it when the user asks about related papers, similar work, or what else in their library covers a topic. Extract key terms, method names, or author names from the current paper and search with specific keywords. You can call search_library multiple times with different queries to cover different aspects (e.g., topic keywords, author names, method names). When searching the web for related work, ALSO search the user's library so you can tell them what they already have and what's new.

You have a create_diagram tool for creating visual explanations. ONLY use it when the user explicitly asks for a diagram, visualization, flowchart, or architecture overview. Do NOT use it proactively or for tables/comparisons — use plain markdown for those.
How it works: you provide body_html content → the server saves it to a database and wraps it in a full HTML page (with Mermaid.js, KaTeX, and CSS already loaded) → it becomes viewable at /api/diagrams/{id}. The tool result returns this URL and a ready-made markdown_link.
Inside body_html you can use: Mermaid diagrams (<pre class="mermaid">), inline SVG, HTML tables, styled divs, and KaTeX math ($ and $$). Do NOT include <html>, <head>, or <body> tags — only the inner content. Keep body_html concise — prefer Mermaid over verbose SVG, use short labels, and avoid redundant wrapper divs.
IMPORTANT Mermaid syntax rules: Use only ASCII in node labels — no Unicode math symbols (×, →, ∂, Σ, ⋆). Use text equivalents instead (e.g., "multiply" or "*" instead of "×", "->" instead of "→"). Wrap any label containing special characters in double quotes: A["label (with parens)"]. Keep labels short. Test-safe characters: letters, digits, spaces, hyphens, underscores, periods, commas, colons, slashes.
NEVER put raw HTML, SVG, or Mermaid markup in your chat text. After the tool succeeds, include the markdown_link from the result so the user can view the diagram, and add a brief text summary of what it shows.

You can also create small inline visuals directly in chat using live-html code blocks. Write a fenced code block with language tag "live-html" containing HTML body content. The same content types are supported as create_diagram: Mermaid diagrams (<pre class="mermaid">), KaTeX math ($ and $$), HTML tables, inline SVG, and styled divs. Do NOT include <html>, <head>, or <body> tags — only inner content. Example:
\`\`\`live-html
<h3>Comparison</h3>
<table><tr><th>Method</th><th>Accuracy</th></tr><tr><td>Baseline</td><td>82%</td></tr><tr><td>Proposed</td><td>91%</td></tr></table>
\`\`\`

**When to use plain text (default — vast majority of responses):** Tables, comparisons, lists, summaries, definitions, and explanations should ALL be plain markdown text in the chat. Use standard markdown tables (| col1 | col2 |) for tabular data. Do NOT use live-html or create_diagram for content that markdown can handle. When in doubt, use plain text.
**When to use live-html (rare — inline):** ONLY for content that genuinely cannot be expressed in markdown: Mermaid flowcharts with complex branching, inline SVG graphics, or KaTeX formula layouts that need precise spatial arrangement. Simple tables, comparisons, and lists do NOT qualify — use markdown for those.
**When to use create_diagram (very rare — saved link):** ONLY when the user explicitly asks for a diagram, flowchart, or visual, AND the content is substantial enough to warrant its own page (large Mermaid diagrams, multi-section visual references, complex SVG illustrations). NEVER use create_diagram for tables, comparisons, summaries, or text content. NEVER use it proactively — only when the user specifically requests a visual artifact.

When explaining math, use LaTeX format with $ for inline and $$ for display math.
Always ground your answers in the paper's content. Cite specific sections when possible.

Be thorough and detailed in your responses. When discussing methods, architectures, or results, walk through the reasoning step by step rather than summarizing at a high level. Define background terms, concepts, and notation where it would help the reader — even if they didn't explicitly ask — so the explanation is self-contained. For example, if a paper uses "KL divergence" or "cross-attention", briefly explain what these mean in context before diving into how the paper uses them. Prefer longer, more educational responses over terse ones.`;

const GENERIC_SYSTEM_PROMPT = `You are a helpful research assistant. You do NOT have a specific paper loaded, so answer general questions about machine learning, research methodology, statistics, or any topic the user asks about.

You MUST use the tavily_search tool whenever the user's question involves:
- Current events, recent papers, or state-of-the-art results
- Any specific year, date, or time period
- Verifying factual claims, benchmarks, or metrics
Never say you lack access to recent information — always search first. Never guess specific values.

If the user asks you to ingest, add, or read papers, use the ingest_paper tool. For multiple papers, use the "papers" array parameter to batch them in a single tool call (up to 10 at once) — do NOT call ingest_paper separately for each paper. The tool searches Semantic Scholar and arXiv for PDFs and queues them automatically. Do NOT use tavily_search to find papers for ingestion — use ingest_paper directly.

You can search the user's paper library using the search_library tool. Use it when the user asks about papers in their library, similar work, or what they have on a topic.

You have a create_diagram tool for creating visual explanations. ONLY use it when the user explicitly asks for a diagram, visualization, flowchart, or architecture overview. Do NOT use it proactively or for tables/comparisons — use plain markdown for those.
How it works: you provide body_html content → the server saves it to a database and wraps it in a full HTML page (with Mermaid.js, KaTeX, and CSS already loaded) → it becomes viewable at /api/diagrams/{id}. The tool result returns this URL and a ready-made markdown_link.
Inside body_html you can use: Mermaid diagrams (<pre class="mermaid">), inline SVG, HTML tables, styled divs, and KaTeX math ($ and $$). Do NOT include <html>, <head>, or <body> tags — only the inner content.
NEVER put raw HTML, SVG, or Mermaid markup in your chat text. After the tool succeeds, include the markdown_link from the result so the user can view the diagram.

You can also create small inline visuals directly in chat using live-html code blocks. Write a fenced code block with language tag "live-html" containing HTML body content. The same content types are supported as create_diagram: Mermaid diagrams (<pre class="mermaid">), KaTeX math ($ and $$), HTML tables, inline SVG, and styled divs. Do NOT include <html>, <head>, or <body> tags — only inner content. Example:
\`\`\`live-html
<h3>Comparison</h3>
<table><tr><th>Method</th><th>Accuracy</th></tr><tr><td>Baseline</td><td>82%</td></tr><tr><td>Proposed</td><td>91%</td></tr></table>
\`\`\`

**When to use plain text (default — vast majority of responses):** Tables, comparisons, lists, summaries, definitions, and explanations should ALL be plain markdown text in the chat. Use standard markdown tables (| col1 | col2 |) for tabular data. Do NOT use live-html or create_diagram for content that markdown can handle. When in doubt, use plain text.
**When to use live-html (rare — inline):** ONLY for content that genuinely cannot be expressed in markdown: Mermaid flowcharts with complex branching, inline SVG graphics, or KaTeX formula layouts that need precise spatial arrangement. Simple tables, comparisons, and lists do NOT qualify — use markdown for those.
**When to use create_diagram (very rare — saved link):** ONLY when the user explicitly asks for a diagram, flowchart, or visual, AND the content is substantial enough to warrant its own page (large Mermaid diagrams, multi-section visual references, complex SVG illustrations). NEVER use create_diagram for tables, comparisons, summaries, or text content. NEVER use it proactively — only when the user specifically requests a visual artifact.

When explaining math, use LaTeX format with $ for inline and $$ for display math.
Be thorough and detailed in your responses.`;

// ---- Tool definitions (provider-neutral) -----------------------------------

function getToolDefinitions(): ToolDefinition[] {
  return [
    {
      name: "tavily_search",
      description:
        "Search the web for external information not found in the paper. Use this for citation verification, SOTA comparisons, code repositories, author info, or any facts not in the paper.",
      parameters: {
        type: "object",
        properties: {
          query: {
            type: "string",
            description: "The search query",
          },
        },
        required: ["query"],
      },
    },
    {
      name: "ingest_paper",
      description:
        "Search for research papers by title and add them to the ingestion queue. Can ingest a single paper or a batch of up to 10 papers at once. Use this when the user mentions papers they want to read or ingest.",
      parameters: {
        type: "object",
        properties: {
          title: {
            type: "string",
            description: "Title of a single paper to search for (use this OR papers, not both)",
          },
          year: {
            type: "number",
            description: "Optional publication year to narrow search (for single paper mode)",
          },
          papers: {
            type: "array",
            description: "Batch mode: array of papers to ingest (up to 10). Use this when ingesting multiple papers at once.",
            items: {
              type: "object",
              properties: {
                title: { type: "string", description: "Paper title" },
                year: { type: "number", description: "Optional publication year" },
              },
              required: ["title"],
            },
          },
        },
        required: [],
      },
    },
    {
      name: "search_library",
      description:
        "Search the user's paper library using keyword queries. Returns papers matching the query ranked by relevance. Use specific keywords, author names, or topic terms rather than full sentences. You can call this multiple times with different queries to broaden the search.",
      parameters: {
        type: "object",
        properties: {
          query: {
            type: "string",
            description:
              "Search keywords (e.g. 'transformer attention mechanism', 'Vaswani', 'reinforcement learning reward shaping'). Supports AND (space), OR, quoted phrases, and - for exclusion.",
          },
        },
        required: ["query"],
      },
    },
    {
      name: "fix_metadata",
      description:
        "Fix missing or incorrect metadata (authors, year, abstract, keywords) for papers in the library. Can target a specific paper by title or fix all papers with missing metadata. Returns a summary of what was fixed.",
      parameters: {
        type: "object",
        properties: {
          paper_title: {
            type: "string",
            description:
              "Optional: title (or partial title) of a specific paper to fix. If omitted, fixes all papers with missing metadata.",
          },
        },
        required: [],
      },
    },
    {
      name: "get_metadata_status",
      description:
        "Check the metadata coverage of papers in the library. Returns counts of papers with and without authors, year, abstract, keywords. Use this when the user asks about metadata quality or coverage.",
      parameters: {
        type: "object",
        properties: {},
        required: [],
      },
    },
    {
      name: "delete_duplicates",
      description:
        "Find and delete duplicate papers in the library. Papers with the same title are considered duplicates. Keeps the best copy (the one with the most metadata) and deletes the rest. Returns a summary of what was deleted.",
      parameters: {
        type: "object",
        properties: {
          dry_run: {
            type: "boolean",
            description: "If true, only report duplicates without deleting. Defaults to false.",
          },
        },
        required: [],
      },
    },
    {
      name: "create_diagram",
      description:
        'Saves HTML body content to the server and returns a URL where the diagram is viewable. The server wraps your body_html in a full page with Mermaid.js, KaTeX CSS/JS, and responsive styles already loaded. You only provide the inner body content. The response includes a markdown_link you should share with the user. Supported content: Mermaid (<pre class="mermaid">), inline SVG, HTML tables, styled text, KaTeX math ($ and $$). Do NOT include <html>/<head>/<body> tags.',
      parameters: {
        type: "object",
        properties: {
          title: {
            type: "string",
            description: "Short title for the diagram",
          },
          description: {
            type: "string",
            description: "Brief description of what this diagram explains",
          },
          body_html: {
            type: "string",
            description:
              'HTML body content only (no <html>/<head>/<body> tags). Use <pre class="mermaid"> for Mermaid diagrams, inline SVG, HTML tables, etc.',
          },
        },
        required: ["title", "description", "body_html"],
      },
    },
  ];
}

// ---- System prompt builder -------------------------------------------------

function buildSystemPrompt(
  paperMarkdown: string,
  options: { includePaper: boolean; genericMode: boolean }
): SystemBlock[] {
  if (options.genericMode) {
    return [{ text: GENERIC_SYSTEM_PROMPT, cache: false }];
  }
  if (options.includePaper) {
    return [
      { text: PAPER_SYSTEM_PROMPT, cache: true },
      {
        text: `Here is the full text of the research paper:\n\n${paperMarkdown}`,
        cache: true,
      },
    ];
  }
  return [
    {
      text:
        PAPER_SYSTEM_PROMPT +
        "\n\n(The paper was provided in the earlier turn — refer to your prior analysis in the conversation.)",
      cache: false,
    },
  ];
}

// ---- Generic LLM call with retries + fallback ------------------------------

async function callLLMStream(
  sseController: ReadableStreamDefaultController,
  paperMarkdown: string,
  messages: AgentMessage[],
  options?: { includePaper?: boolean; model?: string; genericMode?: boolean }
): Promise<{
  content: ContentBlock[];
  stop_reason: string;
  usage: LLMUsage;
}> {
  const includePaper = options?.includePaper !== false;
  const genericMode = options?.genericMode === true;
  const model = options?.model || provider.primaryModel;

  const systemBlocks = buildSystemPrompt(paperMarkdown, {
    includePaper,
    genericMode,
  });
  const tools = getToolDefinitions();

  // Choose max_tokens: Anthropic gets full range, DeepSeek caps internally
  const maxTokens = model === provider.fallbackModel && provider.name === "anthropic" ? 4096 : 16384;

  let lastStatus = 0;
  let lastBody = "";

  for (let attempt = 0; attempt <= provider.maxRetries; attempt++) {
    const { url, headers, body } = provider.buildRequest(
      model,
      maxTokens,
      systemBlocks,
      tools,
      messages
    );

    const fetchController = new AbortController();
    const fetchTimeout = setTimeout(() => fetchController.abort(), 120_000); // 2 min timeout
    let res: Response;
    try {
      res = await fetch(url, { method: "POST", headers, body, signal: fetchController.signal });
    } catch (fetchErr) {
      clearTimeout(fetchTimeout);
      if (fetchErr instanceof Error && fetchErr.name === "AbortError") {
        throw new Error(`${provider.name} request timed out after 120s`);
      }
      throw fetchErr;
    }
    clearTimeout(fetchTimeout);

    if (res.ok) {
      try {
        // Add a timeout for streaming too — if no data for 60s, abort
        const streamTimeout = setTimeout(() => fetchController.abort(), 60_000);
        const result = await provider.parseSSE(res, sseController);
        clearTimeout(streamTimeout);
        return result;
      } catch (streamErr) {
        const errMsg =
          streamErr instanceof Error ? streamErr.message : String(streamErr);
        console.warn(
          `[${provider.name}] Stream error on attempt ${attempt + 1}/${provider.maxRetries}: ${errMsg}`
        );
        if (attempt < provider.maxRetries) {
          const backoffMs = Math.min(
            provider.initialBackoffMs * Math.pow(2, attempt),
            15_000
          );
          console.warn(
            `[${provider.name}] Retrying in ${(backoffMs / 1000).toFixed(1)}s...`
          );
          sseEmit(sseController, {
            type: "status",
            message: "Connection interrupted, retrying...",
            new_step: true,
          });
          await new Promise((r) => setTimeout(r, backoffMs));
          continue;
        }
        throw streamErr;
      }
    }

    lastStatus = res.status;
    lastBody = await res.text();

    if (
      provider.retryableStatuses.includes(res.status) &&
      attempt < provider.maxRetries
    ) {
      const retryAfterHeader = res.headers.get("retry-after");
      const rawBackoffMs = retryAfterHeader
        ? parseFloat(retryAfterHeader) * 1000
        : provider.initialBackoffMs * Math.pow(2, attempt);
      const backoffMs = Math.min(rawBackoffMs, 15_000);
      console.warn(
        `[${provider.name}] ${res.status} on ${model} (attempt ${attempt + 1}/${provider.maxRetries}), ` +
          `retrying in ${(backoffMs / 1000).toFixed(1)}s` +
          (rawBackoffMs > 15_000
            ? ` (capped from ${(rawBackoffMs / 1000).toFixed(0)}s)`
            : "") +
          `...`
      );
      await new Promise((resolve) => setTimeout(resolve, backoffMs));
      continue;
    }
  }

  // All retries exhausted — try fallback model if different
  if (
    provider.retryableStatuses.includes(lastStatus) &&
    provider.fallbackModel !== model
  ) {
    console.warn(
      `[${provider.name}] ${model} exhausted ${provider.maxRetries} retries (${lastStatus}), falling back to ${provider.fallbackModel}`
    );
    const fallbackMaxTokens = provider.name === "anthropic" ? 4096 : 8192;
    const { url, headers, body } = provider.buildRequest(
      provider.fallbackModel,
      fallbackMaxTokens,
      systemBlocks,
      tools,
      messages
    );

    const fbController = new AbortController();
    const fbTimeout = setTimeout(() => fbController.abort(), 120_000);
    let fbRes: Response;
    try {
      fbRes = await fetch(url, { method: "POST", headers, body, signal: fbController.signal });
    } catch (fbErr) {
      clearTimeout(fbTimeout);
      if (fbErr instanceof Error && fbErr.name === "AbortError") {
        throw new Error(`${provider.name} fallback request timed out after 120s`);
      }
      throw fbErr;
    }
    clearTimeout(fbTimeout);
    if (fbRes.ok) {
      return await provider.parseSSE(fbRes, sseController);
    }

    const text = await fbRes.text();
    reportApiError("llm", `${provider.name} fallback failed (${fbRes.status}): ${text.slice(0, 200)}`);
    throw new Error(
      `${provider.name} fallback API error (${fbRes.status}): ${text}`
    );
  }

  reportApiError("llm", `${provider.name} API error (${lastStatus}): ${lastBody.slice(0, 200)}`);
  throw new Error(`${provider.name} API error (${lastStatus}): ${lastBody}`);
}

// ---- Tool execution --------------------------------------------------------

async function executeTavilySearch(
  query: string
): Promise<Record<string, unknown>> {
  console.log(`[Tavily] Searching: "${query}"`);
  const startTime = Date.now();
  try {
    const response = await tvly.search(query, {
      searchDepth: "basic",
      maxResults: 5,
      includeAnswer: true,
    });
    const elapsed = Date.now() - startTime;
    console.log(
      `[Tavily] Search completed in ${elapsed}ms — ` +
        `${response.results.length} results, ` +
        `answer=${response.answer ? "yes" : "no"}`
    );
    if (response.results.length > 0) {
      console.log(
        `[Tavily] Top results:\n` +
          response.results
            .map((r, i) => `  ${i + 1}. ${r.title} (${r.url})`)
            .join("\n")
      );
    }
    return {
      answer: response.answer,
      results: response.results.map((r) => ({
        title: r.title,
        url: r.url,
        content: r.content,
      })),
    };
  } catch (err) {
    const elapsed = Date.now() - startTime;
    const errMsg = err instanceof Error ? err.message : String(err);
    console.error(`[Tavily] Search FAILED after ${elapsed}ms: ${errMsg}`);
    if (err instanceof Error && err.stack) {
      console.error(`[Tavily] Stack: ${err.stack}`);
    }
    reportApiError("search", `Tavily search failed: ${errMsg.slice(0, 200)}`);
    return {
      error: `Search failed: ${errMsg}`,
      results: [],
    };
  }
}

function sseEmit(
  controller: ReadableStreamDefaultController,
  event: Record<string, unknown>
) {
  try {
    controller.enqueue(
      new TextEncoder().encode(`data: ${JSON.stringify(event)}\n\n`)
    );
  } catch {
    // Controller already closed (client disconnected) — ignore
  }
}

// ---- Chat endpoint ---------------------------------------------------------

interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

export async function POST(req: NextRequest) {
  let body: {
    messages: ChatMessage[];
    documentId?: string | null;
    chatId?: string;
    highlightText?: string;
    highlightAnchor?: string;
  };

  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON" }, { status: 400 });
  }

  const {
    messages,
    documentId,
    chatId: incomingChatId,
    highlightText,
    highlightAnchor,
  } = body;

  const isGenericMode = !documentId;
  let paperMarkdown = "";

  if (!isGenericMode) {
    const md = await getPaperMarkdown(documentId);
    if (!md) {
      return NextResponse.json(
        { error: "Paper not found. Please re-upload." },
        { status: 404 }
      );
    }
    paperMarkdown = md;
  }

  const stream = new ReadableStream({
    async start(controller) {
      try {
        // Determine or create chatId
        let chatId = incomingChatId;
        if (!chatId) {
          const lastUserMsg = [...messages]
            .reverse()
            .find((m) => m.role === "user");
          const title = lastUserMsg
            ? lastUserMsg.content.slice(0, 80)
            : "New Chat";
          chatId = await createChat(
            documentId ?? null,
            title,
            highlightText,
            highlightAnchor
          );
        }

        // Save the latest user message to DB
        const lastMsg = messages[messages.length - 1];
        if (lastMsg && lastMsg.role === "user") {
          await addChatMessage(chatId, "user", lastMsg.content);
        }

        // Build agent messages from chat history
        const agentMessages: AgentMessage[] = messages.map((m) => ({
          role: m.role,
          content: m.content,
        }));

        // Track cumulative usage across steps
        let totalUsage: LLMUsage = {
          input_tokens: 0,
          output_tokens: 0,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
        };

        function accumulateUsage(usage: LLMUsage) {
          totalUsage.input_tokens! += usage.input_tokens || 0;
          totalUsage.output_tokens! += usage.output_tokens || 0;
          totalUsage.cache_creation_input_tokens! +=
            usage.cache_creation_input_tokens || 0;
          totalUsage.cache_read_input_tokens! +=
            usage.cache_read_input_tokens || 0;
        }

        async function emitResultAndClose(text: string) {
          await addChatMessage(chatId!, "assistant", text);

          console.log(
            `[Cache] provider=${provider.name} paper=${documentId ?? "generic"} chat=${chatId} ` +
              `creation=${totalUsage.cache_creation_input_tokens} ` +
              `read=${totalUsage.cache_read_input_tokens} ` +
              `input=${totalUsage.input_tokens} ` +
              `output=${totalUsage.output_tokens}`
          );
          await logCacheUsage(
            documentId ?? null,
            chatId!,
            totalUsage.cache_creation_input_tokens!,
            totalUsage.cache_read_input_tokens!,
            totalUsage.input_tokens!,
            totalUsage.output_tokens!
          );

          sseEmit(controller, {
            type: "result",
            role: "assistant",
            content: text,
            chatId,
            usage: totalUsage,
          });
          controller.close();
        }

        // Agent loop: call LLM, execute tools if requested, repeat
        // Step 0: primary model with full paper (deep reasoning)
        // Step 1+: fallback model without paper (presenting tool results — fast & cheap)
        let accumulatedText = ""; // Accumulate text across all steps
        for (let step = 0; step < MAX_STEPS; step++) {
          const isFirstStep = step === 0;

          if (isFirstStep) {
            sseEmit(controller, {
              type: "status",
              message: "Thinking...",
              new_step: true,
            });
          } else {
            sseEmit(controller, {
              type: "status",
              message: "Reading results...",
              new_step: true,
            });
          }

          const response = await callLLMStream(
            controller,
            paperMarkdown,
            agentMessages,
            {
              includePaper: isFirstStep && !isGenericMode,
              model: isFirstStep
                ? provider.primaryModel
                : provider.fallbackModel,
              genericMode: isGenericMode,
            }
          );
          accumulateUsage(response.usage);

          if (response.stop_reason !== "tool_use") {
            const modelLabel = isFirstStep
              ? provider.primaryModel
              : provider.fallbackModel;
            console.log(
              `[Agent] Step ${step + 1}/${MAX_STEPS} (${modelLabel}): finished with stop_reason=${response.stop_reason}`
            );
            let text = response.content
              .filter((b) => b.type === "text")
              .map((b) => b.text)
              .join("");

            const hadTruncatedTool =
              response.stop_reason === "max_length" &&
              response.content.some((b) => b.type === "tool_use");
            if (hadTruncatedTool && text.trim().length < 20) {
              text =
                "The response was too large to generate in one pass. Please try again with a simpler request (e.g., ask for a shorter or less detailed diagram).";
            }

            const fullText = accumulatedText ? accumulatedText + "\n\n" + text : text;
            await emitResultAndClose(fullText);
            return;
          }

          // Accumulate any text emitted alongside tool calls
          const stepText = response.content
            .filter((b) => b.type === "text")
            .map((b) => b.text)
            .join("");
          if (stepText.trim()) {
            accumulatedText += (accumulatedText ? "\n\n" : "") + stepText;
          }

          // Tool use handling
          const toolUseBlocks = response.content.filter(
            (b) => b.type === "tool_use"
          );
          if (toolUseBlocks.length === 0) {
            console.log(
              `[Agent] Step ${step + 1}: stop_reason=tool_use but no tool_use blocks found`
            );
            break;
          }

          const modelLabel = isFirstStep
            ? provider.primaryModel
            : provider.fallbackModel;
          console.log(
            `[Agent] Step ${step + 1}/${MAX_STEPS} (${modelLabel}): requested ${toolUseBlocks.length} tool(s): ` +
              toolUseBlocks
                .map((b) => `${b.name}(${JSON.stringify(b.input)})`)
                .join(", ")
          );

          agentMessages.push({
            role: "assistant",
            content: response.content,
          });

          const toolResults = await Promise.all(
            toolUseBlocks.map(async (block) => {
              let result: string;
              if (block.name === "tavily_search") {
                sseEmit(controller, {
                  type: "status",
                  message: `Searching: "${block.input!.query}"`,
                });
                const searchResult = await executeTavilySearch(
                  block.input!.query
                );
                result = JSON.stringify(searchResult);
              } else if (block.name === "ingest_paper") {
                const input = block.input as unknown as {
                  title?: string;
                  year?: number;
                  papers?: { title: string; year?: number }[];
                };

                // Build list of papers to ingest
                const paperList = input.papers?.length
                  ? input.papers.slice(0, 10)
                  : input.title
                    ? [{ title: input.title, year: input.year }]
                    : [];

                if (paperList.length === 0) {
                  result = JSON.stringify({ error: "No paper title or papers array provided" });
                } else if (paperList.length === 1) {
                  // Single paper
                  const p = paperList[0];
                  sseEmit(controller, {
                    type: "status",
                    message: `Ingesting paper: "${p.title}"`,
                  });
                  console.log(`[Agent] Ingesting paper: "${p.title}"${p.year ? ` (${p.year})` : ""}`);
                  const ingestResult = await searchAndIngestPaper(p.title, p.year);
                  result = JSON.stringify(ingestResult);
                } else {
                  // Batch mode
                  sseEmit(controller, {
                    type: "status",
                    message: `Ingesting ${paperList.length} papers...`,
                  });
                  console.log(`[Agent] Batch ingesting ${paperList.length} papers`);
                  const results = await Promise.all(
                    paperList.map(async (p) => {
                      try {
                        const r = await searchAndIngestPaper(p.title, p.year);
                        return { title: p.title, ...r };
                      } catch (err) {
                        return { title: p.title, success: false, message: err instanceof Error ? err.message : "Error" };
                      }
                    })
                  );
                  const succeeded = results.filter((r) => r.success).length;
                  const failed = results.filter((r) => !r.success);
                  sseEmit(controller, {
                    type: "status",
                    message: `Queued ${succeeded}/${paperList.length} papers`,
                  });
                  result = JSON.stringify({
                    batch: true,
                    total: paperList.length,
                    succeeded,
                    failed: failed.length,
                    results,
                  });
                }
              } else if (block.name === "create_diagram") {
                const input = block.input as unknown as {
                  title: string;
                  description: string;
                  body_html: string;
                };
                sseEmit(controller, {
                  type: "status",
                  message: "Creating diagram...",
                });
                console.log(`[Agent] Creating diagram: "${input.title}"`);

                // Validate mermaid blocks before saving
                const mermaidError = await validateMermaidBlocks(input.body_html);
                if (mermaidError) {
                  console.warn(`[Agent] Diagram rejected — ${mermaidError.error}`);
                  result = JSON.stringify(mermaidError);
                } else {
                  const diagramId = await saveDiagram(
                    documentId ?? null,
                    chatId!,
                    input.title,
                    input.description,
                    input.body_html
                  );
                  const url = `/api/diagrams/${diagramId}`;
                  result = JSON.stringify({
                    success: true,
                    diagram_id: diagramId,
                    url,
                    markdown_link: `[View: ${input.title}](${url})`,
                    instruction:
                      "Include the markdown_link in your response. Do NOT reproduce the HTML content.",
                  });
                }
              } else if (block.name === "search_library") {
                const query = block.input!.query;
                sseEmit(controller, {
                  type: "status",
                  message: `Searching library: "${query}"`,
                });
                console.log(`[Agent] Searching library: "${query}"`);
                const allPapers = await searchPapers(query);
                const matches = (
                  allPapers as (typeof allPapers[number] & { rank?: number })[]
                )
                  .filter(
                    (p) =>
                      (p.rank ?? 0) > 0 &&
                      (!documentId || p.id !== documentId)
                  )
                  .slice(0, 10);
                result = JSON.stringify({
                  query,
                  total_matches: matches.length,
                  papers: matches.map((p) => ({
                    title: p.title,
                    authors: p.authors,
                    year: p.year,
                    venue: p.venue,
                    abstract: p.abstract,
                  })),
                });
              } else if (block.name === "fix_metadata") {
                const paperTitle = (block.input as { paper_title?: string })?.paper_title;
                sseEmit(controller, {
                  type: "status",
                  message: paperTitle ? `Fixing metadata for "${paperTitle}"...` : "Fixing all missing metadata...",
                });

                let query: string;
                const params: string[] = [];
                if (paperTitle) {
                  query = `SELECT id, title, markdown FROM papers WHERE (authors IS NULL OR authors = '') AND LOWER(title) LIKE $1`;
                  params.push(`%${paperTitle.toLowerCase()}%`);
                } else {
                  query = `SELECT id, title, markdown FROM papers WHERE authors IS NULL OR authors = ''`;
                }
                const papersToFix = await pool.query(query, params);
                const fixed: string[] = [];
                const failed: string[] = [];

                for (const paper of papersToFix.rows) {
                  try {
                    const meta = await extractMetadata(paper.markdown);
                    const updates: string[] = [];
                    const vals: (string | number)[] = [];
                    let idx = 1;
                    if (meta.authors) { updates.push(`authors = $${idx++}`); vals.push(meta.authors); }
                    if (meta.year) { updates.push(`year = $${idx++}`); vals.push(meta.year); }
                    if (meta.abstract) { updates.push(`abstract = $${idx++}`); vals.push(meta.abstract); }
                    if (meta.keywords) { updates.push(`keywords = $${idx++}`); vals.push(meta.keywords); }
                    if (meta.title && paper.title.startsWith("##")) { updates.push(`title = $${idx++}`); vals.push(meta.title); }
                    if (updates.length > 0) {
                      vals.push(paper.id);
                      await pool.query(`UPDATE papers SET ${updates.join(", ")} WHERE id = $${idx}`, vals);
                      fixed.push(meta.title || paper.title);
                    } else {
                      failed.push(`${paper.title}: LLM could not extract metadata`);
                    }
                  } catch (err) {
                    failed.push(`${paper.title}: ${err instanceof Error ? err.message : "error"}`);
                  }
                }

                result = JSON.stringify({
                  total_found: papersToFix.rows.length,
                  fixed: fixed.length,
                  fixed_papers: fixed,
                  failed: failed.length,
                  failed_papers: failed,
                });
              } else if (block.name === "get_metadata_status") {
                sseEmit(controller, { type: "status", message: "Checking metadata coverage..." });
                const stats = await pool.query(`
                  SELECT
                    COUNT(*) as total,
                    COUNT(CASE WHEN authors IS NOT NULL AND authors != '' THEN 1 END) as with_authors,
                    COUNT(CASE WHEN year IS NOT NULL THEN 1 END) as with_year,
                    COUNT(CASE WHEN abstract IS NOT NULL AND abstract != '' THEN 1 END) as with_abstract,
                    COUNT(CASE WHEN keywords IS NOT NULL AND keywords != '' THEN 1 END) as with_keywords
                  FROM papers
                `);
                const s = stats.rows[0];
                const missing = await pool.query(
                  `SELECT title, authors, year FROM papers WHERE authors IS NULL OR authors = '' ORDER BY created_at DESC LIMIT 20`
                );
                result = JSON.stringify({
                  total_papers: parseInt(s.total),
                  with_authors: parseInt(s.with_authors),
                  with_year: parseInt(s.with_year),
                  with_abstract: parseInt(s.with_abstract),
                  with_keywords: parseInt(s.with_keywords),
                  missing_metadata_papers: missing.rows.map((r: { title: string }) => r.title),
                });
              } else if (block.name === "delete_duplicates") {
                const dryRun = (block.input as { dry_run?: boolean })?.dry_run ?? false;
                sseEmit(controller, { type: "status", message: dryRun ? "Scanning for duplicates..." : "Deleting duplicates..." });

                // Find duplicates grouped by title
                const dupes = await pool.query(`
                  SELECT title, array_agg(id ORDER BY
                    CASE WHEN authors IS NOT NULL AND authors != '' THEN 0 ELSE 1 END,
                    CASE WHEN year IS NOT NULL THEN 0 ELSE 1 END,
                    CASE WHEN abstract IS NOT NULL AND abstract != '' THEN 0 ELSE 1 END,
                    created_at DESC
                  ) as ids, COUNT(*) as cnt
                  FROM papers
                  GROUP BY title
                  HAVING COUNT(*) > 1
                `);

                if (dupes.rows.length === 0) {
                  result = JSON.stringify({ duplicates_found: 0, message: "No duplicates found" });
                } else {
                  const deleted: { title: string; kept: string; removed: string[] }[] = [];
                  for (const row of dupes.rows) {
                    const [keep, ...remove] = row.ids as string[];
                    if (!dryRun) {
                      for (const id of remove) {
                        await pool.query(`DELETE FROM papers WHERE id = $1`, [id]);
                      }
                    }
                    deleted.push({ title: row.title, kept: keep, removed: remove });
                  }
                  const totalRemoved = deleted.reduce((sum, d) => sum + d.removed.length, 0);
                  result = JSON.stringify({
                    dry_run: dryRun,
                    duplicate_groups: dupes.rows.length,
                    total_removed: totalRemoved,
                    details: deleted.map(d => ({
                      title: d.title,
                      copies_removed: d.removed.length,
                    })),
                  });
                }
              } else {
                console.warn(
                  `[Agent] Unknown tool requested: ${block.name}`
                );
                result = JSON.stringify({
                  error: `Unknown tool: ${block.name}`,
                });
              }
              console.log(
                `[Agent] Tool result for ${block.name} (${block.id}): ${result.slice(0, 200)}${result.length > 200 ? "..." : ""}`
              );
              return {
                tool_use_id: block.id!,
                content: result,
              };
            })
          );

          // Format tool results using the provider's convention
          const toolMessages = provider.formatToolResults(toolResults);
          agentMessages.push(...toolMessages);
        }

        // Exhausted MAX_STEPS — one final call with fallback model
        console.log(`[Agent] Reached step limit (${MAX_STEPS}), making final summary call`);
        sseEmit(controller, {
          type: "status",
          message: "Wrapping up...",
          new_step: true,
        });
        // Tell the LLM it must stop using tools and give a final answer
        agentMessages.push({
          role: "user",
          content: "[SYSTEM: You have reached the maximum number of tool calls. You MUST now give your final response to the user. Summarize what you accomplished, note anything still in progress, and do NOT call any more tools.]",
        });
        const finalResponse = await callLLMStream(
          controller,
          paperMarkdown,
          agentMessages,
          {
            includePaper: false,
            model: provider.fallbackModel,
            genericMode: isGenericMode,
          }
        );
        accumulateUsage(finalResponse.usage);

        const finalStepText = finalResponse.content
          .filter((b) => b.type === "text")
          .map((b) => b.text)
          .join("");
        const finalText = accumulatedText
          ? accumulatedText + "\n\n" + finalStepText
          : finalStepText;

        await emitResultAndClose(finalText);
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : "Chat failed";
        console.error("Chat error:", message);
        if (err instanceof Error && err.stack) {
          console.error("Chat error stack:", err.stack);
        }
        sseEmit(controller, { type: "error", message });
        controller.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
    },
  });
}
