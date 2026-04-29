import { useEffect, useState, useCallback } from "react";
import { ChevronDown, Plus, X } from "lucide-react";
import {
  FilterGroup,
  FilterCondition,
  FilterNode,
  SortEntry,
  emptyFilterTree,
  newFilterId,
  countConditions,
} from "@/store/dataStore";
import { useDataStore } from "@/store/dataStore";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Separator } from "@/components/ui/separator";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";

// ── Operator definitions ───────────────────────────────────────────────────

type OperatorDef = { value: string; label: string };

const NULL_OPS: OperatorDef[] = [
  { value: "is_null",     label: "is null" },
  { value: "is_not_null", label: "is not null" },
];

const OPERATORS: Record<string, OperatorDef[]> = {
  numeric: [
    { value: "equals",     label: "=" },
    { value: "not_equals", label: "≠" },
    { value: "gt",         label: ">" },
    { value: "gte",        label: "≥" },
    { value: "lt",         label: "<" },
    { value: "lte",        label: "≤" },
    ...NULL_OPS,
  ],
  datetime: [
    { value: "equals", label: "=" },
    { value: "gt",     label: "after" },
    { value: "gte",    label: "on/after" },
    { value: "lt",     label: "before" },
    { value: "lte",    label: "on/before" },
    ...NULL_OPS,
  ],
  string: [
    { value: "contains",     label: "contains" },
    { value: "not_contains", label: "doesn't contain" },
    { value: "equals",       label: "equals" },
    { value: "not_equals",   label: "not equals" },
    { value: "starts_with",  label: "starts with" },
    { value: "ends_with",    label: "ends with" },
    ...NULL_OPS,
  ],
};

const NO_VALUE_OPS = new Set(["is_null", "is_not_null"]);

type DtypeCategory = "numeric" | "datetime" | "string";

function getDtypeCategory(dtype: string): DtypeCategory {
  if (/^(int|uint|float)/.test(dtype)) return "numeric";
  if (/^(datetime|timedelta)/.test(dtype)) return "datetime";
  return "string";
}

function defaultOp(dtype: string): string {
  return OPERATORS[getDtypeCategory(dtype)][0].value;
}

// ── Datetime helpers ──────────────────────────────────────────────────────

// Extract timezone from a pandas dtype string.
// "datetime64[ns, UTC]" → "UTC"  |  "datetime64[ns]" → null
function extractColTimezone(dtype: string): string | null {
  const m = dtype.match(/\[[^\],]+,\s*([^\]]+)\]/);
  return m ? m[1].trim() : null;
}

// Placeholder for datetime value inputs, reflecting the stored format.
function datetimePlaceholder(dtype: string): string {
  const tz = extractColTimezone(dtype);
  return tz ? `YYYY-MM-DD HH:MM:SS (${tz})` : "YYYY-MM-DD HH:MM:SS";
}

// Accept YYYY-MM-DD or YYYY-MM-DD HH:MM[:SS[.f]] — no inline timezone offset.
const DATETIME_RE = /^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}(:\d{2}(\.\d+)?)?)?$/;

// Radix Select does not allow empty string as an item value — use a sentinel.
const TZ_NONE = "__none__";

function tzToSelect(tz: string | null | undefined): string {
  return tz ?? TZ_NONE;
}
function selectToTz(v: string): string | null {
  return v === TZ_NONE ? null : v;
}

const BASE_TZ_OPTIONS = [
  { value: TZ_NONE,               label: "None (naive)" },
  { value: "UTC",                 label: "UTC" },
  { value: "America/New_York",    label: "America/New_York" },
  { value: "America/Los_Angeles", label: "America/Los_Angeles" },
  { value: "Europe/London",       label: "Europe/London" },
  { value: "Europe/Paris",        label: "Europe/Paris" },
  { value: "Europe/Rome",         label: "Europe/Rome" },
  { value: "Asia/Tokyo",          label: "Asia/Tokyo" },
  { value: "Asia/Shanghai",       label: "Asia/Shanghai" },
  { value: "Australia/Sydney",    label: "Australia/Sydney" },
];

