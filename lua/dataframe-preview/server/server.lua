-- server.lua
--
-- This module owns the lifecycle of the local TCP server that sits between
-- Neovim and the browser.  It does two things:
--
--   1. Serve the pre-built React UI (ui/dist/index.html) over plain HTTP so
--      the browser can load the page.
--
--   2. Upgrade those connections that ask for WebSocket, then hand each
--      upgraded connection off to handlers.lua for the actual data protocol.
--
-- WHY vim.uv (libuv)?
--   Neovim is single-threaded.  If we used a blocking network call the editor
--   would freeze every time a browser tab connected or scrolled.  vim.uv lets
--   us register callbacks that fire when network events happen; Neovim's own
--   event loop calls them between keystrokes, so the editor stays responsive.
--
-- SINGLE SERVER, MANY SESSIONS
--   The server starts once (lazily, on the first :PreviewDataFrame call) and
--   stays alive for the whole Neovim session.  Each preview tab gets a unique
--   UUID in the URL.  The WebSocket handler reads that UUID to know which
--   dataframe a given browser tab is asking about.

local bit = require("bit")
local bor = bit.bor -- LuaJIT bitwise OR (Neovim uses LuaJIT, not Lua 5.4)

local http = require("dataframe-preview.server.http")
local ws = require("dataframe-preview.server.ws")
local handlers = require("dataframe-preview.server.handlers")
local log = require("dataframe-preview.utils.logging")

-- Module state.  These are intentionally module-level (not inside a table
-- constructor) so that `ensure_started` can guard against double-starts.
local M = {
  _tcp = nil, ---@type uv_tcp_t|nil  the listening socket handle
  _port = nil, ---@type integer|nil   the OS-assigned port number
  _running = false, -- true once the server is listening
  _clients = {}, ---@type table<uv_tcp_t, boolean>  all active WebSocket connections
}

-- Labels for the two phases a connection can be in.
-- Every new TCP connection starts in HTTP mode.  If the browser sends an
-- "Upgrade: websocket" header we switch to WS mode and never go back.
local CONN_HTTP = "http"
local CONN_WS = "ws"

