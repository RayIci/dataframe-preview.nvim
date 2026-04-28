import { create } from "zustand";

// ── Types ──────────────────────────────────────────────────────────────────

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

export interface FilterCondition {
  type:     "condition";
  id:       string;
  column:   string;
  operator: string;
  value:    string;
}

export interface FilterGroup {
  type:     "group";
  id:       string;
  logic:    "AND" | "OR";
  children: FilterNode[];
}

export type FilterNode = FilterCondition | FilterGroup;

type RowCell  = string | number | boolean | null;
type RowChunk = RowCell[][];

// ── Filter helpers ─────────────────────────────────────────────────────────

let _fid = 0;
export function newFilterId(): string { return String(++_fid); }

export function emptyFilterTree(): FilterGroup {
  return { type: "group", id: newFilterId(), logic: "AND", children: [] };
}

export function countConditions(node: FilterNode): number {
  if (node.type === "condition") return 1;
  return node.children.reduce((sum, c) => sum + countConditions(c), 0);
}

export function hasActiveFilter(tree: FilterGroup): boolean {
  return countConditions(tree) > 0;
}

export function hasConditionForCol(node: FilterNode, col: string): boolean {
  if (node.type === "condition") return node.column === col;
  return node.children.some((c) => hasConditionForCol(c, col));
}

// ── Per-session data ───────────────────────────────────────────────────────

export interface SessionData {
  meta:          Meta | null;
  rowCache:      Map<number, RowChunk>;
  loading:       boolean;
  error:         string | null;
  sort:          SortEntry[];
  filterTree:    FilterGroup;
  scrollVersion: number;
}

function emptySessionData(): SessionData {
  return {
    meta:          null,
    rowCache:      new Map(),
    loading:       true,
    error:         null,
    sort:          [],
    filterTree:    emptyFilterTree(),
    scrollVersion: 0,
  };
}

const CHUNK_SIZE = 100;

// ── Store ──────────────────────────────────────────────────────────────────

interface DataStore {
  dataByUuid: Map<string, SessionData>;
  wsStatus:   "connecting" | "open" | "closed" | "error";

  initSession:   (uuid: string) => void;
  setMeta:       (uuid: string, meta: Meta) => void;
  addRows:       (uuid: string, offset: number, rows: RowChunk) => void;
  setError:      (uuid: string, msg: string | null) => void;
  setSortFilter: (uuid: string, sort: SortEntry[], filterTree: FilterGroup) => void;
  setWsStatus:   (s: DataStore["wsStatus"]) => void;
  getData:       (uuid: string) => SessionData | undefined;
  hasRows:       (uuid: string, offset: number) => boolean;
  getRow:        (uuid: string, index: number) => RowCell[] | undefined;
}

function patchSession(
  map: Map<string, SessionData>,
  uuid: string,
  patch: Partial<SessionData>
): Map<string, SessionData> {
  const existing = map.get(uuid) ?? emptySessionData();
  const next = new Map(map);
  next.set(uuid, { ...existing, ...patch });
  return next;
}

export const useDataStore = create<DataStore>((set, get) => ({
  dataByUuid: new Map(),
  wsStatus:   "connecting",

  initSession: (uuid) =>
    set((s) => {
      if (s.dataByUuid.has(uuid)) return s;
      const next = new Map(s.dataByUuid);
      next.set(uuid, emptySessionData());
      return { dataByUuid: next };
    }),

  setMeta: (uuid, meta) =>
    set((s) => ({
      dataByUuid: patchSession(s.dataByUuid, uuid, { meta, loading: false }),
    })),

  addRows: (uuid, offset, rows) =>
    set((s) => {
      const session = s.dataByUuid.get(uuid) ?? emptySessionData();
      const newCache = new Map(session.rowCache);
      newCache.set(offset, rows);
      return { dataByUuid: patchSession(s.dataByUuid, uuid, { rowCache: newCache }) };
    }),

  setError: (uuid, msg) =>
    set((s) => ({
      dataByUuid: patchSession(s.dataByUuid, uuid, { error: msg, loading: false }),
    })),

  setSortFilter: (uuid, sort, filterTree) =>
    set((s) => {
      const session = s.dataByUuid.get(uuid) ?? emptySessionData();
      return {
        dataByUuid: patchSession(s.dataByUuid, uuid, {
          sort,
          filterTree,
          rowCache:      new Map(),
          scrollVersion: session.scrollVersion + 1,
        }),
      };
    }),

  setWsStatus: (wsStatus) => set({ wsStatus }),

  getData:  (uuid) => get().dataByUuid.get(uuid),

  hasRows: (uuid, offset) =>
    get().dataByUuid.get(uuid)?.rowCache.has(offset) ?? false,

  getRow: (uuid, index) => {
    const chunkOffset = Math.floor(index / CHUNK_SIZE) * CHUNK_SIZE;
    const chunk = get().dataByUuid.get(uuid)?.rowCache.get(chunkOffset);
    return chunk?.[index - chunkOffset];
  },
}));
