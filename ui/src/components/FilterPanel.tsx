import { useState, useEffect, useRef } from "react";
import { FilterCondition, FilterLogic, newFilterId } from "@/store/dataStore";

interface FilterPanelProps {
  columns:    string[];
  dtypes:     string[];
  conditions: FilterCondition[];
  logic:      FilterLogic;
  initialCol?: string;
  onApply:    (conditions: FilterCondition[], logic: FilterLogic) => void;
  onClose:    () => void;
}

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

const selectCls = "rounded border border-border bg-background px-1.5 py-1 text-xs text-foreground focus:outline-none focus:ring-1 focus:ring-ring";
const btnCls    = "rounded px-2 py-1 text-xs";

export function FilterPanel({
  columns, dtypes, conditions, logic, initialCol, onApply, onClose,
}: FilterPanelProps) {
  const panelRef = useRef<HTMLDivElement>(null);

  const [localConditions, setLocalConditions] = useState<FilterCondition[]>(conditions);
  const [localLogic, setLocalLogic] = useState<FilterLogic>(logic);

  const firstCol  = initialCol ?? columns[0] ?? "";
  const firstDtype = dtypes[columns.indexOf(firstCol)] ?? "object";

  const [addCol, setAddCol] = useState(firstCol);
  const [addOp,  setAddOp]  = useState(() => defaultOp(firstDtype));
  const [addVal, setAddVal] = useState("");

  // When addCol changes, reset operator to the first one for that dtype
  function handleAddColChange(col: string) {
    setAddCol(col);
    const idx   = columns.indexOf(col);
    const dtype = dtypes[idx] ?? "object";
    setAddOp(defaultOp(dtype));
  }

  function addCondition() {
    if (!addVal.trim()) return;
    setLocalConditions((prev) => [
      ...prev,
      { id: newFilterId(), column: addCol, operator: addOp, value: addVal.trim() },
    ]);
    setAddVal("");
  }

  function removeCondition(id: string) {
    setLocalConditions((prev) => prev.filter((c) => c.id !== id));
  }

  function handleAddKeyDown(e: React.KeyboardEvent) {
    if (e.key === "Enter") addCondition();
  }

  // Close on outside click
  useEffect(() => {
    function handleClick(e: MouseEvent) {
      if (panelRef.current && !panelRef.current.contains(e.target as Node)) onClose();
    }
    document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, [onClose]);

  // Close on Escape
  useEffect(() => {
    function handleKey(e: KeyboardEvent) { if (e.key === "Escape") onClose(); }
    document.addEventListener("keydown", handleKey);
    return () => document.removeEventListener("keydown", handleKey);
  }, [onClose]);

  const addColDtype = dtypes[columns.indexOf(addCol)] ?? "object";
  const addOps      = OPERATORS[getDtypeCategory(addColDtype)];

  return (
    <div
      ref={panelRef}
      className="fixed top-12 right-4 z-50 w-80 rounded-md border border-border bg-card shadow-xl text-xs"
    >
      {/* Header */}
      <div className="flex items-center justify-between px-3 py-2 border-b border-border">
        <span className="font-medium text-foreground">Filters</span>
        <button className="text-muted-foreground hover:text-foreground" onClick={onClose}>×</button>
      </div>

      {/* Logic selector */}
      <div className="flex items-center gap-2 px-3 py-2 border-b border-border">
        <span className="text-muted-foreground">Logic:</span>
        <select
          className={selectCls}
          value={localLogic}
          onChange={(e) => setLocalLogic(e.target.value as FilterLogic)}
        >
          <option value="AND">AND — all conditions must match</option>
          <option value="OR">OR — any condition must match</option>
        </select>
      </div>

      {/* Active conditions */}
      {localConditions.length > 0 && (
        <div className="px-3 py-2 border-b border-border flex flex-col gap-1 max-h-48 overflow-y-auto">
          {localConditions.map((c) => (
            <div key={c.id} className="flex items-center gap-1 text-foreground">
              <span className="w-20 truncate text-muted-foreground">{c.column}</span>
              <span className="w-20 truncate">{c.operator}</span>
              <span className="flex-1 truncate font-mono">&ldquo;{c.value}&rdquo;</span>
              <button
                className="shrink-0 text-muted-foreground hover:text-foreground"
                onClick={() => removeCondition(c.id)}
              >
                ×
              </button>
            </div>
          ))}
        </div>
      )}

      {/* Add condition form */}
      <div className="px-3 py-2 border-b border-border">
        <div className="text-muted-foreground mb-1.5">Add condition:</div>
        <div className="flex flex-col gap-1.5">
          <div className="flex gap-1">
            <select className={`${selectCls} flex-1`} value={addCol} onChange={(e) => handleAddColChange(e.target.value)}>
              {columns.map((col) => (
                <option key={col} value={col}>{col}</option>
              ))}
            </select>
            <select className={`${selectCls} flex-1`} value={addOp} onChange={(e) => setAddOp(e.target.value)}>
              {addOps.map((op) => (
                <option key={op.value} value={op.value}>{op.label}</option>
              ))}
            </select>
          </div>
          <div className="flex gap-1">
            <input
              autoFocus
              type="text"
              className={`${selectCls} flex-1`}
              placeholder="Value…"
              value={addVal}
              onChange={(e) => setAddVal(e.target.value)}
              onKeyDown={handleAddKeyDown}
            />
            <button
              className={`${btnCls} bg-primary text-primary-foreground hover:opacity-90 disabled:opacity-40`}
              onClick={addCondition}
              disabled={!addVal.trim()}
            >
              Add
            </button>
          </div>
        </div>
      </div>

      {/* Footer buttons */}
      <div className="flex gap-1.5 px-3 py-2 justify-end">
        <button
          className={`${btnCls} border border-border text-muted-foreground hover:text-foreground hover:bg-muted`}
          onClick={() => { setLocalConditions([]); onApply([], localLogic); }}
        >
          Clear all
        </button>
        <button
          className={`${btnCls} bg-primary text-primary-foreground hover:opacity-90`}
          onClick={() => onApply(localConditions, localLogic)}
        >
          Apply
        </button>
      </div>
    </div>
  );
}
