-- ============================================================================
-- c4/tests/helpers.lua — test-only utilities. NOT shipped in the driver.
-- Pure-Lua SHA1/Base64 (to stand in for C4:Hash/C4:Base64Encode), a scripted
-- fake SignalR server transport, manual timers, and a tiny test runner.
-- Lua 5.1 safe.
-- ============================================================================

TestHelp = TestHelp or {}

-- --- Test-only SHA1 (RFC 3174), arithmetic-only. Verified against hashlib. ---
local function w32_add(a, b)
  return (a + b) % 4294967296
end

local function w32_xor2(a, b)
  local r, bit = 0, 1
  for _ = 1, 32 do
    if (a % 2) ~= (b % 2) then
      r = r + bit
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit = bit * 2
  end
  return r
end

local function w32_and2(a, b)
  local r, bit = 0, 1
  for _ = 1, 32 do
    if (a % 2) == 1 and (b % 2) == 1 then
      r = r + bit
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit = bit * 2
  end
  return r
end

local function w32_or2(a, b)
  local r, bit = 0, 1
  for _ = 1, 32 do
    if (a % 2) == 1 or (b % 2) == 1 then
      r = r + bit
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit = bit * 2
  end
  return r
end

local function w32_not(a)
  return 4294967295 - (a % 4294967296)
end

local function w32_rotl(x, n)
  x = x % 4294967296
  n = n % 32
  if n == 0 then
    return x
  end
  -- Split first so the multiply never exceeds 2^32 (double-exact).
  local low = x % (2 ^ (32 - n))
  return (low * (2 ^ n) + math.floor(x / (2 ^ (32 - n)))) % 4294967296
end

