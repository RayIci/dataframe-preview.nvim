local M = {}

---@class HttpRequest
---@field method  string
---@field path    string
---@field headers table<string, string>
---@field body    string

---Parses a raw HTTP request string.
---Returns nil if the request is incomplete.
---@param raw string
---@return HttpRequest|nil
function M.parse_request(raw)
  local header_end = raw:find("\r\n\r\n", 1, true)
  if not header_end then
    return nil
  end

  local header_block = raw:sub(1, header_end - 1)
  local lines = vim.split(header_block, "\r\n", { plain = true })

  local req_line = lines[1] or ""
  local method, path = req_line:match("^(%S+) (%S+)")
  if not method then
    return nil
  end

  local headers = {}
  for i = 2, #lines do
    local k, v = lines[i]:match("^([^:]+):%s*(.+)$")
    if k then
      headers[k:lower()] = v
    end
  end

  return {
    method = method,
    path = path,
    headers = headers,
    body = raw:sub(header_end + 4),
  }
end

---Builds a minimal HTTP response string.
---@param status  integer  e.g. 200
---@param reason  string   e.g. "OK"
---@param headers table<string, string>
---@param body    string
---@return string
function M.build_response(status, reason, headers, body)
  local lines = { string.format("HTTP/1.1 %d %s", status, reason) }
  for k, v in pairs(headers) do
    lines[#lines + 1] = string.format("%s: %s", k, v)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = body
  return table.concat(lines, "\r\n")
end

return M
