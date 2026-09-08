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
    removed = {},
    proxy_sends = {},
    device_sends = {},
    consumers = {},
    saved = {},
    events = {},
    proxy_fail = false,
    fetch_calls = {},
    send_calls = {},
    binding_clears = {},
    net_connections = {},
    net_connects = {},
    net_disconnects = {},
    net_sends = {},
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
  function C4:RemoveDynamicBinding(id)
    env.removed[#env.removed + 1] = id
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
    if env.consumers_fail then
      error("no discovery")
    end
    return env.consumers[binding]
  end
  function C4:SetBindingAddress(id, address)
    if env.binding_clear_fail then
      error("clear failed")
    end
    env.binding_clears[#env.binding_clears + 1] = { id = id, address = address }
  end
  function C4:GetBindingAddress(_id)
    return ""
  end
  function C4:CreateNetworkConnection(id, host, kind)
    env.net_connections[#env.net_connections + 1] = { id = id, host = host, kind = kind }
  end
  function C4:NetPortOptions(_id, _port, _kind, _opts) end
  function C4:NetConnect(id, port)
    env.net_connects[#env.net_connects + 1] = { id = id, port = port }
  end
  function C4:NetDisconnect(id, port)
    env.net_disconnects[#env.net_disconnects + 1] = { id = id, port = port }
  end
  function C4:SendToNetwork(id, port, data)
    env.net_sends[#env.net_sends + 1] = { id = id, port = port, data = data }
  end
  function C4:FireEvent(name)
    env.events[#env.events + 1] = name
  end
  function C4:PersistGetValue(key)
    -- Director answers a missing key with zero values, not nil: model
    -- that, so nested-call crashes (tonumber of nothing raises) fail
    -- here instead of only in the field.
    if env.saved[key] == nil then
      return
    end
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
  T.check_equal(FLOCLOUD_DRIVER_VERSION, "2026090815", "cloud version")
  T.check_equal(FLOGIC_LINK_VERSION, 1, "protocol version is 1")
  T.check_equal(FloUpdate.ASSET, "flologic_cloud.c4z", "updater tracks the cloud package")
  T.check_equal(FloUpdate.FAMILY_ASSETS[1], "flologic_cloud.c4z", "updater requires its own package")
  T.check_equal(FloUpdate.FAMILY_ASSETS[2], "flologic_water_valve.c4z", "updater requires the valve sibling")
  T.check(flocloud_selection == nil, "no single-valve selection helper")
  T.check(FLOCLOUD_PROP_PICKER == nil, "no picker property constant")
  T.check(FLOCLOUD_PROP_OVERRIDE == nil, "no override property constant")
  local body = JSON.encode({
    {
      tag_name = "c4-v2026090809",
      draft = false,
      prerelease = false,
      assets = {
        {
          name = "flologic_cloud.c4z",
          browser_download_url = "https://github.com/psaab/flologic_HA/releases/download/c4-v2026090809/flologic_cloud.c4z",
        },
        {
          name = "flologic_water_valve.c4z",
          browser_download_url = "https://github.com/psaab/flologic_HA/releases/download/c4-v2026090809/flologic_water_valve.c4z",
        },
      },
    },
    {
      -- Newer tag but missing the valve sibling: not a valid lockstep
      -- release, so the older complete release wins.
      tag_name = "c4-v2026090812",
      draft = false,
      prerelease = false,
      assets = {
        {
          name = "flologic_cloud.c4z",
          browser_download_url = "https://github.com/psaab/flologic_HA/releases/download/c4-v2026090812/flologic_cloud.c4z",
        },
      },
    },
  })
  local release = FloUpdate.select_release(JSON.decode(body))
  T.check(release ~= nil, "cloud asset selected")
  T.check_equal(release.version, "2026090809", "incomplete newer release skipped")
  T.check(release.url:find("flologic_cloud.c4z", 1, true) ~= nil, "cloud asset url")
end)

T.test("cloud: discovery creates one dynamic binding per valve", function()
  local env = boot(cloud_env())
  T.check_equal(env.timers.pending_count(), 5, "poll, reconcile, soon, and update timers")
  local v1, v2 = make_valve(), make_valve({ id = 22, uuid = "uuid-2", valveFriendlyName = "Garden" })
  discover(env, { v1, v2 }, { { valveId = 11, notificationsList = 64 } })
  -- Every link is dynamic and carries its valve name (lowest free first).
  T.check_equal(#env.bindings, 2, "two dynamic bindings")
  T.check_equal(env.bindings[1].id, 2001, "first valve takes 2001")
  T.check_equal(env.bindings[1].name, "Kitchen", "first link shows valve 11")
  T.check_equal(env.bindings[2].id, 2002, "second valve takes 2002")
  T.check_equal(env.bindings[2].name, "Garden", "second link shows valve 22")
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
  T.check_equal(#env.bindings, 2, "stable map adds no bindings")
  -- A departed valve marks its slot unavailable without deleting it.
  script_account(env, { v1 }, {})
  flocloud_poll_now()
  T.check_equal(#env.bindings, 2, "removed slot is never deleted")
  T.check_equal(flocloud_state.slots[2002].available, false, "removed slot unavailable")
  T.check_equal(Properties["Valve Count"], "1", "count tracks the account")
  -- The valve returns: same slot resumes without a new binding.
  script_account(env, { v1, v2 }, {})
  flocloud_poll_now()
  T.check_equal(#env.bindings, 2, "returning valve reuses its slot")
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
  env.consumers[2001] = { [55] = "Upstairs Valve" }
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
  -- Hintless fallback with exactly one bound consumer attributes by
  -- elimination over the live binding relationship (single-valve
  -- bootstrap when the proxy leg is broken).
  local count = #env.device_sends
  ExecuteCommand("FLOGIC_HELLO", Link.build_hello())
  T.check_equal(#env.device_sends, count + 2, "single-consumer hintless hello answered")
  T.check_equal(env.device_sends[count + 1].command, "FLOGIC_IDENTITY", "attributed to the live slot")
  -- Ambiguous fallback traffic is dropped: two consumers, no elimination.
  env.consumers[2001] = { [55] = "Upstairs Valve", [56] = "Downstairs Valve" }
  count = #env.device_sends
  ExecuteCommand("FLOGIC_HELLO", Link.build_hello())
  T.check_equal(#env.device_sends, count, "ambiguous hintless fallback dropped")
  -- Indeterminate lookups disqualify attribution too.
  env.consumers_fail = true
  ExecuteCommand("FLOGIC_HELLO", Link.build_hello())
  T.check_equal(#env.device_sends, count, "indeterminate lookup drops hintless fallback")
  env.consumers_fail = false
  ExecuteCommand("Bogus Programming Command", {})
  T.check_equal(#env.device_sends, count, "unknown commands still ignored")
  env.proxy_fail = false
  OnDriverDestroyed()
end)

T.test("cloud: consumer discovery decodes Director id-name maps", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  env.proxy_fail = true
  -- A numeric device NAME must never become a device id: decode by key.
  env.consumers[2001] = { [55] = "1234" }
  env.device_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_HELLO", Link.build_hello())
  T.check(#env.device_sends >= 1, "fallback still routes with a numeric name")
  T.check_equal(env.device_sends[1].id, 55, "fallback targets the key, never the name")
  -- An empty map is an observed-unbound binding, not a lookup failure.
  env.consumers[2001] = {}
  env.device_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_HELLO", Link.build_hello())
  T.check_equal(#env.device_sends, 0, "empty map sends to nobody")
  OnBindingChanged(2001, "FLOGIC_VALVE", true)
  flocloud_reconcile_bindings()
  T.check_equal(flocloud_state.slots[2001].bound, false, "empty map marks unbound")
  -- A failed lookup keeps the previous flag rather than flapping.
  OnBindingChanged(2001, "FLOGIC_VALVE", true)
  env.consumers_fail = true
  flocloud_reconcile_bindings()
  T.check_equal(flocloud_state.slots[2001].bound, true, "failed lookup keeps the flag")
  env.consumers_fail = false
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
  T.check_equal(#env.bindings, 2, "both dynamic bindings re-created")
  T.check_equal(env.bindings[1].id, 2001, "first slot restored")
  T.check_equal(env.bindings[2].id, 2002, "second slot restored")
  T.check_equal(env.bindings[1].class, "FLOGIC_VALVE", "class restored")
  T.check_equal(flocloud_state.valve_slots["11"], 2001, "identity restored")
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
  -- re-adding the same id may fail: the map must survive anyway.
  local real_add = C4.AddDynamicBinding
  function C4:AddDynamicBinding(_id)
    error("already exists")
  end
  OnDriverLateInit("test")
  C4.AddDynamicBinding = real_add
  T.check_equal(flocloud_state.valve_slots["11"], 2001, "map kept despite re-add failure")
  T.check_equal(flocloud_state.valve_slots["22"], 2002, "map kept despite re-add failure")
  ReceivedFromProxy(2002, "FLOGIC_HELLO", Link.build_hello())
  T.check_equal(#sends_to(env, 2002, Link.MSG_IDENTITY), 1, "restored slot still answers hello")
  OnDriverDestroyed()
end)

T.test("cloud: departed slot is reused only after explicit unbind (M1)", function()
  local env = boot(cloud_env())
  -- Fill every slot: 16 valves take 2001-2016 lowest-first, so reuse
  -- (not a fresh slot) is the only way a newcomer can ever land.
  local valves = {}
  for i = 1, 16 do
    valves[i] = make_valve({ id = 100 + i, uuid = "uuid-" .. i, valveFriendlyName = "V" .. i })
  end
  discover(env, valves, {})
  T.check_equal(#env.bindings, 16, "all slots consumed")
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
  -- Explicit unbind observed: the slot recycles for the next newcomer.
  -- The binding is removed + re-added so the Connections view shows the
  -- new valve's name (Director has no rename API).
  OnBindingChanged(2001, "FLOGIC_VALVE", false)
  T.check_equal(flocloud_find_free_slot(), 2001, "unbound slot offered for reuse")
  -- The live re-check must observe zero consumers before reuse proceeds.
  env.consumers[2001] = {}
  local newcomer = make_valve({ id = 200, uuid = "uuid-new", valveFriendlyName = "New" })
  local with_newcomer = { newcomer }
  for _, valve in ipairs(remaining) do
    with_newcomer[#with_newcomer + 1] = valve
  end
  script_account(env, with_newcomer, {})
  flocloud_poll_now()
  T.check_equal(#env.removed, 1, "departed binding removed")
  T.check_equal(env.removed[1], 2001, "removed the reused slot")
  T.check_equal(env.bindings[#env.bindings].id, 2001, "slot re-added")
  T.check_equal(env.bindings[#env.bindings].name, "New", "re-added link shows the new valve")
  T.check_equal(flocloud_state.valve_slots["200"], 2001, "unbound slot reused")
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

local function fill_all_slots(env)
  -- 16 valves take 2001-2016, forcing reuse (never a fresh slot) for
  -- the next newcomer.
  local valves = {}
  for i = 1, 16 do
    valves[i] = make_valve({ id = 100 + i, uuid = "uuid-" .. i, valveFriendlyName = "V" .. i })
  end
  discover(env, valves, {})
  return valves
end

T.test("cloud: failed re-add after remove leaves the old entry for retry", function()
  local env = boot(cloud_env())
  local valves = fill_all_slots(env)
  local remaining = {}
  for i = 2, 16 do
    remaining[#remaining + 1] = valves[i]
  end
  script_account(env, remaining, {})
  flocloud_poll_now()
  OnBindingChanged(2001, "FLOGIC_VALVE", false)
  -- Explicit empty map: the live re-check observes zero consumers.
  env.consumers[2001] = {}
  local newcomer = make_valve({ id = 200, uuid = "uuid-new", valveFriendlyName = "New" })
  local real_add = C4.AddDynamicBinding
  function C4:AddDynamicBinding(_id)
    error("exists")
  end
  local arrived = { newcomer }
  for _, valve in ipairs(remaining) do
    arrived[#arrived + 1] = valve
  end
  script_account(env, arrived, {})
  flocloud_poll_now()
  C4.AddDynamicBinding = real_add
  -- Remove succeeded but re-add failed: the binding is gone, so the map
  -- must NOT point the newcomer at a nonexistent binding.
  T.check_equal(#env.removed, 1, "remove attempted")
  T.check_equal(flocloud_state.valve_slots["200"], nil, "newcomer not mapped without a binding")
  T.check_equal(flocloud_state.slots[2001].valve_id, "101", "old entry kept for retry")
  -- Next poll retries the whole remove + add and lands.
  script_account(env, arrived, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.valve_slots["200"], 2001, "retry maps the newcomer")
  OnDriverDestroyed()
end)

T.test("cloud: reuse vetoed when the slot rebound live", function()
  local env = boot(cloud_env())
  local valves = fill_all_slots(env)
  local remaining = {}
  for i = 2, 16 do
    remaining[#remaining + 1] = valves[i]
  end
  script_account(env, remaining, {})
  flocloud_poll_now()
  OnBindingChanged(2001, "FLOGIC_VALVE", false)
  -- The flag says unbound, but a live consumer is bound: the flag is
  -- stale, so the slot is vetoed — the old identity is preserved and
  -- the newcomer is never mapped onto a live Composer link.
  env.consumers[2001] = { [55] = "Upstairs Valve" }
  local newcomer = make_valve({ id = 200, uuid = "uuid-new", valveFriendlyName = "New" })
  local arrived = { newcomer }
  for _, valve in ipairs(remaining) do
    arrived[#arrived + 1] = valve
  end
  script_account(env, arrived, {})
  flocloud_poll_now()
  T.check_equal(#env.removed, 0, "live binding never removed")
  T.check_equal(flocloud_state.valve_slots["200"], nil, "newcomer never mapped onto a live link")
  T.check_equal(flocloud_state.slots[2001].valve_id, "101", "old identity preserved")
  T.check_equal(flocloud_state.slots[2001].bound, true, "stale flag refreshed to bound")
  OnDriverDestroyed()
end)

T.test("cloud: reuse vetoed when the binding lookup fails", function()
  local env = boot(cloud_env())
  local valves = fill_all_slots(env)
  local remaining = {}
  for i = 2, 16 do
    remaining[#remaining + 1] = valves[i]
  end
  script_account(env, remaining, {})
  flocloud_poll_now()
  OnBindingChanged(2001, "FLOGIC_VALVE", false)
  -- No live observation available: the slot is not reused.
  env.consumers_fail = true
  local newcomer = make_valve({ id = 200, uuid = "uuid-new", valveFriendlyName = "New" })
  local arrived = { newcomer }
  for _, valve in ipairs(remaining) do
    arrived[#arrived + 1] = valve
  end
  script_account(env, arrived, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.valve_slots["200"], nil, "newcomer not mapped without a live check")
  T.check_equal(flocloud_state.slots[2001].valve_id, "101", "old entry kept")
  T.check_equal(#env.removed, 0, "nothing removed without a live check")
  -- A later poll with a working lookup proceeds normally.
  env.consumers_fail = false
  env.consumers[2001] = {}
  script_account(env, arrived, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.valve_slots["200"], 2001, "retry maps once observed")
  OnDriverDestroyed()
end)

T.test("cloud: vetoed slot is skipped for the next safe candidate", function()
  local env = boot(cloud_env())
  local valves = fill_all_slots(env)
  local remaining = {}
  for i = 3, 16 do
    remaining[#remaining + 1] = valves[i]
  end
  script_account(env, remaining, {})
  flocloud_poll_now()
  OnBindingChanged(2001, "FLOGIC_VALVE", false)
  OnBindingChanged(2002, "FLOGIC_VALVE", false)
  -- 2001 rebound live (stale flag); 2002 is genuinely free.
  env.consumers[2001] = { [55] = "Upstairs Valve" }
  env.consumers[2002] = {}
  local newcomer = make_valve({ id = 200, uuid = "uuid-new", valveFriendlyName = "New" })
  local arrived = { newcomer }
  for _, valve in ipairs(remaining) do
    arrived[#arrived + 1] = valve
  end
  script_account(env, arrived, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.slots[2001].valve_id, "101", "vetoed slot keeps its valve")
  T.check_equal(flocloud_state.slots[2001].bound, true, "vetoed slot flag refreshed")
  T.check_equal(flocloud_state.valve_slots["200"], 2002, "newcomer takes the next safe slot")
  T.check_equal(#env.removed, 1, "only the safe slot rebound")
  T.check_equal(env.removed[1], 2002, "vetoed binding untouched")
  OnDriverDestroyed()
end)

T.test("cloud: uuid change quarantines the slot and re-places the valve", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  T.check_equal(flocloud_state.valve_slots["11"], 2001, "valve placed")
  -- Same numeric id, different immutable identity: a different valve.
  script_account(env, { make_valve({ uuid = "uuid-replacement" }) }, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.slots[2001].available, false, "conflicted slot quarantined")
  T.check_equal(flocloud_state.slots[2001].valve_id, "11", "quarantine keeps the old valve id")
  local slot = flocloud_state.valve_slots["11"]
  T.check(slot ~= nil and slot ~= 2001, "replacement re-placed on a new slot")
  T.check_equal(flocloud_state.slots[slot].available, true, "new slot available")
  T.check(flocloud_verify_slot(slot), "new slot verifies")
  T.check(not flocloud_verify_slot(2001), "quarantined slot never verifies")
  -- The old slot's commands fail; nothing executes for the wrong valve.
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("c-old", "mode_home"))
  T.check_equal(#sends_to(env, 2001, Link.MSG_CMD_NACK), 1, "quarantined slot nacks")
  T.check_equal(#flocloud_state.command_queue, 0, "quarantined command never queued")
  -- Next poll: stable, no duplicate placement.
  script_account(env, { make_valve({ uuid = "uuid-replacement" }) }, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.valve_slots["11"], slot, "mapping stable across polls")
  T.check_equal(flocloud_state.slots[2001].available, false, "quarantine persists")
  OnDriverDestroyed()
end)

T.test("cloud: restored map links but never writes before verification", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  OnDriverDestroyed()
  OnDriverLateInit("test")
  -- Restored map, no poll since restart: hello links, commands wait.
  flocloud_state.last_devices = nil
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_HELLO", Link.build_hello())
  T.check_equal(#sends_to(env, 2001, Link.MSG_IDENTITY), 1, "restored slot still answers hello")
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("c-early", "mode_home"))
  local nacks = sends_to(env, 2001, Link.MSG_CMD_NACK)
  T.check_equal(#nacks, 1, "unverified command nacked")
  T.check_equal(Link.parse(nacks[1].params).error_reason, "verifying", "nack names verification")
  T.check_equal(#flocloud_state.command_queue, 0, "no cloud write from an unverified map")
  -- The verifying poll authorizes the slot normally.
  script_account(env, { make_valve() }, {})
  flocloud_poll_now()
  T.check(flocloud_verify_slot(2001), "slot verified after poll")
  OnDriverDestroyed()
end)

T.test("cloud: account change drops cached authorization until re-verified", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  T.check(flocloud_verify_slot(2001), "slot verified before the change")
  Properties.Email = "someone@else.com"
  OnPropertyChanged("Email")
  T.check(flocloud_state.last_devices == nil, "cached inventory dropped")
  T.check(flocloud_state.last_slices[2001] == nil, "cached slice dropped")
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("c-stale", "mode_home"))
  local nacks = sends_to(env, 2001, Link.MSG_CMD_NACK)
  T.check_equal(#nacks, 1, "stale-account command nacked")
  T.check_equal(Link.parse(nacks[1].params).error_reason, "verifying", "nack names verification")
  -- Same physical valves on the new account keep their slots...
  script_account(env, { make_valve() }, {})
  flocloud_poll_now()
  T.check(flocloud_verify_slot(2001), "same uuid re-verifies in place")
  -- ...while a uuid change quarantines instead of adopting.
  script_account(env, { make_valve({ uuid = "uuid-other-account" }) }, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.slots[2001].available, false, "changed uuid quarantined")
  OnDriverDestroyed()
end)

T.test("cloud: valve removal publishes unavailable to the bound slot", function()
  local env = boot(cloud_env())
  local v1 = make_valve()
  local v2 = make_valve({ id = 22, uuid = "uuid-2", valveFriendlyName = "Garden" })
  discover(env, { v1, v2 }, {})
  OnBindingChanged(2001, "FLOGIC_VALVE", true)
  OnBindingChanged(2002, "FLOGIC_VALVE", true)
  env.proxy_sends = {}
  script_account(env, { v2 }, {})
  flocloud_poll_now()
  local unav = sends_to(env, 2001, Link.MSG_UNAVAILABLE)
  T.check_equal(#unav, 1, "removal publishes unavailable")
  T.check_equal(Link.parse(unav[1].params).valve_id, "11", "notice names the valve")
  T.check_equal(Link.parse(unav[1].params).error_reason, "left-account", "notice names the reason")
  T.check_equal(#sends_to(env, 2002, Link.MSG_UNAVAILABLE), 0, "healthy slot untouched")
  -- Transition published once, not every poll.
  env.proxy_sends = {}
  script_account(env, { v2 }, {})
  flocloud_poll_now()
  T.check_equal(#sends_to(env, 2001, Link.MSG_UNAVAILABLE), 0, "unavailable published once")
  -- Explicitly unbound slots have no listener and are skipped.
  OnBindingChanged(2002, "FLOGIC_VALVE", false)
  env.proxy_sends = {}
  script_account(env, {}, {})
  flocloud_poll_now()
  T.check_equal(#sends_to(env, 2002, Link.MSG_UNAVAILABLE), 0, "unbound slot skipped")
  OnDriverDestroyed()
end)

T.test("cloud: identity conflict publishes unavailable once", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  OnBindingChanged(2001, "FLOGIC_VALVE", true)
  env.proxy_sends = {}
  script_account(env, { make_valve({ uuid = "uuid-new" }) }, {})
  flocloud_poll_now()
  local unav = sends_to(env, 2001, Link.MSG_UNAVAILABLE)
  T.check_equal(#unav, 1, "conflict publishes unavailable")
  T.check_equal(Link.parse(unav[1].params).error_reason, "identity-conflict", "reason names the conflict")
  OnDriverDestroyed()
end)

T.test("cloud: hello on a stale slot notifies the peer", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  script_account(env, {}, {})
  flocloud_poll_now()
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_HELLO", Link.build_hello())
  local unav = sends_to(env, 2001, Link.MSG_UNAVAILABLE)
  T.check_equal(#unav, 1, "stale hello answered with unavailable")
  T.check_equal(#sends_to(env, 2001, Link.MSG_IDENTITY), 0, "no identity for a stale slot")
  OnDriverDestroyed()
end)

T.test("cloud: refresh replays cache and hurries one coalesced poll", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  local calls = #env.fetch_calls
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_GET_STATE", Link.build_get_state())
  T.check_equal(#sends_to(env, 2001, Link.MSG_STATE), 1, "cache replayed immediately")
  env.timers.advance(1500)
  T.check_equal(#env.fetch_calls, calls + 1, "one coalesced poll hurried")
  -- A second refresh inside the window replays cache but polls nothing new.
  ReceivedFromProxy(2001, "FLOGIC_GET_STATE", Link.build_get_state())
  env.timers.advance(1500)
  T.check_equal(#env.fetch_calls, calls + 1, "window coalesces refresh polls")
  -- After the window, refresh polls again.
  flocloud_state.refresh_poll_at = os.time() - FLOCLOUD_REFRESH_POLL_MIN_S - 1
  ReceivedFromProxy(2001, "FLOGIC_GET_STATE", Link.build_get_state())
  env.timers.advance(1500)
  T.check_equal(#env.fetch_calls, calls + 2, "poll resumes after the window")
  OnDriverDestroyed()
end)

T.test("cloud: queued commands expire before transmit past the deadline", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  local held = nil
  flocloud_command_send = function(job, settled)
    env.send_calls[#env.send_calls + 1] = job
    held = settled
  end
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-1", "mode_home"))
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-2", "mode_away"))
  T.check_equal(#flocloud_state.command_queue, 1, "second command queued")
  -- Age the queued job past the transmit deadline, then settle the first.
  flocloud_state.command_queue[1].enqueued_at = os.time() - FLOCLOUD_COMMAND_DEADLINE_S - 1
  held()
  local nacks = sends_to(env, 2001, Link.MSG_CMD_NACK)
  T.check_equal(#nacks, 1, "stale job nacked")
  T.check_equal(Link.parse(nacks[1].params).error_reason, "expired", "expiry reason")
  T.check_equal(#env.send_calls, 1, "expired job never transmitted")
  T.check_equal(#sends_to(env, 2001, Link.MSG_CMD_ACK), 1, "live job acked")
  T.check(flocloud_state.pending_commands[2001]["run-2"] == nil, "expired pending cleared")
  OnDriverDestroyed()
end)

T.test("cloud: a poll due during a command runs before the next command", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  local settlers = {}
  flocloud_command_send = function(job, settled)
    env.send_calls[#env.send_calls + 1] = job
    settlers[#settlers + 1] = settled
  end
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-1", "mode_home"))
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-2", "mode_away"))
  local calls = #env.fetch_calls
  -- A poll comes due while the first command executes: remembered, not dropped.
  flocloud_poll_now()
  T.check(flocloud_state.poll_overdue, "due poll remembered")
  T.check_equal(#env.fetch_calls, calls, "no poll while busy")
  -- Hold the due poll open to prove ordering: poll first, command after.
  local release_poll = nil
  flocloud_account_fetch = function(hub, cb)
    env.fetch_calls[#env.fetch_calls + 1] = { hub = hub }
    release_poll = function()
      cb(nil, { user = { id = 7 }, devices = { make_valve() }, accesses = {} })
    end
  end
  settlers[1]()
  T.check_equal(#env.fetch_calls, calls + 1, "due poll started first")
  T.check_equal(#env.send_calls, 1, "second command waits while the poll runs")
  release_poll()
  T.check_equal(#env.send_calls, 2, "queued command runs after the poll settles")
  OnDriverDestroyed()
end)

T.test("cloud: open breaker rejects commands at admission", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  flocloud_state.cb_open_until = os.time() + 300
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-1", "mode_home"))
  local nacks = sends_to(env, 2001, Link.MSG_CMD_NACK)
  T.check_equal(#nacks, 1, "cooling-down command nacked")
  T.check_equal(Link.parse(nacks[1].params).error_reason, "cooling-down", "explicit status")
  T.check_equal(#flocloud_state.command_queue, 0, "nothing queued during cooldown")
  T.check_equal(#env.send_calls, 0, "no session during cooldown")
  -- After cooldown, admission resumes.
  flocloud_state.cb_open_until = 0
  script_send(env, nil)
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-2", "mode_home"))
  T.check_equal(#env.send_calls, 1, "admission resumes after cooldown")
  OnDriverDestroyed()
end)

T.test("cloud: breaker opening fails already-queued commands fast", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  local held = nil
  flocloud_command_send = function(job, settled)
    env.send_calls[#env.send_calls + 1] = job
    held = settled
  end
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-1", "mode_home"))
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-2", "mode_away"))
  flocloud_state.cb_failures = 4
  env.proxy_sends = {}
  held("transport-99")
  T.check(flocloud_breaker_open(), "breaker opened")
  local nacks = sends_to(env, 2001, Link.MSG_CMD_NACK)
  T.check_equal(#nacks, 2, "both jobs settled")
  T.check_equal(Link.parse(nacks[2].params).error_reason, "cooling-down", "queued job failed fast")
  T.check_equal(#env.send_calls, 1, "queued job never transmitted during cooldown")
  T.check_equal(#flocloud_state.command_queue, 0, "queue drained")
  OnDriverDestroyed()
end)

T.test("cloud: credential change resets the breaker for the new regime", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  flocloud_state.cb_failures = 5
  flocloud_state.cb_open_until = os.time() + 300
  T.check(flocloud_breaker_open(), "breaker open before the change")
  Properties.Email = "fixed@example.com"
  OnPropertyChanged("Email")
  T.check_equal(flocloud_state.cb_failures, 0, "failure count reset")
  T.check(not flocloud_breaker_open(), "cooldown cleared for new credentials")
  script_account(env, { make_valve() }, {})
  flocloud_poll_now()
  script_send(env, nil)
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-1", "mode_home"))
  T.check_equal(#env.send_calls, 1, "commands admit under the new credentials")
  OnDriverDestroyed()
end)

T.test("cloud: corrupt valve mode skips the slice without sinking the poll", function()
  local env = boot(cloud_env())
  local bad = make_valve()
  bad.mode = -1
  discover(env, { bad }, {})
  T.check_equal(flocloud_state.valve_slots["11"], 2001, "valve still placed")
  T.check_equal(#sends_to(env, 2001, Link.MSG_STATE), 0, "no slice for a corrupt mode")
  T.check_equal(flocloud_state.last_slices[2001], nil, "nothing cached")
  -- Recovery when the cloud reports a sane mode again.
  script_account(env, { make_valve() }, {})
  flocloud_poll_now()
  T.check_equal(#sends_to(env, 2001, Link.MSG_STATE), 1, "slice resumes")
  OnDriverDestroyed()
end)

T.test("cloud: slice builder scrubs cosmetic strings and omits bad flow state", function()
  local env = boot(cloud_env())
  local slice = flocloud_build_slice({ id = 11, mode = 1, valveFriendlyName = "A\001B", flowState = -2 }, nil)
  T.check(slice ~= nil, "snapshot survives cosmetic garbage")
  T.check_equal(slice.name, "AB", "control chars stripped")
  T.check_equal(slice.flow_state, nil, "bad flow state omitted, not fatal")
  T.check(flocloud_build_slice({ id = 11, mode = 2.5 }, nil) == nil, "fractional mode fails the slice")
  T.check(flocloud_build_slice({ id = 11, mode = -1 }, nil) == nil, "negative mode fails the slice")
  OnDriverDestroyed()
end)

T.test("cloud: relog tokens harvest from any settled session", function()
  local env = boot(cloud_env())
  -- A rotated token persists even when the session later fails: login
  -- succeeded, so the rotation is real and must not be lost.
  flocloud_note_session_end({ relog_token = "fresh-token" }, "timeout:session")
  T.check_equal(flocloud_state.relog_token, "fresh-token", "rotation kept on failure")
  T.check_equal(env.saved.flocloud_relog, "fresh-token", "rotation persisted")
  -- Empty, missing, and unchanged harvests are no-ops.
  flocloud_note_session_end({ relog_token = "" }, "timeout:session")
  flocloud_note_session_end(nil, "timeout:session")
  flocloud_note_session_end({ relog_token = "fresh-token" }, nil)
  T.check_equal(flocloud_state.relog_token, "fresh-token", "no-op harvests keep the token")
  -- Auth failure drops the persisted token: it may be the rejected
  -- credential, and the next session must log in fully.
  flocloud_note_session_end({ relog_token = "fresh-token" }, "auth")
  T.check_equal(flocloud_state.relog_token, "", "suspect token dropped")
  T.check_equal(env.saved.flocloud_relog, "", "drop persisted")
  OnDriverDestroyed()
end)

T.test("cloud: retired bindings drain on OFFLINE and survive clear failures", function()
  local env = boot(cloud_env())
  flocloud_state.retired_bindings = {}
  flocloud_state.retired_bindings[6100] = 443
  OnConnectionStatusChanged(6100, 443, "OFFLINE")
  T.check_equal(flocloud_state.retired_bindings[6100], nil, "drained id released")
  T.check_equal(#env.binding_clears, 1, "address cleared")
  -- A failing clear must not raise out of the entry point or wedge the map.
  flocloud_state.retired_bindings[6101] = 443
  env.binding_clear_fail = true
  OnConnectionStatusChanged(6101, 443, "OFFLINE")
  T.check_equal(flocloud_state.retired_bindings[6101], nil, "map clears despite failure")
  env.binding_clear_fail = false
  -- Wrong port or foreign events never drain.
  flocloud_state.retired_bindings[6102] = 443
  OnConnectionStatusChanged(6102, 444, "OFFLINE")
  OnConnectionStatusChanged(6102, 443, "ONLINE")
  T.check_equal(flocloud_state.retired_bindings[6102], 443, "mismatched events ignored")
  OnDriverDestroyed()
end)

T.test("cloud: pool exhaustion reclaims one undrained binding", function()
  local env = boot(cloud_env())
  flocloud_state.retired_bindings = {}
  T.check_equal(flocloud_reclaim_retired_binding(), nil, "nothing to reclaim")
  flocloud_state.retired_bindings[6100] = 443
  flocloud_state.retired_bindings[6101] = 443
  local freed = flocloud_reclaim_retired_binding()
  T.check(freed == 6100 or freed == 6101, "one id freed")
  T.check_equal(#env.binding_clears, 1, "freed address cleared")
  local left = 0
  for _ in pairs(flocloud_state.retired_bindings) do
    left = left + 1
  end
  T.check_equal(left, 1, "only one reclaimed per call")
  OnDriverDestroyed()
end)

T.test("cloud: quarantine purges already-admitted work (R1)", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  local held = nil
  flocloud_command_send = function(job, settled)
    env.send_calls[#env.send_calls + 1] = job
    held = held or settled
    if #env.send_calls == 1 then
      return -- hold the first command open; the second queues behind it
    end
    settled()
  end
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-1", "mode_home"))
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-2", "mode_away"))
  T.check_equal(#flocloud_state.command_queue, 1, "second command queued")
  -- A poll comes due while run-1 executes; it runs first when run-1
  -- settles and quarantines the slot: the admitted-but-unsent run-2
  -- must die with the authorization.
  script_account(env, { make_valve({ uuid = "uuid-replacement" }) }, {})
  flocloud_poll_now()
  T.check(flocloud_state.poll_overdue, "due poll remembered while busy")
  held()
  T.check_equal(flocloud_state.slots[2001].available, false, "slot quarantined by the due poll")
  T.check_equal(#env.send_calls, 1, "purged job never transmitted")
  T.check_equal(#flocloud_state.command_queue, 0, "queue purged at quarantine")
  local nacks = sends_to(env, 2001, Link.MSG_CMD_NACK)
  T.check_equal(#nacks, 1, "purged job nacked")
  T.check_equal(Link.parse(nacks[1].params).error_reason, "identity-changed", "purge names the cause")
  T.check(flocloud_state.pending_commands[2001] == nil, "purged slot pending cleared")
  OnDriverDestroyed()
end)

T.test("cloud: left-account quarantine purges the slot's queued work (R1)", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  local held = nil
  flocloud_command_send = function(job, settled)
    env.send_calls[#env.send_calls + 1] = job
    if held == nil then
      held = settled
    else
      settled()
    end
  end
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-1", "mode_home"))
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-2", "mode_away"))
  env.proxy_sends = {}
  script_account(env, {}, {})
  flocloud_poll_now()
  held()
  T.check_equal(#env.send_calls, 1, "departed job never transmitted")
  local nacks = sends_to(env, 2001, Link.MSG_CMD_NACK)
  T.check_equal(Link.parse(nacks[#nacks].params).error_reason, "valve-unavailable", "departure purge reason")
  OnDriverDestroyed()
end)

T.test("cloud: dequeue revalidates dead authorizations (R1)", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  script_send(env, nil)
  -- A job whose slot went unavailable after admission dies at dequeue.
  script_account(env, {}, {})
  flocloud_poll_now()
  flocloud_state.command_queue[1] = {
    cmd_id = "dead-1",
    slot = 2001,
    valve_id = "11",
    name = "mode_home",
    fields = { mode = 1 },
    enqueued_at = os.time(),
  }
  flocloud_state.pending_commands[2001] = { ["dead-1"] = true }
  env.proxy_sends = {}
  flocloud_run_next()
  T.check_equal(#env.send_calls, 0, "dead job never transmitted")
  local nacks = sends_to(env, 2001, Link.MSG_CMD_NACK)
  T.check_equal(Link.parse(nacks[1].params).error_reason, "valve-unavailable", "dead slot nacked")
  -- A job admitted under a superseded scope dies as identity-changed.
  script_account(env, { make_valve() }, {})
  flocloud_poll_now()
  flocloud_state.command_queue[1] = {
    cmd_id = "dead-2",
    slot = 2001,
    valve_id = "11",
    name = "mode_home",
    fields = { mode = 1 },
    enqueued_at = os.time(),
    scope = "stale",
  }
  flocloud_state.pending_commands[2001] = { ["dead-2"] = true }
  env.proxy_sends = {}
  flocloud_run_next()
  nacks = sends_to(env, 2001, Link.MSG_CMD_NACK)
  T.check_equal(Link.parse(nacks[1].params).error_reason, "identity-changed", "stale scope nacked")
  T.check_equal(#env.send_calls, 0, "stale-scope job never transmitted")
  OnDriverDestroyed()
end)

T.test("cloud: jobs carry expected identity and deadline to the session (R1/R2)", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  script_send(env, nil)
  local before = os.time()
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-1", "mode_home"))
  local job = env.send_calls[1]
  T.check_equal(job.expected_uuid, "uuid-1", "expected identity carried")
  T.check(job.scope == flocloud_config_scope(), "admission scope carried")
  T.check(job.deadline_at - job.enqueued_at == FLOCLOUD_COMMAND_DEADLINE_S, "absolute deadline carried")
  T.check(job.enqueued_at >= before and job.enqueued_at <= os.time(), "enqueue stamp sane")
  OnDriverDestroyed()
end)

T.test("cloud: nil consumer lookup is observed-unbound, not failure (R7)", function()
  local env = boot(cloud_env())
  local valves = fill_all_slots(env)
  local remaining = {}
  for i = 2, 16 do
    remaining[#remaining + 1] = valves[i]
  end
  script_account(env, remaining, {})
  flocloud_poll_now()
  OnBindingChanged(2001, "FLOGIC_VALVE", false)
  -- No consumers entry at all: Director answered nil (documented
  -- no-bindings), so the live re-check observes zero consumers and the
  -- departed slot recycles — no veto, no stuck map.
  T.check(env.consumers[2001] == nil, "lookup answers nil")
  local newcomer = make_valve({ id = 200, uuid = "uuid-new", valveFriendlyName = "New" })
  local arrived = { newcomer }
  for _, valve in ipairs(remaining) do
    arrived[#arrived + 1] = valve
  end
  script_account(env, arrived, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.valve_slots["200"], 2001, "nil lookup recycles the departed slot")
  -- Slow reconciliation treats nil the same way.
  OnBindingChanged(2002, "FLOGIC_VALVE", true)
  T.check(env.consumers[2002] == nil, "second lookup answers nil")
  flocloud_reconcile_bindings()
  T.check_equal(flocloud_state.slots[2002].bound, false, "nil marks unbound")
  OnDriverDestroyed()
end)

T.test("cloud: snapshots carry ordering and the advertised budget (R3/R8)", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  T.check_equal(flocloud_state.link_epoch, 1, "first boot is epoch 1")
  local states = sends_to(env, 2001, Link.MSG_STATE)
  T.check_equal(#states, 1, "one fan-out slice")
  local first = Link.parse(states[1].params)
  T.check_equal(first.seq, 1, "fan-out consumes seq 1")
  T.check_equal(first.epoch, 1, "fan-out stamps the epoch")
  T.check_equal(first.fresh_s, 360, "default 60s poll advertises 360s")
  -- Second poll advances the sequence; the cache replay reuses it.
  script_account(env, { make_valve() }, {})
  flocloud_poll_now()
  states = sends_to(env, 2001, Link.MSG_STATE)
  T.check_equal(Link.parse(states[#states].params).seq, 2, "next poll advances the sequence")
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_GET_STATE", Link.build_get_state())
  states = sends_to(env, 2001, Link.MSG_STATE)
  T.check_equal(#states, 1, "cache replayed")
  T.check_equal(Link.parse(states[1].params).seq, 2, "replay reuses the sequence by design")
  -- Unavailability consumes the next sequence so it orders after states.
  env.proxy_sends = {}
  script_account(env, {}, {})
  flocloud_poll_now()
  local unav = sends_to(env, 2001, Link.MSG_UNAVAILABLE)
  T.check_equal(Link.parse(unav[1].params).seq, 3, "notice orders after the last snapshot")
  T.check_equal(Link.parse(unav[1].params).epoch, 1, "notice stamps the epoch")
  -- A restart bumps the epoch; sequences restart under it.
  OnDriverDestroyed()
  OnDriverLateInit("test")
  T.check_equal(flocloud_state.link_epoch, 2, "epoch strictly increases across restarts")
  script_account(env, { make_valve() }, {})
  flocloud_poll_now()
  states = sends_to(env, 2001, Link.MSG_STATE)
  local after = Link.parse(states[#states].params)
  T.check_equal(after.epoch, 2, "new boot stamps the new epoch")
  T.check_equal(after.seq, 1, "sequences restart under the new epoch")
  OnDriverDestroyed()
end)

T.test("cloud: freshness budget spans the whole poll range (R8)", function()
  local env = boot(cloud_env())
  local function budget_for(poll)
    Properties["Poll Interval"] = poll
    env.proxy_sends = {}
    script_account(env, { make_valve() }, {})
    flocloud_poll_now()
    local states = sends_to(env, 2001, Link.MSG_STATE)
    return Link.parse(states[#states].params).fresh_s
  end
  T.check_equal(budget_for("30"), 300, "fast poll clamps to the floor")
  T.check_equal(budget_for("60"), 360, "default poll advertises 360s")
  T.check_equal(budget_for("3600"), 10980, "hourly poll advertises three intervals plus a session")
  T.check_equal(budget_for("bogus"), 360, "garbage poll falls back to default")
  OnDriverDestroyed()
end)

T.test("cloud: hintless fallback attributes only the unique consumer (R11)", function()
  local env = boot(cloud_env())
  local v1 = make_valve()
  local v2 = make_valve({ id = 22, uuid = "uuid-2", valveFriendlyName = "Garden" })
  discover(env, { v1, v2 }, {})
  env.proxy_fail = true
  -- Two mapped slots, one live consumer: the hintless hello attributes
  -- to the occupied slot.
  env.consumers[2001] = { [55] = "Upstairs Valve" }
  env.consumers[2002] = {}
  env.device_sends = {}
  ExecuteCommand("FLOGIC_HELLO", Link.build_hello())
  T.check(#env.device_sends >= 1, "unique consumer attributed")
  T.check_equal(env.device_sends[1].id, 55, "reply targets the single consumer")
  -- A hint still wins over attribution: both slots occupied, the
  -- hinted slot answers its own consumer.
  env.consumers[2002] = { [56] = "Garden Valve" }
  local hello = Link.build_hello()
  hello[FLOCLOUD_K_FROM] = "22"
  env.device_sends = {}
  ExecuteCommand("FLOGIC_HELLO", hello)
  T.check(#env.device_sends >= 1, "hinted hello answered")
  T.check_equal(env.device_sends[1].id, 56, "hint routes to its own slot")
  -- Two live consumers: ambiguous, dropped.
  env.device_sends = {}
  ExecuteCommand("FLOGIC_HELLO", Link.build_hello())
  T.check_equal(#env.device_sends, 0, "ambiguous hintless hello dropped")
  env.proxy_fail = false
  OnDriverDestroyed()
end)

T.test("cloud: quarantined same-id slot reuses only after a live unbind check", function()
  local env = boot(cloud_env())
  local valves = fill_all_slots(env)
  -- Valve 101 is replaced at capacity: 2001 quarantines and the
  -- replacement finds no slot at all.
  local replaced = {}
  for _, valve in ipairs(valves) do
    if valve.id == 101 then
      replaced[#replaced + 1] = make_valve({ id = 101, uuid = "uuid-replacement", valveFriendlyName = "V1" })
    else
      replaced[#replaced + 1] = valve
    end
  end
  script_account(env, replaced, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.slots[2001].available, false, "old slot quarantined")
  T.check_equal(flocloud_state.valve_slots["101"], nil, "replacement unplaced at capacity")
  -- The quarantined slot reports unbound, but a live consumer is bound:
  -- the stale flag must not bypass the reuse guard for the same id.
  OnBindingChanged(2001, "FLOGIC_VALVE", false)
  env.consumers[2001] = { [55] = "Upstairs Valve" }
  script_account(env, replaced, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.slots[2001].valve_id, "101", "vetoed slot keeps its valve")
  T.check_equal(flocloud_state.slots[2001].bound, true, "vetoed slot flag refreshed")
  T.check_equal(flocloud_state.valve_slots["101"], nil, "same-id reuse vetoed on a live link")
  T.check_equal(#env.removed, 0, "live binding never removed")
  -- Genuinely unbound, the same-id slot recycles in place.
  OnBindingChanged(2001, "FLOGIC_VALVE", false)
  env.consumers[2001] = {}
  script_account(env, replaced, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.valve_slots["101"], 2001, "unbound same-id slot recycled")
  T.check(flocloud_verify_slot(2001), "recycled slot verifies")
  OnDriverDestroyed()
end)

T.test("cloud: cross-namespace ID-only records quarantine, uuid proves (scope)", function()
  local env = boot(cloud_env())
  local v1 = make_valve()
  v1.uuid = nil
  discover(env, { v1 }, {})
  T.check(flocloud_verify_slot(2001), "ID-only verifies within its namespace")
  -- Same numeric id on a different account without uuid proof: a
  -- different valve until proven otherwise — quarantine, no adoption.
  Properties.Email = "someone@else.com"
  OnPropertyChanged("Email")
  local v2 = make_valve()
  v2.uuid = nil
  script_account(env, { v2 }, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.slots[2001].available, false, "ID-only cross-namespace quarantined")
  T.check(not flocloud_verify_slot(2001), "quarantined slot never verifies")
  -- With the immutable uuid on both sides, the same move re-verifies.
  local env2 = boot(cloud_env())
  discover(env2, { make_valve() }, {})
  Properties.Email = "someone@else.com"
  OnPropertyChanged("Email")
  script_account(env2, { make_valve() }, {})
  flocloud_poll_now()
  T.check(flocloud_verify_slot(2001), "uuid-proven move re-verifies in place")
  OnDriverDestroyed()
end)

T.test("cloud: restart keeps ID-only slots within the same scope", function()
  local env = boot(cloud_env())
  local v1 = make_valve()
  v1.uuid = nil
  discover(env, { v1 }, {})
  OnDriverDestroyed()
  OnDriverLateInit("test")
  -- A restart is not a namespace change: the persisted scope matches,
  -- so the ID-only slot re-verifies instead of quarantining.
  local v2 = make_valve()
  v2.uuid = nil
  script_account(env, { v2 }, {})
  flocloud_poll_now()
  T.check_equal(flocloud_state.slots[2001].available, true, "ID-only slot kept after restart")
  T.check(flocloud_verify_slot(2001), "slot verifies after restart")
  OnDriverDestroyed()
end)

T.test("cloud: install grace without transmission reports a failure (R12)", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  local packet = FloUpdate.build_install_packet("flologic_cloud.c4z")
  local err_seen, calls = "unset", 0
  flocloud_soap_send(packet, function(err)
    calls = calls + 1
    err_seen = err
  end)
  local binding = flocloud_state.soap_binding
  T.check(binding ~= nil, "soap binding allocated")
  T.check_equal(#env.net_connects, 1, "connect attempted")
  -- No callback before grace expiry: the trigger never transmitted, so
  -- expiry reports a connection failure — never a sent trigger.
  env.timers.advance(3000)
  T.check_equal(calls, 1, "expiry settles the send")
  T.check_equal(err_seen, "cannot reach Composer endpoint", "untransmitted trigger is a failure")
  -- ONLINE transmits; a reply then settles success as before.
  err_seen, calls = "unset", 0
  flocloud_soap_send(packet, function(err)
    calls = calls + 1
    err_seen = err
  end)
  binding = flocloud_state.soap_binding
  OnConnectionStatusChanged(binding, FloUpdate.SOAP_PORT, "ONLINE")
  T.check_equal(#env.net_sends, 1, "packet transmitted on open")
  ReceivedFromNetwork(binding, FloUpdate.SOAP_PORT, "HTTP/1.1 200 OK")
  T.check_equal(calls, 1, "reply settles the send")
  T.check(err_seen == nil, "transmitted trigger settles success, got " .. tostring(err_seen))
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

-- Capture print output for one function, restoring print even on failure.
local function capture_print(fn)
  local saved = print
  local lines = {}
  print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring(select(i, ...))
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  local ok, err = pcall(fn)
  print = saved
  if not ok then
    error(err, 0)
  end
  return lines
end

local function printed(lines, pattern)
  for _, line in ipairs(lines) do
    if line:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

T.test("cloud: skip message distinguishes busy from not-ready", function()
  local env = boot(cloud_env())
  Properties[FLOCLOUD_PROP_DEBUG] = "On"
  -- Fresh busy: names the owner and its age.
  flocloud_account_fetch = function(hub, cb)
    env.fetch_calls[#env.fetch_calls + 1] = { hub = hub }
  end
  flocloud_poll_now()
  T.check(flocloud_state.busy, "held poll claims busy")
  local lines = capture_print(flocloud_poll_now)
  T.check(printed(lines, "poll skipped: session busy (poll "), "busy skip names the poll owner")
  T.check(flocloud_state.poll_overdue, "due poll remembered while busy")
  -- Uninitialized: a different message, no overdue flag.
  flocloud_state.initialized = false
  flocloud_state.poll_overdue = false
  lines = capture_print(flocloud_poll_now)
  T.check(printed(lines, "poll skipped: driver not ready"), "not-ready skip is distinct")
  T.check(not flocloud_state.poll_overdue, "no overdue flag while not ready")
  OnDriverDestroyed()
end)

T.test("cloud: busy watchdog clears a stuck poll and polls fresh", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  -- A hung transport: the seam records the poll but never calls back.
  local orphans = {}
  flocloud_account_fetch = function(hub, cb)
    env.fetch_calls[#env.fetch_calls + 1] = { hub = hub }
    orphans[#orphans + 1] = cb
  end
  flocloud_poll_now()
  T.check(flocloud_state.busy, "stuck poll holds busy")
  local calls = #env.fetch_calls
  -- Age past the watchdog and poll again: the orphan is force-cleared and
  -- a fresh poll starts in the same call.
  flocloud_state.busy_since = os.time() - FLOCLOUD_BUSY_WATCHDOG_S - 1
  local lines = capture_print(flocloud_poll_now)
  T.check(printed(lines, "busy watchdog: poll stuck"), "watchdog announces the stuck poll")
  T.check_equal(#env.fetch_calls, calls + 1, "fresh poll starts after the clear")
  T.check(flocloud_state.busy, "fresh poll holds busy")
  T.check_equal(flocloud_state.busy_what, "poll", "fresh claim re-stamps the owner")
  -- The orphan's late reply settles nothing: generation fenced.
  local devices_before = flocloud_state.last_devices
  orphans[1](nil, { user = { id = 7 }, devices = { make_valve({ id = 99 }) }, accesses = {} })
  T.check(flocloud_state.busy, "orphan reply does not clear the fresh poll")
  T.check(flocloud_state.last_devices == devices_before, "orphan account ignored")
  OnDriverDestroyed()
end)

T.test("cloud: busy watchdog nacks an orphaned command job", function()
  local env = boot(cloud_env())
  discover(env, { make_valve() }, {})
  local held = nil
  flocloud_command_send = function(job, settled)
    env.send_calls[#env.send_calls + 1] = job
    held = settled
  end
  env.proxy_sends = {}
  ReceivedFromProxy(2001, "FLOGIC_COMMAND", Link.build_command("run-1", "mode_home"))
  T.check(flocloud_state.busy, "command holds busy")
  T.check_equal(flocloud_state.busy_what, "command:mode_home", "busy names the command")
  -- Hang the send, age past the watchdog, then poll: the stuck job is
  -- nacked and the poll proceeds.
  flocloud_state.busy_since = os.time() - FLOCLOUD_BUSY_WATCHDOG_S - 1
  script_account(env, { make_valve() }, {})
  local calls = #env.fetch_calls
  local lines = capture_print(flocloud_poll_now)
  T.check(printed(lines, "busy watchdog: command:mode_home stuck"), "watchdog announces the stuck command")
  local nacks = sends_to(env, 2001, Link.MSG_CMD_NACK)
  T.check_equal(#nacks, 1, "orphaned job nacked")
  T.check_equal(Link.parse(nacks[1].params).error_reason, "stuck", "stuck reason")
  T.check(flocloud_state.pending_commands[2001]["run-1"] == nil, "orphaned pending cleared")
  T.check_equal(#env.fetch_calls, calls + 1, "poll proceeds after the clear")
  -- The orphan's late settle is fenced: no second ack.
  held()
  T.check_equal(#sends_to(env, 2001, Link.MSG_CMD_ACK), 0, "late settle sends no ack")
  OnDriverDestroyed()
end)

T.test("cloud: first boot without the epoch key initializes at epoch 1", function()
  -- The mock answers a missing key with zero values, like Director: a
  -- nested tonumber(PersistGetValue()) would raise here and abort
  -- LateInit before the runtime enables (0811/0812 field wedge).
  local env = boot(cloud_env())
  T.check(flocloud_state.initialized, "runtime enabled on first boot")
  T.check_equal(flocloud_state.link_epoch, 1, "epoch starts at 1")
  T.check_equal(env.saved[FLOCLOUD_PERSIST_EPOCH], "1", "epoch persisted")
  T.check_equal(Properties[FLOCLOUD_PROP_CONNECTION], "Initializing", "boot reaches connection setup")
  OnDriverDestroyed()
end)

T.test("cloud: restart with an existing epoch increments it", function()
  local env = cloud_env()
  env.saved[FLOCLOUD_PERSIST_EPOCH] = "5"
  boot(env)
  T.check(flocloud_state.initialized, "runtime enabled on restart")
  T.check_equal(flocloud_state.link_epoch, 6, "epoch strictly increases")
  T.check_equal(env.saved[FLOCLOUD_PERSIST_EPOCH], "6", "epoch re-persisted")
  OnDriverDestroyed()
end)
