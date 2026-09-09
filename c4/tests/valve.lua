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
  function C4:SetTimer(ms, callback, repeating)
    -- Mirror Director: a nil repeat flag raises on hardware ("repeat
    -- should be a boolean"), as does a zero interval ("Invalid argument
    -- value"). Fail here instead of only in the field.
    assert(type(repeating) == "boolean", "C4:SetTimer repeating must be a boolean")
    assert(type(ms) == "number" and ms > 0, "C4:SetTimer ms must be positive")
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
  -- Deterministic tile baseline: last_level intentionally survives
  -- in-process reloads in production, which would leak across tests
  -- sharing one Lua state. Reset before LateInit so restore recomputes
  -- from persist (or 0), then wipe boot's own *light* sends (link
  -- traffic such as the startup hello is untouched): every level
  -- sequence below asserts post-boot sends only, and boot
  -- establishment itself is pinned by its dedicated test.
  flovalve_state.last_level = 0
  OnDriverLateInit("test")
  local kept = {}
  for _, send in ipairs(env.proxy_sends) do
    if send.binding ~= LIGHT then
      kept[#kept + 1] = send
    end
  end
  env.proxy_sends = kept
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
    -- Level Target API: the tile follows LIGHT_BRIGHTNESS_CHANGED with
    -- LIGHT_BRIGHTNESS_CURRENT. The pre-3.3 LIGHT_LEVEL notify is
    -- silently discarded by light_v2 proxies, so the helper matches
    -- ONLY the new vocabulary: any LIGHT_LEVEL regression shows up as
    -- missing levels here.
    if send.binding == LIGHT and send.command == "LIGHT_BRIGHTNESS_CHANGED" then
      found[#found + 1] = send.params.LIGHT_BRIGHTNESS_CURRENT
    end
  end
  return found
end

local function handshake(env, id)
  id = id or "11"
  from_cloud(env, Link.build_identity(id))
end

local function push_state(env, state, extra)
  local built = Link.build_state(state, extra)
  T.check(built ~= nil, "state builds")
  from_cloud(env, built)
  return built
end

local function push_unavailable(env, valve_id, reason, extra)
  from_cloud(env, Link.build_unavailable(valve_id, reason, extra))
end

local function get_state_count(env)
  local count = 0
  for _, send in ipairs(link_sends(env)) do
    if send.params[Link.K_MSG] == Link.MSG_GET_STATE then
      count = count + 1
    end
  end
  return count
end

local function push_digest(env)
  from_cloud(env, {
    [Link.K_VERSION] = tostring(Link.VERSION),
    [Link.K_MSG] = Link.MSG_STATE,
    [Link.K_BODY] = "",
    [Link.K_TRUNC] = "1",
    [Link.K_HASH] = "abc123",
  })
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
  T.check_equal(FLOVALVE_DRIVER_VERSION, "2026090828", "valve version lockstep with cloud")
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
  T.check(values(1, true, 8)[101] == true, "valve-closed flow state closes 101 without flags")
  T.check(values(1, true, 4)[101] == false, "flowing home leaves 101 open")
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
  -- Level Target param shape (supports_target proxies): preferred over
  -- the legacy LEVEL fallback when both are present.
  ReceivedFromProxy(LIGHT, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0 })
  local v2dim = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(v2dim.fields.action, "mode_shutoff", "v2 target 0 closes")
  ReceivedFromProxy(LIGHT, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 75 })
  local v2bright = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(v2bright.fields.action, "mode_home", "v2 target > 0 opens")
  ReceivedFromProxy(LIGHT, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, LEVEL = 0 })
  local pref = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(pref.fields.action, "mode_home", "v2 target wins over legacy LEVEL")
  -- Oldest-API shape: bare LIGHT.
  ReceivedFromProxy(LIGHT, "SET_BRIGHTNESS_TARGET", { LIGHT = 0 })
  local leg0 = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(leg0.fields.action, "mode_shutoff", "legacy LIGHT 0 closes")
  ReceivedFromProxy(LIGHT, "SET_BRIGHTNESS_TARGET", { LIGHT = 50 })
  local leg50 = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(leg50.fields.action, "mode_home", "legacy LIGHT > 0 opens")
  ReceivedFromProxy(LIGHT, "SET_BRIGHTNESS_TARGET", {})
  T.check_equal(#commands_sent(env), 10, "level-less brightness target sends nothing")
  ReceivedFromProxy(LIGHT, "BOGUS", {})
  T.check_equal(#commands_sent(env), 10, "unknown light command sends nothing")
end)

T.test("valve: plain ON/OFF, BUTTON_ACTION, and RAMP_TO_LEVEL route to open/close", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  ReceivedFromProxy(LIGHT, "OFF", {})
  local off_body = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(off_body.fields.action, "mode_shutoff", "plain OFF issues shutoff")
  ReceivedFromProxy(LIGHT, "ON", {})
  local on_body = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(on_body.fields.action, "mode_home", "plain ON restores home")
  -- Remotes/keypads act on release (ACTION 2); press (ACTION 1) is ignored.
  local before = #commands_sent(env)
  ReceivedFromProxy(LIGHT, "BUTTON_ACTION", { BUTTON_ID = 0, ACTION = 1 })
  T.check_equal(#commands_sent(env), before, "button press sends nothing")
  ReceivedFromProxy(LIGHT, "BUTTON_ACTION", { BUTTON_ID = "1", ACTION = "2" })
  local btn_body = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(btn_body.fields.action, "mode_shutoff", "button 1 release closes")
  ReceivedFromProxy(LIGHT, "BUTTON_ACTION", { BUTTON_ID = 2, ACTION = 2 })
  local tog_body = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(tog_body.fields.action, "mode_home", "button 2 release toggles open")
  ReceivedFromProxy(LIGHT, "RAMP_TO_LEVEL", { LEVEL = 0 })
  local ramp0 = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(ramp0.fields.action, "mode_shutoff", "ramp target 0 closes")
  ReceivedFromProxy(LIGHT, "RAMP_TO_LEVEL", { LIGHT_BRIGHTNESS_TARGET = 80 })
  local ramp80 = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(ramp80.fields.action, "mode_home", "ramp target > 0 opens")
  check_list_equal(light_levels(env), { 100, 0, 100, 0, 100, 0, 100 }, "each tap reports optimistically")
end)

T.test("valve: Identify Tile marks the proxy without moving the valve", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  local before = #commands_sent(env)
  ExecuteCommand("Identify Tile", {})
  check_list_equal(light_levels(env), { 100, 50 }, "mark shows latching 50")
  T.check_equal(#commands_sent(env), before, "identify sends no valve commands")
  T.check_equal(flovalve_state.last_level, 100, "mark preserves the true level")
  T.check_equal(Properties["Last Command"], "Identify Tile: marked (50)", "identify stamps last command")
end)

T.test("valve: proxy bind state is exposed for tile diagnosis", function()
  local env = boot(valve_env())
  handshake(env, "11")
  OnBindingChanged(LIGHT, "LIGHT_V2", true)
  T.check_equal(Properties["Proxy Bound"], "Bound", "bind stamps bound")
  OnBindingChanged(LIGHT, "LIGHT_V2", false)
  T.check_equal(Properties["Proxy Bound"], "Unbound", "unbind stamps unbound")
end)

T.test("valve: tile off means closed, on means everything else", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state({ mode = 1, flow_state = 1 }))
  check_list_equal(light_levels(env), { 100 }, "idle home reports on")
  -- Flow-state 8 ("Valve closed") with no mode flags: tile off, contact
  -- 101 closed, water-off edge fires — the switch follows the valve's
  -- closed state, not just its mode flags.
  push_state(env, base_state({ mode = 1, flow_state = 8 }))
  local sends101 = contact_sends(env, 101)
  T.check_equal(sends101[#sends101], "CLOSED", "101 closes on valve-closed flow state")
  check_list_equal(light_levels(env), { 100, 0 }, "tile reports off when closed")
  local saw_off = false
  for _, name in ipairs(env.events) do
    if name == "Water Off Detected" then
      saw_off = true
    end
  end
  T.check(saw_off, "water-off edge fires on valve-closed flow state")
  T.check_equal(Properties["Water Flowing"], "No", "closed valve never flows")
  -- Reopening clears everything together.
  push_state(env, base_state({ mode = 1, flow_state = 4 }))
  sends101 = contact_sends(env, 101)
  T.check_equal(sends101[#sends101], "OPENED", "101 reopens with flow")
  check_list_equal(light_levels(env), { 100, 0, 100 }, "tile reports on when not closed")
  local saw_cleared = false
  for _, name in ipairs(env.events) do
    if name == "Water Off Cleared" then
      saw_cleared = true
    end
  end
  T.check(saw_cleared, "water-off clear edge fires on reopen")
end)

T.test("valve: restore tracking follows the mode even when closed", function()
  local env = boot(valve_env())
  handshake(env, "11")
  -- A closed valve still has a mode: ON must restore the actual current
  -- mode, never a stale one frozen by the closure.
  push_state(env, base_state({ mode = 2, flow_state = 8 }))
  check_list_equal(light_levels(env), { 0 }, "closed away reports off")
  ReceivedFromProxy(LIGHT, "DYNAMIC_ON", {})
  local body = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  T.check_equal(body.fields.action, "mode_away", "on restores current away despite closure")
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
  -- The v2 protocol has no "unknown": missing data renders as 0, so the
  -- bind serves the best-known level (0 default) rather than quiet.
  check_list_equal(light_levels(env), { 0 }, "bind serves best-known level before first state")
  handshake(env, "11")
  push_state(env, base_state({ mode = 8 }))
  env.proxy_sends = {}
  OnBindingChanged(LIGHT, "LIGHT_V2", true)
  check_list_equal(light_levels(env), { 0 }, "rebound tile replays the confirmed level")
  OnBindingChanged(LIGHT, "LIGHT_V2", false)
  T.check_equal(#light_levels(env), 1, "unbind replays nothing")
end)

T.test("valve: boot establishes the tile before the first push", function()
  -- Manual boot (no send wipe): a binding with no value leaves every
  -- tile dark, so boot must speak first even with no persist and no
  -- state yet.
  local env = valve_env()
  OnDriverInit("test")
  flovalve_state.last_level = 0
  OnDriverLateInit("test")
  check_list_equal(light_levels(env), { 0 }, "fresh boot establishes 0")
  -- Persisted closed state boots to 0 (not the default path): the
  -- restore expression must survive a falsy-looking 0 level.
  local env2 = valve_env()
  env2.saved["flovalve_valve_id"] = "11"
  env2.saved["flovalve_last_state"] = Link.build_state_body(base_state({ id = "11", mode = 8 }))
  OnDriverInit("test")
  flovalve_state.last_level = 100
  OnDriverLateInit("test")
  check_list_equal(light_levels(env2), { 0 }, "persisted closed boots to 0")
  T.check_equal(flovalve_state.last_level, 0, "boot level latched, stale 100 dropped")
end)

T.test("valve: navigator state queries are served, never command", function()
  local env = boot(valve_env())
  -- Unknown state: serve the default, command nothing. Silence would
  -- time the query out and reset the tile to 0 anyway.
  OnRequestData(LIGHT)
  check_list_equal(light_levels(env), { 0 }, "request-data serves 0 with no state")
  T.check_equal(#commands_sent(env), 0, "request-data commands nothing")
  OnRequestData(600)
  T.check_equal(#light_levels(env), 1, "request-data answers the light binding only")
  for _, cmd in ipairs({ "GET_LIGHT_LEVEL", "GET_STATE", "GET_BRIGHTNESS_TARGET" }) do
    ReceivedFromProxy(LIGHT, cmd, {})
  end
  check_list_equal(light_levels(env), { 0, 0, 0, 0 }, "each query is answered")
  T.check_equal(#commands_sent(env), 0, "queries command nothing")
  -- Known state: serve it, still commanding nothing.
  handshake(env, "11")
  push_state(env, base_state({ mode = 1 }))
  env.proxy_sends = {}
  OnRequestData(LIGHT)
  ReceivedFromProxy(LIGHT, "GET_STATE", {})
  check_list_equal(light_levels(env), { 100, 100 }, "queries serve the observed level")
  T.check_equal(#commands_sent(env), 0, "queries never command the valve")
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
      T.check(
        spec.kind == "open" or spec.kind == "close" or spec.kind == "toggle" or spec.kind == "identify",
        name .. " kind known"
      )
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
  -- Unstamped snapshots (older clouds) keep legacy semantics: every
  -- receipt is novel and recovers. The stamped duplicate path is
  -- covered by the R3 test below.
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  push_state(env, base_state())
  flovalve_check_freshness()
  T.check_equal(Properties["Connection"], "Online", "fresh data stays online")
  -- Simulate a cloud outage: the last snapshot ages past the limit.
  flovalve_state.last_slice_at = os.time() - FLOVALVE_STALE_MIN_S - 1
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

T.test("valve: ack holds the tile only until the observation deadline", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  local first = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  from_cloud(env, Link.build_ack(first.cmd_id))
  -- The ack timer is gone (no "no response" settle), but the entry now
  -- awaits observation: a confirming snapshot settles it as confirmed.
  env.timers.advance(60000)
  T.check(Properties["Last Command"]:find("acknowledged; awaiting refresh", 1, true) ~= nil, "ack display holds")
  push_state(env, base_state({ updated = os.time(), mode = 8 }))
  T.check(Properties["Last Command"]:find("confirmed", 1, true) ~= nil, "snapshot confirms the request")
  check_list_equal(light_levels(env), { 100, 0, 0 }, "confirmed tile shows the observed level")
  -- An ack WITHOUT any following snapshot reconciles past the
  -- observation deadline instead of displaying the request forever.
  ReceivedFromProxy(LIGHT, "DYNAMIC_ON", {})
  local second = Link.parse(commands_sent(env)[#commands_sent(env)].params)
  from_cloud(env, Link.build_ack(second.cmd_id))
  env.timers.advance(FLOVALVE_OBSERVATION_TIMEOUT_S * 1000 + 5000)
  T.check(
    Properties["Last Command"]:find("acknowledged but unconfirmed", 1, true) ~= nil,
    "silence past the deadline is displayed"
  )
  check_list_equal(light_levels(env), { 100, 0, 0, 100, 0 }, "tile reconciled to last observed")
  T.check(next(flovalve_state.pending_commands) == nil, "observation entry settled by the timer")
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
  push_state(env, base_state({ id = "22" }))
  ReceivedFromProxy(LIGHT, "DYNAMIC_ON", {})
  fallback = device_commands(env)
  T.check_equal(fallback[#fallback].params["FLOGIC_FROM"], "22", "new handshake re-authorizes the hint")
end)

T.test("valve: duplicate snapshots never renew freshness or clear markings (R3)", function()
  local env = boot(valve_env())
  handshake(env, "11")
  local first = push_state(env, base_state({ uuid = "uuid-1" }), { seq = 1, epoch = 1, fresh_s = 360 })
  T.check(first ~= nil, "stamped state builds")
  local receipt = flovalve_state.last_slice_at
  -- Age past the watchdog and mark stale; the replay must not recover.
  flovalve_state.last_slice_at = os.time() - 370
  flovalve_check_freshness()
  T.check(flovalve_state.stale, "silence marks stale")
  from_cloud(env, first) -- exact redelivery of the applied snapshot
  T.check(flovalve_state.stale, "duplicate never clears stale")
  T.check(flovalve_state.last_slice_at < receipt, "duplicate never renews the watchdog")
  -- An unavailable notice orders after the snapshot; the stale
  -- snapshot redelivered after it must not revoke the marking.
  push_unavailable(env, "11", "left-account", { seq = 2, epoch = 1 })
  T.check_equal(flovalve_state.unavailable, "left-account", "notice marks")
  from_cloud(env, first)
  T.check_equal(flovalve_state.unavailable, "left-account", "older duplicate never revokes unavailability")
  -- A NOVEL snapshot recovers everything.
  push_state(env, base_state({ uuid = "uuid-1", updated = os.time() }), { seq = 3, epoch = 1, fresh_s = 360 })
  T.check(flovalve_state.unavailable == nil, "novel snapshot clears unavailability")
  T.check(not flovalve_state.stale, "novel snapshot clears stale")
  T.check(flovalve_state.last_slice_at >= receipt, "novel snapshot renews the watchdog")
end)

T.test("valve: cloud restart re-baselines ordering (R3)", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state({ uuid = "uuid-1" }), { seq = 5, epoch = 1 })
  T.check_equal(flovalve_state.link_seq, 5, "baseline established")
  -- New boot, restarted numbering: newer epoch always applies.
  push_state(env, base_state({ uuid = "uuid-1", updated = os.time() }), { seq = 1, epoch = 2 })
  T.check_equal(flovalve_state.link_epoch, 2, "new epoch re-baselines")
  T.check_equal(flovalve_state.link_seq, 1, "restarted numbering accepted")
  -- Delayed pre-restart traffic drops even with a higher sequence.
  local receipt = flovalve_state.last_slice_at
  push_state(env, base_state({ uuid = "uuid-1", updated = os.time() }), { seq = 9, epoch = 1 })
  T.check_equal(flovalve_state.link_seq, 1, "old epoch never advances the baseline")
  T.check(flovalve_state.last_slice_at == receipt, "old epoch never renews freshness")
end)

T.test("valve: same-id replacement resets history before applying (R4)", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state({ uuid = "uuid-1", mode = 1 }))
  T.check_equal(#env.events, 0, "first push syncs quietly")
  -- Same numeric id, different immutable identity: a replacement valve.
  -- Without the reset this push would fire a Mode Changed transition
  -- (home -> shutoff) against the old valve's baseline.
  push_state(env, base_state({ uuid = "uuid-2", mode = 8, updated = os.time() }))
  T.check_equal(flovalve_state.restore_action, "mode_home", "restore target reset, not inherited")
  T.check_equal(#env.events, 0, "replacement re-baselines quietly, no spurious transition")
  T.check_equal(env.saved["flovalve_valve_uuid"], "uuid-2", "new identity persisted")
  -- The pre-replacement restore target is gone for good: Open offers
  -- the default, never the old valve's mode.
  ExecuteCommand("Open Valve", {})
  T.check(
    Properties["Last Command"] ~= nil and Properties["Last Command"]:sub(1, 10) == "Open Valve",
    "open still offered after replacement"
  )
end)

T.test("valve: restart before the first new snapshot restores no stale state (R4)", function()
  local env = valve_env()
  -- Persisted association belongs to valve 22; the stored body belongs
  -- to valve 11 (identity changed, restart before any new snapshot).
  env.saved["flovalve_valve_id"] = "22"
  env.saved["flovalve_valve_uuid"] = "uuid-22"
  env.saved["flovalve_last_state"] = Link.build_state_body(base_state({ id = "11", uuid = "uuid-11", mode = 2 }))
  boot(env)
  T.check_equal(flovalve_state.restore_action, "mode_home", "foreign body never relearned as restore")
  T.check(Properties["Mode"] ~= "away", "foreign body never prefilled")
  -- The matched association still restores (positive control).
  local env2 = valve_env()
  env2.saved["flovalve_valve_id"] = "11"
  env2.saved["flovalve_valve_uuid"] = "uuid-11"
  env2.saved["flovalve_last_state"] = Link.build_state_body(base_state({ id = "11", uuid = "uuid-11", mode = 2 }))
  boot(env2)
  T.check_equal(flovalve_state.restore_action, "mode_away", "matched body restores the target")
  T.check_equal(Properties["Mode"], "away", "matched body prefills the display")
end)

T.test("valve: identity change clears the persisted association at once (R4)", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state({ uuid = "uuid-1", mode = 1 }))
  T.check(env.saved["flovalve_last_state"] ~= nil and env.saved["flovalve_last_state"] ~= "", "state persisted")
  OnBindingChanged(LINK, "FLOGIC_VALVE", false)
  OnBindingChanged(LINK, "FLOGIC_VALVE", true)
  handshake(env, "22")
  T.check_equal(env.saved["flovalve_last_state"], "", "old body cleared on identity change")
  T.check_equal(env.saved["flovalve_valve_uuid"], "", "old uuid cleared on identity change")
  T.check_equal(env.saved["flovalve_valve_id"], "22", "new id persisted")
end)

T.test("valve: unbind settles the optimistic tile and cancels deadlines (R5)", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  local cmd_id = next(flovalve_state.pending_commands)
  local timer = flovalve_state.pending_commands[cmd_id].timer
  OnBindingChanged(LINK, "FLOGIC_VALVE", false)
  check_list_equal(light_levels(env), { 100, 0, 100 }, "unbind reconciles the tile at once")
  T.check(Properties["Last Command"]:find("Link lost", 1, true) ~= nil, "unbind says the command dropped")
  T.check(timer.cancelled, "pending deadline cancelled explicitly")
  env.timers.advance((FLOVALVE_ACK_TIMEOUT_S + 5) * 1000)
  check_list_equal(light_levels(env), { 100, 0, 100 }, "no late settle after deadlines pass")
end)

T.test("valve: unavailable notice settles in-flight requests (R5)", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  push_unavailable(env, "11", "left-account")
  check_list_equal(light_levels(env), { 100, 0, 100 }, "unavailable reconciles the tile at once")
  T.check(Properties["Last Command"]:find("command(s) dropped", 1, true) ~= nil, "unavailable says commands dropped")
  T.check(next(flovalve_state.pending_commands) == nil, "in-flight entries settled")
  env.timers.advance((FLOVALVE_ACK_TIMEOUT_S + 5) * 1000)
  check_list_equal(light_levels(env), { 100, 0, 100 }, "no late settle after deadlines pass")
end)

T.test("valve: commands block before the first observation (R5)", function()
  local env = boot(valve_env())
  handshake(env, "11")
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  T.check_equal(#commands_sent(env), 0, "blind write refused")
  T.check_equal(Properties["Last Command"], "Close Valve: no state yet", "unknown state displayed")
  check_list_equal(light_levels(env), {}, "tile never claims optimistically")
  -- The first observation unblocks normally.
  push_state(env, base_state())
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  T.check_equal(#commands_sent(env), 1, "observed valve accepts commands")
end)

T.test("valve: watchdog honors the advertised budget (R8)", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state({ uuid = "uuid-1" }), { seq = 1, epoch = 1, fresh_s = 3600 })
  T.check_equal(flovalve_state.fresh_budget, 3600, "budget adopted")
  -- Silence past the old floor but inside the budget: still current.
  flovalve_state.last_slice_at = os.time() - 600
  flovalve_check_freshness()
  T.check(not flovalve_state.stale, "budgeted silence stays current")
  -- Silence past the budget: stale.
  flovalve_state.last_slice_at = os.time() - 3700
  flovalve_check_freshness()
  T.check(flovalve_state.stale, "over-budget silence marks stale")
  -- An absurd budget is ignored in favor of the floor.
  flovalve_state.stale = false
  push_state(env, base_state({ uuid = "uuid-1", updated = os.time() }), { seq = 2, epoch = 1, fresh_s = 10 })
  T.check_equal(flovalve_state.fresh_budget, 3600, "absurd budget ignored")
  flovalve_state.last_slice_at = os.time() - 400
  flovalve_check_freshness()
  T.check(not flovalve_state.stale, "previous sane budget still rules")
end)

T.test("valve: identity without state fails explicitly, then recovers slowly (R10)", function()
  local env = boot(valve_env())
  T.check_equal(get_state_count(env), 0, "nothing requested before the handshake")
  handshake(env, "11")
  T.check_equal(get_state_count(env), 1, "handshake requests state")
  -- Two bounded re-requests, then an explicit failure — never "Linking"
  -- forever.
  env.timers.advance(FLOVALVE_FIRST_STATE_TIMEOUT_S * 1000)
  T.check_equal(get_state_count(env), 2, "first wait expiry re-requests")
  T.check(not flovalve_state.state_failed, "still waiting")
  env.timers.advance(FLOVALVE_FIRST_STATE_TIMEOUT_S * 1000)
  T.check_equal(get_state_count(env), 3, "second wait expiry re-requests")
  env.timers.advance(FLOVALVE_FIRST_STATE_TIMEOUT_S * 1000)
  T.check(flovalve_state.state_failed, "bounded wait fails explicitly")
  T.check_equal(Properties["Connection"], "Link failed: no state from cloud", "failure displayed")
  T.check_equal(get_state_count(env), 3, "no more requests after failure")
  T.check(flovalve_state.hint_valve_id == nil, "suspect hint dropped at failure")
  -- The slow freshness tick restarts a failed wait with a re-handshake
  -- (the failed identity may itself be wrong).
  local function hello_count()
    local count = 0
    for _, send in ipairs(link_sends(env)) do
      if send.params[Link.K_MSG] == Link.MSG_HELLO then
        count = count + 1
      end
    end
    return count
  end
  local hellos = hello_count()
  env.timers.advance(FLOVALVE_STALE_CHECK_S * 1000)
  T.check_equal(hello_count(), hellos + 1, "slow tick re-handshakes")
  T.check(not flovalve_state.state_failed, "failure clears on restart")
  -- A corrected identity re-links from the failed wait.
  handshake(env, "22")
  push_state(env, base_state({ id = "22" }))
  T.check(flovalve_state.state_wait_timer == nil, "wait disarmed by state")
  T.check_equal(Properties["Connection"], "Online", "link online")
end)

T.test("valve: digests extend the first-state wait without consuming attempts (R10)", function()
  local env = boot(valve_env())
  handshake(env, "11")
  env.timers.advance((FLOVALVE_FIRST_STATE_TIMEOUT_S - 10) * 1000)
  push_digest(env)
  T.check_equal(flovalve_state.state_wait_attempts, 1, "digest consumes no attempt")
  T.check_equal(get_state_count(env), 2, "digest sends only its own retry")
  -- Past the original deadline: the extended wait still runs.
  env.timers.advance(20000)
  T.check(not flovalve_state.state_failed, "extended wait survives the original deadline")
  T.check_equal(get_state_count(env), 2, "no wait re-request while extended")
  -- The extended wait still expires and re-requests eventually.
  env.timers.advance((FLOVALVE_FIRST_STATE_TIMEOUT_S - 10) * 1000)
  T.check_equal(get_state_count(env), 3, "extended wait expires into a re-request")
end)

T.test("valve: nil provider lookup is observed-unbound, not failure (R7)", function()
  -- Plural API answers nil (documented no-bindings): startup stays
  -- silent instead of bursting hellos into the void.
  local env = valve_env()
  env.providers = nil
  boot(env)
  T.check_equal(Properties["Connection"], "Not linked", "unbound startup stays silent")
  T.check_equal(#link_sends(env), 0, "no hello burst on an unbound link")
  -- Recovery still works when the link binds.
  env.providers = { [77] = "FloLogic Cloud" }
  OnBindingChanged(LINK, "FLOGIC_VALVE", true)
  T.check(#link_sends(env) >= 1, "bind still handshakes")
  -- Singular API: nil and 0 both mean unbound.
  local function boot_singular(answer)
    local e = valve_env()
    C4.GetBoundProviderDevices = nil
    function C4:GetBoundProviderDevice()
      if answer == "raise" then
        error("no discovery")
      end
      return answer
    end
    boot(e)
    return e
  end
  local s1 = boot_singular(nil)
  T.check_equal(Properties["Connection"], "Not linked", "singular nil is unbound")
  T.check_equal(#link_sends(s1), 0, "singular nil stays silent")
  local s2 = boot_singular(0)
  T.check_equal(Properties["Connection"], "Not linked", "singular 0 is unbound")
  T.check_equal(#link_sends(s2), 0, "singular 0 stays silent")
  local s3 = boot_singular(77)
  T.check(#link_sends(s3) >= 1, "singular id handshakes")
  local s4 = boot_singular("not-an-id")
  T.check(#link_sends(s4) >= 1, "garbage stays indeterminate (assume bound)")
  local s5 = boot_singular("raise")
  T.check(#link_sends(s5) >= 1, "error stays indeterminate (assume bound)")
end)

T.test("valve: install grace without transmission reports a failure (R12)", function()
  local env = boot(valve_env())
  local err_seen, calls = "unset", 0
  flovalve_soap_send("packet", function(err)
    calls = calls + 1
    err_seen = err
  end)
  T.check(flovalve_state.soap_binding ~= nil, "soap binding allocated")
  -- No callback before grace expiry: the trigger never transmitted, so
  -- expiry reports a connection failure — never a sent trigger.
  env.timers.advance(3000)
  T.check_equal(calls, 1, "expiry settles the send")
  T.check_equal(err_seen, "cannot reach Composer endpoint", "untransmitted trigger is a failure")
  T.check_equal(#env.net_sends, 0, "nothing transmitted without a connection")
end)

T.test("valve: history reset cancels pending deadlines explicitly", function()
  local env = boot(valve_env())
  handshake(env, "11")
  push_state(env, base_state())
  ReceivedFromProxy(LIGHT, "DYNAMIC_OFF", {})
  local cmd_id = next(flovalve_state.pending_commands)
  local timer = flovalve_state.pending_commands[cmd_id].timer
  -- The cloud re-identifies the same binding (slot change, no Composer
  -- unbind): the reset path owns the in-flight entry.
  handshake(env, "22")
  T.check(timer.cancelled, "reset cancels the pending deadline")
  T.check(next(flovalve_state.pending_commands) == nil, "reset drops the entry")
  T.check_equal(Properties["Last Command"], "Link changed: 1 command(s) dropped", "reset says the command dropped")
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