// Ensure the column's own timezone always appears in the list.
function buildTzOptions(colTz: string | null) {
  if (!colTz || BASE_TZ_OPTIONS.some((o) => o.value === colTz)) return BASE_TZ_OPTIONS;
  return [{ value: colTz, label: colTz }, ...BASE_TZ_OPTIONS];
}

// ── Immutable tree helpers ────────────────────────────────────────────────

function mapGroup(
  group: FilterGroup,
  fn: (g: FilterGroup) => FilterGroup,
): FilterGroup {
  const updated = fn(group);
  return {
    ...updated,
    children: updated.children.map((child) =>
      child.type === "group" ? mapGroup(child, fn) : child,
    ),
  };
}

function addChild(
  tree: FilterGroup,
  parentId: string,
  child: FilterNode,
): FilterGroup {
  return mapGroup(tree, (g) =>
    g.id === parentId ? { ...g, children: [...g.children, child] } : g,
  );
}

function removeNode(tree: FilterGroup, nodeId: string): FilterGroup {
  return mapGroup(tree, (g) => ({
    ...g,
    children: g.children.filter((c) => c.id !== nodeId),
  }));
}

function updateCondition(
  tree: FilterGroup,
  condId: string,
  patch: Partial<Omit<FilterCondition, "type" | "id">>,
): FilterGroup {
  return mapGroup(tree, (g) => ({
    ...g,
    children: g.children.map((c) =>
      c.type === "condition" && c.id === condId ? { ...c, ...patch } : c,
    ),
  }));
}

function updateGroupLogic(
  tree: FilterGroup,
  groupId: string,
  logic: "AND" | "OR",
): FilterGroup {
  return mapGroup(tree, (g) => (g.id === groupId ? { ...g, logic } : g));
}

// ── ConditionRow ──────────────────────────────────────────────────────────

interface ConditionRowProps {
  condition: FilterCondition;
  columns: string[];
  dtypes: string[];
  onChange: (patch: Partial<Omit<FilterCondition, "type" | "id">>) => void;
  onRemove: () => void;
}

