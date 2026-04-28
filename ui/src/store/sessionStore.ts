import { create } from "zustand";

export interface SessionInfo {
  uuid:      string;
  var_name:  string;
  row_count: number;
  col_count: number;
  columns:   string[];
  dtypes:    string[];
  isNew:     boolean;
}

interface SessionStore {
  sessions:   SessionInfo[];
  activeUuid: string | null;
  addSession:  (info: Omit<SessionInfo, "isNew">) => void;
  setActive:   (uuid: string) => void;
  setSessions: (sessions: Omit<SessionInfo, "isNew">[]) => void;
}

export const useSessionStore = create<SessionStore>((set) => ({
  sessions:   [],
  activeUuid: null,

  addSession: (info) =>
    set((s) => {
      if (s.sessions.find((x) => x.uuid === info.uuid)) return s;
      const newSession: SessionInfo = { ...info, isNew: true };
      return {
        sessions:   [...s.sessions, newSession],
        activeUuid: s.activeUuid ?? info.uuid,
      };
    }),

  setActive: (uuid) =>
    set((s) => ({
      activeUuid: uuid,
      sessions:   s.sessions.map((x) =>
        x.uuid === uuid ? { ...x, isNew: false } : x
      ),
    })),

  setSessions: (sessions) =>
    set((s) => {
      const existing = new Set(s.sessions.map((x) => x.uuid));
      const fresh = sessions
        .filter((x) => !existing.has(x.uuid))
        .map((x) => ({ ...x, isNew: false }));
      return {
        sessions:   [...s.sessions, ...fresh],
        activeUuid: s.activeUuid ?? sessions[0]?.uuid ?? null,
      };
    }),
}));
