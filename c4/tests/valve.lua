-- ============================================================================
-- c4/tests/valve.lua — valve-driver suite (scripted cloud peer).
--
-- Loaded by loader_valve.lua in its own Lua state (plan D8: bundles must
-- never share a state). Covers the VALVE-U4 identity decision, the
-- hello/identity handshake, full-state apply across all seven contacts,
-- Navigator click forwarding, programming commands, ack/nack
-- correlation, the SendToDevice fallback both directions, link-loss
-- behavior, and persist/restore. Lua 5.1 safe.
-- ============================================================================

local T = TestHelp
local Link = FloLogicLink

local LINK = 600
local LIGHT = 5001

local function valve_env()
  local timers = T.new_fake_timers()
  local env = {
    timers = timers,
    proxy_sends = {},
    device_sends = {},
    providers = { [77] = "FloLogic Cloud" },
    provider_lookup = true,
    saved = {},
    events = {},
    proxy_fail_link = false,
    net_connections = {},
    net_connects = {},
    net_disconnects = {},
    net_sends = {},
  }
  Properties = {
    ["Debug Mode"] = "Off",
    ["Update Check Interval"] = "24",
  }
  C4 = {}
  function C4:UpdateProperty(name, value)
    Properties[name] = value
  end
  function C4:SendToProxy(binding, command, params, kind)
    -- Models a broken peer-driver leg with a healthy light proxy: only
    -- the link binding raises, forcing the SendToDevice fallback.
    if env.proxy_fail_link and binding == LINK then
      error("link down")
    end
    env.proxy_sends[#env.proxy_sends + 1] = { binding = binding, command = command, params = params, kind = kind }
  end
  function C4:SendToDevice(id, command, params)
    env.device_sends[#env.device_sends + 1] = { id = id, command = command, params = params }
  end
  function C4:GetBoundProviderDevices(_, binding)
    if not env.provider_lookup then
      error("no discovery")
    end
    return env.providers
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
  function C4:url()
    local transfer = {}
    function transfer:SetOptions(_opts) end
    function transfer:OnDone(_cb) end
    function transfer:Get(_url, _headers) end
    function transfer:Post(_url, _body, _headers) end
    function transfer:Cancel() end
    return transfer
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
  return env
end

local function boot(env)
  OnDriverInit("test")
  OnDriverLateInit("test")
  return env
end

-- Inbound cloud->valve traffic over the primary leg.
local function from_cloud(env, envelope)
  ReceivedFromProxy(LINK, envelope[Link.K_MSG], envelope)
end

local function link_sends(env)
  local found = {}
  for _, send in ipairs(env.proxy_sends) do
    if send.binding == LINK then
      found[#found + 1] = send
    end
  end
  return found
end

local function hellos(env)
  local found = {}
  for _, send in ipairs(link_sends(env)) do
    if send.params[Link.K_MSG] == Link.MSG_HELLO then
      found[#found + 1] = send
    end
  end
  return found
end

local function commands_sent(env)
  local found = {}
  for _, send in ipairs(link_sends(env)) do
    if send.params[Link.K_MSG] == Link.MSG_COMMAND then
      found[#found + 1] = send
    end
  end
  return found
end

local function contact_sends(env, binding)
  local found = {}
  for _, send in ipairs(env.proxy_sends) do
    if send.binding == binding then
      found[#found + 1] = send.command
    end
  end
  return found
end

local function light_levels(env)
  local found = {}
  for _, send in ipairs(env.proxy_sends) do
    if send.binding == LIGHT and send.command == "LIGHT_LEVEL" then
      found[#found + 1] = send.params.LEVEL
    end
  end
  return found
end

local function handshake(env, id)
  id = id or "11"
  from_cloud(env, Link.build_identity(id))
end

local function push_state(env, state)
  from_cloud(env, Link.build_state(state))
end

local function check_list_equal(actual, expected, message)
  T.check_equal(#actual, #expected, message .. " (length)")
  for i = 1, #expected do
    T.check_equal(actual[i], expected[i], message .. " [" .. i .. "]")
  end
end

local function base_state(overrides)
  local state = { id = "11", mode = 1, online = true, name = "Kitchen", flow_state = 1 }
  if overrides ~= nil then
    for k, v in pairs(overrides) do
      state[k] = v
    end
  end
  return state
end

T.test("valve: version, link pin, updater asset, no selector (VALVE-U4)", function()
  valve_env()
  T.check_equal(FLOVALVE_DRIVER_VERSION, "2026090810", "valve version lockstep with cloud")
  T.check_equal(FLOGIC_LINK_VERSION, 1, "protocol version is 1")
  T.check_equal(FloUpdate.ASSET, "flologic_water_valve.c4z", "updater tracks the valve package")
  T.check_equal(FloUpdate.FAMILY_ASSETS[1], "flologic_cloud.c4z", "updater requires the cloud sibling")
  T.check_equal(FloUpdate.FAMILY_ASSETS[2], "flologic_water_valve.c4z", "updater requires its own package")
  T.check_equal(FLOVALVE_LINK_ID, 600, "static link id")
  T.check_equal(FLOVALVE_LIGHT_ID, 5001, "light proxy id")
  T.check_equal(FLOVALVE_LINK_CLASS, "FLOGIC_VALVE", "link class matches cloud slots")
  T.check(FLOVALVE_PROP_PICKER == nil, "no picker property constant")
  T.check(FLOVALVE_PROP_OVERRIDE == nil, "no override property constant")
  T.check(FLOVALVE_PROP_EMAIL == nil, "no credential property constant")
  T.check(FLOVALVE_PROGRAM_COMMANDS["Open Valve"] ~= nil, "Open Valve programming action")
  T.check(FLOVALVE_PROGRAM_COMMANDS["Close Valve"] ~= nil, "Close Valve programming action")
  T.check(FLOVALVE_PROGRAM_COMMANDS["Toggle"] ~= nil, "Toggle programming action")
end)

T.test("valve: bind handshakes, identity persists, rebind re-handshakes", function()
  local env = boot(valve_env())
  T.check_equal(#hellos(env), 1, "startup hello")
  T.check(flovalve_state.valve_id == nil, "no identity before handshake")
  handshake(env, "11")
  T.check_equal(flovalve_state.valve_id, "11", "identity learned")
  T.check_equal(env.saved["flovalve_valve_id"], "11", "identity persisted")
  T.check_equal(Properties["Valve ID"], "11", "identity displayed")
  -- One GET_STATE covers the race where the cloud had nothing cached.
  local get_state = 0
  for _, send in ipairs(link_sends(env)) do
    if send.params[Link.K_MSG] == Link.MSG_GET_STATE then
      get_state = get_state + 1
    end
  end
  T.check_equal(get_state, 1, "get-state after identity")
  -- Rebind clears the authoritative id and hellos again: the persisted
  -- id is never trusted across binds (plan D3).
  OnBindingChanged(LINK, "CONTROL", false)
  OnBindingChanged(LINK, "CONTROL", true)
  T.check_equal(#hellos(env), 2, "rebind re-handshakes")
  T.check(flovalve_state.valve_id == nil, "authoritative id cleared across binds")
  T.check_equal(env.saved["flovalve_valve_id"], "11", "persisted id kept for display only")
  -- Commands before the new handshake are dropped locally, never sent.
  local before = #commands_sent(env)
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  T.check_equal(#commands_sent(env), before, "no command without identity")
  T.check(Properties["Last Command"]:find("not linked") ~= nil, "drop is displayed")
  handshake(env, "11")
  T.check_equal(flovalve_state.valve_id, "11", "identity re-learned")
end)

T.test("valve: first state push reports steady contacts, display, and level", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  -- Steady-state sync on first push: STATE_* transitions nothing.
  check_list_equal(contact_sends(env, 101), { "STATE_OPENED" }, "101 valve closed steady open")
  check_list_equal(contact_sends(env, 102), { "STATE_OPENED" }, "102 away steady open")
  check_list_equal(contact_sends(env, 103), { "STATE_OPENED" }, "103 flowing steady open")
  check_list_equal(contact_sends(env, 104), { "STATE_OPENED" }, "104 leak steady open")
  check_list_equal(contact_sends(env, 105), { "STATE_OPENED" }, "105 warning steady open")
  check_list_equal(contact_sends(env, 106), { "STATE_OPENED" }, "106 critical steady open")
  check_list_equal(contact_sends(env, 107), { "STATE_CLOSED" }, "107 online steady closed")
  T.check_equal(Properties["Valve Name"], "Kitchen", "display name")
  T.check_equal(Properties["Mode"], "home", "mode status")
  T.check_equal(Properties["Water Flowing"], "No", "flow text")
  T.check_equal(Properties["Connection"], "Online", "link online")
  T.check(Properties["Last Link Update"] ~= "", "link timestamp set")
  check_list_equal(light_levels(env), { 100 }, "tile level 100 when water may flow")
  T.check_equal(#env.events, 0, "first push is the silent baseline")
end)

T.test("valve: contact truth table across all seven sensors", function()
  valve_env()
  local F = FloModel.VALVE_MODE_FLAGS
  local function values(mode, online, flow_state)
    return flovalve_contact_values({ mode = mode, online = online, flow_state = flow_state })
  end
  local home = values(1, true, 1)
  T.check(home[101] == false and home[107] == true, "home idle: open, online")
  T.check(values(8, true, 1)[101] == true, "shutoff closes 101")
  T.check(values(2, true, 1)[102] == true, "away closes 102")
  T.check(values(128, true, 1)[102] == true, "auto_away closes 102")
  T.check(values(1024, true, 1)[102] == true, "external_away closes 102")
  T.check(values(1, true, 4)[103] == true, "flow state 4 closes 103")
  T.check(values(1, false, 4)[103] == false, "offline never flows")
  T.check(values(1, true, 8)[103] == false, "valve-closed flow state never flows")
  T.check(values(1, true, nil)[103] == false, "missing flow state never flows")
  T.check(values(64, true, 1)[104] == true, "external_leak closes 104")
  T.check(values(32768, true, 1)[104] == true, "sensor_leak closes 104")
  T.check(values(F.change_battery, true, 1)[105] == true, "change_battery warns 105")
  T.check(values(F.updating, true, 1)[105] == true, "updating warns 105")
  T.check(values(F.error, true, 1)[106] == true, "error faults 106")
  T.check(values(F.system_down, true, 1)[106] == true, "system_down faults 106")
  T.check(values(F.valve_failure, true, 1)[106] == true, "valve_failure faults 106")
  T.check(values(1, false, 1)[107] == false, "offline opens 107")
  T.check(flovalve_contact_values(nil) == nil, "nil slice is unusable")
  T.check(flovalve_contact_values({ mode = "x", online = true }) == nil, "non-numeric mode is unusable")
  T.check(flovalve_contact_values({ mode = 8.5, online = true }) == nil, "fractional mode is unusable")
  T.check(flovalve_contact_values({ mode = -1, online = true }) == nil, "negative mode is unusable")
end)

T.test("valve: later pushes fire transitions and edge events only on change", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  local contacts_before = #env.proxy_sends
  push_state(env, base_state())
  T.check_equal(#env.proxy_sends, contacts_before + 1, "identical push only re-reports the tile level")
  push_state(env, base_state({ mode = 8 }))
  local sends101 = contact_sends(env, 101)
  T.check_equal(sends101[#sends101], "CLOSED", "101 transitions closed on shutoff")
  T.check_equal(Properties["Mode"], "shutoff", "mode tracks push")
  check_list_equal(light_levels(env), { 100, 100, 0 }, "tile level follows water-off")
  local saw_off, saw_mode = false, false
  for _, name in ipairs(env.events) do
    if name == "Water Off Detected" then
      saw_off = true
    end
    if name == "Mode Changed" then
      saw_mode = true
    end
  end
  T.check(saw_off, "water-off edge fired")
  T.check(saw_mode, "mode edge fired")
  push_state(env, base_state({ mode = 1, flow_state = 4 }))
  local sends103 = contact_sends(env, 103)
  T.check_equal(sends103[#sends103], "CLOSED", "103 transitions closed on flow")
  local saw_flow, saw_cleared = false, false
  for _, name in ipairs(env.events) do
    if name == "Flow Started" then
      saw_flow = true
    end
    if name == "Water Off Cleared" then
      saw_cleared = true
    end
  end
  T.check(saw_flow, "flow edge fired")
  T.check(saw_cleared, "water-off clear edge fired")
end)

T.test("valve: Navigator click sends open/close and reports optimistically", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  local sent = commands_sent(env)
  T.check_equal(#sent, 1, "click sends one command")
  local body = Link.parse(sent[1].params)
  T.check_equal(body.fields.action, "mode_shutoff", "off click issues shutoff")
  check_list_equal(light_levels(env), { 100, 0 }, "off click reports 0 immediately")
  ReceivedFromProxy(LIGHT, "DYNAMIC_ON", {})
  sent = commands_sent(env)
  local on_body = Link.parse(sent[#sent].params)
  T.check_equal(on_body.fields.action, "mode_home", "on click restores default home")
  check_list_equal(light_levels(env), { 100, 0, 100 }, "on click reports 100 immediately")
  -- Toggle follows the last reported level.
  ReceivedFromProxy(LIGHT, "TOGGLE", {})
  local toggle_body = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(toggle_body.fields.action, "mode_shutoff", "toggle from on closes")
  ReceivedFromProxy(LIGHT, "SET_BRIGHTNESS_TARGET", { LEVEL = 0 })
  local dim_body = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(dim_body.fields.action, "mode_shutoff", "level 0 closes")
  ReceivedFromProxy(LIGHT, "SET_BRIGHTNESS_TARGET", { LEVEL = 50 })
  local bright_body = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(bright_body.fields.action, "mode_home", "level > 0 opens")
  ReceivedFromProxy(LIGHT, "SET_BRIGHTNESS_TARGET", {})
  T.check_equal(#commands_sent(env), 5, "level-less brightness target sends nothing")
  ReceivedFromProxy(LIGHT, "BOGUS", {})
  T.check_equal(#commands_sent(env), 5, "unknown light command sends nothing")
end)

T.test("valve: open restores the last non-shutoff mode from pushes", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state({ mode = 2 }))
  ReceivedFromProxy(LIGHT, "DYNAMIC_ON", {})
  local body = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(body.fields.action, "mode_away", "on restores tracked away")
  -- Water-off pushes never overwrite the restore target.
  push_state(env, base_state({ mode = 8 }))
  ReceivedFromProxy(LIGHT, "DYNAMIC_ON", {})
  local still = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(still.fields.action, "mode_away", "shutoff push keeps restore target")
  T.check_equal(flovalve_state.restore_action, "mode_away", "restore target tracked")
end)

T.test("valve: rebinding to a different valve resets control history", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state({ mode = 2 }))
  T.check_equal(flovalve_state.restore_action, "mode_away", "restore target tracked")
  push_state(env, base_state({ mode = 8 }))
  T.check(flovalve_state.last_water_off, "water-off baseline latched")
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  T.check(next(flovalve_state.pending_commands) ~= nil, "command in flight")
  -- Mid-life slot rebinding: another valve's state arrives, the link
  -- re-handshakes, and the new identity must not inherit history.
  push_state(env, base_state({ id = "22", mode = 1 }))
  T.check(flovalve_state.valve_id == nil, "mismatch clears the authoritative id")
  handshake(env, "22")
  T.check_equal(flovalve_state.restore_action, "mode_home", "restore target reset to the safe default")
  T.check(flovalve_state.contact_states == nil, "contact baselines cleared")
  T.check(flovalve_state.last_mode == nil, "edge baselines cleared")
  T.check(flovalve_state.last_state == nil, "prior live state invalidated")
  T.check(next(flovalve_state.pending_commands) == nil, "old valve's pending dropped")
  -- The new valve is already shut off: its first push is a quiet
  -- baseline, and Open selects the default — never the old valve's mode.
  env.events = {}
  env.proxy_sends = {}
  push_state(env, base_state({ id = "22", mode = 8 }))
  T.check_equal(#env.events, 0, "first push of the new valve fires no edges")
  local sends101 = contact_sends(env, 101)
  T.check_equal(sends101[#sends101], "STATE_CLOSED", "first push syncs contacts quietly")
  ReceivedFromProxy(LIGHT, "DYNAMIC_ON", {})
  local body = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(body.fields.action, "mode_home", "open uses the safe default, not the old valve's mode")
end)

T.test("valve: same-valve re-link keeps baselines across a flap", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state({ mode = 2 }))
  OnBindingChanged(LINK, "CONTROL", false)
  OnBindingChanged(LINK, "CONTROL", true)
  handshake(env, "11")
  T.check_equal(flovalve_state.restore_action, "mode_away", "restore target survives a same-valve flap")
  T.check(flovalve_state.last_mode ~= nil, "edge baselines survive a same-valve flap")
  -- A genuine transition across the flap still fires (not swallowed by
  -- a spurious fresh baseline).
  env.events = {}
  push_state(env, base_state({ mode = 8 }))
  local sends101 = contact_sends(env, 101)
  T.check_equal(sends101[#sends101], "CLOSED", "transition (not silent sync) after same-valve re-link")
  local saw_off = false
  for _, name in ipairs(env.events) do
    if name == "Water Off Detected" then
      saw_off = true
    end
  end
  T.check(saw_off, "genuine transition across the flap still fires")
end)

T.test("valve: programming commands forward validated link actions", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  ExecuteCommand("LUA_ACTION", { ACTION = "Close Valve" })
  local body = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(body.fields.action, "mode_shutoff", "LUA_ACTION routes Close Valve")
  ExecuteCommand("Set Home Limit", { Minutes = "30" })
  local limited = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(limited.fields.action, "home_limit", "limit action name")
  T.check_equal(limited.fields.value, 30, "limit value forwarded")
  local before = #commands_sent(env)
  ExecuteCommand("Set Home Limit", { Minutes = "0" })
  T.check_equal(#commands_sent(env), before, "out-of-range value sends nothing")
  T.check(Properties["Last Command"]:find("rejected") ~= nil, "rejection is displayed")
  ExecuteCommand("Set Mode Away", {})
  local mode_body = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(mode_body.fields.action, "mode_away", "mode command forwards")
  ExecuteCommand("Refresh", {})
  local refresh = 0
  for _, send in ipairs(link_sends(env)) do
    if send.params[Link.K_MSG] == Link.MSG_GET_STATE then
      refresh = refresh + 1
    end
  end
  T.check(refresh >= 1, "Refresh asks the cloud for state")
  ExecuteCommand("Bogus Command", {})
  T.check_equal(#commands_sent(env), before + 1, "unknown command sends nothing")
end)

T.test("valve: ack/nack correlation settles commands without moving state", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  local first = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  from_cloud(env, Link.build_ack(first.cmd_id))
  T.check(Properties["Last Command"]:find("acknowledged") ~= nil, "ack is displayed")
  T.check_equal(Properties["Mode"], "home", "ack alone moves no state")
  ReceivedFromProxy(LIGHT, "DYNAMIC_ON", {})
  local second = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  from_cloud(env, Link.build_nack(second.cmd_id, "queue-full"))
  T.check(Properties["Last Command"]:find("rejected %(queue%-full%)") ~= nil, "nack reason is displayed")
  T.check_equal(Properties["Mode"], "home", "nack alone moves no state")
  -- Optimistic tile levels (100 push, 0 off-send, 100 on-send) roll back
  -- to the last confirmed state on nack instead of displaying the failed
  -- action until the next poll (M2).
  check_list_equal(light_levels(env), { 100, 0, 100, 100 }, "nack restores the confirmed tile level")
  T.check_equal(flovalve_state.last_level, 100, "level state rolled back")
  T.check_equal(flovalve_handle_link("FLOGIC_CMD_ACK", Link.build_ack("nope-1")), false, "unknown ack ignored")
end)

local function device_commands(env)
  local found = {}
  for _, send in ipairs(env.device_sends) do
    if send.command == "FLOGIC_COMMAND" then
      found[#found + 1] = send
    end
  end
  return found
end

T.test("valve: SendToDevice fallback both directions", function()
  local env = valve_env()
  env.proxy_fail_link = true
  boot(env)
  handshake(env, "11")
  push_state(env, base_state())
  T.check_equal(#link_sends(env), 0, "broken leg sends nothing via proxy")
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  local fallback = device_commands(env)
  T.check_equal(#fallback, 1, "command falls back to SendToDevice")
  T.check_equal(fallback[1].id, 77, "fallback targets the bound provider")
  local fallback_body = Link.parse(fallback[1].params)
  T.check_equal(fallback_body.fields.action, "mode_shutoff", "fallback keeps the action")
  T.check_equal(fallback[1].params["FLOGIC_FROM"], "11", "fallback carries the identity hint")
  -- Cloud-to-valve fallback arrives via ExecuteCommand under the message name.
  ExecuteCommand("FLOGIC_STATE", Link.build_state(base_state({ mode = 8 })))
  T.check_equal(Properties["Mode"], "shutoff", "fallback ingress applies state")
  ExecuteCommand("FLOGIC_IDENTITY", Link.build_identity("11"))
  T.check_equal(flovalve_state.valve_id, "11", "fallback ingress applies identity")
  -- Garbage on either leg warns and drops, never crashes.
  T.check_equal(flovalve_handle_link("FLOGIC_STATE", { nope = 1 }), false, "malformed envelope dropped")
  T.check_equal(flovalve_handle_link("FLOGIC_HELLO", Link.build_hello()), false, "misrouted message dropped")
  ExecuteCommand("Bogus", { nope = 1 })
end)

T.test("valve: provider discovery decodes Director maps and singular scalars", function()
  local env = valve_env()
  env.proxy_fail_link = true
  env.providers = { [77] = "1234" }
  boot(env)
  handshake(env, "11")
  push_state(env, base_state())
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  local fallback = device_commands(env)
  T.check_equal(#fallback, 1, "fallback routes with a numeric name")
  T.check_equal(fallback[1].id, 77, "provider key used, never the name")
  -- The singular provider API answers one scalar id.
  C4.GetBoundProviderDevices = nil
  function C4:GetBoundProviderDevice()
    return 78
  end
  env.device_sends = {}
  ReceivedFromProxy(LIGHT, "DYNAMIC_ON", {})
  fallback = device_commands(env)
  T.check_equal(#fallback, 1, "singular scalar routes")
  T.check_equal(fallback[1].id, 78, "singular scalar is the id")
  -- A failed lookup sends to nobody rather than guessing.
  function C4:GetBoundProviderDevice()
    error("no discovery")
  end
  env.device_sends = {}
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  T.check_equal(#device_commands(env), 0, "failed lookup sends to nobody")
  T.check(Properties["Last Command"]:find("no link route", 1, true) ~= nil, "route failure displayed")
end)

T.test("valve: link loss marks stale, keeps state, and blocks commands", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  local contacts_before = #env.proxy_sends
  OnBindingChanged(LINK, "CONTROL", false)
  T.check(Properties["Connection"]:find("Not linked") ~= nil, "unbind marks not linked")
  T.check(Properties["Connection"]:find("last update") ~= nil, "stale marking keeps the timestamp")
  local saw_lost = false
  for _, name in ipairs(env.events) do
    if name == "Connection Lost" then
      saw_lost = true
    end
  end
  T.check(saw_lost, "link loss fires Connection Lost")
  local before = #commands_sent(env)
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  T.check_equal(#commands_sent(env), before, "unlinked commands send nothing")
  -- Rebind re-handshakes and a fresh push restores the link display.
  OnBindingChanged(LINK, "CONTROL", true)
  T.check_equal(Properties["Connection"], "Linking...", "rebind marks linking")
  handshake(env, "11")
  push_state(env, base_state())
  T.check_equal(Properties["Connection"], "Online", "fresh push restores online")
  local saw_restored = false
  for _, name in ipairs(env.events) do
    if name == "Connection Restored" then
      saw_restored = true
    end
  end
  T.check(saw_restored, "recovery fires Connection Restored")
  T.check_equal(#env.proxy_sends >= contacts_before, true, "contact history intact")
end)

T.test("valve: digest-only state degrades without touching contacts", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  local sends101 = contact_sends(env, 101)
  local digest = {
    [Link.K_VERSION] = "1",
    [Link.K_MSG] = Link.MSG_STATE,
    [Link.K_BODY] = "",
    [Link.K_HASH] = Link.digest("unseen"),
    [Link.K_TRUNC] = "1",
  }
  T.check_equal(flovalve_handle_link("FLOGIC_STATE", digest), true, "digest handled")
  T.check(Properties["Connection"]:find("Degraded") ~= nil, "digest marks degraded")
  check_list_equal(contact_sends(env, 101), sends101, "digest moves no contacts")
  T.check_equal(Properties["Mode"], "home", "digest moves no display")
  local retried = false
  for _, send in ipairs(link_sends(env)) do
    if send.params[Link.K_MSG] == Link.MSG_GET_STATE then
      retried = true
    end
  end
  T.check(retried, "digest retries with GET_STATE")
  -- A second digest in the same burst must not re-retry: each GET_STATE
  -- re-elicits the same digest, which would ping-pong at message speed.
  local function get_state_count()
    local n = 0
    for _, send in ipairs(link_sends(env)) do
      if send.params[Link.K_MSG] == Link.MSG_GET_STATE then
        n = n + 1
      end
    end
    return n
  end
  local before = get_state_count()
  T.check_equal(flovalve_handle_link("FLOGIC_STATE", digest), true, "second digest handled")
  T.check_equal(get_state_count(), before, "immediate second digest does not re-retry")
end)

T.test("valve: foreign-valve state is ignored and re-handshakes", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  local hellos_before = #hellos(env)
  push_state(env, base_state({ id = "22", mode = 8 }))
  T.check_equal(Properties["Mode"], "home", "foreign state paints nothing")
  T.check_equal(#hellos(env), hellos_before + 1, "mismatch re-handshakes")
  handshake(env, "11")
  push_state(env, base_state({ mode = 8 }))
  T.check_equal(Properties["Mode"], "shutoff", "own state applies after re-handshake")
end)

T.test("valve: persist and restore keeps display without replaying programming", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state({ mode = 2 }))
  T.check(env.saved["flovalve_last_state"] ~= nil, "state body persisted")
  local sends102_before = #contact_sends(env, 102)
  local pre_restart_sends = #env.proxy_sends
  -- Same Lua state, fresh lifecycle: models a Director restart.
  OnDriverLateInit("restart")
  T.check_equal(Properties["Valve Name"], "Kitchen", "name restored for display")
  T.check_equal(Properties["Valve ID"], "11", "id restored for display")
  T.check_equal(Properties["Mode"], "away", "mode text restored for display")
  T.check_equal(flovalve_state.restore_action, "mode_away", "restore target survives restart")
  T.check(flovalve_state.contact_states == nil, "no contacts derived before handshake")
  for i = pre_restart_sends + 1, #env.proxy_sends do
    local send = env.proxy_sends[i]
    if send.binding ~= LINK and send.binding ~= LIGHT then
      error("restore replayed programming on binding " .. tostring(send.binding))
    end
  end
  T.check(#hellos(env) >= 1, "restart hellos for a fresh handshake")
  handshake(env, "11")
  push_state(env, base_state({ mode = 2 }))
  local sends102 = contact_sends(env, 102)
  T.check_equal(#sends102, sends102_before + 1, "post-restart push re-baselines once")
  T.check_equal(sends102[#sends102], "STATE_CLOSED", "post-restart push baselines quietly")
  T.check_equal(#env.events, 0, "post-restart baseline fires no events")
end)

T.test("valve: pre-identity state hellos instead of adopting (M6)", function()
  local env = boot(valve_env())
  T.check(flovalve_state.valve_id == nil, "no identity yet")
  local hellos_before = #hellos(env)
  T.check_equal(flovalve_handle_link("FLOGIC_STATE", Link.build_state(base_state())), false, "unverified state dropped")
  T.check_equal(#hellos(env), hellos_before + 1, "drop re-hellos for the authoritative identity")
  T.check(flovalve_state.valve_id == nil, "stranger id never adopted")
  T.check_equal(Properties["Mode"] or "", "", "nothing painted before identity")
  handshake(env, "11")
  push_state(env, base_state())
  T.check_equal(Properties["Mode"], "home", "handshake then state converges")
end)

T.test("valve: light bind replays the confirmed level (L8)", function()
  local env = boot(valve_env())
  OnBindingChanged(LIGHT, "LIGHT_V2", true)
  T.check_equal(#light_levels(env), 0, "no level invented before first state")
  handshake(env, "11")
  push_state(env, base_state({ mode = 8 }))
  env.proxy_sends = {}
  OnBindingChanged(LIGHT, "LIGHT_V2", true)
  check_list_equal(light_levels(env), { 0 }, "rebound tile replays the confirmed level")
  OnBindingChanged(LIGHT, "LIGHT_V2", false)
  T.check_equal(#light_levels(env), 1, "unbind replays nothing")
end)

T.test("valve: program table actions resolve", function()
  -- Guards flovalve_run_program_command's range lookup: every kind="value"
  -- entry must name a FLOVALVE_VALUE_ACTIONS spec, and every other kind
  -- must be a known direct action.
  for name, spec in pairs(FLOVALVE_PROGRAM_COMMANDS) do
    if spec.kind == "value" then
      T.check(FLOVALVE_VALUE_ACTIONS[spec.action] ~= nil, name .. " resolves a range spec")
    elseif spec.kind == "action" then
      T.check(type(spec.action) == "string", name .. " carries a link action")
    else
      T.check(spec.kind == "open" or spec.kind == "close" or spec.kind == "toggle", name .. " kind known")
    end
  end
end)

T.test("valve: pending commands expire without an ack (V1)", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  ExecuteCommand("Close Valve", {})
  local cmd_id = Link.parse(commands_sent(env)[1].params).cmd_id
  T.check(flovalve_state.pending_commands[cmd_id] ~= nil, "command pends")
  flovalve_state.pending_commands[cmd_id].sent_at = os.time() - 200
  push_state(env, base_state())
  T.check(flovalve_state.pending_commands[cmd_id] == nil, "stale pending expired")
  T.check(Properties["Last Command"]:find("no response from cloud") ~= nil, "expiry is displayed")
end)

T.test("valve: unavailable notice marks, blocks commands, clears on recovery", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  T.check_equal(Properties["Connection"], "Online", "online before the notice")
  from_cloud(env, Link.build_unavailable("11", "left-account"))
  T.check(Properties["Connection"]:find("Not available", 1, true) ~= nil, "unavailable marked")
  T.check(Properties["Connection"]:find("left-account", 1, true) ~= nil, "reason shown")
  T.check(Properties["Connection"]:find("last update", 1, true) ~= nil, "last observation kept")
  T.check(flovalve_state.contact_states ~= nil, "contacts retained while unavailable")
  -- Another valve's notice is cross-talk: ignored.
  from_cloud(env, Link.build_unavailable("22", "left-account"))
  T.check(Properties["Connection"]:find("left-account", 1, true) ~= nil, "cross-talk ignored")
  -- Commands block locally instead of moving the tile for a gone valve.
  local before = #commands_sent(env)
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  T.check_equal(#commands_sent(env), before, "no command while unavailable")
  T.check(Properties["Last Command"]:find("not available", 1, true) ~= nil, "block displayed")
  -- Recovery on the next slice.
  push_state(env, base_state())
  T.check_equal(Properties["Connection"], "Online", "slice clears unavailable")
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  T.check_equal(#commands_sent(env), before + 1, "commands resume after recovery")
end)

T.test("valve: display shows observation time and drops out-of-order snapshots", function()
  local env = boot(valve_env())
  handshake(env, "11")
  local t1 = os.time() - 100
  push_state(env, base_state({ updated = t1 }))
  T.check_equal(Properties["Last Link Update"], os.date("%Y-%m-%d %H:%M:%S", t1), "display shows observation time")
  push_state(env, base_state({ updated = t1 + 50, mode = 8 }))
  T.check_equal(Properties["Mode"], "shutoff", "newer snapshot applied")
  push_state(env, base_state({ updated = t1 + 10, mode = 1 }))
  T.check_equal(Properties["Mode"], "shutoff", "older snapshot dropped")
  T.check_equal(
    Properties["Last Link Update"],
    os.date("%Y-%m-%d %H:%M:%S", t1 + 50),
    "display keeps the newer observation"
  )
end)

T.test("valve: watchdog marks stale silence and recovers on the next slice", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  push_state(env, base_state())
  flovalve_check_freshness()
  T.check_equal(Properties["Connection"], "Online", "fresh data stays online")
  -- Simulate a cloud outage: the last snapshot ages past the limit.
  flovalve_state.last_slice_at = os.time() - FLOVALVE_STALE_MIN_S - 1
  flovalve_state.prev_slice_at = os.time() - FLOVALVE_STALE_MIN_S - 61
  flovalve_check_freshness()
  T.check(Properties["Connection"]:find("Stale", 1, true) ~= nil, "silence marked stale")
  local saw_lost = false
  for _, name in ipairs(env.events) do
    if name == "Connection Lost" then
      saw_lost = true
    end
  end
  T.check(saw_lost, "stale fires Connection Lost")
  -- Repeat checks don't re-fire; contacts stay put.
  local events_before = #env.events
  flovalve_check_freshness()
  T.check_equal(#env.events, events_before, "stale fires once")
  T.check(flovalve_state.contact_states ~= nil, "contacts retained while stale")
  -- Recovery on the next slice.
  push_state(env, base_state())
  T.check_equal(Properties["Connection"], "Online", "slice clears staleness")
  T.check(env.events[#env.events] == "Connection Restored", "recovery fires Connection Restored")
end)

T.test("valve: unanswered commands settle on a real deadline and reconcile the tile", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  check_list_equal(light_levels(env), { 100, 0 }, "off click reports 0 immediately")
  -- No reply from the cloud: the deadline timer settles the command and
  -- reconciles the tile to the last observed level — never stuck off.
  env.timers.advance(FLOVALVE_ACK_TIMEOUT_S * 1000 + 5000)
  T.check(Properties["Last Command"]:find("no response from cloud", 1, true) ~= nil, "timeout is displayed")
  check_list_equal(light_levels(env), { 100, 0, 100 }, "tile reconciled to last observed")
  T.check(next(flovalve_state.pending_commands) == nil, "pending settled by the timer")
  -- A subsequent toggle decides from the reconciled level, not the lost request.
  ReceivedFromProxy(LIGHT, "TOGGLE", {})
  local body = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(body.fields.action, "mode_shutoff", "toggle closes from reconciled on")
end)

T.test("valve: ack cancels the command deadline timer", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  local first = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  from_cloud(env, Link.build_ack(first.cmd_id))
  env.timers.advance(FLOVALVE_ACK_TIMEOUT_S * 1000 + 5000)
  check_list_equal(light_levels(env), { 100, 0 }, "acked command never reconciles away")
  T.check(Properties["Last Command"]:find("acknowledged", 1, true) ~= nil, "ack display survives the deadline")
end)

T.test("valve: update socket dispatches through lifecycle entry points", function()
  local env = boot(valve_env())
  local packet = FloUpdate.build_install_packet("flologic_water_valve.c4z")
  local err_seen, calls = "unset", 0
  flovalve_soap_send(packet, function(err)
    calls = calls + 1
    err_seen = err
  end)
  local binding = flovalve_state.soap_binding
  T.check(binding ~= nil, "soap binding allocated")
  T.check_equal(#env.net_connects, 1, "connect attempted")
  -- Foreign binding/port traffic is ignored.
  ReceivedFromNetwork(binding + 1, FloUpdate.SOAP_PORT, "x")
  OnConnectionStatusChanged(binding + 1, FloUpdate.SOAP_PORT, "ONLINE")
  OnConnectionStatusChanged(binding, FloUpdate.SOAP_PORT + 1, "ONLINE")
  T.check_equal(#env.net_sends, 0, "foreign traffic ignored")
  T.check_equal(calls, 0, "foreign traffic settles nothing")
  -- ONLINE transmits the packet; a reply settles success.
  OnConnectionStatusChanged(binding, FloUpdate.SOAP_PORT, "ONLINE")
  T.check_equal(#env.net_sends, 1, "packet transmitted on open")
  T.check_equal(env.net_sends[1].data, packet, "install packet sent")
  ReceivedFromNetwork(binding, FloUpdate.SOAP_PORT, "HTTP/1.1 200 OK")
  T.check_equal(calls, 1, "reply settles the send")
  T.check(err_seen == nil, "reply is success, got " .. tostring(err_seen))
end)

T.test("valve: update socket reports connection failure distinctly", function()
  local env = boot(valve_env())
  local err_seen, calls = "unset", 0
  flovalve_soap_send("packet", function(err)
    calls = calls + 1
    err_seen = err
  end)
  local binding = flovalve_state.soap_binding
  -- OFFLINE before any ONLINE: connection failure, not success.
  OnConnectionStatusChanged(binding, FloUpdate.SOAP_PORT, "OFFLINE")
  T.check_equal(calls, 1, "close settles the send")
  T.check_equal(err_seen, "cannot reach Composer endpoint", "connection failure distinguished")
  T.check_equal(#env.net_sends, 0, "nothing transmitted without a connection")
end)

T.test("valve: fallback hint follows the live handshake, never a stale binding", function()
  local env = valve_env()
  env.proxy_fail_link = true
  boot(env)
  local function fallback_hellos()
    local found = {}
    for _, send in ipairs(env.device_sends) do
      if send.command == "FLOGIC_HELLO" then
        found[#found + 1] = send
      end
    end
    return found
  end
  -- Empty identity: the first hello carries no hint (the cloud cannot
  -- attribute it and drops it; the proxy burst is the bootstrap).
  local hellos = fallback_hellos()
  T.check_equal(#hellos, 1, "first hello falls back")
  T.check(hellos[1].params["FLOGIC_FROM"] == nil, "no hint before any handshake")
  -- A live handshake authorizes the hint from here on.
  handshake(env, "11")
  push_state(env, base_state())
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  local fallback = device_commands(env)
  T.check_equal(fallback[#fallback].params["FLOGIC_FROM"], "11", "hint follows the live handshake")
  -- Rebind: the old hint must not route the new binding's traffic.
  OnBindingChanged(LINK, "CONTROL", false)
  OnBindingChanged(LINK, "CONTROL", true)
  hellos = fallback_hellos()
  T.check(hellos[#hellos].params["FLOGIC_FROM"] == nil, "rebind hello carries no stale hint")
  handshake(env, "22")
  ReceivedFromProxy(LIGHT, "DYNAMIC_ON", {})
  fallback = device_commands(env)
  T.check_equal(fallback[#fallback].params["FLOGIC_FROM"], "22", "new handshake re-authorizes the hint")
end)

T.test("valve: handshake retries are bounded, explicit, and recover slowly", function()
  local env = boot(valve_env())
  T.check_equal(#hellos(env), 1, "startup hello")
  T.check_equal(Properties["Connection"], "Linking...", "linking shown")
  -- Silence: the burst retries on cadence, then fails explicitly. Steps
  -- stay small because one big advance only fires one timer generation.
  for _ = 1, FLOVALVE_HELLO_ATTEMPTS do
    env.timers.advance(FLOVALVE_HELLO_RETRY_S * 1000)
  end
  T.check_equal(#hellos(env), FLOVALVE_HELLO_ATTEMPTS, "bounded retries")
  T.check(Properties["Connection"]:find("Link failed", 1, true) ~= nil, "failure is explicit")
  T.check(flovalve_state.hello_failed, "failed flag set")
  -- Slow recovery restarts one burst; identity ends it.
  for _ = 1, 6 do
    env.timers.advance(FLOVALVE_HELLO_RETRY_S * 1000)
  end
  T.check_equal(#hellos(env), FLOVALVE_HELLO_ATTEMPTS + 1, "slow retry re-hellos once")
  handshake(env, "11")
  T.check(not flovalve_state.hello_failed, "identity clears the failure")
  local count = #hellos(env)
  env.timers.advance(120000)
  T.check_equal(#hellos(env), count, "no more hellos once linked")
end)

T.test("valve: snapshots outside the numeric domains are rejected atomically", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  T.check_equal(Properties["Mode"], "home", "baseline applied")
  local function raw_state(body)
    return { [Link.K_VERSION] = "1", [Link.K_MSG] = Link.MSG_STATE, [Link.K_BODY] = body }
  end
  -- Fractional mode: dropped before any property, contact, edge, or restore update.
  local bad_mode = Link.encode_fields({ id = "11", mode = 2.5, online = true })
  T.check_equal(flovalve_handle_link("FLOGIC_STATE", raw_state(bad_mode)), false, "fractional mode rejected")
  T.check_equal(Properties["Mode"], "home", "nothing applied")
  -- Negative flow state and control-char name: same atomicity.
  local bad_flow = Link.encode_fields({ id = "11", mode = 1, online = true, flow_state = -4 })
  T.check_equal(flovalve_handle_link("FLOGIC_STATE", raw_state(bad_flow)), false, "negative flow rejected")
  local bad_name = Link.encode_fields({ id = "11", mode = 1, online = true, name = "A\001B" })
  T.check_equal(flovalve_handle_link("FLOGIC_STATE", raw_state(bad_name)), false, "control-char name rejected")
  T.check_equal(Properties["Mode"], "home", "still nothing applied")
  T.check_equal(#env.events, 0, "no edges from rejected snapshots")
end)

T.test("valve: Refresh is guarded while unlinked (V2)", function()
  local env = boot(valve_env())
  ExecuteCommand("Refresh", {})
  T.check_equal(Properties["Last Command"], "Refresh: not linked", "unlinked refresh is reported")
  for _, send in ipairs(link_sends(env)) do
    T.check(send.params[Link.K_MSG] ~= Link.MSG_GET_STATE, "unlinked refresh sends no GET_STATE")
  end
  handshake(env, "11")
  env.proxy_sends = {}
  ExecuteCommand("Refresh", {})
  local refreshed = false
  for _, send in ipairs(link_sends(env)) do
    refreshed = refreshed or send.params[Link.K_MSG] == Link.MSG_GET_STATE
  end
  T.check(refreshed, "linked refresh asks the cloud for state")
end)
