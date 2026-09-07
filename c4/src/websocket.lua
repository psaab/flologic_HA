-- ============================================================================
-- c4/src/websocket.lua — RFC 6455 client codec and handshake helpers.
--
-- Pure logic. Defines the global WS table only. No require, no return, no
-- top-level execution. Lua 5.1 safe (arithmetic-only bit handling).
--
-- Crypto and randomness are injected by the caller: on Control4 use
-- C4:Hash("SHA1", ...) and C4:Base64Encode; tests inject pure-Lua versions.
-- The actual socket belongs to the caller (a Director-managed TLS network
-- connection); this module only builds/parses bytes.
-- ============================================================================

WS = {}

WS.GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WS.OP_CONT = 0
WS.OP_TEXT = 1
WS.OP_BINARY = 2
WS.OP_CLOSE = 8
WS.OP_PING = 9
WS.OP_PONG = 10

local function bxor_byte(a, b)
  local result, bit = 0, 1
  for _ = 1, 8 do
    if (a % 2) ~= (b % 2) then
      result = result + bit
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit = bit * 2
  end
  return result
end

function WS.xor_mask(payload, mask)
  local out = {}
  for i = 1, #payload do
    out[i] = string.char(bxor_byte(payload:byte(i), mask[((i - 1) % 4) + 1]))
  end
  return table.concat(out)
end

