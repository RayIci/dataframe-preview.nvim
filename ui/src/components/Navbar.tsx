import { useState } from "react";
import { useDataStore } from "@/store/dataStore";
import { useSessionStore } from "@/store/sessionStore";
import { ThemeToggle } from "@/components/ThemeToggle";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";
import { X } from "lucide-react";

const WS_DOT: Record<string, string> = {
  connecting: "bg-yellow-400",
  open:       "bg-green-400",
  closed:     "bg-muted-foreground",
  error:      "bg-destructive",
};

interface NavbarProps {
  initSession:  (uuid: string) => void;
  closeSession: (uuid: string) => void;
}

export function Navbar({ initSession, closeSession }: NavbarProps) {
  const { sessions, activeUuid, setActive, renameSession } = useSessionStore();
  const wsStatus = useDataStore((s) => s.wsStatus);

  const [editingUuid, setEditingUuid] = useState<string | null>(null);
  const [editValue,   setEditValue]   = useState("");

  function commitRename(uuid: string, varName: string) {
    renameSession(uuid, editValue.trim() || varName);
    setEditingUuid(null);
  }

  return (
    <header className="flex items-center gap-0.5 border-b border-border bg-card px-2 h-14 shrink-0 overflow-x-auto">
      {sessions.map((s) => {
        const isActive  = activeUuid === s.uuid;
        const isEditing = editingUuid === s.uuid;

        return (
          <div key={s.uuid} className="group relative shrink-0">
            <button
              onClick={() => {
                setActive(s.uuid);
                initSession(s.uuid);
              }}
              className={cn(
                "flex flex-col justify-center px-3 pr-6 py-1 rounded min-w-[80px] max-w-[160px] transition-colors",
                isActive
                  ? "bg-primary/10 text-primary"
                  : "text-muted-foreground hover:text-foreground hover:bg-muted"
              )}
            >
              {/* Row 1: editable label */}
              {isEditing ? (
                <input
                  autoFocus
                  value={editValue}
                  className="text-xs font-medium bg-transparent border-b border-primary outline-none w-full"
                  onChange={(e) => setEditValue(e.target.value)}
                  onBlur={() => commitRename(s.uuid, s.var_name)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter")  { commitRename(s.uuid, s.var_name); }
                    if (e.key === "Escape") { setEditingUuid(null); }
                    e.stopPropagation();
                  }}
                  onClick={(e) => e.stopPropagation()}
                />
              ) : (
                <span
                  className="text-xs font-medium truncate"
                  onDoubleClick={(e) => {
                    e.stopPropagation();
                    setEditingUuid(s.uuid);
                    setEditValue(s.label);
                  }}
                >
                  {s.label}
                </span>
              )}

              {/* Row 2: var_name badge */}
              <Badge
                variant="outline"
                className="w-fit text-[9px] px-1 h-3.5 mt-0.5 font-normal leading-none"
              >
                {s.var_name}
              </Badge>
            </button>

            {/* Close button */}
            <button
              className={cn(
                "absolute top-1.5 right-1 p-0.5 rounded transition-opacity",
                "opacity-0 group-hover:opacity-100",
                "text-muted-foreground hover:text-destructive"
              )}
              onClick={(e) => {
                e.stopPropagation();
                closeSession(s.uuid);
              }}
              title="Close session"
            >
              <X size={11} />
            </button>

            {/* New-session dot */}
            {s.isNew && (
              <span className="absolute top-1 left-1 size-1.5 rounded-full bg-primary pointer-events-none" />
            )}
          </div>
        );
      })}

      <div className="flex-1" />

      <span
        className={cn("size-1.5 rounded-full shrink-0 mr-1", WS_DOT[wsStatus] ?? "bg-muted-foreground")}
        title={`WebSocket: ${wsStatus}`}
      />
      <ThemeToggle />
    </header>
  );
}
