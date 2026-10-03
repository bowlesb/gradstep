"use client";

import { useState, useEffect, useCallback, useMemo, useRef, FormEvent } from "react";
import { ImperativePanelHandle, Panel, PanelGroup, PanelResizeHandle } from "react-resizable-panels";
import CollapseHandle from "@/components/CollapseHandle";
import MarkdownReader, { SelectionAction } from "@/components/MarkdownReader";
import LibraryView, { QueueSummary } from "@/components/LibraryView";
import ChatPanel, { ChatMessage, ChatHistoryItem } from "@/components/ChatPanel";
import AllChatsView, { AllChat } from "@/components/AllChatsView";
import AllDiagramsView, { DiagramItem } from "@/components/AllDiagramsView";
import { Paper, SortField, SortOrder, ExternalResult } from "@/components/PaperTable";
import UploadModal from "@/components/UploadModal";
import ResearchFeed, { FeedTopic } from "@/components/ResearchFeed";
import { FeedResult } from "@/lib/db";
import { useDeviceType } from "@/hooks/useDeviceType";
import MobileTabBar, { MobileTab } from "@/components/MobileTabBar";
import TableOfContents, { TocEntry } from "@/components/TableOfContents";
import FigureViewer from "@/components/FigureViewer";
import BugReportForm from "@/components/BugReportForm";
import LoginForm from "@/components/LoginForm";
import AdminPanel from "@/components/AdminPanel";
import { useOffline } from "@/hooks/useOffline";
import { listOfflinePapers } from "@/lib/offline-store";

type ViewMode = "feed" | "library" | "reader" | "browse" | "chat";

function DebugInfo() {
  const [info, setInfo] = useState<string[]>([]);
  useEffect(() => {
    function update() {
      const cs = getComputedStyle(document.documentElement);
      const standalone = (navigator as unknown as Record<string, unknown>).standalone || window.matchMedia("(display-mode: standalone)").matches;
      setInfo([
        `window.innerHeight: ${window.innerHeight}`,
        `window.outerHeight: ${window.outerHeight}`,
        `screen.height: ${screen.height}`,
        `html.clientHeight: ${document.documentElement.clientHeight}`,
        `body.clientHeight: ${document.body.clientHeight}`,
        `body.offsetHeight: ${document.body.offsetHeight}`,
        `visualViewport.height: ${window.visualViewport ? window.visualViewport.height : "N/A"}`,
        `--sat: ${cs.getPropertyValue("--sat")}`,
        `--sab: ${cs.getPropertyValue("--sab")}`,
        `standalone: ${standalone}`,
        `devicePixelRatio: ${window.devicePixelRatio}`,
      ]);
    }
    update();
    window.addEventListener("resize", update);
    return () => window.removeEventListener("resize", update);
  }, []);
  return (
    <div className="settings-section">
      <div className="settings-section-title">Debug Info</div>
      <div style={{ fontSize: 11, color: "var(--text-secondary)", fontFamily: "monospace", lineHeight: 1.8 }}>
        {info.map((line, i) => <div key={i}>{line}</div>)}
      </div>
    </div>
  );
}

