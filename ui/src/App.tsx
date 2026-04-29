import { useDataStore } from "@/store/dataStore";
import { useSessionStore } from "@/store/sessionStore";
import { useWebSocket } from "@/hooks/useWebSocket";
import { Navbar } from "@/components/Navbar";
import { MetadataBar } from "@/components/MetadataBar";
import { FilterBar } from "@/components/FilterBar";
import { DataGrid } from "@/components/DataGrid";

function EmptyState() {
  return (
    <div className="flex flex-1 items-center justify-center">
      <div className="text-center space-y-2">
        <p className="text-muted-foreground text-sm">No active sessions.</p>
        <p className="text-xs text-muted-foreground/70">
          Pause a debugger in Neovim, then run{" "}
          <code className="text-foreground bg-muted px-1 py-0.5 rounded text-[11px]">
            :PreviewDataFrame
          </code>
        </p>
      </div>
    </div>
  );
}

export function App() {
  const { fetchRows, applySortFilter, initSession, closeSession } = useWebSocket();
  const sessions   = useSessionStore((s) => s.sessions);
  const activeUuid = useSessionStore((s) => s.activeUuid);
  const activeMeta = useDataStore(
    (s) => (activeUuid ? s.getData(activeUuid)?.meta : null) ?? null
  );

  return (
    <div className="flex h-screen flex-col overflow-hidden">
      <Navbar initSession={initSession} closeSession={closeSession} />
      <MetadataBar />

      {sessions.length === 0 ? (
        <EmptyState />
      ) : (
        <>
          {activeUuid && activeMeta && (
            <FilterBar
              uuid={activeUuid}
              columns={activeMeta.columns}
              dtypes={activeMeta.dtypes}
              applySortFilter={applySortFilter}
            />
          )}

          {activeUuid ? (
            <DataGrid
              uuid={activeUuid}
              fetchRows={fetchRows}
              applySortFilter={applySortFilter}
            />
          ) : (
            <div className="flex flex-1 items-center justify-center text-muted-foreground text-sm">
              Select a session above
            </div>
          )}
        </>
      )}
    </div>
  );
}
