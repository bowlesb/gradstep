"use client";

import { useState } from "react";
import { FeedResult } from "@/lib/db";

export interface FeedTopic {
  name: string;
  count: number;
}

interface Props {
  topics: FeedTopic[];
  results: FeedResult[];
  loading: boolean;
  refreshing: boolean;
  activeTopic: string | null;
  onTopicChange: (topic: string | null) => void;
  onRefresh: () => void;
  onIngest: (pdfUrl: string, title: string) => Promise<void>;
  onGoToLibrary: () => void;
  onOpenUpload: () => void;
  device: "mobile" | "tablet" | "desktop";
  lastRefreshed?: string | null;
}

function timeAgo(isoDate: string): string {
  const diff = Date.now() - new Date(isoDate).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

function formatDate(dateStr: string | null): string {
  if (!dateStr) return "";
  const d = new Date(dateStr);
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

export default function ResearchFeed({
  topics,
  results,
  loading,
  refreshing,
  activeTopic,
  onTopicChange,
  onRefresh,
  onIngest,
  onGoToLibrary,
  onOpenUpload,
  device,
  lastRefreshed,
}: Props) {
  const isMobile = device === "mobile";

  // Track ingestion status per paper: "adding" | "added"
  const [ingestStatus, setIngestStatus] = useState<Record<string, "adding" | "added">>({});

  async function handleIngest(pdfUrl: string, title: string) {
    setIngestStatus((prev) => ({ ...prev, [pdfUrl]: "adding" }));
    try {
      await onIngest(pdfUrl, title);
      setIngestStatus((prev) => ({ ...prev, [pdfUrl]: "added" }));
    } catch {
      setIngestStatus((prev) => {
        const next = { ...prev };
        delete next[pdfUrl];
        return next;
      });
    }
  }

  // Filter results by active topic
  const filteredResults = activeTopic
    ? results.filter((r) => r.topic === activeTopic)
    : results;

  // Loading state
  if (loading && results.length === 0) {
    return (
      <div className="feed-container">
        <div className={`feed-header ${isMobile ? "mobile" : ""}`}>
          <div className="feed-header-row">
            <h1>Research Feed</h1>
          </div>
          <div className="feed-subtitle">Discovering papers based on your library...</div>
        </div>
        <div className="feed-empty">
          <div className="spinner" style={{ fontSize: 24 }}>
            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="var(--accent)" strokeWidth="2">
              <path d="M21 12a9 9 0 1 1-6.219-8.56" />
            </svg>
          </div>
          <p>Searching for recent papers matching your interests...</p>
        </div>
      </div>
    );
  }

  // Empty state: no papers in library
  if (topics.length === 0 && !loading) {
    return (
      <div className="feed-container">
        <div className={`feed-header ${isMobile ? "mobile" : ""}`}>
          <div className="feed-header-row">
            <h1>Research Feed</h1>
            <div style={{ flex: 1 }} />
            <button
              onClick={onGoToLibrary}
              style={{
                background: "transparent",
                border: "1px solid var(--border)",
                borderRadius: "8px",
                padding: "6px 12px",
                cursor: "pointer",
                color: "var(--text-secondary)",
                fontSize: "13px",
                display: "flex",
                alignItems: "center",
                gap: 4,
              }}
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20" />
                <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z" />
              </svg>
              Library
            </button>
          </div>
          <div className="feed-subtitle">Personalized recommendations based on your library</div>
        </div>
        <div className="feed-empty">
          <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="var(--text-secondary)" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" style={{ opacity: 0.5 }}>
            <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20" />
            <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z" />
          </svg>
          <h3>Add papers to get recommendations</h3>
          <p>
            Upload research papers to your library. We&apos;ll analyze your topics
            and find recent papers you might be interested in.
          </p>
          <div className="feed-empty-actions">
            <button className="feed-empty-btn primary" onClick={onOpenUpload}>
              Upload Paper
            </button>
            <button className="feed-empty-btn" onClick={onGoToLibrary}>
              Browse Library
            </button>
          </div>
        </div>
      </div>
    );
  }

  // Empty state: topics exist but no results
  if (filteredResults.length === 0 && !loading) {
    return (
      <div className="feed-container">
        <div className={`feed-header ${isMobile ? "mobile" : ""}`}>
          <div className="feed-header-row">
            <h1>Research Feed</h1>
            <div style={{ flex: 1 }} />
            <button
              onClick={onGoToLibrary}
              style={{
                background: "transparent",
                border: "1px solid var(--border)",
                borderRadius: "8px",
                padding: "6px 12px",
                cursor: "pointer",
                color: "var(--text-secondary)",
                fontSize: "13px",
                display: "flex",
                alignItems: "center",
                gap: 4,
              }}
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20" />
                <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z" />
              </svg>
              Library
            </button>
          </div>
        </div>
        {topics.length > 0 && (
          <div className={`feed-topic-chips ${isMobile ? "mobile" : ""}`}>
            <button
              className={`feed-chip ${!activeTopic ? "active" : ""}`}
              onClick={() => onTopicChange(null)}
            >
              All
            </button>
            {topics.map((t) => (
              <button
                key={t.name}
                className={`feed-chip ${activeTopic === t.name ? "active" : ""}`}
                onClick={() => onTopicChange(activeTopic === t.name ? null : t.name)}
              >
                {t.name}
                {t.count > 0 && <span className="feed-chip-count">{t.count}</span>}
              </button>
            ))}
          </div>
        )}
        <div className="feed-empty">
          <h3>No new papers this month</h3>
          <p>Check back later or try refreshing to search for the latest papers.</p>
          <div className="feed-empty-actions">
            <button
              className="feed-empty-btn primary"
              onClick={onRefresh}
              disabled={refreshing}
            >
              {refreshing ? "Refreshing..." : "Refresh Feed"}
            </button>
          </div>
        </div>
      </div>
    );
  }

  // Main feed view with results
  return (
    <div className="feed-container">
      <div className={`feed-header ${isMobile ? "mobile" : ""}`}>
        <div className="feed-header-row">
          <h1>Research Feed</h1>
          <div style={{ flex: 1 }} />
          <button
            onClick={onOpenUpload}
            title="Upload Paper"
            style={{
              background: "transparent",
              border: "1px solid var(--border)",
              borderRadius: "8px",
              padding: "6px 8px",
              cursor: "pointer",
              color: "var(--text-secondary)",
              display: "flex",
              alignItems: "center",
            }}
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
              <polyline points="17 8 12 3 7 8" />
              <line x1="12" y1="3" x2="12" y2="15" />
            </svg>
          </button>
          <button
            onClick={onGoToLibrary}
            title="Library"
            style={{
              background: "transparent",
              border: "1px solid var(--border)",
              borderRadius: "8px",
              padding: "6px 8px",
              cursor: "pointer",
              color: "var(--text-secondary)",
              display: "flex",
              alignItems: "center",
            }}
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20" />
              <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z" />
            </svg>
          </button>
        </div>
        <div className="feed-subtitle">Recent papers matching your research interests</div>
      </div>

      {/* Topic chips */}
      <div className={`feed-topic-chips ${isMobile ? "mobile" : ""}`}>
        <button
          className={`feed-chip ${!activeTopic ? "active" : ""}`}
          onClick={() => onTopicChange(null)}
        >
          All
        </button>
        {topics.map((t) => (
          <button
            key={t.name}
            className={`feed-chip ${activeTopic === t.name ? "active" : ""}`}
            onClick={() => onTopicChange(activeTopic === t.name ? null : t.name)}
          >
            {t.name}
            {t.count > 0 && <span className="feed-chip-count">{t.count}</span>}
          </button>
        ))}
      </div>

      {/* Status bar */}
      <div className={`feed-status-bar ${isMobile ? "mobile" : ""}`}>
        <span>
          {filteredResults.length} paper{filteredResults.length !== 1 ? "s" : ""}
          {lastRefreshed && ` \u00b7 Updated ${timeAgo(lastRefreshed)}`}
        </span>
        <div style={{ flex: 1 }} />
        <button
          className={`feed-refresh-btn ${refreshing ? "spinning" : ""}`}
          onClick={onRefresh}
          disabled={refreshing}
        >
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <polyline points="23 4 23 10 17 10" />
            <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10" />
          </svg>
          {refreshing ? "Refreshing..." : "Refresh"}
        </button>
      </div>

      {/* Card grid */}
      <div className="feed-grid">
        {filteredResults.map((paper) => (
          <div key={paper.id} className="feed-card">
            <div className="feed-card-title" style={{
              display: "-webkit-box",
              WebkitLineClamp: 2,
              WebkitBoxOrient: "vertical" as const,
              overflow: "hidden",
            }}>{paper.title}</div>
            {paper.authors ? (
              <div className="feed-card-authors" style={{
                overflow: "hidden",
                textOverflow: "ellipsis",
                whiteSpace: "nowrap",
              }}>{paper.authors}</div>
            ) : null}
            {paper.abstract ? (
              <div className="feed-card-abstract" style={{
                display: "-webkit-box",
                WebkitLineClamp: 3,
                WebkitBoxOrient: "vertical" as const,
                overflow: "hidden",
              }}>{paper.abstract}</div>
            ) : null}
            <div className="feed-card-meta">
              {paper.publication_date ? (
                <span>{formatDate(paper.publication_date)}</span>
              ) : null}
              {paper.citation_count > 0 ? (
                <span>{paper.citation_count} citations</span>
              ) : null}
              <span className="feed-badge">{paper.topic}</span>
            </div>
            <div>
              {ingestStatus[paper.pdf_url] === "added" ? (
                <button
                  className="feed-add-btn ingested"
                  onClick={onGoToLibrary}
                >
                  See in Library
                </button>
              ) : (
                <button
                  className="feed-add-btn"
                  onClick={() => handleIngest(paper.pdf_url, paper.title)}
                  disabled={ingestStatus[paper.pdf_url] === "adding"}
                >
                  {ingestStatus[paper.pdf_url] === "adding" ? "Adding..." : "+ Add to Library"}
                </button>
              )}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
