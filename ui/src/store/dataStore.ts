import { create } from "zustand";

export interface Meta {
  var_name:  string;
  row_count: number;
  col_count: number;
  columns:   string[];
  dtypes:    string[];
}

export interface SortEntry {
  column:    string;
  ascending: boolean;
}

// Discriminated union: a condition leaf or a group with children
export interface FilterCondition {
  type:     "condition";
  id:       string;   // client-only; stripped before sending to server
  column:   string;
  operator: string;
  value:    string;
}

export interface FilterGroup {
  type:     "group";
  id:       string;   // client-only; stripped before sending to server
  logic:    "AND" | "OR";
  children: FilterNode[];
}

export type FilterNode = FilterCondition | FilterGroup;

let _fid = 0;
export function newFilterId(): string { return String(++_fid); }

export function emptyFilterTree(): FilterGroup {
  return { type: "group", id: newFilterId(), logic: "AND", children: [] };
}

// Count all condition leaves recursively
export function countConditions(node: FilterNode): number {
  if (node.type === "condition") return 1;
  return node.children.reduce((sum, c) => sum + countConditions(c), 0);
}

// True if the tree has at least one condition leaf
export function hasActiveFilter(tree: FilterGroup): boolean {
  return countConditions(tree) > 0;
}

// Check if any condition in the tree targets the given column
export function hasConditionForCol(node: FilterNode, col: string): boolean {
  if (node.type === "condition") return node.column === col;
  return node.children.some((c) => hasConditionForCol(c, col));
}

type RowChunk = (string | number | boolean | null)[][];

interface DataStore {
  meta:          Meta | null;
  rowCache:      Map<number, RowChunk>;
  loading:       boolean;
  error:         string | null;
  wsStatus:      "connecting" | "open" | "closed" | "error";
  sort:          SortEntry[];
  filterTree:    FilterGroup;
  scrollVersion: number;

  setMeta:       (meta: Meta) => void;
  addRows:       (offset: number, rows: RowChunk) => void;
  setLoading:    (v: boolean) => void;
  setError:      (msg: string | null) => void;
  setWsStatus:   (s: DataStore["wsStatus"]) => void;
  setSortFilter: (sort: SortEntry[], filterTree: FilterGroup) => void;
  hasRows:       (offset: number) => boolean;
  getRow:        (index: number) => (string | number | boolean | null)[] | undefined;
}

export const useDataStore = create<DataStore>((set, get) => ({
  meta:          null,
  rowCache:      new Map(),
  loading:       true,
  error:         null,
  wsStatus:      "connecting",
  sort:          [],
  filterTree:    emptyFilterTree(),
  scrollVersion: 0,

  setMeta:     (meta)   => set({ meta, loading: false }),
  setLoading:  (v)      => set({ loading: v }),
  setError:    (msg)    => set({ error: msg, loading: false }),
  setWsStatus: (s)      => set({ wsStatus: s }),

  setSortFilter: (sort, filterTree) =>
    set((s) => ({
      sort,
      filterTree,
      rowCache:      new Map(),
      scrollVersion: s.scrollVersion + 1,
    })),

  addRows: (offset, rows) =>
    set((state) => {
      const next = new Map(state.rowCache);
      next.set(offset, rows);
      return { rowCache: next };
    }),

  hasRows: (offset) => get().rowCache.has(offset),

  getRow: (index) => {
    const CHUNK = 100;
    const chunkOffset = Math.floor(index / CHUNK) * CHUNK;
    const chunk = get().rowCache.get(chunkOffset);
    return chunk?.[index - chunkOffset];
  },
}));
