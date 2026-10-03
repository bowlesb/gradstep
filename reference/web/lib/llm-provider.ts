// ---------------------------------------------------------------------------
// lib/llm-provider.ts – Normalised LLM provider abstraction
// Supports Anthropic (Claude) and DeepSeek via a common interface.
// ---------------------------------------------------------------------------

// ---- Normalised types used by the agent loop in route.ts -------------------

export interface ContentBlock {
  type: string;
  text?: string;
  id?: string;
  name?: string;
  input?: Record<string, string>;
}

export interface LLMUsage {
  input_tokens?: number;
  output_tokens?: number;
  cache_creation_input_tokens?: number;
  cache_read_input_tokens?: number;
}

export interface LLMResponse {
  content: ContentBlock[];
  stop_reason: string;
  usage: LLMUsage;
}

export interface ToolDefinition {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
}

export interface AgentMessage {
  role: "user" | "assistant" | "system" | "tool";
  content: string | ContentBlock[] | Record<string, unknown>[];
  tool_call_id?: string;
}

export interface SystemBlock {
  text: string;
  cache: boolean; // whether this block should be cached
}

// ---- Provider interface ----------------------------------------------------

export interface LLMProvider {
  name: string;
  primaryModel: string;
  fallbackModel: string;
  maxRetries: number;
  initialBackoffMs: number;
  retryableStatuses: number[];

  /** Build the fetch request for the provider's API. */
  buildRequest(
    model: string,
    maxTokens: number,
    systemBlocks: SystemBlock[],
    tools: ToolDefinition[],
    messages: AgentMessage[]
  ): { url: string; headers: Record<string, string>; body: string };

  /** Parse SSE stream, emit text deltas to client, return normalised response. */
  parseSSE(
    response: Response,
    sseController: ReadableStreamDefaultController
  ): Promise<LLMResponse>;

  /** Format tool execution results into messages for the next API call. */
  formatToolResults(
    results: { tool_use_id: string; content: string }[]
  ): AgentMessage[];
}

// ---- Helpers ---------------------------------------------------------------

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

// ---- Anthropic provider ----------------------------------------------------

const anthropicProvider: LLMProvider = {
  name: "anthropic",
  primaryModel: "claude-sonnet-4-5-20250929",
  fallbackModel: "claude-haiku-4-5-20251001",
  maxRetries: 3,
  initialBackoffMs: 5_000,
  retryableStatuses: [429, 529],

  buildRequest(model, maxTokens, systemBlocks, tools, messages) {
    const system = systemBlocks.map((b) =>
      b.cache
        ? { type: "text", text: b.text, cache_control: { type: "ephemeral" } }
        : { type: "text", text: b.text }
    );

    const anthropicTools = tools.map((t) => ({
      name: t.name,
      description: t.description,
      input_schema: t.parameters,
    }));

    // Convert AgentMessage[] → Anthropic message format
    const anthropicMessages = messages
      .filter((m) => m.role !== "system")
      .map((m) => ({ role: m.role as "user" | "assistant", content: m.content }));

    return {
      url: "https://api.anthropic.com/v1/messages",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": process.env.ANTHROPIC_API_KEY!,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model,
        max_tokens: maxTokens,
        stream: true,
        system,
        tools: anthropicTools,
        messages: anthropicMessages,
      }),
    };
  },

  async parseSSE(res, sseController) {
    const reader = res.body!.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    const contentBlocks: ContentBlock[] = [];
    const jsonBuffers = new Map<number, string>();
    const lastProgressEmit = new Map<number, number>();
    let stopReason = "";
    let usage: LLMUsage = {};

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";

      for (const line of lines) {
        if (!line.startsWith("data: ")) continue;
        const jsonStr = line.slice(6).trim();
        if (!jsonStr || jsonStr === "[DONE]") continue;

        let data;
        try {
          data = JSON.parse(jsonStr);
        } catch {
          continue;
        }

        switch (data.type) {
          case "message_start":
            usage = data.message?.usage || {};
            break;

          case "content_block_start": {
            const block = data.content_block;
            if (block.type === "text") {
              contentBlocks[data.index] = { type: "text", text: "" };
            } else if (block.type === "tool_use") {
              contentBlocks[data.index] = {
                type: "tool_use",
                id: block.id,
                name: block.name,
                input: {},
              };
              jsonBuffers.set(data.index, "");
              const toolLabel =
                block.name === "create_diagram"
                  ? "Generating diagram..."
                  : block.name === "tavily_search"
                    ? "Preparing search..."
                    : block.name === "ingest_paper"
                      ? "Looking up paper..."
                      : block.name === "search_library"
                        ? "Searching library..."
                        : "Processing...";
              sseEmit(sseController, { type: "status", message: toolLabel });
            }
            break;
          }

          case "content_block_delta": {
            const block = contentBlocks[data.index];
            if (data.delta.type === "text_delta" && block?.type === "text") {
              block.text = (block.text || "") + data.delta.text;
              sseEmit(sseController, {
                type: "text_delta",
                text: data.delta.text,
              });
            } else if (data.delta.type === "input_json_delta") {
              const prev = jsonBuffers.get(data.index) || "";
              jsonBuffers.set(data.index, prev + data.delta.partial_json);
              if (contentBlocks[data.index]?.name === "create_diagram") {
                const now = Date.now();
                const last = lastProgressEmit.get(data.index) || 0;
                if (now - last > 2000) {
                  lastProgressEmit.set(data.index, now);
                  const kb = (
                    (jsonBuffers.get(data.index) || "").length / 1024
                  ).toFixed(1);
                  sseEmit(sseController, {
                    type: "status",
                    message: `Generating diagram... (${kb}KB composed)`,
                  });
                }
              }
            }
            break;
          }

          case "content_block_stop": {
            const jsonBuf = jsonBuffers.get(data.index);
            if (
              jsonBuf !== undefined &&
              contentBlocks[data.index]?.type === "tool_use"
            ) {
              try {
                contentBlocks[data.index].input = JSON.parse(jsonBuf);
              } catch {
                contentBlocks[data.index].input = {};
              }
              jsonBuffers.delete(data.index);
            }
            break;
          }

          case "message_delta":
            stopReason = data.delta?.stop_reason || stopReason;
            if (data.usage) {
              usage.output_tokens = data.usage.output_tokens;
            }
            break;

          case "error":
            throw new Error(data.error?.message || "Claude streaming error");
        }
      }
    }

    return { content: contentBlocks, stop_reason: stopReason, usage };
  },

  formatToolResults(results) {
    return [
      {
        role: "user" as const,
        content: results.map((r) => ({
          type: "tool_result",
          tool_use_id: r.tool_use_id,
          content: r.content,
        })),
      },
    ];
  },
};

