import { StatusBar } from "@/components/StatusBar";
import { DataGrid } from "@/components/DataGrid";
import { useWebSocket } from "@/hooks/useWebSocket";

const sessionId = new URLSearchParams(window.location.search).get("session") ?? "";

export function App() {
  const { fetchRows } = useWebSocket(sessionId);

  if (!sessionId) {
    return (
      <div className="flex h-screen items-center justify-center text-muted-foreground text-sm">
        No session ID in URL. Open this page from Neovim via <code className="mx-1 text-foreground">:PreviewDataFrame</code>.
      </div>
    );
  }

  return (
    <div className="flex h-screen flex-col overflow-hidden">
      <StatusBar />
      <DataGrid fetchRows={fetchRows} />
    </div>
  );
}
