import { useRef, useEffect, useCallback } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useDataStore } from "@/store/dataStore";
import { Badge } from "@/components/ui/badge";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { LoadingSkeleton } from "./LoadingSkeleton";

const ROW_HEIGHT   = 32;
const CHUNK_SIZE   = 100;
const PREFETCH_GAP = 20;

// Map pandas dtype prefixes to a readable badge variant
function dtypeBadge(dtype: string): { label: string; variant: "default" | "secondary" | "outline" } {
  if (dtype.startsWith("int") || dtype.startsWith("uint") || dtype.startsWith("float"))
    return { label: dtype, variant: "default" };
  if (dtype.startsWith("datetime") || dtype.startsWith("timedelta"))
    return { label: dtype, variant: "secondary" };
  return { label: dtype, variant: "outline" };
}

interface DataGridProps {
  fetchRows: (offset: number) => void;
}

export function DataGrid({ fetchRows }: DataGridProps) {
  const { meta, loading, error, getRow, hasRows } = useDataStore();
  const scrollRef = useRef<HTMLDivElement>(null);

  const rowCount = meta?.row_count ?? 0;

  const virtualizer = useVirtualizer({
    count:           rowCount,
    getScrollElement: () => scrollRef.current,
    estimateSize:    () => ROW_HEIGHT,
    overscan:        5,
  });

  const items = virtualizer.getVirtualItems();

  // Prefetch chunks when approaching the edge of loaded data
  const prefetch = useCallback(() => {
    if (!items.length) return;
    const lastIndex = items[items.length - 1].index;
    const nextChunkOffset = Math.floor((lastIndex + PREFETCH_GAP) / CHUNK_SIZE) * CHUNK_SIZE;
    if (nextChunkOffset < rowCount && !hasRows(nextChunkOffset)) {
      fetchRows(nextChunkOffset);
    }
  }, [items, rowCount, hasRows, fetchRows]);

  useEffect(() => { prefetch(); }, [prefetch]);

  if (error) {
    return (
      <div className="flex flex-1 items-center justify-center text-destructive text-sm">
        {error}
      </div>
    );
  }

  if (loading || !meta) {
    return <LoadingSkeleton cols={5} />;
  }

  const colCount = meta.columns.length;
  const colWidth = `${Math.max(120, Math.floor(100 / colCount))}px`;

  return (
    <TooltipProvider delayDuration={300}>
      <div className="flex flex-col flex-1 overflow-hidden">
        {/* Sticky header */}
        <div
          className="flex shrink-0 border-b border-border bg-card text-xs font-medium text-muted-foreground"
          style={{ minWidth: `${colCount * 120}px` }}
        >
          {/* Row index header */}
          <div className="w-14 shrink-0 px-2 py-2 text-right border-r border-border">#</div>
          {meta.columns.map((col, i) => {
            const { label, variant } = dtypeBadge(meta.dtypes[i] ?? "");
            return (
              <div
                key={i}
                className="flex items-center gap-1.5 px-2 py-2 border-r border-border last:border-r-0 overflow-hidden"
                style={{ width: colWidth, minWidth: colWidth }}
              >
                <span className="truncate text-foreground">{col}</span>
                <Badge variant={variant} className="shrink-0">{label}</Badge>
              </div>
            );
          })}
        </div>

        {/* Virtual scroll body */}
        <div ref={scrollRef} className="flex-1 overflow-auto">
          <div
            style={{ height: `${virtualizer.getTotalSize()}px`, position: "relative" }}
          >
            {items.map((vRow) => {
              const row = getRow(vRow.index);
              return (
                <div
                  key={vRow.key}
                  data-index={vRow.index}
                  ref={virtualizer.measureElement}
                  className="absolute flex w-full border-b border-border/50 text-xs hover:bg-muted/30"
                  style={{ top: vRow.start, minWidth: `${colCount * 120}px` }}
                >
                  {/* Row index */}
                  <div className="w-14 shrink-0 px-2 py-1.5 text-right text-muted-foreground border-r border-border/50">
                    {vRow.index}
                  </div>

                  {row ? (
                    row.map((cell, ci) => {
                      const display = cell === null ? "null" : String(cell);
                      return (
                        <Tooltip key={ci}>
                          <TooltipTrigger asChild>
                            <div
                              className="px-2 py-1.5 border-r border-border/50 last:border-r-0 overflow-hidden cursor-default"
                              style={{ width: colWidth, minWidth: colWidth }}
                            >
                              <span
                                className={`block truncate ${cell === null ? "text-muted-foreground italic" : ""}`}
                              >
                                {display}
                              </span>
                            </div>
                          </TooltipTrigger>
                          {display.length > 20 && (
                            <TooltipContent>
                              <span className="break-all">{display}</span>
                            </TooltipContent>
                          )}
                        </Tooltip>
                      );
                    })
                  ) : (
                    // Row not yet fetched — show skeleton cells
                    Array.from({ length: colCount }).map((_, ci) => (
                      <div
                        key={ci}
                        className="px-2 py-1.5 border-r border-border/50 last:border-r-0"
                        style={{ width: colWidth, minWidth: colWidth }}
                      >
                        <div className="h-3 w-3/4 rounded bg-muted/40 animate-pulse" />
                      </div>
                    ))
                  )}
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </TooltipProvider>
  );
}