// ---- DeepSeek provider -----------------------------------------------------

const deepseekProvider: LLMProvider = {
  name: "deepseek",
  primaryModel: "deepseek-chat",
  fallbackModel: "deepseek-chat",
  maxRetries: 3,
  initialBackoffMs: 5_000,
  retryableStatuses: [429, 503],

  buildRequest(model, maxTokens, systemBlocks, tools, messages) {
    // System prompt goes as a system message
    const systemText = systemBlocks.map((b) => b.text).join("\n\n");

    // Convert tools to OpenAI format
    const openaiTools = tools.map((t) => ({
      type: "function" as const,
      function: {
        name: t.name,
        description: t.description,
        parameters: t.parameters,
      },
    }));

    // Convert AgentMessage[] → OpenAI message format
    const openaiMessages: Record<string, unknown>[] = [
      { role: "system", content: systemText },
    ];

    for (const msg of messages) {
      if (msg.role === "system") continue;
      if (msg.role === "tool") {
        openaiMessages.push({
          role: "tool",
          tool_call_id: msg.tool_call_id,
          content: msg.content as string,
        });
      } else if (msg.role === "assistant" && Array.isArray(msg.content)) {
        // Convert ContentBlock[] to OpenAI assistant message with tool_calls
        const blocks = msg.content as ContentBlock[];
        const textParts = blocks.filter((b) => b.type === "text");
        const toolParts = blocks.filter((b) => b.type === "tool_use");

        const assistantMsg: Record<string, unknown> = {
          role: "assistant",
          content:
            textParts.length > 0
              ? textParts.map((b) => b.text).join("")
              : null,
        };

        if (toolParts.length > 0) {
          assistantMsg.tool_calls = toolParts.map((b) => ({
            id: b.id,
            type: "function",
            function: {
              name: b.name,
              arguments: JSON.stringify(b.input || {}),
            },
          }));
        }

        openaiMessages.push(assistantMsg);
      } else if (msg.role === "user" && Array.isArray(msg.content)) {
        // Anthropic tool results come as user messages with tool_result blocks.
        // For DeepSeek these are already converted via formatToolResults, but
        // handle gracefully if encountered.
        const blocks = msg.content as Record<string, unknown>[];
        for (const block of blocks) {
          if (block.type === "tool_result") {
            openaiMessages.push({
              role: "tool",
              tool_call_id: block.tool_use_id as string,
              content: block.content as string,
            });
          }
        }
      } else {
        openaiMessages.push({
          role: msg.role,
          content: msg.content as string,
        });
      }
    }

    // Cap max_tokens to DeepSeek's limit
    const cappedMaxTokens = Math.min(maxTokens, 8192);

    return {
      url: "https://api.deepseek.com/chat/completions",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${process.env.DEEPSEEK_API_KEY!}`,
      },
      body: JSON.stringify({
        model,
        max_tokens: cappedMaxTokens,
        stream: true,
        stream_options: { include_usage: true },
        tools: openaiTools,
        messages: openaiMessages,
      }),
    };
  },

  async parseSSE(res, sseController) {
    const reader = res.body!.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    let textContent = "";
    // Accumulate tool calls by index
    const toolCalls = new Map<
      number,
      { id: string; name: string; arguments: string }
    >();
    let stopReason = "";
    let usage: LLMUsage = {};

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";

      for (const line of lines) {
        if (!line.startsWith("data: ")) continue;
        const jsonStr = line.slice(6).trim();
        if (!jsonStr || jsonStr === "[DONE]") continue;

        let data;
        try {
          data = JSON.parse(jsonStr);
        } catch {
          continue;
        }

        // Usage comes in the final chunk (with stream_options.include_usage)
        if (data.usage) {
          usage = {
            input_tokens: data.usage.prompt_tokens,
            output_tokens: data.usage.completion_tokens,
            cache_creation_input_tokens:
              data.usage.prompt_cache_miss_tokens ?? 0,
            cache_read_input_tokens:
              data.usage.prompt_cache_hit_tokens ?? 0,
          };
        }

        const choice = data.choices?.[0];
        if (!choice) continue;

        // Finish reason
        if (choice.finish_reason) {
          // Normalise: "tool_calls" → "tool_use", "stop" → "end_turn"
          if (choice.finish_reason === "tool_calls") {
            stopReason = "tool_use";
          } else if (choice.finish_reason === "stop") {
            stopReason = "end_turn";
          } else if (choice.finish_reason === "length") {
            stopReason = "max_length";
          } else {
            stopReason = choice.finish_reason;
          }
        }

        const delta = choice.delta;
        if (!delta) continue;

        // Text content
        if (delta.content) {
          textContent += delta.content;
          sseEmit(sseController, {
            type: "text_delta",
            text: delta.content,
          });
        }

        // Tool calls (streamed incrementally)
        if (delta.tool_calls) {
          for (const tc of delta.tool_calls) {
            const idx = tc.index ?? 0;
            if (!toolCalls.has(idx)) {
              toolCalls.set(idx, {
                id: tc.id || "",
                name: tc.function?.name || "",
                arguments: "",
              });
              // Emit status for tool call start
              const toolName = tc.function?.name || "";
              const toolLabel =
                toolName === "create_diagram"
                  ? "Generating diagram..."
                  : toolName === "tavily_search"
                    ? "Preparing search..."
                    : toolName === "ingest_paper"
                      ? "Looking up paper..."
                      : toolName === "search_library"
                        ? "Searching library..."
                        : "Processing...";
              sseEmit(sseController, { type: "status", message: toolLabel });
            }

            const existing = toolCalls.get(idx)!;
            if (tc.id) existing.id = tc.id;
            if (tc.function?.name) existing.name = tc.function.name;
            if (tc.function?.arguments) {
              existing.arguments += tc.function.arguments;

              // Progress for diagram generation
              if (existing.name === "create_diagram") {
                const kb = (existing.arguments.length / 1024).toFixed(1);
                if (existing.arguments.length % 2048 < 100) {
                  sseEmit(sseController, {
                    type: "status",
                    message: `Generating diagram... (${kb}KB composed)`,
                  });
                }
              }
            }
          }
        }
      }
    }

    // Build normalised content blocks
    const contentBlocks: ContentBlock[] = [];
    if (textContent) {
      contentBlocks.push({ type: "text", text: textContent });
    }
    for (const [, tc] of toolCalls) {
      let parsedInput: Record<string, string> = {};
      try {
        parsedInput = JSON.parse(tc.arguments);
      } catch {
        /* empty */
      }
      contentBlocks.push({
        type: "tool_use",
        id: tc.id,
        name: tc.name,
        input: parsedInput,
      });
    }

    return { content: contentBlocks, stop_reason: stopReason, usage };
  },

  formatToolResults(results) {
    // DeepSeek/OpenAI format: separate tool messages for each result
    return results.map((r) => ({
      role: "tool" as const,
      tool_call_id: r.tool_use_id,
      content: r.content,
    }));
  },
};

// ---- Factory ---------------------------------------------------------------

export function getProvider(): LLMProvider {
  const provider = (process.env.LLM_PROVIDER || "anthropic").toLowerCase();
  switch (provider) {
    case "deepseek":
      return deepseekProvider;
    case "anthropic":
      return anthropicProvider;
    default:
      console.warn(
        `[LLM] Unknown provider "${provider}", falling back to anthropic`
      );
      return anthropicProvider;
  }
}
