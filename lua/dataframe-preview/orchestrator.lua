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
-- resolve_provider(providers, dap_provider, frame_id, var_name, done_cb)
--
-- When a single provider is given it is used directly.  When multiple are
-- given each one's can_handle_expr is evaluated via DAP sequentially; the
-- one that returns true is selected.  Calls done_cb(provider, nil) on
-- success or done_cb(nil, err) if 0 or >1 providers match.
-- ---------------------------------------------------------------------------
local function resolve_provider(providers, dap_provider, frame_id, var_name, done_cb)
  if #providers == 1 then
    done_cb(providers[1], nil)
    return
  end

  local results = {}
  local index = 0

  local function check_next()
    index = index + 1
    if index > #providers then
      local matched = {}
      for _, r in ipairs(results) do
        if r.matched then
          matched[#matched + 1] = r.provider
        end
      end
      if #matched == 0 then
        done_cb(nil, "dataframe-preview: no provider can handle '" .. var_name .. "'")
      elseif #matched > 1 then
        done_cb(nil, "dataframe-preview: multiple providers matched '" .. var_name .. "'")
      else
        done_cb(matched[1], nil)
      end
      return
    end

    local provider = providers[index]
    dap_provider:evaluate(provider:can_handle_expr(var_name), frame_id, function(err, result)
      local ok, matched = pcall(provider.parse_can_handle, provider, result)
      results[#results + 1] = { provider = provider, matched = not err and ok and matched }
      check_next()
    end)
  end

  check_next()
end

-- ---------------------------------------------------------------------------
-- M.preview(dap_provider, lang_providers)
--
-- Entry point — called by commands.lua when the user runs :PreviewDataFrame.
--
-- `dap_provider`   — an object that can talk to the active debugger
--                    (see dap/provider.lua for the interface)
-- `lang_providers` — list of LanguageProvider objects registered for the
--                    current filetype (see language/provider.lua)
--
-- Both providers are injected here (not required directly) so they can be
-- swapped out for other debuggers or languages without changing this file.
-- ---------------------------------------------------------------------------
function M.preview(dap_provider, lang_providers)
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

    -- ── Step 2: resolve which provider handles this variable ──────────────
    -- With a single provider this is a no-op fast path.  With multiple
    -- providers each one's can_handle_expr is evaluated sequentially until
    -- exactly one returns true.
    resolve_provider(lang_providers, dap_provider, frame_id, var_name, function(lang_provider, resolve_err)
      if resolve_err then
        log.error(resolve_err)
        return
      end

      -- ── Step 3: evaluate a metadata expression ───────────────────────────
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

        -- ── Step 4: parse the metadata ─────────────────────────────────────
        -- If the variable is not a DataFrame the expression will fail or
        -- return something unparseable.  pcall turns that into a nil return
        -- instead of an uncaught error.
        local ok, metadata = pcall(lang_provider.parse_metadata, lang_provider, result)
        if not ok then
          log.error("dataframe-preview: '" .. var_name .. "' does not appear to be a DataFrame")
          return
        end

        -- ── Step 5: register the session ───────────────────────────────────
        -- We store var_name + frame_id + metadata + lang_provider under a
        -- UUID so the WebSocket handler can look them up when the browser
        -- connects.
        local uuid = generate_uuid()
        session_store.create(uuid, {
          var_name = var_name,
          frame_id = frame_id,
          metadata = metadata,
          lang_provider = lang_provider,
          sort = {},
          filter_tree = { type = "group", logic = "AND", children = {} },
        })

        -- ── Step 6 & 7: start server, broadcast, and open browser ────────────
        -- ensure_started is idempotent — it only actually starts the server
        -- on the first call.  The callback fires with the port number once
        -- the server is ready (immediately if it was already running).
        server.ensure_started(dap_provider, function(port)
          -- Broadcast the new session to any already-open browser tabs.
          -- If no clients are connected this is a no-op.
          server.broadcast({
            type = "session_created",
            uuid = uuid,
            var_name = var_name,
            row_count = metadata.row_count,
            col_count = metadata.col_count,
            columns = metadata.columns,
            dtypes = metadata.dtypes,
          })

          -- Only open a new browser window if no tab is currently connected.
          -- If the browser is already open it will receive the session_created
          -- broadcast above and add the new tab to its navbar automatically.
          if not server.has_connected_clients() then
            local url = string.format("http://127.0.0.1:%d", port)
            log.info("dataframe-preview: opening browser (" .. var_name .. ", " .. metadata.row_count .. " rows)")
            browser.open(url)
          else
            log.info("dataframe-preview: session broadcast (" .. var_name .. ")")
          end
        end)
      end)
    end)
  end)
end

return M
