-- ============================================================================
-- c4/tests/link.lua — shared link-protocol conformance suite (unit 1).
--
-- Exercises c4/shared/flologic_link.lua as pure request/response functions:
-- round trips, validation rejections, version mismatches, and the
-- oversize/truncated-payload branches. Loaded by loader_standalone.lua and
-- tests/test_c4_lua.py after the driver suites; asserts nothing about the
-- monolith driver. Lua 5.1 safe.
-- ============================================================================

local L = TestHelp
local Link = FloLogicLink

local function full_state(overrides)
  local state = {
    id = 11,
    uuid = "uuid-1",
    name = "Kitchen",
    mode = 33,
    online = true,
    flow_state = 4,
    device_type = "Connect",
    home_interval = 10,
    away_interval = 5,
    bypass_time = 30,
    access = 64,
    updated = 1757200000,
  }
  if overrides ~= nil then
    for k, v in pairs(overrides) do
      state[k] = v
    end
  end
  return state
end

local function worst_case_state()
  return {
    id = "4294967295",
    uuid = string.rep("u", 128),
    name = string.rep("n", 128),
    mode = 268435456,
    online = true,
    flow_state = 8,
    device_type = string.rep("d", 64),
    home_interval = 999999,
    away_interval = 999999,
    bypass_time = 999999,
    access = 4294967295,
    updated = 9999999999,
  }
end

