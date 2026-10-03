// IndexedDB-based offline paper storage
// Stores paper metadata + HTML for offline reading

const DB_NAME = "science-reader-offline";
const DB_VERSION = 1;
const PAPERS_STORE = "papers";
const MAX_OFFLINE_PAPERS = 20;

export interface OfflinePaper {
  id: string;
  title: string;
  authors: string | null;
  year: number | null;
  venue: string | null;
  abstract: string | null;
  keywords: string | null;
  html: string;
  toc: unknown[] | null;
  savedAt: number; // timestamp
}

function openDB(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(PAPERS_STORE)) {
        db.createObjectStore(PAPERS_STORE, { keyPath: "id" });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export async function saveOfflinePaper(paper: OfflinePaper): Promise<void> {
  const db = await openDB();
  // Check count first
  const count = await getOfflineCount(db);
  if (count >= MAX_OFFLINE_PAPERS) {
    // Check if this paper is already saved (update is fine)
    const existing = await getOfflinePaperFromDB(db, paper.id);
    if (!existing) {
      throw new Error(`Offline limit reached (${MAX_OFFLINE_PAPERS}). Remove a paper first.`);
    }
  }
  return new Promise((resolve, reject) => {
    const tx = db.transaction(PAPERS_STORE, "readwrite");
    tx.objectStore(PAPERS_STORE).put(paper);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

export async function removeOfflinePaper(id: string): Promise<void> {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(PAPERS_STORE, "readwrite");
    tx.objectStore(PAPERS_STORE).delete(id);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

export async function getOfflinePaper(id: string): Promise<OfflinePaper | null> {
  const db = await openDB();
  return getOfflinePaperFromDB(db, id);
}

function getOfflinePaperFromDB(db: IDBDatabase, id: string): Promise<OfflinePaper | null> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(PAPERS_STORE, "readonly");
    const req = tx.objectStore(PAPERS_STORE).get(id);
    req.onsuccess = () => resolve(req.result ?? null);
    req.onerror = () => reject(req.error);
  });
}

export async function listOfflinePapers(): Promise<OfflinePaper[]> {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(PAPERS_STORE, "readonly");
    const req = tx.objectStore(PAPERS_STORE).getAll();
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export async function isOfflineSaved(id: string): Promise<boolean> {
  const paper = await getOfflinePaper(id);
  return paper !== null;
}

export async function getOfflinePaperIds(): Promise<Set<string>> {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(PAPERS_STORE, "readonly");
    const req = tx.objectStore(PAPERS_STORE).getAllKeys();
    req.onsuccess = () => resolve(new Set(req.result.map(String)));
    req.onerror = () => reject(req.error);
  });
}

function getOfflineCount(db: IDBDatabase): Promise<number> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(PAPERS_STORE, "readonly");
    const req = tx.objectStore(PAPERS_STORE).count();
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}
