import { useCallback, useState } from "react";

const STORAGE_KEY = "df-col-widths";
const MIN_WIDTH   = 80;
const DEFAULT_WIDTH = 150;

function loadWidths(): Record<string, number> {
  try {
    return JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "{}") as Record<string, number>;
  } catch {
    return {};
  }
}

function saveWidths(widths: Record<string, number>): void {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(widths)); } catch { /* ignore */ }
}

export function useColumnResize() {
  const [widths, setWidths] = useState<Record<string, number>>(loadWidths);

  const getWidth = useCallback((col: string) => widths[col] ?? DEFAULT_WIDTH, [widths]);

  const startResize = useCallback((col: string, startX: number) => {
    const startW = widths[col] ?? DEFAULT_WIDTH;
    document.body.classList.add("resizing");

    const onMove = (e: MouseEvent) => {
      const newW = Math.max(MIN_WIDTH, startW + (e.clientX - startX));
      setWidths((prev) => {
        const next = { ...prev, [col]: newW };
        saveWidths(next);
        return next;
      });
    };

    const onUp = () => {
      document.body.classList.remove("resizing");
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup",  onUp);
    };

    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup",  onUp);
  }, [widths]);

  return { getWidth, startResize };
}
