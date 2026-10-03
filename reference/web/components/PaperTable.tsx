"use client";

import { useState } from "react";

interface Paper {
  id: string;
  title: string;
  authors: string | null;
  year: number | null;
  venue: string | null;
  abstract: string | null;
  keywords: string | null;
  created_at: string;
  last_opened_at: string | null;
  ingestion_status?: 'pending' | 'downloading' | 'converting' | 'extracting' | 'failed' | null;
  ingestion_error?: string | null;
  rank?: number | null;
}

export interface ExternalResult {
  title: string;
  authors: string;
  year: number | null;
  pdfUrl: string;
}

type SortField = "title" | "authors" | "year" | "venue" | "created_at" | "last_opened_at";
type SortOrder = "asc" | "desc";

interface Props {
  papers: Paper[];
  sortField: SortField;
  sortOrder: SortOrder;
  onSort: (field: SortField) => void;
  onSelect: (paper: Paper) => void;
  onDelete?: (paperId: string) => void;
  selectedId?: string | null;
  compact?: boolean;
  loadingId?: string | null;
  searching?: boolean;
  mobile?: boolean;
  externalResults?: ExternalResult[];
  externalSearching?: boolean;
  onIngest?: (pdfUrl: string, title: string) => void;
  offlineIds?: Set<string>;
  onToggleOffline?: (paper: Paper) => void;
  offlineSaving?: string | null;
}

export type { Paper, SortField, SortOrder };

const statusConfig: Record<string, { label: string; color: string; bg: string; spinning: boolean }> = {
  pending:     { label: "Queued",      color: "#71717a", bg: "rgba(113,113,122,0.12)", spinning: false },
  downloading: { label: "Downloading", color: "#3b82f6", bg: "rgba(59,130,246,0.12)",  spinning: true },
  converting:  { label: "Converting",  color: "#8b5cf6", bg: "rgba(139,92,246,0.12)",  spinning: true },
  extracting:  { label: "Extracting",  color: "#8b5cf6", bg: "rgba(139,92,246,0.12)",  spinning: true },
  failed:      { label: "Failed",      color: "#ef4444", bg: "rgba(239,68,68,0.12)",   spinning: false },
};

function StatusBadge({ status }: { status: string }) {
  const cfg = statusConfig[status] || statusConfig.pending;
  return (
    <span style={{
      display: "inline-flex",
      alignItems: "center",
      gap: "5px",
      fontSize: "11px",
      fontWeight: 600,
      color: cfg.color,
      background: cfg.bg,
      padding: "2px 8px",
      borderRadius: "9999px",
      letterSpacing: "0.02em",
    }}>
      {cfg.spinning && <span className="spinner" style={{
        width: "10px",
        height: "10px",
        border: `2px solid ${cfg.bg}`,
        borderTop: `2px solid ${cfg.color}`,
        borderRadius: "50%",
      }} />}
      {cfg.label}
    </span>
  );
}

function RelevanceBadge({ rank }: { rank: number }) {
  // rank is typically 0 to ~0.6 from ts_rank; normalize to percentage
  const pct = Math.min(Math.round(rank * 100 / 0.6), 100);
  const color = pct >= 60 ? "#22c55e" : pct >= 30 ? "#eab308" : "#71717a";
  const bg = pct >= 60 ? "rgba(34,197,94,0.12)" : pct >= 30 ? "rgba(234,179,8,0.12)" : "rgba(113,113,122,0.08)";
  return (
    <span style={{
      fontSize: "11px",
      fontWeight: 600,
      color,
      background: bg,
      padding: "2px 8px",
      borderRadius: "9999px",
      letterSpacing: "0.02em",
    }}>
      {pct > 0 ? `${pct}%` : "\u2014"}
    </span>
  );
}

function KeywordChips({ keywords }: { keywords: string | null }) {
  if (!keywords) return null;
  const items = keywords.split(", ").filter(Boolean).slice(0, 5);
  if (items.length === 0) return null;
  return (
    <div style={{ display: "flex", flexWrap: "wrap", gap: "4px", marginTop: "4px" }}>
      {items.map((kw) => (
        <span
          key={kw}
          style={{
            fontSize: "10px",
            fontWeight: 500,
            color: "var(--text-secondary)",
            background: "var(--bg-secondary)",
            border: "1px solid var(--border)",
            padding: "1px 6px",
            borderRadius: "9999px",
            whiteSpace: "nowrap",
          }}
        >
          {kw}
        </span>
      ))}
    </div>
  );
}

