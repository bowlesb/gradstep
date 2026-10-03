"use client";

import { useState, useEffect, useCallback } from "react";

interface AllChat {
  id: string;
  paper_id: string | null;
  title: string | null;
  paper_title: string | null;
  highlight_text: string | null;
  message_count: number;
  created_at: string;
  updated_at: string;
}

interface Props {
  onSelectChat: (chat: AllChat) => void;
  onClose: () => void;
  onNewGeneralChat?: () => void;
  mobile?: boolean;
}

export type { AllChat };

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

export default function AllChatsView({ onSelectChat, onClose, onNewGeneralChat, mobile }: Props) {
  const [chats, setChats] = useState<AllChat[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === "Escape") { onClose(); e.preventDefault(); }
    }
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onClose]);

  const fetchChats = useCallback(async () => {
    try {
      const res = await fetch("/api/chats/all");
      const data = await res.json();
      setChats(data.chats || []);
    } catch {
      /* ignore */
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchChats();
  }, [fetchChats]);

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
          All Chats
        </h2>
        <span
          style={{
            fontSize: "13px",
            color: "var(--text-secondary)",
          }}
        >
          {!loading && `${chats.length} chat${chats.length !== 1 ? "s" : ""}`}
        </span>
        <span style={{ flex: 1 }} />
        {onNewGeneralChat && (
          <button
            onClick={onNewGeneralChat}
            style={{
              background: "var(--accent)",
              color: "#fff",
              border: "none",
              borderRadius: "6px",
              padding: "6px 14px",
              fontSize: "13px",
              fontWeight: 500,
              cursor: "pointer",
              display: "flex",
              alignItems: "center",
              gap: "6px",
            }}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
              <line x1="12" y1="5" x2="12" y2="19" />
              <line x1="5" y1="12" x2="19" y2="12" />
            </svg>
            New Chat
          </button>
        )}
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
            Loading chats...
          </div>
        ) : chats.length === 0 ? (
          <div
            style={{
              textAlign: "center",
              padding: "3rem",
              color: "var(--text-secondary)",
              fontSize: "14px",
            }}
          >
            No chats yet
          </div>
        ) : mobile ? (
          /* Mobile: card layout */
          <div style={{ padding: "8px" }}>
            {chats.map((chat) => (
              <div
                key={chat.id}
                onClick={() => onSelectChat(chat)}
                style={{
                  padding: "12px 14px",
                  margin: "4px 0",
                  borderRadius: "8px",
                  cursor: "pointer",
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
                      {chat.title || "Untitled Chat"}
                    </div>
                    {chat.paper_title && (
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
                        {chat.paper_title}
                      </div>
                    )}
                  </div>
                  <div style={{ display: "flex", flexDirection: "column", alignItems: "flex-end", gap: "4px", flexShrink: 0 }}>
                    <span
                      style={{
                        fontSize: "10px",
                        fontWeight: 500,
                        padding: "2px 6px",
                        borderRadius: "4px",
                        background: chat.paper_id
                          ? "var(--accent)"
                          : "var(--bg-secondary)",
                        color: chat.paper_id ? "#fff" : "var(--text-secondary)",
                        border: chat.paper_id ? "none" : "1px solid var(--border)",
                      }}
                    >
                      {chat.paper_id ? "Paper" : "General"}
                    </span>
                    <span style={{ fontSize: "11px", color: "var(--text-secondary)" }}>
                      {relativeTime(chat.updated_at)}
                    </span>
                  </div>
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
                <th style={{ textAlign: "left", padding: "10px 16px" }}>Paper</th>
                <th style={{ textAlign: "left", padding: "10px 12px" }}>Chat</th>
                <th style={{ textAlign: "center", padding: "10px 12px", width: "70px" }}>Type</th>
                <th style={{ textAlign: "right", padding: "10px 12px", width: "90px" }}>Started</th>
                <th style={{ textAlign: "right", padding: "10px 12px", width: "90px" }}>Last Active</th>
                <th style={{ textAlign: "right", padding: "10px 16px", width: "50px" }}>Msgs</th>
              </tr>
            </thead>
            <tbody>
              {chats.map((chat) => (
                <tr
                  key={chat.id}
                  onClick={() => onSelectChat(chat)}
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
                      color: "var(--text-secondary)",
                      maxWidth: "200px",
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {chat.paper_title || "\u2014"}
                  </td>
                  <td
                    style={{
                      padding: "10px 12px",
                      color: "var(--text-primary)",
                      fontWeight: 500,
                      maxWidth: "250px",
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {chat.title || "Untitled Chat"}
                  </td>
                  <td style={{ padding: "10px 12px", textAlign: "center" }}>
                    <span
                      style={{
                        fontSize: "10px",
                        fontWeight: 500,
                        padding: "2px 6px",
                        borderRadius: "4px",
                        background: chat.paper_id
                          ? "var(--accent)"
                          : "var(--bg-secondary)",
                        color: chat.paper_id ? "#fff" : "var(--text-secondary)",
                        border: chat.paper_id ? "none" : "1px solid var(--border)",
                      }}
                    >
                      {chat.paper_id ? "Paper" : "General"}
                    </span>
                  </td>
                  <td
                    style={{
                      padding: "10px 12px",
                      textAlign: "right",
                      color: "var(--text-secondary)",
                    }}
                  >
                    {relativeTime(chat.created_at)}
                  </td>
                  <td
                    style={{
                      padding: "10px 12px",
                      textAlign: "right",
                      color: "var(--text-secondary)",
                    }}
                  >
                    {relativeTime(chat.updated_at)}
                  </td>
                  <td
                    style={{
                      padding: "10px 16px",
                      textAlign: "right",
                      color: "var(--text-secondary)",
                    }}
                  >
                    {chat.message_count}
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
