# Server Internals

The Lua server is the bridge between the Neovim/DAP world and the browser. It is entirely built on `vim.uv` (libuv) with no external dependencies.

---

## Startup and Port Assignment

```lua
-- server/server.lua
local tcp = vim.uv.new_tcp()
tcp:bind("127.0.0.1", 0)   -- port 0 → OS assigns a free port
tcp:listen(128, on_connect)

local addr = tcp:getsockname()
-- addr.port is now the actual assigned port, e.g. 54321
```

Binding to port `0` lets the OS pick any available port, which means:

- No hardcoded port to conflict with other services.
- Multiple Neovim sessions on the same machine each get their own port.
- The browser URL (`http://127.0.0.1:{port}/?session={uuid}`) is constructed after the port is known.

The server is **lazy**: it starts on the first `:PreviewDataFrame` call and stays running for the lifetime of the Neovim session. Subsequent previews reuse the same server and port.

A `VimLeavePre` autocmd closes the TCP handle when Neovim exits:

```lua
vim.api.nvim_create_autocmd("VimLeavePre", {
  once     = true,
  callback = function() M.stop() end,
})
```

---

## HTTP Layer

`server/http.lua` implements the minimal HTTP/1.1 subset needed:

- **Request parsing** — reads until `\r\n\r\n`, splits the header block into method, path, and a lowercase header map.
- **Response building** — assembles a status line, headers, and body into a valid HTTP/1.1 response string.

The server only handles two request types:

| Request | Response |
|---|---|
| `GET /` (any path without `Upgrade: websocket`) | HTTP 200, body = `ui/dist/index.html` |
| Any request with `Upgrade: websocket` | HTTP 101, WebSocket upgrade |

The `index.html` path is resolved relative to `server.lua`'s own file path using `debug.getinfo`:

```lua
local ui_path = vim.fn.fnamemodify(
  debug.getinfo(1, "S").source:sub(2),  -- strip the leading "@"
  ":h:h:h:h"                            -- server/ → dataframe-preview/ → lua/ → plugin root
) .. "/ui/dist/index.html"
```

This means the plugin works regardless of where it is installed.

---

## WebSocket Handshake

The WebSocket upgrade handshake (RFC 6455 §4.2.2) requires computing:

```
Sec-WebSocket-Accept = base64( sha1( Sec-WebSocket-Key + GUID ) )
```

where `GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"`.

`server/sha1.lua` implements SHA1 in pure Lua using LuaJIT's `bit` library. The key operations:

| Operation | LuaJIT `bit` call |
|---|---|
| 32-bit AND | `bit.band(a, b)` |
| 32-bit OR | `bit.bor(a, b)` |
| 32-bit XOR | `bit.bxor(a, b)` |
| 32-bit NOT | `bit.bnot(a)` |
| Left rotate | `bit.rol(a, n)` |
| Logical right shift | `bit.rshift(a, n)` |
| Truncate to 32 bits | `bit.tobit(a)` |

The `add32` helper handles modular 32-bit addition. Because LuaJIT's `bit` ops return **signed** 32-bit integers (range `[-2^31, 2^31)`), addition is done in Lua's double space (which can represent integers exactly up to 2^53) and then truncated with `bit.tobit`.

`b64encode` in `sha1.lua` uses the standard base64 alphabet with `=` padding.

---

## WebSocket Frame Format (RFC 6455 §5)

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
├─┼─┼─┼─┼───────┼─┼─────────────────────────────────────────────┤
│F│R│R│R│opcode │M│    Payload len    │   Extended length (opt)  │
│I│S│S│S│       │A│                   │                          │
│N│V│V│V│       │S│                   │                          │
└─┴─┴─┴─┴───────┴─┴─────────────────────────────────────────────┘
                   │ If MASK=1: 4-byte masking key follows       │
                   └─────────────────────────────────────────────┘