function TestHelp.sha1(message)
  local bytes = {}
  for i = 1, #message do
    bytes[i] = message:byte(i)
  end
  local bitlen = #message * 8
  bytes[#bytes + 1] = 128
  while (#bytes % 64) ~= 56 do
    bytes[#bytes + 1] = 0
  end
  for i = 7, 0, -1 do
    bytes[#bytes + 1] = math.floor(bitlen / (256 ^ i)) % 256
  end
  local h0, h1, h2, h3, h4 = 1732584193, 4023233417, 2562383102, 271733878, 3285377520
  local w = {}
  for block = 1, #bytes, 64 do
    for i = 0, 15 do
      local o = block + i * 4
      w[i] = bytes[o] * 16777216 + bytes[o + 1] * 65536 + bytes[o + 2] * 256 + bytes[o + 3]
    end
    for i = 16, 79 do
      w[i] = w32_rotl(w32_xor2(w32_xor2(w[i - 3], w[i - 8]), w32_xor2(w[i - 14], w[i - 16])), 1)
    end
    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f = w32_or2(w32_and2(b, c), w32_and2(w32_not(b), d))
        k = 1518500249
      elseif i < 40 then
        f = w32_xor2(w32_xor2(b, c), d)
        k = 1859775393
      elseif i < 60 then
        f = w32_or2(w32_or2(w32_and2(b, c), w32_and2(b, d)), w32_and2(c, d))
        k = 2400959708
      else
        f = w32_xor2(w32_xor2(b, c), d)
        k = 3395469782
      end
      local temp = w32_add(w32_add(w32_add(w32_add(w32_rotl(a, 5), f), e), k), w[i])
      e, d, c, b, a = d, c, w32_rotl(b, 30), a, temp
    end
    h0 = w32_add(h0, a)
    h1 = w32_add(h1, b)
    h2 = w32_add(h2, c)
    h3 = w32_add(h3, d)
    h4 = w32_add(h4, e)
  end
  local out = {}
  for _, h in ipairs({ h0, h1, h2, h3, h4 }) do
    out[#out + 1] =
      string.char(math.floor(h / 16777216) % 256, math.floor(h / 65536) % 256, math.floor(h / 256) % 256, h % 256)
  end
  return table.concat(out)
end

function TestHelp.sha1_hex(message)
  return (TestHelp.sha1(message):gsub(".", function(ch)
    return string.format("%02x", string.byte(ch))
  end))
end

-- --- Test-only Base64. ---
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function TestHelp.b64encode(data)
  local out = {}
  for i = 1, #data, 3 do
    local a = data:byte(i)
    local b = data:byte(i + 1) or 0
    local c = data:byte(i + 2) or 0
    local n = a * 65536 + b * 256 + c
    out[#out + 1] = B64_CHARS:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
    out[#out + 1] = B64_CHARS:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
    out[#out + 1] = (i + 1 <= #data) and B64_CHARS:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "="
    out[#out + 1] = (i + 2 <= #data) and B64_CHARS:sub(n % 64 + 1, n % 64 + 1) or "="
  end
  return table.concat(out)
end

function TestHelp.b64decode(data)
  local rev = {}
  for i = 1, #B64_CHARS do
    rev[B64_CHARS:sub(i, i)] = i - 1
  end
  local out = {}
  local clean = data:gsub("=", "")
  for i = 1, #clean, 4 do
    local n = 0
    local count = 0
    for j = 0, 3 do
      local ch = clean:sub(i + j, i + j)
      if ch ~= "" then
        n = n * 64 + (rev[ch] or 0)
        count = count + 1
      end
    end
    -- Left-align a short final group (missing sextets are zero).
    n = n * (64 ^ (4 - count))
    if count >= 2 then
      out[#out + 1] = string.char(math.floor(n / 65536) % 256)
    end
    if count >= 3 then
      out[#out + 1] = string.char(math.floor(n / 256) % 256)
    end
    if count >= 4 then
      out[#out + 1] = string.char(n % 256)
    end
  end
  return table.concat(out)
end

-- --- Manual timers: set_timeout returns cancel; fire_all(ms) runs due ones. --
function TestHelp.new_fake_timers()
  local timers = { _now = 0, _pending = {}, _seq = 0 }
  function timers.set_timeout(ms, fn)
    timers._seq = timers._seq + 1
    local entry = { at = timers._now + ms, fn = fn, id = timers._seq, cancelled = false }
    timers._pending[#timers._pending + 1] = entry
    return function()
      entry.cancelled = true
    end
  end
  function timers.advance(ms)
    timers._now = timers._now + (ms or 0)
    local again = true
    while again do
      again = false
      local best, best_i = nil, nil
      for i, entry in ipairs(timers._pending) do
        if not entry.cancelled and entry.at <= timers._now then
          if best == nil or entry.at < best.at then
            best, best_i = entry, i
          end
        end
      end
      if best ~= nil then
        table.remove(timers._pending, best_i)
        best.fn()
        again = true
      end
    end
  end
  function timers.pending_count()
    local n = 0
    for _, entry in ipairs(timers._pending) do
      if not entry.cancelled then
        n = n + 1
      end
    end
    return n
  end
  return timers
end

-- --- Scripted fake SignalR server over a fake TCP transport. ---
-- script: array of { expect_target=..., reply_target=..., reply_args={...} }
-- served in order; handshake bytes answered automatically.
function TestHelp.new_fake_server(script)
  local server = {
    _script = script or {},
    _step = 1,
    _sent_frames = {},
    _tcp_callbacks = nil,
    _tcp_closed = false,
    _http_calls = {},
    negotiate_token = "test-connection-token",
    negotiate_code = 200,
    valve_sent_delay = false, -- when true, swallow ValveSent fast path
    split_writes = false, -- when true, fragment every server frame byte-wise
  }

  local function server_frame(text)
    local len = #text
    if len < 126 then
      return string.char(129, len) .. text
    end
    return string.char(129, 126, math.floor(len / 256) % 256, len % 256) .. text
  end

  function server._emit(text)
    local bytes = server_frame(text)
    if server.split_writes then
      for i = 1, #bytes do
        server._tcp_callbacks.on_data(bytes:sub(i, i))
      end
    else
      server._tcp_callbacks.on_data(bytes)
    end
  end

  local function handle_record(raw)
    -- SignalR handshake request (no "type") gets the "{}" handshake reply.
    local ok, msg = pcall(JSON.decode, raw)
    if not ok or type(msg) ~= "table" then
      return
    end
    if msg.type ~= 1 then
      server._emit("{}" .. SignalR.RECORD_SEPARATOR)
      return
    end
    local step = server._script[server._step]
    server._step = server._step + 1
    assert(step ~= nil, "fake server got unexpected invoke: " .. tostring(msg.target))
    assert(
      step.expect_target == msg.target,
      "fake server expected " .. tostring(step.expect_target) .. " got " .. tostring(msg.target)
    )
    if step.capture ~= nil then
      step.capture(msg)
    end
    local replies = step.replies or { { target = step.reply_target, args = step.reply_args or {} } }
    for _, reply in ipairs(replies) do
      server._emit(JSON.encode({ type = 1, target = reply.target, arguments = reply.args }) .. SignalR.RECORD_SEPARATOR)
    end
  end

  local function handle_client_text(text)
    for raw in (text .. SignalR.RECORD_SEPARATOR):gmatch("(.-)" .. SignalR.RECORD_SEPARATOR) do
      if raw ~= "" then
        handle_record(raw)
      end
    end
  end

  -- Reuse the real client-frame parser to decode what the driver sends.
  local parser_holder = {}
  local function client_parser()
    if parser_holder.p == nil then
      parser_holder.p = WS.new_parser({
        expect_masked = true,
        on_message = function(payload)
          handle_client_text(payload)
        end,
        on_error = function(msg)
          error("fake server could not parse client frame: " .. tostring(msg))
        end,
      })
    end
    return parser_holder.p
  end

  function server.http_post(url, body, headers, cb)
    server._http_calls[#server._http_calls + 1] = { url = url, body = body, headers = headers }
    local payload = JSON.encode({ connectionToken = server.negotiate_token })
    cb(nil, payload, server.negotiate_code)
  end

  function server.tcp_open(host, port, callbacks)
    server._tcp_callbacks = callbacks
    server._host, server._port = host, port
    local handle = {}
    function handle.send(bytes)
      server._sent_frames[#server._sent_frames + 1] = bytes
      if bytes:sub(1, 3) == "GET" then
        -- Websocket handshake: answer 101 with the correct accept key.
        local key = bytes:match("Sec%-WebSocket%-Key:%s*([^\r\n]+)")
        assert(key ~= nil, "fake server: handshake missing key")
        key = key:gsub("%s+$", "")
        local accept = TestHelp.b64encode(TestHelp.sha1(key .. WS.GUID))
        local response = "HTTP/1.1 101 Switching Protocols\r\n"
          .. "Upgrade: websocket\r\n"
          .. "Connection: Upgrade\r\n"
          .. "Sec-WebSocket-Accept: "
          .. accept
          .. "\r\n\r\n"
        server._tcp_callbacks.on_data(response)
      else
        client_parser().feed(bytes)
      end
    end
    function handle.close()
      server._tcp_closed = true
    end
    -- Open asynchronously from the caller's view (direct call is fine).
    callbacks.on_open()
    return handle
  end

  return server
end

-- --- Tiny test runner. ---
TestHelp._tests = {}
TestHelp._failures = 0
TestHelp._passes = 0

function TestHelp.test(name, fn)
  TestHelp._tests[#TestHelp._tests + 1] = { name = name, fn = fn }
end

function TestHelp.check(cond, message)
  if not cond then
    error("check failed: " .. tostring(message), 2)
  end
end

function TestHelp.check_equal(actual, expected, message)
  if actual ~= expected then
    error(
      "check failed ("
        .. tostring(message)
        .. "): expected <"
        .. tostring(expected)
        .. "> got <"
        .. tostring(actual)
        .. ">",
      2
    )
  end
end

function TestHelp.run_all()
  for _, t in ipairs(TestHelp._tests) do
    local ok, err = pcall(t.fn)
    if ok then
      TestHelp._passes = TestHelp._passes + 1
      print("ok - " .. t.name)
    else
      TestHelp._failures = TestHelp._failures + 1
      print("FAIL - " .. t.name .. ": " .. tostring(err))
    end
  end
  print(string.format("passed=%d failed=%d", TestHelp._passes, TestHelp._failures))
  if TestHelp._failures > 0 then
    os.exit(1)
  end
end
