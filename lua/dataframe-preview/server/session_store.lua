---@class Session
---@field var_name  string
---@field frame_id  integer
---@field metadata  Metadata|nil
---@field ws_client uv_tcp_t|nil

local M = {}

---@type table<string, Session>
local _store = {}

---@param uuid     string
---@param session  Session
function M.create(uuid, session)
  _store[uuid] = session
end

---@param uuid string
---@return Session|nil
function M.get(uuid)
  return _store[uuid]
end

---Attaches an active WebSocket TCP handle to the session.
---@param uuid      string
---@param ws_client uv_tcp_t
function M.attach_client(uuid, ws_client)
  if _store[uuid] then
    _store[uuid].ws_client = ws_client
  end
end

---@param uuid string
function M.remove(uuid)
  _store[uuid] = nil
end

function M.clear()
  _store = {}
end

return M
