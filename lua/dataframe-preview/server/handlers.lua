local ws = require("dataframe-preview.server.ws")
local session_store = require("dataframe-preview.server.session_store")
local log = require("dataframe-preview.utils.logging")

local M = {}

---Sends an error message over the WebSocket.
---@param client uv_tcp_t
---@param msg    string
local function send_error(client, msg)
  client:write(ws.encode_json({ type = "error", message = msg }))
end

---Handles the initial "init" message from the browser.
---Sends back the full metadata for the session.
---@param uuid      string
---@param client    uv_tcp_t
function M.on_init(uuid, client)
  session_store.attach_client(uuid, client)
  local session = session_store.get(uuid)
  if not session then
    send_error(client, "Unknown session: " .. uuid)
    return
  end
  if not session.metadata then
    send_error(client, "Metadata not yet available for session: " .. uuid)
    return
  end
  local meta = session.metadata
  client:write(ws.encode_json({
    type = "meta",
    var_name = session.var_name,
    row_count = meta.row_count,
    col_count = meta.col_count,
    columns = meta.columns,
    dtypes = meta.dtypes,
  }))
end

---Handles a "fetch_rows" request from the browser.
---Evaluates the rows expression via the DAP provider and sends back the chunk.
---@param uuid          string
---@param offset        integer
---@param limit         integer
---@param client        uv_tcp_t
---@param dap_provider  DapProvider
---@param lang_provider LanguageProvider
function M.on_fetch_rows(uuid, offset, limit, client, dap_provider, lang_provider)
  local session = session_store.get(uuid)
  if not session then
    send_error(client, "Unknown session: " .. uuid)
    return
  end

  local expr = lang_provider:rows_expr(session.var_name, offset, limit)

  dap_provider:evaluate(expr, session.frame_id, function(err, result)
    if err then
      send_error(client, "Row fetch failed: " .. err)
      return
    end

    local ok, rows = pcall(lang_provider.parse_rows, lang_provider, result)
    if not ok then
      send_error(client, "Row parse failed: " .. tostring(rows))
      return
    end

    client:write(ws.encode_json({
      type = "rows",
      offset = offset,
      data = rows,
    }))
  end)
end

---Dispatches a decoded WebSocket message to the appropriate handler.
---@param payload       string   raw JSON string
---@param client        uv_tcp_t
---@param dap_provider  DapProvider
---@param lang_provider LanguageProvider
function M.dispatch(payload, client, dap_provider, lang_provider)
  local ok, msg = pcall(vim.json.decode, payload)
  if not ok or type(msg) ~= "table" then
    send_error(client, "Invalid message format")
    return
  end

  local msg_type = msg.type
  if msg_type == "init" then
    M.on_init(msg.session, client)
  elseif msg_type == "fetch_rows" then
    M.on_fetch_rows(msg.session, msg.offset or 0, msg.limit or 100, client, dap_provider, lang_provider)
  else
    log.warn("handlers: unknown message type: " .. tostring(msg_type))
  end
end

return M
