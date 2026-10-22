// The server's own request shape for one model call (chat, titles, suggestions, Study maps, tags, podcast scripts).
// Every call goes to OpenRouter (owner direction 2026-10-18, reaffirmed 2026-10-21: OpenRouter exclusively); this shape is
// never sent anywhere as-is. openrouter-chat.ts translates it into OpenRouter's chat/completions body. It keeps the
// block structure (system blocks with a cache breakpoint, user/assistant turns, tool calls and results) that the hold,
// replay digest and cache-prefix rules were written against. Deno and Node compatible: types only.

export interface CacheControl { type: 'ephemeral'; ttl?: '5m' | '1h' }
export interface TextBlock { type: 'text'; text: string; cache_control?: CacheControl | null }
export interface ImageBlock {
  type: 'image';
  source: { type: 'base64'; media_type: 'image/png' | 'image/jpeg' | 'image/gif' | 'image/webp'; data: string };
  cache_control?: CacheControl | null;
}
/** A page our search tool returned (search_web, Tavily): sent to the model as text naming its address. */
export interface SearchResultBlock {
  type: 'search_result'; source: string; title: string; content: TextBlock[]; citations?: { enabled: boolean };
  cache_control?: CacheControl | null;
}
export interface ToolUseBlock { type: 'tool_use'; id: string; name: string; input: unknown; cache_control?: CacheControl | null }
export interface ToolResultBlock {
  type: 'tool_result'; tool_use_id: string; content: string | (TextBlock | ImageBlock | SearchResultBlock)[];
  is_error?: boolean; cache_control?: CacheControl | null;
}
/** A finished turn's reasoning details, sent back unchanged when the answer continues after a tool round. */
export interface ReasoningBlock { type: 'openrouter_reasoning'; details: unknown[]; cache_control?: CacheControl | null }
export type ContentBlock = TextBlock | ImageBlock | SearchResultBlock | ToolUseBlock | ToolResultBlock | ReasoningBlock;
export interface MessageParam { role: 'user' | 'assistant'; content: string | ContentBlock[] }

/** A function tool the model may call; our server runs it or relays it. Provider-native (server-side) tools are not
 * part of this shape: their cost cannot be bounded before the request (CHAT.md "Web search"). */
export interface ToolDefinition {
  name: string;
  description: string;
  input_schema: { type: 'object'; properties?: Record<string, unknown>; required?: readonly string[] | string[]; [key: string]: unknown };
}
export type ToolChoice = { type: 'auto' } | { type: 'any' } | { type: 'none' } | { type: 'tool'; name: string };
export type Effort = 'low' | 'medium' | 'high';

export interface ModelRequest {
  /** The OpenRouter model (`anthropic/claude-sonnet-5.5`, `google/…` through GEMINI_MODEL, `deepseek/…`). */
  model: string;
  /** The output allowance, reasoning included. */
  max_tokens: number;
  system?: string | TextBlock[];
  messages: MessageParam[];
  tools?: ToolDefinition[];
  tool_choice?: ToolChoice;
  /** `disabled` turns reasoning off where the route allows it; anything else asks for reasoning at `output_config.effort`. */
  thinking?: { type: string };
  /** `minimal` is Gemini's (the paper explainer: CHAT.md "Paper AI Explainer", "Speed"); Claude and DeepSeek take the others. */
  output_config?: { effort?: Effort | 'minimal'; format?: { type: 'json_schema'; schema: Record<string, unknown> } };
}