-- Build the HTTP Upgrade request. key must be the Base64 of 16 random bytes.
function WS.build_handshake_request(host, path, key, extra_headers)
  local lines = {
    "GET " .. path .. " HTTP/1.1",
    "Host: " .. host,
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " .. key,
    "Sec-WebSocket-Version: 13",
  }
  if extra_headers ~= nil then
    for _, line in ipairs(extra_headers) do
      lines[#lines + 1] = line
    end
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n"
end

-- Expected Sec-WebSocket-Accept for a client key. sha1_fn(data) returns raw
-- bytes; b64_fn(data) returns Base64 text.
function WS.expected_accept(key, sha1_fn, b64_fn)
  return b64_fn(sha1_fn(key .. WS.GUID))
end

-- Parse a server handshake response. Returns accept_key, bytes_consumed on
-- success; nil, "need_more" when the headers are incomplete; nil, err otherwise.
function WS.parse_handshake_response(buffer)
  local cut = buffer:find("\r\n\r\n", 1, true)
  if (cut and cut > 16384) or (not cut and #buffer > 16384) then
    return nil, "websocket headers too large"
  end
  if cut == nil then
    return nil, "need_more"
  end
  local head = buffer:sub(1, cut - 1)
  local status = head:match("^HTTP/%S+%s+(%d+)")
  if status ~= "101" then
    return nil, "websocket upgrade rejected: " .. (status or "?")
  end
  -- Match the header name case-insensitively but keep the original value:
  -- Base64 is case-sensitive.
  local accept, upgrade, connection = nil, nil, nil
  for line in (head .. "\r\n"):gmatch("([^\r\n]*)\r\n") do
    local name, value = line:match("^([^:]+):%s*(.-)%s*$")
    if name ~= nil and name:lower() == "sec-websocket-accept" then
      accept = value
    elseif name ~= nil and name:lower() == "upgrade" then
      upgrade = value:lower()
    elseif name ~= nil and name:lower() == "connection" then
      connection = "," .. value:lower():gsub("%s", "") .. ","
    end
  end
  if upgrade ~= "websocket" or not connection or not connection:find(",upgrade,", 1, true) then
    return nil, "websocket upgrade headers invalid"
  end
  if accept == nil or accept == "" then
    return nil, "websocket upgrade missing Sec-WebSocket-Accept"
  end
  return accept, cut + 3
end

-- Build a single masked client frame (FIN set). mask is 4 byte numbers.
function WS.build_client_frame(payload, mask, opcode)
  opcode = opcode or WS.OP_TEXT
  local len = #payload
  local head
  if len < 126 then
    head = string.char(128 + opcode, 128 + len)
  elseif len < 65536 then
    head = string.char(128 + opcode, 128 + 126, math.floor(len / 256) % 256, len % 256)
  else
    local high = math.floor(len / 4294967296)
    local low = len % 4294967296
    head = string.char(
      128 + opcode,
      128 + 127,
      0,
      0,
      0,
      0,
      math.floor(low / 16777216) % 256,
      math.floor(low / 65536) % 256,
      math.floor(low / 256) % 256,
      low % 256
    )
    if high ~= 0 then
      error("websocket payload too large")
    end
  end
  return head .. string.char(mask[1], mask[2], mask[3], mask[4]) .. WS.xor_mask(payload, mask)
end

function WS.build_close_payload(code, reason)
  code = code or 1000
  return string.char(math.floor(code / 256) % 256, code % 256) .. (reason or "")
end

-- Incremental server-frame parser. Callbacks:
--   on_message(payload, is_binary)  -- reassembled text/binary message
--   on_ping(payload) -> true to auto-send pong via send_frame
--   on_pong(payload)
--   on_close(code, reason)
--   on_error(message)
--   send_frame(payload, opcode) -- masked client-frame sender; nil disables pong
function WS.new_parser(callbacks)
  callbacks = callbacks or {}
  local self = { _buffer = "", _frag_opcode = nil, _frag_parts = {} }

  local max_size = callbacks.max_message_size or 1048576
  function self.stop()
    self._stopped = true
    self._buffer, self._frag_parts, self._frag_size = "", {}, 0
  end
  local function fail(message)
    self.stop()
    if callbacks.on_error then
      callbacks.on_error(message)
    end
  end

  local function parse_one()
    local buf, blen = self._buffer, #self._buffer
    if blen < 2 then
      return nil -- need more
    end
    local b1, b2 = buf:byte(1), buf:byte(2)
    local fin = b1 >= 128
    local opcode = b1 % 16
    if b1 % 128 >= 16 then
      return nil, "websocket RSV bits set without negotiated extensions"
    end
    local masked = b2 >= 128
    if masked ~= (callbacks.expect_masked == true) then
      return nil, "incorrect websocket masking"
    end
    if opcode ~= 0 and opcode ~= 1 and opcode ~= 2 and opcode ~= 8 and opcode ~= 9 and opcode ~= 10 then
      return nil, "unknown websocket opcode"
    end
    local len = b2 % 128
    if opcode >= 8 and (not fin or len > 125 or (opcode == 8 and len == 1)) then
      return nil, "invalid websocket control frame"
    end
    local pos = 3
    if len == 126 then
      if blen < 4 then
        return nil
      end
      len = buf:byte(3) * 256 + buf:byte(4)
      pos = 5
    elseif len == 127 then
      if blen < 10 then
        return nil
      end
      local high = buf:byte(3) * 16777216 + buf:byte(4) * 65536 + buf:byte(5) * 256 + buf:byte(6)
      local low = buf:byte(7) * 16777216 + buf:byte(8) * 65536 + buf:byte(9) * 256 + buf:byte(10)
      if high ~= 0 then
        return nil, "websocket frame too large"
      end
      len = low
      pos = 11
    end
    if len > max_size then
      return nil, "websocket frame too large"
    end
    local mask = nil
    if masked then
      if blen < pos + 3 then
        return nil
      end
      mask = { buf:byte(pos, pos + 3) }
      pos = pos + 4
    end
    if blen < pos + len - 1 then
      return nil -- need more
    end
    local payload = buf:sub(pos, pos + len - 1)
    if mask ~= nil then
      payload = WS.xor_mask(payload, mask)
    end
    self._buffer = buf:sub(pos + len)
    return { fin = fin, opcode = opcode, payload = payload }
  end

  function self.feed(data)
    if self._stopped then
      return
    end
    self._buffer = self._buffer .. data
    if #self._buffer > max_size + 14 then
      fail("websocket buffer too large")
      return
    end
    while not self._stopped do
      local frame, err = parse_one()
      if err ~= nil then
        fail(err)
        return
      end
      if frame == nil then
        return -- need more data
      end
      local op, payload = frame.opcode, frame.payload
      if op == WS.OP_CONT then
        if self._frag_opcode == nil then
          fail("stray websocket continuation frame")
          return
        end
        self._frag_size = (self._frag_size or 0) + #payload
        if self._frag_size > max_size then
          fail("websocket message too large")
          return
        end
        self._frag_parts[#self._frag_parts + 1] = payload
        if frame.fin then
          local message = table.concat(self._frag_parts)
          local is_binary = self._frag_opcode == WS.OP_BINARY
          self._frag_opcode, self._frag_parts = nil, {}
          if callbacks.on_message ~= nil then
            callbacks.on_message(message, is_binary)
          end
        end
      elseif op == WS.OP_TEXT or op == WS.OP_BINARY then
        if self._frag_opcode ~= nil then
          fail("interleaved websocket data frame")
          return
        end
        if frame.fin then
          if callbacks.on_message ~= nil then
            callbacks.on_message(payload, op == WS.OP_BINARY)
          end
        else
          self._frag_opcode, self._frag_parts, self._frag_size = op, { payload }, #payload
        end
      elseif op == WS.OP_PING then
        local want_pong = true
        if callbacks.on_ping ~= nil then
          want_pong = callbacks.on_ping(payload)
        end
        if want_pong and callbacks.send_frame ~= nil then
          callbacks.send_frame(payload, WS.OP_PONG)
        end
      elseif op == WS.OP_PONG then
        if callbacks.on_pong ~= nil then
          callbacks.on_pong(payload)
        end
      elseif op == WS.OP_CLOSE then
        self.stop()
        local code, reason = 1005, ""
        if #payload >= 2 then
          code = payload:byte(1) * 256 + payload:byte(2)
          reason = payload:sub(3)
        end
        if callbacks.on_close ~= nil then
          callbacks.on_close(code, reason)
        end
        return
      else
        if callbacks.on_error ~= nil then
          callbacks.on_error("unknown websocket opcode " .. tostring(op))
        end
        return
      end
    end
  end

  return self
end
