# Frontend

The UI is a single-page React application that connects to the Lua server over WebSocket and renders the dataframe using virtual scrolling. It supports multiple simultaneous sessions (one browser tab, multiple DataFrame previews shown as sub-tabs).

---

## Stack

| Package | Role |
|---|---|
| **React 19** | Component model, hooks |
| **shadcn/ui** | Design system (Badge, Button, Input, Select, Skeleton, Tooltip, Separator) |
| **Tailwind CSS v4** | Utility-first styling (required by shadcn/ui) |
| **@tanstack/react-virtual** | Virtual row rendering |
| **Zustand** | Global state (session list + per-session data cache) |
| **Vite** + **vite-plugin-singlefile** | Build toolchain; output is a single inlined `index.html` |

The built `ui/dist/index.html` is **committed to the repository** so users don't need Node.js. It contains all JS and CSS inlined.

---

## Building the Frontend

```bash
make build-ui        # bun install + vite build → ui/dist/index.html
make ui-dev          # vite dev server on http://localhost:5173 (hot reload)
make ui-typecheck    # tsc --noEmit (no output, just type checking)
```

The Vite config uses `vite-plugin-singlefile` to inline all assets:

```ts
// ui/vite.config.ts
import { viteSingleFile } from "vite-plugin-singlefile";

export default defineConfig({
  plugins: [react(), tailwindcss(), viteSingleFile()],
  build: { outDir: "dist", emptyOutDir: true },
});
```

### Development workflow

When working on the UI, run `make ui-dev` to start the Vite dev server. The dev server does **not** communicate with a real Neovim session — you'll need to mock the WebSocket responses or temporarily point the app at a running Neovim server.

Practical approach: start a debug session in Neovim, trigger `:PreviewDataFrame` once (this starts the Lua server), then add a proxy to `vite.config.ts`:

```ts
// ui/vite.config.ts (dev only)
server: {
  proxy: {
    "/ws": { target: "ws://127.0.0.1:PORT", ws: true },
  },
},
```

Replace `PORT` with the port printed by Neovim's debug log (`debug = true` in setup).

---

## Application Structure

```
ui/src/
├── main.tsx              # React root mount
├── App.tsx               # Mounts Navbar + MetadataBar + FilterBar + DataGrid
├── index.css             # Tailwind v4 + shadcn CSS variables (light + dark theme)
│
├── store/
│   ├── dataStore.ts      # Zustand store: per-session row cache, sort, filter, scroll state
│   └── sessionStore.ts   # Zustand store: session tab list, active session, labels
│
├── hooks/
│   ├── useWebSocket.ts   # WS lifecycle, message routing, fetchRows, applySortFilter, refresh
│   ├── useColumnResize.ts # Column width state, persisted to localStorage
│   └── useLockedCols.ts  # Locked (pinned) column list, persisted to localStorage
│
├── components/
│   ├── Navbar.tsx         # Session tabs, theme toggle, WS status indicator
│   ├── MetadataBar.tsx    # Variable name, row/col counts, dtype summary, Refresh button
│   ├── FilterBar.tsx      # Sort and filter UI; sends apply_sort_filter over WebSocket
│   ├── DataGrid.tsx       # Virtual table (TanStack Virtual + shadcn primitives)
│   ├── LoadingSkeleton.tsx # Skeleton rows during initial load
│   ├── ScrollToTop.tsx    # Scroll-to-top button
│   ├── ThemeToggle.tsx    # Light/dark toggle button (also embedded in Navbar)
│   └── ui/               # shadcn/ui primitives
│       ├── badge.tsx
│       ├── button.tsx
│       ├── input.tsx
│       ├── select.tsx
│       ├── separator.tsx
│       ├── skeleton.tsx
│       └── tooltip.tsx
│
└── lib/
    └── utils.ts          # cn() (clsx + tailwind-merge)
```

---

## State Management

### `store/sessionStore.ts` — session tab list

Tracks the ordered list of sessions the browser knows about, the active (focused) session UUID, and user-assigned labels:

```ts
interface SessionInfo {
  uuid:          string;
  var_name:      string;
  label:         string;       // user-editable display name
  row_count:     number;
  col_count:     number;
  columns:       string[];
  dtypes:        string[];
  index_columns: string[];
  isNew:         boolean;      // true until the tab has been viewed once
}

interface SessionStore {
  sessions:      SessionInfo[];
  activeUuid:    string | null;
  addSession:    (info: SessionInfo) => void;
  removeSession: (uuid: string) => void;
  setActive:     (uuid: string) => void;
  renameSession: (uuid: string, label: string) => void;
}
```

### `store/dataStore.ts` — per-session data

Holds all data state keyed by session UUID:

```ts
interface SessionData {
  meta:          Meta | null;          // column names, dtypes, row/col counts, index_columns
  rowCache:      Map<number, RowChunk>; // offset → 100-row chunk
  loading:       boolean;
  error:         string | null;
  sort:          SortEntry[];          // active multi-column sort
  filterTree:    FilterGroup;          // active recursive AND/OR filter tree
  scrollVersion: number;               // incremented on sort/filter change to reset scroll
  lockedRows:    number[];             // pinned row indices (in display order)
}

interface DataStore {
  dataByUuid: Map<string, SessionData>;
  wsStatus:   "connecting" | "open" | "closed" | "error";
  // ... actions: initSession, setMeta, addRows, setSort, setFilterTree, ...
}
```

### Row cache design

Rows are cached in 100-row chunks keyed by their start offset:

