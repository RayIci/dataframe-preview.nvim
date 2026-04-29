import { useRef, useEffect, useCallback } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import {
  useDataStore, SortEntry, FilterGroup,
  hasConditionForCol,
} from "@/store/dataStore";
import { Badge } from "@/components/ui/badge";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { LoadingSkeleton } from "./LoadingSkeleton";
import { ScrollToTop } from "./ScrollToTop";
import { useColumnResize } from "@/hooks/useColumnResize";
import { cn } from "@/lib/utils";

const ROW_HEIGHT    = 32;
const CHUNK_SIZE    = 100;
const PREFETCH_GAP  = 20;
const HEADER_HEIGHT = 48; // px — room for 2-line column headers
const ROW_INDEX_W   = 56; // matches w-14 (3.5rem × 16px)

function dtypeBadge(dtype: string): { label: string; variant: "default" | "secondary" | "outline" } {
  if (/^(int|uint|float)/.test(dtype))     return { label: dtype, variant: "default" };
  if (/^(datetime|timedelta)/.test(dtype)) return { label: dtype, variant: "secondary" };
  return { label: dtype, variant: "outline" };
}

interface DataGridProps {
  uuid:            string;
  fetchRows:       (uuid: string, offset: number) => void;
  applySortFilter: (uuid: string, sort: SortEntry[], filterTree: FilterGroup) => void;
}

