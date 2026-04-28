# dataframe-preview.nvim

## Table of contents

<!--toc:start-->

- [dataframe-preview.nvim](#dataframe-previewnvim)
  - [Table of contents](#table-of-contents)
  - [Features](#features)
  - [Requirements](#requirements)
  - [Installation](#installation)
  - [Configuration](#configuration)
  - [Usage](#usage)
    - [Recommended keymap](#recommended-keymap)
    - [Multiple previews](#multiple-previews)
  - [How It Works](#how-it-works)
  - [Extending](#extending)
    - [Adding a language (e.g. Polars, R, C++)](#adding-a-language-eg-polars-r-c)
    - [Adding a DAP client](#adding-a-dap-client)
  - [Development](#development)
  - [Project Structure](#project-structure)
  - [Docs](#docs)
  - [License](#license)
  <!--toc:end-->

A Neovim plugin that lets you visualize dataframes in a live browser UI while debugging — no code injection, no side effects, no CSV files.

Place your cursor on any Pandas DataFrame variable, trigger `:PreviewDataFrame`, and a fully interactive table opens in your default browser with virtual scrolling that handles millions of rows instantly.

---

## Features

- **Zero code injection** — data is read via standard DAP `evaluate` requests. Nothing is written to disk or injected into the debugged process.
- **Instant load** — the browser UI renders only the visible rows using virtual scrolling. A 10M-row DataFrame opens in the same time as a 10-row one.
- **On-demand chunking** — rows are fetched in chunks of 100 as you scroll. The Lua backend streams them over WebSocket.
- **Async by design** — the local HTTP/WebSocket server runs on `vim.uv` (libuv). Neovim never blocks.
- **Sort and filter** — multi-column sort and recursive AND/OR filter trees applied server-side via DAP; only matching rows are ever fetched.
- **Extensible** — clean `DapProvider` and `LanguageProvider` interfaces make it straightforward to support additional debuggers and languages beyond the defaults.
- **Self-contained** — the pre-built frontend bundle is committed to the repo. Users need only Neovim + a DAP adapter. No Node.js required at runtime.

---

## Requirements

| Requirement                                                       | Version                           |
| ----------------------------------------------------------------- | --------------------------------- |
| Neovim                                                            | ≥ 0.10 (requires `vim.uv`)        |
| [mfussenegger/nvim-dap](https://github.com/mfussenegger/nvim-dap) | any recent                        |
| A DAP debug adapter                                               | e.g. `debugpy` for Python         |
| Python + Pandas                                                   | for the default language provider |

---

## Installation

**lazy.nvim**

```lua
{
  "RayIci/dataframe-preview.nvim",
  dependencies = { "mfussenegger/nvim-dap" },
  config = function()
    require("dataframe-preview").setup()
  end,
}
```

**packer.nvim**

```lua
use {
  "RayIci/dataframe-preview.nvim",
  requires = { "mfussenegger/nvim-dap" },
  config = function()
    require("dataframe-preview").setup()
  end,
}
```

---

## Configuration

```lua
require("dataframe-preview").setup({
  -- Enable debug-level logging via vim.notify
  debug = false,  -- default

  -- Providers per filetype. Each entry is an array; when multiple providers
  -- are listed the plugin evaluates can_handle_expr for each in order and
  -- picks the first match. Omit to use the built-in Pandas provider for Python.
  lang_providers = {
    python = { require("dataframe-preview.language.python_pandas").new() },
  },
})
```

| Option           | Type                                | Default           | Description                                                                                                            |
| ---------------- | ----------------------------------- | ----------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `debug`          | `boolean`                           | `false`           | Enables verbose `DEBUG`-level log messages                                                                             |
| `lang_providers` | `table<string, LanguageProvider[]>` | Pandas for Python | Providers per filetype. Multiple providers are tried in order; the first whose `can_handle_expr` returns true is used. |

---

## Usage

1. Open a Python file and start a debug session with `nvim-dap`.
2. Set a breakpoint on a line where a Pandas DataFrame exists in scope.
3. Run the program until it stops at the breakpoint.
4. Move the cursor to the DataFrame variable name.
5. Run `:PreviewDataFrame` (or your keymap).

A new browser tab opens with the DataFrame. Scroll down to load more rows on demand.

### Recommended keymap

```lua
vim.keymap.set("n", "<leader>dp", "<cmd>PreviewDataFrame<cr>", {
  desc = "Preview DataFrame under cursor",
})
```

### Multiple previews

Each invocation opens a new browser tab with its own independent data session. You can preview `df_users` and `df_orders` simultaneously — they will not interfere.

---

## How It Works

```
Neovim (cursor on "df")
  │  :PreviewDataFrame
  ▼
Orchestrator
  ├─ nvim-dap: get current stack frame ID
  ├─ nvim-dap: evaluate read-only Python expression → JSON metadata
  ├─ Register session (UUID)
  ├─ Start vim.uv TCP server (lazy, port auto-assigned)
  └─ Open browser: http://127.0.0.1:{PORT}/?session={UUID}

Browser tab
  └─ WebSocket ws://127.0.0.1:{PORT}/ws
       ├─ → { type:"init",             session }
       ├─ ← { type:"meta",             columns, dtypes, row_count }
       ├─ → { type:"fetch_rows",       offset:0,   limit:100 }
       ├─ ← { type:"rows",             data:[[...]] }
       ├─ → { type:"fetch_rows",       offset:100, limit:100 }  ← scroll trigger
       ├─ ← { type:"rows",             data:[[...]] }
       ├─ → { type:"apply_sort_filter", sort:[…], filter_tree:{…} }  ← user sorts/filters
       └─ ← { type:"meta",             row_count (filtered) }
```

See [`docs/architecture.md`](docs/architecture.md) for the full breakdown.

---

## Extending

### Adding a language (e.g. Polars, R, C++)

Implement the `LanguageProvider` interface:

```lua
local LanguageProvider = require("dataframe-preview.language.provider")
local classes = require("dataframe-preview.utils.classes")

local MyProvider = setmetatable({}, { __index = LanguageProvider })

function MyProvider:metadata_expr(var_name, filter_tree)
  -- Must return JSON: { shape:[rows,cols], columns:[...], dtypes:[...] }
  -- filter_tree is a FilterNode (or nil); row_count should reflect filtered rows.
  return string.format("my_metadata_fn(%s)", var_name)
end

function MyProvider:rows_expr(var_name, offset, limit, sort, filter_tree)
  -- sort is a SortEntry[] (or nil); filter_tree is a FilterNode (or nil).
  return string.format("my_rows_fn(%s, %d, %d)", var_name, offset, limit)
end

function MyProvider:parse_metadata(raw)
  local d = vim.json.decode(raw)
  return { row_count=d.shape[1], col_count=d.shape[2],
           columns=d.columns, dtypes=d.dtypes }
end

function MyProvider:parse_rows(raw)
  return vim.json.decode(raw)
end

function MyProvider:can_handle_expr(var_name)
  -- Must return a DAP expression that evaluates to a truthy/falsy string
  return string.format("isinstance(%s, MyType)", var_name)
end

function MyProvider:parse_can_handle(raw)
  return raw == "True"
end

function MyProvider.new() return classes.new(MyProvider) end
```

Then pass it to `setup`:

```lua
require("dataframe-preview").setup({
  lang_providers = {
    python = { MyProvider.new() },
  },
})
```

See [`docs/extending.md`](docs/extending.md) for complete Polars and C++ examples.

### Adding a DAP client

> **Note:** The DAP provider is not yet configurable via `setup()` — `NvimDap` is wired in `init.lua` directly. To use a custom provider, implement the `DapProvider` interface and replace the `NvimDap.new()` call in `init.lua` with your own instance.

```lua
local DapProvider = require("dataframe-preview.dap.provider")
local MyDap = setmetatable({}, { __index = DapProvider })

function MyDap:is_available() return true end
function MyDap:get_frame_id(callback) ... end
function MyDap:evaluate(expr, frame_id, callback) ... end
```

See [`docs/extending.md`](docs/extending.md) for the full interface contract and a worked example.

---

## Development

```bash
make install-hooks   # install git pre-commit hook
make format          # format Lua with StyLua  (cargo install stylua)
make format-check    # check formatting without modifying
make lint            # luacheck              (luarocks install luacheck)
make test            # run plenary test suite
make build-ui        # build frontend → ui/dist/index.html  (requires Node.js)
make ui-dev          # start Vite dev server with hot reload
make ui-typecheck    # TypeScript type check
make ci              # format-check + lint + test + ui-typecheck
make clean           # remove build artifacts
```

---

## Project Structure

```
dataframe-preview.nvim/
├── plugin/                          # Neovim plugin entrypoint
├── lua/dataframe-preview/
│   ├── init.lua                     # setup(), dependency injection
│   ├── config.lua                   # option schema + defaults
│   ├── commands.lua                 # :PreviewDataFrame registration
│   ├── orchestrator.lua             # main workflow coordinator
│   ├── browser.lua                  # cross-platform browser opener
│   ├── dap/
│   │   ├── provider.lua             # DapProvider interface
│   │   └── nvim_dap.lua             # mfussenegger/nvim-dap implementation
│   ├── language/
│   │   ├── provider.lua             # LanguageProvider interface
│   │   └── python_pandas.lua        # Python Pandas implementation
│   └── server/
│       ├── server.lua               # vim.uv TCP server lifecycle
│       ├── http.lua                 # HTTP parser + response builder
│       ├── ws.lua                   # WebSocket RFC 6455 framing
│       ├── sha1.lua                 # Pure-Lua SHA1 for WS handshake
│       ├── session_store.lua        # UUID → session registry
│       └── handlers.lua             # WebSocket message handlers
├── ui/
│   ├── src/                         # React 19 + shadcn/ui source
│   └── dist/index.html              # Pre-built bundle (committed)
├── tests/                           # Mirrors lua/ — plenary/busted specs
├── docs/                            # Extended documentation
└── scripts/pre-commit               # Git hook (install: make install-hooks)
```

---

## Docs

| Document                                               | Contents                                                     |
| ------------------------------------------------------ | ------------------------------------------------------------ |
| [`docs/architecture.md`](docs/architecture.md)         | Full data-flow, threading model, server state machine        |
| [`docs/extending.md`](docs/extending.md)               | DapProvider + LanguageProvider extension guide with examples |
| [`docs/server-internals.md`](docs/server-internals.md) | HTTP/WebSocket implementation details, SHA1, frame format    |
| [`docs/frontend.md`](docs/frontend.md)                 | UI stack, virtual scrolling strategy, dev workflow           |

---

## License

MIT
