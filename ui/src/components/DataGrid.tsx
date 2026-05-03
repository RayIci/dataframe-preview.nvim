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
import { useLockedCols } from "@/hooks/useLockedCols";
import { Pin, GripVertical, KeyRound } from "lucide-react";
import { cn } from "@/lib/utils";

const ROW_HEIGHT    = 32;
const CHUNK_SIZE    = 100;
const PREFETCH_GAP  = 20;
const HEADER_HEIGHT = 48;
const ROW_INDEX_W   = 56;

function dtypeBadge(dtype: string): { label: string; variant: "default" | "secondary" | "outline" } {
  if (/^(int|uint|float)/.test(dtype))     return { label: dtype, variant: "default" };
  if (/^(datetime|timedelta)/.test(dtype)) return { label: dtype, variant: "secondary" };
  return { label: dtype, variant: "outline" };
}

// Style applied to locked column cells to freeze them horizontally via translateX.
// CSS custom property --locked-tx is updated on scroll with no React re-renders.
const lockedStyle = (zIndex: number): React.CSSProperties => ({
  transform:       "translateX(var(--locked-tx, 0px))",
  position:        "relative",
  zIndex,
  backgroundColor: "var(--color-card)",
});

interface DataGridProps {
  uuid:            string;
  fetchRows:       (uuid: string, offset: number) => void;
  applySortFilter: (uuid: string, sort: SortEntry[], filterTree: FilterGroup) => void;
}

