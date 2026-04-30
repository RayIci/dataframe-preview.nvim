import { useState, useCallback } from "react";
import { RefreshCw } from "lucide-react";
import { useDataStore } from "@/store/dataStore";
import { useSessionStore } from "@/store/sessionStore";
import { cn } from "@/lib/utils";

function dtypeSummary(dtypes: string[]): { key: string; count: number }[] {
  const map = new Map<string, number>();
  for (const d of dtypes) {
    map.set(d, (map.get(d) ?? 0) + 1);
  }
  return [...map.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([key, count]) => ({ key, count }));
}

interface MetadataBarProps {
  refreshSession: (uuid: string) => void;
}

export function MetadataBar({ refreshSession }: MetadataBarProps) {
  const activeUuid = useSessionStore((s) => s.activeUuid);
  const meta = useDataStore((s) =>
    activeUuid ? (s.getData(activeUuid)?.meta ?? null) : null
  );

  const [spinning, setSpinning] = useState(false);

  const handleRefresh = useCallback(() => {
    if (!activeUuid || spinning) return;
    setSpinning(true);
    refreshSession(activeUuid);
    setTimeout(() => setSpinning(false), 800);
  }, [activeUuid, spinning, refreshSession]);

  if (!meta) return null;

  const summary = dtypeSummary(meta.dtypes);

  return (
    <div className="flex items-center gap-2 px-4 h-8 shrink-0 border-b border-border bg-card text-xs text-muted-foreground select-none overflow-x-auto">
      <span className="font-medium text-foreground shrink-0">{meta.var_name}</span>
      <span className="text-border">·</span>
      <span className="shrink-0 tabular-nums">{meta.row_count.toLocaleString()} rows</span>
      <span className="text-border">·</span>
      <span className="shrink-0">{meta.col_count} cols</span>
      <span className="text-border">·</span>
      <div className="flex items-center gap-1.5 shrink-0">
        {summary.map(({ key, count }) => (
          <span key={key} className="inline-flex items-center gap-0.5">
            <span className="font-mono">{key}</span>
            <span className="text-muted-foreground/60">×{count}</span>
          </span>
        ))}
      </div>

      <div className="flex-1" />

      <button
        onClick={handleRefresh}
        className="shrink-0 text-muted-foreground hover:text-foreground transition-colors"
        title="Refresh DataFrame"
      >
        <RefreshCw
          size={12}
          className={cn(spinning && "animate-spin")}
        />
      </button>
    </div>
  );
}
