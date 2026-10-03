"use client";

import { useState, useEffect, useMemo, useCallback } from "react";
import PaperTable, { Paper, SortField, SortOrder, ExternalResult } from "./PaperTable";
import BugReportForm from "./BugReportForm";

export interface QueueSummary {
  total: number;
  pending: number;
  downloading: number;
  converting: number;
  extracting: number;
  complete: number;
  failed: number;
  processing: boolean;
}

interface Props {
  papers: Paper[];
  onSelectPaper: (paper: Paper) => void;
  onOpenUpload?: () => void;
  uploading: boolean;
  uploadProgress: string;
  selectedPaperId?: string | null;
  loadingPaperId?: string | null;
  sortField: SortField;
  sortOrder: SortOrder;
  onSort: (field: SortField) => void;
  onSearch: (query: string) => void;
  queueSummary?: QueueSummary | null;
  onRetryFailed?: () => void;
  onClearCompleted?: () => void;
  onToggleReader?: () => void;
  onDeletePaper?: (paperId: string) => void;
  externalResults?: ExternalResult[];
  externalSearching?: boolean;
  onSearchExternal?: (query: string) => void;
  onIngestExternal?: (pdfUrl: string, title: string) => void;
  mobile?: boolean;
  onGoToFeed?: () => void;
  onGoToAllChats?: () => void;
  onGoToAllDiagrams?: () => void;
  darkMode?: boolean;
  apiErrors?: { service: string; message: string; timestamp: number }[];
  onDismissApiErrors?: () => void;
  authUsername?: string | null;
  onLogout?: () => void;
  onAdmin?: () => void;
  offlineIds?: Set<string>;
  onToggleOffline?: (paper: Paper) => void;
  offlineSaving?: string | null;
  isOnline?: boolean;
}

