local http = require("dataframe-preview.server.http")
local ws = require("dataframe-preview.server.ws")
local handlers = require("dataframe-preview.server.handlers")
local log = require("dataframe-preview.utils.logging")

local M = {
  _tcp = nil, ---@type uv_tcp_t|nil
  _port = nil, ---@type integer|nil
  _running = false,
}

-- Per-connection state
local CONN_HTTP = "http"
local CONN_WS = "ws"

---Handles one accepted TCP connection.
---@param client    uv_tcp_t
---@param dap_prov  DapProvider
---@param lang_prov LanguageProvider
local function handle_connection(client, dap_prov, lang_prov)
  local state = CONN_HTTP
  local buf = ""

  client:read_start(function(err, chunk)
    if err or not chunk then
      client:close()
      return
    end

    buf = buf .. chunk

    if state == CONN_HTTP then
      local req = http.parse_request(buf)
      if not req then
        return
      end -- wait for more data

      -- WebSocket upgrade
      local upgrade = req.headers["upgrade"] or ""
      if upgrade:lower() == "websocket" then
        local response = ws.handshake(req)
        client:write(response)
        state = CONN_WS
        buf = "" -- discard HTTP bytes; remaining buf is WS data
        return
      end

      -- Serve the pre-built index.html for all other GET requests
      local ui_path = vim.fn.fnamemodify(
        debug.getinfo(1, "S").source:sub(2), -- this file's path
        ":h:h:h:h" -- four levels up: server/ → dataframe-preview/ → lua/ → plugin root
      ) .. "/ui/dist/index.html"

      local f = io.open(ui_path, "rb")
      local body = f and f:read("*a") or "<h1>UI not built. Run: make build-ui</h1>"
      if f then
        f:close()
      end

      local response = http.build_response(200, "OK", {
        ["Content-Type"] = "text/html; charset=utf-8",
        ["Content-Length"] = tostring(#body),
        ["Connection"] = "close",
      }, body)
      client:write(response)
      client:shutdown()
      client:close()
      buf = ""
      return
    end

    -- WebSocket frame processing
    if state == CONN_WS then
      while true do
        local frame = ws.decode(buf)
        if not frame then
          break
        end

        buf = buf:sub(frame.consumed + 1)

        if frame.opcode == ws.OP_CLOSE then
          client:write(ws.encode_json({ type = "close" }))
          client:close()
          return
        elseif frame.opcode == ws.OP_PING then
          -- Pong with same payload
          local pong = string.char(0x80 | ws.OP_PONG) .. string.char(#frame.payload) .. frame.payload
          client:write(pong)
        elseif frame.opcode == ws.OP_TEXT then
          vim.schedule(function()
            handlers.dispatch(frame.payload, client, dap_prov, lang_prov)
          end)
        end
      end
    end
  end)
end

---Starts the TCP server if not already running. Calls back with the port.
---@param dap_prov  DapProvider
---@param lang_prov LanguageProvider
---@param callback  fun(port: integer)
function M.ensure_started(dap_prov, lang_prov, callback)
  if M._running then
    callback(M._port)
    return
  end

  local tcp = vim.uv.new_tcp()
  -- Bind to loopback on a random OS-assigned port
  tcp:bind("127.0.0.1", 0)
  tcp:listen(128, function(err)
    if err then
      log.error("server: listen error: " .. err)
      return
    end

    local client = vim.uv.new_tcp()
    tcp:accept(client)
    handle_connection(client, dap_prov, lang_prov)
  end)

  local addr = tcp:getsockname()
  M._tcp = tcp
  M._port = addr.port
  M._running = true

  log.debug("server: listening on 127.0.0.1:" .. M._port)

  -- Shut down cleanly when Neovim exits
  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function()
      M.stop()
    end,
  })

  callback(M._port)
end

function M.stop()
  if M._tcp then
    M._tcp:close()
    M._tcp = nil
  end
  M._running = false
  M._port = nil
  log.debug("server: stopped")
end

return M
