"use client";

import { useState, useEffect, useRef, useCallback } from "react";

interface Props {
  open: boolean;
  onClose: () => void;
  onUploadFile: (file: File) => Promise<void>;
  onUploadUrl: (url: string) => Promise<void>;
}

function isPdf(file: File) {
  return file.type === "application/pdf" || file.name.toLowerCase().endsWith(".pdf");
}

export default function UploadModal({ open, onClose, onUploadFile, onUploadUrl }: Props) {
  const [dragOver, setDragOver] = useState(false);
  const [urlInput, setUrlInput] = useState("");
  const [urlError, setUrlError] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const fileInputRef = useRef<HTMLInputElement>(null);

  // Escape key closes modal (only when not busy)
  useEffect(() => {
    if (!open || busy) return;
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, busy, onClose]);

  // Reset state when modal opens
  useEffect(() => {
    if (open) {
      setDragOver(false);
      setUrlInput("");
      setUrlError("");
      setError("");
      setBusy(false);
    }
  }, [open]);

  const handleFile = useCallback(
    async (file: File) => {
      setBusy(true);
      setError("");
      try {
        await onUploadFile(file);
        onClose();
      } catch (err) {
        setError(err instanceof Error ? err.message : "Upload failed");
      } finally {
        setBusy(false);
      }
    },
    [onUploadFile, onClose]
  );

  const handleDrop = useCallback(
    (e: React.DragEvent) => {
      e.preventDefault();
      setDragOver(false);
      const file = e.dataTransfer.files[0];
      if (file && isPdf(file)) {
        handleFile(file);
      }
    },
    [handleFile]
  );

  const handleUrlSubmit = useCallback(async () => {
    const trimmed = urlInput.trim();
    if (!trimmed) return;
    try {
      new URL(trimmed);
    } catch {
      setUrlError("Please enter a valid URL");
      return;
    }
    setUrlError("");
    setBusy(true);
    setError("");
    try {
      await onUploadUrl(trimmed);
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Ingestion failed");
    } finally {
      setBusy(false);
    }
  }, [urlInput, onUploadUrl, onClose]);

  if (!open) return null;

  return (
    <div
      onClick={busy ? undefined : onClose}
      style={{
        position: "fixed",
        inset: 0,
        zIndex: 9999,
        background: "rgba(0,0,0,0.6)",
        backdropFilter: "blur(4px)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          position: "relative",
          maxWidth: 640,
          width: "90%",
          background: "var(--bg-primary)",
          borderRadius: 12,
          padding: 32,
          boxShadow: "0 8px 32px rgba(0,0,0,0.3)",
        }}
      >
        {/* Close X (hidden when busy) */}
        {!busy && (
          <button
            onClick={onClose}
            style={{
              position: "absolute",
              top: 12,
              right: 12,
              background: "transparent",
              border: "none",
              cursor: "pointer",
              padding: 4,
              color: "var(--text-secondary)",
            }}
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <line x1="18" y1="6" x2="6" y2="18" />
              <line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
        )}

        {/* Busy overlay */}
        {busy ? (
          <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 16, padding: "24px 0" }}>
            <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="var(--accent)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"
              style={{ animation: "spin 1s linear infinite" }}>
              <path d="M21 12a9 9 0 1 1-6.219-8.56" />
            </svg>
            <span style={{ color: "var(--text-secondary)", fontSize: 14 }}>Processing...</span>
            <style>{`@keyframes spin { to { transform: rotate(360deg); } }`}</style>
          </div>
        ) : (
          <>
            {/* Error message */}
            {error && (
              <div style={{ marginBottom: 16, padding: "8px 12px", background: "rgba(239,68,68,0.1)", border: "1px solid #ef4444", borderRadius: 8, color: "#ef4444", fontSize: 13 }}>
                {error}
              </div>
            )}

            {/* Two columns */}
            <div style={{ display: "flex", gap: 24, flexWrap: "wrap" }}>
              {/* Left — drag-drop zone */}
              <div
                onDragOver={(e) => { e.preventDefault(); setDragOver(true); }}
                onDragLeave={() => setDragOver(false)}
                onDrop={handleDrop}
                onClick={() => fileInputRef.current?.click()}
                style={{
                  flex: 1,
                  minWidth: 200,
                  border: `2px dashed ${dragOver ? "var(--accent)" : "var(--border)"}`,
                  borderRadius: 10,
                  padding: "32px 16px",
                  display: "flex",
                  flexDirection: "column",
                  alignItems: "center",
                  justifyContent: "center",
                  gap: 12,
                  cursor: "pointer",
                  transition: "border-color 0.15s ease",
                  background: dragOver ? "rgba(59,130,246,0.05)" : "transparent",
                }}
              >
                <svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="var(--text-secondary)" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
                  <polyline points="17 8 12 3 7 8" />
                  <line x1="12" y1="3" x2="12" y2="15" />
                </svg>
                <span style={{ color: "var(--text-secondary)", fontSize: 14, textAlign: "center" }}>
                  Drop PDF here or click to browse
                </span>
                <input
                  ref={fileInputRef}
                  type="file"
                  accept=".pdf"
                  style={{ display: "none" }}
                  onChange={(e) => {
                    const file = e.target.files?.[0];
                    if (file) handleFile(file);
                  }}
                />
              </div>

              {/* Right — URL input */}
              <div style={{ flex: 1, minWidth: 200, display: "flex", flexDirection: "column", justifyContent: "center", gap: 10 }}>
                <label style={{ fontSize: 13, color: "var(--text-secondary)", fontWeight: 500 }}>
                  Or add by URL
                </label>
                <input
                  type="text"
                  placeholder="https://arxiv.org/pdf/..."
                  value={urlInput}
                  onChange={(e) => { setUrlInput(e.target.value); setUrlError(""); }}
                  onBlur={() => {
                    if (urlInput.trim()) {
                      try { new URL(urlInput.trim()); setUrlError(""); } catch { setUrlError("Please enter a valid URL"); }
                    }
                  }}
                  onKeyDown={(e) => { if (e.key === "Enter") handleUrlSubmit(); }}
                  style={{
                    background: "var(--bg-secondary)",
                    color: "var(--text-primary)",
                    border: `1px solid ${urlError ? "#ef4444" : "var(--border)"}`,
                    borderRadius: 8,
                    padding: "8px 12px",
                    fontSize: 14,
                    outline: "none",
                    width: "100%",
                    boxSizing: "border-box",
                  }}
                />
                {urlError && (
                  <span style={{ color: "#ef4444", fontSize: 12 }}>{urlError}</span>
                )}
                <button
                  onClick={handleUrlSubmit}
                  disabled={!urlInput.trim()}
                  style={{
                    background: "var(--accent)",
                    color: "white",
                    border: "none",
                    borderRadius: 8,
                    padding: "8px 16px",
                    fontSize: 14,
                    fontWeight: 500,
                    cursor: urlInput.trim() ? "pointer" : "not-allowed",
                    opacity: urlInput.trim() ? 1 : 0.5,
                  }}
                >
                  Add
                </button>
              </div>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
