-- session_store.lua
--
-- An in-memory registry that maps a UUID string to a Session object.
--
-- WHAT IS A SESSION?
--   Each call to :PreviewDataFrame creates one session.  A session records
--   everything the server needs to service a specific browser tab:
--     • var_name  — the name of the variable the user previewed ("df")
--     • frame_id  — the DAP stack-frame ID at the moment of the preview
--                   (identifies which scope to evaluate expressions in)
--     • metadata  — shape, column names, dtypes (fetched once at preview time)
--     • ws_client — the live TCP handle for the WebSocket once the browser
--                   connects (nil until the browser sends the "init" message)
--
-- WHY UUID KEYS?
--   The server handles multiple browser tabs simultaneously (one per
--   :PreviewDataFrame call).  The browser includes its UUID in every message
--   so the server can look up the right session data.  The UUID is also
--   embedded in the page URL:
--     http://127.0.0.1:{PORT}/?session={UUID}
--
-- LIFETIME
--   Sessions accumulate during a Neovim session — they are never evicted.
--   For a developer tool previewing a handful of dataframes at a time this
--   is fine.  The entire store is wiped when M.clear() is called (which
--   happens when the server shuts down on VimLeavePre).

---@class Session
---@field var_name     string           -- variable name under the cursor, e.g. "df"
---@field frame_id     integer          -- DAP stack frame ID (scope for evaluate)
---@field metadata     Metadata|nil     -- shape/column info; nil before first fetch
---@field ws_client    uv_tcp_t|nil     -- live WebSocket handle; nil before browser connects
---@field lang_provider LanguageProvider -- provider resolved at preview time

local M = {}

-- The actual store: a plain Lua table keyed by UUID string.
-- Module-level so it persists across multiple function calls.
---@type table<string, Session>
local _store = {}

-- Store a new session under the given UUID.
-- Called by orchestrator.lua immediately after metadata is fetched.
---@param uuid    string
---@param session Session
function M.create(uuid, session)
  _store[uuid] = session
end

-- Retrieve a session by UUID.  Returns nil if the UUID is unknown.
---@param uuid string
---@return Session|nil
function M.get(uuid)
  return _store[uuid]
end

-- Attach a live WebSocket TCP handle to an existing session.
-- Called by handlers.on_init once the browser sends its first message.
-- After this the server could push data to the tab at any time via
-- session.ws_client:write(...)
---@param uuid      string
---@param ws_client uv_tcp_t
function M.attach_client(uuid, ws_client)
  if _store[uuid] then
    _store[uuid].ws_client = ws_client
  end
end

-- Delete a session (e.g. when the browser tab closes).
---@param uuid string
function M.remove(uuid)
  _store[uuid] = nil
end

-- Wipe all sessions.  Used during testing (before_each) and on server stop.
function M.clear()
  _store = {}
end

return M
