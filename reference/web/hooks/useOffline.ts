"use client";

import { useState, useEffect, useCallback } from "react";
import {
  saveOfflinePaper,
  removeOfflinePaper,
  getOfflinePaper,
  getOfflinePaperIds,
  OfflinePaper,
} from "@/lib/offline-store";

export function useOffline() {
  const [isOnline, setIsOnline] = useState(true);
  const [offlineIds, setOfflineIds] = useState<Set<string>>(new Set());
  const [saving, setSaving] = useState<string | null>(null);

  // Track online/offline status
  useEffect(() => {
    setIsOnline(navigator.onLine);
    const goOnline = () => setIsOnline(true);
    const goOffline = () => setIsOnline(false);
    window.addEventListener("online", goOnline);
    window.addEventListener("offline", goOffline);
    return () => {
      window.removeEventListener("online", goOnline);
      window.removeEventListener("offline", goOffline);
    };
  }, []);

  // Load saved paper IDs on mount
  useEffect(() => {
    getOfflinePaperIds().then(setOfflineIds).catch(() => {});
  }, []);

  const refreshIds = useCallback(async () => {
    try {
      const ids = await getOfflinePaperIds();
      setOfflineIds(ids);
    } catch {}
  }, []);

  const savePaperOffline = useCallback(
    async (paper: { id: string; title: string; authors: string | null; year: number | null; venue: string | null; abstract: string | null; keywords: string | null }, html: string, toc: unknown[] | null) => {
      setSaving(paper.id);
      try {
        const offlinePaper: OfflinePaper = {
          ...paper,
          html,
          toc,
          savedAt: Date.now(),
        };
        await saveOfflinePaper(offlinePaper);
        await refreshIds();
      } finally {
        setSaving(null);
      }
    },
    [refreshIds]
  );

  const removePaperOffline = useCallback(
    async (id: string) => {
      await removeOfflinePaper(id);
      await refreshIds();
    },
    [refreshIds]
  );

  const loadPaperOffline = useCallback(
    async (id: string): Promise<{ html: string; toc: unknown[] | null } | null> => {
      const paper = await getOfflinePaper(id);
      if (!paper) return null;
      return { html: paper.html, toc: paper.toc };
    },
    []
  );

  const isOffline = useCallback((id: string) => offlineIds.has(id), [offlineIds]);

  return {
    isOnline,
    offlineIds,
    saving,
    savePaperOffline,
    removePaperOffline,
    loadPaperOffline,
    isOffline,
  };
}
