-- ============================================================================
-- c4/tests/run.lua — standalone driver test suite (mocked C4/transports).
--
-- Run with real Lua 5.1:  lua5.1 c4/tests/loader_standalone.lua
-- Loaded by the pytest+lupa wrapper after the src modules. Assumes the
-- globals JSON, FloModel, SignalR, WS, FloLogic, TestHelp are present.
-- Lua 5.1 safe.
-- ============================================================================

local T = TestHelp

local function make_valve(overrides)
  local valve = {
    id = 11,
    uuid = "uuid-1",
    isZConnect = true,
    isZGateway = false,
    mode = 1,
    online = true,
    flowState = 1,
    deviceTypeName = "Connect",
    homeIntervalTime = 10,
    awayIntervalTime = 5,
    bypassTime = 30,
    preAlertNoticeInterval = 2,
  }
  if overrides ~= nil then
    for k, v in pairs(overrides) do
      valve[k] = v
    end
  end
  return valve
end

-- --- JSON ---

T.test("json: decode scalars and structures", function()
  T.check_equal(JSON.decode("true"), true, "true")
  T.check_equal(JSON.decode("false"), false, "false")
  T.check_equal(JSON.decode("null"), nil, "null")
  T.check_equal(JSON.decode("42"), 42, "int")
  T.check_equal(JSON.decode("-1.5e3"), -1500, "float")
  local t = JSON.decode('{"a":[1,"x",null],"b":{}}')
  T.check_equal(t.a[1], 1, "nested array")
  T.check_equal(t.a[2], "x", "nested string")
  T.check(t.a[3] == nil, "null element is nil")
  T.check_equal(#t.a, 2, "null truncates array")
end)

T.test("json: decode escapes and unicode", function()
  local t = JSON.decode('"A\\u00e9\\n\\t\\"\\\\\\/\\b\\f\\r"')
  T.check_equal(t, 'A\195\169\n\t"\\' .. "/" .. "\008\012\r", "escapes")
  -- Surrogate pair U+1D11E (musical G clef) -> 4-byte UTF-8.
  local g = JSON.decode('"\\ud834\\udd1e"')
  T.check_equal(#g, 4, "surrogate length")
  T.check_equal(string.byte(g, 1), 240, "surrogate byte 1")
end)

T.test("json: decode rejects malformed input", function()
  for _, bad in ipairs({ "", "{", '{"a":}', "[1,]", '{"a":1', '"abc', "tru", "01x", "1e", "[1 2]" }) do
    local ok = pcall(JSON.decode, bad)
    T.check(not ok, "rejects " .. bad)
  end
end)

T.test("json: encode values and roundtrip", function()
  T.check_equal(JSON.encode(nil), "null", "nil")
  T.check_equal(JSON.encode(true), "true", "bool")
  T.check_equal(JSON.encode(42), "42", "int")
  T.check_equal(JSON.encode(0.5), "0.5", "float")
  T.check_equal(JSON.encode({}), "[]", "empty table is array")
  T.check_equal(JSON.encode(JSON.null), "null", "null sentinel")
  T.check_equal(JSON.encode({ "a", JSON.null }), '["a",null]', "null in array")
  local obj = { mode = 8, name = 'Caf\195\169 "x"\n', on = true, list = { 1, 2 } }
  local back = JSON.decode(JSON.encode(obj))
  T.check_equal(back.mode, 8, "roundtrip number")
  T.check_equal(back.name, obj.name, "roundtrip string")
  T.check_equal(back.list[2], 2, "roundtrip array")
  local ok = pcall(JSON.encode, { [1] = "a", key = "b" })
  T.check(not ok, "mixed table rejected")
end)

-- --- Model ---

T.test("model: flag arithmetic and mode decode", function()
  T.check(FloModel.has_flag(33, 32), "33 has 32")
  T.check(not FloModel.has_flag(33, 64), "33 lacks 64")
  T.check(not FloModel.has_flag(nil, 1), "nil safe")
  T.check_equal(FloModel.mode_name({ mode = 1 }), "home", "exact")
  T.check_equal(FloModel.mode_name({ mode = 33 }), "shutoff", "flag fallback")
  T.check_equal(FloModel.mode_name({ mode = 6 }), "bypass", "away+bypass")
  T.check_equal(FloModel.mode_name({ mode = 130 }), "away", "away+auto_away")
  T.check_equal(FloModel.mode_name({ mode = 64 }), "shutoff", "external_leak")
  T.check(FloModel.mode_name({ mode = 128 }) == nil, "auto_away alone is nil")
  T.check(FloModel.mode_name({}) == nil, "missing mode is nil")
  T.check_equal(FloModel.mode_status_name({ mode = 33 }), "flow_time_exceeded", "status priority")
  T.check_equal(FloModel.mode_status_name({}), "unknown", "status unknown")
  T.check_equal(FloModel.mode_status_name({ mode = 2 ^ 30 }), "unknown_" .. tostring(2 ^ 30), "status unknown_N")
  local flags = FloModel.mode_flag_names({ mode = 33 })
  T.check_equal(#flags, 2, "two flags")
end)

T.test("model: flow state, countdowns, notifications", function()
  T.check(FloModel.is_water_flowing({ online = true, flowState = 4 }), "flowing")
  T.check(not FloModel.is_water_flowing({ online = true, flowState = 1 }), "idle")
  T.check(not FloModel.is_water_flowing({ online = false, flowState = 4 }), "offline")
  local now = os.time()
  local started = os.date("!%Y-%m-%dT%H:%M:%SZ", now - 60)
  local valve = make_valve({
    online = true,
    flowState = 4,
    mode = 1,
    lastNewFlow = started,
    preAlertNoticeInterval = 10,
  })
  local elapsed = FloModel.flow_elapsed_seconds(valve, now)
  T.check(elapsed ~= nil and elapsed >= 55 and elapsed <= 65, "elapsed ~60, got " .. tostring(elapsed))
  local countdown = FloModel.shutoff_countdown_seconds(valve, now)
  T.check(countdown ~= nil and countdown >= 530 and countdown <= 550, "countdown ~540")
  local access = { notificationsList = 64 }
  T.check(FloModel.advance_shutoff_warning(valve, access, now), "warning inside window")
  valve.preAlertNoticeInterval = 0
  T.check(not FloModel.advance_shutoff_warning(valve, access, now), "warning outside window")
  T.check(not FloModel.advance_shutoff_warning(valve, nil, now), "warning needs flag")
  T.check(FloModel.notification_flags(access).advance_shutoff, "flag decode")
  T.check(not FloModel.notification_flags(nil).always, "nil access safe")
  T.check(FloModel.shutoff_countdown_seconds(make_valve(), now) == nil, "idle countdown nil")
end)

T.test("model: valve discovery and lookup", function()
  local v1 = make_valve()
  local v2 = make_valve({ id = 22, uuid = "uuid-2" })
  local gw = make_valve({ id = 99, uuid = "gw", isZConnect = false, isZGateway = true })
  local both = FloModel.controllable_valves({ v1, gw, v2 })
  T.check_equal(#both, 2, "both valves, no gateway")
  T.check_equal(FloModel.choose_valve({ v1, gw, v2 }), v1, "primary prefers ZConnect")
  local any = make_valve({ id = 33, uuid = "u3", isZConnect = false, isAnyConnect = true })
  T.check_equal(FloModel.choose_valve({ any, v2 }), v2, "ZConnect beats AnyConnect")
  T.check(FloModel.choose_valve({}) == nil, "empty is nil")
  T.check_equal(FloModel.find_valve({ v1, v2 }, "22"), v2, "find by id")
  T.check_equal(FloModel.find_valve({ v1, v2 }, "UUID-2"), v2, "find case-insensitive")
  T.check(FloModel.find_valve({ v1 }, "nope") == nil, "find miss")
  T.check_equal(FloModel.unique_id_prefix(v1), "uuid-1", "prefix uuid")
  T.check_equal(FloModel.unique_id_prefix({ id = 7 }), "7", "prefix id fallback")
  T.check_equal(FloModel.mode_value("away"), 2, "mode value")
  T.check(not pcall(FloModel.mode_value, "bogus"), "mode value rejects")
end)

-- --- SignalR ---

T.test("signalr: invoke framing and dispatch across chunks", function()
  local built = SignalR.build_invoke("Login", { "a", 1 })
  T.check(built:sub(-1) == "\030", "record separator-terminated")
  local got = nil
  local d = SignalR.new_dispatcher()
  d.wait_for("LoggedIn", function(args)
    got = args
  end)
  -- Split mid-frame: nothing fires until the separator arrives.
  local half = math.floor(#built / 2)
  d.feed("{}" .. "\030" .. built:sub(1, half))
  T.check(got == nil, "no early fire")
  d.feed(built:sub(half + 1))
  T.check(got == nil, "invoke is not an event")
  d.feed('{"type":1,"target":"LoggedIn","arguments":[{"id":7}]}' .. "\030")
  T.check(got ~= nil and got[1].id == 7, "dispatched")
  T.check_equal(d.pending("LoggedIn"), 0, "one-shot consumed")
end)

T.test("signalr: cancel and fail_all", function()
  local d = SignalR.new_dispatcher()
  local fired = 0
  local cancel = d.wait_for("Ev", function()
    fired = fired + 1
  end)
  cancel()
  d.feed('{"type":1,"target":"Ev","arguments":[]}' .. "\030")
  T.check_equal(fired, 0, "cancelled waiter silent")
  local errs = 0
  d.wait_for("Ev", function(_args, err)
    if err ~= nil then
      errs = errs + 1
    end
  end)
  d.fail_all("boom")
  T.check_equal(errs, 1, "fail_all delivers")
  local bad = 0
  local d2 = SignalR.new_dispatcher({
    on_error = function()
      bad = bad + 1
    end,
  })
  d2.feed("not json" .. "\030")
  T.check_equal(bad, 1, "bad frame reported, stream survives")
end)

-- --- WebSocket ---

T.test("websocket: RFC 6455 handshake vector", function()
  local accept = WS.expected_accept("dGhlIHNhbXBsZSBub25jZQ==", TestHelp.sha1, TestHelp.b64encode)
  T.check_equal(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "RFC accept key")
  local req = WS.build_handshake_request("example.com:443", "/ws?id=1", "KEY==")
  T.check(req:find("GET /ws?id=1 HTTP/1.1\r\n", 1, true) == 1, "request line")
  T.check(req:find("Sec-WebSocket-Version: 13\r\n", 1, true) ~= nil, "version header")
  local good =
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSEC-WEBSOCKET-ACCEPT: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\nEXTRA"
  local key, consumed = WS.parse_handshake_response(good)
  T.check_equal(key, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "accept parsed, case preserved")
  T.check_equal(consumed, #good - 5, "consumed through blank line")
  local k2, why = WS.parse_handshake_response("HTTP/1.1 101 X\r\nSec")
  T.check(k2 == nil and why == "need_more", "incomplete waits")
  local k3, e3 = WS.parse_handshake_response("HTTP/1.1 400 Bad\r\n\r\n")
  T.check(k3 == nil and e3 ~= nil, "non-101 rejected")
end)

T.test("websocket: client frame sizes and masking", function()
  local mask = { 1, 2, 3, 4 }
  local tiny = WS.build_client_frame("Hi", mask)
  T.check_equal(tiny:byte(1), 128 + 1, "FIN+text")
  T.check_equal(tiny:byte(2), 128 + 2, "masked len 2")
  T.check_equal(WS.xor_mask(tiny:sub(7), mask), "Hi", "mask roundtrip")
  local mid = WS.build_client_frame(string.rep("a", 200), mask)
  T.check_equal(mid:byte(2), 128 + 126, "16-bit marker")
  T.check_equal(mid:byte(3) * 256 + mid:byte(4), 200, "16-bit length")
  local big = WS.build_client_frame(string.rep("b", 66000), mask)
  T.check_equal(big:byte(2), 128 + 127, "64-bit marker")
  T.check_equal(big:byte(7) * 16777216 + big:byte(8) * 65536 + big:byte(9) * 256 + big:byte(10), 66000, "64-bit length")
end)

T.test("websocket: parser handles fragments, ping, close, partial data", function()
  local messages, pongs, closes, errors = {}, {}, {}, {}
  local parser = WS.new_parser({
    on_message = function(payload, binary)
      messages[#messages + 1] = { payload, binary }
    end,
    send_frame = function(payload, opcode)
      pongs[#pongs + 1] = { payload, opcode }
    end,
    on_close = function(code, reason)
      closes[#closes + 1] = { code, reason }
    end,
    on_error = function(msg)
      errors[#errors + 1] = msg
    end,
  })
  -- Fragmented text "Hello" across two frames and three TCP chunks.
  parser.feed(string.char(1, 2) .. "He")
  parser.feed(string.char(128, 3))
  T.check_equal(#messages, 0, "no message before FIN")
  parser.feed("llo")
  T.check_equal(#messages, 1, "reassembled")
  T.check_equal(messages[1][1], "Hello", "fragment content")
  -- Ping -> auto pong; close -> callback with code.
  parser.feed(string.char(137, 4) .. "ping")
  T.check_equal(#pongs, 1, "pong sent")
  T.check_equal(pongs[1][2], WS.OP_PONG, "pong opcode")
  parser.feed(string.char(136, 2) .. string.char(3, 232))
  T.check_equal(closes[1][1], 1000, "close code")
  T.check_equal(#errors, 0, "no errors")
  -- Stray continuation is a protocol error, not a crash.
  parser.feed(string.char(128, 1) .. "x")
  T.check_equal(#errors, 0, "closed parser ignores trailing bytes")
end)

-- --- FloLogic session (scripted fake server) ---

local HUB_URL = "https://hub-cloudapps-prod.azurewebsites.net"

local function test_user()
  return { id = 7, relogToken = "relog-1" }
end

local function new_test_session(server, timers, overrides)
  local opts = {
    email = "u@example.com",
    password = "pw",
    device_name = "test",
    device_code = "code",
    device_token = "token",
    http_post = function(url, body, headers, cb)
      server.http_post(url, body, headers, cb)
    end,
    tcp_open = function(host, port, cbs)
      return server.tcp_open(host, port, cbs)
    end,
    set_timeout = function(ms, fn)
      return timers.set_timeout(ms, fn)
    end,
    client_key = function()
      return "dGhlIHNhbXBsZSBub25jZQ=="
    end,
    sha1 = TestHelp.sha1,
    b64encode = TestHelp.b64encode,
    random_mask = function()
      return { 9, 8, 7, 6 }
    end,
    log = function() end,
  }
  if overrides ~= nil then
    for k, v in pairs(overrides) do
      opts[k] = v
    end
  end
  return FloLogic.new_session(opts)
end

local function fetch_script(user, valves, access_rows, sched_rows, notif_rows)
  local script = {
    {
      expect_target = "Login",
      replies = {
        { target = "LoggedIn", args = { user } },
        { target = "ValveSent", args = { valves[1] } },
      },
    },
    { expect_target = "RefreshValveArray", reply_target = "ValveArraySent", reply_args = { valves } },
    {
      expect_target = "RequestUserAccesses",
      reply_target = "UserAccessesSent",
      reply_args = { access_rows },
    },
    {
      expect_target = "RequestSchedulerEvents",
      reply_target = "SchedulerEventsSent",
      reply_args = { sched_rows },
    },
    {
      expect_target = "RefreshValvesNotificationsHistory",
      reply_target = "NotificationsHistorySent",
      reply_args = { notif_rows },
    },
  }
  return script
end

T.test("session: full snapshot for the selected valve", function()
  local timers = TestHelp.new_fake_timers()
  local user = test_user()
  local v1 = make_valve()
  local v2 = make_valve({ id = 22, uuid = "uuid-2", mode = 2 })
  local access_rows = { { valveId = 22, notificationsList = 64 } }
  local sched_rows = { { action = "mode", actionPayload = { mode = 1 } } }
  local notif_rows = { { id = 5 } }
  local script = fetch_script(user, { v1, v2 }, access_rows, sched_rows, notif_rows)
  local server = TestHelp.new_fake_server(script)
  local session = new_test_session(server, timers)
  local err, snap = nil, nil
  session.fetch_snapshot(HUB_URL, "uuid-2", function(e, s)
    err, snap = e, s
  end)
  T.check(err == nil, "no error, got " .. tostring(err))
  T.check(snap ~= nil, "snapshot present")
  T.check_equal(snap.user.id, 7, "user")
  T.check_equal(#snap.devices, 2, "array devices after probe")
  T.check_equal(snap.valve.uuid, "uuid-2", "selected valve resolved")
  T.check_equal(snap.access.valveId, 22, "access row matched to selection")
  T.check_equal(#snap.scheduler, 1, "scheduler rows")
  T.check_equal(#snap.notifications, 1, "notification rows")
  T.check_equal(session.relog_token, "relog-1", "relog captured")
  T.check(server._tcp_closed, "connection closed after fetch")
  T.check_equal(timers.pending_count(), 0, "no timers leak")
  -- Negotiate went to /signalr/negotiate with device headers.
  T.check_equal(#server._http_calls, 1, "one negotiate call")
  local call = server._http_calls[1]
  T.check(call.url:find("/signalr/negotiate", 1, true) ~= nil, "negotiate path")
  T.check_equal(call.headers.userDeviceCode, "code", "device header")
  -- Websocket handshake carried the connection token.
  T.check(server._sent_frames[1]:find("id=test%-connection%-token", 1) ~= nil, "token in path")
end)

T.test("session: inventory arrives without a primary valve push", function()
  local timers = TestHelp.new_fake_timers()
  local user = test_user()
  local v1 = make_valve()
  local v2 = make_valve({ id = 22, uuid = "uuid-2" })
  local server = TestHelp.new_fake_server({
    { expect_target = "Login", replies = { { target = "LoggedIn", args = { user } } } },
    {
      expect_target = "RefreshValveArray",
      reply_target = "ValveArraySent",
      reply_args = { { v1, v2 } },
    },
    {
      expect_target = "RequestUserAccesses",
      reply_target = "UserAccessesSent",
      reply_args = { {} },
    },
    {
      expect_target = "RequestSchedulerEvents",
      reply_target = "SchedulerEventsSent",
      reply_args = { {} },
    },
    {
      expect_target = "RefreshValvesNotificationsHistory",
      reply_target = "NotificationsHistorySent",
      reply_args = { {} },
    },
  })
  local session = new_test_session(server, timers)
  local err, snap = nil, nil
  session.fetch_snapshot(HUB_URL, "uuid-2", function(e, s)
    err, snap = e, s
  end)
  T.check(snap ~= nil, "inventory does not depend on a primary push")
  T.check(err == nil, "no error, got " .. tostring(err))
  T.check_equal(#snap.devices, 2, "array devices")
  T.check_equal(snap.valve.uuid, "uuid-2", "selected valve resolved")
  -- Empty per-valve history stays empty: no account-wide retry, so another
  -- site's notifications can never leak in.
  T.check_equal(#snap.notifications, 0, "empty history stays empty")
end)

T.test("session: sends commands with the cloud envelope", function()
  local timers = TestHelp.new_fake_timers()
  local user = test_user()
  local v1 = make_valve()
  local seen = nil
  local server = TestHelp.new_fake_server({
    {
      expect_target = "Login",
      replies = {
        { target = "LoggedIn", args = { user } },
        { target = "ValveSent", args = { v1 } },
      },
    },
    { expect_target = "RefreshValveArray", reply_target = "ValveArraySent", reply_args = { { v1 } } },
    {
      expect_target = "RequestStateChange",
      capture = function(msg)
        seen = msg
      end,
      reply_target = "StateChangeResult",
      reply_args = { { ok = true } },
    },
  })
  local session = new_test_session(server, timers)
  local err, res = nil, nil
  session.send_command(HUB_URL, "uuid-1", { mode = 8 }, function(e, r)
    err, res = e, r
  end)
  T.check(err == nil, "no error, got " .. tostring(err))
  T.check(res ~= nil and res.valve.uuid == "uuid-1", "primary valve commanded")
  T.check(seen ~= nil, "command captured")
  local cmd = seen.arguments[3]
  T.check_equal(cmd.active, true, "active flag")
  T.check_equal(cmd.userId, 7, "user id")
  T.check_equal(cmd.valveId, 11, "valve id")
  T.check_equal(cmd.mode, 8, "mode field")
  T.check(cmd.created:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil, "created stamp")
  T.check(server._tcp_closed, "connection closed after command")
end)

T.test("session: auth, timeout, and missing-valve errors", function()
  local timers = TestHelp.new_fake_timers()
  local user = test_user()
  -- 401 on negotiate.
  local denied = TestHelp.new_fake_server({})
  denied.negotiate_code = 401
  local err1 = nil
  new_test_session(denied, timers).fetch_snapshot(HUB_URL, nil, function(e)
    err1 = e
  end)
  T.check_equal(err1, "auth", "401 is auth")
  -- Unknown selection: probed array still lacks it.
  local v1 = make_valve()
  local server = TestHelp.new_fake_server({
    {
      expect_target = "Login",
      replies = {
        { target = "LoggedIn", args = { user } },
        { target = "ValveSent", args = { v1 } },
      },
    },
    {
      expect_target = "RefreshValveArray",
      reply_target = "ValveArraySent",
      reply_args = { { v1 } },
    },
  })
  local err2 = nil
  new_test_session(server, timers).fetch_snapshot(HUB_URL, "nope", function(e)
    err2 = e
  end)
  T.check_equal(err2, "valve-not-found", "unknown selection")
  -- Metadata timeouts degrade like the Home Assistant client: access
  -- degrades to nil instead of failing the snapshot.
  local hanging = TestHelp.new_fake_server({
    {
      expect_target = "Login",
      replies = {
        { target = "LoggedIn", args = { user } },
        { target = "ValveSent", args = { v1 } },
      },
    },
    { expect_target = "RefreshValveArray", reply_target = "ValveArraySent", reply_args = { { v1 } } },
    { expect_target = "RequestUserAccesses" }, -- never replies
    { expect_target = "RequestSchedulerEvents" }, -- never replies
    { expect_target = "RefreshValvesNotificationsHistory" }, -- never replies
  })
  local err3, snap3 = nil, nil
  new_test_session(hanging, timers).fetch_snapshot(HUB_URL, "uuid-1", function(e, s)
    err3, snap3 = e, s
  end)
  T.check(err3 == nil, "waits for the timeout")
  timers.advance(30000)
  T.check(err3 == nil, "access timeout degrades instead of failing")
  timers.advance(30000)
  T.check(err3 == nil, "scheduler timeout degrades instead of failing")
  timers.advance(30000)
  T.check(err3 == nil, "snapshot completes, got " .. tostring(err3))
  T.check(snap3 ~= nil and snap3.access == nil, "access degrades to nil")
  T.check(snap3 ~= nil and #snap3.scheduler == 0, "scheduler degrades to empty")
  T.check(hanging._tcp_closed, "closed after completion")
  T.check_equal(timers.pending_count(), 0, "no timers leak")
end)

T.test("session: hub URL parsing", function()
  local hub = FloLogic.parse_hub_url("https://example.com")
  T.check_equal(hub.host, "example.com", "host")
  T.check_equal(hub.port, 443, "default port")
  T.check_equal(hub.path, "/signalr", "signalr appended")
  local custom = FloLogic.parse_hub_url("https://example.com:8443/base/signalr/")
  T.check_equal(custom.port, 8443, "custom port")
  T.check_equal(custom.path, "/base/signalr", "existing path kept")
  T.check(FloLogic.parse_hub_url("not a url") == nil, "bad URL rejected")
end)

T.test("session: deadline cancels stalled HTTP and ignores late completion", function()
  local timers = TestHelp.new_fake_timers()
  local callback, cancelled, completions, result = nil, false, 0, nil
  local session = new_test_session({}, timers, {
    http_post = function(_, _, _, cb)
      callback = cb
      return function()
        cancelled = true
      end
    end,
  })
  session.fetch_snapshot(HUB_URL, "11", function(err)
    result, completions = err, completions + 1
  end)
  timers.advance(180000)
  T.check_equal(result, "timeout:session", "whole-session deadline")
  T.check(cancelled, "HTTP cancelled")
  callback(nil, '{"connectionToken":"late"}', 200)
  T.check_equal(completions, 1, "completion occurs once")
  T.check_equal(timers.pending_count(), 0, "deadline cleanup")
end)

T.test("session: websocket waits for SignalR acknowledgement", function()
  local timers = TestHelp.new_fake_timers()
  local writes, callbacks, result, closed = {}, nil, nil, false
  local session = new_test_session(TestHelp.new_fake_server({}), timers, {
    tcp_open = function(_, _, cb)
      callbacks = cb
      cb.on_open()
      return {
        send = function(bytes)
          writes[#writes + 1] = bytes
        end,
        close = function()
          closed = true
        end,
      }
    end,
  })
  session.fetch_snapshot(HUB_URL, "11", function(err)
    result = err
  end)
  local accept = WS.expected_accept("dGhlIHNhbXBsZSBub25jZQ==", TestHelp.sha1, TestHelp.b64encode)
  callbacks.on_data(
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
      .. accept
      .. "\r\n\r\n"
  )
  T.check_equal(#writes, 2, "only upgrade and SignalR handshake sent")
  timers.advance(30000)
  T.check_equal(result, "timeout:upgrade", "missing acknowledgement times out")
  T.check(closed, "stalled socket closed")
end)

T.test("session: discovery honors full inventory despite an early primary push", function()
  local timers = TestHelp.new_fake_timers()
  local server = TestHelp.new_fake_server({
    {
      expect_target = "Login",
      replies = {
        { target = "ValveSent", args = { make_valve() } },
        { target = "LoggedIn", args = { test_user() } },
      },
    },
    { expect_target = "RefreshValveArray", reply_target = "ValveArraySent", reply_args = { {} } },
  })
  local snapshot
  new_test_session(server, timers).fetch_snapshot(HUB_URL, "", function(err, snap)
    T.check(err == nil, "discovery succeeded")
    snapshot = snap
  end)
  T.check(snapshot ~= nil and #snapshot.devices == 0, "primary push cannot resurrect removed valve")
  T.check_equal(timers.pending_count(), 0, "cleanup")
end)

T.test("session: pushed valves merge into a live inventory", function()
  local timers = TestHelp.new_fake_timers()
  local v2 = make_valve({ id = 22, uuid = "uuid-2", mode = 2 })
  local updated = make_valve({ mode = 8 })
  -- Split declaration: captures inside the initializer must see this local.
  local server
  server = TestHelp.new_fake_server({
    { expect_target = "Login", reply_target = "LoggedIn", reply_args = { test_user() } },
    { expect_target = "RefreshValveArray", reply_target = "ValveArraySent", reply_args = { { make_valve() } } },
    {
      expect_target = "RequestUserAccesses",
      reply_target = "UserAccessesSent",
      reply_args = { {} },
      capture = function()
        -- A replacement and a brand-new valve arrive mid-fetch.
        server._emit(
          JSON.encode({ type = 1, target = "ValveSent", arguments = { updated } }) .. SignalR.RECORD_SEPARATOR
        )
        server._emit(JSON.encode({ type = 1, target = "ValveSent", arguments = { v2 } }) .. SignalR.RECORD_SEPARATOR)
      end,
    },
    { expect_target = "RequestSchedulerEvents", reply_target = "SchedulerEventsSent", reply_args = { {} } },
    {
      expect_target = "RefreshValvesNotificationsHistory",
      reply_target = "NotificationsHistorySent",
      reply_args = { {} },
    },
  })
  local err, snap = nil, nil
  new_test_session(server, timers).fetch_snapshot(HUB_URL, "11", function(e, s)
    err, snap = e, s
  end)
  T.check(err == nil, "no error, got " .. tostring(err))
  T.check_equal(#snap.devices, 2, "pushed valve joins the inventory")
  T.check_equal(snap.valve.mode, 8, "matching push replaces the cached valve")
  T.check_equal(FloModel.find_valve(snap.devices, 22).uuid, "uuid-2", "new push is selectable")
  T.check_equal(timers.pending_count(), 0, "cleanup")
end)

T.test("session: cloud error notices and malformed frames do not abort a fetch", function()
  local timers = TestHelp.new_fake_timers()
  -- Split declaration: captures inside the initializer must see this local.
  local server
  server = TestHelp.new_fake_server({
    {
      expect_target = "Login",
      replies = {
        { target = "LoggedIn", args = { test_user() } },
        { target = "ErrorOccured", args = { { message = "spurious" } } },
      },
    },
    {
      expect_target = "RefreshValveArray",
      reply_target = "ValveArraySent",
      reply_args = { { make_valve() } },
      capture = function()
        server._emit("not json at all" .. SignalR.RECORD_SEPARATOR)
        server._emit('{"type":1,"target":12345}' .. SignalR.RECORD_SEPARATOR)
        server._tcp_callbacks.on_data(string.char(130, 4) .. "junk")
      end,
    },
    { expect_target = "RequestUserAccesses", reply_target = "UserAccessesSent", reply_args = { {} } },
    { expect_target = "RequestSchedulerEvents", reply_target = "SchedulerEventsSent", reply_args = { {} } },
    {
      expect_target = "RefreshValvesNotificationsHistory",
      reply_target = "NotificationsHistorySent",
      reply_args = { {} },
    },
  })
  local err, snap = nil, nil
  new_test_session(server, timers).fetch_snapshot(HUB_URL, "11", function(e, s)
    err, snap = e, s
  end)
  T.check(err == nil, "fetch survives, got " .. tostring(err))
  T.check(snap ~= nil and snap.valve.id == 11, "snapshot completes")
  T.check_equal(timers.pending_count(), 0, "cleanup")
end)

T.test("session: explicit command selection and negative acknowledgement", function()
  local timers = TestHelp.new_fake_timers()
  local untouched = TestHelp.new_fake_server({})
  local rejected
  new_test_session(untouched, timers).send_command(HUB_URL, "", { mode = 8 }, function(err)
    rejected = err
  end)
  T.check_equal(rejected, "select-valve", "blank target rejected")
  T.check_equal(#untouched._http_calls, 0, "no cloud request")
  local server = TestHelp.new_fake_server({
    { expect_target = "Login", reply_target = "LoggedIn", reply_args = { test_user() } },
    { expect_target = "RefreshValveArray", reply_target = "ValveArraySent", reply_args = { { make_valve() } } },
    { expect_target = "RequestStateChange", reply_target = "StateChangeResult", reply_args = { false } },
  })
  new_test_session(server, timers).send_command(HUB_URL, "11", { mode = 8 }, function(err)
    rejected = err
  end)
  T.check_equal(rejected, "command-rejected", "negative cloud result surfaced")
end)

T.test("session: invalid inventory fails instead of choosing a gateway", function()
  for _, inventory in ipairs({
    false,
    { { id = 11 }, { id = 11 } },
    { { name = "missing identity" } },
    { { id = 11, isZGateway = true } },
  }) do
    local timers = TestHelp.new_fake_timers()
    local server = TestHelp.new_fake_server({
      { expect_target = "Login", reply_target = "LoggedIn", reply_args = { test_user() } },
      { expect_target = "RefreshValveArray", reply_target = "ValveArraySent", reply_args = { inventory } },
    })
    local result
    new_test_session(server, timers).send_command(HUB_URL, "11", { mode = 8 }, function(err)
      result = err
    end)
    T.check(result ~= nil, "invalid inventory/target rejected")
    T.check(server._tcp_closed, "socket closed")
  end
end)

T.test("websocket: bounded input and protocol errors retire parser", function()
  local errors, messages = 0, 0
  local parser = WS.new_parser({
    max_message_size = 16,
    on_error = function()
      errors = errors + 1
    end,
    on_message = function()
      messages = messages + 1
    end,
  })
  parser.feed(string.char(129, 126, 0, 17))
  parser.feed(string.char(129, 1) .. "x")
  T.check_equal(errors, 1, "size limit fails once")
  T.check_equal(messages, 0, "retired parser delivers no messages")
  local key, err = WS.parse_handshake_response(string.rep("x", 16385))
  T.check(key == nil and err ~= "need_more", "header bound")
end)

T.test("model: UTC parsing handles offsets and calendar boundaries", function()
  T.check_equal(FloModel.parse_datetime_utc("1970-01-01T00:00:00Z"), 0, "epoch")
  T.check_equal(FloModel.parse_datetime_utc("1970-01-01T01:30:00+01:30"), 0, "positive offset")
  T.check_equal(FloModel.parse_datetime_utc("1969-12-31T19:00:00-05:00"), 0, "negative offset")
  T.check_equal(FloModel.parse_datetime_utc("2000-02-29T00:00:00.123Z"), 951782400, "leap day")
  T.check(FloModel.parse_datetime_utc("1900-02-29T00:00:00Z") == nil, "invalid leap day")
  T.check(FloModel.parse_datetime_utc("2026-09-07T24:00:00Z") == nil, "invalid hour")
end)

T.test("session: live inventory removal cannot return a stale selected valve", function()
  local timers = TestHelp.new_fake_timers()
  local script = fetch_script(test_user(), { make_valve() }, {}, {}, {})
  script[3].replies = {
    { target = "ValveArraySent", args = { {} } },
    { target = "UserAccessesSent", args = { {} } },
  }
  local result, snapshot
  new_test_session(TestHelp.new_fake_server(script), timers).fetch_snapshot(HUB_URL, "11", function(err, snap)
    result, snapshot = err, snap
  end)
  T.check_equal(result, "valve-not-found", "live removal invalidates snapshot")
  T.check(snapshot == nil, "old valve cannot be resurrected")
end)

T.test("session: invalid URLs and transport exceptions fail cleanly", function()
  for _, url in ipairs({
    "http://example.com",
    "https://example.com:70000",
    "https://user@example.com",
    "https://example.com?q=1",
  }) do
    T.check(FloLogic.parse_hub_url(url) == nil, "unsupported URL rejected")
  end
  local timers = TestHelp.new_fake_timers()
  local result
  new_test_session({}, timers, {
    http_post = function()
      error("private transport details")
    end,
  }).fetch_snapshot(HUB_URL, "11", function(err)
    result = err
  end)
  T.check_equal(result, "http:adapter-error", "adapter exception sanitized")
  T.check_equal(timers.pending_count(), 0, "exception cancels watchdog")
end)

T.test("session: websocket upgrade carries the same identity as negotiation", function()
  local server = TestHelp.new_fake_server({
    { expect_target = "Login", reply_target = "LoggedIn", reply_args = { test_user() } },
    { expect_target = "RefreshValveArray", reply_target = "ValveArraySent", reply_args = { {} } },
  })
  local result
  new_test_session(server, TestHelp.new_fake_timers(), { relog_token = "saved-session-token" }).fetch_snapshot(
    HUB_URL,
    "",
    function(err, snapshot)
      T.check(err == nil, "discovery succeeds")
      result = snapshot
    end
  )
  T.check(result ~= nil, "session completed")
  local request = server._sent_frames[1]
  local headers = {}
  for name, value in request:gmatch("\r\n([^:\r\n]+): ([^\r\n]*)") do
    headers[name] = value
  end
  local expected = {
    userDeviceCode = "code",
    userDeviceToken = "token",
    relogToken = "saved-session-token",
    OsPlatform = "Android",
    AppVer = "control4",
    DeviceName = "test",
  }
  for name, value in pairs(expected) do
    T.check_equal(server._http_calls[1].headers[name], value, "negotiate " .. name)
    T.check_equal(headers[name], value, "websocket " .. name)
  end
end)

T.test("updates: select only stable C4 releases with the expected package", function()
  local function release(version)
    local tag = "c4-v" .. version
    return {
      tag_name = tag,
      assets = {
        {
          name = "flologic_valve.c4z",
          browser_download_url = "https://github.com/psaab/flologic_HA/releases/download/"
            .. tag
            .. "/flologic_valve.c4z",
        },
      },
    }
  end
  local older, newer = release("2026090701"), release("2026090703")
  local draft, prerelease, wrong_asset = release("2026090799"), release("2026090798"), release("2026090797")
  draft.draft, prerelease.prerelease = true, true
  wrong_asset.assets[1].browser_download_url = "https://example.invalid/driver.c4z"
  local best =
    FloUpdate.select_release({ newer, { tag_name = "v0.2.2", assets = {} }, draft, older, prerelease, wrong_asset })
  T.check_equal(best.version, "2026090703", "choose newest eligible C4 release")
  T.check(FloUpdate.select_release({ { tag_name = "v0.2.2", assets = {} } }) == nil, "HA release ignored")
end)

T.test("updates: watchdog cancels HTTP and suppresses late results", function()
  local timers = TestHelp.new_fake_timers()
  local callback, cancelled, result, count
  count = 0
  local check = FloUpdate.new_check({
    set_timeout = timers.set_timeout,
    http_get = function(_, _, cb)
      callback = cb
      return function()
        cancelled = true
      end
    end,
    on_result = function(err)
      result, count = err, count + 1
    end,
  })
  check.start()
  timers.advance(35000)
  T.check(cancelled and result ~= nil, "timeout cancels and reports")
  callback(nil, "[]", 200)
  T.check_equal(count, 1, "late result ignored")
end)

T.test("updates: version compare and install packet bytes", function()
  T.check_equal(FloUpdate.compare_versions("2026090705", "2026090705"), 0, "equal")
  T.check_equal(FloUpdate.compare_versions("2026090704", "2026090705"), -1, "older")
  T.check_equal(FloUpdate.compare_versions("2026090706", "2026090705"), 1, "newer")
  T.check_equal(FloUpdate.compare_versions("999", "1000"), -1, "width-insensitive")
  T.check_equal(
    FloUpdate.build_install_packet("flologic_valve.c4z"),
    '<c4soap async="0" category="composer" name="UpdateProjectC4i"'
      .. ' operation="RWX" session="0"><param name="name" type="string">flologic_valve.c4z</param></c4soap>\000',
    "exact soap packet"
  )
  T.check(
    FloUpdate.build_install_packet('a&<b>"c"'):find("a&amp;&lt;b&gt;&quot;c&quot;", 1, true) ~= nil,
    "filename escaped"
  )
end)

local function install_fixtures(version)
  local tag = "c4-v" .. version
  local releases = {
    {
      tag_name = tag,
      draft = false,
      prerelease = false,
      assets = {
        {
          name = "flologic_valve.c4z",
          browser_download_url = "https://github.com/psaab/flologic_HA/releases/download/"
            .. tag
            .. "/flologic_valve.c4z",
        },
      },
    },
  }
  local files = { ["flologic_valve.c4z"] = "OLD-DRIVER-BYTES" }
  local store = {
    files = files,
    set_dir_calls = {},
    soap_packets = {},
    denied = false,
    soap_err = nil,
    corrupt_write = false,
  }
  local fakes = {
    get_installed = function()
      return true
    end,
    file_set_dir = function(alias)
      store.set_dir_calls[#store.set_dir_calls + 1] = alias
      return not store.denied
    end,
    file_exists = function(name)
      return files[name] ~= nil
    end,
    file_delete = function(name)
      files[name] = nil
    end,
    file_write = function(name, data)
      files[name] = store.corrupt_write and data:sub(1, #data - 1) or data
    end,
    file_size = function(name)
      return files[name] and #files[name] or nil
    end,
    soap_send = function(packet, cb)
      store.soap_packets[#store.soap_packets + 1] = packet
      cb(store.soap_err)
      return function() end
    end,
  }
  return releases, store, fakes
end

local function install_http(releases_body, asset_body, seen)
  return function(url, _, cb)
    seen[#seen + 1] = url
    if url:find("api.github.com", 1, true) then
      cb(nil, releases_body, 200, nil)
    else
      cb(nil, asset_body, 200, nil)
    end
    return function() end
  end
end

T.test("updates: install downloads, stages, and triggers on newer release", function()
  local timers = TestHelp.new_fake_timers()
  local releases, store, fakes = install_fixtures("2026090803")
  local seen, progress, err, outcome = {}, {}, nil, nil
  fakes.http_get = install_http(JSON.encode(releases), "NEW-DRIVER-BYTES", seen)
  fakes.set_timeout = timers.set_timeout
  fakes.force, fakes.current_version = false, "2026090705"
  fakes.on_progress = function(text)
    progress[#progress + 1] = text
  end
  fakes.on_result = function(e, o)
    err, outcome = e, o
  end
  local op = FloUpdate.new_install(fakes)
  op.start()
  T.check(err == nil, "no error, got " .. tostring(err))
  T.check_equal(outcome.attempted, "2026090803", "attempted version")
  T.check_equal(store.files["flologic_valve.c4z"], "NEW-DRIVER-BYTES", "staged bytes")
  T.check_equal(store.set_dir_calls[1], "C4Z_ROOT", "staged to the install root")
  T.check_equal(#store.soap_packets, 1, "one install trigger")
  T.check_equal(store.soap_packets[1], FloUpdate.build_install_packet("flologic_valve.c4z"), "trigger packet")
  T.check_equal(#seen, 2, "releases + asset fetch")
  T.check(progress[1]:find("Downloading", 1, true) ~= nil, "download progress")
end)

T.test("updates: install skips when current, force reinstalls anyway", function()
  local timers = TestHelp.new_fake_timers()
  local releases, store, fakes = install_fixtures("2026090705")
  local seen = {}
  fakes.http_get = install_http(JSON.encode(releases), "NEW-DRIVER-BYTES", seen)
  fakes.set_timeout = timers.set_timeout
  fakes.force, fakes.current_version = false, "2026090705"
  local err, outcome = nil, nil
  fakes.on_result = function(e, o)
    err, outcome = e, o
  end
  FloUpdate.new_install(fakes).start()
  T.check(err == nil, "skip is not an error")
  T.check(outcome.attempted == nil and outcome.skipped == "up-to-date", "nothing applied")
  T.check_equal(#seen, 1, "no download when current")
  T.check_equal(store.files["flologic_valve.c4z"], "OLD-DRIVER-BYTES", "old build intact")
  fakes.force = true
  local ferr, foutcome = nil, nil
  fakes.on_result = function(e, o)
    ferr, foutcome = e, o
  end
  FloUpdate.new_install(fakes).start()
  T.check(ferr == nil, "force has no error")
  T.check_equal(foutcome.attempted, "2026090705", "force attempts same build")
  T.check_equal(store.files["flologic_valve.c4z"], "NEW-DRIVER-BYTES", "bytes replaced")
end)

T.test("updates: install failures leave the old driver intact", function()
  local timers = TestHelp.new_fake_timers()
  local function run(mutator, current)
    local releases, store, fakes = install_fixtures("2026090803")
    local seen = {}
    fakes.http_get = install_http(JSON.encode(releases), "NEW-DRIVER-BYTES", seen)
    fakes.set_timeout = timers.set_timeout
    fakes.force, fakes.current_version = false, current or "2026090705"
    local err, outcome = "unset", "unset"
    fakes.on_result = function(e, o)
      err, outcome = e, o
    end
    if mutator then
      mutator(fakes, store)
    end
    FloUpdate.new_install(fakes).start()
    return err, outcome, store
  end
  local err = run(function(fakes, store)
    store.denied = true
  end)
  T.check(err:find("denied", 1, true) ~= nil, "denied store reported, got " .. tostring(err))
  local _, _, denied_store = run(function(_, store)
    store.denied = true
  end)
  T.check_equal(denied_store.files["flologic_valve.c4z"], "OLD-DRIVER-BYTES", "denial keeps old file")
  T.check_equal(#denied_store.soap_packets, 0, "denial triggers nothing")
  local size_err = run(function(_, store)
    store.corrupt_write = true
  end)
  T.check(size_err:find("size mismatch", 1, true) ~= nil, "short write reported")
  local _, _, missing = run(function(fakes)
    fakes.get_installed = function()
      return false
    end
  end)
  T.check_equal(#missing.soap_packets, 0, "absent driver never installs")
  local _, skipped = run(function(fakes)
    fakes.get_installed = function()
      return false
    end
  end)
  T.check(skipped.skipped == "not-installed", "absent driver reports skip")
end)

T.test("updates: install follows asset redirects with headers", function()
  local timers = TestHelp.new_fake_timers()
  local releases, _, fakes = install_fixtures("2026090803")
  local hops = {}
  fakes.http_get = function(url, _, cb)
    hops[#hops + 1] = url
    if url:find("api.github.com", 1, true) then
      cb(nil, JSON.encode(releases), 200, nil)
    elseif #hops == 2 then
      cb(nil, "", 302, { Location = "https://objects.example.invalid/asset" })
    else
      cb(nil, "NEW-DRIVER-BYTES", 200, nil)
    end
    return function() end
  end
  fakes.set_timeout = timers.set_timeout
  fakes.force, fakes.current_version = false, "2026090705"
  local err, outcome = nil, nil
  fakes.on_result = function(e, o)
    err, outcome = e, o
  end
  FloUpdate.new_install(fakes).start()
  T.check(err == nil, "redirect followed, got " .. tostring(err))
  T.check_equal(outcome.attempted, "2026090803", "attempted after redirect")
  T.check_equal(hops[3], "https://objects.example.invalid/asset", "followed Location")
end)

T.test("updates: install rejects bare redirects and cancel wins races", function()
  local timers = TestHelp.new_fake_timers()
  local releases, _, fakes = install_fixtures("2026090803")
  fakes.http_get = function(url, _, cb)
    if url:find("api.github.com", 1, true) then
      cb(nil, JSON.encode(releases), 200, nil)
    else
      cb(nil, "", 302, nil)
    end
    return function() end
  end
  fakes.set_timeout = timers.set_timeout
  fakes.force, fakes.current_version = false, "2026090705"
  local err = nil
  fakes.on_result = function(e)
    err = e
  end
  FloUpdate.new_install(fakes).start()
  T.check(err == "Asset redirect not followed by transport", "bare redirect is explicit, got " .. tostring(err))
  local answer, count = nil, 0
  fakes.http_get = function(_, _, cb)
    answer = cb
    return function() end
  end
  fakes.on_result = function()
    count = count + 1
  end
  local op = FloUpdate.new_install(fakes)
  op.start()
  op.cancel()
  answer(nil, "[]", 200, nil)
  timers.advance(200000)
  T.check_equal(count, 0, "cancelled install stays silent")
end)
