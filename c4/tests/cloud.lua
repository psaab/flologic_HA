-- ============================================================================
-- c4/tests/cloud.lua — cloud-driver suite (scripted valves + account).
--
-- Loaded by loader_cloud.lua in its own Lua state (plan D8: two bundles
-- must never share a state). Covers handshake, fan-out routing, the link
-- action set, authorization, the circuit breaker, persist/restore, and
-- destroy cleanup. Lua 5.1 safe.
-- ============================================================================

local T = TestHelp
local Link = FloLogicLink

local function cloud_env()
  local timers = T.new_fake_timers()
  local env = {
    timers = timers,
    bindings = {},
    proxy_sends = {},
    device_sends = {},
    consumers = {},
    saved = {},
    events = {},
    proxy_fail = false,
    fetch_calls = {},
    send_calls = {},
  }
  Properties = {
    Email = "u@example.com",
    Password = "pw",
    ["Hub URL"] = "https://hub-cloudapps-prod.azurewebsites.net",
    ["Poll Interval"] = "60",
    ["Debug Mode"] = "Off",
    ["Update Check Interval"] = "24",
  }
  C4 = {}
  function C4:UpdateProperty(name, value)
    Properties[name] = value
  end
  function C4:AddDynamicBinding(id, kind, provider, name, class, hidden, autobind)
    env.bindings[#env.bindings + 1] = { id = id, kind = kind, provider = provider, name = name, class = class }
  end
  function C4:SendToProxy(binding, command, params, kind)
    if env.proxy_fail then
      error("proxy down")
    end
    env.proxy_sends[#env.proxy_sends + 1] = { binding = binding, command = command, params = params, kind = kind }
  end
  function C4:SendToDevice(id, command, params)
    env.device_sends[#env.device_sends + 1] = { id = id, command = command, params = params }
  end
  function C4:GetBoundConsumerDevices(_, binding)
    return env.consumers[binding]
  end
  function C4:FireEvent(name)
    env.events[#env.events + 1] = name
  end
  function C4:PersistGetValue(key)
    return env.saved[key]
  end
  function C4:PersistSetValue(key, value)
    env.saved[key] = value
  end
  function C4:UUID()
    return "12345678-1234-4234-8234-123456789abc"
  end
  function C4:Hash(_, value)
    return T.sha1(value)
  end
  function C4:Base64Encode(value)
    return T.b64encode(value)
  end
  function C4:SetTimer(ms, callback, repeating)
    local timer = {}
    function timer:Cancel()
      self.cancelled = true
      if self.cancel then
        self.cancel()
      end
    end
    local function fire()
      if timer.cancelled then
        return
      end
      callback(timer)
      if repeating and not timer.cancelled then
        timer.cancel = timers.set_timeout(ms, fire)
      end
    end
    timer.cancel = timers.set_timeout(ms, fire)
    return timer
  end
  return env
end

local function boot(env)
  flocloud_account_fetch = nil
  flocloud_command_send = nil
  OnDriverInit("test")
  OnDriverLateInit("test")
  return env
end

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
    valveFriendlyName = "Kitchen",
    homeIntervalTime = 10,
    awayIntervalTime = 5,
    bypassTime = 30,
  }
  if overrides ~= nil then
    for k, v in pairs(overrides) do
      valve[k] = v
    end
  end
  return valve
end

local function script_account(env, devices, accesses)
  flocloud_account_fetch = function(hub, cb)
    env.fetch_calls[#env.fetch_calls + 1] = { hub = hub }
    cb(nil, { user = { id = 7 }, devices = devices, accesses = accesses or {} })
  end
end

local function script_send(env, err)
  flocloud_command_send = function(job, settled)
    env.send_calls[#env.send_calls + 1] = job
    settled(err)
  end
end

local function sends_to(env, binding, msg)
  local found = {}
  for _, send in ipairs(env.proxy_sends) do
    if send.binding == binding and send.params[Link.K_MSG] == msg then
      found[#found + 1] = send
    end
  end
  return found
end

local function discover(env, devices, accesses)
  script_account(env, devices, accesses)
  env.timers.advance(2000)
end

T.test("cloud: version, link pin, updater asset, no picker (CLOUD-U6)", function()
  T.check_equal(FLOCLOUD_DRIVER_VERSION, "2026090803", "cloud version")
  T.check_equal(FLOGIC_LINK_VERSION, 1, "protocol version is 1")
  T.check_equal(FloUpdate.ASSET, "flologic_cloud.c4z", "updater tracks the cloud package")
  T.check(flocloud_selection == nil, "no single-valve selection helper")
  T.check(FLOCLOUD_PROP_PICKER == nil, "no picker property constant")
  T.check(FLOCLOUD_PROP_OVERRIDE == nil, "no override property constant")
  local body = JSON.encode({
    {
      tag_name = "c4-v2026090803",
      draft = false,
      prerelease = false,
      assets = {
        {
          name = "flologic_cloud.c4z",
          browser_download_url = "https://github.com/psaab/flologic_HA/releases/download/c4-v2026090803/flologic_cloud.c4z",
        },
      },
    },
    {
      tag_name = "c4-v2026090803",
      draft = false,
      prerelease = false,
      assets = {
        {
          name = "flologic_valve.c4z",
          browser_download_url = "https://github.com/psaab/flologic_HA/releases/download/c4-v2026090803/flologic_valve.c4z",
        },
      },
    },
  })
  local release = FloUpdate.select_release(JSON.decode(body))
  T.check(release ~= nil, "cloud asset selected")
  T.check_equal(release.version, "2026090803", "cloud release version")
  T.check(release.url:find("flologic_cloud.c4z", 1, true) ~= nil, "cloud asset url")
end)

T.test("cloud: discovery creates one binding per valve, first static", function()
  local env = boot(cloud_env())
  T.check_equal(env.timers.pending_count(), 5, "poll, reconcile, soon, and update timers")
  local v1, v2 = make_valve(), make_valve({ id = 22, uuid = "uuid-2", valveFriendlyName = "Garden" })
  discover(env, { v1, v2 }, { { valveId = 11, notificationsList = 64 } })
  -- Slot 2001 is the static manifest provider, so only 2002 is created
  -- dynamically; both slots are managed identically from here on.
  T.check_equal(#env.bindings, 1, "one dynamic binding")
  T.check_equal(env.bindings[1].id, 2002, "second valve takes 2002")
  for _, binding in ipairs(env.bindings) do
    T.check_equal(binding.kind, "CONTROL", "control binding")
    T.check(binding.provider, "provider side")
    T.check_equal(binding.class, "FLOGIC_VALVE", "valve class")
  end
  T.check_equal(Properties["Valve Count"], "2", "valve count published")
  T.check(Properties["Available Valves"]:find("11: Kitchen", 1, true) ~= nil, "valve list names 11")
  T.check_equal(Properties.Connection, "Online", "account online")
  T.check_equal(flocloud_state.valve_slots["11"], 2001, "identity maps 11 to 2001")
  T.check_equal(flocloud_state.valve_slots["22"], 2002, "identity maps 22 to 2002")
  T.check(env.saved.flocloud_slots ~= nil, "slot map persisted")
  -- A repeat poll with the same inventory adds nothing.
  flocloud_poll_now()
  T.check_equal(#env.bindings, 1, "stable map adds no bindings")
  -- A departed valve marks its slot unavailable without deleting it.
  script_account(env, { v1 }, {})
  flocloud_poll_now()
  T.check_equal(#env.bindings, 1, "removed slot is never deleted")
  T.check_equal(flocloud_state.slots[2002].available, false, "removed slot unavailable")
  T.check_equal(Properties["Valve Count"], "1", "count tracks the account")
  -- The valve returns: same slot resumes without a new binding.
  script_account(env, { v1, v2 }, {})
  flocloud_poll_now()
  T.check_equal(#env.bindings, 1, "returning valve reuses its slot")
  T.check(flocloud_state.slots[2002].available, "slot available again")
  OnDriverDestroyed()
end)

T.test("cloud: handshake answers hello per slot and stays silent unmapped", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_HELLO", Link.build_hello())
  local identities = sends_to(env, 2001, Link.MSG_IDENTITY)
  T.check_equal(#identities, 1, "one identity reply")
  local parsed = Link.parse(identities[1].params)
  T.check_equal(parsed.valve_id, "11", "identity names the slot valve")
  -- Cached slice follows the identity so the valve paints immediately.
  T.check_equal(#sends_to(env, 2001, Link.MSG_STATE), 1, "state follows identity")
  -- Unmapped slots stay silent (D3).
  local before = #env.proxy_sends
  ReceivedFromProxy(2009, "FLOGIC_HELLO", Link.build_hello())
  T.check_equal(#env.proxy_sends, before, "unmapped hello answered with silence")
  OnDriverDestroyed()
end)

T.test("cloud: fan-out routes each slice to its own slot only", function()
  local env = boot(cloud_env())
  local v1 = make_valve({ mode = 1 })
  local v2 = make_valve({ id = 22, uuid = "uuid-2", valveFriendlyName = "Garden", mode = 2 })
  discover(env, { v1, v2 }, { { valveId = 22, notificationsList = 64 } })
  local states_1, states_2 = sends_to(env, 2001, Link.MSG_STATE), sends_to(env, 2002, Link.MSG_STATE)
  T.check_equal(#states_1, 1, "slot 2001 gets one slice")
  T.check_equal(#states_2, 1, "slot 2002 gets one slice")
  T.check_equal(Link.parse(states_1[1].params).fields.id, "11", "slot 2001 carries valve 11")
  T.check_equal(Link.parse(states_2[1].params).fields.id, "22", "slot 2002 carries valve 22")
  T.check_equal(Link.parse(states_2[1].params).fields.access, 64, "access row matched per valve")
  -- Between polls a valve polls its own slot without disturbing the other.
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_GET_STATE", Link.build_get_state())
  T.check_equal(#sends_to(env, 2001, Link.MSG_STATE), 1, "get_state answered")
  T.check_equal(#sends_to(env, 2002, Link.MSG_STATE), 0, "other slot untouched")
  T.check_equal(Link.parse(sends_to(env, 2001, Link.MSG_STATE)[1].params).fields.id, "11", "refresh still valve 11")
  OnDriverDestroyed()
end)

T.test("cloud: misrouted and malformed link traffic fails closed", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  env.proxy_sends = {}
  local slice = flocloud_build_slice(make_valve(), nil, 1757200000)
  ReceivedFromProxy(2001, "FLOGIC_STATE", Link.build_state(slice))
  T.check_equal(#env.proxy_sends, 0, "cloud-to-valve message ignored")
  ReceivedFromProxy(2001, "FLOGIC_HELLO", { garbage = "x" })
  T.check_equal(#env.proxy_sends, 0, "malformed envelope ignored")
  local hello = Link.build_hello()
  hello[Link.K_VERSION] = "2"
  ReceivedFromProxy(2001, "FLOGIC_HELLO", hello)
  T.check_equal(#env.proxy_sends, 0, "version mismatch ignored")
  OnDriverDestroyed()
end)

T.test("cloud: command authorized, queued, and acked with correlation", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  script_send(env, nil)
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("cmd-1", "mode_shutoff"))
  T.check_equal(#env.send_calls, 1, "command sent to the cloud")
  T.check_equal(env.send_calls[1].valve_id, "11", "slot authorizes valve 11")
  T.check_equal(env.send_calls[1].fields.mode, 8, "shutoff mode value")
  T.check_equal(Properties["Last Command"], "mode_shutoff: acknowledged; awaiting refresh", "ack published")
  local acks = sends_to(env, 2001, Link.MSG_CMD_ACK)
  T.check_equal(#acks, 1, "one ack")
  T.check_equal(Link.parse(acks[1].params).cmd_id, "cmd-1", "ack echoes the command id")
  OnDriverDestroyed()
end)

T.test("cloud: command rejections nack with reason", function()
  local env = boot(cloud_env())
  local v1 = make_valve()
  local v2 = make_valve({ id = 22, uuid = "uuid-2", valveFriendlyName = "Garden" })
  discover(env, { v1, v2 }, {})
  script_send(env, nil)
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("cmd-2", "bogus_action"))
  local nacks = sends_to(env, 2001, Link.MSG_CMD_NACK)
  T.check_equal(#nacks, 1, "unknown action nacked")
  T.check_equal(Link.parse(nacks[1].params).error_reason, "unknown-action", "nack reason")
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("cmd-3", "home_limit", { value = 1.5 }))
  nacks = sends_to(env, 2001, Link.MSG_CMD_NACK)
  T.check_equal(#nacks, 2, "fractional home limit nacked")
  -- A departed valve's slot nacks instead of executing.
  script_account(env, { v1 }, {})
  flocloud_poll_now()
  env.proxy_sends = {}
  ReceivedFromProxy(2002, "FLOGIC_COMMAND", Link.build_command("cmd-4", "mode_home"))
  nacks = sends_to(env, 2002, Link.MSG_CMD_NACK)
  T.check_equal(#nacks, 1, "unavailable slot nacked")
  T.check_equal(Link.parse(nacks[1].params).error_reason, "valve-unavailable", "unavailable reason")
  -- Commands on slots with no valve are dropped, never executed.
  local before = #env.send_calls
  ReceivedFromProxy(2009, "FLOGIC_COMMAND", Link.build_command("cmd-5", "mode_home"))
  T.check_equal(#env.send_calls, before, "unmapped command never sent")
  T.check_equal(#env.proxy_sends, 1, "unmapped command never nacked")
  -- A full queue nacks instead of silently dropping the oldest write.
  for i = 1, 8 do
    flocloud_state.command_queue[i] = { cmd_id = "fill-" .. i, slot = 2001, valve_id = "11", name = "x", fields = {} }
  end
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("cmd-6", "mode_home"))
  nacks = sends_to(env, 2001, Link.MSG_CMD_NACK)
  T.check_equal(Link.parse(nacks[#nacks].params).error_reason, "queue-full", "overflow nacked")
  flocloud_state.command_queue = {}
  -- A cloud rejection nacks without feeding the circuit breaker.
  script_send(env, "command-rejected")
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("cmd-7", "mode_home"))
  nacks = sends_to(env, 2001, Link.MSG_CMD_NACK)
  T.check_equal(Link.parse(nacks[#nacks].params).error_reason, "cloud rejected the command", "rejection described")
  T.check_equal(flocloud_state.cb_failures, 0, "logical rejection never trips the breaker")
  OnDriverDestroyed()
end)

T.test("cloud: provider SendToDevice fallback both directions", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  env.proxy_fail = true
  env.consumers[2001] = { 55 }
  env.proxy_sends = {}
  env.device_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_HELLO", Link.build_hello())
  T.check_equal(#env.proxy_sends, 0, "proxy send raised, nothing recorded")
  T.check(#env.device_sends >= 1, "hello fell back to the bound consumer")
  T.check_equal(env.device_sends[1].id, 55, "fallback targets the consumer")
  T.check_equal(env.device_sends[1].command, "FLOGIC_IDENTITY", "fallback keeps the message name")
  T.check_equal(Link.parse(env.device_sends[1].params).valve_id, "11", "fallback keeps the envelope")
  -- Fallback receive arrives via ExecuteCommand with the sender hint.
  local hello = Link.build_hello()
  hello[FLOCLOUD_K_FROM] = "11"
  local before = #env.device_sends
  ExecuteCommand("FLOGIC_HELLO", hello)
  T.check_equal(env.device_sends[before + 1].command, "FLOGIC_IDENTITY", "fallback hello answered on the fallback path")
  -- Unattributable fallback traffic is dropped.
  local count = #env.device_sends
  ExecuteCommand("FLOGIC_HELLO", Link.build_hello())
  T.check_equal(#env.device_sends, count, "hintless fallback dropped")
  ExecuteCommand("Bogus Programming Command", {})
  T.check_equal(#env.device_sends, count, "unknown commands still ignored")
  env.proxy_fail = false
  OnDriverDestroyed()
end)

T.test("cloud: circuit breaker backs off and recovers", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  flocloud_account_fetch = function(_, cb)
    cb("transport-28")
  end
  for _ = 1, 4 do
    flocloud_poll_now()
  end
  T.check_equal(flocloud_state.cb_failures, 4, "failures counted")
  T.check(not flocloud_breaker_open(), "breaker still closed")
  T.check(Properties.Connection:find("transport%-28") ~= nil, "transport error surfaced")
  flocloud_poll_now()
  T.check(flocloud_breaker_open(), "breaker opens on the fifth failure")
  T.check(Properties.Connection:find("backing off", 1, true) ~= nil, "backoff published")
  local calls = #env.fetch_calls
  flocloud_poll_now()
  T.check_equal(#env.fetch_calls, calls, "open breaker makes no cloud call")
  -- Logical errors never feed the breaker, even at the threshold.
  flocloud_note_result(false, "command-rejected")
  T.check_equal(flocloud_state.cb_failures, 5, "logical rejection ignored")
  -- Expiry plus one success closes the breaker.
  flocloud_state.cb_open_until = 0
  script_account(env, { make_valve() }, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.cb_failures, 0, "success resets the count")
  T.check(not flocloud_breaker_open(), "breaker closed")
  T.check_equal(Properties.Connection, "Online", "account online again")
  T.check(env.events[#env.events] == "Connection Restored", "restoration published")
  OnDriverDestroyed()
end)

T.test("cloud: destroy retires work and fences late callbacks", function()
  local env = boot(cloud_env())
  local held = nil
  flocloud_account_fetch = function(_, cb)
    held = cb
  end
  env.timers.advance(2000)
  T.check(flocloud_state.busy, "poll in flight")
  OnDriverDestroyed()
  T.check_equal(env.timers.pending_count(), 0, "destroy cancels every timer")
  held(nil, { user = { id = 7 }, devices = { make_valve() }, accesses = {} })
  T.check_equal(#env.proxy_sends, 0, "late poll settles nothing")
  T.check_equal(#env.events, 0, "destroyed driver emits no events")
  T.check(not flocloud_state.busy, "busy cleared")
  OnPropertyChanged("Email")
  T.check_equal(env.timers.pending_count(), 0, "property callback cannot restart destroyed driver")
  flocloud_poll_now()
  T.check(held ~= nil and #env.proxy_sends == 0, "poll after destroy stays silent")
end)

T.test("cloud: persist and restore revive bindings across restarts", function()
  local env = boot(cloud_env())
  local v1 = make_valve()
  local v2 = make_valve({ id = 22, uuid = "uuid-2", valveFriendlyName = "Garden" })
  discover(env, { v1, v2 }, {})
  T.check(env.saved.flocloud_slots ~= nil, "map persisted")
  OnDriverDestroyed()
  env.bindings = {}
  env.proxy_sends = {}
  OnDriverLateInit("test")
  T.check_equal(#env.bindings, 1, "dynamic binding re-created, static remembered")
  T.check_equal(env.bindings[1].id, 2002, "dynamic slot restored")
  T.check_equal(env.bindings[1].class, "FLOGIC_VALVE", "class restored")
  T.check_equal(flocloud_state.valve_slots["11"], 2001, "static identity restored")
  T.check_equal(flocloud_state.valve_slots["22"], 2002, "identity restored")
  -- Restored slots handshake immediately, before the next poll.
  ReceivedFromProxy(2002, "FLOGIC_HELLO", Link.build_hello())
  local identities = sends_to(env, 2002, Link.MSG_IDENTITY)
  T.check_equal(#identities, 1, "restored slot answers hello")
  T.check_equal(Link.parse(identities[1].params).valve_id, "22", "restored identity correct")
  OnDriverDestroyed()
end)

T.test("cloud: credential change cancels work and clears the relog token", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  flocloud_state.relog_token = "old-account-token"
  flocloud_state.command_queue[1] = { cmd_id = "old", slot = 2001, valve_id = "11", name = "x", fields = {} }
  Properties.Email = "new@example.invalid"
  OnPropertyChanged("Email")
  T.check_equal(flocloud_state.relog_token, "", "account token cleared")
  T.check_equal(env.saved.flocloud_relog, "", "persisted token cleared")
  T.check_equal(#flocloud_state.command_queue, 0, "queued valve work cancelled")
  T.check_equal(Properties.Connection, "Refreshing configuration", "refresh published")
  local nacks = sends_to(env, 2001, Link.MSG_CMD_NACK)
  T.check_equal(#nacks, 1, "cancelled job nacked so the valve settles")
  T.check_equal(Link.parse(nacks[1].params).error_reason, "cancelled", "cancel reason")
  OnDriverDestroyed()
end)

T.test("cloud: slice builder validates and normalizes valve data", function()
  local slice, err = flocloud_build_slice(make_valve(), { valveId = 11, notificationsList = 64 }, 1757200000)
  T.check(err == nil, "valid valve builds, got " .. tostring(err))
  T.check_equal(slice.id, "11", "numeric id stringified")
  T.check_equal(slice.online, true, "online boolean")
  T.check_equal(slice.access, 64, "access row attached")
  T.check_equal(slice.updated, 1757200000, "snapshot time attached")
  local ok, perr = Link.parse_state_body(Link.build_state_body(slice))
  T.check(ok ~= nil, "slice passes link validation, got " .. tostring(perr))
  local bad, berr = flocloud_build_slice({ id = 11 }, nil, 0)
  T.check(bad == nil and berr == "bad-valve", "mode-less valve rejected")
  local bad_id, iderr = flocloud_build_slice(make_valve({ id = "" }), nil, 0)
  T.check(bad_id == nil and iderr == "bad-valve", "id-less valve rejected")
end)

T.test("cloud: action vocabulary maps modes and ranges", function()
  local fields = flocloud_action_fields({ action = "mode_shutoff" })
  T.check_equal(fields.mode, 8, "shutoff value")
  fields = flocloud_action_fields({ action = "mode_home" })
  T.check_equal(fields.mode, 1, "home value")
  fields = flocloud_action_fields({ action = "home_limit", value = 30 })
  T.check_equal(fields.homeIntervalTime, 30, "home limit mapped")
  fields = flocloud_action_fields({ action = "away_limit", value = 0.5 })
  T.check_equal(fields.awayIntervalTime, 0.5, "fractional away limit kept")
  local _, unknown = flocloud_action_fields({ action = "nope" })
  T.check_equal(unknown, "unknown-action", "unknown action named")
  local _, bad_range = flocloud_action_fields({ action = "home_limit", value = 1.5 })
  T.check_equal(bad_range, "bad-param:value", "fractional home limit rejected")
  local _, missing = flocloud_action_fields({ action = "home_limit" })
  T.check_equal(missing, "bad-param:value", "missing value rejected")
  local _, not_table = flocloud_action_fields(nil)
  T.check_equal(not_table, "bad-action", "nil body rejected")
end)

T.test("cloud: action tables resolve", function()
  -- Guards flocloud_action_fields: every mode action must name a real
  -- mode value and every value action a complete range spec, so no
  -- table drift can turn a valid command into an empty write.
  for action, mode in pairs(FLOCLOUD_MODE_ACTIONS) do
    T.check(FloModel.VALVE_MODES[mode] ~= nil, action .. " resolves to a mode value")
  end
  for action, spec in pairs(FLOCLOUD_VALUE_ACTIONS) do
    T.check(
      type(spec.field) == "string" and type(spec.min) == "number" and type(spec.max) == "number",
      action .. " spec complete"
    )
  end
end)

T.test("cloud: identical cmd_ids on two slots ack independently (H3)", function()
  local env = boot(cloud_env())
  local v1 = make_valve()
  local v2 = make_valve({ id = 22, uuid = "uuid-2", valveFriendlyName = "Garden" })
  discover(env, { v1, v2 }, {})
  -- Hold both settlements so the two same-id commands overlap in flight,
  -- the way a close-all-valves scene issues them within one second.
  local settlers = {}
  flocloud_command_send = function(job, settled)
    env.send_calls[#env.send_calls + 1] = job
    settlers[#settlers + 1] = settled
  end
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("same-id", "mode_home"))
  ReceivedFromProxy(2002, "FLOGIC_COMMAND", Link.build_command("same-id", "mode_away"))
  T.check_equal(#env.send_calls, 1, "first command executes while the second queues")
  settlers[1]()
  T.check_equal(#sends_to(env, 2001, Link.MSG_CMD_ACK), 1, "slot 2001 acked")
  T.check_equal(#env.send_calls, 2, "second command executes after the first settles")
  settlers[2]()
  T.check_equal(#sends_to(env, 2002, Link.MSG_CMD_ACK), 1, "slot 2002 acked despite the shared id")
  OnDriverDestroyed()
end)

T.test("cloud: restore keeps the map when re-add fails, Lua reload (H4)", function()
  local env = boot(cloud_env())
  local v2 = make_valve({ id = 22, uuid = "uuid-2", valveFriendlyName = "Garden" })
  discover(env, { make_valve(), v2 }, {})
  T.check(env.saved.flocloud_slots ~= nil, "map persisted")
  OnDriverDestroyed()
  env.bindings = {}
  env.proxy_sends = {}
  -- A Lua reload (driver update) keeps Director-side runtime bindings, so
  -- re-adding the same id may fail: the map must survive anyway. Two
  -- valves so the dynamic slot (2002) exercises the failing re-add; the
  -- static slot (2001) never re-adds.
  local real_add = C4.AddDynamicBinding
  function C4:AddDynamicBinding(_id)
    error("already exists")
  end
  OnDriverLateInit("test")
  C4.AddDynamicBinding = real_add
  T.check_equal(flocloud_state.valve_slots["11"], 2001, "static map kept")
  T.check_equal(flocloud_state.valve_slots["22"], 2002, "dynamic map kept despite re-add failure")
  ReceivedFromProxy(2002, "FLOGIC_HELLO", Link.build_hello())
  T.check_equal(#sends_to(env, 2002, Link.MSG_IDENTITY), 1, "restored slot still answers hello")
  OnDriverDestroyed()
end)

T.test("cloud: departed slot is reused only after explicit unbind (M1)", function()
  local env = boot(cloud_env())
  -- Fill every slot: 16 valves take 2001-2016, so reuse (not a fresh
  -- slot) is the only way a newcomer can ever land.
  local valves = {}
  for i = 1, 16 do
    valves[i] = make_valve({ id = 100 + i, uuid = "uuid-" .. i, valveFriendlyName = "V" .. i })
  end
  discover(env, valves, {})
  -- 2001 is the static manifest provider; the other 15 are dynamic.
  T.check_equal(#env.bindings, 15, "all dynamic slots consumed")
  -- Valve 101 leaves; its slot goes unavailable but keeps the link.
  local remaining = {}
  for i = 2, 16 do
    remaining[#remaining + 1] = valves[i]
  end
  script_account(env, remaining, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.slots[2001].available, false, "slot marked unavailable")
  -- Bound-state unknown (never observed): the slot is not offered.
  T.check_equal(flocloud_find_free_slot(), nil, "unobserved link not stolen")
  -- Explicit unbind observed: the slot recycles for the next newcomer,
  -- even when re-add fails (the Director binding already exists).
  OnBindingChanged(2001, "FLOGIC_VALVE", false)
  T.check_equal(flocloud_find_free_slot(), 2001, "unbound slot offered for reuse")
  local newcomer = make_valve({ id = 200, uuid = "uuid-new", valveFriendlyName = "New" })
  local with_newcomer = { newcomer }
  for _, valve in ipairs(remaining) do
    with_newcomer[#with_newcomer + 1] = valve
  end
  local real_add = C4.AddDynamicBinding
  function C4:AddDynamicBinding(_id)
    error("exists")
  end
  script_account(env, with_newcomer, {})
  flocloud_poll_now()
  C4.AddDynamicBinding = real_add
  T.check_equal(flocloud_state.valve_slots["200"], 2001, "unbound slot reused without re-add")
  T.check_equal(flocloud_state.valve_slots["101"], nil, "departed reverse mapping cleared")
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_HELLO", Link.build_hello())
  local identities = sends_to(env, 2001, Link.MSG_IDENTITY)
  T.check_equal(#identities, 1, "reused slot answers hello")
  T.check_equal(Link.parse(identities[1].params).valve_id, "200", "reused slot names the new valve")
  -- A still-bound departed link is never stolen: observe 2002 bound,
  -- remove its valve, and confirm a second newcomer finds no slot.
  OnBindingChanged(2002, "FLOGIC_VALVE", true)
  local remaining2 = {}
  for _, valve in ipairs(with_newcomer) do
    if valve.id ~= 102 then
      remaining2[#remaining2 + 1] = valve
    end
  end
  local newcomer2 = make_valve({ id = 201, uuid = "uuid-new2", valveFriendlyName = "New2" })
  remaining2[#remaining2 + 1] = newcomer2
  script_account(env, remaining2, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.slots[2002].available, false, "second slot marked unavailable")
  T.check_equal(flocloud_state.valve_slots["201"], nil, "bound departed link not stolen")
  OnDriverDestroyed()
end)

T.test("cloud: unbind retires the slot's queued and pending work (L5)", function()
  local env = boot(cloud_env())
  local v1 = make_valve()
  local v2 = make_valve({ id = 22, uuid = "uuid-2", valveFriendlyName = "Garden" })
  discover(env, { v1, v2 }, {})
  local settlers = {}
  flocloud_command_send = function(job, settled)
    env.send_calls[#env.send_calls + 1] = job
    settlers[#settlers + 1] = settled
  end
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-1", "mode_home"))
  ReceivedFromProxy(2002, "FLOGIC_COMMAND", Link.build_command("run-2", "mode_home"))
  T.check_equal(#flocloud_state.command_queue, 1, "second command queued behind the first")
  OnBindingChanged(2001, "FLOGIC_VALVE", false)
  T.check_equal(#flocloud_state.command_queue, 1, "queue keeps the surviving slot only")
  T.check_equal(flocloud_state.command_queue[1].slot, 2002, "only the unbound slot purged")
  T.check(flocloud_state.pending_commands[2001] == nil, "unbound pending cleared")
  settlers[1]()
  T.check_equal(#sends_to(env, 2001, Link.MSG_CMD_ACK), 0, "late completion skips the dead slot")
  T.check_equal(#env.send_calls, 2, "surviving job still executes")
  settlers[2]()
  T.check_equal(#sends_to(env, 2002, Link.MSG_CMD_ACK), 1, "surviving job acked")
  OnDriverDestroyed()
end)
