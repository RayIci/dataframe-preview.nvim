# Extending dataframe-preview.nvim

The plugin is built around two interfaces: `LanguageProvider` and `DapProvider`. Implementing either lets you support new dataframe libraries, languages, or debug clients without touching the core.

---

## LanguageProvider

### Interface

```lua
-- lua/dataframe-preview/language/provider.lua

---@class LanguageProvider
-- :metadata_expr(var_name)          → string   (DAP evaluate expression)
-- :rows_expr(var_name, offset, limit) → string (DAP evaluate expression)
-- :parse_metadata(raw)              → Metadata
-- :parse_rows(raw)                  → any[][]
```

The expressions are sent verbatim to the DAP adapter's `evaluate` endpoint. They must be **read-only** (no side effects) and must return a **JSON string** that your `parse_*` methods can decode.

```lua
---@class Metadata
---@field row_count integer
---@field col_count integer
---@field columns   string[]
---@field dtypes    string[]
```

### Skeleton

```lua
local LanguageProvider = require("dataframe-preview.language.provider")
local classes          = require("dataframe-preview.utils.classes")

---@class MyProvider : LanguageProvider
local MyProvider = setmetatable({}, { __index = LanguageProvider })

function MyProvider:metadata_expr(var_name)
  -- Must produce a JSON string with keys: shape, columns, dtypes
  return "..."
end

function MyProvider:rows_expr(var_name, offset, limit)
  -- Must produce a JSON array of arrays: [[row0col0, row0col1, ...], ...]
  return "..."
end

function MyProvider:parse_metadata(raw)
  local d = vim.json.decode(raw)
  return {
    row_count = d.shape[1],
    col_count = d.shape[2],
    columns   = d.columns,
    dtypes    = d.dtypes,
  }
end

function MyProvider:parse_rows(raw)
  return vim.json.decode(raw)
end

function MyProvider.new()
  return classes.new(MyProvider)
end

return MyProvider
```

### Example: Polars (Python)

```lua
-- lua/dataframe-preview/language/python_polars.lua

local LanguageProvider = require("dataframe-preview.language.provider")
local classes          = require("dataframe-preview.utils.classes")

local PythonPolars = setmetatable({}, { __index = LanguageProvider })

function PythonPolars:metadata_expr(var_name)
  return string.format(
    "__import__('json').dumps({"
      .. "'shape': list(%s.shape),"
      .. "'columns': %s.columns,"
      .. "'dtypes': [str(d) for d in %s.dtypes]"
      .. "})",
    var_name, var_name, var_name
  )
end

function PythonPolars:rows_expr(var_name, offset, limit)
  -- Polars .to_dicts() returns a list of {col: val} dicts.
  -- We convert to a list of lists to match the shared protocol.
  return string.format(
    "__import__('json').dumps("
      .. "[[row[c] for c in %s.columns] "
      .. "for row in %s.slice(%d, %d).to_dicts()]"
      .. ", default=str)",  -- default=str handles non-JSON-native types
    var_name, var_name, offset, limit
  )
end

function PythonPolars:parse_metadata(raw)
  local d = vim.json.decode(raw)
  return {
    row_count = d.shape[1],
    col_count = d.shape[2],
    columns   = d.columns,
    dtypes    = d.dtypes,
  }
end

function PythonPolars:parse_rows(raw)
  return vim.json.decode(raw)
end

function PythonPolars.new()
  return classes.new(PythonPolars)
end

return PythonPolars
```

Usage:

```lua
require("dataframe-preview").setup({
  lang_provider = require("dataframe-preview.language.python_polars").new(),
})
```

### Example: C++ (Eigen matrix via GDB/DAP)

C++ debuggers evaluate C++ expressions. The key challenge is that C++ has no built-in JSON serialization, so you need a helper expression that builds a JSON-like string manually, or (if your adapter supports it) calls a helper function you defined in the program.

```lua
-- Assumes a helper function `dfpreview_serialize(mat, offset, limit)`
-- is compiled into the target binary in debug builds.
-- This is NOT code injection — the function must pre-exist in the binary.

local CppEigenProvider = setmetatable({}, { __index = LanguageProvider })

function CppEigenProvider:metadata_expr(var_name)
  -- Returns: {"shape":[rows,cols],"columns":["0","1",...],"dtypes":["double",...]}
  return string.format(
    '"{\"shape\":[" + std::to_string(%s.rows()) + "," + '
      .. 'std::to_string(%s.cols()) + "]}"',
    var_name, var_name
  )
end

-- parse_metadata would need to construct columns/dtypes from shape
function CppEigenProvider:parse_metadata(raw)
  -- raw is the string result from the DAP evaluate, e.g. '{"shape":[100,3]}'
  local d = vim.json.decode(raw)
  local cols = {}
  local dtypes = {}
  for i = 1, d.shape[2] do
    cols[i]   = tostring(i - 1)
    dtypes[i] = "double"
  end
  return { row_count=d.shape[1], col_count=d.shape[2], columns=cols, dtypes=dtypes }
end
```

