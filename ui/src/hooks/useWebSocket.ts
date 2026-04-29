import { useEffect, useRef, useCallback } from "react";
import { useDataStore, SortEntry, FilterGroup, FilterNode } from "@/store/dataStore";
import { useSessionStore, SessionInfo } from "@/store/sessionStore";

const CHUNK_SIZE = 100;

function stripIds(node: FilterNode): object {
  if (node.type === "condition") {
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    const { id: _id, ...rest } = node;
    return rest;
  }
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  const { id: _id, ...rest } = node;
  return { ...rest, children: node.children.map(stripIds) };
}

export function useWebSocket() {
  const wsRef      = useRef<WebSocket | null>(null);
  const pendingRef = useRef<Map<string, Set<number>>>(new Map());

  const sessionStore = useSessionStore();
  const dataStore    = useDataStore();

  const send = useCallback((msg: object) => {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify(msg));
    }
  }, []);

  // Send init for a session only if its meta hasn't been loaded yet.
  const initSession = useCallback(
    (uuid: string) => {
      if (useDataStore.getState().getData(uuid)?.meta) return;
      useDataStore.getState().initSession(uuid);
      send({ type: "init", session: uuid });
    },
    [send]
  );

  const fetchRows = useCallback(
    (uuid: string, offset: number) => {
      const pending = pendingRef.current.get(uuid) ?? new Set<number>();
      if (pending.has(offset)) return;
      if (useDataStore.getState().hasRows(uuid, offset)) return;
      pending.add(offset);
      pendingRef.current.set(uuid, pending);
      send({ type: "fetch_rows", session: uuid, offset, limit: CHUNK_SIZE });
    },
    [send]
  );

  const applySortFilter = useCallback(
    (uuid: string, sort: SortEntry[], filterTree: FilterGroup) => {
      useDataStore.getState().setSortFilter(uuid, sort, filterTree);
      pendingRef.current.set(uuid, new Set());
      send({
        type:        "apply_sort_filter",
        session:     uuid,
        sort,
        filter_tree: stripIds(filterTree),
      });
    },
    [send]
  );

  const closeSession = useCallback(
    (uuid: string) => {
      send({ type: "close_session", session: uuid });
      useSessionStore.getState().removeSession(uuid);
    },
    [send]
  );

  useEffect(() => {
    const sock = new WebSocket(`ws://${window.location.host}/ws`);
    wsRef.current = sock;
    dataStore.setWsStatus("connecting");

    sock.onopen = () => {
      dataStore.setWsStatus("open");
      sock.send(JSON.stringify({ type: "list_sessions" }));
    };

    sock.onmessage = (ev) => {
      const msg = JSON.parse(ev.data as string) as Record<string, unknown>;

      if (msg.type === "sessions_list") {
        const sessions = msg.sessions as Omit<SessionInfo, "isNew">[];
        useSessionStore.getState().setSessions(sessions);
        sessions.forEach((s) => {
          useDataStore.getState().initSession(s.uuid);
          send({ type: "init", session: s.uuid });
        });

      } else if (msg.type === "session_created") {
        const info = msg as unknown as Omit<SessionInfo, "isNew">;
        useSessionStore.getState().addSession(info);
        useDataStore.getState().initSession(info.uuid);
        send({ type: "init", session: info.uuid });

      } else if (msg.type === "meta") {
        const uuid = msg.session as string;
        useDataStore.getState().setMeta(uuid, {
          var_name:  msg.var_name  as string,
          row_count: msg.row_count as number,
          col_count: msg.col_count as number,
          columns:   msg.columns   as string[],
          dtypes:    msg.dtypes    as string[],
        });
        fetchRows(uuid, 0);

      } else if (msg.type === "rows") {
        const uuid   = msg.session as string;
        const offset = msg.offset  as number;
        pendingRef.current.get(uuid)?.delete(offset);
        useDataStore.getState().addRows(uuid, offset, msg.data as never);

      } else if (msg.type === "error") {
        const uuid = msg.session as string | undefined;
        if (uuid) {
          useDataStore.getState().setError(uuid, msg.message as string);
        }
      }
    };

    sock.onerror  = () => dataStore.setWsStatus("error");
    sock.onclose  = () => dataStore.setWsStatus("closed");

    return () => sock.close();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return { fetchRows, applySortFilter, initSession, closeSession };
}