```

### Opcodes used

| Hex | Name | Direction | Handled by |
|---|---|---|---|
| `0x1` | Text | both | `ws.encode`, `ws.decode` |
| `0x8` | Close | client→server | write close frame, close conn |
| `0x9` | Ping | client→server | write pong frame |
| `0xA` | Pong | (server→client) | in response to ping |

### Encoding (server → client)

Server frames are **never masked** (RFC 6455 §5.1). Payload length encoding:

| Length | Encoding |
|---|---|
| 0–125 | 1 byte |
| 126–65535 | byte `126` + 2-byte big-endian length |
| ≥ 65536 | byte `127` + 8-byte big-endian length |

### Decoding (client → server)

Client frames are **always masked** (RFC 6455 §5.3). The masking key is 4 bytes immediately after the length field. Each payload byte is unmasked by XORing with `mask_key[(i-1) % 4 + 1]`:

```lua
chars[i] = string.char(bit.bxor(raw:byte(i), mask_key:byte((i-1) % 4 + 1)))
```

The decoder returns `nil` when the buffer does not yet contain a full frame, allowing the server to accumulate TCP chunks before trying again.

---

## Session Store

`server/session_store.lua` is a simple module-level Lua table:

```lua
local _store = {}  -- { [uuid] = Session }
```

Sessions are keyed by UUID and hold:

```lua
---@class Session
---@field var_name      string           -- "df_users"
---@field frame_id      integer          -- DAP stack frame ID
---@field metadata      Metadata|nil     -- row_count, col_count, columns, dtypes
---@field ws_client     uv_tcp_t|nil     -- attached after WebSocket init message
---@field lang_provider LanguageProvider -- provider resolved at preview time
---@field sort          SortEntry[]      -- active multi-column sort (default: {})
---@field filter_tree   FilterNode       -- active recursive filter tree (default: empty root group)
```

The `ws_client` is `nil` until the browser connects and sends `{ type:"init" }`. At that point `handlers.on_init` calls `session_store.attach_client(uuid, client)`.

`lang_provider` is stored at session-creation time so that both the initial metadata fetch and all subsequent row fetches use the same provider without re-running the `can_handle_expr` check.

Sessions are never automatically garbage-collected during a Neovim session (they accumulate, one per `:PreviewDataFrame` call). This is intentional — it allows a closed browser tab to reconnect if the user reopens the URL. Sessions are cleared entirely when the server stops (`VimLeavePre`).

---

## Message Handlers

`server/handlers.lua` dispatches decoded WebSocket JSON to two handlers:

### `on_init(uuid, client)`

1. Calls `session_store.attach_client(uuid, client)` to register the WebSocket handle.
2. Looks up `session.metadata` (already computed by the orchestrator before the browser even connected).
3. Sends `{ type:"meta", var_name, row_count, col_count, columns, dtypes }`.

### `on_fetch_rows(uuid, offset, limit, client, dap_provider, lang_provider)`

1. Gets `session.var_name` and `session.frame_id` from the store.
2. Calls `lang_provider:rows_expr(var_name, offset, limit, session.sort, session.filter_tree)` to build the expression.
3. Calls `dap_provider:evaluate(expr, frame_id, cb)` — this is async.
4. In the callback, calls `lang_provider:parse_rows(result)`.
5. Sends `{ type:"rows", offset, data:[[...]] }`.

### `on_apply_sort_filter(uuid, sort, filter_tree, client, dap_provider)`

1. Looks up the session by UUID.
2. Updates `session.sort` and `session.filter_tree` with the values sent by the browser.
3. Calls `lang_provider:metadata_expr(var_name, filter_tree)` to build a new metadata expression that reflects the active filter.
4. Calls `dap_provider:evaluate(expr, frame_id, cb)` — this is async.
5. In the callback, calls `lang_provider:parse_metadata(result)` and stores the result in `session.metadata`.
6. Sends an updated `{ type:"meta", row_count, col_count, columns, dtypes }` so the frontend can resize the virtual scroller to the filtered row count.

After this response the frontend will re-issue `fetch_rows` requests; those calls read `session.sort` and `session.filter_tree` automatically, so the returned rows already reflect the active sort/filter.

All three handlers send `{ type:"error", message }` on any failure so the UI can display it.

---

## Error Handling Summary

| Failure point | User-visible effect |
|---|---|
| No active DAP session | `vim.notify` error: "No active DAP session" |
| Not paused at a breakpoint | `vim.notify` error: "Debugger is not paused…" |
| Variable not a DataFrame | `vim.notify` error: "failed to parse metadata" |
| DAP evaluate error | `vim.notify` error with DAP error message |
| Row fetch DAP error | `{ type:"error" }` sent to browser UI |
| Row parse error | `{ type:"error" }` sent to browser UI |
| `ui/dist/index.html` missing | Browser shows "Run: make build-ui" inline |
| Browser tab closed mid-stream | OP_CLOSE frame → server closes TCP handle gracefully |
