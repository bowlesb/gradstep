import {
  getTopKeywords,
  getStaleTopics,
  saveFeedResults,
  updateFeedMetadata,
  clearOldFeedResults,
  getFeedResults,
  FeedResult,
} from "@/lib/db";
import { searchRecentPapers } from "@/lib/paper-search";

interface RefreshOptions {
  forceRefresh?: boolean;
  maxTopics?: number;
}

export interface FeedData {
  topics: string[];
  results: FeedResult[];
  lastRefreshed: string | null;
}

export async function refreshFeed(
  options?: RefreshOptions
): Promise<FeedData> {
  const { forceRefresh = false, maxTopics = 8 } = options || {};

  // 1. Get top keywords from library
  const topics = await getTopKeywords(maxTopics);
  if (topics.length === 0) {
    return { topics: [], results: [], lastRefreshed: null };
  }

  // 2. Find which topics need refreshing (>6h old, or all if forced)
  const staleTopics = forceRefresh
    ? topics
    : await getStaleTopics(6, topics);

  // 3. Fetch new results for stale topics
  if (staleTopics.length > 0) {
    for (let i = 0; i < staleTopics.length; i++) {
      const topic = staleTopics[i];

      // Rate-limit delay between calls (skip first)
      if (i > 0) {
        await new Promise((r) => setTimeout(r, 1100));
      }

      try {
        const results = await searchRecentPapers(topic);
        if (results.length > 0) {
          await saveFeedResults(
            results.map((r) => ({ ...r, topic }))
          );
        }
        await updateFeedMetadata(topic, results.length);
      } catch (err) {
        if (err instanceof Error && err.message === "rate_limited") {
          console.warn(
            `[Feed] Rate limited on topic "${topic}", skipping remaining topics`
          );
          break;
        }
        console.error(`[Feed] Error fetching topic "${topic}":`, err);
      }
    }

    // 4. Prune old entries
    await clearOldFeedResults(45);
  }

  // 5. Return all cached results
  const results = await getFeedResults(topics);
  const lastRefreshed = new Date().toISOString();

  return { topics, results, lastRefreshed };
}
