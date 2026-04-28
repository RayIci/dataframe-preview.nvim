# Frontend

The UI is a single-page React application that connects to the Lua server over WebSocket and renders the dataframe using virtual scrolling.

---

## Stack

| Package | Role |
|---|---|
| **React 19** | Component model, hooks |
| **shadcn/ui** | Design system (Table, Badge, Skeleton, Tooltip) |
| **Tailwind CSS v4** | Utility-first styling (required by shadcn/ui) |
| **@tanstack/react-virtual** | Virtual row rendering |
| **@tanstack/react-table** | Column definitions and state |
| **Zustand** | Global state (metadata + row cache) |
| **Vite** + **vite-plugin-singlefile** | Build toolchain; output is a single inlined `index.html` |

The built `ui/dist/index.html` is **committed to the repository** so users don't need Node.js. It contains all JS and CSS inlined. Gzipped size is ~97 KB.

---

## Building the Frontend

```bash
make build-ui        # npm install + vite build → ui/dist/index.html
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

Practical approach: start a debug session in Neovim, trigger `:PreviewDataFrame` once (this starts the Lua server), then change the `vite.config.ts` to proxy WebSocket requests:

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
├── App.tsx               # Reads ?session= param, mounts StatusBar + DataGrid
├── index.css             # Tailwind + CSS variables (dark theme)
│
├── store/
│   └── dataStore.ts      # Zustand store: meta, rowCache, wsStatus
│
├── hooks/
│   └── useWebSocket.ts   # WS lifecycle, message routing, fetchRows
│
├── components/
│   ├── DataGrid.tsx       # Virtual table (TanStack Virtual + shadcn Table)
│   ├── FilterPanel.tsx    # Sort and filter UI; sends apply_sort_filter over WebSocket
│   ├── StatusBar.tsx      # Variable name, counts, WS status indicator
│   ├── LoadingSkeleton.tsx # Skeleton rows during initial load
│   └── ui/               # shadcn/ui primitives
│       ├── badge.tsx
│       ├── skeleton.tsx
│       └── tooltip.tsx
│
└── lib/
    └── utils.ts          # cn() (clsx + tailwind-merge)
```

---

## State Management

The Zustand store (`store/dataStore.ts`) holds all shared state:

```ts
interface DataStore {
  meta:        Meta | null;           // column names, dtypes, row/col counts
  rowCache:    Map<number, RowChunk>; // offset → 100-row chunk
  loading:     boolean;
  error:       string | null;
  wsStatus:    "connecting" | "open" | "closed" | "error";
  sort:        SortEntry[];           // active multi-column sort
  filterTree:  FilterNode;            // active recursive AND/OR filter tree
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

`getRow(index)` computes `chunkOffset = floor(index / 100) * 100` and looks up `rowCache.get(chunkOffset)[index - chunkOffset]`. If the chunk isn't loaded yet, `getRow` returns `undefined` and the virtual row renders a skeleton placeholder.

Chunks are **never evicted** from the cache — memory grows linearly with the number of rows the user has scrolled through. For typical interactive use (viewing the first few hundred rows of a large dataframe) this is fine. If you need to support scrolling through millions of rows, a sliding window eviction policy could be added to `dataStore.ts`.

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

`PREFETCH_GAP = 20` means the next chunk is requested when the user is within 20 rows of the end of the currently loaded data — enough lookahead that the next chunk usually arrives before the user needs it.

A `pendingRef` Set prevents duplicate in-flight requests for the same chunk offset.

---

## WebSocket Hook

`hooks/useWebSocket.ts` manages the connection lifecycle:

```ts
useEffect(() => {
  const sock = new WebSocket(`ws://${window.location.host}/ws`);

  sock.onopen  = () => sock.send(JSON.stringify({ type:"init", session: sessionId }));
  sock.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if      (msg.type === "meta")  store.setMeta(msg);      // initial meta + after sort/filter
    else if (msg.type === "rows")  store.addRows(msg.offset, msg.data);
    else if (msg.type === "error") store.setError(msg.message);
  };

  // Sending sort/filter changes (called by FilterPanel):
  // sock.send(JSON.stringify({ type:"apply_sort_filter", session: sessionId,
  //                            sort: [{column, ascending}], filter_tree: {…} }));

  return () => sock.close();
}, [sessionId]);
```

The session ID is read from the URL query string once at module load:

```ts
// App.tsx
const sessionId = new URLSearchParams(window.location.search).get("session") ?? "";
```

---

## Styling

The app uses a dark theme by default, defined as CSS variables in `src/index.css`. The palette follows shadcn/ui's `slate` base color with `dark` mode forced (no system preference toggle — this is a developer tool that lives in a terminal context).

Column headers display the dtype of each column as a small `<Badge>`:

| dtype prefix | Badge style |
|---|---|
| `int`, `uint`, `float` | `default` (primary tint) |
| `datetime`, `timedelta` | `secondary` |
| anything else (object, bool, category…) | `outline` |

Cell values that are truncated by the column width show their full value in a `<Tooltip>` on hover (triggers after 300ms).

`null` values (Python `None` → JSON `null`) are displayed as italic `"null"` in muted foreground color.

---

## Adding shadcn/ui Components

The `ui/` directory is a standard shadcn/ui project. To add a new component:

```bash
cd ui
npx shadcn@latest add <component-name>
```

This copies the component source into `ui/src/components/ui/`. After adding, rebuild:

```bash
make build-ui
```

The new component is available at `@/components/ui/<component-name>`.
