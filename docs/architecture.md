# Architecture

## Overview

The plugin is built around three boundaries:

1. **Neovim ↔ DAP adapter** — standard DAP `evaluate` requests (read-only)
2. **Neovim ↔ Browser** — a `vim.uv` TCP server speaking HTTP + WebSocket
3. **Lua ↔ Frontend** — a typed JSON message protocol over the WebSocket

```
┌─────────────────────────────────────────────────────────────────────┐
│  Neovim process                                                      │
│                                                                      │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────┐  │
│  │ orchestrator │───▶│ DapProvider  │───▶│  DAP debug adapter   │  │
│  │              │    │ (nvim_dap)   │    │  (e.g. debugpy)      │  │
│  └──────┬───────┘    └──────────────┘    └──────────────────────┘  │
│         │                                                            │
│         │ session_store.create(uuid, metadata)                       │
│         ▼                                                            │
│  ┌──────────────┐    ┌──────────────────────────────────────────┐  │
│  │session_store │    │  vim.uv TCP server (127.0.0.1:PORT)      │  │
│  │              │    │                                            │  │
│  │  uuid →      │    │  HTTP GET /  → serve dist/index.html     │  │
│  │  {var_name,  │◀───│  WS  /ws    → dispatch to handlers.lua  │  │
│  │   frame_id,  │    │                                            │  │
│  │   metadata,  │    └──────────────────────────────────────────┘  │
│  │   ws_client} │                          │                        │
│  └──────────────┘                          │ WebSocket              │
└───────────────────────────────────────────────────────────────────┘
                                             │
                                             ▼
                               ┌─────────────────────────┐
                               │  Browser tab             │
                               │  React + shadcn/ui       │
                               │  TanStack Virtual        │
                               │  Zustand store           │
                               └─────────────────────────┘
```

---

## Data Flow Step by Step

### 1. Command triggered

```
user presses <leader>dp
  → vim.api.nvim_create_user_command callback
  → orchestrator.preview(dap_provider, lang_providers)
    -- lang_providers is table<string, LanguageProvider[]> keyed by filetype
```

### 2. DAP frame resolution

```lua
-- orchestrator.lua
local var_name = vim.fn.expand("<cword>")
dap_provider:get_frame_id(function(frame_id, err)
  -- nvim_dap.lua: session:request("stackTrace", ...) → frames[1].id
end)
```

This is asynchronous: the DAP request goes over a JSON-RPC socket to the debug adapter. The callback is fired via `vim.schedule` (Neovim main thread) when the response arrives.

### 2a. Provider resolution

```lua
-- orchestrator.lua → resolve_provider()
local ft = vim.bo.filetype
local providers = lang_providers[ft]  -- array of LanguageProvider

-- If only one provider is registered it is used directly (no DAP round-trip).
-- Otherwise each provider's can_handle_expr is evaluated in order:
for _, provider in ipairs(providers) do
  local expr = provider:can_handle_expr(var_name)
  dap_provider:evaluate(expr, frame_id, function(err, raw)
    if provider:parse_can_handle(raw) then
      -- this provider is stored in the session and used for all subsequent steps
    end
  end)
end
```

The resolved provider is stored in the session so that both metadata evaluation (Step 3) and row fetching (Step 8) use the same provider without re-resolving.

### 3. Metadata evaluation

```lua
-- lang_provider is the single provider selected by Step 2a.
-- The expression is pure read-only Python:
-- __import__('json').dumps({'shape': list(df.shape),
--                           'columns': df.columns.tolist(),
--                           'dtypes': df.dtypes.astype(str).tolist()})

local expr = lang_provider:metadata_expr(var_name)
dap_provider:evaluate(expr, frame_id, function(err, result)
  local metadata = lang_provider:parse_metadata(result)
  -- { row_count=50000, col_count=5, columns=[...], dtypes=[...] }
end)
```

The DAP adapter evaluates this expression in the paused Python process and returns the JSON string as the `result` field of the `evaluate` response. **No file is written. No code is injected.** The expression is evaluated the same way as typing it in the DAP REPL.

### 4. Session creation

```lua
local uuid = generate_uuid()
session_store.create(uuid, {
  var_name = var_name,
  frame_id = frame_id,
  metadata = metadata,
})
```

The session lives in a Lua table keyed by UUID. The UUID is embedded in the browser URL so the frontend can identify itself on WebSocket connect.

### 5. Server start (lazy)

```lua
server.ensure_started(dap_provider, function(port)
  browser.open("http://127.0.0.1:" .. port .. "/?session=" .. uuid)
end)
```

The server is started only on the first `PreviewDataFrame` call. Subsequent calls reuse the same port. The OS assigns the port dynamically (`bind("127.0.0.1", 0)`), so there are no port conflicts.