function ConditionRow({
  condition,
  columns,
  dtypes,
  onChange,
  onRemove,
}: ConditionRowProps) {
  const colIdx    = columns.indexOf(condition.column);
  const dtype     = dtypes[colIdx] ?? "object";
  const cat       = getDtypeCategory(dtype);
  const ops       = OPERATORS[cat];
  const isDatetime = cat === "datetime";
  const noValue   = NO_VALUE_OPS.has(condition.operator);

  const isInvalid =
    isDatetime && !noValue && condition.value !== "" && !DATETIME_RE.test(condition.value);

  const tzOptions = buildTzOptions(condition.col_timezone ?? null);

  const handleColChange = (col: string) => {
    const idx    = columns.indexOf(col);
    const newType = dtypes[idx] ?? "object";
    const colTz  = extractColTimezone(newType);
    onChange({
      column:          col,
      operator:        defaultOp(newType),
      dtype_category:  getDtypeCategory(newType),
      col_timezone:    colTz,
      filter_timezone: colTz,
    });
  };

  return (
    <div className="flex items-center gap-1.5 py-0.5 group/row">
      {/* Column */}
      <Select value={condition.column} onValueChange={handleColChange}>
        <SelectTrigger className="h-7 w-32 text-xs">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {columns.map((c) => (
            <SelectItem key={c} value={c} className="text-xs">
              {c}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      {/* Operator */}
      <Select
        value={condition.operator}
        onValueChange={(v) => onChange({ operator: v })}
      >
        <SelectTrigger className="h-7 w-28 text-xs">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {ops.map((op) => (
            <SelectItem key={op.value} value={op.value} className="text-xs">
              {op.label}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      {/* Value — hidden for null operators */}
      {!noValue && (
        <Input
          className={cn(
            "h-7 flex-1 min-w-0 text-xs",
            isInvalid && "border-destructive focus-visible:ring-destructive",
          )}
          placeholder={isDatetime ? datetimePlaceholder(dtype) : "value…"}
          value={condition.value}
          onChange={(e) => onChange({ value: e.target.value })}
        />
      )}

      {/* Timezone selector — datetime columns only, hidden for null operators */}
      {isDatetime && !noValue && (
        <Select
          value={tzToSelect(condition.filter_timezone)}
          onValueChange={(v) => onChange({ filter_timezone: selectToTz(v) })}
        >
          <SelectTrigger className="h-7 w-36 text-xs shrink-0">
            <SelectValue placeholder="tz…" />
          </SelectTrigger>
          <SelectContent>
            {tzOptions.map((tz) => (
              <SelectItem key={tz.value} value={tz.value} className="text-xs">
                {tz.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      )}

      {/* Remove */}
      <button
        className="shrink-0 text-muted-foreground hover:text-destructive opacity-0 group-hover/row:opacity-100 transition-opacity"
        onClick={onRemove}
        aria-label="Remove condition"
      >
        <X size={13} />
      </button>
    </div>
  );
}

// ── GroupEditor (recursive) ────────────────────────────────────────────────

const GROUP_COLORS = [
  "border-primary/40",
  "border-secondary-foreground/30",
  "border-muted-foreground/30",
];

interface GroupEditorProps {
  group: FilterGroup;
  columns: string[];
  dtypes: string[];
  onUpdate: (g: FilterGroup) => void;
  onRemove?: () => void;
  depth: number;
}

function GroupEditor({
  group,
  columns,
  dtypes,
  onUpdate,
  onRemove,
  depth,
}: GroupEditorProps) {
  const color = GROUP_COLORS[depth % GROUP_COLORS.length];

  const addCondition = () => {
    const dtype  = dtypes[0] ?? "object";
    const colTz  = extractColTimezone(dtype);
    const cond: FilterCondition = {
      type:            "condition",
      id:              newFilterId(),
      column:          columns[0] ?? "",
      operator:        defaultOp(dtype),
      value:           "",
      dtype_category:  getDtypeCategory(dtype),
      col_timezone:    colTz,
      filter_timezone: colTz,
    };
    onUpdate(addChild(group, group.id, cond) as FilterGroup);
  };

  const addSubGroup = () => {
    onUpdate(addChild(group, group.id, emptyFilterTree()) as FilterGroup);
  };

  return (
    <div className={cn("border-l-2 pl-3 mt-1", color)}>
      {/* Group header */}
      <div className="flex items-center gap-1.5 mb-1.5">
        <Select
          value={group.logic}
          onValueChange={(v) =>
            onUpdate(updateGroupLogic(group, group.id, v as "AND" | "OR"))
          }
        >
          <SelectTrigger className="h-6 w-16 text-[10px] font-semibold">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="AND" className="text-xs">
              AND
            </SelectItem>
            <SelectItem value="OR" className="text-xs">
              OR
            </SelectItem>
          </SelectContent>
        </Select>

        <span className="text-[10px] text-muted-foreground uppercase tracking-wide">
          group
        </span>

        {onRemove && (
          <button
            className="ml-auto text-muted-foreground hover:text-destructive text-[10px] flex items-center gap-0.5"
            onClick={onRemove}
          >
            <X size={11} /> remove group
          </button>
        )}
      </div>

      {/* Children */}
      {group.children.map((child) => {
        if (child.type === "condition") {
          return (
            <ConditionRow
              key={child.id}
              condition={child}
              columns={columns}
              dtypes={dtypes}
              onChange={(patch) =>
                onUpdate(updateCondition(group, child.id, patch) as FilterGroup)
              }
              onRemove={() =>
                onUpdate(removeNode(group, child.id) as FilterGroup)
              }
            />
          );
        }
        return (
          <GroupEditor
            key={child.id}
            group={child}
            columns={columns}
            dtypes={dtypes}
            onUpdate={(updated) =>
              onUpdate(
                mapGroup(group, (g) => ({
                  ...g,
                  children: g.children.map((c) =>
                    c.type === "group" && c.id === child.id ? updated : c,
                  ),
                })) as FilterGroup,
              )
            }
            onRemove={() =>
              onUpdate(removeNode(group, child.id) as FilterGroup)
            }
            depth={depth + 1}
          />
        );
      })}

      {/* Add buttons */}
      <div className="flex gap-1.5 mt-1.5">
        <button
          className="flex items-center gap-1 text-[10px] text-muted-foreground hover:text-foreground
                     border border-dashed border-border rounded px-2 py-0.5 transition-colors"
          onClick={addCondition}
        >
          <Plus size={10} /> condition
        </button>
        <button
          className="flex items-center gap-1 text-[10px] text-muted-foreground hover:text-foreground
                     border border-dashed border-border rounded px-2 py-0.5 transition-colors"
          onClick={addSubGroup}
        >
          <Plus size={10} /> group
        </button>
      </div>
    </div>
  );
}

// ── FilterBar ─────────────────────────────────────────────────────────────

interface FilterBarProps {
  uuid: string;
  columns: string[];
  dtypes: string[];
  applySortFilter: (
    uuid: string,
    sort: SortEntry[],
    filterTree: FilterGroup,
  ) => void;
}

export function FilterBar({
  uuid,
  columns,
  dtypes,
  applySortFilter,
}: FilterBarProps) {
  const data = useDataStore((s) => s.getData(uuid));
  const serverSort = data?.sort ?? [];
  const serverTree = data?.filterTree ?? emptyFilterTree();

  const [expanded, setExpanded] = useState(false);
  const [draftSort, setDraftSort] = useState<SortEntry[]>(serverSort);
  const [draftTree, setDraftTree] = useState<FilterGroup>(serverTree);

  // Reset drafts when switching sessions
  useEffect(() => {
    setDraftSort(serverSort);
    setDraftTree(serverTree);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [uuid]);

  const conditionCount = countConditions(draftTree);
  const hasFilter = conditionCount > 0;
  const hasSort = draftSort.length > 0;
  const hasAny = hasFilter || hasSort;

  const handleApply = useCallback(() => {
    applySortFilter(uuid, draftSort, draftTree);
  }, [uuid, draftSort, draftTree, applySortFilter]);

  const handleClear = useCallback(() => {
    const emptySort = [] as SortEntry[];
    const emptyTree = emptyFilterTree();
    setDraftSort(emptySort);
    setDraftTree(emptyTree);
    applySortFilter(uuid, emptySort, emptyTree);
  }, [uuid, applySortFilter]);

  const removeSortEntry = useCallback(
    (col: string) => {
      const next = draftSort.filter((s) => s.column !== col);
      setDraftSort(next);
    },
    [draftSort],
  );

  const toggleSortDir = useCallback((col: string) => {
    setDraftSort((prev) =>
      prev.map((s) =>
        s.column === col ? { ...s, ascending: !s.ascending } : s,
      ),
    );
  }, []);

  const addSortCol = useCallback(
    (col: string) => {
      if (!draftSort.find((s) => s.column === col)) {
        setDraftSort((prev) => [...prev, { column: col, ascending: true }]);
      }
    },
    [draftSort],
  );

  const availableSortCols = columns.filter(
    (c) => !draftSort.find((s) => s.column === c),
  );

  return (
    <div className="border-b border-border bg-card/60 shrink-0 text-xs select-none">
      {/* ── Collapsed bar ── */}
      <div className="flex items-center gap-2 px-3 py-1.5 min-h-[34px]">
        {/* Toggle button */}
        <button
          className="flex items-center gap-1 text-muted-foreground hover:text-foreground font-medium shrink-0 transition-colors"
          onClick={() => setExpanded((e) => !e)}
        >
          <ChevronDown
            size={12}
            className={cn(
              "transition-transform duration-150",
              expanded && "rotate-180",
            )}
          />
          Filters
          {hasAny && !expanded && (
            <span className="ml-1 text-primary font-normal">
              {[
                hasSort && `${draftSort.length} sort`,
                hasFilter && `${conditionCount} filter`,
              ]
                .filter(Boolean)
                .join(", ")}
            </span>
          )}
        </button>

        {/* Chip summary when collapsed */}
        {!expanded && hasAny && (
          <div className="flex flex-wrap items-center gap-1 flex-1 min-w-0 overflow-hidden">
            {draftSort.map((s) => (
              <Badge
                key={s.column}
                variant="secondary"
                className="gap-1 pl-1.5 pr-1 py-0 h-5 cursor-default"
              >
                <button
                  className="hover:text-primary"
                  onClick={() => {
                    toggleSortDir(s.column);
                    handleApply();
                  }}
                >
                  {s.ascending ? "↑" : "↓"}
                </button>
                {s.column}
                <button
                  className="hover:text-destructive ml-0.5"
                  onClick={() => {
                    removeSortEntry(s.column);
                    applySortFilter(
                      uuid,
                      draftSort.filter((x) => x.column !== s.column),
                      draftTree,
                    );
                  }}
                >
                  <X size={10} />
                </button>
              </Badge>
            ))}
            {hasFilter && (
              <Badge
                variant="outline"
                className="text-primary border-primary/30 h-5"
              >
                {conditionCount} condition{conditionCount !== 1 ? "s" : ""}
              </Badge>
            )}
          </div>
        )}

        <div className="flex-1" />

        {hasAny && !expanded && (
          <button
            className="text-muted-foreground hover:text-destructive text-[10px] shrink-0"
            onClick={handleClear}
          >
            clear all
          </button>
        )}
      </div>

      {/* ── Expanded panel ── */}
      {expanded && (
        <div className="px-3 pb-3">
          <Separator className="mb-3" />

          {/* Sort row */}
          <div className="mb-3">
            <div className="flex items-center gap-2 flex-wrap">
              <span className="text-muted-foreground font-medium shrink-0">
                Sort
              </span>

              {draftSort.map((s) => (
                <Badge
                  key={s.column}
                  variant="secondary"
                  className="gap-1 pl-1.5 pr-1 py-0 h-5 cursor-default"
                >
                  <button
                    className="hover:text-primary"
                    title="Toggle direction"
                    onClick={() => toggleSortDir(s.column)}
                  >
                    {s.ascending ? "↑" : "↓"}
                  </button>
                  {s.column}
                  <button
                    className="hover:text-destructive ml-0.5"
                    onClick={() => removeSortEntry(s.column)}
                  >
                    <X size={10} />
                  </button>
                </Badge>
              ))}

              {availableSortCols.length > 0 && (
                <Select onValueChange={addSortCol}>
                  <SelectTrigger className="h-6 w-28 text-[10px]">
                    <div className="flex items-center gap-1 text-muted-foreground">
                      <Plus size={10} /> add column
                    </div>
                  </SelectTrigger>
                  <SelectContent>
                    {availableSortCols.map((c) => (
                      <SelectItem key={c} value={c} className="text-xs">
                        {c}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}
            </div>
          </div>

          <Separator className="mb-3" />

          {/* Filter tree */}
          <div className="mb-3">
            <GroupEditor
              group={draftTree}
              columns={columns}
              dtypes={dtypes}
              onUpdate={setDraftTree}
              depth={0}
            />
          </div>

          {/* Action buttons */}
          <div className="flex items-center gap-1.5 justify-end mt-1">
            <Button
              variant="ghost"
              size="sm"
              className="h-7 text-xs"
              onClick={handleClear}
            >
              Clear all
            </Button>
            <Button size="sm" className="h-7 text-xs" onClick={handleApply}>
              Apply
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}
