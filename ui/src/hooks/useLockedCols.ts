import { useState, useCallback } from "react";

const STORAGE_KEY = "df-locked-cols";

function load(): string[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    return raw ? (JSON.parse(raw) as string[]) : [];
  } catch {
    return [];
  }
}

function save(cols: string[]) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(cols));
  } catch { /* ignore */ }
}

export function useLockedCols() {
  const [lockedCols, setLockedCols] = useState<string[]>(load);

  const lockedSet = new Set(lockedCols);

  const toggleLock = useCallback((col: string) => {
    setLockedCols((prev) => {
      const next = prev.includes(col)
        ? prev.filter((c) => c !== col)
        : [...prev, col];
      save(next);
      return next;
    });
  }, []);

  const reorderLocked = useCallback((fromIdx: number, toIdx: number) => {
    setLockedCols((prev) => {
      const next = [...prev];
      const [item] = next.splice(fromIdx, 1);
      next.splice(toIdx, 0, item);
      save(next);
      return next;
    });
  }, []);

  return { lockedCols, lockedSet, toggleLock, reorderLocked };
}