L.test("link: version pinned and message sets disjoint", function()
  L.check_equal(FLOGIC_LINK_VERSION, 1, "protocol version is 1")
  L.check_equal(Link.VERSION, FLOGIC_LINK_VERSION, "module mirrors global")
  local seen, count = {}, 0
  for _, name in ipairs({
    Link.MSG_HELLO,
    Link.MSG_GET_STATE,
    Link.MSG_COMMAND,
    Link.MSG_IDENTITY,
    Link.MSG_STATE,
    Link.MSG_CMD_ACK,
    Link.MSG_CMD_NACK,
  }) do
    L.check(type(name) == "string", "message name is a string")
    L.check(seen[name] == nil, "distinct names, dup " .. tostring(name))
    seen[name], count = true, count + 1
  end
  L.check_equal(count, 7, "seven messages")
  L.check_equal(#Link.VALVE_TO_CLOUD, 3, "three valve->cloud messages")
  L.check_equal(#Link.CLOUD_TO_VALVE, 4, "four cloud->valve messages")
  for _, name in ipairs(Link.VALVE_TO_CLOUD) do
    L.check(Link.is_valve_to_cloud(name), name .. " routes valve->cloud")
    L.check(not Link.is_cloud_to_valve(name), name .. " never routes cloud->valve")
  end
  for _, name in ipairs(Link.CLOUD_TO_VALVE) do
    L.check(Link.is_cloud_to_valve(name), name .. " routes cloud->valve")
    L.check(not Link.is_valve_to_cloud(name), name .. " never routes valve->cloud")
  end
end)

L.test("link: digest vectors and canonical field order", function()
  L.check_equal(Link.digest(""), "811c9dc5", "fnv empty")
  L.check_equal(Link.digest("foobar"), "bf9cf968", "fnv foobar")
  L.check_equal(Link.digest("hello"), "4f9f2cab", "fnv hello")
  L.check_equal(Link.encode_fields({ b = 1, a = 2 }), '{"a":2,"b":1}', "keys sorted")
  local ok, err = Link.digest(nil)
  L.check(ok == nil and err == "digest-needs-string", "digest rejects non-string")
end)

L.test("link: hello and get_state round-trip", function()
  for _, build in ipairs({ Link.build_hello, Link.build_get_state }) do
    local env = build()
    L.check_equal(env[Link.K_VERSION], "1", "wire version is string 1")
    local msg, err = Link.parse(env)
    L.check(msg ~= nil, "parses, got " .. tostring(err))
    L.check_equal(msg.msg, env[Link.K_MSG], "name survives")
    L.check_equal(msg.version, 1, "version decoded")
    L.check(msg.truncated == false, "not truncated")
  end
  L.check_equal(Link.build_hello()[Link.K_MSG], Link.MSG_HELLO, "hello name")
  L.check_equal(Link.build_get_state()[Link.K_MSG], Link.MSG_GET_STATE, "get_state name")
end)

L.test("link: identity handshake round-trip and rejection", function()
  local env = Link.build_identity("uuid-2")
  L.check_equal(env[Link.K_BODY], "uuid-2", "valve id in body")
  local msg, err = Link.parse(env)
  L.check(msg ~= nil, "parses, got " .. tostring(err))
  L.check_equal(msg.valve_id, "uuid-2", "valve id decoded")
  local numeric = Link.parse(Link.build_identity(22))
  L.check_equal(numeric.valve_id, "22", "numeric id coerced to string")
  for _, bad in ipairs({ nil, "", string.rep("x", 129), "has space ok?", 0 / 0 }) do
    -- "has space ok?" is a valid id (spaces allowed); the rest must fail.
    local built, build_err = Link.build_identity(bad)
    if bad == "has space ok?" then
      L.check(built ~= nil, "spaces allowed in ids")
    else
      L.check(built == nil and build_err == "bad-valve-id", "rejects " .. tostring(bad))
    end
  end
  local control = Link.build_identity("a\001b")
  L.check(control == nil, "control characters rejected")
end)

L.test("link: command round-trip with cmd_id correlation", function()
  local env = Link.build_command("cmd-7", "Set Mode Shutoff", { Minutes = 30 })
  L.check(env ~= nil, "command builds")
  L.check_equal(env[Link.K_CMD], "cmd-7", "cmd id on wire")
  local msg, err = Link.parse(env)
  L.check(msg ~= nil, "parses, got " .. tostring(err))
  L.check_equal(msg.cmd_id, "cmd-7", "cmd id decoded")
  L.check_equal(msg.fields.action, "Set Mode Shutoff", "action decoded")
  L.check_equal(msg.fields.Minutes, 30, "param decoded")
  -- Bare action with no params round-trips too.
  local bare = Link.parse(Link.build_command("c2", "Ping", nil))
  L.check_equal(bare.fields.action, "Ping", "paramless action")
  -- Ack/nack echo the same cmd id.
  local ack = Link.parse(Link.build_ack("cmd-7"))
  L.check_equal(ack.cmd_id, "cmd-7", "ack echoes cmd id")
  L.check_equal(ack.msg, Link.MSG_CMD_ACK, "ack name")
  local nack = Link.parse(Link.build_nack("cmd-7", "slot not bound"))
  L.check_equal(nack.cmd_id, "cmd-7", "nack echoes cmd id")
  L.check_equal(nack.error_reason, "slot not bound", "nack reason")
  -- Builder rejections never raise.
  L.check(Link.build_command("", "x") == nil, "empty cmd id rejected")
  L.check(Link.build_command("c", "") == nil, "empty action rejected")
  L.check(Link.build_command("c", string.rep("a", 65)) == nil, "long action rejected")
  L.check(Link.build_command("c", "a\002b") == nil, "control-char action rejected")
  L.check(Link.build_command("c", "ok", { action = 1 }) == nil, "param clash rejected")
  L.check(Link.build_command("c", "ok", { ["has space"] = 1 }) == nil, "bad param key rejected")
  L.check(Link.build_command("c", "ok", { deep = {} }) == nil, "nested param rejected")
  L.check(Link.build_command("c", "ok", { n = 0 / 0 }) == nil, "nonfinite param rejected")
  L.check(Link.build_nack("c", "") == nil, "empty nack reason rejected")
  L.check(Link.build_ack(nil) == nil, "missing ack cmd id rejected")
end)

L.test("link: full state round-trip with hash verification", function()
  local env = Link.build_state(full_state())
  L.check(env[Link.K_TRUNC] == nil, "natural state is not truncated")
  L.check_equal(env[Link.K_HASH], Link.digest(env[Link.K_BODY]), "hash covers body")
  local msg, err = Link.parse(env)
  L.check(msg ~= nil, "parses, got " .. tostring(err))
  L.check_equal(msg.fields.id, "11", "numeric id canonicalized to string")
  L.check_equal(msg.fields.mode, 33, "mode survives")
  L.check_equal(msg.fields.online, true, "online survives")
  L.check_equal(msg.fields.access, 64, "access flags survive")
  L.check_equal(msg.fields.name, "Kitchen", "name survives")
  -- A tampered body fails the integrity check.
  local tampered = Link.build_state(full_state())
  tampered[Link.K_BODY] = tampered[Link.K_BODY]:gsub("Kitchen", "Garage")
  local got, tamper_err = Link.parse(tampered)
  L.check(got == nil and tamper_err == "hash-mismatch", "tamper detected, got " .. tostring(tamper_err))
  -- A non-string hash is malformed, not a mismatch.
  local bad_hash = Link.build_state(full_state())
  bad_hash[Link.K_HASH] = 42
  L.check(Link.parse(bad_hash) == nil, "numeric hash rejected")
end)

L.test("link: field codec escapes and strictness", function()
  local tricky = { q = 'say "hi" \\ bye', nl = "a\nb\tc", uni = "Café" }
  local encoded = Link.encode_fields(tricky)
  local back, err = Link.decode_fields(encoded)
  L.check(back ~= nil, "escapes decode, got " .. tostring(err))
  L.check_equal(back.q, tricky.q, "quotes survive")
  L.check_equal(back.nl, tricky.nl, "controls survive")
  L.check_equal(back.uni, tricky.uni, "utf-8 survives")
  L.check_equal(Link.decode_fields('{"a":"\\u00e9"}').a, "é", "u-escape decodes")
  for body, _ in pairs({
    [""] = true,
    ["[]"] = true,
    ["{unquoted:1}"] = true,
    ['{"a":null}'] = true,
    ['{"a":[1]}'] = true,
    ['{"a":{"b":1}}'] = true,
    ['{"a":1} trailing'] = true,
    ['{"a":01}'] = true,
    ['{"a":1,}'] = true,
    ["{'a':1}"] = true,
  }) do
    L.check(Link.decode_fields(body) == nil, "rejects " .. body)
  end
end)

L.test("link: validation rejects malformed envelopes", function()
  local function rejects(params, why)
    local msg, err = Link.parse(params)
    L.check(msg == nil and err ~= nil, "rejects " .. why .. ", got err " .. tostring(err))
    return err
  end
  rejects(nil, "nil envelope")
  rejects("FLOGIC_HELLO", "string envelope")
  rejects({}, "empty envelope")
  rejects({ [Link.K_MSG] = Link.MSG_HELLO }, "missing version")
  local cmd = Link.build_command("c1", "act", nil)
  cmd[Link.K_CMD] = nil
  rejects(cmd, "command without cmd id")
  local ack = Link.build_ack("c1")
  ack[Link.K_CMD] = ""
  rejects(ack, "ack with empty cmd id")
  local nack = Link.build_nack("c1", "busy")
  nack[Link.K_ERROR] = nil
  rejects(nack, "nack without reason")
  local identity = Link.build_identity("v1")
  identity[Link.K_BODY] = ""
  rejects(identity, "identity without valve id")
  local no_action = Link.build_command("c1", "act", nil)
  no_action[Link.K_BODY] = '{"Minutes":30}'
  rejects(no_action, "command without action")
  local overflow = Link.build_command("c1", "act", nil)
  overflow[Link.K_BODY] = '{"action":"act","value":1e999}'
  L.check_equal(
    rejects(overflow, "command with overflow param"),
    "bad-param-value:value",
    "overflow error names the key"
  )
  local neg_overflow = Link.build_command("c1", "act", nil)
  neg_overflow[Link.K_BODY] = '{"action":"act","value":-1e999}'
  L.check_equal(
    rejects(neg_overflow, "command with negative overflow"),
    "bad-param-value:value",
    "negative overflow rejected"
  )
  local empty_state = Link.build_state(full_state())
  empty_state[Link.K_BODY] = "{}"
  empty_state[Link.K_HASH] = Link.digest("{}")
  rejects(empty_state, "state without required fields")
  local renamed = Link.build_state(full_state())
  renamed[Link.K_BODY] = '{"id":"11","mode":1,"online":true,"bogus":2}'
  renamed[Link.K_HASH] = Link.digest(renamed[Link.K_BODY])
  rejects(renamed, "state with unknown field")
  local non_string_body = Link.build_hello()
  non_string_body[Link.K_BODY] = 42
  rejects(non_string_body, "non-string body")
end)

L.test("link: version mismatch fails closed", function()
  local function version_case(version, why)
    local env = Link.build_hello()
    env[Link.K_VERSION] = version
    local msg, err = Link.parse(env)
    L.check(msg == nil and err == "version-mismatch", why .. " rejected, got " .. tostring(err))
  end
  version_case("2", "newer version")
  version_case("0", "older version")
  version_case("x", "garbage version")
  version_case("", "empty version")
  version_case(nil, "missing version")
  local env = Link.build_hello()
  env[Link.K_MSG] = "FLOGIC_FUTURE"
  local msg, err = Link.parse(env)
  L.check(msg == nil and err == "unknown-message", "unknown name rejected, got " .. tostring(err))
end)

L.test("link: oversize body rejected, digest fallback accepted", function()
  -- A raw oversize body on the wire never parses, even with a valid hash.
  local big = string.rep("s", Link.MAX_BODY_BYTES + 1)
  local oversize = Link.build_hello()
  oversize[Link.K_BODY] = big
  local msg, err = Link.parse(oversize)
  L.check(msg == nil and err == "oversize-body", "oversize rejected, got " .. tostring(err))
  -- Oversized commands fail at build time: the cloud must nack, never send.
  local huge_params = { blob = string.rep("p", Link.MAX_BODY_BYTES + 1) }
  local built, build_err = Link.build_command("c9", "act", huge_params)
  L.check(built == nil and build_err == "command-body-oversize", "oversize command refused")
  -- Shrink the budget to force the state digest path through the builder.
  local saved_budget = Link.MAX_BODY_BYTES
  Link.MAX_BODY_BYTES = 64
  local degraded = Link.build_state(full_state())
  Link.MAX_BODY_BYTES = saved_budget
  L.check(degraded ~= nil, "degraded state still builds")
  L.check_equal(degraded[Link.K_TRUNC], "1", "trunc flag set")
  L.check_equal(degraded[Link.K_BODY], "", "body withheld")
  L.check(degraded[Link.K_HASH] ~= nil and #degraded[Link.K_HASH] > 0, "digest identifies unseen body")
  local parsed, parse_err = Link.parse(degraded)
  L.check(parsed ~= nil, "digest-only parses, got " .. tostring(parse_err))
  L.check(parsed.truncated and parsed.fields == nil, "digest-only carries no fields")
  L.check_equal(parsed.hash, degraded[Link.K_HASH], "digest survives the round trip")
  -- A trunc flag without a digest is malformed.
  local no_digest = Link.build_hello()
  no_digest[Link.K_MSG] = Link.MSG_STATE
  no_digest[Link.K_TRUNC] = "1"
  local naked, naked_err = Link.parse(no_digest)
  L.check(naked == nil and naked_err == "digest-missing", "trunc needs a digest")
end)

L.test("link: worst-case full state fits the byte budget", function()
  local body, err = Link.build_state_body(worst_case_state())
  L.check(body ~= nil, "worst case encodes, got " .. tostring(err))
  print("link worst-case valve_state body: " .. #body .. " bytes (budget " .. Link.MAX_BODY_BYTES .. ")")
  L.check(#body <= Link.MAX_BODY_BYTES, "worst case exceeds budget")
  local env = Link.build_state(worst_case_state())
  L.check(env[Link.K_TRUNC] == nil, "worst case needs no digest fallback")
  local back, back_err = Link.parse(env)
  L.check(back ~= nil and back.fields ~= nil, "worst case round-trips, got " .. tostring(back_err))
  L.check_equal(back.fields.name, string.rep("n", 128), "max name survives")
end)

L.test("link: scripted cloud/valve exchange", function()
  -- Bind: valve hello -> cloud identity -> valve state request -> state.
  local hello, hello_err = Link.parse(Link.build_hello())
  L.check(hello ~= nil and hello.msg == Link.MSG_HELLO, "cloud reads hello, got " .. tostring(hello_err))
  L.check(Link.is_valve_to_cloud(hello.msg), "hello arrives on the valve->cloud leg")
  local identity = Link.parse(Link.build_identity("uuid-9"))
  L.check(identity ~= nil and identity.valve_id == "uuid-9", "valve reads identity")
  L.check(Link.is_cloud_to_valve(identity.msg), "identity arrives on the cloud->valve leg")
  -- Steady state: cloud fan-out slice parses on the valve.
  local state = Link.parse(Link.build_state(full_state({ id = "uuid-9", mode = 1 })))
  L.check(state ~= nil and state.fields.mode == 1, "valve reads fan-out state")
  L.check(Link.is_cloud_to_valve(state.msg), "state arrives on the cloud->valve leg")
  -- Control: valve command executes on the cloud, ack returns to the valve.
  local command = Link.parse(Link.build_command("job-3", "Set Away Limit", { Minutes = 120 }))
  L.check(command ~= nil and command.fields.Minutes == 120, "cloud reads command")
  L.check(Link.is_valve_to_cloud(command.msg), "command arrives on the valve->cloud leg")
  local ack = Link.parse(Link.build_ack(command.cmd_id))
  L.check_equal(ack.cmd_id, "job-3", "ack correlates to the issued command")
end)