export default function PaperTable({
  papers,
  sortField,
  sortOrder,
  onSort,
  onSelect,
  onDelete,
  selectedId,
  compact,
  loadingId,
  searching,
  mobile,
  externalResults,
  externalSearching,
  onIngest,
  offlineIds,
  onToggleOffline,
  offlineSaving,
}: Props) {
  const [confirmingDeleteId, setConfirmingDeleteId] = useState<string | null>(null);
  const [ingestingUrl, setIngestingUrl] = useState<string | null>(null);

  // ─── External results card list ────────────────────────────
  if (externalResults !== undefined) {
    if (externalSearching) {
      return (
        <div style={{ padding: "2rem", textAlign: "center", color: "var(--text-secondary)" }}>
          <span className="spinner" style={{
            display: "inline-block",
            width: "16px",
            height: "16px",
            border: "2px solid var(--border)",
            borderTop: "2px solid var(--accent)",
            borderRadius: "50%",
            marginRight: "8px",
            verticalAlign: "middle",
          }} />
          Searching arXiv &amp; Semantic Scholar...
        </div>
      );
    }

    if (externalResults.length === 0) {
      return (
        <div style={{ padding: "2rem", textAlign: "center", color: "var(--text-secondary)" }}>
          No external results found
        </div>
      );
    }

    return (
      <div>
        {externalResults.map((r, i) => (
          <div
            key={`${r.pdfUrl}-${i}`}
            className="paper-card"
          >
            <div className="paper-card-title">{r.title}</div>
            <div className="paper-card-meta">
              <span>{r.authors?.split(",")[0]?.trim() || "\u2014"}</span>
              <span>{r.year || "\u2014"}</span>
              <span className="status-badge">
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    if (onIngest) {
                      setIngestingUrl(r.pdfUrl);
                      onIngest(r.pdfUrl, r.title);
                    }
                  }}
                  disabled={ingestingUrl === r.pdfUrl}
                  style={{
                    background: ingestingUrl === r.pdfUrl ? "var(--bg-secondary)" : "var(--accent)",
                    color: ingestingUrl === r.pdfUrl ? "var(--text-secondary)" : "#fff",
                    border: "none",
                    borderRadius: "6px",
                    padding: "4px 12px",
                    fontSize: "12px",
                    fontWeight: 600,
                    cursor: ingestingUrl === r.pdfUrl ? "default" : "pointer",
                    transition: "all 0.15s ease",
                  }}
                >
                  {ingestingUrl === r.pdfUrl ? "Queued" : "Ingest"}
                </button>
              </span>
            </div>
          </div>
        ))}
      </div>
    );
  }

  // ─── Mobile card layout ─────────────────────────────────────
  if (mobile) {
    return (
      <div>
        {papers.length === 0 && (
          <div style={{ padding: "2rem", textAlign: "center", color: "var(--text-secondary)" }}>
            No papers found
          </div>
        )}
        {papers.map((p) => {
          const isQueued = !!p.ingestion_status && p.ingestion_status !== "failed";
          return (
            <div
              key={p.id}
              className={`paper-card ${selectedId === p.id ? "selected" : ""} ${isQueued ? "queued" : ""}`}
              onClick={() => { if (!isQueued) onSelect(p); }}
              style={{ position: "relative" }}
            >
              <div className="paper-card-title">
                {loadingId === p.id ? "Loading..." : p.title || "Untitled"}
              </div>
              <KeywordChips keywords={p.keywords} />
              <div className="paper-card-meta">
                {searching && <RelevanceBadge rank={p.rank || 0} />}
                <span>{p.authors?.split(",")[0]?.trim() || "\u2014"}</span>
                <span>{p.year || "\u2014"}</span>
                <span className="status-badge">
                  {p.ingestion_status ? (
                    <StatusBadge status={p.ingestion_status} />
                  ) : (
                    <span style={{ color: "#22c55e", fontSize: "12px" }}>Ingested</span>
                  )}
                </span>
                {offlineIds?.has(p.id) && (
                  <span style={{ color: "var(--accent)", fontSize: "11px", fontWeight: 600 }} title="Available offline">
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style={{ verticalAlign: "-1px" }}>
                      <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/>
                    </svg>
                    {" "}Offline
                  </span>
                )}
              </div>
              {onToggleOffline && !p.ingestion_status && (
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    onToggleOffline(p);
                  }}
                  disabled={offlineSaving === p.id}
                  style={{
                    position: "absolute",
                    top: 8,
                    right: onDelete ? 48 : 8,
                    background: offlineIds?.has(p.id) ? "var(--accent-muted)" : "var(--bg-secondary)",
                    border: offlineIds?.has(p.id) ? "1px solid var(--accent)" : "1px solid var(--border)",
                    borderRadius: "6px",
                    padding: "4px 8px",
                    cursor: offlineSaving === p.id ? "wait" : "pointer",
                    color: offlineIds?.has(p.id) ? "var(--accent)" : "var(--text-secondary)",
                    fontSize: "11px",
                    display: "flex",
                    alignItems: "center",
                    gap: 4,
                    zIndex: 2,
                  }}
                  title={offlineIds?.has(p.id) ? "Remove offline copy" : "Save for offline reading"}
                >
                  {offlineSaving === p.id ? (
                    <span className="spinner" style={{ width: 12, height: 12, border: "2px solid var(--border)", borderTop: "2px solid var(--accent)", borderRadius: "50%" }} />
                  ) : offlineIds?.has(p.id) ? (
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                      <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
                      <polyline points="7 10 12 15 17 10" />
                      <line x1="12" y1="15" x2="12" y2="3" />
                    </svg>
                  ) : (
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                      <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
                      <polyline points="7 10 12 15 17 10" />
                      <line x1="12" y1="15" x2="12" y2="3" />
                    </svg>
                  )}
                </button>
              )}
              {onDelete && (
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    if (confirmingDeleteId === p.id) {
                      onDelete(p.id);
                      setConfirmingDeleteId(null);
                    } else {
                      setConfirmingDeleteId(p.id);
                      setTimeout(() => setConfirmingDeleteId((cur) => cur === p.id ? null : cur), 3000);
                    }
                  }}
                  style={{
                    position: "absolute",
                    top: 8,
                    right: 8,
                    background: confirmingDeleteId === p.id ? "#ef4444" : "var(--bg-secondary)",
                    border: confirmingDeleteId === p.id ? "1px solid #ef4444" : "1px solid var(--border)",
                    borderRadius: "6px",
                    padding: "4px 8px",
                    cursor: "pointer",
                    color: confirmingDeleteId === p.id ? "#fff" : "var(--text-secondary)",
                    fontSize: "11px",
                    display: "flex",
                    alignItems: "center",
                    gap: 4,
                    zIndex: 2,
                  }}
                >
                  {confirmingDeleteId === p.id ? (
                    "Confirm"
                  ) : (
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                      <polyline points="3 6 5 6 21 6" />
                      <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
                    </svg>
                  )}
                </button>
              )}
            </div>
          );
        })}
      </div>
    );
  }

  // ─── Desktop table layout ───────────────────────────────────
  const arrow = (field: SortField) =>
    sortField === field ? (sortOrder === "asc" ? " \u25B2" : " \u25BC") : "";

  const columns: { field: SortField | "status" | "rank"; label: string; hide?: boolean; sortable?: boolean }[] = [
    ...(searching ? [{ field: "rank" as const, label: "Match", sortable: false }] : []),
    { field: "title", label: "Title" },
    { field: "authors", label: "Authors", hide: compact },
    { field: "year", label: "Year" },
    { field: "created_at", label: "Added", hide: compact },
    { field: "last_opened_at", label: "Last Opened" },
    { field: "status", label: "Status", sortable: false },
  ];

  const visibleCols = columns.filter((c) => !c.hide);

  return (
    <div style={{ overflowX: "auto" }}>
      <table
        style={{
          width: "100%",
          borderCollapse: "collapse",
          fontSize: "14px",
        }}
      >
        <thead>
          <tr>
            {visibleCols.map((col) => (
              <th
                key={col.field}
                onClick={() => col.sortable !== false && col.field !== "status" ? onSort(col.field as SortField) : undefined}
                style={{
                  padding: "10px 12px",
                  textAlign: "left",
                  borderBottom: "1px solid var(--border)",
                  color: "var(--text-secondary)",
                  fontWeight: 500,
                  fontSize: "12px",
                  textTransform: "uppercase",
                  letterSpacing: "0.05em",
                  cursor: col.sortable !== false ? "pointer" : "default",
                  userSelect: "none",
                  whiteSpace: "nowrap",
                }}
              >
                {col.label}
                {col.sortable !== false && col.field !== "status" ? arrow(col.field as SortField) : ""}
              </th>
            ))}
            {onToggleOffline && <th style={{ width: 32, borderBottom: "1px solid var(--border)" }} />}
            {onDelete && <th style={{ width: 32, borderBottom: "1px solid var(--border)" }} />}
          </tr>
        </thead>
        <tbody>
          {papers.length === 0 && (
            <tr>
              <td
                colSpan={visibleCols.length + (onToggleOffline ? 1 : 0) + (onDelete ? 1 : 0)}
                style={{
                  padding: "2rem",
                  textAlign: "center",
                  color: "var(--text-secondary)",
                }}
              >
                No papers found
              </td>
            </tr>
          )}
          {papers.map((p) => {
            const isQueued = !!p.ingestion_status && p.ingestion_status !== 'failed';
            return (
            <tr
              key={p.id}
              onClick={() => { if (!isQueued) onSelect(p); }}
              title={p.ingestion_status === 'failed' ? (p.ingestion_error || 'Ingestion failed') : undefined}
              style={{
                cursor: isQueued ? "not-allowed" : loadingId === p.id ? "wait" : "pointer",
                opacity: isQueued ? 0.6 : 1,
                background:
                  selectedId === p.id
                    ? "var(--accent-muted)"
                    : "transparent",
                borderBottom: "1px solid var(--border)",
                transition: "background 0.15s",
              }}
              onMouseEnter={(e) => {
                if (selectedId !== p.id && !isQueued) {
                  (e.currentTarget as HTMLTableRowElement).style.background =
                    "var(--bg-hover)";
                }
                const delBtn = e.currentTarget.querySelector(".row-delete-btn") as HTMLElement;
                if (delBtn) delBtn.style.opacity = "0.4";
              }}
              onMouseLeave={(e) => {
                (e.currentTarget as HTMLTableRowElement).style.background =
                  selectedId === p.id
                    ? "var(--accent-muted)"
                    : "transparent";
                const delBtn = e.currentTarget.querySelector(".row-delete-btn") as HTMLElement;
                if (delBtn) delBtn.style.opacity = "0";
                if (confirmingDeleteId === p.id) setConfirmingDeleteId(null);
              }}
            >
              {searching && (
                <td style={{ padding: "10px 12px", whiteSpace: "nowrap" }}>
                  <RelevanceBadge rank={p.rank || 0} />
                </td>
              )}
              <td
                style={{
                  padding: "10px 12px",
                  maxWidth: compact ? "200px" : "350px",
                  color: "var(--text-primary)",
                  fontWeight: 500,
                }}
              >
                <div style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                  {loadingId === p.id ? "Loading..." : p.title || "Untitled"}
                </div>
                <KeywordChips keywords={p.keywords} />
              </td>
              {!compact && (
                <td
                  style={{
                    padding: "10px 12px",
                    maxWidth: "200px",
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    whiteSpace: "nowrap",
                    color: "var(--text-secondary)",
                  }}
                >
                  {p.authors || "\u2014"}
                </td>
              )}
              <td
                style={{
                  padding: "10px 12px",
                  color: "var(--text-secondary)",
                  whiteSpace: "nowrap",
                }}
              >
                {p.year || "\u2014"}
              </td>
              {!compact && (
                <td
                  style={{
                    padding: "10px 12px",
                    color: "var(--text-secondary)",
                    whiteSpace: "nowrap",
                    fontSize: "13px",
                  }}
                >
                  {new Date(p.created_at).toLocaleDateString()}
                </td>
              )}
              <td
                style={{
                  padding: "10px 12px",
                  color: "var(--text-secondary)",
                  whiteSpace: "nowrap",
                  fontSize: "13px",
                }}
              >
                {p.last_opened_at
                  ? new Date(p.last_opened_at).toLocaleDateString()
                  : "\u2014"}
              </td>
              <td
                style={{
                  padding: "10px 12px",
                  whiteSpace: "nowrap",
                }}
              >
                <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
                  {p.ingestion_status ? (
                    <StatusBadge status={p.ingestion_status} />
                  ) : (
                    <span style={{ color: "#22c55e", fontSize: "13px" }}>Ingested</span>
                  )}
                  {offlineIds?.has(p.id) && (
                    <span title="Available offline" style={{ color: "var(--accent)", display: "inline-flex", alignItems: "center" }}>
                      <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
                        <polyline points="7 10 12 15 17 10" />
                        <line x1="12" y1="15" x2="12" y2="3" />
                      </svg>
                    </span>
                  )}
                </span>
              </td>
              {onToggleOffline && (
                <td
                  style={{ padding: "4px 8px", width: 32, textAlign: "center" }}
                  onClick={(e) => e.stopPropagation()}
                >
                  {!p.ingestion_status && (
                    <button
                      onClick={() => onToggleOffline(p)}
                      disabled={offlineSaving === p.id}
                      className="row-delete-btn"
                      title={offlineIds?.has(p.id) ? "Remove offline copy" : "Save for offline"}
                      style={{
                        background: "transparent",
                        border: "none",
                        cursor: offlineSaving === p.id ? "wait" : "pointer",
                        padding: 2,
                        color: offlineIds?.has(p.id) ? "var(--accent)" : "var(--text-secondary)",
                        opacity: offlineIds?.has(p.id) ? 1 : 0,
                        transition: "opacity 0.15s",
                        display: "flex",
                        alignItems: "center",
                      }}
                    >
                      {offlineSaving === p.id ? (
                        <span className="spinner" style={{ width: 14, height: 14, border: "2px solid var(--border)", borderTop: "2px solid var(--accent)", borderRadius: "50%" }} />
                      ) : (
                        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                          <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
                          <polyline points="7 10 12 15 17 10" />
                          <line x1="12" y1="15" x2="12" y2="3" />
                        </svg>
                      )}
                    </button>
                  )}
                </td>
              )}
              {onDelete && (
                <td
                  style={{ padding: "4px 8px", width: 32, textAlign: "center" }}
                  onClick={(e) => e.stopPropagation()}
                >
                  {confirmingDeleteId === p.id ? (
                    <button
                      onClick={() => { onDelete(p.id); setConfirmingDeleteId(null); }}
                      onMouseLeave={() => setConfirmingDeleteId(null)}
                      title="Click again to confirm delete"
                      style={{
                        background: "transparent",
                        border: "none",
                        cursor: "pointer",
                        padding: 2,
                        color: "#ef4444",
                        opacity: 1,
                        display: "flex",
                        alignItems: "center",
                      }}
                    >
                      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <polyline points="3 6 5 6 21 6" />
                        <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6" />
                        <path d="M10 11v6" /><path d="M14 11v6" />
                        <path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2" />
                      </svg>
                    </button>
                  ) : (
                    <button
                      onClick={() => setConfirmingDeleteId(p.id)}
                      className="row-delete-btn"
                      title="Delete paper"
                      style={{
                        background: "transparent",
                        border: "none",
                        cursor: "pointer",
                        padding: 2,
                        color: "var(--text-secondary)",
                        opacity: 0,
                        transition: "opacity 0.15s",
                        display: "flex",
                        alignItems: "center",
                      }}
                    >
                      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <polyline points="3 6 5 6 21 6" />
                        <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6" />
                        <path d="M10 11v6" /><path d="M14 11v6" />
                        <path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2" />
                      </svg>
                    </button>
                  )}
                </td>
              )}
            </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