export default function LibraryView({
  papers,
  onSelectPaper,
  onOpenUpload,
  uploading,
  uploadProgress,
  selectedPaperId,
  loadingPaperId,
  sortField,
  sortOrder,
  onSort,
  onSearch,
  queueSummary,
  onRetryFailed,
  onClearCompleted,
  onToggleReader,
  onDeletePaper,
  externalResults,
  externalSearching,
  onSearchExternal,
  onIngestExternal,
  mobile,
  onGoToFeed,
  onGoToAllChats,
  onGoToAllDiagrams,
  darkMode,
  apiErrors,
  onDismissApiErrors,
  authUsername,
  onLogout,
  onAdmin,
  offlineIds,
  onToggleOffline,
  offlineSaving,
  isOnline,
}: Props) {
  const [searchInput, setSearchInput] = useState("");
  const [showBugReport, setShowBugReport] = useState(false);

  // Escape key closes bug report modal
  useEffect(() => {
    if (!showBugReport) return;
    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === "Escape") { setShowBugReport(false); e.preventDefault(); }
    }
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [showBugReport]);
  const [searchMode, setSearchMode] = useState<"local" | "arxiv">("local");
  const [activeKeyword, setActiveKeyword] = useState<string | null>(null);
  const [showKeywords, setShowKeywords] = useState(false);
  const [searchFocused, setSearchFocused] = useState(false);

  // Extract unique keywords from all loaded papers
  const allKeywords = useMemo(() => {
    const counts = new Map<string, number>();
    for (const p of papers) {
      const kws = p.keywords;
      if (!kws) continue;
      for (const kw of kws.split(", ")) {
        const trimmed = kw.trim();
        if (trimmed) counts.set(trimmed, (counts.get(trimmed) || 0) + 1);
      }
    }
    return [...counts.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([kw]) => kw);
  }, [papers]);

  // Filter papers by active keyword (client-side)
  const filteredPapers = useMemo(() => {
    if (!activeKeyword) return papers;
    return papers.filter((p) => {
      const kws = p.keywords;
      if (!kws) return false;
      return kws.split(", ").some((k) => k.trim() === activeKeyword);
    });
  }, [papers, activeKeyword]);

  // Clear keyword filter and close overlay when searching
  useEffect(() => {
    if (searchInput) {
      setActiveKeyword(null);
      setShowKeywords(false);
    }
  }, [searchInput]);

  // Debounced search
  useEffect(() => {
    const timer = setTimeout(() => {
      if (searchMode === "arxiv" && onSearchExternal) {
        onSearchExternal(searchInput);
      } else {
        onSearch(searchInput);
      }
    }, 300);
    return () => clearTimeout(timer);
  }, [searchInput, searchMode, onSearch, onSearchExternal]);

  return (
    <div
      style={{
        height: "100%",
        display: "flex",
        flexDirection: "column",
        background: "var(--bg-primary)",
      }}
    >
      {/* Header */}
      <div
        className={mobile ? "mobile-header" : undefined}
        style={{
          padding: mobile ? "12px 16px" : "20px 24px",
          borderBottom: "1px solid var(--border)",
          display: "flex",
          alignItems: "center",
          gap: "12px",
          flexWrap: "wrap",
        }}
      >
        <div style={{ position: "relative", width: mobile ? undefined : "260px", flex: mobile ? 1 : undefined, minWidth: 0 }}>
          <input
            type="text"
            placeholder={activeKeyword ? `Filtered: ${activeKeyword}` : searchMode === "arxiv" ? "Search arXiv..." : "Search papers..."}
            value={searchInput}
            onChange={(e) => setSearchInput(e.target.value)}
            onFocus={() => setSearchFocused(true)}
            onBlur={() => setTimeout(() => setSearchFocused(false), 150)}
            style={{
              background: "var(--bg-secondary)",
              color: "var(--text-primary)",
              border: "1px solid var(--border)",
              borderRadius: "8px",
              padding: "8px 14px",
              fontSize: "14px",
              outline: "none",
              width: "100%",
              minWidth: 0,
            }}
          />
          {searchFocused && !searchInput && allKeywords.length > 0 && (
            <div
              style={{
                position: "absolute",
                top: "100%",
                left: 0,
                right: 0,
                zIndex: 10,
                background: "var(--bg-primary)",
                border: "1px solid var(--border)",
                borderRadius: "0 0 8px 8px",
                padding: "8px 10px",
                display: "flex",
                flexWrap: "wrap",
                gap: "4px 6px",
                boxShadow: "0 4px 12px rgba(0,0,0,0.12)",
                maxHeight: "160px",
                overflowY: "auto",
              }}
            >
              {activeKeyword && (
                <button
                  onMouseDown={(e) => { e.preventDefault(); setActiveKeyword(null); }}
                  style={{
                    fontSize: "11px", color: "var(--text-secondary)", background: "transparent",
                    border: "none", cursor: "pointer", padding: "3px 6px", textDecoration: "underline",
                  }}
                >
                  Clear filter
                </button>
              )}
              {allKeywords.slice(0, 20).map((kw) => (
                <button
                  key={kw}
                  onMouseDown={(e) => {
                    e.preventDefault();
                    setActiveKeyword(activeKeyword === kw ? null : kw);
                  }}
                  style={{
                    fontSize: "11px",
                    fontWeight: activeKeyword === kw ? 600 : 400,
                    color: activeKeyword === kw ? "#fff" : "var(--text-secondary)",
                    background: activeKeyword === kw ? "var(--accent)" : "var(--bg-secondary)",
                    border: "none",
                    borderRadius: "12px",
                    padding: "3px 8px",
                    cursor: "pointer",
                    transition: "all 0.12s ease",
                    whiteSpace: "nowrap",
                  }}
                >
                  {kw}
                </button>
              ))}
            </div>
          )}
        </div>

        {onSearchExternal && (
          <button
            onClick={() => {
              const next = searchMode === "local" ? "arxiv" : "local";
              setSearchMode(next);
              if (next === "local") {
                onSearch(searchInput);
              } else if (searchInput) {
                onSearchExternal(searchInput);
              }
            }}
            title={searchMode === "arxiv" ? "Switch to local search" : "Search arXiv / Semantic Scholar"}
            style={{
              background: searchMode === "arxiv" ? "var(--accent)" : "transparent",
              border: searchMode === "arxiv" ? "1px solid var(--accent)" : "1px solid var(--border)",
              borderRadius: "8px",
              padding: "6px 8px",
              cursor: "pointer",
              color: searchMode === "arxiv" ? "#fff" : "var(--text-secondary)",
              display: "flex",
              alignItems: "center",
              flexShrink: 0,
              transition: "all 0.15s ease",
            }}
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <circle cx="12" cy="12" r="10" />
              <line x1="2" y1="12" x2="22" y2="12" />
              <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" />
            </svg>
          </button>
        )}

        {!mobile && <div style={{ flex: 1 }} />}

        {onGoToAllChats && !mobile && (
          <button
            onClick={onGoToAllChats}
            className="instant-tooltip"
            data-tip="All Chats"
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
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
            </svg>
          </button>
        )}

        {onGoToAllDiagrams && !mobile && (
          <button
            onClick={onGoToAllDiagrams}
            className="instant-tooltip"
            data-tip="Diagrams"
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
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <rect x="3" y="3" width="18" height="18" rx="2" ry="2" />
              <line x1="3" y1="9" x2="21" y2="9" />
              <line x1="9" y1="21" x2="9" y2="9" />
            </svg>
          </button>
        )}

        {onGoToFeed && !mobile && (
          <button
            onClick={onGoToFeed}
            className="instant-tooltip"
            data-tip="Research Feed"
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
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M4 11a9 9 0 0 1 9 9" />
              <path d="M4 4a16 16 0 0 1 16 16" />
              <circle cx="5" cy="19" r="1" />
            </svg>
          </button>
        )}

        {onToggleReader && !mobile && (
          <button
            onClick={onToggleReader}
            title="Open Reader"
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
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z" />
              <path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z" />
            </svg>
          </button>
        )}

        {!mobile && (
          <button
            onClick={() => setShowBugReport(true)}
            title="Report a Bug"
            style={{
              background: "transparent",
              border: "1px solid var(--border)",
              borderRadius: "8px",
              padding: "6px 8px",
              cursor: "pointer",
              color: "var(--text-secondary)",
              display: "flex",
              alignItems: "center",
              flexShrink: 0,
            }}
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M8 2l1.88 1.88" />
              <path d="M14.12 3.88L16 2" />
              <path d="M9 7.13v-1a3.003 3.003 0 1 1 6 0v1" />
              <path d="M12 20c-3.3 0-6-2.7-6-6v-3a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v3c0 3.3-2.7 6-6 6" />
              <path d="M12 20v-9" />
              <path d="M6.53 9C4.6 8.8 3 7.1 3 5" />
              <path d="M6 13H2" />
              <path d="M3 21c0-2.1 1.7-3.9 3.8-4" />
              <path d="M20.97 5c0 2.1-1.6 3.8-3.5 4" />
              <path d="M22 13h-4" />
              <path d="M17.2 17c2.1.1 3.8 1.9 3.8 4" />
            </svg>
          </button>
        )}

        {isOnline === false && (
          <span
            style={{
              display: "inline-flex",
              alignItems: "center",
              gap: 4,
              fontSize: "11px",
              fontWeight: 600,
              color: "#f59e0b",
              background: "rgba(245,158,11,0.12)",
              padding: "4px 10px",
              borderRadius: "9999px",
              whiteSpace: "nowrap",
            }}
          >
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
              <line x1="1" y1="1" x2="23" y2="23" />
              <path d="M16.72 11.06A10.94 10.94 0 0 1 19 12.55" />
              <path d="M5 12.55a10.94 10.94 0 0 1 5.17-2.39" />
              <path d="M10.71 5.05A16 16 0 0 1 22.56 9" />
              <path d="M1.42 9a15.91 15.91 0 0 1 4.7-2.88" />
              <path d="M8.53 16.11a6 6 0 0 1 6.95 0" />
              <line x1="12" y1="20" x2="12.01" y2="20" />
            </svg>
            Offline
          </span>
        )}

        <button
          onClick={onOpenUpload}
          disabled={uploading}
          title="Upload PDF"
          style={{
            background: "transparent",
            border: "1px solid var(--border)",
            borderRadius: "8px",
            padding: "6px 8px",
            cursor: uploading ? "wait" : "pointer",
            color: "var(--text-secondary)",
            display: "flex",
            alignItems: "center",
            flexShrink: 0,
          }}
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
            <polyline points="17 8 12 3 7 8" />
            <line x1="12" y1="3" x2="12" y2="15" />
          </svg>
        </button>

        {onAdmin && !mobile && (
          <button
            onClick={onAdmin}
            title="User management"
            style={{
              background: "transparent",
              border: "1px solid var(--border)",
              borderRadius: "8px",
              padding: "6px 8px",
              cursor: "pointer",
              color: "var(--text-secondary)",
              display: "flex",
              alignItems: "center",
              gap: "4px",
              flexShrink: 0,
              fontSize: "12px",
            }}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" />
              <circle cx="9" cy="7" r="4" />
              <path d="M23 21v-2a4 4 0 0 0-3-3.87" />
              <path d="M16 3.13a4 4 0 0 1 0 7.75" />
            </svg>
          </button>
        )}

        {onLogout && authUsername && !mobile && (
          <button
            onClick={onLogout}
            title={`Sign out (${authUsername})`}
            style={{
              background: "transparent",
              border: "1px solid rgba(239,68,68,0.3)",
              borderRadius: "8px",
              padding: "6px 8px",
              cursor: "pointer",
              color: "#ef4444",
              display: "flex",
              alignItems: "center",
              gap: "4px",
              flexShrink: 0,
              fontSize: "12px",
            }}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
              <polyline points="16 17 21 12 16 7" />
              <line x1="21" y1="12" x2="9" y2="12" />
            </svg>
          </button>
        )}
      </div>

      {/* Upload progress */}
      {uploadProgress && (
        <div
          style={{
            padding: "8px 24px",
            background: "var(--bg-secondary)",
            borderBottom: "1px solid var(--border)",
            color: "var(--text-secondary)",
            fontSize: "13px",
          }}
        >
          {uploadProgress}
        </div>
      )}

      {/* API error flash banner */}
      {apiErrors && apiErrors.length > 0 && (
        <div
          style={{
            padding: "10px 24px",
            background: "rgba(239,68,68,0.1)",
            borderBottom: "2px solid #ef4444",
            display: "flex",
            alignItems: "flex-start",
            gap: "10px",
            fontSize: "13px",
            animation: "flash-error 0.6s ease-out",
          }}
        >
          <span style={{
            fontSize: "20px",
            lineHeight: "1",
            flexShrink: 0,
            animation: "pulse-error 2s infinite",
          }}>🚨</span>
          <div style={{ flex: 1 }}>
            <div style={{ color: "#ef4444", fontWeight: 700, marginBottom: "2px" }}>
              API Error — Ingestion Degraded
            </div>
            {[...new Map(apiErrors.map(e => [`${e.service}:${e.message}`, e])).values()].map((err, i) => (
              <div key={i} style={{ color: "var(--text-secondary)", fontSize: "12px" }}>
                {err.message}
              </div>
            ))}
          </div>
          {onDismissApiErrors && (
            <button
              onClick={onDismissApiErrors}
              style={{
                background: "transparent",
                border: "1px solid #ef4444",
                color: "#ef4444",
                borderRadius: "4px",
                padding: "2px 10px",
                fontSize: "12px",
                cursor: "pointer",
                flexShrink: 0,
              }}
            >
              Dismiss
            </button>
          )}
        </div>
      )}

      {/* Queue status – only show when items are actively processing or failed */}
      {queueSummary && (queueSummary.pending + queueSummary.downloading + queueSummary.converting + queueSummary.extracting + queueSummary.failed > 0) && (
        <div
          style={{
            padding: "8px 24px",
            background: "var(--bg-secondary)",
            borderBottom: "1px solid var(--border)",
            display: "flex",
            alignItems: "center",
            gap: "12px",
            fontSize: "13px",
          }}
        >
          {(queueSummary.processing || queueSummary.pending > 0) && (
            <span style={{ color: "var(--accent)" }}>
              <span className="spinner" style={{ fontSize: "12px", marginRight: "6px" }}>⟳</span>
              {queueSummary.downloading + queueSummary.converting + queueSummary.extracting > 0
                ? `Ingesting: ${queueSummary.downloading + queueSummary.converting + queueSummary.extracting} active`
                : "Starting ingestion..."}
              {queueSummary.pending > 0 && `, ${queueSummary.pending} queued`}
            </span>
          )}
          {queueSummary.failed > 0 && (
            <span style={{ color: "#ef4444" }}>
              {queueSummary.failed} failed
            </span>
          )}
          <span style={{ flex: 1 }} />
          {queueSummary.failed > 0 && onRetryFailed && (
            <button
              onClick={onRetryFailed}
              style={{
                background: "transparent",
                color: "var(--accent)",
                border: "1px solid var(--accent)",
                borderRadius: "4px",
                padding: "2px 8px",
                fontSize: "12px",
                cursor: "pointer",
              }}
            >
              Retry Failed
            </button>
          )}
        </div>
      )}

      {/* Table */}
      <div style={{ flex: 1, overflowY: "auto", padding: "0 8px", position: "relative" }}>
        <PaperTable
          papers={filteredPapers}
          sortField={sortField}
          sortOrder={sortOrder}
          onSort={onSort}
          onSelect={onSelectPaper}
          onDelete={onDeletePaper}
          selectedId={selectedPaperId}
          loadingId={loadingPaperId}
          searching={!!searchInput}
          mobile={mobile}
          externalResults={searchMode === "arxiv" ? externalResults : undefined}
          externalSearching={searchMode === "arxiv" ? externalSearching : undefined}
          onIngest={onIngestExternal}
          offlineIds={offlineIds}
          onToggleOffline={onToggleOffline}
          offlineSaving={offlineSaving}
        />
      </div>

      {/* Empty state with drop hint */}
      {filteredPapers.length === 0 && !uploading && !searchInput && !activeKeyword && (
        <div
          style={{
            position: "absolute",
            top: "50%",
            left: "50%",
            transform: "translate(-50%, -50%)",
            textAlign: "center",
            color: "var(--text-secondary)",
          }}
        >
          <p style={{ fontSize: "16px", marginBottom: "8px" }}>
            No papers yet
          </p>
          <p style={{ fontSize: "13px" }}>
            Click the upload icon to add a paper
          </p>
        </div>
      )}

      {/* Bug Report Modal (desktop) */}
      {showBugReport && (
        <div
          onClick={() => setShowBugReport(false)}
          style={{
            position: "fixed",
            inset: 0,
            zIndex: 200,
            background: "rgba(0,0,0,0.5)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            padding: 20,
          }}
        >
          <div
            onClick={(e) => e.stopPropagation()}
            style={{
              background: "var(--bg-primary)",
              borderRadius: 12,
              border: "1px solid var(--border)",
              width: "100%",
              maxWidth: 480,
              maxHeight: "80vh",
              overflow: "auto",
              padding: 24,
              boxShadow: "0 20px 60px rgba(0,0,0,0.3)",
            }}
          >
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
              <h2 style={{ fontSize: 18, fontWeight: 600, color: "var(--text-primary)", margin: 0 }}>
                Report a Bug
              </h2>
              <button
                onClick={() => setShowBugReport(false)}
                style={{
                  background: "transparent",
                  border: "none",
                  color: "var(--text-secondary)",
                  cursor: "pointer",
                  fontSize: 20,
                  lineHeight: 1,
                  padding: "4px 8px",
                }}
              >
                ×
              </button>
            </div>
            <BugReportForm darkMode={darkMode} />
          </div>
        </div>
      )}
    </div>
  );
}
