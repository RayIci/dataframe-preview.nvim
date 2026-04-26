import { useEffect, useRef, useCallback } from "react";
import { useDataStore, SortEntry, FilterCondition, FilterLogic } from "@/store/dataStore";

const CHUNK_SIZE = 100;

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

  const applySortFilter = useCallback((
    sort: SortEntry[],
    filter: FilterCondition[],
    logic: FilterLogic,
  ) => {
    store.setSortFilter(sort, filter, logic);
    pendingRef.current.clear();
    send({
      type: "apply_sort_filter",
      session: sessionId,
      sort,
      // Strip client-only `id` before sending to server
      filter: filter.map(({ column, operator, value }) => ({ column, operator, value })),
      filter_logic: logic,
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