> **Note:** The complexity of C++ expressions depends heavily on the debugger and adapter (GDB, LLDB, VS Code's cpptools). Test your expressions in the DAP REPL first.

### Auto-detecting the language

If you want the plugin to pick a provider automatically based on the file type or DAP session:

```lua
-- In your setup or a wrapper module:
local ft = vim.bo.filetype
local lang_provider

if ft == "python" then
  -- Could auto-detect Polars vs Pandas at evaluation time
  lang_provider = require("dataframe-preview.language.python_pandas").new()
elseif ft == "cpp" then
  lang_provider = require("my.providers.cpp_eigen").new()
end

require("dataframe-preview").setup({ lang_provider = lang_provider })
```

---

## DapProvider

### Interface

```lua
-- lua/dataframe-preview/dap/provider.lua

---@class DapProvider
-- :is_available()                              → boolean
-- :get_frame_id(callback)                      → (async) frame_id | nil, err | nil
-- :evaluate(expr, frame_id, callback)          → (async) nil, result | nil, err | nil
```

All methods that interact with the debugger are **asynchronous**. Your implementation must call `callback` exactly once — either with a result or with an error string.

### Skeleton

```lua
local DapProvider = require("dataframe-preview.dap.provider")
local classes     = require("dataframe-preview.utils.classes")

---@class MyDapProvider : DapProvider
local MyDapProvider = setmetatable({}, { __index = DapProvider })

---@return boolean
function MyDapProvider:is_available()
  local ok = pcall(require, "my-dap-plugin")
  return ok
end

---@param callback fun(frame_id: integer|nil, err: string|nil)
function MyDapProvider:get_frame_id(callback)
  -- Resolve the current stack frame ID.
  -- Must call callback(frame_id, nil) on success
  --          or callback(nil, "error message") on failure.
  local my_dap = require("my-dap-plugin")
  local session = my_dap.current_session()
  if not session then
    callback(nil, "No active session")
    return
  end
  -- ... async request ...
  callback(frame_id, nil)
end

---@param expr     string
---@param frame_id integer
---@param callback fun(err: string|nil, result: string|nil)
function MyDapProvider:evaluate(expr, frame_id, callback)
  -- Evaluate `expr` in the given frame.
  -- result must be the string representation of the evaluated value.
  local my_dap = require("my-dap-plugin")
  my_dap.evaluate(expr, frame_id, function(response)
    if response.error then
      callback(response.error, nil)
    else
      callback(nil, response.value)  -- must be a string
    end
  end)
end

function MyDapProvider.new()
  return classes.new(MyDapProvider)
end

return MyDapProvider
```

### Async contract

The callbacks from `get_frame_id` and `evaluate` are called on the **Neovim main thread** via `vim.schedule`. This means:

- You **may** call any Neovim API inside the callbacks.
- You **must not** call Neovim APIs directly inside a raw `vim.uv` callback without `vim.schedule`.
- The orchestrator chains these calls sequentially — `evaluate` is always called after `get_frame_id` resolves.

### Example: vimspector (hypothetical)

```lua
local VimspectorDap = setmetatable({}, { __index = DapProvider })

function VimspectorDap:is_available()
  return vim.fn.exists(":VimspectorEval") == 2
end

function VimspectorDap:get_frame_id(callback)
  -- vimspector exposes the current frame through its Python API
  local frame_id = vim.fn["vimspector#GetCurrentFrame"]()
  vim.schedule(function()
    if frame_id and frame_id ~= vim.NIL then
      callback(frame_id, nil)
    else
      callback(nil, "vimspector: no current frame")
    end
  end)
end

function VimspectorDap:evaluate(expr, frame_id, callback)
  vim.fn["vimspector#EvalWithCallback"](expr, frame_id, function(result)
    vim.schedule(function()
      callback(nil, result)
    end)
  end)
end
```

---

## Registering a custom provider via setup

The `setup` function accepts `dap_provider` and `lang_provider` overrides directly:

```lua
require("dataframe-preview").setup({
  dap_provider  = require("my.providers.vimspector").new(),
  lang_provider = require("my.providers.python_polars").new(),
  debug         = false,
})
```

> `init.lua` will need a small update to forward these opts to the orchestrator. See the note at the bottom of `lua/dataframe-preview/init.lua` — the current MVP wires `NvimDap` and `PythonPandas` directly. Adding `opts.dap_provider` and `opts.lang_provider` fallback is a one-line change per provider.

---

## Testing your provider

Place your spec in `tests/dataframe-preview/language/` or `tests/dataframe-preview/dap/` to mirror the module structure. Use a mock DAP provider to test parsing logic in isolation:

```lua
-- tests/dataframe-preview/language/python_polars_spec.lua
local PythonPolars = require("dataframe-preview.language.python_polars")

describe("PythonPolars.parse_metadata", function()
  local p = PythonPolars.new()

  it("parses shape and columns", function()
    local raw = vim.json.encode({
      shape   = { 500, 3 },
      columns = { "a", "b", "c" },
      dtypes  = { "Int64", "Utf8", "Float64" },
    })
    local meta = p:parse_metadata(raw)
    assert.equal(500, meta.row_count)
    assert.equal(3,   meta.col_count)
  end)
end)
```

Run with `make test`.
