-- handlers.lua
--
-- Processes the JSON messages that the browser sends over WebSocket.
--
-- The browser speaks a simple protocol with two message types:
--
--   { "type": "init", "session": "<uuid>" }
--     Sent once when the page loads.  The server replies with the dataframe's
--     metadata (column names, dtypes, total row count).
--
--   { "type": "fetch_rows", "session": "<uuid>", "offset": 0, "limit": 100 }
--     Sent whenever the user scrolls near unfetched rows.  The server
--     evaluates the appropriate DAP expression and replies with the row data.
--
-- Both handlers write their response directly to the `client` TCP handle
-- using ws.encode_json, which wraps the table in a WebSocket text frame.
--
-- ERROR HANDLING PHILOSOPHY
--   Errors that happen on the Neovim side (bad session UUID, DAP failure,
--   parse failure) are sent back to the browser as:
--     { "type": "error", "message": "..." }
--   This lets the UI show a meaningful message rather than silently hanging.

local ws = require("dataframe-preview.server.ws")
local session_store = require("dataframe-preview.server.session_store")
local log = require("dataframe-preview.utils.logging")

local M = {}

-- Helper: send a JSON error frame to the browser.
-- Used whenever something goes wrong so the UI can display it.
---@param client uv_tcp_t
---@param msg    string
local function send_error(client, msg)
  client:write(ws.encode_json({ type = "error", message = msg }))
end

-- ---------------------------------------------------------------------------
-- M.on_init(uuid, client)
--
-- Handles the first message from the browser after it connects.
-- By the time this runs the orchestrator has already:
--   1. Evaluated the metadata expression via DAP.
--   2. Stored the result in session_store under `uuid`.
-- So we just need to look it up and send it back.
-- ---------------------------------------------------------------------------
function M.on_init(uuid, client)
  -- Register the live WebSocket handle with the session so other parts of
  -- the code could push to this tab proactively if needed.
  session_store.attach_client(uuid, client)

  local session = session_store.get(uuid)
  if not session then
    -- This can happen if the user manually types a URL with a made-up UUID.
    send_error(client, "Unknown session: " .. uuid)
    return
  end

  if not session.metadata then
    -- Should not happen in normal flow (orchestrator always stores metadata
    -- before opening the browser), but guard defensively.
    send_error(client, "Metadata not yet available for session: " .. uuid)
    return
  end

  local meta = session.metadata

  -- Reply with everything the frontend needs to set up the table columns
  -- and know how many rows to expect.
  client:write(ws.encode_json({
    type = "meta",
    var_name = session.var_name,
    row_count = meta.row_count,
    col_count = meta.col_count,
    columns = meta.columns,
    dtypes = meta.dtypes,
  }))
end

-- ---------------------------------------------------------------------------
-- M.on_fetch_rows(uuid, offset, limit, client, dap_provider, lang_provider)
--
-- Fetches a chunk of rows from the debugged process via DAP and sends them
-- back over WebSocket.
--
-- This is called every time the user scrolls near the bottom of the loaded
-- data.  The virtual scroller in the browser sends:
--   { "type": "fetch_rows", "session": uuid, "offset": 100, "limit": 100 }
-- meaning "give me rows 100–199".
--
-- The sequence inside this function:
--   1. Ask the LanguageProvider to produce a read-only DAP expression that
--      evaluates to the requested rows as a JSON string.
--   2. Ask the DapProvider to evaluate that expression in the correct stack
--      frame (so variables are in scope).
--   3. Parse the result with the LanguageProvider.
--   4. Send the rows back to the browser.
--
-- Step 2 is asynchronous — the DAP evaluate call goes over a socket to the
-- debug adapter and the result arrives in a callback.  The rest of the steps
-- happen inside that callback.
-- ---------------------------------------------------------------------------
function M.on_fetch_rows(uuid, offset, limit, client, dap_provider)
  local session = session_store.get(uuid)
  if not session then
    send_error(client, "Unknown session: " .. uuid)
    return
  end

  local lang_provider = session.lang_provider

  -- Build the language-specific DAP evaluate expression, incorporating any
  -- active sort and filter from the session so the slice is consistent with
  -- the current view state.
  local expr =
    lang_provider:rows_expr(session.var_name, offset, limit, session.sort, session.filter, session.filter_logic)

  -- Evaluate the expression in the debugger.
  -- `session.frame_id` pins the evaluation to the exact stack frame that was
  -- active when :PreviewDataFrame was called, ensuring the variable is in scope.
  dap_provider:evaluate(expr, session.frame_id, function(err, result)
    if err then
      send_error(client, "Row fetch failed: " .. err)
      return
    end

    -- Parse the raw string returned by the DAP adapter into a Lua table.
    -- pcall catches any JSON decode or format errors without crashing.
    local ok, rows = pcall(lang_provider.parse_rows, lang_provider, result)
    if not ok then
      send_error(client, "Row parse failed: " .. tostring(rows))
      return
    end

    -- Send the rows to the browser.
    -- `offset` is included so the frontend knows where in the full dataset
    -- to place this chunk (it may have multiple requests in flight).
    client:write(ws.encode_json({
      type = "rows",
      offset = offset,
      data = rows,
    }))
  end)
