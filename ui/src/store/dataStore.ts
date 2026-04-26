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

export interface FilterCondition {
  id:       string;   // client-only; stripped before sending to server
  column:   string;
  operator: string;
  value:    string;
}

export type FilterLogic = "AND" | "OR";

let _fid = 0;
export function newFilterId(): string { return String(++_fid); }

type RowChunk = (string | number | boolean | null)[][];

interface DataStore {
  meta:          Meta | null;
  rowCache:      Map<number, RowChunk>;
  loading:       boolean;
  error:         string | null;
  wsStatus:      "connecting" | "open" | "closed" | "error";
  sort:          SortEntry[];
  filter:        FilterCondition[];
  filterLogic:   FilterLogic;
  scrollVersion: number;

  setMeta:       (meta: Meta) => void;
  addRows:       (offset: number, rows: RowChunk) => void;
  setLoading:    (v: boolean) => void;
  setError:      (msg: string | null) => void;
  setWsStatus:   (s: DataStore["wsStatus"]) => void;
  setSortFilter: (sort: SortEntry[], filter: FilterCondition[], logic: FilterLogic) => void;
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
  filter:        [],
  filterLogic:   "AND",
  scrollVersion: 0,

  setMeta:     (meta)   => set({ meta, loading: false }),
  setLoading:  (v)      => set({ loading: v }),
  setError:    (msg)    => set({ error: msg, loading: false }),
  setWsStatus: (s)      => set({ wsStatus: s }),

  setSortFilter: (sort, filter, logic) =>
    set((s) => ({
      sort,
      filter,
      filterLogic:   logic,
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
