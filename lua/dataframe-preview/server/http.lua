-- http.lua
--
-- A minimal HTTP/1.1 parser and response builder.
--
-- This module only handles what the server actually needs:
--   • Parse an incoming HTTP request (method, path, headers).
--   • Build an outgoing HTTP response (status line + headers + body).
--
-- We do NOT implement keep-alive, chunked encoding, request bodies, or any
-- other HTTP features that are not required by this use case.
--
-- HOW HTTP MESSAGES LOOK (simplified):
--
--   Request:
--     GET /?session=abc HTTP/1.1\r\n
--     Host: 127.0.0.1:54321\r\n
--     Upgrade: websocket\r\n
--     \r\n                          ← blank line marks end of headers
--
--   Response:
--     HTTP/1.1 200 OK\r\n
--     Content-Type: text/html\r\n
--     Content-Length: 1234\r\n
--     \r\n                          ← blank line marks end of headers
--     <html>...</html>              ← body

local M = {}

---@class HttpRequest
---@field method  string           -- e.g. "GET"
---@field path    string           -- e.g. "/?session=abc"
---@field headers table<string, string>  -- lowercase keys, e.g. headers["upgrade"]
---@field body    string           -- everything after the blank header line

-- ---------------------------------------------------------------------------
-- M.parse_request(raw)
--
-- Parses a raw HTTP request string and returns a structured HttpRequest.
-- Returns nil if the full header block has not arrived yet (no "\r\n\r\n").
-- This can happen because TCP is a stream — the OS may deliver the request
-- in multiple chunks.  The server calls parse_request again each time more
-- bytes arrive until it returns non-nil.
-- ---------------------------------------------------------------------------
function M.parse_request(raw)
  -- The blank line ("\r\n\r\n") separates headers from the body.
  -- If it hasn't arrived yet, the request is incomplete.
  local header_end = raw:find("\r\n\r\n", 1, true)
  if not header_end then
    return nil
  end

  -- Split the header section into individual lines.
  local header_block = raw:sub(1, header_end - 1)
  local lines = vim.split(header_block, "\r\n", { plain = true })

  -- The first line is the request line: "METHOD PATH HTTP/VERSION"
  local req_line = lines[1] or ""
  local method, path = req_line:match("^(%S+) (%S+)")
  if not method then
    return nil -- malformed request line
  end

  -- Parse the remaining lines as "Header-Name: value" pairs.
  -- We lowercase the header names so callers don't have to worry about
  -- case ("Upgrade" vs "upgrade" vs "UPGRADE" are all the same header).
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
    -- Everything after the blank line is the body (usually empty for GET).
    body = raw:sub(header_end + 4),
  }
end

-- ---------------------------------------------------------------------------
-- M.build_response(status, reason, headers, body)
--
-- Assembles a minimal HTTP/1.1 response string.
--
-- Example output:
--   "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\nbody text"
-- ---------------------------------------------------------------------------
function M.build_response(status, reason, headers, body)
  -- Start with the status line.
  local lines = { string.format("HTTP/1.1 %d %s", status, reason) }

  -- Add each header as "Name: value".
  for k, v in pairs(headers) do
    lines[#lines + 1] = string.format("%s: %s", k, v)
  end

  -- The blank line (empty entry) separates headers from body.
  lines[#lines + 1] = ""
  lines[#lines + 1] = body

  -- HTTP requires "\r\n" (CRLF) as the line separator.
  return table.concat(lines, "\r\n")
end

return M