### 6. Browser connects

The browser loads `index.html` (served by the Lua HTTP handler), then opens a WebSocket to the same host:

```
GET /?session=<uuid>   →  HTTP 200, body = ui/dist/index.html
GET /ws                →  HTTP 101 Switching Protocols (WebSocket upgrade)
```

### 7. WebSocket handshake

The Lua server detects the `Upgrade: websocket` header and performs the RFC 6455 handshake:

```
Sec-WebSocket-Accept = base64(sha1(Sec-WebSocket-Key + "258EAFA5-..."))
```

SHA1 is computed by `server/sha1.lua` — a pure-Lua, LuaJIT-compatible implementation (no external dependencies).

### 8. Data streaming

```
Browser                          Lua server
  │                                │
  │── { type:"init", session } ──▶ │  attach ws_client to session
  │◀─ { type:"meta", ... } ────── │  send metadata from session_store
  │                                │
  │── { type:"fetch_rows",        │
  │    offset:0, limit:100 } ───▶ │  evaluate rows_expr via DAP
  │◀─ { type:"rows",              │
  │    offset:0, data:[[...]] } ─ │
  │                                │
  │  (user scrolls to row 80)      │
  │── { type:"fetch_rows",        │
  │    offset:100, limit:100 } ──▶│  evaluate rows_expr via DAP
  │◀─ { type:"rows", ... } ────── │
```

Each `fetch_rows` triggers a fresh DAP `evaluate` call. The rows expression:

```python
__import__('json').dumps(
  df.iloc[{offset}:{offset+limit}]
    .astype(object)
    .where(df.iloc[...].notna(), None)
    .values.tolist()
)
```

The `.astype(object).where(...notna(), None)` step ensures `NaN` values become JSON `null` rather than the non-standard `NaN` token.

---

## Threading Model

Neovim runs on a single thread. Both the `vim.uv` I/O callbacks and the DAP response callbacks are dispatched on this same thread via Neovim's event loop.

```
Neovim event loop (single thread)
  │
  ├── vim.uv read callback (new TCP data arrives)
  │     └── ws.decode(buf) → frame
  │           └── vim.schedule(function()
  │                 handlers.dispatch(frame.payload, ...)  ← safe Neovim API
  │                   └── dap_provider:evaluate(expr, ..., callback)
  │                         └── session:request("evaluate", ..., function(err, resp)
  │                               └── vim.schedule(function()
  │                                     client:write(ws.encode_json(rows))
  │                                   end)
  │                             end)
  │               end)
  │
  └── vim.uv accept callback (new TCP connection)
        └── handle_connection(client)
```

**Key rule:** `vim.uv` callbacks that call Neovim APIs (like `dap.session()`) must be wrapped with `vim.schedule`. The server's read callback wraps the `handlers.dispatch` call with `vim.schedule` for exactly this reason. The TCP `client:write()` call is a pure libuv operation and is safe from any context.

---

## Server State Machine

Each accepted TCP connection runs a simple state machine:

```
READING_HTTP
  │
  │  parse HTTP headers
  │
  ├─ Upgrade: websocket  ──▶  WS_HANDSHAKE
  │                              │
  │                              │  write 101 response
  │                              ▼
  │                           WEBSOCKET
  │                              │
  │                              │  decode frames in a loop
  │                              │
  │                              ├─ OP_TEXT   → vim.schedule → handlers.dispatch
  │                              ├─ OP_PING   → write pong frame
  │                              ├─ OP_CLOSE  → write close frame → close conn
  │                              └─ (partial frame) → wait for more data
  │
  └─ (any other path)  ──▶  serve index.html → close connection
```

---

## Module Dependency Graph

```
init.lua
  ├── config.lua
  ├── utils/logging.lua
  ├── commands.lua
  │     └── orchestrator.lua
  │           ├── server/server.lua
  │           │     ├── server/http.lua
  │           │     ├── server/ws.lua
  │           │     │     └── server/sha1.lua
  │           │     │     └── server/http.lua
  │           │     ├── server/handlers.lua
  │           │     │     ├── server/ws.lua
  │           │     │     └── server/session_store.lua
  │           │     └── utils/logging.lua
  │           ├── server/session_store.lua
  │           ├── browser.lua
  │           │     ├── utils/os.lua
  │           │     └── utils/logging.lua
  │           ├── dap/  (injected)
  │           └── language/ (injected)
  ├── dap/nvim_dap.lua
  │     ├── dap/provider.lua
  │     └── utils/classes.lua
  └── language/python_pandas.lua
        ├── language/provider.lua
        └── utils/classes.lua
```

`DapProvider` and `LanguageProvider` are injected into `orchestrator` and `handlers` by `init.lua`, keeping those modules decoupled from any concrete implementation.