export default function Home() {
  // ─── Device type ─────────────────────────────────────────────
  const device = useDeviceType();
  const isMobile = device === "mobile";
  const isTablet = device === "tablet";

  // ─── Offline mode ─────────────────────────────────────────────
  const { isOnline, offlineIds, saving: offlineSaving, savePaperOffline, removePaperOffline, loadPaperOffline, isOffline: isOfflineSaved } = useOffline();

  // ─── Authentication ──────────────────────────────────────────
  const [authLoaded, setAuthLoaded] = useState(false);
  const [authenticated, setAuthenticated] = useState(false);
  const [isLocalNetwork, setIsLocalNetwork] = useState(false);
  const [authUsername, setAuthUsername] = useState<string | null>(null);
  const [hasUsers, setHasUsers] = useState(true);
  const [showAdmin, setShowAdmin] = useState(false);

  useEffect(() => {
    fetch("/api/auth/me")
      .then((res) => res.json())
      .then((data) => {
        setAuthenticated(data.authenticated);
        setIsLocalNetwork(data.isLocal);
        setAuthUsername(data.username ?? null);
        setHasUsers(data.hasUsers);
        setAuthLoaded(true);
      })
      .catch(() => setAuthLoaded(true));
  }, []);

  const handleLogin = useCallback((username: string) => {
    setAuthenticated(true);
    setAuthUsername(username);
  }, []);

  const handleLogout = useCallback(async () => {
    await fetch("/api/auth/logout", { method: "POST" }).catch(() => {});
    setAuthenticated(false);
    setAuthUsername(null);
  }, []);

  // ─── Mobile tab state ────────────────────────────────────────
  const [mobileTab, setMobileTab] = useState<MobileTab>("library");

  // ─── View mode state machine ───────────────────────────────────
  const [viewMode, setViewMode] = useState<ViewMode>("library");

  // ─── Paper state ───────────────────────────────────────────────
  const [activePaperId, setActivePaperId] = useState<string | null>(null);
  const [paperHtml, setPaperHtml] = useState<string | null>(null);
  const [papers, setPapers] = useState<Paper[]>([]);
  const [searchQuery, setSearchQuery] = useState("");
  const [sortField, setSortField] = useState<SortField>("created_at");
  const [sortOrder, setSortOrder] = useState<SortOrder>("desc");
  const [loadingPaperId, setLoadingPaperId] = useState<string | null>(null);
  const [paperToc, setPaperToc] = useState<TocEntry[] | null>(null);
  const [scrollToHeadingId, setScrollToHeadingId] = useState<string | null>(null);

  // ─── External search state ─────────────────────────────────────
  const [externalResults, setExternalResults] = useState<ExternalResult[]>([]);
  const [externalSearching, setExternalSearching] = useState(false);

  // ─── Feed state ───────────────────────────────────────────────
  const [feedTopics, setFeedTopics] = useState<FeedTopic[]>([]);
  const [feedResults, setFeedResults] = useState<FeedResult[]>([]);
  const [feedLoading, setFeedLoading] = useState(false);
  const [feedRefreshing, setFeedRefreshing] = useState(false);
  const [feedActiveTopic, setFeedActiveTopic] = useState<string | null>(null);
  const [feedLastRefreshed, setFeedLastRefreshed] = useState<string | null>(null);

  // ─── Upload state ──────────────────────────────────────────────
  const [uploading, setUploading] = useState(false);
  const [uploadProgress, setUploadProgress] = useState("");
  const [uploadModalOpen, setUploadModalOpen] = useState(false);

  // ─── Chat state ────────────────────────────────────────────────
  const [activeChatId, setActiveChatId] = useState<string | null>(null);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState("");
  const [sending, setSending] = useState(false);
  const [agentStatus, setAgentStatus] = useState<string | null>(null);
  const [streamingContent, setStreamingContent] = useState("");
  const [chatHistory, setChatHistory] = useState<ChatHistoryItem[]>([]);
  const [chatPanelView, setChatPanelView] = useState<"chat" | "history">("chat");
  const [pendingHighlight, setPendingHighlight] = useState<{ text: string; anchor: string } | null>(null);
  const [paperChatMode, setPaperChatMode] = useState(false);
  const [currentHighlightAnchor, setCurrentHighlightAnchor] = useState<string | null>(null);
  const abortControllerRef = useRef<AbortController | null>(null);
  const chatGenerationRef = useRef(0);

  // ─── Dark mode ──────────────────────────────────────────────────
  const [darkMode, setDarkMode] = useState(() => {
    if (typeof window !== "undefined") {
      return localStorage.getItem("darkMode") === "true";
    }
    return false;
  });

  useEffect(() => {
    document.documentElement.classList.toggle("dark", darkMode);
    localStorage.setItem("darkMode", String(darkMode));
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", darkMode ? "#0f0f0f" : "#ffffff");
  }, [darkMode]);

  // ─── Font scale (Kindle-style text sizing) ────────────────────
  const [fontScale, setFontScale] = useState(1.0);

  // Load persisted font scale on mount
  useEffect(() => {
    const saved = localStorage.getItem("paperFontScale");
    if (saved) setFontScale(parseFloat(saved));
  }, []);

  const handleFontScaleChange = useCallback((scale: number) => {
    const clamped = Math.round(Math.max(0.7, Math.min(1.8, scale)) * 10) / 10;
    setFontScale(clamped);
    localStorage.setItem("paperFontScale", String(clamped));
  }, []);

  // ─── Chat font scale ─────────────────────────────────────────
  const [chatFontScale, setChatFontScale] = useState(1.0);

  useEffect(() => {
    const saved = localStorage.getItem("chatFontScale");
    if (saved) setChatFontScale(parseFloat(saved));
  }, []);

  const handleChatFontScaleChange = useCallback((scale: number) => {
    const clamped = Math.round(Math.max(0.7, Math.min(1.8, scale)) * 10) / 10;
    setChatFontScale(clamped);
    localStorage.setItem("chatFontScale", String(clamped));
  }, []);

  // ─── Active paper title ────────────────────────────────────────
  const activePaperTitle = useMemo(() => {
    if (!activePaperId) return null;
    const paper = papers.find((p) => p.id === activePaperId);
    return paper?.title || null;
  }, [activePaperId, papers]);

  // ─── TOC navigation ─────────────────────────────────────────────
  const handleTocNavigate = useCallback((headingId: string) => {
    setScrollToHeadingId(headingId);
  }, []);

  const handleScrollComplete = useCallback(() => {
    setScrollToHeadingId(null);
  }, []);

  // ─── All Chats view ────────────────────────────────────────────
  const [showAllChats, setShowAllChats] = useState(false);
  const [showAllDiagrams, setShowAllDiagrams] = useState(false);

  // ─── Figures viewer ────────────────────────────────────────────
  const [showFigures, setShowFigures] = useState(false);
  const [initialFigureSrc, setInitialFigureSrc] = useState<string | null>(null);

  const handleFigureClick = useCallback((src: string) => {
    setInitialFigureSrc(src);
    setShowFigures(true);
  }, []);

  // ─── Escape key closes overlays ──────────────────────────────
  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === "Escape") {
        if (showFigures) { setShowFigures(false); e.preventDefault(); }
        else if (showAllChats) { setShowAllChats(false); e.preventDefault(); }
        else if (showAllDiagrams) { setShowAllDiagrams(false); e.preventDefault(); }
        else if (showAdmin) { setShowAdmin(false); e.preventDefault(); }
      }
    }
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [showFigures, showAllChats, showAllDiagrams, showAdmin]);

  // ─── Tablet full-screen sub-view (PDF vs Chat) ────────────────
  const [tabletShowChat, setTabletShowChat] = useState(false);

  // ─── Collapsible panel refs & state ──────────────────────────
  const readerPdfPanelRef = useRef<ImperativePanelHandle>(null);
  const readerChatPanelRef = useRef<ImperativePanelHandle>(null);
  const browseLibraryPanelRef = useRef<ImperativePanelHandle>(null);
  const browsePdfPanelRef = useRef<ImperativePanelHandle>(null);

  const [readerPdfCollapsed, setReaderPdfCollapsed] = useState(false);
  const [readerChatCollapsed, setReaderChatCollapsed] = useState(false);
  const [browseLibraryCollapsed, setBrowseLibraryCollapsed] = useState(false);
  const [browsePdfCollapsed, setBrowsePdfCollapsed] = useState(false);

  // Reset collapse states when switching views
  useEffect(() => {
    setReaderPdfCollapsed(false);
    setReaderChatCollapsed(false);
    setBrowseLibraryCollapsed(false);
    setBrowsePdfCollapsed(false);
  }, [viewMode]);

  // ─── Ingestion queue ──────────────────────────────────────────
  const [queueSummary, setQueueSummary] = useState<QueueSummary | null>(null);
  const [apiErrors, setApiErrors] = useState<{ service: string; message: string; timestamp: number }[]>([]);
  const fetchPapersRef = useRef<(() => Promise<void>) | null>(null);
  const prevQueueTotal = useRef<number>(0);

  async function handleRetryFailed() {
    await fetch("/api/ingest", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "retry" }),
    });
  }

  async function handleClearCompleted() {
    await fetch("/api/ingest", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "clear" }),
    });
  }

  // ─── Data loading ──────────────────────────────────────────────

  const fetchPapers = useCallback(async () => {
    try {
      if (!navigator.onLine) {
        // Offline: show only locally-cached papers
        const offline = await listOfflinePapers();
        const asPapers: Paper[] = offline.map((p) => ({
          id: p.id,
          title: p.title,
          authors: p.authors,
          year: p.year,
          venue: p.venue,
          abstract: p.abstract,
          keywords: p.keywords,
          created_at: new Date(p.savedAt).toISOString(),
          last_opened_at: null,
        }));
        setPapers(asPapers);
        return;
      }
      const params = new URLSearchParams();
      if (searchQuery) params.set("q", searchQuery);
      else {
        params.set("sort", sortField);
        params.set("order", sortOrder);
      }
      const res = await fetch(`/api/papers?${params}`);
      if (!res.ok) {
        console.error(`[fetchPapers] HTTP ${res.status}: ${res.statusText}`);
        return;
      }
      const data = await res.json();
      setPapers(data.papers || []);
    } catch (err) {
      console.error("[fetchPapers] Network error:", err);
      // On network error, try to show offline papers
      try {
        const offline = await listOfflinePapers();
        if (offline.length > 0) {
          const asPapers: Paper[] = offline.map((p) => ({
            id: p.id,
            title: p.title,
            authors: p.authors,
            year: p.year,
            venue: p.venue,
            abstract: p.abstract,
            keywords: p.keywords,
            created_at: new Date(p.savedAt).toISOString(),
            last_opened_at: null,
          }));
          setPapers(asPapers);
        }
      } catch {}
    }
  }, [searchQuery, sortField, sortOrder]);

  useEffect(() => {
    if (authLoaded && authenticated) fetchPapers();
  }, [fetchPapers, authLoaded, authenticated]);

  // Keep ref current so the queue poller always uses latest sort/search
  fetchPapersRef.current = fetchPapers;

  useEffect(() => {
    if (!authLoaded || !authenticated) return;
    let active = true;
    let timer: ReturnType<typeof setTimeout>;
    async function pollQueue() {
      try {
        const res = await fetch("/api/ingest");
        if (!res.ok) return;
        const data = await res.json();
        if (!active) return;
        setQueueSummary(data.summary);
        if (data.apiErrors?.length > 0) setApiErrors(data.apiErrors);
        const s = data.summary;
        const hasActive = s && (s.total > 0);
        const wasActive = prevQueueTotal.current > 0;
        prevQueueTotal.current = s?.total ?? 0;
        if (s?.complete > 0) {
          await handleClearCompleted();
          await fetchPapersRef.current?.();
        } else if (hasActive) {
          await fetchPapersRef.current?.();
        } else if (wasActive && !hasActive) {
          // Queue just became empty — refresh to show newly completed papers
          await fetchPapersRef.current?.();
        }
      } catch { /* ignore */ }
      // Schedule next poll only after current one completes (no overlapping)
      if (active) timer = setTimeout(pollQueue, 2000);
    }
    pollQueue();
    return () => { active = false; clearTimeout(timer); };
  }, [authLoaded, authenticated]);

  // ─── Feed data loading ─────────────────────────────────────────
  const fetchFeed = useCallback(async (forceRefresh = false) => {
    if (forceRefresh) {
      setFeedRefreshing(true);
    } else {
      setFeedLoading(true);
    }
    try {
      const params = new URLSearchParams();
      if (forceRefresh) params.set("refresh", "1");
      const res = await fetch(`/api/feed?${params}`);
      const data = await res.json();
      setFeedTopics(data.topics || []);
      setFeedResults(data.results || []);
      setFeedLastRefreshed(data.lastRefreshed || null);
    } catch {
      /* ignore */
    } finally {
      setFeedLoading(false);
      setFeedRefreshing(false);
    }
  }, []);

  // Load feed on mount (after auth)
  useEffect(() => {
    if (authLoaded && authenticated) fetchFeed();
  }, [fetchFeed, authLoaded, authenticated]);

  const fetchChatHistory = useCallback(async () => {
    try {
      const url = paperChatMode && activePaperId
        ? `/api/chats?paperId=${activePaperId}`
        : `/api/chats?generic=1`;
      const res = await fetch(url);
      const data = await res.json();
      setChatHistory(data.chats || []);
    } catch {
      /* ignore */
    }
  }, [activePaperId, paperChatMode]);

  useEffect(() => {
    fetchChatHistory();
  }, [fetchChatHistory]);

  // ─── Handlers ──────────────────────────────────────────────────

  async function handleUpload(file: File) {
    setUploading(true);
    setUploadProgress("Uploading to Mathpix for conversion...");
    try {
      const formData = new FormData();
      formData.append("file", file);
      const res = await fetch("/api/upload", { method: "POST", body: formData });
      if (!res.ok) {
        const err = await res.json();
        throw new Error(err.error || "Upload failed");
      }
      const data = await res.json();
      setPaperHtml(data.html);
      setPaperToc(data.toc ?? null);
      setActivePaperId(data.documentId);
      setPaperChatMode(true);
      setMessages([]);
      setActiveChatId(null);
      setChatPanelView("chat");
      setUploadProgress("");
      if (isMobile) {
        setMobileTab("paper");
      } else {
        setViewMode("reader");
      }
      fetchPapers();
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Upload failed";
      setUploadProgress(`Error: ${msg}`);
      throw err;
    } finally {
      setUploading(false);
    }
  }

  async function handleUploadUrl(url: string) {
    setUploading(true);
    setUploadProgress("Queuing URL for ingestion...");
    try {
      const res = await fetch("/api/ingest", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ urls: [url] }),
      });
      if (!res.ok) {
        const err = await res.json();
        throw new Error(err.error || "Ingestion failed");
      }
      setUploadProgress("URL queued for ingestion");
      setTimeout(() => setUploadProgress(""), 3000);
      // Immediately refresh papers so the queued item appears in the library
      fetchPapersRef.current?.();
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Ingestion failed";
      setUploadProgress(`Error: ${msg}`);
      throw err;
    } finally {
      setUploading(false);
    }
  }

  async function loadPaper(paper: Paper) {
    if (paper.ingestion_status) return;
    setLoadingPaperId(paper.id);
    try {
      let html: string;
      let toc: unknown[] | null = null;
      let documentId = paper.id;

      if (isOnline) {
        const res = await fetch(`/api/papers?id=${paper.id}`);
        if (!res.ok) throw new Error("Failed to load paper");
        const data = await res.json();
        html = data.html;
        toc = data.toc ?? null;
        documentId = data.documentId;
      } else {
        // Offline: try loading from IndexedDB
        const cached = await loadPaperOffline(paper.id);
        if (!cached) throw new Error("Paper not available offline");
        html = cached.html;
        toc = cached.toc;
      }

      setPaperHtml(html);
      setPaperToc(toc as TocEntry[] | null);
      setActivePaperId(documentId);
      setPaperChatMode(true);
      setMessages([]);
      setActiveChatId(null);
      setChatPanelView("history");
      if (isMobile) {
        setMobileTab("paper");
      } else if (isTablet) {
        setViewMode("reader");
        setTabletShowChat(false);
      } else if (viewMode === "library") {
        setViewMode("browse");
      }
      // In browse mode, stay in browse
      // Refresh paper list so last_opened_at updates
      if (isOnline) fetchPapers();
    } catch (err) {
      setUploadProgress(err instanceof Error ? err.message : "Error loading paper");
    } finally {
      setLoadingPaperId(null);
    }
  }

  function handleSort(field: SortField) {
    if (field === sortField) {
      setSortOrder(sortOrder === "asc" ? "desc" : "asc");
    } else {
      setSortField(field);
      setSortOrder("asc");
    }
  }

  const handleSearch = useCallback((query: string) => {
    setSearchQuery(query);
  }, []);

  const handleSearchExternal = useCallback(async (query: string) => {
    if (!query.trim()) {
      setExternalResults([]);
      return;
    }
    setExternalSearching(true);
    try {
      const res = await fetch(`/api/search-external?q=${encodeURIComponent(query)}`);
      const data = await res.json();
      setExternalResults(data.results || []);
    } catch {
      setExternalResults([]);
    } finally {
      setExternalSearching(false);
    }
  }, []);

  async function handleIngestExternal(pdfUrl: string, title: string) {
    const filename = `${title.replace(/[^a-zA-Z0-9 ]/g, "").slice(0, 60).trim()}.pdf`;
    setUploadProgress(`Queuing "${title}" for ingestion...`);
    try {
      const res = await fetch("/api/ingest", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ urls: [{ url: pdfUrl, filename }] }),
      });
      if (!res.ok) {
        const err = await res.json();
        throw new Error(err.error || "Ingestion failed");
      }
      setUploadProgress(`"${title}" queued for ingestion`);
      setTimeout(() => setUploadProgress(""), 3000);
      // Immediately refresh papers so the queued item appears in the library
      fetchPapersRef.current?.();
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Ingestion failed";
      setUploadProgress(`Error: ${msg}`);
      setTimeout(() => setUploadProgress(""), 5000);
      throw err; // Re-throw so the feed component knows it failed
    }
  }

  async function sendMessage(content: string, highlightText?: string, highlightAnchor?: string, forceNewChat?: boolean, overrideDocumentId?: string) {
    if (paperChatMode && !activePaperId && !overrideDocumentId) return;
    if (!content.trim()) return;

    // Abort any in-flight chat before starting a new one
    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }

    // Bump generation so any still-running async work from a previous call
    // knows it is stale and should not touch state.
    const generation = ++chatGenerationRef.current;
    const isStale = () => chatGenerationRef.current !== generation;

    const userMsg: ChatMessage = { role: "user", content: content.trim() };
    // When forcing a new chat, start fresh instead of using stale state
    const newMessages = forceNewChat ? [userMsg] : [...messages, userMsg];
    setMessages(newMessages);
    setInput("");
    setSending(true);
    setAgentStatus("Thinking...");
    setStreamingContent("");
    setChatPanelView("chat");
    if (highlightAnchor) setCurrentHighlightAnchor(highlightAnchor);

    const chatIdToUse = forceNewChat ? null : activeChatId;
    const documentId = overrideDocumentId ?? (paperChatMode ? activePaperId : null);

    const abortController = new AbortController();
    abortControllerRef.current = abortController;
    // Track accumulated streamed text so we can preserve it on error
    let accumulated = "";

    try {
      const res = await fetch("/api/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          messages: newMessages,
          documentId,
          chatId: chatIdToUse,
          highlightText,
          highlightAnchor,
        }),
        signal: abortController.signal,
      });

      if (!res.ok) {
        const err = await res.json();
        throw new Error(err.error || "Chat request failed");
      }

      const reader = res.body?.getReader();
      if (!reader) throw new Error("No response stream");

      const decoder = new TextDecoder();
      let buffer = "";
      let gotResult = false;
      const STREAM_TIMEOUT_MS = 90_000; // 90s max silence

      while (true) {
        if (isStale()) break; // A newer chat has taken over

        // Race between next chunk and a timeout
        const timeoutPromise = new Promise<{ done: true; value: undefined }>((_, reject) =>
          setTimeout(() => reject(new Error("Response timed out — the AI took too long to respond")), STREAM_TIMEOUT_MS)
        );
        const { done, value } = await Promise.race([reader.read(), timeoutPromise]);
        if (done) break;
        if (isStale()) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        // Keep the last (possibly incomplete) line in the buffer
        buffer = lines.pop() || "";

        for (const line of lines) {
          if (!line.startsWith("data: ")) continue;
          const json = line.slice(6);
          if (!json) continue;

          try {
            const event = JSON.parse(json);
            if (isStale()) break;

            if (event.type === "status") {
              setAgentStatus(event.message);
              // On a new agent step (e.g. after tool use), keep the
              // already-streamed text visible so the user does not see
              // their response vanish mid-read.
              if (event.new_step) {
                if (accumulated.trim()) {
                  accumulated += "\n\n---\n\n";
                }
                setStreamingContent(accumulated);
              }
            } else if (event.type === "text_delta") {
              setAgentStatus(null);
              accumulated += event.text;
              setStreamingContent(accumulated);
            } else if (event.type === "result") {
              gotResult = true;
              if (!isStale()) {
                setMessages([
                  ...newMessages,
                  { role: "assistant", content: event.content },
                ]);
                if (event.chatId) {
                  setActiveChatId(event.chatId);
                }
                fetchChatHistory();
              }
            } else if (event.type === "error") {
              throw new Error(event.message || "Chat failed");
            }
          } catch (parseErr) {
            // If it's our own rethrown error, propagate it
            if (parseErr instanceof Error && parseErr.message !== "Chat failed" && parseErr.message !== json) {
              throw parseErr;
            }
          }
        }
      }

      if (isStale()) return; // Don't touch state — a newer chat owns it now

      // Stream ended without a result event — connection dropped or server error
      if (!gotResult) {
        const partialContent = accumulated.trim();
        setMessages([
          ...newMessages,
          {
            role: "assistant",
            content: partialContent
              ? partialContent + "\n\n*Response interrupted — connection lost*"
              : "The response was interrupted. Please try again.",
          },
        ]);
      }
    } catch (err: unknown) {
      if (isStale()) return; // Don't touch state — a newer chat owns it now

      if (abortController.signal.aborted) {
        // Cancelled by user or by a newer sendMessage call
        const partialContent = accumulated.trim();
        if (partialContent) {
          setMessages([
            ...newMessages,
            {
              role: "assistant",
              content: partialContent + "\n\n*Response stopped*",
            },
          ]);
        } else {
          // Nothing was streamed yet — remove the user message and restore input
          setMessages(newMessages.slice(0, -1));
          setInput(content.trim());
        }
      } else {
        const msg = err instanceof Error ? err.message : "Chat failed";
        // Preserve any content that was already streamed before the error
        const partialContent = accumulated.trim();
        const errorSuffix = `\n\n*Connection lost: ${msg}*`;
        setMessages([
          ...newMessages,
          {
            role: "assistant",
            content: partialContent
              ? partialContent + errorSuffix
              : `Error: ${msg}`,
          },
        ]);
      }
    } finally {
      // Only clean up if this is still the active generation
      if (!isStale()) {
        abortControllerRef.current = null;
        setSending(false);
        setAgentStatus(null);
        setStreamingContent("");
      }
    }
  }

  function handleCancelChat() {
    chatGenerationRef.current++;
    abortControllerRef.current?.abort();
    abortControllerRef.current = null;
  }

  function handleSelectionAction(selectedText: string, action: SelectionAction) {
    // Kill any in-flight chat and invalidate its generation so its callbacks
    // won't overwrite state after we reset it below.
    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }
    chatGenerationRef.current++;
    setSending(false);
    setAgentStatus(null);
    setStreamingContent("");

    const anchor = selectedText.slice(0, 100);
    let prompt: string;
    if (action === "define") {
      prompt = `Define and explain this concept in general terms:\n\n"${selectedText}"`;
    } else if (action === "relevance") {
      prompt = `Using ONLY the paper's content (do NOT search the web), explain the relevance and role of this passage within the paper:\n\n"${selectedText}"`;
    } else if (action === "similar") {
      prompt = `Find the most important papers related to this one. Search my library and the web for recent related work, alternative approaches, and key citations. Focus especially on work related to: "${selectedText}"`;
    } else {
      prompt = `Ingest this paper: ${selectedText}`;
    }
    setPaperChatMode(true);
    setMessages([]);
    setActiveChatId(null);
    setChatPanelView("chat");
    if (isMobile) {
      setMobileTab("chat");
      // Auto-send on mobile, always as a brand new chat
      // Pass documentId directly since setPaperChatMode state update hasn't flushed yet
      sendMessage(prompt, selectedText, anchor, true, activePaperId ?? undefined);
    } else if (isTablet) {
      setTabletShowChat(true);
      setViewMode("reader");
      sendMessage(prompt, selectedText, anchor, true, activePaperId ?? undefined);
    } else {
      setInput(prompt);
      setPendingHighlight({ text: selectedText, anchor });
      setCurrentHighlightAnchor(anchor);
      setViewMode("reader");
    }
  }

  function handleNewChat() {
    // Kill any in-flight chat
    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }
    chatGenerationRef.current++;
    setSending(false);
    setAgentStatus(null);
    setStreamingContent("");
    setMessages([]);
    setActiveChatId(null);
    setCurrentHighlightAnchor(null);
    setChatPanelView("chat");
  }

  function handlePaperChatModeChange(mode: boolean) {
    if (mode && !activePaperId) return;
    setPaperChatMode(mode);
    handleNewChat();
  }

  async function handleLoadChat(chatId: string) {
    try {
      const res = await fetch(`/api/chats/${chatId}/messages`);
      const data = await res.json();
      const msgs: ChatMessage[] = (data.messages || []).map(
        (m: { role: string; content: string }) => ({
          role: m.role as "user" | "assistant",
          content: m.content,
        })
      );
      setMessages(msgs);
      setActiveChatId(chatId);
      setChatPanelView("chat");

      // If no paper is loaded, ensure we're in general chat mode
      if (!activePaperId) {
        setPaperChatMode(false);
      }

      // Track and scroll to this chat's highlight anchor
      const chat = chatHistory.find((c) => c.id === chatId);
      setCurrentHighlightAnchor(chat?.highlight_anchor ?? null);
      if (chat?.highlight_anchor) {
        handleHighlightClick(chat.highlight_anchor);
      }
    } catch {
      /* ignore */
    }
  }

  function handleNewGeneralChat() {
    setShowAllChats(false);
    setMessages([]);
    setActiveChatId(null);
    setPaperChatMode(false);
    setChatPanelView("chat");
    if (isMobile) {
      setMobileTab("chat");
    } else {
      setViewMode("chat");
    }
  }

  async function handleAllChatsSelect(chat: AllChat) {
    setShowAllChats(false);

    // Load chat messages
    try {
      const res = await fetch(`/api/chats/${chat.id}/messages`);
      const data = await res.json();
      const msgs: ChatMessage[] = (data.messages || []).map(
        (m: { role: string; content: string }) => ({
          role: m.role as "user" | "assistant",
          content: m.content,
        })
      );
      setMessages(msgs);
      setActiveChatId(chat.id);
      setChatPanelView("chat");

      if (chat.paper_id) {
        // Paper chat — load the paper and switch to reader
        setPaperChatMode(true);
        setLoadingPaperId(chat.paper_id);
        try {
          const paperRes = await fetch(`/api/papers?id=${chat.paper_id}`);
          if (paperRes.ok) {
            const paperData = await paperRes.json();
            setPaperHtml(paperData.html);
            setPaperToc(paperData.toc ?? null);
            setActivePaperId(paperData.documentId);
          }
        } finally {
          setLoadingPaperId(null);
        }
        if (isMobile) {
          setMobileTab("chat");
        } else if (isTablet) {
          setViewMode("reader");
          setTabletShowChat(true);
        } else {
          setViewMode("reader");
        }
      } else {
        // General chat
        setPaperChatMode(false);
        if (isMobile) {
          setMobileTab("chat");
        } else {
          setViewMode("chat");
        }
      }
    } catch {
      /* ignore */
    }
  }

  async function handleAllDiagramsSelect(diagram: DiagramItem) {
    setShowAllDiagrams(false);

    // Load the chat if there is one
    if (diagram.chat_id) {
      try {
        const res = await fetch(`/api/chats/${diagram.chat_id}/messages`);
        const data = await res.json();
        const msgs: ChatMessage[] = (data.messages || []).map(
          (m: { role: string; content: string }) => ({
            role: m.role as "user" | "assistant",
            content: m.content,
          })
        );
        setMessages(msgs);
        setActiveChatId(diagram.chat_id);
        setChatPanelView("chat");
      } catch {
        /* ignore */
      }
    }

    if (diagram.paper_id) {
      setPaperChatMode(true);
      setLoadingPaperId(diagram.paper_id);
      try {
        const paperRes = await fetch(`/api/papers?id=${diagram.paper_id}`);
        if (paperRes.ok) {
          const paperData = await paperRes.json();
          setPaperHtml(paperData.html);
          setPaperToc(paperData.toc ?? null);
          setActivePaperId(paperData.documentId);
        }
      } finally {
        setLoadingPaperId(null);
      }
      if (isMobile) {
        setMobileTab("chat");
      } else if (isTablet) {
        setViewMode("reader");
        setTabletShowChat(true);
      } else {
        setViewMode("reader");
      }
    } else if (diagram.chat_id) {
      setPaperChatMode(false);
      if (isMobile) {
        setMobileTab("chat");
      } else if (isTablet) {
        setViewMode("reader");
        setTabletShowChat(true);
      } else {
        setViewMode("reader");
      }
    }
  }

  function handleScrollToFigure(captionText: string) {
    setShowFigures(false);
    if (isMobile) {
      setMobileTab("paper");
    }
    // Use existing scroll-to-text mechanism
    setTimeout(() => {
      handleHighlightClick(captionText);
    }, 200);
  }

  function handleHighlightClick(anchor: string) {
    // Send a postMessage to the iframe to scroll to/highlight the text
    const iframe = document.querySelector("iframe");
    if (iframe?.contentWindow) {
      iframe.contentWindow.postMessage(
        { type: "scroll-to-text", text: anchor },
        "*"
      );
    }
  }

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (pendingHighlight) {
      sendMessage(input, pendingHighlight.text, pendingHighlight.anchor, true);
      setPendingHighlight(null);
    } else {
      sendMessage(input);
    }
  }

  function goToLibrary() {
    if (isTablet) {
      // On tablet, always go to full-screen library (no split browse mode)
      setViewMode("library");
    } else if (paperHtml && activePaperId) {
      // Paper is open: slide into browse mode keeping the paper visible
      setViewMode("browse");
    } else {
      // No paper open: go to full-screen library
      setViewMode("library");
    }
  }

  function goToFullLibrary() {
    setViewMode("library");
    setPaperHtml(null);
    setPaperToc(null);
    setActivePaperId(null);
    setMessages([]);
    setActiveChatId(null);
  }

  function goToFeed() {
    if (isMobile) {
      setMobileTab("feed");
    } else {
      setViewMode("feed");
    }
  }

  function toggleBrowse() {
    setViewMode(viewMode === "browse" ? "reader" : "browse");
  }

  async function handleToggleOffline(paper: Paper) {
    if (isOfflineSaved(paper.id)) {
      await removePaperOffline(paper.id);
    } else {
      // Need to fetch the paper HTML to save it offline
      try {
        let html: string;
        let toc: unknown[] | null = null;
        if (activePaperId === paper.id && paperHtml) {
          // Already loaded — use current data
          html = paperHtml;
          toc = paperToc;
        } else {
          const res = await fetch(`/api/papers?id=${paper.id}`);
          if (!res.ok) throw new Error("Failed to fetch paper for offline");
          const data = await res.json();
          html = data.html;
          toc = data.toc ?? null;
        }
        await savePaperOffline(paper, html, toc);
      } catch (err) {
        setUploadProgress(err instanceof Error ? err.message : "Failed to save offline");
      }
    }
  }

  async function handleDeletePaper(paperId: string) {
    try {
      let res = await fetch(`/api/papers?id=${paperId}`, { method: "DELETE" });
      if (res.status === 404) {
        // Not in papers table — try deleting from ingestion queue
        res = await fetch(`/api/ingest?id=${paperId}`, { method: "DELETE" });
      }
      if (!res.ok) {
        const err = await res.json();
        throw new Error(err.error || "Delete failed");
      }
      // If the deleted paper is currently active, clear it
      if (activePaperId === paperId) {
        setPaperHtml(null);
        setPaperToc(null);
        setActivePaperId(null);
        setMessages([]);
        setActiveChatId(null);
        if (viewMode !== "library" && viewMode !== "feed") setViewMode("library");
      }
      // Also remove offline copy if it exists
      if (isOfflineSaved(paperId)) removePaperOffline(paperId).catch(() => {});
      fetchPapers();
    } catch {
      /* ignore */
    }
  }

  // ─── PDF highlights from chat history ─────────────────────────
  const pdfHighlights = useMemo(
    () =>
      chatHistory
        .filter((c) => c.highlight_anchor)
        .map((c) => ({ text: c.highlight_anchor!, chatId: c.id })),
    [chatHistory]
  );

  const handleChatHighlightClick = useCallback(
    (chatId: string) => {
      if (isMobile) {
        setMobileTab("chat");
      } else if (isTablet) {
        setTabletShowChat(true);
        setViewMode("reader");
      } else {
        setViewMode("reader");
      }
      handleLoadChat(chatId);
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [chatHistory, isMobile, isTablet]
  );

  // ─── Render ────────────────────────────────────────────────────

  // Auth loading state
  if (!authLoaded) {
    return (
      <div style={{
        minHeight: "100dvh",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        background: "var(--bg-primary)",
        color: "var(--text-secondary)",
        fontSize: "14px",
      }}>
        Loading...
      </div>
    );
  }

  // Auth gate — show login form if not authenticated (public network)
  if (!authenticated) {
    return <LoginForm onLogin={handleLogin} hasUsers={hasUsers} />;
  }

  // Admin panel (desktop only, local network only)
  if (showAdmin && isLocalNetwork && !isMobile && !isTablet) {
    return <AdminPanel onClose={() => setShowAdmin(false)} />;
  }

  const uploadModal = (
    <UploadModal open={uploadModalOpen} onClose={() => setUploadModalOpen(false)}
      onUploadFile={handleUpload} onUploadUrl={handleUploadUrl} />
  );

  const resizeHandleWidth = isTablet ? 24 : 6;
  const panelMinSize = isTablet ? 20 : 30;

  // ─── Mobile render: single-view with bottom tab bar ──────────
  if (isMobile) {
    return (
      <div className="mobile-app-container">
        {uploadModal}
        <div className="mobile-content-area" style={mobileTab === "chat" ? { overflowY: "hidden" } : undefined}>
          {mobileTab === "feed" && (
            <ResearchFeed
              topics={feedTopics}
              results={feedResults}
              loading={feedLoading}
              refreshing={feedRefreshing}
              activeTopic={feedActiveTopic}
              onTopicChange={setFeedActiveTopic}
              onRefresh={() => fetchFeed(true)}
              onIngest={handleIngestExternal}
              onGoToLibrary={() => { fetchPapersRef.current?.(); setMobileTab("library"); }}
              onOpenUpload={() => setUploadModalOpen(true)}
              device="mobile"
              lastRefreshed={feedLastRefreshed}
            />
          )}
          {mobileTab === "library" && (
            <LibraryView
              papers={papers}
              onSelectPaper={loadPaper}
              onOpenUpload={() => setUploadModalOpen(true)}
              uploading={uploading}
              uploadProgress={uploadProgress}
              selectedPaperId={activePaperId}
              loadingPaperId={loadingPaperId}
              sortField={sortField}
              sortOrder={sortOrder}
              onSort={handleSort}
              onSearch={handleSearch}
              queueSummary={queueSummary}
              apiErrors={apiErrors}
              onDismissApiErrors={() => setApiErrors([])}
              onRetryFailed={handleRetryFailed}
              onClearCompleted={handleClearCompleted}
              onDeletePaper={handleDeletePaper}
              externalResults={externalResults}
              externalSearching={externalSearching}
              onSearchExternal={handleSearchExternal}
              onIngestExternal={handleIngestExternal}
              mobile
              offlineIds={offlineIds}
              onToggleOffline={handleToggleOffline}
              offlineSaving={offlineSaving}
              isOnline={isOnline}
            />
          )}
          {mobileTab === "paper" && (
            <div style={{ height: "100%", background: "var(--paper-bg)", position: "relative" }}>
              {paperHtml ? (
                <>
                  <MarkdownReader
                    html={paperHtml}
                    onSelectionAction={handleSelectionAction}
                    darkMode={darkMode}
                    highlights={pdfHighlights}
                    onChatHighlightClick={handleChatHighlightClick}
                    mobile
                    fontScale={fontScale}
                    onFontScaleChange={handleFontScaleChange}
                    scrollToHeadingId={scrollToHeadingId}
                    onScrollComplete={handleScrollComplete}
                    onFigureClick={handleFigureClick}
                  />
                  {paperToc && paperToc.length > 0 && (
                    <TableOfContents
                      entries={paperToc}
                      onNavigate={handleTocNavigate}
                      darkMode={darkMode}
                      mobile
                    />
                  )}
                  {/* Figures button — positioned top-right on mobile paper view */}
                  {activePaperId && (
                    <button
                      onClick={() => setShowFigures(true)}
                      data-tooltip="View figures"
                      style={{
                        position: "absolute",
                        top: 8,
                        right: 8,
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
                        <rect x="3" y="3" width="18" height="18" rx="2" ry="2" />
                        <circle cx="8.5" cy="8.5" r="1.5" />
                        <polyline points="21 15 16 10 5 21" />
                      </svg>
                      Figs
                    </button>
                  )}
                </>
              ) : (
                <div style={{
                  display: "flex", alignItems: "center", justifyContent: "center",
                  height: "100%", color: "var(--text-secondary)", fontSize: "14px",
                }}>
                  Select a paper from the Library tab
                </div>
              )}
            </div>
          )}
          {mobileTab === "chat" && (
            <div style={{ height: "100%", overflow: "hidden" }}>
              <ChatPanel
                messages={messages}
                sending={sending}
                agentStatus={agentStatus}
                streamingContent={streamingContent}
                input={input}
                onInputChange={setInput}
                onSubmit={handleSubmit}
                onCancel={handleCancelChat}
                onNewChat={handleNewChat}
                chatHistory={chatHistory}
                onLoadChat={handleLoadChat}
                onHighlightClick={handleHighlightClick}
                activeChatId={activeChatId}
                panelView={chatPanelView}
                onPanelViewChange={setChatPanelView}
                mobile
                chatFontScale={chatFontScale}
                onChatFontScaleChange={handleChatFontScaleChange}
                paperChatMode={paperChatMode}
                onPaperChatModeChange={handlePaperChatModeChange}
                paperLoaded={!!paperHtml}
                activePaperTitle={activePaperTitle}
                onSelectionAction={handleSelectionAction}
                onGoToAllChats={() => setShowAllChats(true)}
                onGoToAllDiagrams={() => setShowAllDiagrams(true)}
                currentHighlightAnchor={currentHighlightAnchor}
                onGoToPaperHighlight={(anchor) => {
                  setMobileTab("paper");
                  // Wait for iframe to signal it's ready (scripts loaded),
                  // then send the scroll command
                  let scrolled = false;
                  const cleanup = () => window.removeEventListener("message", onReady);
                  const doScroll = () => {
                    if (scrolled) return;
                    const iframe = document.querySelector("iframe");
                    if (iframe?.contentWindow) {
                      scrolled = true;
                      iframe.contentWindow.postMessage({ type: "scroll-to-text", text: anchor }, "*");
                      cleanup();
                    }
                  };
                  const onReady = (e: MessageEvent) => {
                    if (e.data?.type === "iframe-ready") {
                      // Small delay to ensure all listeners are registered
                      setTimeout(doScroll, 50);
                    }
                  };
                  window.addEventListener("message", onReady);
                  // Safety timeout to clean up listener
                  setTimeout(() => { cleanup(); doScroll(); }, 5000);
                }}
              />
            </div>
          )}
          {mobileTab === "settings" && (
            <div className="settings-panel">
              <div className="settings-header">
                <h2>Settings</h2>
              </div>
              <div className="settings-section">
                <div className="settings-section-title">Appearance</div>
                <div className="settings-row">
                  <span className="settings-row-label">Dark Mode</span>
                  <button
                    className={`settings-toggle ${darkMode ? "active" : ""}`}
                    onClick={() => setDarkMode(!darkMode)}
                  />
                </div>
              </div>
              <div className="settings-section">
                <div className="settings-section-title">Report a Bug</div>
                <BugReportForm darkMode={darkMode} />
              </div>
              {/* Account section */}
              <div className="settings-section">
                <div className="settings-section-title">Account</div>
                {authUsername && (
                  <div className="settings-row">
                    <span className="settings-row-label">Signed in as</span>
                    <span style={{ fontSize: "14px", color: "var(--text-primary)", fontWeight: 500 }}>{authUsername}</span>
                  </div>
                )}
                <div className="settings-row">
                  <span className="settings-row-label">Sign out</span>
                  <button
                    onClick={handleLogout}
                    style={{
                      background: "transparent",
                      border: "1px solid rgba(239,68,68,0.3)",
                      borderRadius: "8px",
                      padding: "6px 14px",
                      fontSize: "13px",
                      color: "#ef4444",
                      cursor: "pointer",
                      fontWeight: 500,
                    }}
                  >
                    Sign Out
                  </button>
                </div>
              </div>
            </div>
          )}
        </div>
        {showAllChats && (
          <div style={{
            position: "fixed",
            top: 0,
            left: 0,
            right: 0,
            bottom: 0,
            zIndex: 100,
            background: "var(--bg-primary)",
          }}>
            <AllChatsView
              onSelectChat={handleAllChatsSelect}
              onClose={() => setShowAllChats(false)}
              onNewGeneralChat={handleNewGeneralChat}
              mobile
            />
          </div>
        )}
        {showAllDiagrams && (
          <div style={{
            position: "fixed",
            top: 0,
            left: 0,
            right: 0,
            bottom: 0,
            zIndex: 100,
            background: "var(--bg-primary)",
          }}>
            <AllDiagramsView
              onClose={() => setShowAllDiagrams(false)}
              onSelectDiagram={handleAllDiagramsSelect}
              mobile
            />
          </div>
        )}
        {showFigures && activePaperId && (
          <FigureViewer
            paperId={activePaperId}
            darkMode={darkMode}
            mobile
            onClose={() => { setShowFigures(false); setInitialFigureSrc(null); }}
            onScrollToFigure={handleScrollToFigure}
            initialFigureSrc={initialFigureSrc}
          />
        )}
        <MobileTabBar
          activeTab={mobileTab}
          onTabChange={setMobileTab}
          paperLoaded={!!paperHtml}
        />
      </div>
    );
  }

  // ─── Desktop & Tablet render paths ───────────────────────────

  // All Chats view (full screen, desktop/tablet)
  if (showAllChats) {
    return (
      <div style={{ height: "100vh", position: "relative", overflow: "hidden" }}>
        {uploadModal}
        <AllChatsView
          onSelectChat={handleAllChatsSelect}
          onClose={() => setShowAllChats(false)}
          onNewGeneralChat={handleNewGeneralChat}
        />
      </div>
    );
  }

  // All Diagrams view (full screen, desktop/tablet)
  if (showAllDiagrams) {
    return (
      <div style={{ height: "100vh", position: "relative", overflow: "hidden" }}>
        {uploadModal}
        <AllDiagramsView
          onClose={() => setShowAllDiagrams(false)}
          onSelectDiagram={handleAllDiagramsSelect}
        />
      </div>
    );
  }

  // Figures view (full screen overlay, desktop/tablet)
  if (showFigures && activePaperId) {
    return (
      <div style={{ height: "100vh", position: "relative", overflow: "hidden" }}>
        <FigureViewer
          paperId={activePaperId}
          darkMode={darkMode}
          onClose={() => { setShowFigures(false); setInitialFigureSrc(null); }}
          onScrollToFigure={handleScrollToFigure}
          initialFigureSrc={initialFigureSrc}
        />
      </div>
    );
  }

  // Feed view (full screen)
  if (viewMode === "feed") {
    return (
      <div style={{ height: "100vh", position: "relative", overflow: "hidden" }}>
        {uploadModal}
        <ResearchFeed
          topics={feedTopics}
          results={feedResults}
          loading={feedLoading}
          refreshing={feedRefreshing}
          activeTopic={feedActiveTopic}
          onTopicChange={setFeedActiveTopic}
          onRefresh={() => fetchFeed(true)}
          onIngest={handleIngestExternal}
          onGoToLibrary={() => { fetchPapersRef.current?.(); setViewMode("library"); }}
          onOpenUpload={() => setUploadModalOpen(true)}
          device={isTablet ? "tablet" : "desktop"}
          lastRefreshed={feedLastRefreshed}
        />
      </div>
    );
  }

  // Library view (full screen)
  if (viewMode === "library") {
    return (
      <div style={{ height: "100vh", position: "relative", overflow: "hidden" }}>
        {uploadModal}
        <LibraryView
          papers={papers}
          onSelectPaper={loadPaper}
          onOpenUpload={() => setUploadModalOpen(true)}
          uploading={uploading}
          uploadProgress={uploadProgress}
          selectedPaperId={activePaperId}
          loadingPaperId={loadingPaperId}
          sortField={sortField}
          sortOrder={sortOrder}
          onSort={handleSort}
          onSearch={handleSearch}
          queueSummary={queueSummary}
          onRetryFailed={handleRetryFailed}
          onClearCompleted={handleClearCompleted}
          onDeletePaper={handleDeletePaper}
          externalResults={externalResults}
          externalSearching={externalSearching}
          onSearchExternal={handleSearchExternal}
          onIngestExternal={handleIngestExternal}
          onGoToFeed={goToFeed}
          onGoToAllChats={() => setShowAllChats(true)}
          onGoToAllDiagrams={() => setShowAllDiagrams(true)}
          darkMode={darkMode}
          authUsername={authUsername}
          onLogout={handleLogout}
          onAdmin={isLocalNetwork ? () => setShowAdmin(true) : undefined}
          offlineIds={offlineIds}
          onToggleOffline={handleToggleOffline}
          offlineSaving={offlineSaving}
          isOnline={isOnline}
        />
      </div>
    );
  }

  // General chat view (full-screen chat, no paper)
  if (viewMode === "chat") {
    return (
      <div style={{ height: "100vh", position: "relative", overflow: "hidden", display: "flex", flexDirection: "column" }}>
        {uploadModal}
        <ChatPanel
          messages={messages}
          sending={sending}
          agentStatus={agentStatus}
          streamingContent={streamingContent}
          input={input}
          onInputChange={setInput}
          onSubmit={handleSubmit}
          onCancel={handleCancelChat}
          onNewChat={handleNewChat}
          chatHistory={chatHistory}
          onLoadChat={handleLoadChat}
          onHighlightClick={handleHighlightClick}
          activeChatId={activeChatId}
          panelView={chatPanelView}
          onPanelViewChange={setChatPanelView}
          onLibrary={goToLibrary}
          chatFontScale={chatFontScale}
          onChatFontScaleChange={handleChatFontScaleChange}
          paperChatMode={false}
          onPaperChatModeChange={handlePaperChatModeChange}
          paperLoaded={false}
          onSelectionAction={handleSelectionAction}
          onGoToAllChats={() => setShowAllChats(true)}
          onGoToAllDiagrams={() => setShowAllDiagrams(true)}
          currentHighlightAnchor={currentHighlightAnchor}
        />
      </div>
    );
  }

  // Reader view (PDF left | Chat right)
  if (viewMode === "reader") {
    // ── Tablet: full-screen PDF or Chat (no split panels) ──────
    if (isTablet) {
      return (
        <div style={{ height: "100vh", position: "relative", overflow: "hidden" }}>
          {uploadModal}
          {tabletShowChat ? (
            /* Full-screen Chat */
            <div style={{ height: "100%", display: "flex", flexDirection: "column" }}>
              <ChatPanel
                messages={messages}
                sending={sending}
                agentStatus={agentStatus}
                streamingContent={streamingContent}
                input={input}
                onInputChange={setInput}
                onSubmit={handleSubmit}
                onCancel={handleCancelChat}
                onNewChat={handleNewChat}
                chatHistory={chatHistory}
                onLoadChat={handleLoadChat}
                onHighlightClick={(anchor) => {
                  setTabletShowChat(false);
                  handleHighlightClick(anchor);
                }}
                activeChatId={activeChatId}
                panelView={chatPanelView}
                onPanelViewChange={setChatPanelView}
                onLibrary={() => setTabletShowChat(false)}
                onLibraryLabel="Paper"
                chatFontScale={chatFontScale}
                onChatFontScaleChange={handleChatFontScaleChange}
                paperChatMode={paperChatMode}
                onPaperChatModeChange={handlePaperChatModeChange}
                paperLoaded={!!paperHtml}
                activePaperTitle={activePaperTitle}
                onSelectionAction={handleSelectionAction}
                onGoToAllChats={() => setShowAllChats(true)}
                onGoToAllDiagrams={() => setShowAllDiagrams(true)}
                currentHighlightAnchor={currentHighlightAnchor}
              />
            </div>
          ) : (
            /* Full-screen PDF */
            <div style={{ height: "100%", background: "var(--paper-bg)", position: "relative" }}>
              {paperHtml ? (
                <>
                  <MarkdownReader
                    html={paperHtml}
                    onSelectionAction={handleSelectionAction}
                    darkMode={darkMode}
                    highlights={pdfHighlights}
                    onChatHighlightClick={handleChatHighlightClick}
                    fontScale={fontScale}
                    onFontScaleChange={handleFontScaleChange}
                    scrollToHeadingId={scrollToHeadingId}
                    onScrollComplete={handleScrollComplete}
                    onFigureClick={handleFigureClick}
                  />
                  {paperToc && paperToc.length > 0 && (
                    <TableOfContents
                      entries={paperToc}
                      onNavigate={handleTocNavigate}
                      darkMode={darkMode}
                    />
                  )}
                </>
              ) : (
                <div style={{
                  display: "flex", alignItems: "center", justifyContent: "center",
                  height: "100%", color: "var(--text-secondary)", fontSize: "14px",
                }}>
                  Select a paper from the Library
                </div>
              )}
              {/* Floating top bar */}
              <div style={{
                position: "absolute", top: 12, left: 12, right: 12, zIndex: 20,
                display: "flex", justifyContent: "space-between", alignItems: "center",
                pointerEvents: "none",
              }}>
                <button
                  onClick={goToLibrary}
                  style={{
                    pointerEvents: "auto",
                    background: "var(--bg-secondary)", border: "1px solid var(--border)",
                    borderRadius: "10px", padding: "8px 14px", cursor: "pointer",
                    color: "var(--text-primary)", display: "flex", alignItems: "center", gap: 6,
                    boxShadow: "0 2px 8px rgba(0,0,0,0.12)", fontSize: "14px", fontWeight: 500,
                  }}
                >
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <polyline points="15 18 9 12 15 6" />
                  </svg>
                  Library
                </button>
                <div style={{ display: "flex", gap: 8, pointerEvents: "auto" }}>
                  <button
                    onClick={() => setShowAllChats(true)}
                    className="instant-tooltip"
                    data-tip="All Chats"
                    style={{
                      background: "var(--bg-secondary)", border: "1px solid var(--border)",
                      borderRadius: "10px", padding: "8px 10px", cursor: "pointer",
                      color: "var(--text-secondary)", display: "flex", alignItems: "center",
                      boxShadow: "0 2px 8px rgba(0,0,0,0.12)",
                    }}
                  >
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                      <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
                    </svg>
                  </button>
                  <button
                    onClick={() => setShowAllDiagrams(true)}
                    className="instant-tooltip"
                    data-tip="Diagrams"
                    style={{
                      background: "var(--bg-secondary)", border: "1px solid var(--border)",
                      borderRadius: "10px", padding: "8px 10px", cursor: "pointer",
                      color: "var(--text-secondary)", display: "flex", alignItems: "center",
                      boxShadow: "0 2px 8px rgba(0,0,0,0.12)",
                    }}
                  >
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                      <rect x="3" y="3" width="18" height="18" rx="2" ry="2" />
                      <line x1="3" y1="9" x2="21" y2="9" />
                      <line x1="9" y1="21" x2="9" y2="9" />
                    </svg>
                  </button>
                  {activePaperId && (
                    <button
                      onClick={() => setShowFigures(true)}
                      data-tooltip="Figures"
                      style={{
                        background: "var(--bg-secondary)", border: "1px solid var(--border)",
                        borderRadius: "10px", padding: "8px 10px", cursor: "pointer",
                        color: "var(--text-secondary)", display: "flex", alignItems: "center",
                        boxShadow: "0 2px 8px rgba(0,0,0,0.12)",
                      }}
                    >
                      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <rect x="3" y="3" width="18" height="18" rx="2" ry="2" />
                        <circle cx="8.5" cy="8.5" r="1.5" />
                        <polyline points="21 15 16 10 5 21" />
                      </svg>
                    </button>
                  )}
                  <button
                    onClick={() => setDarkMode(!darkMode)}
                    data-tooltip={darkMode ? "Light mode" : "Dark mode"}
                    style={{
                      background: "var(--bg-secondary)", border: "1px solid var(--border)",
                      borderRadius: "10px", padding: "8px 10px", cursor: "pointer",
                      color: "var(--text-secondary)", display: "flex", alignItems: "center",
                      boxShadow: "0 2px 8px rgba(0,0,0,0.12)",
                    }}
                  >
                    {darkMode ? (
                      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <circle cx="12" cy="12" r="5" />
                        <line x1="12" y1="1" x2="12" y2="3" /><line x1="12" y1="21" x2="12" y2="23" />
                        <line x1="4.22" y1="4.22" x2="5.64" y2="5.64" /><line x1="18.36" y1="18.36" x2="19.78" y2="19.78" />
                        <line x1="1" y1="12" x2="3" y2="12" /><line x1="21" y1="12" x2="23" y2="12" />
                        <line x1="4.22" y1="19.78" x2="5.64" y2="18.36" /><line x1="18.36" y1="5.64" x2="19.78" y2="4.22" />
                      </svg>
                    ) : (
                      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
                      </svg>
                    )}
                  </button>
                  {isLocalNetwork && !isTablet && (
                    <button
                      onClick={() => setShowAdmin(true)}
                      data-tooltip="User management"
                      style={{
                        background: "var(--bg-secondary)", border: "1px solid var(--border)",
                        borderRadius: "10px", padding: "8px 10px", cursor: "pointer",
                        color: "var(--text-secondary)", display: "flex", alignItems: "center",
                        boxShadow: "0 2px 8px rgba(0,0,0,0.12)",
                      }}
                    >
                      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" />
                        <circle cx="9" cy="7" r="4" />
                        <path d="M23 21v-2a4 4 0 0 0-3-3.87" />
                        <path d="M16 3.13a4 4 0 0 1 0 7.75" />
                      </svg>
                    </button>
                  )}
                  {authUsername && !isTablet && (
                    <button
                      onClick={handleLogout}
                      data-tooltip={`Sign out (${authUsername})`}
                      style={{
                        background: "var(--bg-secondary)", border: "1px solid var(--border)",
                        borderRadius: "10px", padding: "8px 10px", cursor: "pointer",
                        color: "var(--text-secondary)", display: "flex", alignItems: "center",
                        boxShadow: "0 2px 8px rgba(0,0,0,0.12)",
                      }}
                    >
                      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
                        <polyline points="16 17 21 12 16 7" />
                        <line x1="21" y1="12" x2="9" y2="12" />
                      </svg>
                    </button>
                  )}
                  {paperHtml && (
                    <button
                      onClick={() => { setTabletShowChat(true); setChatPanelView("chat"); }}
                      style={{
                        background: "var(--accent)", border: "none",
                        borderRadius: "10px", padding: "8px 14px", cursor: "pointer",
                        color: "#fff", display: "flex", alignItems: "center", gap: 6,
                        boxShadow: "0 2px 8px rgba(0,0,0,0.15)", fontSize: "14px", fontWeight: 500,
                      }}
                    >
                      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
                      </svg>
                      Chat
                    </button>
                  )}
                </div>
              </div>
            </div>
          )}
        </div>
      );
    }

    // ── Desktop: split panels (PDF | Chat) ─────────────────────
    return (
      <div style={{ height: "100vh", position: "relative", overflow: "hidden" }}>
        {uploadModal}
        <PanelGroup direction="horizontal" style={{ height: "100%", overflow: "hidden" }}>
          <Panel
            ref={readerPdfPanelRef}
            defaultSize={50}
            minSize={panelMinSize}
            collapsible={true}
            collapsedSize={0}
            onCollapse={() => setReaderPdfCollapsed(true)}
            onExpand={() => setReaderPdfCollapsed(false)}
          >
            <div
              style={{ height: "100%", background: "var(--paper-bg)", position: "relative" }}
            >
              {paperHtml && (
                <>
                  <MarkdownReader
                    html={paperHtml}
                    onSelectionAction={handleSelectionAction}
                    darkMode={darkMode}
                    highlights={pdfHighlights}
                    onChatHighlightClick={handleChatHighlightClick}
                    fontScale={fontScale}
                    onFontScaleChange={handleFontScaleChange}
                    scrollToHeadingId={scrollToHeadingId}
                    onScrollComplete={handleScrollComplete}
                    onFigureClick={handleFigureClick}
                  />
                  {paperToc && paperToc.length > 0 && (
                    <TableOfContents
                      entries={paperToc}
                      onNavigate={handleTocNavigate}
                      darkMode={darkMode}
                    />
                  )}
                  {/* Top-right button group: Figs + Dark mode */}
                  <div style={{
                    position: "absolute",
                    top: 12,
                    right: 12,
                    zIndex: 15,
                    display: "flex",
                    gap: 6,
                    alignItems: "center",
                  }}>
                    {activePaperId && (
                      <button
                        onClick={() => setShowFigures(true)}
                        title="View figures"
                        style={{
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
                          <rect x="3" y="3" width="18" height="18" rx="2" ry="2" />
                          <circle cx="8.5" cy="8.5" r="1.5" />
                          <polyline points="21 15 16 10 5 21" />
                        </svg>
                        Figs
                      </button>
                    )}
                    <button
                      onClick={() => setDarkMode(!darkMode)}
                      title={darkMode ? "Light mode" : "Dark mode"}
                      style={{
                        background: darkMode ? "rgba(30,30,30,0.9)" : "rgba(255,255,255,0.9)",
                        border: `1px solid ${darkMode ? "#3f3f46" : "#d4d4d8"}`,
                        borderRadius: "10px",
                        padding: "6px",
                        cursor: "pointer",
                        color: darkMode ? "#e4e4e7" : "#18181b",
                        boxShadow: "0 2px 8px rgba(0,0,0,0.15)",
                        backdropFilter: "blur(8px)",
                        WebkitBackdropFilter: "blur(8px)",
                        display: "flex",
                        alignItems: "center",
                      }}
                    >
                      {darkMode ? (
                        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                          <circle cx="12" cy="12" r="5" />
                          <line x1="12" y1="1" x2="12" y2="3" /><line x1="12" y1="21" x2="12" y2="23" />
                          <line x1="4.22" y1="4.22" x2="5.64" y2="5.64" /><line x1="18.36" y1="18.36" x2="19.78" y2="19.78" />
                          <line x1="1" y1="12" x2="3" y2="12" /><line x1="21" y1="12" x2="23" y2="12" />
                          <line x1="4.22" y1="19.78" x2="5.64" y2="18.36" /><line x1="18.36" y1="5.64" x2="19.78" y2="4.22" />
                        </svg>
                      ) : (
                        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                          <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
                        </svg>
                      )}
                    </button>
                  </div>
                </>
              )}
            </div>
          </Panel>

          <PanelResizeHandle
            style={{
              width: resizeHandleWidth,
              background: "var(--resize-handle)",
              cursor: "col-resize",
            }}
          />

          <Panel
            ref={readerChatPanelRef}
            defaultSize={50}
            minSize={25}
            collapsible={true}
            collapsedSize={0}
            onCollapse={() => setReaderChatCollapsed(true)}
            onExpand={() => setReaderChatCollapsed(false)}
          >
            <ChatPanel
              messages={messages}
              sending={sending}
              agentStatus={agentStatus}
              streamingContent={streamingContent}
              input={input}
              onInputChange={setInput}
              onSubmit={handleSubmit}
              onCancel={handleCancelChat}
              onNewChat={handleNewChat}
              chatHistory={chatHistory}
              onLoadChat={handleLoadChat}
              onHighlightClick={handleHighlightClick}
              activeChatId={activeChatId}
              panelView={chatPanelView}
              onPanelViewChange={setChatPanelView}
              onLibrary={goToLibrary}
              chatFontScale={chatFontScale}
              onChatFontScaleChange={handleChatFontScaleChange}
              paperChatMode={paperChatMode}
              onPaperChatModeChange={handlePaperChatModeChange}
              paperLoaded={!!paperHtml}
              onSelectionAction={handleSelectionAction}
              onGoToAllChats={() => setShowAllChats(true)}
              onGoToAllDiagrams={() => setShowAllDiagrams(true)}
              currentHighlightAnchor={currentHighlightAnchor}
            />
          </Panel>
        </PanelGroup>
        <CollapseHandle
          side="left"
          visible={readerPdfCollapsed}
          onClick={() => readerPdfPanelRef.current?.expand()}
          label="Show PDF"
        />
        <CollapseHandle
          side="right"
          visible={readerChatCollapsed}
          onClick={() => readerChatPanelRef.current?.expand()}
          label="Show Chat"
        />
      </div>
    );
  }

  // Browse view (Library left | PDF right) — desktop only
  return (
    <div style={{ height: "100vh", position: "relative", overflow: "hidden" }}>
      {uploadModal}
      <PanelGroup direction="horizontal" style={{ height: "100%", overflow: "hidden" }}>
        <Panel
          ref={browseLibraryPanelRef}
          defaultSize={50}
          minSize={20}
          collapsible={true}
          collapsedSize={0}
          onCollapse={() => setBrowseLibraryCollapsed(true)}
          onExpand={() => setBrowseLibraryCollapsed(false)}
        >
          <LibraryView
            papers={papers}
            onSelectPaper={loadPaper}
            onOpenUpload={() => setUploadModalOpen(true)}
            uploading={uploading}
            uploadProgress={uploadProgress}
            selectedPaperId={activePaperId}
            loadingPaperId={loadingPaperId}
            sortField={sortField}
            sortOrder={sortOrder}
            onSort={handleSort}
            onSearch={handleSearch}
            queueSummary={queueSummary}
            onRetryFailed={handleRetryFailed}
            onClearCompleted={handleClearCompleted}
            onToggleReader={toggleBrowse}
            onDeletePaper={handleDeletePaper}
            externalResults={externalResults}
            externalSearching={externalSearching}
            onSearchExternal={handleSearchExternal}
            onIngestExternal={handleIngestExternal}
            onGoToFeed={goToFeed}
            onGoToAllChats={() => setShowAllChats(true)}
            onGoToAllDiagrams={() => setShowAllDiagrams(true)}
            darkMode={darkMode}
            offlineIds={offlineIds}
            onToggleOffline={handleToggleOffline}
            offlineSaving={offlineSaving}
            isOnline={isOnline}
          />
        </Panel>

        <PanelResizeHandle
          style={{
            width: resizeHandleWidth,
            background: "var(--resize-handle)",
            cursor: "col-resize",
          }}
        />

        <Panel
          ref={browsePdfPanelRef}
          defaultSize={50}
          minSize={panelMinSize}
          collapsible={true}
          collapsedSize={0}
          onCollapse={() => setBrowsePdfCollapsed(true)}
          onExpand={() => setBrowsePdfCollapsed(false)}
        >
          <div
            style={{ height: "100%", background: "var(--paper-bg)", position: "relative" }}
            onMouseEnter={(e) => {
              e.currentTarget.querySelectorAll<HTMLElement>("[data-close-btn],[data-chat-btn]").forEach(b => b.style.opacity = "1");
            }}
            onMouseLeave={(e) => {
              e.currentTarget.querySelectorAll<HTMLElement>("[data-close-btn],[data-chat-btn]").forEach(b => b.style.opacity = "0");
            }}
          >
            {/* Hoverable close X on paper panel */}
            <button
              data-close-btn
              onClick={goToFullLibrary}
              data-tooltip="Close paper"
              style={{
                position: "absolute", top: 10, right: 10, zIndex: 10,
                opacity: 0, transition: "opacity 0.15s ease",
                background: "var(--bg-secondary)", border: "1px solid var(--border)",
                borderRadius: "8px", padding: "4px 6px", cursor: "pointer",
                color: "var(--text-secondary)", display: "flex", alignItems: "center",
                boxShadow: "0 2px 8px rgba(0,0,0,0.12)",
              }}
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <line x1="18" y1="6" x2="6" y2="18" />
                <line x1="6" y1="6" x2="18" y2="18" />
              </svg>
            </button>
            {paperHtml && (
              <button
                data-chat-btn
                onClick={() => { handleNewChat(); setViewMode("reader"); }}
                data-tooltip="Open chat"
                style={{
                  position: "absolute", top: 10, right: 40, zIndex: 10,
                  opacity: 0, transition: "opacity 0.15s ease",
                  background: "var(--bg-secondary)", border: "1px solid var(--border)",
                  borderRadius: "8px", padding: "4px 6px", cursor: "pointer",
                  color: "var(--text-secondary)", display: "flex", alignItems: "center",
                  boxShadow: "0 2px 8px rgba(0,0,0,0.12)",
                }}
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
                </svg>
              </button>
            )}
            {paperHtml ? (
              <>
                <MarkdownReader
                  html={paperHtml}
                  onSelectionAction={handleSelectionAction}
                  darkMode={darkMode}
                  highlights={pdfHighlights}
                  onChatHighlightClick={handleChatHighlightClick}
                  fontScale={fontScale}
                  onFontScaleChange={handleFontScaleChange}
                  scrollToHeadingId={scrollToHeadingId}
                  onScrollComplete={handleScrollComplete}
                  onFigureClick={handleFigureClick}
                />
                {paperToc && paperToc.length > 0 && (
                  <TableOfContents
                    entries={paperToc}
                    onNavigate={handleTocNavigate}
                    darkMode={darkMode}
                  />
                )}
                {/* Top-right button group: Figs + Dark mode — always visible */}
                <div style={{
                  position: "absolute",
                  top: 12,
                  right: 12,
                  zIndex: 15,
                  display: "flex",
                  gap: 6,
                  alignItems: "center",
                }}>
                  {activePaperId && (
                    <button
                      onClick={() => setShowFigures(true)}
                      title="View figures"
                      style={{
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
                        <rect x="3" y="3" width="18" height="18" rx="2" ry="2" />
                        <circle cx="8.5" cy="8.5" r="1.5" />
                        <polyline points="21 15 16 10 5 21" />
                      </svg>
                      Figs
                    </button>
                  )}
                  <button
                    onClick={() => setDarkMode(!darkMode)}
                    title={darkMode ? "Light mode" : "Dark mode"}
                    style={{
                      background: darkMode ? "rgba(30,30,30,0.9)" : "rgba(255,255,255,0.9)",
                      border: `1px solid ${darkMode ? "#3f3f46" : "#d4d4d8"}`,
                      borderRadius: "10px",
                      padding: "6px",
                      cursor: "pointer",
                      color: darkMode ? "#e4e4e7" : "#18181b",
                      boxShadow: "0 2px 8px rgba(0,0,0,0.15)",
                      backdropFilter: "blur(8px)",
                      WebkitBackdropFilter: "blur(8px)",
                      display: "flex",
                      alignItems: "center",
                    }}
                  >
                    {darkMode ? (
                      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <circle cx="12" cy="12" r="5" />
                        <line x1="12" y1="1" x2="12" y2="3" /><line x1="12" y1="21" x2="12" y2="23" />
                        <line x1="4.22" y1="4.22" x2="5.64" y2="5.64" /><line x1="18.36" y1="18.36" x2="19.78" y2="19.78" />
                        <line x1="1" y1="12" x2="3" y2="12" /><line x1="21" y1="12" x2="23" y2="12" />
                        <line x1="4.22" y1="19.78" x2="5.64" y2="18.36" /><line x1="18.36" y1="5.64" x2="19.78" y2="4.22" />
                      </svg>
                    ) : (
                      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
                      </svg>
                    )}
                  </button>
                </div>
              </>
            ) : (
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  height: "100%",
                  color: "var(--text-secondary)",
                  fontSize: "14px",
                }}
              >
                Select a paper from the library
              </div>
            )}
          </div>
        </Panel>
      </PanelGroup>
      <CollapseHandle
        side="left"
        visible={browseLibraryCollapsed}
        onClick={() => browseLibraryPanelRef.current?.expand()}
        label="Show Library"
      />
      <CollapseHandle
        side="right"
        visible={browsePdfCollapsed}
        onClick={() => browsePdfPanelRef.current?.expand()}
        label="Show PDF"
      />
    </div>
  );
}