```
rowCache = Map {
  0   → [[row0], [row1], ..., [row99]],
  100 → [[row100], ..., [row199]],
  200 → [[row200], ..., [row299]],
  ...
}
```

`getRow(index)` computes `chunkOffset = floor(index / 100) * 100` and looks up `rowCache.get(chunkOffset)[index - chunkOffset]`. If the chunk isn't loaded yet, the virtual row renders a skeleton placeholder.

Chunks are **never evicted** from the cache — memory grows linearly with the number of rows the user has scrolled through. For typical interactive use this is fine.

---

## Virtual Scrolling

`DataGrid.tsx` uses `@tanstack/react-virtual`'s `useVirtualizer`:

```tsx
const virtualizer = useVirtualizer({
  count:            rowCount,        // total rows from metadata
  getScrollElement: () => scrollRef.current,
  estimateSize:     () => ROW_HEIGHT, // 32px
  overscan:         5,               // render 5 extra rows above/below viewport
});
```

The virtualizer renders only the visible DOM nodes. A 50,000-row dataframe renders the same ~30 `<div>` elements regardless of scroll position.

### Prefetch trigger

The `prefetch` function runs after every virtualizer update:

```ts
const lastIndex = items[items.length - 1].index;
const nextChunkOffset = Math.floor((lastIndex + PREFETCH_GAP) / CHUNK_SIZE) * CHUNK_SIZE;

if (nextChunkOffset < rowCount && !hasRows(nextChunkOffset)) {
  fetchRows(nextChunkOffset);
}
```

`PREFETCH_GAP = 20` means the next chunk is requested when the user is within 20 rows of the end of the currently loaded data. A `pendingRef` Set prevents duplicate in-flight requests for the same chunk offset.

---

## WebSocket Hook

`hooks/useWebSocket.ts` manages the connection lifecycle and multi-session routing:

```ts
useEffect(() => {
  const sock = new WebSocket(`ws://${window.location.host}/ws`);

  sock.onopen = () => {
    // Request the current session list to restore tabs after a page reload.
    sock.send(JSON.stringify({ type: "list_sessions" }));
  };

  sock.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    switch (msg.type) {
      case "sessions_list":
        // Add each session to sessionStore; send "init" for any not yet initialized.
        break;
      case "session_created":
        // Broadcast: a new preview was triggered from Neovim.
        sessionStore.addSession(msg);
        sock.send(JSON.stringify({ type: "init", session: msg.uuid }));
        break;
      case "meta":
        dataStore.setMeta(msg.session, msg);
        break;
      case "rows":
        dataStore.addRows(msg.session, msg.offset, msg.data);
        break;
      case "error":
        dataStore.setError(msg.session, msg.message);
        break;
    }
  };

  return () => sock.close();
}, []);
```

Exported helpers — `fetchRows`, `applySortFilter`, `initSession`, `closeSession`, `refreshSession` — all route messages by UUID so multiple open sessions don't interfere.

---

## Persistent Preferences

Two hooks back their state to `localStorage` so user preferences survive page reloads:

### `useColumnResize`

- Key: `"df-col-widths"` — stores `{ [columnName]: widthPx }`.
- `MIN_WIDTH = 80px`, `DEFAULT_WIDTH = 150px`.
- Drag detection uses document-level `mousemove`/`mouseup` listeners for precision tracking outside the column boundary.

### `useLockedCols`

- Key: `"df-locked-cols"` — stores an ordered array of pinned column names.
- `toggleLock(col)` adds or removes a column from the pinned set.
- `reorderLocked(fromIdx, toIdx)` reorders within the pinned set via drag-and-drop.
- Locked columns are rendered with a CSS `translateX(--locked-tx)` offset to stay visible during horizontal scroll — no React re-render per scroll pixel.

---

## DataGrid Features

| Feature | How it works |
|---|---|
| **Column pinning** | Pin icon in header; locked columns stay left-aligned while the rest scroll |
| **Column reordering** | Drag pinned columns via GripVertical handle |
| **Column resizing** | Drag the right edge of any column header |
| **Row pinning** | Pin icon on hover; pinned rows sticky below the column header |
| **Row reordering** | Drag pinned rows via grip handle |
| **Sort indicators** | ↑/↓ on sorted columns; rank number shown for multi-column sort |
| **Filter indicator** | Amber dot on column header when a filter is active for that column |
| **Index columns** | Key icon for named DataFrame index levels; shown as leading locked columns |
| **Dtype badges** | Colored badge per column: default=numeric, secondary=datetime, outline=string/other |
| **Cell tooltips** | Full value shown on hover for cells truncated by column width (300 ms delay) |
| **Null display** | Python `None` / JSON `null` shown as italic `"null"` in muted foreground |

---

## Styling

The app supports **light and dark themes** toggled via the Navbar button. The palette is the shadcn/ui **mist** theme (Luma preset) using OKLCH color space. CSS variables bridge shadcn token names to Tailwind utilities.

Column headers display the dtype of each column as a small `<Badge>`:

| dtype prefix | Badge style |
|---|---|
| `int`, `uint`, `float` | `default` (primary tint) |
| `datetime`, `timedelta` | `secondary` |
| anything else (object, bool, category…) | `outline` |

---

## Adding shadcn/ui Components

The `ui/` directory is a standard shadcn/ui project. To add a new component:

```bash
cd ui
bunx shadcn@latest add <component-name>
```

This copies the component source into `ui/src/components/ui/`. After adding, rebuild:

```bash
make build-ui
```

The new component is available at `@/components/ui/<component-name>`.