export function DataGrid({ uuid, fetchRows, applySortFilter }: DataGridProps) {
  const data              = useDataStore((s) => s.getData(uuid));
  const getRow            = useDataStore((s) => s.getRow);
  const hasRows           = useDataStore((s) => s.hasRows);
  const toggleLockedRow   = useDataStore((s) => s.toggleLockedRow);
  const reorderLockedRows = useDataStore((s) => s.reorderLockedRows);

  const scrollRef = useRef<HTMLDivElement>(null);
  const { getWidth, startResize }                        = useColumnResize();
  const { lockedCols, lockedSet: lockedColSet, toggleLock, reorderLocked } = useLockedCols();

  const meta          = data?.meta          ?? null;
  const loading       = data?.loading       ?? true;
  const error         = data?.error         ?? null;
  const sort          = data?.sort          ?? [];
  const filterTree    = data?.filterTree;
  const scrollVersion = data?.scrollVersion ?? 0;
  const lockedRows    = data?.lockedRows    ?? [];

  const lockedRowSet = new Set(lockedRows);

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

  // Update --locked-tx on scroll without triggering React re-renders
  const handleScroll = useCallback((e: React.UIEvent<HTMLDivElement>) => {
    scrollRef.current?.style.setProperty("--locked-tx", `${e.currentTarget.scrollLeft}px`);
  }, []);

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

  const handleToggleRow = useCallback((rowIndex: number) => {
    toggleLockedRow(uuid, rowIndex);
    const chunkOffset = Math.floor(rowIndex / CHUNK_SIZE) * CHUNK_SIZE;
    if (!hasRows(uuid, chunkOffset)) fetchRows(uuid, chunkOffset);
  }, [uuid, toggleLockedRow, hasRows, fetchRows]);

  // Use refs (not state) for DnD drag-from tracking — onDrop closures must
  // read the synchronous value, not a potentially-stale React state snapshot.
  const dragColFromRef = useRef<number | null>(null);
  const dragRowFromRef = useRef<number | null>(null);

  if (error) {
    return (
      <div className="flex flex-1 items-center justify-center text-destructive text-sm px-4 text-center">
        {error}
      </div>
    );
  }

  if (loading || !meta) return <LoadingSkeleton cols={5} />;

  // Locked cols that still exist in this DataFrame; unlocked cols in original order
  const activeLocked = lockedCols.filter((c) => meta.columns.includes(c));
  const unlocked     = meta.columns.filter((c) => !lockedColSet.has(c));
  const orderedCols  = [...activeLocked, ...unlocked];

  const indexColSet = new Set(meta.index_columns ?? []);

  const totalWidth = ROW_INDEX_W + orderedCols.reduce((sum, c) => sum + getWidth(c), 0);

  return (
    <TooltipProvider delayDuration={300}>
      <div className="flex flex-col flex-1 overflow-hidden relative">

        <div ref={scrollRef} className="flex-1 overflow-auto" onScroll={handleScroll}>
          <div style={{ minWidth: totalWidth }}>

            {/* ── Column headers ─────────────────────────────────────────── */}
            <div
              className="flex border-b-2 border-border bg-card"
              style={{ position: "sticky", top: 0, height: HEADER_HEIGHT, zIndex: 20 }}
            >
              {/* Row-index header — always frozen */}
              <div
                className="shrink-0 flex items-center justify-end px-2 border-r border-border text-[10px] text-muted-foreground/50 select-none"
                style={{ width: ROW_INDEX_W, minWidth: ROW_INDEX_W, ...lockedStyle(25) }}
              >
                #
              </div>

              {orderedCols.map((col) => {
                const origIdx      = meta.columns.indexOf(col);
                const { label, variant } = dtypeBadge(meta.dtypes[origIdx] ?? "");
                const sortEntry    = sort.find((s) => s.column === col);
                const sortRank     = sortEntry ? sort.indexOf(sortEntry) : -1;
                const isFiltered   = filterTree ? hasConditionForCol(filterTree, col) : false;
                const colW         = getWidth(col);
                const isLocked     = lockedColSet.has(col);
                const lockedIdx    = activeLocked.indexOf(col);
                const isLastLocked = isLocked && lockedIdx === activeLocked.length - 1;

                const isIdx = indexColSet.has(col);

                return (
                  <div
                    key={col}
                    className={cn(
                      "group relative flex items-stretch select-none border-r border-border",
                      isLastLocked && "border-r-[3px] border-r-primary/30"
                    )}
                    style={{
                      width: colW, minWidth: colW, maxWidth: colW,
                      ...(isLocked ? lockedStyle(15) : {}),
                    }}
                    onDragOver={isLocked ? (e) => e.preventDefault() : undefined}
                    onDrop={isLocked ? (e) => {
                      e.preventDefault();
                      const raw  = e.dataTransfer.getData("text/plain");
                      const from = dragColFromRef.current ?? (raw !== "" ? parseInt(raw) : null);
                      if (from !== null && from !== lockedIdx) reorderLocked(from, lockedIdx);
                      dragColFromRef.current = null;
                    } : undefined}
                  >
                    {/* Sort button */}
                    <button
                      className="flex flex-col justify-center flex-1 min-w-0 px-2 py-1.5 cursor-pointer hover:bg-muted/50 text-left gap-1 transition-colors"
                      onClick={() => handleSortClick(col)}
                      title="Click to sort · again to reverse · again to remove"
                    >
                      <div className="flex items-center gap-1 min-w-0">
                        {sortEntry && (
                          <span className="shrink-0 text-primary font-bold text-[11px] leading-none">
                            {sortEntry.ascending ? "↑" : "↓"}
                            {sort.length > 1 && <span className="text-[9px]">{sortRank + 1}</span>}
                          </span>
                        )}
                        {isFiltered && (
                          <span className="shrink-0 size-1.5 rounded-full bg-amber-400" title="Filtered" />
                        )}
                        {isIdx && (
                          <KeyRound size={10} className="shrink-0 text-muted-foreground/50" />
                        )}
                        <span className={cn(
                          "truncate text-[11px] font-semibold leading-tight",
                          sortEntry ? "text-primary" : isIdx ? "italic text-muted-foreground/70" : "text-foreground"
                        )}>
                          {col}
                        </span>
                      </div>
                      <Badge variant={variant} className="w-fit shrink-0 text-[9px] px-1.5 py-0 h-4 font-normal rounded-sm">
                        {label}
                      </Badge>
                    </button>

                    {/* Pin icon + drag handle — explicit element, not the whole column div */}
                    <div
                      className={cn(
                        "shrink-0 flex flex-col items-center justify-center gap-0.5 pr-3 transition-opacity z-10",
                        isLocked
                          ? "opacity-100"
                          : "opacity-0 group-hover:opacity-60"
                      )}
                    >
                      {/* Drag grip — only rendered and draggable when locked */}
                      {isLocked && (
                        <div
                          draggable
                          className="cursor-grab text-muted-foreground hover:text-primary transition-colors"
                          onDragStart={(e) => {
                            e.dataTransfer.setData("text/plain", String(lockedIdx));
                            dragColFromRef.current = lockedIdx;
                          }}
                          title="Drag to reorder"
                        >
                          <GripVertical size={12} />
                        </div>
                      )}
                      <button
                        className={cn(
                          "transition-colors",
                          isLocked ? "text-primary hover:text-destructive" : "text-muted-foreground hover:text-primary"
                        )}
                        onClick={(e) => { e.stopPropagation(); toggleLock(col); }}
                        title={isLocked ? "Unpin column" : "Pin column"}
                      >
                        <Pin size={12} fill={isLocked ? "currentColor" : "none"} />
                      </button>
                    </div>

                    {/* Resize handle */}
                    <div
                      className="absolute right-0 top-0 h-full w-2.5 cursor-col-resize z-20"
                      onMouseDown={(e) => { e.preventDefault(); e.stopPropagation(); startResize(col, e.clientX); }}
                    >
                      <div className="absolute right-0 top-1/4 h-1/2 w-0.5 rounded-full bg-border group-hover:bg-primary group-hover:w-1 transition-all duration-150" />
                    </div>
                  </div>
                );
              })}
            </div>

            {/* ── Pinned rows zone ───────────────────────────────────────── */}
            {lockedRows.length > 0 && (
              <div style={{ position: "sticky", top: HEADER_HEIGHT, zIndex: 8 }}>
                {lockedRows.map((rowIdx, displayIdx) => {
                  const row = getRow(uuid, rowIdx);
                  return (
                    <div
                      key={rowIdx}
                      className="flex border-b-2 border-primary/25 bg-card"
                      style={{ height: ROW_HEIGHT }}
                      onDragOver={(e) => e.preventDefault()}
                      onDrop={(e) => {
                        e.preventDefault();
                        const raw  = e.dataTransfer.getData("text/plain");
                        const from = dragRowFromRef.current ?? (raw !== "" ? parseInt(raw) : null);
                        if (from !== null && from !== displayIdx) reorderLockedRows(uuid, from, displayIdx);
                        dragRowFromRef.current = null;
                      }}
                    >
                      {/* Row-index cell — grip + row number + unpin */}
                      <div
                        className="shrink-0 flex items-center gap-1 px-1.5 border-r border-primary/25 text-[10px] text-primary/70 tabular-nums"
                        style={{ width: ROW_INDEX_W, minWidth: ROW_INDEX_W, ...lockedStyle(5) }}
                      >
                        <div
                          draggable
                          className="cursor-grab text-muted-foreground hover:text-primary transition-colors shrink-0"
                          onDragStart={(e) => {
                            e.dataTransfer.setData("text/plain", String(displayIdx));
                            dragRowFromRef.current = displayIdx;
                          }}
                          title="Drag to reorder"
                        >
                          <GripVertical size={12} />
                        </div>
                        <span className="flex-1 text-right tabular-nums">{rowIdx}</span>
                        <button
                          className="hover:text-destructive transition-colors leading-none shrink-0"
                          onClick={() => handleToggleRow(rowIdx)}
                          title="Unpin row"
                        >
                          ×
                        </button>
                      </div>

                      {/* Data cells */}
                      {orderedCols.map((col) => {
                        const isColLocked = lockedColSet.has(col);
                        const origIdx     = meta.columns.indexOf(col);
                        const colW        = getWidth(col);
                        const cell        = row ? row[origIdx] : undefined;
                        const display     = cell == null ? "null" : String(cell);
                        const isNull      = cell == null;
                        return (
                          <div
                            key={col}
                            data-cell
                            className="px-2 py-1.5 border-r border-primary/20 last:border-r-0 overflow-hidden"
                            style={{
                              width: colW, minWidth: colW, maxWidth: colW,
                              ...(isColLocked ? lockedStyle(5) : {}),
                            }}
                          >
                            {row ? (
                              <span className={cn("block truncate text-[11px]", isNull && "text-muted-foreground/40 italic")}>
                                {display}
                              </span>
                            ) : (
                              <div className="h-3 w-3/4 rounded bg-muted/40 animate-pulse" />
                            )}
                          </div>
                        );
                      })}
                    </div>
                  );
                })}
              </div>
            )}

            {/* ── Virtual scroll body ────────────────────────────────────── */}
            <div style={{ height: `${virtualizer.getTotalSize()}px`, position: "relative" }}>
              {items.map((vRow) => {
                // Locked rows: invisible placeholder preserves virtualizer scroll position
                if (lockedRowSet.has(vRow.index)) {
                  return (
                    <div
                      key={vRow.key}
                      data-index={vRow.index}
                      ref={virtualizer.measureElement}
                      className="absolute w-full"
                      style={{ top: vRow.start, height: ROW_HEIGHT }}
                    />
                  );
                }

                const row = getRow(uuid, vRow.index);
                return (
                  <div
                    key={vRow.key}
                    data-index={vRow.index}
                    ref={virtualizer.measureElement}
                    className="absolute flex w-full border-b border-border/40 hover:bg-muted/20 transition-colors group/row"
                    style={{ top: vRow.start }}
                  >
                    {/* Row-index cell with hover pin button */}
                    <div
                      className="shrink-0 flex items-center justify-end gap-0.5 px-1.5 border-r border-border/40 text-[11px] text-muted-foreground/40 tabular-nums"
                      style={{ width: ROW_INDEX_W, minWidth: ROW_INDEX_W, ...lockedStyle(5) }}
                    >
                      <button
                        className="opacity-0 group-hover/row:opacity-50 hover:!opacity-100 hover:text-primary transition-opacity shrink-0"
                        onClick={() => handleToggleRow(vRow.index)}
                        title="Pin row"
                      >
                        <Pin size={9} />
                      </button>
                      <span>{vRow.index}</span>
                    </div>

                    {/* Data cells */}
                    {orderedCols.map((col) => {
                      const isColLocked = lockedColSet.has(col);
                      const origIdx     = meta.columns.indexOf(col);
                      const colW        = getWidth(col);

                      if (!row) {
                        return (
                          <div
                            key={col}
                            data-cell
                            className="px-2 py-1.5 border-r border-border/40 last:border-r-0"
                            style={{
                              width: colW, minWidth: colW, maxWidth: colW,
                              ...(isColLocked ? lockedStyle(5) : {}),
                            }}
                          >
                            <div className="h-3 w-3/4 rounded bg-muted/40 animate-pulse" />
                          </div>
                        );
                      }

                      const cell    = row[origIdx];
                      const display = cell === null ? "null" : String(cell);
                      const isNull  = cell === null;

                      return (
                        <Tooltip key={col}>
                          <TooltipTrigger asChild>
                            <div
                              data-cell
                              className="px-2 py-1.5 border-r border-border/40 last:border-r-0 overflow-hidden cursor-default"
                              style={{
                                width: colW, minWidth: colW, maxWidth: colW,
                                ...(isColLocked ? lockedStyle(5) : {}),
                              }}
                            >
                              <span className={cn("block truncate", isNull && "text-muted-foreground/40 italic")}>
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
                    })}
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
