import { useDataStore } from "@/store/dataStore";

const STATUS_COLORS = {
  connecting: "text-yellow-400",
  open:       "text-green-400",
  closed:     "text-muted-foreground",
  error:      "text-red-400",
} as const;

export function StatusBar() {
  const { meta, wsStatus, loading } = useDataStore();

  return (
    <div className="flex items-center gap-4 border-b border-border bg-card px-4 py-2 text-xs text-muted-foreground shrink-0">
      {meta ? (
        <>
          <span className="font-semibold text-foreground">{meta.var_name}</span>
          <span>{meta.row_count.toLocaleString()} rows × {meta.col_count} cols</span>
        </>
      ) : (
        <span>{loading ? "Loading…" : "No data"}</span>
      )}
      <span className="ml-auto flex items-center gap-1.5">
        <span className={`size-1.5 rounded-full bg-current ${STATUS_COLORS[wsStatus]}`} />
        <span className={STATUS_COLORS[wsStatus]}>{wsStatus}</span>
      </span>
    </div>
  );
}
