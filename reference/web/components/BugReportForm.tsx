"use client";

import { useState, useRef, useCallback } from "react";

interface BugReport {
  id: string;
  title: string;
  description: string;
  screenshots: string[];
  status: string;
  created_at: string;
}

function makeTitle(desc: string): string {
  // Use first line or first 80 chars as auto-title
  const firstLine = desc.split(/[.\n]/)[0]?.trim() || desc.trim();
  return firstLine.slice(0, 80);
}

interface Props {
  darkMode?: boolean;
}

export default function BugReportForm({ darkMode }: Props) {
  const [description, setDescription] = useState("");
  const [screenshots, setScreenshots] = useState<string[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showHistory, setShowHistory] = useState(false);
  const [history, setHistory] = useState<BugReport[]>([]);
  const [loadingHistory, setLoadingHistory] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const handleScreenshotUpload = useCallback((files: FileList | null) => {
    if (!files) return;
    const remaining = 5 - screenshots.length;
    const toProcess = Array.from(files).slice(0, remaining);

    for (const file of toProcess) {
      if (!file.type.startsWith("image/")) continue;
      if (file.size > 5 * 1024 * 1024) continue; // 5MB limit

      const reader = new FileReader();
      reader.onload = (e) => {
        const dataUrl = e.target?.result as string;
        setScreenshots((prev) => {
          if (prev.length >= 5) return prev;
          return [...prev, dataUrl];
        });
      };
      reader.readAsDataURL(file);
    }
  }, [screenshots.length]);

  const removeScreenshot = useCallback((index: number) => {
    setScreenshots((prev) => prev.filter((_, i) => i !== index));
  }, []);

  const handleSubmit = async () => {
    if (!description.trim()) {
      setError("Please describe the issue.");
      return;
    }

    setSubmitting(true);
    setError(null);

    try {
      const res = await fetch("/api/bug-reports", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          title: makeTitle(description),
          description: description.trim(),
          screenshots,
          pageUrl: window.location.href,
          userAgent: navigator.userAgent,
        }),
      });

      if (!res.ok) throw new Error("Failed to submit");

      setSubmitted(true);
      setDescription("");
      setScreenshots([]);

      // Auto-dismiss success after 3s
      setTimeout(() => setSubmitted(false), 3000);
    } catch {
      setError("Failed to submit bug report. Please try again.");
    } finally {
      setSubmitting(false);
    }
  };

  const loadHistory = async () => {
    if (showHistory) {
      setShowHistory(false);
      return;
    }
    setLoadingHistory(true);
    try {
      const res = await fetch("/api/bug-reports");
      if (res.ok) {
        const data = await res.json();
        setHistory(data);
      }
    } catch {
      // ignore
    } finally {
      setLoadingHistory(false);
      setShowHistory(true);
    }
  };

  const statusColor = (status: string) => {
    if (status === "resolved") return "#22c55e";
    if (status === "in_progress") return "#f59e0b";
    return "#ef4444";
  };

  const statusLabel = (status: string) => {
    if (status === "resolved") return "Resolved";
    if (status === "in_progress") return "In Progress";
    return "Open";
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      {submitted && (
        <div style={{
          padding: "10px 14px",
          background: darkMode ? "#14532d" : "#dcfce7",
          color: darkMode ? "#86efac" : "#166534",
          borderRadius: 8,
          fontSize: 13,
          fontWeight: 500,
        }}>
          Bug report submitted successfully!
        </div>
      )}

      {error && (
        <div style={{
          padding: "10px 14px",
          background: darkMode ? "#7f1d1d" : "#fef2f2",
          color: darkMode ? "#fca5a5" : "#991b1b",
          borderRadius: 8,
          fontSize: 13,
        }}>
          {error}
        </div>
      )}

      <textarea
        placeholder="Describe the issue — what happened, what you expected..."
        value={description}
        onChange={(e) => setDescription(e.target.value)}
        maxLength={10000}
        rows={4}
        style={{
          padding: "10px 12px",
          borderRadius: 8,
          border: `1px solid var(--border)`,
          background: "var(--bg-secondary)",
          color: "var(--text-primary)",
          fontSize: 14,
          outline: "none",
          resize: "vertical",
          fontFamily: "inherit",
          minHeight: 80,
        }}
      />

      {/* Screenshot upload */}
      <div>
        <input
          ref={fileInputRef}
          type="file"
          accept="image/*"
          multiple
          style={{ display: "none" }}
          onChange={(e) => handleScreenshotUpload(e.target.files)}
        />
        <button
          onClick={() => fileInputRef.current?.click()}
          disabled={screenshots.length >= 5}
          style={{
            display: "flex",
            alignItems: "center",
            gap: 6,
            padding: "8px 12px",
            borderRadius: 8,
            border: `1px dashed var(--border)`,
            background: "transparent",
            color: screenshots.length >= 5 ? "var(--text-secondary)" : "var(--text-primary)",
            fontSize: 13,
            cursor: screenshots.length >= 5 ? "default" : "pointer",
            opacity: screenshots.length >= 5 ? 0.5 : 1,
          }}
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <rect x="3" y="3" width="18" height="18" rx="2" ry="2" />
            <circle cx="8.5" cy="8.5" r="1.5" />
            <polyline points="21 15 16 10 5 21" />
          </svg>
          {screenshots.length === 0
            ? "Attach screenshots (up to 5)"
            : `${screenshots.length}/5 screenshot${screenshots.length !== 1 ? "s" : ""}`}
        </button>
      </div>

      {/* Screenshot previews */}
      {screenshots.length > 0 && (
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          {screenshots.map((src, i) => (
            <div
              key={i}
              style={{
                position: "relative",
                width: 72,
                height: 72,
                borderRadius: 8,
                overflow: "hidden",
                border: `1px solid var(--border)`,
              }}
            >
              <img
                src={src}
                alt={`Screenshot ${i + 1}`}
                style={{ width: "100%", height: "100%", objectFit: "cover" }}
              />
              <button
                onClick={() => removeScreenshot(i)}
                style={{
                  position: "absolute",
                  top: 2,
                  right: 2,
                  width: 20,
                  height: 20,
                  borderRadius: "50%",
                  border: "none",
                  background: "rgba(0,0,0,0.6)",
                  color: "#fff",
                  fontSize: 12,
                  cursor: "pointer",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  lineHeight: 1,
                }}
              >
                ×
              </button>
            </div>
          ))}
        </div>
      )}

      <button
        onClick={handleSubmit}
        disabled={submitting || !description.trim()}
        style={{
          padding: "10px 16px",
          borderRadius: 8,
          border: "none",
          background: submitting || !description.trim()
            ? "var(--text-secondary)"
            : "var(--accent)",
          color: "#fff",
          fontSize: 14,
          fontWeight: 600,
          cursor: submitting ? "wait" : "pointer",
          opacity: submitting || !description.trim() ? 0.5 : 1,
        }}
      >
        {submitting ? "Submitting..." : "Submit Bug Report"}
      </button>

      {/* History toggle */}
      <button
        onClick={loadHistory}
        style={{
          padding: "8px 12px",
          borderRadius: 8,
          border: `1px solid var(--border)`,
          background: "transparent",
          color: "var(--text-secondary)",
          fontSize: 13,
          cursor: "pointer",
          textAlign: "center",
        }}
      >
        {loadingHistory ? "Loading..." : showHistory ? "Hide past reports" : "View past reports"}
      </button>

      {/* Bug history */}
      {showHistory && history.length > 0 && (
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          {history.map((bug) => (
            <div
              key={bug.id}
              style={{
                padding: "10px 12px",
                borderRadius: 8,
                border: `1px solid var(--border)`,
                background: "var(--bg-secondary)",
              }}
            >
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 4 }}>
                <span style={{ fontSize: 13, fontWeight: 600, color: "var(--text-primary)" }}>
                  {bug.title}
                </span>
                <span style={{
                  fontSize: 11,
                  fontWeight: 600,
                  padding: "2px 8px",
                  borderRadius: 10,
                  background: statusColor(bug.status) + "22",
                  color: statusColor(bug.status),
                }}>
                  {statusLabel(bug.status)}
                </span>
              </div>
              <div style={{ fontSize: 12, color: "var(--text-secondary)", lineHeight: 1.4 }}>
                {bug.description.length > 120 ? bug.description.slice(0, 120) + "..." : bug.description}
              </div>
              {bug.screenshots && bug.screenshots.length > 0 && (
                <div style={{ display: "flex", gap: 4, marginTop: 6 }}>
                  {bug.screenshots.map((src: string, i: number) => (
                    <img
                      key={i}
                      src={src}
                      alt=""
                      style={{ width: 40, height: 40, borderRadius: 4, objectFit: "cover", border: `1px solid var(--border)` }}
                    />
                  ))}
                </div>
              )}
              <div style={{ fontSize: 11, color: "var(--text-secondary)", marginTop: 4 }}>
                {new Date(bug.created_at).toLocaleDateString()}
              </div>
            </div>
          ))}
        </div>
      )}

      {showHistory && history.length === 0 && (
        <div style={{ fontSize: 13, color: "var(--text-secondary)", textAlign: "center", padding: 12 }}>
          No bug reports yet.
        </div>
      )}
    </div>
  );
}
