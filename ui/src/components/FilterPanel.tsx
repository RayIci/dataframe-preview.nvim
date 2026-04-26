import { useState, useEffect, useRef } from "react";
import {
  FilterNode, FilterGroup, FilterCondition,
  newFilterId, emptyFilterTree,
} from "@/store/dataStore";

// ─── Operator definitions ────────────────────────────────────────────────────

type OperatorDef = { value: string; label: string };

const OPERATORS: Record<string, OperatorDef[]> = {
  numeric: [
    { value: "equals",     label: "=" },
    { value: "not_equals", label: "≠" },
    { value: "gt",         label: ">" },
    { value: "gte",        label: "≥" },
    { value: "lt",         label: "<" },
    { value: "lte",        label: "≤" },
  ],
  datetime: [
    { value: "equals", label: "=" },
    { value: "gt",     label: ">" },
    { value: "gte",    label: "≥" },
    { value: "lt",     label: "<" },
    { value: "lte",    label: "≤" },
  ],
  string: [
    { value: "contains",     label: "contains" },
    { value: "not_contains", label: "not contains" },
    { value: "equals",       label: "equals" },
    { value: "not_equals",   label: "not equals" },
    { value: "starts_with",  label: "starts with" },
    { value: "ends_with",    label: "ends with" },
  ],
};

function getDtypeCategory(dtype: string): keyof typeof OPERATORS {
  if (/^(int|uint|float)/.test(dtype)) return "numeric";
  if (/^(datetime|timedelta)/.test(dtype)) return "datetime";
  return "string";
}

function defaultOp(dtype: string): string {
  return OPERATORS[getDtypeCategory(dtype)][0].value;
}

// ─── Immutable tree helpers ───────────────────────────────────────────────────

function mapGroup(group: FilterGroup, fn: (g: FilterGroup) => FilterGroup): FilterGroup {
  const updated = fn(group);
  return {
    ...updated,
    children: updated.children.map((child) =>
      child.type === "group" ? mapGroup(child, fn) : child
    ),
  };
}

function addChild(tree: FilterGroup, parentId: string, child: FilterNode): FilterGroup {
  return mapGroup(tree, (g) =>
    g.id === parentId ? { ...g, children: [...g.children, child] } : g
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
      c.type === "condition" && c.id === condId ? { ...c, ...patch } : c
    ),
  }));
}

function updateGroupLogic(tree: FilterGroup, groupId: string, logic: "AND" | "OR"): FilterGroup {
  return mapGroup(tree, (g) => (g.id === groupId ? { ...g, logic } : g));
}

// ─── Shared style constants ───────────────────────────────────────────────────

const selectCls =
  "rounded border border-border bg-background px-1.5 py-1 text-xs text-foreground focus:outline-none focus:ring-1 focus:ring-ring";

// ─── FilterConditionRow ───────────────────────────────────────────────────────

interface ConditionRowProps {
  condition: FilterCondition;
  columns:   string[];
  dtypes:    string[];
  onChange:  (patch: Partial<Omit<FilterCondition, "type" | "id">>) => void;
  onRemove:  () => void;
}

function FilterConditionRow({ condition, columns, dtypes, onChange, onRemove }: ConditionRowProps) {
  const colIdx  = columns.indexOf(condition.column);
  const dtype   = dtypes[colIdx] ?? "object";
  const ops     = OPERATORS[getDtypeCategory(dtype)];

  function handleColChange(col: string) {
    const newDtype = dtypes[columns.indexOf(col)] ?? "object";
    onChange({ column: col, operator: defaultOp(newDtype) });
  }

  return (
    <div className="flex items-center gap-1 py-0.5">
      <select
        className={`${selectCls} w-24 shrink-0`}
        value={condition.column}
        onChange={(e) => handleColChange(e.target.value)}
      >
        {columns.map((c) => <option key={c} value={c}>{c}</option>)}
      </select>
      <select
        className={`${selectCls} w-24 shrink-0`}
        value={condition.operator}
        onChange={(e) => onChange({ operator: e.target.value })}
      >
        {ops.map((op) => <option key={op.value} value={op.value}>{op.label}</option>)}
      </select>
      <input
        type="text"
        className={`${selectCls} flex-1 min-w-0`}
        placeholder="value…"
        value={condition.value}
        onChange={(e) => onChange({ value: e.target.value })}
      />
      <button
        className="shrink-0 text-muted-foreground hover:text-foreground px-1"
        onClick={onRemove}
        title="Remove condition"
      >
        ×
      </button>
    </div>
  );
}

// ─── FilterGroupEditor (recursive) ───────────────────────────────────────────

interface GroupEditorProps {
  group:    FilterGroup;
  columns:  string[];
  dtypes:   string[];
  onUpdate: (updated: FilterGroup) => void;   // root update bubbles here
  onRemove?: () => void;
  depth:    number;
}

