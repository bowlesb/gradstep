"use client";

import { useState, useEffect, useCallback } from "react";

interface DiagramItem {
  id: string;
  paper_id: string | null;
  chat_id: string | null;
  title: string;
  description: string | null;
  created_at: string;
  paper_title: string | null;
  chat_title: string | null;
}

interface Props {
  onClose: () => void;
  onSelectDiagram?: (diagram: DiagramItem) => void;
  mobile?: boolean;
}

export type { DiagramItem };

function relativeTime(dateStr: string): string {
  const now = Date.now();
  const then = new Date(dateStr).getTime();
  const diffMs = now - then;
  const diffMin = Math.floor(diffMs / 60000);
  if (diffMin < 1) return "just now";
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHr = Math.floor(diffMin / 60);
  if (diffHr < 24) return `${diffHr}h ago`;
  const diffDay = Math.floor(diffHr / 24);
  if (diffDay < 7) return `${diffDay}d ago`;
  return new Date(dateStr).toLocaleDateString();
}

export default function AllDiagramsView({ onClose, onSelectDiagram, mobile }: Props) {
  const [diagrams, setDiagrams] = useState<DiagramItem[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === "Escape") { onClose(); e.preventDefault(); }
    }
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onClose]);

  const fetchDiagrams = useCallback(async () => {
    try {
      const res = await fetch("/api/diagrams/all");
      const data = await res.json();
      setDiagrams(data.diagrams || []);
    } catch {
      /* ignore */
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchDiagrams();
  }, [fetchDiagrams]);

  function openDiagram(id: string) {
    window.open(`/api/diagrams/${id}`, "_blank");
  }

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
        style={{
          padding: mobile ? "12px 16px" : "16px 24px",
          borderBottom: "1px solid var(--border)",
          display: "flex",
          alignItems: "center",
          gap: "12px",
          flexShrink: 0,
        }}
      >
        <button
          onClick={onClose}
          style={{
            background: "transparent",
            border: "none",
            cursor: "pointer",
            color: "var(--text-secondary)",
            display: "flex",
            alignItems: "center",
            padding: "4px",
          }}
        >
          <svg
            width="20"
            height="20"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <polyline points="15 18 9 12 15 6" />
          </svg>
        </button>
        <h2
          style={{
            margin: 0,
            fontSize: mobile ? "18px" : "16px",
            fontWeight: 600,
            color: "var(--text-primary)",
          }}
        >
          Diagrams
        </h2>
        <span
          style={{
            fontSize: "13px",
            color: "var(--text-secondary)",
          }}
        >
          {!loading && `${diagrams.length} diagram${diagrams.length !== 1 ? "s" : ""}`}
        </span>
      </div>

      {/* Content */}
      <div style={{ flex: 1, overflowY: "auto" }}>
        {loading ? (
          <div
            style={{
              textAlign: "center",
              padding: "3rem",
              color: "var(--text-secondary)",
              fontSize: "14px",
            }}
          >
            Loading diagrams...
          </div>
        ) : diagrams.length === 0 ? (
          <div
            style={{
              textAlign: "center",
              padding: "3rem",
              color: "var(--text-secondary)",
              fontSize: "14px",
            }}
          >
            No diagrams yet. Ask the AI to create a diagram or visual explanation in chat.
          </div>
        ) : mobile ? (
          /* Mobile: card layout */
          <div style={{ padding: "8px" }}>
            {diagrams.map((d) => (
              <div
                key={d.id}
                style={{
                  padding: "12px 14px",
                  margin: "4px 0",
                  borderRadius: "8px",
                  border: "1px solid var(--border)",
                  background: "var(--bg-primary)",
                }}
              >
                <div
                  style={{
                    display: "flex",
                    justifyContent: "space-between",
                    alignItems: "flex-start",
                    gap: "8px",
                  }}
                >
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div
                      style={{
                        fontWeight: 500,
                        fontSize: "14px",
                        color: "var(--text-primary)",
                        overflow: "hidden",
                        textOverflow: "ellipsis",
                        whiteSpace: "nowrap",
                      }}
                    >
                      {d.title}
                    </div>
                    {d.description && (
                      <div
                        style={{
                          fontSize: "12px",
                          color: "var(--text-secondary)",
                          marginTop: "3px",
                          overflow: "hidden",
                          textOverflow: "ellipsis",
                          whiteSpace: "nowrap",
                        }}
                      >
                        {d.description}
                      </div>
                    )}
                    {d.paper_title && (
                      <div
                        style={{
                          fontSize: "11px",
                          color: "var(--accent)",
                          marginTop: "3px",
                          overflow: "hidden",
                          textOverflow: "ellipsis",
                          whiteSpace: "nowrap",
                        }}
                      >
                        {d.paper_title}
                      </div>
                    )}
                  </div>
                  <span style={{ fontSize: "11px", color: "var(--text-secondary)", flexShrink: 0 }}>
                    {relativeTime(d.created_at)}
                  </span>
                </div>
                <div style={{ display: "flex", gap: "8px", marginTop: "8px" }}>
                  <button
                    onClick={() => openDiagram(d.id)}
                    style={{
                      flex: 1,
                      padding: "6px 0",
                      fontSize: "12px",
                      fontWeight: 500,
                      background: "var(--accent)",
                      color: "#fff",
                      border: "none",
                      borderRadius: "6px",
                      cursor: "pointer",
                    }}
                  >
                    View Diagram
                  </button>
                  {(d.paper_id || d.chat_id) && onSelectDiagram && (
                    <button
                      onClick={() => onSelectDiagram(d)}
                      style={{
                        flex: 1,
                        padding: "6px 0",
                        fontSize: "12px",
                        fontWeight: 500,
                        background: "transparent",
                        color: "var(--text-primary)",
                        border: "1px solid var(--border)",
                        borderRadius: "6px",
                        cursor: "pointer",
                      }}
                    >
                      {d.paper_id ? "Open Paper + Chat" : "Open Chat"}
                    </button>
                  )}
                </div>
              </div>
            ))}
          </div>
        ) : (
          /* Desktop/tablet: table layout */
          <table
            style={{
              width: "100%",
              borderCollapse: "collapse",
              fontSize: "13px",
            }}
          >
            <thead>
              <tr
                style={{
                  borderBottom: "1px solid var(--border)",
                  color: "var(--text-secondary)",
                  fontSize: "11px",
                  fontWeight: 600,
                  textTransform: "uppercase",
                  letterSpacing: "0.5px",
                }}
              >
                <th style={{ textAlign: "left", padding: "10px 16px" }}>Title</th>
                <th style={{ textAlign: "left", padding: "10px 12px" }}>Description</th>
                <th style={{ textAlign: "left", padding: "10px 12px" }}>Paper</th>
                <th style={{ textAlign: "left", padding: "10px 12px" }}>Chat</th>
                <th style={{ textAlign: "right", padding: "10px 12px", width: "90px" }}>Created</th>
                <th style={{ textAlign: "center", padding: "10px 16px", width: "60px" }}></th>
              </tr>
            </thead>
            <tbody>
              {diagrams.map((d) => (
                <tr
                  key={d.id}
                  onClick={() => onSelectDiagram && (d.paper_id || d.chat_id) ? onSelectDiagram(d) : openDiagram(d.id)}
                  style={{
                    borderBottom: "1px solid var(--border)",
                    cursor: "pointer",
                    transition: "background 0.1s",
                  }}
                  onMouseEnter={(e) => {
                    e.currentTarget.style.background = "var(--bg-hover)";
                  }}
                  onMouseLeave={(e) => {
                    e.currentTarget.style.background = "transparent";
                  }}
                >
                  <td
                    style={{
                      padding: "10px 16px",
                      color: "var(--text-primary)",
                      fontWeight: 500,
                      maxWidth: "200px",
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {d.title}
                  </td>
                  <td
                    style={{
                      padding: "10px 12px",
                      color: "var(--text-secondary)",
                      maxWidth: "250px",
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {d.description || "\u2014"}
                  </td>
                  <td
                    style={{
                      padding: "10px 12px",
                      color: d.paper_title ? "var(--accent)" : "var(--text-secondary)",
                      maxWidth: "180px",
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {d.paper_title || "\u2014"}
                  </td>
                  <td
                    style={{
                      padding: "10px 12px",
                      color: d.chat_title ? "var(--accent)" : "var(--text-secondary)",
                      maxWidth: "150px",
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {d.chat_title || "\u2014"}
                  </td>
                  <td
                    style={{
                      padding: "10px 12px",
                      textAlign: "right",
                      color: "var(--text-secondary)",
                    }}
                  >
                    {relativeTime(d.created_at)}
                  </td>
                  <td style={{ padding: "10px 16px", textAlign: "center" }}>
                    <button
                      onClick={(e) => { e.stopPropagation(); openDiagram(d.id); }}
                      title="View diagram"
                      style={{
                        background: "transparent",
                        border: "1px solid var(--border)",
                        borderRadius: "6px",
                        padding: "3px 8px",
                        fontSize: "11px",
                        color: "var(--accent)",
                        cursor: "pointer",
                        whiteSpace: "nowrap",
                      }}
                    >
                      View
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
