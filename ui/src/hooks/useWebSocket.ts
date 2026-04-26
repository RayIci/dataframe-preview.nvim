import { useEffect, useRef, useCallback } from "react";
import { useDataStore, SortEntry, FilterGroup, FilterNode } from "@/store/dataStore";

const CHUNK_SIZE = 100;

// Recursively strip client-only `id` fields before sending to the server
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

export function useWebSocket(sessionId: string) {
  const wsRef      = useRef<WebSocket | null>(null);
  const pendingRef = useRef<Set<number>>(new Set());
  const store      = useDataStore();

  const send = useCallback((msg: object) => {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify(msg));
    }
  }, []);

  const fetchRows = useCallback((offset: number) => {
    if (pendingRef.current.has(offset)) return;
    if (useDataStore.getState().hasRows(offset)) return;
    pendingRef.current.add(offset);
    send({ type: "fetch_rows", session: sessionId, offset, limit: CHUNK_SIZE });
  }, [sessionId, send]);

  const applySortFilter = useCallback((sort: SortEntry[], filterTree: FilterGroup) => {
    store.setSortFilter(sort, filterTree);
    pendingRef.current.clear();
    send({
      type:        "apply_sort_filter",
      session:     sessionId,
      sort,
      filter_tree: stripIds(filterTree),
    });
  }, [store, send, sessionId]);

  useEffect(() => {
    const url  = `ws://${window.location.host}/ws`;
    const sock = new WebSocket(url);
    wsRef.current = sock;
    store.setWsStatus("connecting");

    sock.onopen = () => {
      store.setWsStatus("open");
      sock.send(JSON.stringify({ type: "init", session: sessionId }));
    };

    sock.onmessage = (ev) => {
      const msg = JSON.parse(ev.data as string);

      if (msg.type === "meta") {
        store.setMeta({
          var_name:  msg.var_name,
          row_count: msg.row_count,
          col_count: msg.col_count,
          columns:   msg.columns,
          dtypes:    msg.dtypes,
        });
        fetchRows(0);
      } else if (msg.type === "rows") {
        pendingRef.current.delete(msg.offset);
        store.addRows(msg.offset, msg.data);
      } else if (msg.type === "error") {
        store.setError(msg.message);
      }
    };

    sock.onerror = () => store.setWsStatus("error");
    sock.onclose = () => store.setWsStatus("closed");

    return () => sock.close();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId]);

  return { fetchRows, applySortFilter };
}
