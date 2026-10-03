"use client";

import { useState, useCallback } from "react";

export interface TocEntry {
  level: number;
  id: string;
  title: string;
}

interface Props {
  entries: TocEntry[];
  onNavigate: (headingId: string) => void;
  darkMode: boolean;
  mobile?: boolean;
}

export default function TableOfContents({ entries, onNavigate, darkMode, mobile }: Props) {
  const [collapsed, setCollapsed] = useState(true);

  const handleClick = useCallback(
    (id: string) => {
      onNavigate(id);
    },
    [onNavigate]
  );

  if (entries.length === 0) return null;

  // Find minimum heading level to normalize indentation
  const minLevel = Math.min(...entries.map((e) => e.level));

  if (collapsed) {
    return (
      <button
        onClick={() => setCollapsed(false)}
        title="Show table of contents"
        style={{
          position: "absolute",
          top: mobile ? 8 : 12,
          left: mobile ? 8 : 12,
          zIndex: 15,
          background: darkMode ? "rgba(30,30,30,0.9)" : "rgba(255,255,255,0.9)",
          border: `1px solid ${darkMode ? "#3f3f46" : "#d4d4d8"}`,
          borderRadius: "10px",
          padding: "6px 10px",
          cursor: "pointer",
          color: darkMode ? "#e4e4e7" : "#18181b",
          boxShadow: "0 2px 8px rgba(0,0,0,0.15)",
          backdropFilter: "blur(8px)",
          WebkitBackdropFilter: "blur(8px)",
          display: "flex",
          alignItems: "center",
          gap: 4,
          fontSize: "12px",
          fontWeight: 500,
        }}
      >
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <line x1="3" y1="6" x2="21" y2="6" />
          <line x1="3" y1="12" x2="15" y2="12" />
          <line x1="3" y1="18" x2="18" y2="18" />
        </svg>
        TOC
      </button>
    );
  }

  return (
    <>
    {/* Invisible backdrop to catch clicks outside the panel (including on the iframe) */}
    <div
      onClick={() => setCollapsed(true)}
      style={{
        position: "absolute",
        inset: 0,
        zIndex: 14,
      }}
    />
    <div
      style={{
        position: "absolute",
        top: mobile ? 8 : 12,
        left: mobile ? 8 : 12,
        zIndex: 15,
        background: darkMode ? "rgba(20,20,20,0.95)" : "rgba(255,255,255,0.95)",
        border: `1px solid ${darkMode ? "#3f3f46" : "#d4d4d8"}`,
        borderRadius: "12px",
        boxShadow: "0 4px 20px rgba(0,0,0,0.2)",
        backdropFilter: "blur(12px)",
        WebkitBackdropFilter: "blur(12px)",
        maxHeight: mobile ? "60vh" : "70vh",
        maxWidth: mobile ? "85vw" : "320px",
        minWidth: mobile ? "200px" : "220px",
        display: "flex",
        flexDirection: "column",
        overflow: "hidden",
      }}
    >
      {/* Header */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          padding: "8px 12px",
          borderBottom: `1px solid ${darkMode ? "#27272a" : "#e4e4e7"}`,
          flexShrink: 0,
        }}
      >
        <span
          style={{
            fontSize: "12px",
            fontWeight: 600,
            color: darkMode ? "#a1a1aa" : "#71717a",
            textTransform: "uppercase",
            letterSpacing: "0.5px",
          }}
        >
          Contents
        </span>
        <button
          onClick={() => setCollapsed(true)}
          style={{
            background: "transparent",
            border: "none",
            cursor: "pointer",
            color: darkMode ? "#71717a" : "#a1a1aa",
            padding: "2px",
            display: "flex",
            alignItems: "center",
          }}
          title="Collapse TOC"
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <line x1="18" y1="6" x2="6" y2="18" />
            <line x1="6" y1="6" x2="18" y2="18" />
          </svg>
        </button>
      </div>

      {/* Entries */}
      <div
        style={{
          overflowY: "auto",
          padding: "6px 0",
          flex: 1,
        }}
      >
        {entries.map((entry, i) => {
          const indent = (entry.level - minLevel) * 14;
          return (
            <button
              key={`${entry.id}-${i}`}
              onClick={() => handleClick(entry.id)}
              style={{
                display: "block",
                width: "100%",
                textAlign: "left",
                background: "transparent",
                border: "none",
                cursor: "pointer",
                padding: `4px 12px 4px ${12 + indent}px`,
                fontSize: entry.level <= minLevel ? "13px" : "12px",
                fontWeight: entry.level <= minLevel ? 600 : 400,
                color: darkMode ? "#d4d4d8" : "#3f3f46",
                lineHeight: 1.4,
                transition: "background 0.1s",
                whiteSpace: "nowrap",
                overflow: "hidden",
                textOverflow: "ellipsis",
              }}
              onMouseEnter={(e) => {
                e.currentTarget.style.background = darkMode ? "rgba(99,102,241,0.15)" : "rgba(99,102,241,0.08)";
              }}
              onMouseLeave={(e) => {
                e.currentTarget.style.background = "transparent";
              }}
              title={entry.title}
            >
              {entry.title}
            </button>
          );
        })}
      </div>
    </div>
    </>
  );
}