-- ---------------------------------------------------------------------------
-- handle_connection(client, dap_prov)
--
-- Called once for every browser connection that the listening socket accepts.
-- It wires up a read callback on the raw TCP `client` handle and maintains a
-- small state machine per connection:
--
--   CONN_HTTP → parse incoming bytes as HTTP
--             → if "Upgrade: websocket" header → CONN_WS (never returns to HTTP)
--             → otherwise → serve index.html and close
--
--   CONN_WS   → decode incoming bytes as WebSocket frames in a loop
--             → dispatch each complete frame to handlers.lua
--
-- WHY a loop inside the read callback?
--   TCP is a stream protocol.  The OS may coalesce or fragment packets however
--   it likes.  A single `read` callback invocation might deliver:
--     • a partial frame  → we must buffer and wait for the rest
--     • exactly one frame → handle it
--     • multiple frames   → handle all of them before returning
--   The `while true` loop + `ws.decode` returning nil-on-incomplete handles
--   all three cases correctly.
-- ---------------------------------------------------------------------------
local function handle_connection(client, dap_prov)
  -- `state` tracks which protocol phase this connection is in.
  local state = CONN_HTTP

  -- `buf` accumulates raw bytes from the TCP stream.
  -- We append every chunk to it and consume bytes as we parse complete
  -- messages.  This handles TCP fragmentation transparently.
  local buf = ""

  -- Register an async read callback.  libuv calls this whenever new bytes
  -- arrive on the socket.  `err` is set if the connection was reset; `chunk`
  -- is nil when the remote side closed normally.
  client:read_start(function(err, chunk)
    if err or not chunk then
      -- Connection closed or errored — release the OS handle and deregister.
      M._clients[client] = nil
      client:close()
      return
    end

    buf = buf .. chunk

    -- ── HTTP phase ──────────────────────────────────────────────────────────
    if state == CONN_HTTP then
      -- http.parse_request returns nil if we haven't received the full
      -- HTTP header block yet (i.e. no "\r\n\r\n" in the buffer).
      -- Returning here means libuv will call us again when more data arrives.
      local req = http.parse_request(buf)
      if not req then
        return
      end

      -- Check whether the browser is requesting a WebSocket upgrade.
      -- This is the standard HTTP/1.1 mechanism for bootstrapping WebSocket:
      -- the client sends a regular GET with extra headers, the server
      -- responds with "101 Switching Protocols", and from that point on the
      -- TCP stream speaks the WebSocket frame protocol instead of HTTP.
      local upgrade = req.headers["upgrade"] or ""
      if upgrade:lower() == "websocket" then
        -- ws.handshake builds the "101 Switching Protocols" response,
        -- including the cryptographic Sec-WebSocket-Accept header that
        -- proves to the browser we understood its request.
        local response = ws.handshake(req)
        client:write(response)

        -- Switch the connection into WebSocket mode and register the client
        -- in the global set so broadcast() can reach it.
        state = CONN_WS
        M._clients[client] = true

        -- Discard the HTTP bytes we already parsed; any remaining bytes in
        -- `buf` would be the start of WebSocket frame data (rare but possible
        -- if the client is very fast).
        buf = ""
        return
      end

      -- Not a WebSocket request — serve the React UI.
      --
      -- `debug.getinfo(1,"S").source` returns the path of THIS file prefixed
      -- with "@".  We strip the "@" with :sub(2) then walk four directories
      -- up (server/ → dataframe-preview/ → lua/ → plugin root) to find the
      -- pre-built index.html that Vite produced.
      local ui_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h:h") .. "/ui/dist/index.html"

      local f = io.open(ui_path, "rb")
      local body = f and f:read("*a") or "<h1>UI not built. Run: make build-ui</h1>"
      if f then
        f:close()
      end

      -- Send the HTML and immediately close the connection.
      -- We set Connection: close because this server does not implement
      -- HTTP keep-alive; every HTML request gets its own short-lived socket.
      local response = http.build_response(200, "OK", {
        ["Content-Type"] = "text/html; charset=utf-8",
        ["Content-Length"] = tostring(#body),
        ["Connection"] = "close",
      }, body)
      client:write(response)
      -- `shutdown` sends a TCP FIN (orderly close of the write side) before
      -- `close` frees the handle.  This lets the browser finish reading.
      client:shutdown()
      client:close()
      buf = ""
      return
    end

    -- ── WebSocket phase ─────────────────────────────────────────────────────
    if state == CONN_WS then
      -- Drain all complete frames out of the buffer.
      -- ws.decode returns nil if `buf` does not yet hold a full frame,
      -- which breaks the loop and waits for the next read callback.
      while true do
        local frame = ws.decode(buf)
        if not frame then
          break -- incomplete frame — wait for more TCP data
        end

        -- Advance the buffer past the bytes we just consumed.
        -- frame.consumed is the total byte length of the decoded frame
        -- (header + payload), so buf:sub(consumed+1) is everything after it.
        buf = buf:sub(frame.consumed + 1)

        -- Handle each WebSocket opcode:

        if frame.opcode == ws.OP_CLOSE then
          -- Browser is closing the tab or calling ws.close().
          -- RFC 6455 requires the server to echo a close frame before
          -- shutting down its side of the connection.
          M._clients[client] = nil
          client:write(ws.encode_json({ type = "close" }))
          client:close()
          return
        elseif frame.opcode == ws.OP_PING then
          -- Browsers occasionally send ping frames to check that the server
          -- is still alive (keepalive mechanism).  The spec requires us to
          -- reply with a pong containing the same payload bytes.
          --
          -- We build the pong frame manually here because it is tiny and
          -- does not need the full ws.encode path:
          --   byte 1: FIN=1 (0x80) | opcode PONG (0x0A) = 0x8A
          --   byte 2: payload length (no masking from server side)
          --   rest:   the echoed payload
          local pong = string.char(bor(0x80, ws.OP_PONG)) .. string.char(#frame.payload) .. frame.payload
          client:write(pong)
        elseif frame.opcode == ws.OP_TEXT then
          -- A text frame carries a JSON message from the browser
          -- (e.g. {"type":"fetch_rows", "session":"...", "offset":100}).
          --
          -- WHY vim.schedule here?
          --   We are inside a vim.uv read callback.  The libuv event loop
          --   dispatches this callback on Neovim's main thread, but calling
          --   Neovim APIs (like dap.session()) from within a raw libuv
          --   callback is not safe.  vim.schedule defers the call to the
          --   next safe point in Neovim's own event loop iteration, where
          --   all Neovim APIs are guaranteed to be accessible.
          vim.schedule(function()
            handlers.dispatch(frame.payload, client, dap_prov)
          end)
        end
        -- Binary frames (opcode 0x2) are not used by this protocol and are
        -- silently ignored.
      end
    end
  end)
end

-- ---------------------------------------------------------------------------
-- M.ensure_started(dap_prov, callback)
--
-- Idempotent server starter.  The first call binds a TCP socket, starts
-- listening, and invokes `callback(port)`.  Every subsequent call just
-- invokes `callback(port)` immediately with the already-running port.
--
-- Port selection: binding to port 0 tells the OS to assign any free
-- ephemeral port (typically in the range 49152–65535).  We query the
-- actual assigned port with getsockname() immediately after bind.
-- ---------------------------------------------------------------------------
function M.ensure_started(dap_prov, callback)
  if M._running then
    -- Server is already up — nothing to do.
    callback(M._port)
    return
  end

  -- Create a new TCP handle.  In libuv, handles are objects that wrap an
  -- OS file descriptor.  We need one for the listening socket.
  local tcp = vim.uv.new_tcp()

  -- Bind to loopback only (127.0.0.1) so the server is never reachable from
  -- outside the machine.  Port 0 lets the OS choose a free port.
  tcp:bind("127.0.0.1", 0)

  -- Start listening.  The number 128 is the backlog — the maximum number of
  -- pending connections the OS will queue before refusing new ones.  128 is
  -- more than enough for a single-user tool.
  --
  -- The callback fires whenever a new browser connection arrives.
  tcp:listen(128, function(err)
    if err then
      log.error("server: listen error: " .. err)
      return
    end

    -- We must create a *separate* handle for the accepted client.
    -- The listening `tcp` handle stays in "listen mode" permanently;
    -- `client` is the handle for this specific connection.
    local client = vim.uv.new_tcp()
    tcp:accept(client)

    -- Hand the client connection off to our HTTP/WS handler.
    handle_connection(client, dap_prov)
  end)

  -- Read back the port the OS actually assigned.
  -- We do this right after bind (before any connection arrives) because
  -- getsockname is synchronous and always available once the socket is bound.
  local addr = tcp:getsockname()
  M._tcp = tcp
  M._port = addr.port
  M._running = true

  log.debug("server: listening on 127.0.0.1:" .. M._port)

  -- Register a one-shot autocmd so we clean up the socket when Neovim exits.
  -- Without this the OS would reclaim the port anyway on process exit, but
  -- explicit cleanup is polite and avoids any "address in use" errors if
  -- something restarts quickly.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function()
      M.stop()
    end,
  })

  callback(M._port)
end

-- Broadcast a JSON-encodable table to all connected WebSocket clients.
-- Safe to call from any context: client:write() is a pure libuv operation.
-- pcall guards against a handle that was closed between the pairs() iteration
-- start and the write (possible if a close event fires on another coroutine).
function M.broadcast(tbl)
  local frame = ws.encode_json(tbl)
  for client in pairs(M._clients) do
    pcall(function()
      client:write(frame)
    end)
  end
end

-- Returns true if at least one browser tab has an active WebSocket connection.
function M.has_connected_clients()
  return next(M._clients) ~= nil
end

-- Closes the listening socket and resets module state.
-- Called automatically on VimLeavePre; can also be called manually.
function M.stop()
  if M._tcp then
    M._tcp:close()
    M._tcp = nil
  end
  M._clients = {}
  M._running = false
  M._port = nil
  log.debug("server: stopped")
end

return M
