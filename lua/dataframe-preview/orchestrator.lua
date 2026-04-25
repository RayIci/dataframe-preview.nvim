-- orchestrator.lua
--
-- The main workflow coordinator.  When the user runs :PreviewDataFrame this
-- module drives the entire sequence of async steps:
--
--   1. Read the variable name from the editor cursor.
--   2. Ask the DAP adapter for the current stack frame ID.
--   3. Evaluate a metadata expression (shape, columns, dtypes) via DAP.
--   4. Register a session in the session store.
--   5. Ensure the local HTTP/WebSocket server is running.
--   6. Open the browser at the session URL.
--
-- WHY IS THIS ALL ASYNC?
--   Steps 2 and 3 talk to an external debug adapter process over a socket.
--   We cannot block Neovim's main thread waiting for a response — that would
--   freeze the editor.  Instead each step accepts a callback that fires when
--   the result is ready, and the next step is kicked off from inside that
--   callback.  This is the same pattern as Node.js "callback chains".

local server = require("dataframe-preview.server.server")
local session_store = require("dataframe-preview.server.session_store")
local browser = require("dataframe-preview.browser")
local log = require("dataframe-preview.utils.logging")

local M = {}

-- Generate a UUID-like string to uniquely identify this preview session.
--
-- We don't need cryptographic randomness here — the UUID just needs to be
-- unique enough that two :PreviewDataFrame calls in the same Neovim session
-- don't collide.  We combine:
--   • the process ID      (constant per Neovim session, but unique across machines)
--   • a nanosecond timer  (changes every call)
--   • math.random         (additional entropy)
--
-- The result looks like a real UUID v4 (8-4-4-4-12 hex groups) but is not
-- RFC 4122 compliant.  That is fine for our purposes.
---@return string
local function generate_uuid()
  local pid = vim.uv.os_getpid()
  local time = vim.uv.hrtime() -- nanoseconds since some arbitrary epoch
  math.randomseed(time)
  return string.format(
    "%08x-%04x-4%03x-%04x-%012x",
    pid,
    math.random(0, 0xFFFF),
    math.random(0, 0xFFF),
    math.random(0x8000, 0xBFFF),
    math.random(0, 0xFFFFFFFFFFFF)
  )
end

-- ---------------------------------------------------------------------------
-- M.preview(dap_provider, lang_provider)
--
-- Entry point — called by commands.lua when the user runs :PreviewDataFrame.
--
-- `dap_provider`  — an object that can talk to the active debugger
--                   (see dap/provider.lua for the interface)
-- `lang_provider` — an object that knows how to serialise the dataframe
--                   (see language/provider.lua for the interface)
--
-- Both providers are injected here (not required directly) so they can be
-- swapped out for other debuggers or languages without changing this file.
-- ---------------------------------------------------------------------------
function M.preview(dap_provider, lang_provider)
  -- Sanity-check that the DAP plugin is actually loaded before doing anything.
  if not dap_provider:is_available() then
    log.error("dataframe-preview: DAP provider is not available")
    return
  end

  -- Read the word under the cursor.  This is the variable name the user wants
  -- to preview.  vim.fn.expand("<cword>") returns the "word" under the cursor
  -- using Vim's word definition (alphanumeric + underscores).
  local var_name = vim.fn.expand("<cword>")
  if var_name == "" then
    log.warn("dataframe-preview: cursor is not on a variable name")
    return
  end

  -- ── Step 1: get the current DAP stack frame ID ───────────────────────────
  -- The frame ID tells the debug adapter which scope to evaluate expressions
  -- in.  Without it, variable names would not be in scope.
  -- This call is async — the callback fires when the debug adapter responds.
  dap_provider:get_frame_id(function(frame_id, err)
    if err then
      log.error("dataframe-preview: " .. err)
      return
    end

    -- ── Step 2: evaluate a metadata expression ─────────────────────────────
    -- lang_provider:metadata_expr returns a read-only expression like:
    --   __import__('json').dumps({'shape': list(df.shape), ...})
    -- The debug adapter evaluates this in the paused Python process and
    -- returns the result as a string.
    local meta_expr = lang_provider:metadata_expr(var_name)

    dap_provider:evaluate(meta_expr, frame_id, function(eval_err, result)
      if eval_err then
        log.error("dataframe-preview: failed to evaluate '" .. var_name .. "': " .. eval_err)
        return
      end

      -- ── Step 3: parse the metadata ───────────────────────────────────────
      -- If the variable is not a DataFrame the expression will fail or
      -- return something unparseable.  pcall turns that into a nil return
      -- instead of an uncaught error.
      local ok, metadata = pcall(lang_provider.parse_metadata, lang_provider, result)
      if not ok then
        log.error("dataframe-preview: '" .. var_name .. "' does not appear to be a DataFrame")
        return
      end

      -- ── Step 4: register the session ─────────────────────────────────────
      -- We store var_name + frame_id + metadata under a UUID so the
      -- WebSocket handler can look them up when the browser connects.
      local uuid = generate_uuid()
      session_store.create(uuid, {
        var_name = var_name,
        frame_id = frame_id,
        metadata = metadata,
      })

      -- ── Step 5 & 6: start server and open browser ─────────────────────────
      -- ensure_started is idempotent — it only actually starts the server on
      -- the first call.  The callback fires with the port number once the
      -- server is ready (immediately if it was already running).
      server.ensure_started(dap_provider, lang_provider, function(port)
        local url = string.format("http://127.0.0.1:%d/?session=%s", port, uuid)
        log.info("dataframe-preview: opening " .. var_name .. " (" .. metadata.row_count .. " rows)")
        browser.open(url)
      end)
    end)
  end)
end

return M
