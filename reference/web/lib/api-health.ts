// Centralized API health tracking — surfaces errors to the UI

export type ApiService = "llm" | "mathpix" | "search";

export interface ApiError {
  service: ApiService;
  message: string;
  timestamp: number;
}

const ERROR_TTL_MS = 30 * 60 * 1000; // 30 minutes
const errors: ApiError[] = [];

const SERVICE_LABELS: Record<ApiService, string> = {
  llm: "LLM (AI)",
  mathpix: "Mathpix (PDF conversion)",
  search: "Tavily (web search)",
};

export function reportApiError(service: ApiService, message: string) {
  // Deduplicate: don't add if same service+message exists within last 60s
  const recent = errors.find(
    (e) => e.service === service && e.message === message && Date.now() - e.timestamp < 60_000
  );
  if (recent) return;

  errors.push({ service, message, timestamp: Date.now() });
  // Keep max 50
  if (errors.length > 50) errors.splice(0, errors.length - 50);
  console.error(`[API Health] ${SERVICE_LABELS[service]}: ${message}`);
}

export function getActiveErrors(): ApiError[] {
  const cutoff = Date.now() - ERROR_TTL_MS;
  return errors.filter((e) => e.timestamp > cutoff);
}

export function dismissErrors() {
  errors.length = 0;
}

export { SERVICE_LABELS };
