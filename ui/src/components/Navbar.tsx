import { useDataStore } from "@/store/dataStore";
import { useSessionStore } from "@/store/sessionStore";
import { ThemeToggle } from "@/components/ThemeToggle";
import { cn } from "@/lib/utils";

const WS_DOT: Record<string, string> = {
  connecting: "bg-yellow-400",
  open:       "bg-green-400",
  closed:     "bg-muted-foreground",
  error:      "bg-destructive",
};

interface NavbarProps {
  initSession: (uuid: string) => void;
}

export function Navbar({ initSession }: NavbarProps) {
  const { sessions, activeUuid, setActive } = useSessionStore();
  const wsStatus = useDataStore((s) => s.wsStatus);

  return (
    <header className="flex items-center gap-0.5 border-b border-border bg-card px-2 h-10 shrink-0 overflow-x-auto">
      {sessions.map((s) => (
        <button
          key={s.uuid}
          onClick={() => {
            setActive(s.uuid);
            initSession(s.uuid);
          }}
          className={cn(
            "relative flex items-center gap-1.5 px-3 py-1 rounded text-xs font-medium transition-colors shrink-0 whitespace-nowrap",
            activeUuid === s.uuid
              ? "bg-primary/10 text-primary"
              : "text-muted-foreground hover:text-foreground hover:bg-muted"
          )}
        >
          {s.isNew && (
            <span className="absolute top-1 right-1 size-1.5 rounded-full bg-primary" />
          )}
          <span>{s.var_name}</span>
          <span
            className={cn(
              "text-[10px] tabular-nums",
              activeUuid === s.uuid ? "text-primary/70" : "text-muted-foreground"
            )}
          >
            {s.row_count.toLocaleString()}r
          </span>
        </button>
      ))}

      <div className="flex-1" />

      <span
        className={cn("size-1.5 rounded-full shrink-0 mr-1", WS_DOT[wsStatus] ?? "bg-muted-foreground")}
        title={`WebSocket: ${wsStatus}`}
      />
      <ThemeToggle />
    </header>
  );
}
