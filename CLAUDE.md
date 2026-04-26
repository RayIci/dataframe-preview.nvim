# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make install-hooks   # install git pre-commit hook (run once after cloning)
make format          # format Lua with StyLua  (cargo install stylua)
make format-check    # check formatting without modifying (used in CI/pre-commit)
make lint            # luacheck              (luarocks install luacheck)
make test            # run plenary/busted test suite (requires plenary.nvim in lazy)
make build-ui        # install npm deps + build frontend → ui/dist/index.html
make ui-dev          # Vite dev server with hot reload
make ui-typecheck    # TypeScript type check only
make ci              # format-check + lint + test + ui-typecheck
```

To run a single test file:
```bash
nvim --headless -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/dataframe-preview/server/', { minimal_init = 'tests/minimal_init.lua' })" \
  -c "qa!"
```

StyLua config (stylua.toml): 120-column width, 2-space indent, double quotes.  
Luacheck globals: `vim`, `bit`; `--no-unused-args` is always passed.

The pre-built frontend bundle (`ui/dist/index.html`) is committed to the repo — users don't need Node.js at runtime. Rebuild it with `make build-ui` after any UI changes.

## Architecture

The plugin wires three boundaries:

1. **Neovim ↔ DAP adapter** — read-only DAP `evaluate` requests via `nvim-dap`
2. **Neovim ↔ Browser** — a `vim.uv` TCP server speaking HTTP + RFC 6455 WebSocket
3. **Lua ↔ Frontend** — a typed JSON message protocol over that WebSocket

### Lua module flow

```
init.lua          → setup(), wires DapProvider + LanguageProvider via DI
commands.lua      → registers :PreviewDataFrame
orchestrator.lua  → main async workflow: frame_id → metadata → session → browser
server/server.lua → vim.uv TCP server lifecycle (lazy start, OS-assigned port)
server/http.lua   → HTTP parser + response builder (serves dist/index.html)
server/ws.lua     → RFC 6455 framing; depends on server/sha1.lua for handshake
server/handlers.lua → WebSocket message dispatcher (init/fetch_rows → DAP evaluate)
server/session_store.lua → UUID → { var_name, frame_id, metadata, ws_client }
browser.lua       → cross-platform browser opener (Linux/WSL/macOS)
language/provider.lua → LanguageProvider abstract interface
language/python_pandas.lua → Pandas implementation
dap/provider.lua  → DapProvider abstract interface
dap/nvim_dap.lua  → mfussenegger/nvim-dap implementation
utils/logging.lua, utils/os.lua, utils/classes.lua → shared utilities
```

### Critical threading rule

Neovim is single-threaded. `vim.uv` I/O callbacks **must not** call Neovim APIs directly — wrap with `vim.schedule`. The server's TCP read callback wraps `handlers.dispatch` with `vim.schedule` for exactly this reason. `client:write()` is a pure libuv operation and is safe from any context.

### Provider interfaces (dependency injection)

`DapProvider` and `LanguageProvider` are injected into `orchestrator` and `handlers` by `init.lua`. This decouples the core from any concrete debugger or language.

**LanguageProvider** must implement:
- `:metadata_expr(var_name)` → DAP evaluate expression returning JSON `{shape, columns, dtypes}`
- `:rows_expr(var_name, offset, limit)` → DAP evaluate expression returning JSON array-of-arrays
- `:parse_metadata(raw)` → `{ row_count, col_count, columns, dtypes }`
- `:parse_rows(raw)` → `any[][]`

**DapProvider** must implement:
- `:is_available()` → boolean
- `:get_frame_id(callback)` → async, calls `callback(frame_id, nil)` or `callback(nil, err)`
- `:evaluate(expr, frame_id, callback)` → async, calls `callback(nil, result)` or `callback(err, nil)`

Use `utils/classes.lua` for object construction: `return classes.new(MyProvider)`.

### WebSocket protocol

```
Browser → { type:"init",       session: uuid }
Lua    ← { type:"meta",       columns, dtypes, row_count }
Browser → { type:"fetch_rows", offset, limit }
Lua    ← { type:"rows",       offset, data: [[...]] }
```

### Frontend stack

React 19 + shadcn/ui + TanStack Virtual (virtual scrolling) + Zustand (state). Built with Vite into a single `ui/dist/index.html` via `vite-plugin-singlefile`. Source in `ui/src/`.

## Tests

Tests live in `tests/` mirroring `lua/dataframe-preview/`. They use plenary/busted loaded via `tests/minimal_init.lua`, which prepends `~/.local/share/nvim/lazy/plenary.nvim` and the repo root to `runtimepath`.
