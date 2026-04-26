import { useRef, useEffect, useCallback, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { Filter } from "lucide-react";
import {
  useDataStore, SortEntry, FilterGroup,
  hasActiveFilter, countConditions, hasConditionForCol, emptyFilterTree,
} from "@/store/dataStore";
import { Badge } from "@/components/ui/badge";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { LoadingSkeleton } from "./LoadingSkeleton";
import { FilterPanel } from "./FilterPanel";

const ROW_HEIGHT   = 32;
const CHUNK_SIZE   = 100;
const PREFETCH_GAP = 20;

function dtypeBadge(dtype: string): { label: string; variant: "default" | "secondary" | "outline" } {
  if (dtype.startsWith("int") || dtype.startsWith("uint") || dtype.startsWith("float"))
    return { label: dtype, variant: "default" };
  if (dtype.startsWith("datetime") || dtype.startsWith("timedelta"))
    return { label: dtype, variant: "secondary" };
  return { label: dtype, variant: "outline" };
}

interface DataGridProps {
  fetchRows:       (offset: number) => void;
  applySortFilter: (sort: SortEntry[], filterTree: FilterGroup) => void;
}

export function DataGrid({ fetchRows, applySortFilter }: DataGridProps) {
  const { meta, loading, error, getRow, hasRows, sort, filterTree, scrollVersion } = useDataStore();
  const scrollRef = useRef<HTMLDivElement>(null);

  const [filterPanelOpen,  setFilterPanelOpen]  = useState(false);
  const [filterInitialCol, setFilterInitialCol] = useState<string | null>(null);

  const rowCount = meta?.row_count ?? 0;

  const virtualizer = useVirtualizer({
    count:            rowCount,
    getScrollElement: () => scrollRef.current,
    estimateSize:     () => ROW_HEIGHT,
    overscan:         5,
  });

  const items = virtualizer.getVirtualItems();

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: 0 });
  }, [scrollVersion]);

  const prefetch = useCallback(() => {
    if (!items.length) return;
    const lastIndex = items[items.length - 1].index;
    const nextChunkOffset = Math.floor((lastIndex + PREFETCH_GAP) / CHUNK_SIZE) * CHUNK_SIZE;
    if (nextChunkOffset < rowCount && !hasRows(nextChunkOffset)) {
      fetchRows(nextChunkOffset);
    }
  }, [items, rowCount, hasRows, fetchRows]);

  useEffect(() => { prefetch(); }, [prefetch]);

  // Click on a column header always adds/cycles that column in the sort list.
  // Cycles: off → asc → desc → off, without touching other columns.
  const handleSortClick = useCallback((col: string) => {
    const existing = sort.find((s) => s.column === col);
    let newSort: SortEntry[];
    if (!existing)
      newSort = [...sort, { column: col, ascending: true }];
    else if (existing.ascending)
      newSort = sort.map((s) => s.column === col ? { ...s, ascending: false } : s);
    else
      newSort = sort.filter((s) => s.column !== col);
    applySortFilter(newSort, filterTree);
  }, [sort, filterTree, applySortFilter]);

  const clearAllSort = () => applySortFilter([], filterTree);

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
  const filterActive = hasActiveFilter(filterTree);

  return (
    <TooltipProvider delayDuration={300}>
      <div className="flex flex-col flex-1 overflow-hidden">
        {/* Sticky column headers */}
        <div
          className="flex shrink-0 border-b border-border bg-card text-xs font-medium text-muted-foreground"
          style={{ minWidth: `${colCount * 120}px` }}
        >
          <div className="w-14 shrink-0 px-2 py-2 text-right border-r border-border">#</div>
          {meta.columns.map((col, i) => {
            const { label, variant } = dtypeBadge(meta.dtypes[i] ?? "");
            const sortEntry  = sort.find((s) => s.column === col);
            const sortIdx    = sortEntry ? sort.indexOf(sortEntry) : -1;
            const isFiltered = hasConditionForCol(filterTree, col);

            return (
              <div
                key={i}
                className="relative flex items-center gap-1 px-2 py-2 border-r border-border last:border-r-0 overflow-visible select-none"
                style={{ width: colWidth, minWidth: colWidth }}
              >
                {/* Sortable area */}
                <button
                  className="flex items-center gap-1 flex-1 min-w-0 cursor-pointer hover:text-foreground text-left"
                  onClick={() => handleSortClick(col)}
                  title="Click to sort · click again to reverse · click again to remove"
                >
                  {sortEntry && (
                    <span className="shrink-0 text-blue-400 text-[10px] font-bold leading-none">
                      {sortEntry.ascending ? "↑" : "↓"}
                      {sort.length > 1 ? sortIdx + 1 : ""}
                    </span>
                  )}
                  <span className="truncate text-foreground">{col}</span>
                  <Badge variant={variant} className="shrink-0">{label}</Badge>
                </button>

                {/* Filter toggle */}
                <button
                  className={`shrink-0 rounded p-0.5 hover:bg-muted transition-colors ${
                    isFiltered ? "text-amber-400" : "text-muted-foreground hover:text-foreground"
                  }`}
                  onClick={() => { setFilterInitialCol(col); setFilterPanelOpen(true); }}
                  title="Open filter builder"
                >
                  <Filter size={11} />
                </button>
              </div>
            );
          })}
        </div>

        {/* Active sort / filter chips */}
        {(sort.length > 0 || filterActive) && (
          <div
            className="flex flex-wrap items-center gap-1 px-2 py-1 border-b border-border bg-card/80 text-xs shrink-0"
            style={{ minWidth: `${colCount * 120}px` }}
          >
            {sort.length > 0 && (
              <>
                <span className="text-muted-foreground">Sort:</span>
                {sort.map((s, i) => (
                  <span
                    key={s.column}
                    className="inline-flex items-center gap-0.5 rounded bg-blue-950 px-1.5 py-0.5 text-blue-300"
                  >
                    {s.ascending ? "↑" : "↓"} {s.column}
                    <button
                      className="ml-0.5 hover:text-white"
                      onClick={() => applySortFilter(sort.filter((_, j) => j !== i), filterTree)}
                    >
                      ×
                    </button>
                  </span>
                ))}
                <button className="text-muted-foreground hover:text-foreground" onClick={clearAllSort}>
                  clear
                </button>
                {filterActive && <span className="mx-1 text-border">|</span>}
              </>
            )}
            {filterActive && (
              <>
                <span className="text-muted-foreground">Filter:</span>
                <span className="text-amber-300">
                  {countConditions(filterTree)} condition{countConditions(filterTree) !== 1 ? "s" : ""}
                </span>
                <button
                  className="text-amber-400 hover:text-amber-200 underline"
                  onClick={() => { setFilterInitialCol(null); setFilterPanelOpen(true); }}
                >
                  edit
                </button>
                <button
                  className="text-muted-foreground hover:text-foreground"
                  onClick={() => applySortFilter(sort, emptyFilterTree())}
                >
                  clear
                </button>
              </>
            )}
          </div>
        )}

        {/* Recursive filter builder panel (fixed overlay) */}
        {filterPanelOpen && meta && (
          <FilterPanel
            columns={meta.columns}
            dtypes={meta.dtypes}
            filterTree={filterTree}
            initialCol={filterInitialCol ?? undefined}
            onApply={(tree) => { applySortFilter(sort, tree); setFilterPanelOpen(false); }}
            onClose={() => setFilterPanelOpen(false)}
          />
        )}

        {/* Virtual scroll body */}
        <div ref={scrollRef} className="flex-1 overflow-auto">
          <div style={{ height: `${virtualizer.getTotalSize()}px`, position: "relative" }}>
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