end

-- ---------------------------------------------------------------------------
-- M.on_apply_sort_filter(uuid, sort, filter, filter_logic, client, dap_provider)
--
-- Handles a sort/filter change from the browser.  Updates the session's sort
-- and filter state, re-evaluates metadata (to get the filtered row count), and
-- sends an updated "meta" message back so the frontend can resize the scroller.
-- ---------------------------------------------------------------------------
function M.on_apply_sort_filter(uuid, sort, filter, filter_logic, client, dap_provider)
  local session = session_store.get(uuid)
  if not session then
    send_error(client, "Unknown session: " .. uuid)
    return
  end

  session.sort = sort
  session.filter = filter
  session.filter_logic = filter_logic or "AND"

  local lang_provider = session.lang_provider
  local meta_expr = lang_provider:metadata_expr(session.var_name, session.filter, session.filter_logic)

  dap_provider:evaluate(meta_expr, session.frame_id, function(err, result)
    if err then
      send_error(client, "apply_sort_filter evaluate failed: " .. err)
      return
    end

    local ok, metadata = pcall(lang_provider.parse_metadata, lang_provider, result)
    if not ok then
      send_error(client, "apply_sort_filter metadata parse failed")
      return
    end

    session.metadata = metadata

    client:write(ws.encode_json({
      type = "meta",
      var_name = session.var_name,
      row_count = metadata.row_count,
      col_count = metadata.col_count,
      columns = metadata.columns,
      dtypes = metadata.dtypes,
    }))
  end)
end

-- ---------------------------------------------------------------------------
-- M.dispatch(payload, client, dap_provider)
--
-- Entry point called by server.lua for every incoming WebSocket text frame.
-- Decodes the JSON payload and routes to the right handler.
-- ---------------------------------------------------------------------------
function M.dispatch(payload, client, dap_provider)
  -- Decode the JSON message.  pcall prevents a malformed JSON string from
  -- propagating an error up to the libuv callback and crashing the server.
  local ok, msg = pcall(vim.json.decode, payload)
  if not ok or type(msg) ~= "table" then
    send_error(client, "Invalid message format")
    return
  end

  local msg_type = msg.type

  if msg_type == "init" then
    M.on_init(msg.session, client)
  elseif msg_type == "fetch_rows" then
    M.on_fetch_rows(msg.session, msg.offset or 0, msg.limit or 100, client, dap_provider)
  elseif msg_type == "apply_sort_filter" then
    M.on_apply_sort_filter(
      msg.session,
      msg.sort or {},
      msg.filter or {},
      msg.filter_logic or "AND",
      client,
      dap_provider
    )
  else
    log.warn("handlers: unknown message type: " .. tostring(msg_type))
  end
end

return M