function FilterGroupEditor({ group, columns, dtypes, onUpdate, onRemove, depth }: GroupEditorProps) {
  const indentColor = ["border-blue-800", "border-purple-800", "border-teal-800"][depth % 3];

  function addCondition() {
    const dtype = dtypes[0] ?? "object";
    const cond: FilterCondition = {
      type:     "condition",
      id:       newFilterId(),
      column:   columns[0] ?? "",
      operator: defaultOp(dtype),
      value:    "",
    };
    onUpdate(addChild(group, group.id, cond) as FilterGroup);
  }

  function addGroup() {
    const sub: FilterGroup = { ...emptyFilterTree() };
    onUpdate(addChild(group, group.id, sub) as FilterGroup);
  }

  function handleLogicChange(logic: "AND" | "OR") {
    onUpdate(updateGroupLogic(group, group.id, logic) as FilterGroup);
  }

  function handleConditionChange(condId: string, patch: Partial<Omit<FilterCondition, "type" | "id">>) {
    onUpdate(updateCondition(group, condId, patch) as FilterGroup);
  }

  function handleRemoveNode(nodeId: string) {
    onUpdate(removeNode(group, nodeId) as FilterGroup);
  }

  // When a nested group is updated, propagate upward through the tree
  function handleChildGroupUpdate(childId: string, updated: FilterGroup) {
    onUpdate(
      mapGroup(group, (g) => ({
        ...g,
        children: g.children.map((c) =>
          c.type === "group" && c.id === childId ? updated : c
        ),
      })) as FilterGroup
    );
  }

  return (
    <div className={`border-l-2 ${indentColor} pl-2 mt-1`}>
      {/* Group header: logic selector + remove button */}
      <div className="flex items-center gap-1 mb-1">
        <select
          className={`${selectCls} w-16`}
          value={group.logic}
          onChange={(e) => handleLogicChange(e.target.value as "AND" | "OR")}
        >
          <option value="AND">AND</option>
          <option value="OR">OR</option>
        </select>
        <span className="text-muted-foreground text-[10px]">group</span>
        {onRemove && (
          <button
            className="ml-auto text-muted-foreground hover:text-foreground px-1 text-xs"
            onClick={onRemove}
            title="Remove group"
          >
            × group
          </button>
        )}
      </div>

      {/* Children */}
      {group.children.map((child) => {
        if (child.type === "condition") {
          return (
            <FilterConditionRow
              key={child.id}
              condition={child}
              columns={columns}
              dtypes={dtypes}
              onChange={(patch) => handleConditionChange(child.id, patch)}
              onRemove={() => handleRemoveNode(child.id)}
            />
          );
        }
        // Nested group
        return (
          <FilterGroupEditor
            key={child.id}
            group={child}
            columns={columns}
            dtypes={dtypes}
            onUpdate={(updated) => handleChildGroupUpdate(child.id, updated)}
            onRemove={() => handleRemoveNode(child.id)}
            depth={depth + 1}
          />
        );
      })}

      {/* Add buttons */}
      <div className="flex gap-1.5 mt-1.5">
        <button
          className="text-xs text-muted-foreground hover:text-foreground border border-dashed border-border rounded px-2 py-0.5"
          onClick={addCondition}
        >
          + condition
        </button>
        <button
          className="text-xs text-muted-foreground hover:text-foreground border border-dashed border-border rounded px-2 py-0.5"
          onClick={addGroup}
        >
          + group
        </button>
      </div>
    </div>
  );
}

// ─── FilterPanel (top-level container) ───────────────────────────────────────

interface FilterPanelProps {
  columns:    string[];
  dtypes:     string[];
  filterTree: FilterGroup;
  initialCol?: string;
  onApply:    (tree: FilterGroup) => void;
  onClose:    () => void;
}

export function FilterPanel({ columns, dtypes, filterTree, initialCol, onApply, onClose }: FilterPanelProps) {
  const panelRef = useRef<HTMLDivElement>(null);

  // Local copy for editing before Apply
  const [localTree, setLocalTree] = useState<FilterGroup>(() => {
    // If tree is empty and we have an initial column, pre-add one condition
    if (filterTree.children.length === 0 && initialCol) {
      const colIdx = columns.indexOf(initialCol);
      const dtype  = dtypes[colIdx] ?? "object";
      const cond: FilterCondition = {
        type:     "condition",
        id:       newFilterId(),
        column:   initialCol,
        operator: defaultOp(dtype),
        value:    "",
      };
      return { ...filterTree, children: [cond] };
    }
    return filterTree;
  });

  // Close on outside click
  useEffect(() => {
    function onDown(e: MouseEvent) {
      if (panelRef.current && !panelRef.current.contains(e.target as Node)) onClose();
    }
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [onClose]);

  // Close on Escape
  useEffect(() => {
    function onKey(e: KeyboardEvent) { if (e.key === "Escape") onClose(); }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div
      ref={panelRef}
      className="fixed top-12 right-4 z-50 w-[420px] max-h-[80vh] flex flex-col rounded-md border border-border bg-card shadow-xl text-xs"
    >
      {/* Header */}
      <div className="flex items-center justify-between px-3 py-2 border-b border-border shrink-0">
        <span className="font-medium text-foreground">Filter Builder</span>
        <button className="text-muted-foreground hover:text-foreground" onClick={onClose}>×</button>
      </div>

      {/* Scrollable tree area */}
      <div className="flex-1 overflow-y-auto px-3 py-2">
        <FilterGroupEditor
          group={localTree}
          columns={columns}
          dtypes={dtypes}
          onUpdate={setLocalTree}
          depth={0}
        />
      </div>

      {/* Footer buttons */}
      <div className="flex gap-1.5 px-3 py-2 border-t border-border justify-end shrink-0">
        <button
          className="rounded border border-border px-2 py-1 text-muted-foreground hover:text-foreground hover:bg-muted"
          onClick={() => { setLocalTree(emptyFilterTree()); onApply(emptyFilterTree()); }}
        >
          Clear all
        </button>
        <button
          className="rounded bg-primary px-2 py-1 text-primary-foreground hover:opacity-90"
          onClick={() => onApply(localTree)}
        >
          Apply
        </button>
      </div>
    </div>
  );
}