export function DataGrid({ uuid, fetchRows, applySortFilter }: DataGridProps) {
  const data    = useDataStore((s) => s.getData(uuid));
  const getRow  = useDataStore((s) => s.getRow);
  const hasRows = useDataStore((s) => s.hasRows);
  const scrollRef = useRef<HTMLDivElement>(null);
  const { getWidth, startResize } = useColumnResize();

  const meta          = data?.meta          ?? null;
  const loading       = data?.loading       ?? true;
  const error         = data?.error         ?? null;
  const sort          = data?.sort          ?? [];
  const filterTree    = data?.filterTree;
  const scrollVersion = data?.scrollVersion ?? 0;

  const rowCount = meta?.row_count ?? 0;

  const virtualizer = useVirtualizer({
    count:            rowCount,
    getScrollElement: () => scrollRef.current,
    estimateSize:     () => ROW_HEIGHT,
    overscan:         5,
  });

  const items = virtualizer.getVirtualItems();

  useEffect(() => { scrollRef.current?.scrollTo({ top: 0 }); }, [scrollVersion]);
  useEffect(() => { scrollRef.current?.scrollTo({ top: 0 }); }, [uuid]);

  const prefetch = useCallback(() => {
    if (!items.length) return;
    const lastIndex  = items[items.length - 1].index;
    const nextOffset = Math.floor((lastIndex + PREFETCH_GAP) / CHUNK_SIZE) * CHUNK_SIZE;
    if (nextOffset < rowCount && !hasRows(uuid, nextOffset)) fetchRows(uuid, nextOffset);
  }, [items, rowCount, hasRows, uuid, fetchRows]);

  useEffect(() => { prefetch(); }, [prefetch]);

  const handleSortClick = useCallback(
    (col: string) => {
      if (!filterTree) return;
      const existing = sort.find((s) => s.column === col);
      let newSort: SortEntry[];
      if (!existing)
        newSort = [...sort, { column: col, ascending: true }];
      else if (existing.ascending)
        newSort = sort.map((s) => s.column === col ? { ...s, ascending: false } : s);
      else
        newSort = sort.filter((s) => s.column !== col);
      applySortFilter(uuid, newSort, filterTree);
    },
    [sort, filterTree, uuid, applySortFilter]
  );

  if (error) {
    return (
      <div className="flex flex-1 items-center justify-center text-destructive text-sm px-4 text-center">
        {error}
      </div>
    );
  }

  if (loading || !meta) return <LoadingSkeleton cols={5} />;

  const colCount   = meta.columns.length;
  const totalWidth = ROW_INDEX_W + meta.columns.reduce((sum, col) => sum + getWidth(col), 0);

  return (
    <TooltipProvider delayDuration={300}>
      <div className="flex flex-col flex-1 overflow-hidden relative">

        {/* Single scroll container — header + body share the same viewport */}
        <div ref={scrollRef} className="flex-1 overflow-auto">
          <div style={{ minWidth: totalWidth }}>

            {/* ── Column headers — sticky on Y, scrolls with body on X ── */}
            <div
              className="flex border-b-2 border-border bg-card"
              style={{ position: "sticky", top: 0, height: HEADER_HEIGHT, zIndex: 10 }}
            >
              {/* Row-index column */}
              <div
                className="shrink-0 flex items-center justify-end px-2 border-r border-border text-[10px] text-muted-foreground/50 select-none"
                style={{ width: ROW_INDEX_W, minWidth: ROW_INDEX_W }}
              >
                #
              </div>

              {meta.columns.map((col, i) => {
                const { label, variant } = dtypeBadge(meta.dtypes[i] ?? "");
                const sortEntry  = sort.find((s) => s.column === col);
                const sortRank   = sortEntry ? sort.indexOf(sortEntry) : -1;
                const isFiltered = filterTree ? hasConditionForCol(filterTree, col) : false;
                const colW       = getWidth(col);

                return (
                  <div
                    key={i}
                    className="group relative flex items-stretch border-r border-border last:border-r-0 select-none"
                    style={{ width: colW, minWidth: colW, maxWidth: colW }}
                  >
                    {/* ── Sort button — vertical layout ── */}
                    <button
                      className="flex flex-col justify-center flex-1 min-w-0 px-2 py-1.5 cursor-pointer hover:bg-muted/50 text-left gap-1 transition-colors"
                      onClick={() => handleSortClick(col)}
                      title="Click to sort · again to reverse · again to remove"
                    >
                      {/* Row 1: sort indicator + filter dot + column name */}
                      <div className="flex items-center gap-1 min-w-0">
                        {sortEntry && (
                          <span className="shrink-0 text-primary font-bold text-[11px] leading-none">
                            {sortEntry.ascending ? "↑" : "↓"}
                            {sort.length > 1 && (
                              <span className="text-[9px]">{sortRank + 1}</span>
                            )}
                          </span>
                        )}
                        {isFiltered && (
                          <span
                            className="shrink-0 size-1.5 rounded-full bg-amber-400"
                            title="Filtered"
                          />
                        )}
                        <span
                          className={cn(
                            "truncate text-[11px] font-semibold leading-tight",
                            sortEntry ? "text-primary" : "text-foreground"
                          )}
                        >
                          {col}
                        </span>
                      </div>

                      {/* Row 2: dtype badge */}
                      <Badge
                        variant={variant}
                        className="w-fit shrink-0 text-[9px] px-1.5 py-0 h-4 font-normal rounded-sm"
                      >
                        {label}
                      </Badge>
                    </button>

                    {/* ── Resize handle ────────────────────────────────── */}
                    <div
                      className="absolute right-0 top-0 h-full w-2.5 cursor-col-resize z-10"
                      onMouseDown={(e) => {
                        e.preventDefault();
                        e.stopPropagation();
                        startResize(col, e.clientX);
                      }}
                    >
                      <div
                        className="absolute right-0 top-1/4 h-1/2 w-0.5 rounded-full bg-border group-hover:bg-primary group-hover:w-1 transition-all duration-150"
                      />
                    </div>
                  </div>
                );
              })}
            </div>

            {/* ── Virtual scroll body ───────────────────────────────────── */}
            <div style={{ height: `${virtualizer.getTotalSize()}px`, position: "relative" }}>
              {items.map((vRow) => {
                const row = getRow(uuid, vRow.index);
                return (
                  <div
                    key={vRow.key}
                    data-index={vRow.index}
                    ref={virtualizer.measureElement}
                    className="absolute flex w-full border-b border-border/40 hover:bg-muted/20 transition-colors"
                    style={{ top: vRow.start }}
                  >
                    {/* Row index */}
                    <div
                      className="shrink-0 px-2 py-1.5 text-right text-muted-foreground/40 border-r border-border/40 tabular-nums text-[11px]"
                      style={{ width: ROW_INDEX_W, minWidth: ROW_INDEX_W }}
                    >
                      {vRow.index}
                    </div>

                    {/* Data cells */}
                    {row ? (
                      row.map((cell, ci) => {
                        const colW    = getWidth(meta.columns[ci] ?? "");
                        const display = cell === null ? "null" : String(cell);
                        const isNull  = cell === null;
                        return (
                          <Tooltip key={ci}>
                            <TooltipTrigger asChild>
                              <div
                                data-cell
                                className="px-2 py-1.5 border-r border-border/40 last:border-r-0 overflow-hidden cursor-default"
                                style={{ width: colW, minWidth: colW, maxWidth: colW }}
                              >
                                <span
                                  className={cn(
                                    "block truncate",
                                    isNull && "text-muted-foreground/40 italic"
                                  )}
                                >
                                  {display}
                                </span>
                              </div>
                            </TooltipTrigger>
                            {display.length > 25 && (
                              <TooltipContent side="bottom" className="max-w-xs">
                                <span className="break-all font-mono text-xs">{display}</span>
                              </TooltipContent>
                            )}
                          </Tooltip>
                        );
                      })
                    ) : (
                      Array.from({ length: colCount }).map((_, ci) => {
                        const colW = getWidth(meta.columns[ci] ?? "");
                        return (
                          <div
                            key={ci}
                            data-cell
                            className="px-2 py-1.5 border-r border-border/40 last:border-r-0"
                            style={{ width: colW, minWidth: colW, maxWidth: colW }}
                          >
                            <div className="h-3 w-3/4 rounded bg-muted/40 animate-pulse" />
                          </div>
                        );
                      })
                    )}
                  </div>
                );
              })}
            </div>

          </div>
        </div>

        <ScrollToTop scrollRef={scrollRef} />
      </div>
    </TooltipProvider>
  );
}
