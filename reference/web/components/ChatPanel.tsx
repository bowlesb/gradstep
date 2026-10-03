"use client";

import { useRef, useEffect, useMemo, useCallback, useState, FormEvent, KeyboardEvent } from "react";
import type { Components } from "react-markdown";
import ReactMarkdown from "react-markdown";
import remarkMath from "remark-math";
import remarkGfm from "remark-gfm";
import rehypeKatex from "rehype-katex";

// ---- Live HTML inline rendering --------------------------------------------

function buildLiveHtmlSrcdoc(bodyHtml: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"><\/script>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css" />
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"><\/script>
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"
  onload="renderMathInElement(document.body, {delimiters:[{left:'$$',right:'$$',display:true},{left:'$',right:'$',display:false}]})"
><\/script>
<style>
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; min-width: 0; overflow-wrap: break-word; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  line-height: 1.6;
  padding: 16px;
  background: #141414;
  color: #e0e0e0;
  overflow-wrap: break-word;
  word-break: break-word;
}
h1, h2, h3, h4, h5, h6 { margin: 12px 0 8px; }
h1 { font-size: 1.3rem; }
h2 { font-size: 1.15rem; }
h3 { font-size: 1.05rem; }
pre.mermaid { text-align: center; margin: 16px 0; }
table { border-collapse: collapse; width: 100%; margin: 12px 0; }
th, td { border: 1px solid #333; padding: 8px 12px; text-align: left; }
th { background: #1e1e1e; font-weight: 600; }
tr:nth-child(even) { background: #1a1a1a; }
code { background: #1e1e1e; padding: 2px 6px; border-radius: 3px; font-size: 0.9em; }
svg { max-width: 100%; height: auto; }
blockquote { border-left: 3px solid #444; padding-left: 12px; color: #aaa; margin: 12px 0; }
.katex-display { margin: 16px 0; overflow-x: auto; }
body div, body p, body span, body li, body td, body th, body h2, body h3, body h4, body h5, body h6, body strong, body em, body code, body pre:not(.mermaid) {
  color: #e0e0e0 !important;
}
</style>
</head>
<body>
<div id="__content"></div>
<script>
document.getElementById('__content').innerHTML = ${JSON.stringify(bodyHtml).replace(/<\//g, '<\\/').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029')};
// Strip LLM-generated inline colors/backgrounds
document.querySelectorAll('[style]').forEach(function(el) {
  if (el.closest('pre.mermaid') || el.closest('svg')) return;
  el.style.removeProperty('color');
  el.style.removeProperty('background');
  el.style.removeProperty('background-color');
  el.style.removeProperty('background-image');
});
<\/script>
<script>
mermaid.initialize({
  startOnLoad: false,
  theme: 'dark',
  securityLevel: 'loose',
});
document.querySelectorAll('pre.mermaid').forEach(function(el, i) {
  var src = el.textContent;
  mermaid.render('mermaid-' + i, src).then(function(result) {
    el.innerHTML = result.svg;
    notifyResize();
  }).catch(function(err) {
    console.error('Mermaid error:', err);
    el.classList.remove('mermaid');
    el.style.cssText = 'background:#1e1e1e;color:#e06c75;padding:16px;border-radius:8px;white-space:pre-wrap;font-size:0.85em;overflow-x:auto;';
    el.textContent = 'Diagram render error: ' + (err.message || err) + '\\nSource:\\n' + src;
    notifyResize();
  });
});
<\/script>
<script>
function notifyResize() {
  var h = document.documentElement.scrollHeight;
  window.parent.postMessage({ type: 'live-html-resize', height: h }, '*');
}
// Observe DOM changes for dynamic content (Mermaid, KaTeX)
var observer = new MutationObserver(function() { notifyResize(); });
observer.observe(document.body, { childList: true, subtree: true, attributes: true });
// Fallback timers for resources that load after mutation
setTimeout(notifyResize, 500);
setTimeout(notifyResize, 1500);
setTimeout(notifyResize, 3000);
<\/script>
</body>
</html>`;
}

function LiveHtmlBlock({ rawHtml }: { rawHtml: string }) {
  const iframeRef = useRef<HTMLIFrameElement>(null);
  const [height, setHeight] = useState(200);
  const [isSource, setIsSource] = useState(false);

  const srcdoc = useMemo(() => buildLiveHtmlSrcdoc(rawHtml), [rawHtml]);

  useEffect(() => {
    function handleMessage(e: MessageEvent) {
      if (
        e.data &&
        e.data.type === 'live-html-resize' &&
        typeof e.data.height === 'number' &&
        iframeRef.current &&
        e.source === iframeRef.current.contentWindow
      ) {
        setHeight(Math.min(Math.max(e.data.height, 60), 600));
      }
    }
    window.addEventListener('message', handleMessage);
    return () => window.removeEventListener('message', handleMessage);
  }, []);

  const handleOpenNewTab = useCallback(() => {
    const blob = new Blob([srcdoc], { type: 'text/html' });
    const url = URL.createObjectURL(blob);
    window.open(url, '_blank');
  }, [srcdoc]);

  if (isSource) {
    return (
      <div style={{ margin: '12px 0', border: '1px solid var(--border)', borderRadius: '8px', overflow: 'hidden' }}>
        <div style={{ display: 'flex', gap: '8px', padding: '6px 10px', background: 'var(--bg-secondary)', borderBottom: '1px solid var(--border)', fontSize: '12px' }}>
          <button onClick={() => setIsSource(false)} style={{ background: 'transparent', border: 'none', color: 'var(--accent)', cursor: 'pointer', fontSize: '12px', padding: 0 }}>
            View Rendered
          </button>
        </div>
        <pre style={{ margin: 0, padding: '12px', overflow: 'auto', maxHeight: '400px', fontSize: '12px', background: 'var(--bg-primary)', color: 'var(--text-primary)' }}>
          <code>{rawHtml}</code>
        </pre>
      </div>
    );
  }

  return (
    <div style={{ margin: '12px 0', border: '1px solid var(--border)', borderRadius: '8px', overflow: 'hidden' }}>
      <iframe
        ref={iframeRef}
        srcDoc={srcdoc}
        sandbox="allow-scripts"
        title="Live HTML"
        style={{
          width: '100%',
          height: `${height}px`,
          border: 'none',
          display: 'block',
          transition: 'height 0.2s ease',
          background: '#141414',
        }}
      />
      <div style={{ display: 'flex', gap: '8px', padding: '6px 10px', background: 'var(--bg-secondary)', borderTop: '1px solid var(--border)', fontSize: '12px' }}>
        <button onClick={() => setIsSource(true)} style={{ background: 'transparent', border: 'none', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: '12px', padding: 0 }}>
          View Source
        </button>
        <button onClick={handleOpenNewTab} style={{ background: 'transparent', border: 'none', color: 'var(--text-secondary)', cursor: 'pointer', fontSize: '12px', padding: 0 }}>
          Open in new tab
        </button>
      </div>
    </div>
  );
}

// ---- LaTeX delimiter normalisation -----------------------------------------
// LLMs often use \( ... \) and \[ ... \] delimiters for LaTeX math.
// remark-math only supports $ and $$, so convert before rendering.
function normalizeLatexDelimiters(text: string): string {
  // \[ ... \] → $$ ... $$ (display math)
  text = text.replace(/\\\[([\s\S]*?)\\\]/g, (_m, tex) => `$$${tex}$$`);
  // \( ... \) → $ ... $ (inline math)
  text = text.replace(/\\\(([\s\S]*?)\\\)/g, (_m, tex) => `$${tex}$`);
  return text;
}

// ---- Chat types ------------------------------------------------------------

interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

interface ChatHistoryItem {
  id: string;
  title: string | null;
  highlight_text: string | null;
  highlight_anchor: string | null;
  message_count: number;
  created_at: string;
  updated_at: string;
}

interface Props {
  messages: ChatMessage[];
  sending: boolean;
  agentStatus?: string | null;
  streamingContent?: string;
  input: string;
  onInputChange: (value: string) => void;
  onSubmit: (e: FormEvent) => void;
  onCancel?: () => void;
  onNewChat: () => void;
  chatHistory: ChatHistoryItem[];
  onLoadChat: (chatId: string) => void;
  onHighlightClick: (anchor: string) => void;
  activeChatId: string | null;
  panelView: "chat" | "history";
  onPanelViewChange: (view: "chat" | "history") => void;
  onLibrary?: () => void;
  onLibraryLabel?: string;
  mobile?: boolean;
  chatFontScale?: number;
  onChatFontScaleChange?: (scale: number) => void;
  paperChatMode?: boolean;
  onPaperChatModeChange?: (mode: boolean) => void;
  paperLoaded?: boolean;
  activePaperTitle?: string | null;
  onSelectionAction?: (selectedText: string, action: "define" | "relevance" | "ingest" | "similar") => void;
  onGoToAllChats?: () => void;
  onGoToAllDiagrams?: () => void;
  currentHighlightAnchor?: string | null;
  onGoToPaperHighlight?: (anchor: string) => void;
}

export type { ChatMessage, ChatHistoryItem };

export default function ChatPanel({
  messages,
  sending,
  agentStatus,
  streamingContent,
  input,
  onInputChange,
  onSubmit,
  onCancel,
  onNewChat,
  chatHistory,
  onLoadChat,
  onHighlightClick,
  activeChatId,
  panelView,
  onPanelViewChange,
  onLibrary,
  onLibraryLabel,
  mobile,
  chatFontScale = 1.0,
  onChatFontScaleChange,
  paperChatMode,
  onPaperChatModeChange,
  paperLoaded,
  activePaperTitle,
  onSelectionAction,
  onGoToAllChats,
  onGoToAllDiagrams,
  currentHighlightAnchor,
  onGoToPaperHighlight,
}: Props) {
  const chatMessagesRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const isNearBottomRef = useRef(true);
  const [navDropdownOpen, setNavDropdownOpen] = useState(false);
  const navDropdownRef = useRef<HTMLDivElement>(null);

  // Close nav dropdown on outside click
  useEffect(() => {
    if (!navDropdownOpen) return;
    function handleClick(e: MouseEvent) {
      if (navDropdownRef.current && !navDropdownRef.current.contains(e.target as Node)) {
        setNavDropdownOpen(false);
      }
    }
    document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, [navDropdownOpen]);

  // Compute active anchor — prefer directly passed prop, fall back to chatHistory lookup
  const activeAnchor = currentHighlightAnchor
    ?? (activeChatId ? chatHistory.find((c) => c.id === activeChatId)?.highlight_anchor : null)
    ?? null;

  // Text selection state for action buttons
  const [chatSelection, setChatSelection] = useState<string | null>(null);
  const [chatSelectionPos, setChatSelectionPos] = useState<{ top: number; left: number } | null>(null);
  const selectionTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (!onSelectionAction) return;
    const container = chatMessagesRef.current;
    if (!container) return;

    function handleSelectionChange() {
      if (selectionTimerRef.current) clearTimeout(selectionTimerRef.current);
      selectionTimerRef.current = setTimeout(() => {
        const sel = window.getSelection();
        const text = sel?.toString().trim() || "";
        if (text.length > 2 && sel && sel.rangeCount > 0) {
          // Verify selection is inside the chat messages area
          const anchor = sel.anchorNode;
          if (anchor && container?.contains(anchor)) {
            const range = sel.getRangeAt(0);
            const rect = range.getBoundingClientRect();
            const containerRect = container.getBoundingClientRect();
            setChatSelection(text);
            setChatSelectionPos({
              top: rect.bottom - containerRect.top + container.scrollTop + 6,
              left: Math.max(4, Math.min(rect.left - containerRect.left, containerRect.width - 280)),
            });
          }
        } else {
          setChatSelection(null);
          setChatSelectionPos(null);
        }
      }, 300);
    }

    function handleMouseDown() {
      setChatSelection(null);
      setChatSelectionPos(null);
    }

    document.addEventListener("selectionchange", handleSelectionChange);
    container.addEventListener("mousedown", handleMouseDown);
    container.addEventListener("touchstart", handleMouseDown);
    return () => {
      document.removeEventListener("selectionchange", handleSelectionChange);
      container.removeEventListener("mousedown", handleMouseDown);
      container.removeEventListener("touchstart", handleMouseDown);
      if (selectionTimerRef.current) clearTimeout(selectionTimerRef.current);
    };
  }, [onSelectionAction]);

  const handleChatSelectionAction = useCallback((action: "define" | "relevance" | "ingest" | "similar") => {
    if (chatSelection && onSelectionAction) {
      onSelectionAction(chatSelection, action);
      setChatSelection(null);
      setChatSelectionPos(null);
      window.getSelection()?.removeAllRanges();
    }
  }, [chatSelection, onSelectionAction]);

  // Auto-resize textarea to fit content
  const autoResize = useCallback(() => {
    const el = inputRef.current;
    if (!el) return;
    el.style.height = "auto";
    // Cap at ~6 lines (roughly 140px)
    el.style.height = Math.min(el.scrollHeight, 140) + "px";
  }, []);

  useEffect(() => {
    autoResize();
  }, [input, autoResize]);

  const handleKeyDown = useCallback(
    (e: KeyboardEvent<HTMLTextAreaElement>) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        if (!sending && input.trim()) {
          onSubmit(e as unknown as FormEvent);
        }
      }
    },
    [sending, input, onSubmit]
  );

  const handleScroll = useCallback(() => {
    const el = chatMessagesRef.current;
    if (!el) return;
    // Consider "near bottom" if within 80px of the end
    const threshold = 80;
    isNearBottomRef.current =
      el.scrollHeight - el.scrollTop - el.clientHeight < threshold;
  }, []);

  // When the user sends a new message, snap to bottom (but not when assistant response completes)
  const prevMessageCountRef = useRef(messages.length);
  useEffect(() => {
    if (messages.length > prevMessageCountRef.current) {
      const lastMsg = messages[messages.length - 1];
      if (lastMsg?.role === "user") {
        isNearBottomRef.current = true;
      }
    }
    prevMessageCountRef.current = messages.length;
  }, [messages.length, messages]);

  // Auto-scroll only when the user is already near the bottom
  useEffect(() => {
    const el = chatMessagesRef.current;
    if (el && isNearBottomRef.current) {
      el.scrollTop = el.scrollHeight;
    }
  }, [messages, streamingContent, agentStatus]);

  useEffect(() => {
    if (panelView === "chat" && input && !sending) {
      inputRef.current?.focus();
    }
  }, [panelView, input, sending]);

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const diagramLink = useCallback(({ href, children, ...props }: any) => {
    if (href && href.includes("/api/diagrams/")) {
      return (
        <div style={{ margin: "12px 0" }}>
          <iframe
            src={href}
            title={typeof children === "string" ? children : "Diagram"}
            sandbox="allow-scripts"
            style={{
              width: "100%",
              height: "400px",
              border: "1px solid var(--border)",
              borderRadius: "8px",
              background: "var(--bg-primary)",
            }}
          />
          <a
            href={href}
            target="_blank"
            rel="noopener noreferrer"
            style={{
              display: "inline-block",
              marginTop: "6px",
              fontSize: "12px",
              color: "var(--accent)",
            }}
          >
            Open in new tab
          </a>
        </div>
      );
    }
    return (
      <a href={href} target="_blank" rel="noopener noreferrer" {...props}>
        {children}
      </a>
    );
  }, []);

  const markdownComponents: Components = useMemo(
    () => ({
      a: diagramLink,
      code: ({ className, children, ...props }) => {
        if (className === 'language-live-html') {
          const rawHtml = String(children).replace(/\n$/, '');
          return <LiveHtmlBlock key={rawHtml.slice(0, 100)} rawHtml={rawHtml} />;
        }
        return <code className={className} {...props}>{children}</code>;
      },
    }),
    [diagramLink]
  );

  // Streaming-safe components: show placeholder for live-html instead of rendering partial HTML
  const streamingMarkdownComponents: Components = useMemo(
    () => ({
      a: diagramLink,
      code: ({ className, children, ...props }) => {
        if (className === 'language-live-html') {
          return (
            <div style={{
              padding: "16px",
              background: "var(--bg-secondary)",
              border: "1px solid var(--border)",
              borderRadius: "8px",
              color: "var(--text-secondary)",
              fontSize: "13px",
              display: "flex",
              alignItems: "center",
              gap: "8px",
            }}>
              <span className="spinner" style={{
                width: "14px",
                height: "14px",
                border: "2px solid var(--border)",
                borderTop: "2px solid var(--accent)",
                borderRadius: "50%",
              }} />
              Rendering visual...
            </div>
          );
        }
        return <code className={className} {...props}>{children}</code>;
      },
    }),
    [diagramLink]
  );

  return (
    <div
      style={{
        height: "100%",
        display: "flex",
        flexDirection: "column",
        background: "var(--bg-primary)",
        overflow: "hidden",
      }}
    >
      {/* Tab bar */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          borderBottom: "1px solid var(--border)",
          background: "var(--bg-secondary)",
          flexShrink: 0,
          position: "sticky",
          top: 0,
          zIndex: 10,
        }}
      >
        {mobile ? (
          /* ── Mobile: Navigate dropdown ── */
          <div ref={navDropdownRef} style={{ position: "relative" }}>
            <button
              onClick={() => setNavDropdownOpen(!navDropdownOpen)}
              style={{
                padding: "8px 12px",
                background: "transparent",
                color: "var(--accent)",
                border: "none",
                fontSize: "13px",
                fontWeight: 600,
                cursor: "pointer",
                display: "flex",
                alignItems: "center",
                gap: 4,
              }}
            >
              {panelView === "chat" ? "Chat" : "History"}
              <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"
                style={{ transform: navDropdownOpen ? "rotate(180deg)" : "none", transition: "transform 0.15s ease" }}>
                <polyline points="6 9 12 15 18 9" />
              </svg>
            </button>
            {navDropdownOpen && (
              <div style={{
                position: "absolute",
                top: "100%",
                left: 0,
                background: "var(--bg-primary)",
                border: "1px solid var(--border)",
                borderRadius: "8px",
                boxShadow: "0 4px 16px rgba(0,0,0,0.2)",
                minWidth: 160,
                zIndex: 100,
                overflow: "hidden",
              }}>
                <button
                  onClick={() => { onPanelViewChange("chat"); setNavDropdownOpen(false); }}
                  style={{
                    width: "100%",
                    padding: "10px 14px",
                    background: panelView === "chat" ? "var(--accent)" : "transparent",
                    color: panelView === "chat" ? "#fff" : "var(--text-primary)",
                    border: "none",
                    fontSize: "13px",
                    fontWeight: 500,
                    cursor: "pointer",
                    textAlign: "left",
                    display: "flex",
                    alignItems: "center",
                    gap: 8,
                  }}
                >
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
                  </svg>
                  Chat
                </button>
                <button
                  onClick={() => { onPanelViewChange("history"); setNavDropdownOpen(false); }}
                  style={{
                    width: "100%",
                    padding: "10px 14px",
                    background: panelView === "history" ? "var(--accent)" : "transparent",
                    color: panelView === "history" ? "#fff" : "var(--text-primary)",
                    border: "none",
                    fontSize: "13px",
                    fontWeight: 500,
                    cursor: "pointer",
                    textAlign: "left",
                    display: "flex",
                    alignItems: "center",
                    gap: 8,
                  }}
                >
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <circle cx="12" cy="12" r="10" />
                    <polyline points="12 6 12 12 16 14" />
                  </svg>
                  History
                </button>
                {activeAnchor && (
                  <button
                    onClick={() => {
                      setNavDropdownOpen(false);
                      if (onGoToPaperHighlight) {
                        onGoToPaperHighlight(activeAnchor);
                      } else {
                        onHighlightClick(activeAnchor);
                      }
                    }}
                    style={{
                      width: "100%",
                      padding: "10px 14px",
                      background: "transparent",
                      color: "#6366f1",
                      border: "none",
                      borderTop: "1px solid var(--border)",
                      fontSize: "13px",
                      fontWeight: 500,
                      cursor: "pointer",
                      textAlign: "left",
                      display: "flex",
                      alignItems: "center",
                      gap: 8,
                    }}
                  >
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                      <circle cx="11" cy="11" r="8" />
                      <line x1="21" y1="21" x2="16.65" y2="16.65" />
                    </svg>
                    Go to Selection
                  </button>
                )}
              </div>
            )}
          </div>
        ) : (
          /* ── Desktop: flat tab buttons ── */
          <>
            <button
              onClick={() => onPanelViewChange("chat")}
              style={{
                padding: "8px 14px",
                background: "transparent",
                color: panelView === "chat" ? "var(--accent)" : "var(--text-secondary)",
                border: "none",
                borderBottom: panelView === "chat" ? "2px solid var(--accent)" : "2px solid transparent",
                fontSize: "12px",
                fontWeight: 500,
                cursor: "pointer",
              }}
            >
              Chat
            </button>
            <button
              onClick={() => onPanelViewChange("history")}
              style={{
                padding: "8px 14px",
                background: "transparent",
                color: panelView === "history" ? "var(--accent)" : "var(--text-secondary)",
                border: "none",
                borderBottom: panelView === "history" ? "2px solid var(--accent)" : "2px solid transparent",
                fontSize: "12px",
                fontWeight: 500,
                cursor: "pointer",
              }}
            >
              History
            </button>
            {onLibrary && (
              <button
                onClick={onLibrary}
                style={{
                  padding: "8px 14px",
                  background: "transparent",
                  color: "var(--text-secondary)",
                  border: "none",
                  borderBottom: "2px solid transparent",
                  fontSize: "12px",
                  fontWeight: 500,
                  cursor: "pointer",
                }}
              >
                {onLibraryLabel || "Library"}
              </button>
            )}
            {activeAnchor && (
              <button
                onClick={() => onHighlightClick(activeAnchor)}
                title="Scroll to selected text in paper"
                style={{
                  padding: "8px 14px",
                  background: "transparent",
                  color: "var(--accent, #6366f1)",
                  border: "none",
                  borderBottom: "2px solid transparent",
                  fontSize: "12px",
                  fontWeight: 500,
                  cursor: "pointer",
                  display: "flex",
                  alignItems: "center",
                  gap: 4,
                }}
              >
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <circle cx="11" cy="11" r="8" />
                  <line x1="21" y1="21" x2="16.65" y2="16.65" />
                </svg>
                Selected Text
              </button>
            )}
          </>
        )}
        {onChatFontScaleChange && (
          <div
            style={{
              marginLeft: "auto",
              display: "flex",
              alignSelf: "center",
              flexShrink: 0,
              gap: "2px",
              marginRight: onPaperChatModeChange ? 4 : (mobile ? 8 : 6),
            }}
          >
            <button
              onClick={() => onChatFontScaleChange(chatFontScale - 0.1)}
              disabled={chatFontScale <= 0.7}
              title="Decrease font size"
              style={{
                background: "transparent",
                border: "none",
                cursor: chatFontScale <= 0.7 ? "default" : "pointer",
                color: chatFontScale <= 0.7 ? "var(--border)" : "var(--text-secondary)",
                fontSize: mobile ? "13px" : "11px",
                fontWeight: 600,
                padding: mobile ? "4px 6px" : "2px 4px",
                lineHeight: 1,
              }}
            >
              A-
            </button>
            <button
              onClick={() => onChatFontScaleChange(chatFontScale + 0.1)}
              disabled={chatFontScale >= 1.8}
              title="Increase font size"
              style={{
                background: "transparent",
                border: "none",
                cursor: chatFontScale >= 1.8 ? "default" : "pointer",
                color: chatFontScale >= 1.8 ? "var(--border)" : "var(--text-secondary)",
                fontSize: mobile ? "15px" : "13px",
                fontWeight: 600,
                padding: mobile ? "4px 6px" : "2px 4px",
                lineHeight: 1,
              }}
            >
              A+
            </button>
          </div>
        )}
        {onPaperChatModeChange && (
          <div
            style={{
              marginLeft: onChatFontScaleChange ? undefined : "auto",
              marginRight: mobile ? 8 : 6,
              display: "flex",
              alignSelf: "center",
              flexShrink: 0,
              background: "var(--bg-primary)",
              border: "1px solid var(--border)",
              borderRadius: "6px",
              overflow: "hidden",
              fontSize: mobile ? "11px" : "11px",
              fontWeight: 500,
            }}
          >
            <button
              onClick={() => onPaperChatModeChange(false)}
              style={{
                padding: mobile ? "4px 8px" : "3px 8px",
                background: !paperChatMode ? "var(--accent)" : "transparent",
                color: !paperChatMode ? "#fff" : "var(--text-secondary)",
                border: "none",
                cursor: "pointer",
                fontSize: "inherit",
                fontWeight: "inherit",
                transition: "all 0.15s ease",
              }}
            >
              General
            </button>
            <button
              onClick={() => paperLoaded && onPaperChatModeChange(true)}
              style={{
                padding: mobile ? "4px 8px" : "3px 8px",
                background: paperChatMode ? "var(--accent)" : "transparent",
                color: paperChatMode ? "#fff" : "var(--text-secondary)",
                border: "none",
                cursor: paperLoaded ? "pointer" : "default",
                opacity: paperLoaded ? 1 : 0.35,
                fontSize: "inherit",
                fontWeight: "inherit",
                transition: "all 0.15s ease",
              }}
            >
              Paper
            </button>
          </div>
        )}
      </div>

      {panelView === "chat" ? (
        <>
          {/* Messages */}
          <div
            ref={chatMessagesRef}
            onScroll={handleScroll}
            onContextMenu={(e) => {
              // Suppress native context menu when selection action popup is visible
              if (chatSelection && chatSelectionPos && onSelectionAction) {
                e.preventDefault();
              }
            }}
            style={{
              flex: 1,
              overflowY: "auto",
              padding: mobile ? "0" : "1rem",
              display: "flex",
              flexDirection: "column",
              gap: mobile ? 0 : "0.75rem",
              position: "relative",
            }}
          >
            {chatSelection && chatSelectionPos && onSelectionAction && (
              <div
                className={mobile ? "mobile-selection-actions" : undefined}
                style={{
                  position: "absolute",
                  top: chatSelectionPos.top,
                  left: chatSelectionPos.left,
                  zIndex: 20,
                  display: "flex",
                  flexDirection: "row",
                  gap: mobile ? "4px" : "5px",
                  maxWidth: "calc(100% - 8px)",
                }}
              >
                <button onClick={() => handleChatSelectionAction("define")} style={{
                  background: "#6366f1", color: "white", border: "none", borderRadius: "8px",
                  padding: mobile ? "4px 8px" : "5px 12px", fontSize: mobile ? "11px" : "12px",
                  cursor: "pointer", boxShadow: "0 2px 12px rgba(0,0,0,0.25)", whiteSpace: "nowrap",
                }}>
                  Define
                </button>
                <button onClick={() => handleChatSelectionAction("relevance")} style={{
                  background: "#6366f1", color: "white", border: "none", borderRadius: "8px",
                  padding: mobile ? "4px 8px" : "5px 12px", fontSize: mobile ? "11px" : "12px",
                  cursor: "pointer", boxShadow: "0 2px 12px rgba(0,0,0,0.25)", whiteSpace: "nowrap",
                }}>
                  Relevance
                </button>
                <button onClick={() => handleChatSelectionAction("ingest")} style={{
                  background: "#10b981", color: "white", border: "none", borderRadius: "8px",
                  padding: mobile ? "4px 8px" : "5px 12px", fontSize: mobile ? "11px" : "12px",
                  cursor: "pointer", boxShadow: "0 2px 12px rgba(0,0,0,0.25)", whiteSpace: "nowrap",
                }}>
                  Ingest
                </button>
                <button onClick={() => handleChatSelectionAction("similar")} style={{
                  background: "#6366f1", color: "white", border: "none", borderRadius: "8px",
                  padding: mobile ? "4px 8px" : "5px 12px", fontSize: mobile ? "11px" : "12px",
                  cursor: "pointer", boxShadow: "0 2px 12px rgba(0,0,0,0.25)", whiteSpace: "nowrap",
                }}>
                  Similar
                </button>
              </div>
            )}
            {messages.length === 0 && (
              <div
                style={{
                  color: "var(--text-secondary)",
                  textAlign: "center",
                  marginTop: "3rem",
                  fontSize: "14px",
                }}
              >
                <p>
                  {paperChatMode
                    ? `Ask a question about ${activePaperTitle ? `"${activePaperTitle}"` : "the paper"}, or select text and click "Explain".`
                    : "Ask anything — general research questions, concepts, or search for papers."}
                </p>
              </div>
            )}
            {messages.map((m, i) => (
              <div
                key={i}
                style={{
                  padding: mobile ? "10px 0" : "10px 14px",
                  borderRadius: mobile ? 0 : "10px",
                  maxWidth: "100%",
                  width: "100%",
                  wordBreak: "break-word" as const,
                  alignSelf: "stretch",
                  background: mobile
                    ? (m.role === "user" ? "var(--bg-secondary)" : "transparent")
                    : (m.role === "user" ? "var(--accent)" : "var(--bg-secondary)"),
                  borderBottom: mobile ? "1px solid var(--border)" : undefined,
                }}
              >
                <div
                  className="prose prose-sm"
                  style={{ fontSize: `${11 * chatFontScale}px` }}
                >
                  <ReactMarkdown
                    remarkPlugins={[remarkGfm, remarkMath]}
                    rehypePlugins={[rehypeKatex]}
                    components={markdownComponents}
                  >
                    {normalizeLatexDelimiters(m.content)}
                  </ReactMarkdown>
                </div>
              </div>
            ))}
            {sending && streamingContent ? (
              <div
                style={{
                  padding: mobile ? "10px 0" : "10px 14px",
                  borderRadius: mobile ? 0 : "10px",
                  maxWidth: "100%",
                  width: "100%",
                  wordBreak: "break-word" as const,
                  background: mobile ? "transparent" : "var(--bg-secondary)",
                  alignSelf: "stretch",
                  borderBottom: mobile ? "1px solid var(--border)" : undefined,
                }}
              >
                <div
                  className="prose prose-sm"
                  style={{ fontSize: `${11 * chatFontScale}px` }}
                >
                  <ReactMarkdown
                    remarkPlugins={[remarkGfm, remarkMath]}
                    rehypePlugins={[rehypeKatex]}
                    components={streamingMarkdownComponents}
                  >
                    {normalizeLatexDelimiters(streamingContent)}
                  </ReactMarkdown>
                </div>
                {agentStatus && (
                  <div style={{ marginTop: "8px", color: "var(--text-secondary)", fontSize: "13px" }}>
                    {agentStatus}
                  </div>
                )}
              </div>
            ) : sending ? (
              <div
                style={{
                  padding: mobile ? "10px 0" : "10px 14px",
                  borderRadius: mobile ? 0 : "10px",
                  background: mobile ? "transparent" : "var(--bg-secondary)",
                  alignSelf: "stretch",
                  width: "100%",
                }}
              >
                <span style={{ color: "var(--text-secondary)" }}>
                  {agentStatus || "Thinking..."}
                </span>
              </div>
            ) : null}
          </div>

          {/* Input */}
          <div
            style={{
              display: "flex",
              gap: "8px",
              padding: "12px",
              borderTop: "1px solid var(--border)",
              flexShrink: 0,
            }}
          >
            <button
              onClick={onNewChat}
              title="New Chat"
              style={{
                background: "transparent",
                color: "var(--text-secondary)",
                border: "1px solid var(--border)",
                borderRadius: "8px",
                padding: "10px 12px",
                fontSize: "14px",
                cursor: "pointer",
                flexShrink: 0,
              }}
            >
              +
            </button>
            <form
              onSubmit={onSubmit}
              style={{ display: "flex", gap: "8px", flex: 1, alignItems: "flex-end" }}
            >
              <textarea
                ref={inputRef}
                value={input}
                onChange={(e) => onInputChange(e.target.value)}
                onKeyDown={handleKeyDown}
                placeholder={paperChatMode ? (activePaperTitle ? `Ask about "${activePaperTitle.slice(0, 40)}${activePaperTitle.length > 40 ? "..." : ""}"` : "Ask about the paper...") : "Ask anything..."}
                disabled={sending}
                rows={1}
                style={{
                  flex: 1,
                  background: "var(--bg-secondary)",
                  color: "var(--text-primary)",
                  border: "1px solid var(--border)",
                  borderRadius: "8px",
                  padding: "10px 14px",
                  fontSize: "14px",
                  outline: "none",
                  resize: "none",
                  lineHeight: "1.4",
                  fontFamily: "inherit",
                  overflow: "auto",
                }}
              />
              {sending && onCancel ? (
                <button
                  type="button"
                  onClick={onCancel}
                  style={{
                    background: "var(--bg-secondary)",
                    color: "var(--text-primary)",
                    border: "1px solid var(--border)",
                    borderRadius: "8px",
                    padding: "10px 18px",
                    fontSize: "14px",
                    cursor: "pointer",
                    flexShrink: 0,
                  }}
                >
                  Stop
                </button>
              ) : (
                <button
                  type="submit"
                  disabled={sending || !input.trim()}
                  style={{
                    background: "var(--accent)",
                    color: "white",
                    border: "none",
                    borderRadius: "8px",
                    padding: "10px 18px",
                    fontSize: "14px",
                    cursor: "pointer",
                    flexShrink: 0,
                  }}
                >
                  Send
                </button>
              )}
            </form>
          </div>
        </>
      ) : (
        /* History tab */
        <div style={{ flex: 1, overflowY: "auto", padding: "8px" }}>
          {(onGoToAllChats || onGoToAllDiagrams) && (
            <div style={{ display: "flex", gap: "6px", padding: "4px 4px 8px", borderBottom: "1px solid var(--border)", marginBottom: "8px" }}>
              {onGoToAllChats && (
                <button
                  onClick={onGoToAllChats}
                  style={{
                    flex: 1,
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    gap: "6px",
                    padding: mobile ? "10px 12px" : "8px 12px",
                    background: "var(--bg-secondary)",
                    border: "1px solid var(--border)",
                    borderRadius: "8px",
                    cursor: "pointer",
                    color: "var(--text-primary)",
                    fontSize: "13px",
                    fontWeight: 500,
                  }}
                >
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
                  </svg>
                  All Chats
                </button>
              )}
              {onGoToAllDiagrams && (
                <button
                  onClick={onGoToAllDiagrams}
                  style={{
                    flex: 1,
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    gap: "6px",
                    padding: mobile ? "10px 12px" : "8px 12px",
                    background: "var(--bg-secondary)",
                    border: "1px solid var(--border)",
                    borderRadius: "8px",
                    cursor: "pointer",
                    color: "var(--text-primary)",
                    fontSize: "13px",
                    fontWeight: 500,
                  }}
                >
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <rect x="3" y="3" width="18" height="18" rx="2" ry="2" />
                    <line x1="3" y1="9" x2="21" y2="9" />
                    <line x1="9" y1="21" x2="9" y2="9" />
                  </svg>
                  Diagrams
                </button>
              )}
            </div>
          )}
          {chatHistory.length === 0 && (
            <div
              style={{
                color: "var(--text-secondary)",
                textAlign: "center",
                marginTop: "3rem",
                fontSize: "14px",
              }}
            >
              No chat history yet
            </div>
          )}
          {chatHistory.map((chat) => (
            <div
              key={chat.id}
              onClick={() => onLoadChat(chat.id)}
              style={{
                padding: "12px 14px",
                margin: "4px 0",
                borderRadius: "8px",
                cursor: "pointer",
                background:
                  activeChatId === chat.id
                    ? "var(--accent-muted)"
                    : "transparent",
                border: "1px solid var(--border)",
                transition: "background 0.15s",
              }}
              {...(!mobile ? {
                onMouseEnter: (e: React.MouseEvent<HTMLDivElement>) => {
                  if (activeChatId !== chat.id) {
                    e.currentTarget.style.background = "var(--bg-hover)";
                  }
                },
                onMouseLeave: (e: React.MouseEvent<HTMLDivElement>) => {
                  e.currentTarget.style.background =
                    activeChatId === chat.id
                      ? "var(--accent-muted)"
                      : "transparent";
                },
              } : {})}
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
                  {chat.highlight_text && (
                    <div
                      style={{
                        fontSize: "12px",
                        color: "var(--accent)",
                        marginTop: "4px",
                        overflow: "hidden",
                        textOverflow: "ellipsis",
                        whiteSpace: "nowrap",
                        cursor: chat.highlight_anchor ? "pointer" : "default",
                      }}
                      onClick={(e) => {
                        if (chat.highlight_anchor) {
                          e.stopPropagation();
                          onHighlightClick(chat.highlight_anchor);
                        }
                      }}
                      title={
                        chat.highlight_anchor
                          ? "Click to jump to highlighted text in paper"
                          : undefined
                      }
                    >
                      &quot;{chat.highlight_text.slice(0, 80)}
                      {chat.highlight_text.length > 80 ? "..." : ""}
                      &quot;
                    </div>
                  )}
                </div>
                <div
                  style={{
                    fontSize: "11px",
                    color: "var(--text-secondary)",
                    flexShrink: 0,
                    textAlign: "right",
                  }}
                >
                  <div>{new Date(chat.updated_at).toLocaleDateString()}</div>
                  <div>{chat.message_count} msgs</div>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
