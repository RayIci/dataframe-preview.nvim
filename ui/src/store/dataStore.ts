import { create } from "zustand";

export interface Meta {
  var_name:  string;
  row_count: number;
  col_count: number;
  columns:   string[];
  dtypes:    string[];
}

type RowChunk = (string | number | boolean | null)[][];

interface DataStore {
  meta:        Meta | null;
  rowCache:    Map<number, RowChunk>;  // offset → rows
  loading:     boolean;
  error:       string | null;
  wsStatus:    "connecting" | "open" | "closed" | "error";

  setMeta:      (meta: Meta) => void;
  addRows:      (offset: number, rows: RowChunk) => void;
  setLoading:   (v: boolean) => void;
  setError:     (msg: string | null) => void;
  setWsStatus:  (s: DataStore["wsStatus"]) => void;
  hasRows:      (offset: number) => boolean;
  getRow:       (index: number) => (string | number | boolean | null)[] | undefined;
}

export const useDataStore = create<DataStore>((set, get) => ({
  meta:     null,
  rowCache: new Map(),
  loading:  true,
  error:    null,
  wsStatus: "connecting",

  setMeta:     (meta)   => set({ meta, loading: false }),
  setLoading:  (v)      => set({ loading: v }),
  setError:    (msg)    => set({ error: msg, loading: false }),
  setWsStatus: (s)      => set({ wsStatus: s }),

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
