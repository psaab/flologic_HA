-- ============================================================================
-- c4/src/main.lua — Control4 Director glue: lifecycle, properties, commands,
-- events, timers, and the C4 network/HTTP transport for FloLogic sessions.
--
-- Bundled LAST after json/model/signalr/websocket/flologic. Defines Director
-- entry points (OnDriverInit, OnDriverLateInit, ExecuteCommand, ...) plus
-- module state. No top-level C4 calls (safe to load in tests with a stub C4).
-- Lua 5.1 safe.
-- ============================================================================

FLOGIC_DRIVER_VERSION = "2026090705"
print("[flologic] Lua loaded: " .. FLOGIC_DRIVER_VERSION)
FLOGIC_DEFAULT_HUB = "https://hub-cloudapps-prod.azurewebsites.net"
FLOGIC_BINDING_FIRST = 6100
FLOGIC_BINDING_LAST = 6199
FLOGIC_MIN_POLL_SECONDS = 30
FLOGIC_MAX_POLL_SECONDS = 3600
FLOGIC_LOCAL_TICK_MS = 5000
FLOGIC_RELAY_VALVE_CLOSED = 101
FLOGIC_RELAY_AWAY = 102

-- Property names (must match driver.xml).
FLOGIC_PROP_DEBUG = "Debug Mode"
FLOGIC_PROP_EMAIL = "Email"
FLOGIC_PROP_PASSWORD = "Password"
FLOGIC_PROP_HUB = "Hub URL"
FLOGIC_PROP_POLL = "Poll Interval"
FLOGIC_PROP_PICKER = "Select Valve"
FLOGIC_PROP_OVERRIDE = "Valve ID Override"
FLOGIC_PROP_CONNECTION = "Connection"

-- Event names (must match driver.xml).
FLOGIC_EV_FLOW_STARTED = "Flow Started"
FLOGIC_EV_FLOW_STOPPED = "Flow Stopped"
FLOGIC_EV_WATER_OFF = "Water Off Detected"
FLOGIC_EV_WATER_OFF_CLEAR = "Water Off Cleared"
FLOGIC_EV_WARNING = "Warning Alert"
FLOGIC_EV_WARNING_CLEAR = "Warning Cleared"
FLOGIC_EV_CRITICAL = "Critical Fault"
FLOGIC_EV_CRITICAL_CLEAR = "Critical Cleared"
FLOGIC_EV_MODE_CHANGED = "Mode Changed"
FLOGIC_EV_ADVANCE = "Advance Shutoff Warning"
FLOGIC_EV_CONN_LOST = "Connection Lost"
FLOGIC_EV_CONN_RESTORED = "Connection Restored"

-- Driver state. One session at a time; commands queue behind a running poll.
local function flogic_fresh_state()
  return {
    initialized = false,
    busy = false,
    command_queue = {},
    relog_token = "",
    retired_bindings = flogic_state and flogic_state.retired_bindings or {},
  }
end

flogic_state = flogic_fresh_state()

--- Timer closures belong to this load, even if Director delivers a cancelled tick.
local function flogic_set_timer(ms, callback, repeating)
  local owner = flogic_state
  return C4:SetTimer(ms, function(timer)
    if flogic_state == owner and owner.initialized then
      callback(timer)
    end
  end, repeating)
end

local function flogic_log(message)
  if Properties ~= nil and Properties[FLOGIC_PROP_DEBUG] == "On" then
    print("[flologic] " .. tostring(message))
  end
end

local function flogic_log_warn(message)
  print("[flologic] WARN: " .. tostring(message))
end

local function flogic_prop(name)
  if Properties == nil then
    return ""
  end
  return Properties[name] or ""
end

local function flogic_set_prop(name, value)
  if value == nil then
    value = ""
  end
  value = tostring(value)
  if flogic_prop(name) ~= value then
    C4:UpdateProperty(name, value)
  end
end

-- --- Transport: Director-managed TLS TCP connection -----------------------
-- Sessions run serially. A closing binding remains reserved until OFFLINE;
-- another session must not inherit its asynchronous disconnect callbacks.

local function flogic_find_free_binding()
  for id = FLOGIC_BINDING_FIRST, FLOGIC_BINDING_LAST do
    local ok, address = pcall(function()
      return C4:GetBindingAddress(id)
    end)
    if ok and (address == nil or address == "") and not flogic_state.retired_bindings[id] then
      return id
    end
  end
  return nil
end

local function flogic_ensure_binding(host, port)
  local st = flogic_state
  local id = flogic_find_free_binding()
  if id == nil then
    return nil, "no free network binding"
  end
  st.binding = id
  st.hub_host, st.hub_port = host, port
  C4:CreateNetworkConnection(st.binding, host, "SSL")
  C4:NetPortOptions(st.binding, port, "SSL", {
    AUTO_CONNECT = false,
    MONITOR_CONNECTION = false,
    KEEP_CONNECTION = false,
    KEEP_ALIVE = true,
    VERIFY_MODE = "peer",
    CACERTFILE = "./ca-bundle.pem",
  })
  return st.binding
end

function ReceivedFromNetwork(idBinding, nPort, strData)
  local st = flogic_state
  if st.binding == idBinding and st.hub_port == nPort and st.tcp_callbacks ~= nil then
    st.tcp_callbacks.on_data(strData)
  end
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
  local st = flogic_state
  if strStatus == "OFFLINE" and st.retired_bindings[idBinding] == nPort then
    st.retired_bindings[idBinding] = nil
    C4:SetBindingAddress(idBinding, "")
    return
  end
  if st.binding ~= idBinding or st.hub_port ~= nPort or st.tcp_callbacks == nil then
    return
  end
  if strStatus == "ONLINE" then
    st.tcp_callbacks.on_open()
  elseif strStatus == "OFFLINE" then
    st.tcp_callbacks.on_close()
  end
end

local function flogic_tcp_open(host, port, callbacks)
  local binding, err = flogic_ensure_binding(host, port)
  if binding == nil then
    return nil, err
  end
  flogic_state.tcp_callbacks = callbacks
  C4:NetConnect(binding, port)
  local handle = {}
  function handle.send(bytes)
    C4:SendToNetwork(binding, port, bytes)
  end
  function handle.close()
    if flogic_state.tcp_callbacks == callbacks then
      flogic_state.tcp_callbacks = nil
      flogic_state.binding = nil
      flogic_state.retired_bindings[binding] = port
      C4:NetDisconnect(binding, port)
    end
  end
  return handle
end

-- --- Transport: platform HTTPS for the negotiate step ----------------------

local function flogic_http_post(url, body, headers, cb)
  local transfer = C4:url()
  transfer:SetOptions({
    timeout = 30,
    connect_timeout = 10,
    ssl_verify_peer = true,
    ssl_verify_host = true,
    fail_on_error = false,
  })
  transfer:OnDone(function(_, responses, error_code, _error_message)
    local response = responses and responses[#responses]
    if error_code ~= 0 then
      cb("transport-" .. tostring(error_code), nil, response and response.code)
    else
      cb(nil, response and response.body or "", response and response.code)
    end
  end)
  transfer:Post(url, body, headers)
  return function()
    transfer:Cancel()
  end
end

local function flogic_http_get(url, headers, cb)
  local transfer = C4:url()
  transfer:SetOptions({
    timeout = 30,
    connect_timeout = 10,
    ssl_verify_peer = true,
    ssl_verify_host = true,
    fail_on_error = false,
  })
  transfer:OnDone(function(_, responses, code)
    local response = responses and responses[#responses]
    cb(code ~= 0 and "transport-error" or nil, response and response.body or "", response and response.code)
  end)
  transfer:Get(url, headers)
  return function()
    transfer:Cancel()
  end
end

local function flogic_check_update()
  local st = flogic_state
  if not st.initialized or st.updater then
    return
  end
  flogic_set_prop("Update Status", "Checking GitHub")
  flogic_set_prop("Update Download URL", "")
  flogic_set_prop("Latest Driver Version", "")
  local check
  check = FloUpdate.new_check({
    http_get = flogic_http_get,
    set_timeout = function(ms, callback)
      local timer = flogic_set_timer(ms, callback, false)
      return function()
        timer:Cancel()
      end
    end,
    on_result = function(err, release)
      if flogic_state ~= st or not st.initialized or st.updater ~= check then
        return
      end
      st.updater = nil
      if err then
        flogic_set_prop("Update Status", err)
      elseif not release then
        flogic_set_prop("Update Status", "No published C4 package found in recent releases")
      else
        flogic_set_prop("Latest Driver Version", release.version)
        flogic_set_prop("Update Download URL", release.url)
        local status = "Up to date"
        if release.version > FLOGIC_DRIVER_VERSION then
          status = "Update available: " .. release.version .. "; download and install with Composer"
        elseif release.version < FLOGIC_DRIVER_VERSION then
          status = "Running build is newer than the published release"
        end
        flogic_set_prop("Update Status", status)
      end
    end,
  })
  st.updater = check
  check.start()
end

local function flogic_schedule_update_checks()
  local st = flogic_state
  if st.update_timer then
    st.update_timer:Cancel()
    st.update_timer = nil
  end
  local hours = tonumber(flogic_prop("Update Check Interval")) or 24
  if hours ~= hours or hours <= 0 then
    return
  end
  hours = math.min(hours, 168)
  st.update_timer = flogic_set_timer(hours * 3600000, function()
    flogic_check_update()
  end, true)
end

-- --- Crypto / randomness (platform-backed, probed once) --------------------

local function flogic_probe_sha1()
  for _, name in ipairs({ "SHA1", "sha1", "SHA-1" }) do
    local ok, result, err = pcall(function()
      return C4:Hash(name, "test", { return_encoding = "NONE", data_encoding = "NONE" })
    end)
    if ok and result ~= nil and err == nil and #result == 20 then
      return name
    end
  end
  return nil
end

local function flogic_sha1(data)
  local out, err = C4:Hash(flogic_state.sha1_digest, data, { return_encoding = "NONE", data_encoding = "NONE" })
  if out == nil then
    error("C4:Hash failed: " .. tostring(err))
  end
  return out
end

--- Use the random portion of UUIDv4; omit its version/variant bytes.
local function flogic_random_bytes(count)
  local bytes = {}
  while #bytes < count do
    local uuid = assert(C4:UUID("RANDOM"), "UUID generation failed")
    local hex = uuid:gsub("%-", "")
    assert(#hex == 32 and not hex:find("[^%x]"), "invalid UUID")
    for i = 1, 12, 2 do
      bytes[#bytes + 1] = string.char(tonumber(hex:sub(i, i + 1), 16))
      if #bytes == count then
        break
      end
    end
  end
  return table.concat(bytes)
end

local function flogic_random_mask()
  return { flogic_random_bytes(4):byte(1, 4) }
end

local function flogic_client_key()
  return C4:Base64Encode(flogic_random_bytes(16))
end

-- --- Session orchestration --------------------------------------------------

local function flogic_new_session()
  return FloLogic.new_session({
    email = flogic_prop(FLOGIC_PROP_EMAIL),
    password = flogic_prop(FLOGIC_PROP_PASSWORD),
    device_code = flogic_state.device_code,
    device_token = flogic_state.device_token,
    http_post = flogic_http_post,
    tcp_open = flogic_tcp_open,
    set_timeout = function(ms, fn)
      local timer = flogic_set_timer(ms, function(t)
        t:Cancel()
        fn()
      end, false)
      return function()
        timer:Cancel()
      end
    end,
    client_key = flogic_client_key,
    sha1 = flogic_sha1,
    b64encode = function(data)
      return C4:Base64Encode(data)
    end,
    random_mask = flogic_random_mask,
    relog_token = flogic_state.relog_token,
    log = flogic_log,
  })
end

local function flogic_hub_url()
  local url = flogic_prop(FLOGIC_PROP_HUB)
  if url == nil or url == "" then
    url = FLOGIC_DEFAULT_HUB
  end
  return url
end

-- Effective valve selection: manual override wins, else the picker label's
-- "(id)" suffix, else blank (discovery only).
local function flogic_selection()
  local override = flogic_prop(FLOGIC_PROP_OVERRIDE)
  if override ~= nil and override:match("%S") ~= nil then
    return override:match("^%s*(.-)%s*$")
  end
  local picked = flogic_prop(FLOGIC_PROP_PICKER)
  if picked ~= nil then
    local id = picked:match("%(([^%)]+)%)%s*$")
    if id ~= nil then
      return id
    end
  end
  return ""
end

local function flogic_fire(name)
  flogic_log("event: " .. name)
  C4:FireEvent(name)
end

local function flogic_set_connection(ok, detail)
  local st = flogic_state
  if ok then
    flogic_set_prop(FLOGIC_PROP_CONNECTION, "Online")
  else
    flogic_set_prop(FLOGIC_PROP_CONNECTION, "Offline: " .. tostring(detail or "error"))
  end
  if st.last_connection_ok ~= nil and st.last_connection_ok ~= ok then
    if ok then
      flogic_fire(FLOGIC_EV_CONN_RESTORED)
    else
      flogic_fire(FLOGIC_EV_CONN_LOST)
    end
  end
  st.last_connection_ok = ok
end

local function flogic_describe_error(err)
  err = tostring(err or "error")
  if err == "auth" then
    return "authentication failed"
  end
  if err == "valve-not-found" then
    return "selected valve not on account"
  end
  if err == "no-valve" then
    return "no controllable valve"
  end
  return err
end

local function flogic_valve_label(valve)
  return FloModel.valve_name(valve):gsub("[,\r\n]", " ") .. " (" .. tostring(valve.id) .. ")"
end

local function flogic_update_picker(devices)
  local valves = FloModel.controllable_valves(devices)
  local labels = { "Select a valve" }
  local current = flogic_prop(FLOGIC_PROP_PICKER)
  local selected_id = current:match("%(([^%)]+)%)%s*$")
  local keep = labels[1]
  for _, valve in ipairs(valves) do
    local label = flogic_valve_label(valve)
    labels[#labels + 1] = label
    if tostring(valve.id) == selected_id then
      keep = label
    end
  end
  -- Preserve a missing valve's identity; never silently switch the site.
  if selected_id and keep == labels[1] then
    keep = "Unavailable (" .. selected_id .. ")"
    labels[#labels + 1] = keep
  end
  local joined = table.concat(labels, ",")
  if joined ~= flogic_state.last_picker_labels or current ~= keep then
    flogic_state.last_picker_labels = joined
    C4:UpdatePropertyList(FLOGIC_PROP_PICKER, joined, keep)
  end
  local lines = {}
  for _, valve in ipairs(valves) do
    lines[#lines + 1] = tostring(valve.id) .. ": " .. FloModel.valve_name(valve)
  end
  flogic_set_prop("Available Valves", table.concat(lines, " | "))
end

local function flogic_num(value)
  if value == nil or value == "" then
    return ""
  end
  return tostring(value)
end

local function flogic_update_properties(snap)
  local valve, access = snap.valve, snap.access
  local now = os.time()
  local elapsed = FloModel.flow_elapsed_seconds(valve, now)
  local countdown = FloModel.shutoff_countdown_seconds(valve, now)
  local flow_state = FloModel.FLOW_STATE_NAMES[valve.flowState]
  flogic_set_prop("Valve Name", FloModel.valve_name(valve))
  flogic_set_prop("Mode", FloModel.mode_status_name(valve))
  flogic_set_prop("Flow State", flow_state or flogic_num(valve.flowState))
  if FloModel.is_water_flowing(valve) then
    flogic_set_prop("Water Flowing", "Yes")
  else
    flogic_set_prop("Water Flowing", "No")
  end
  flogic_set_prop("Temperature", flogic_num(valve.temperature))
  flogic_set_prop("Battery Level", flogic_num(valve.batteryLevel))
  flogic_set_prop("Signal Strength", flogic_num(valve.signalStrength))
  flogic_set_prop("Current Flow", flogic_num(valve.currentFlow))
  flogic_set_prop("Home Limit", flogic_num(valve.homeIntervalTime))
  flogic_set_prop("Away Limit", flogic_num(valve.awayIntervalTime))
  flogic_set_prop("Bypass Time", flogic_num(valve.bypassTime))
  flogic_set_prop("Auto Away", flogic_num(valve.autoAwayTime))
  flogic_set_prop("Temp Alert", flogic_num(valve.lowTemperatureAlert))
  flogic_set_prop("Temp Shutoff", flogic_num(valve.lowTemperatureLimit))
  flogic_set_prop("Pre-Alert", flogic_num(valve.preAlertNoticeInterval))
  flogic_set_prop("No-Flow Notice", flogic_num(valve.noFlowNoticeInterval))
  flogic_set_prop("Flow Sensitivity", flogic_num(valve.dripRate))
  flogic_set_prop("Shutoff Countdown", flogic_num(countdown))
  flogic_set_prop("Flow Elapsed", flogic_num(elapsed))
  flogic_set_prop("Scheduler Events", tostring(#FloModel.active_scheduler_events(snap.scheduler)))
  flogic_set_prop("Notifications", tostring(#(snap.notifications or {})))
  flogic_set_prop("Last Update", os.date("%Y-%m-%d %H:%M:%S"))
  if access ~= nil then
    local flags = FloModel.notification_flags(access)
    flogic_log("notify advance_shutoff=" .. tostring(flags.advance_shutoff))
  end
end

local function flogic_process_edges(snap)
  local st = flogic_state
  local valve, access = snap.valve, snap.access
  local mode = FloModel.mode_status_name(valve)
  local flowing = FloModel.is_water_flowing(valve)
  local raw_mode = tonumber(valve.mode)
  local water_off = raw_mode ~= nil and FloModel.has_any_flag(raw_mode, FloModel.WATER_OFF_MODE_FLAGS)
  local warning = raw_mode ~= nil and FloModel.has_any_flag(raw_mode, FloModel.WARNING_ALERT_MODE_FLAGS)
  local critical = raw_mode ~= nil and FloModel.has_any_flag(raw_mode, FloModel.CRITICAL_MODE_FLAGS)
  local advance = FloModel.advance_shutoff_warning(valve, access)
  local first = st.last_mode == nil
  if not first then
    if flowing and not st.last_flowing then
      flogic_fire(FLOGIC_EV_FLOW_STARTED)
    elseif st.last_flowing and not flowing then
      flogic_fire(FLOGIC_EV_FLOW_STOPPED)
    end
    if water_off and not st.last_water_off then
      flogic_fire(FLOGIC_EV_WATER_OFF)
    elseif st.last_water_off and not water_off then
      flogic_fire(FLOGIC_EV_WATER_OFF_CLEAR)
    end
    if warning and not st.last_warning then
      flogic_fire(FLOGIC_EV_WARNING)
    elseif st.last_warning and not warning then
      flogic_fire(FLOGIC_EV_WARNING_CLEAR)
    end
    if critical and not st.last_critical then
      flogic_fire(FLOGIC_EV_CRITICAL)
    elseif st.last_critical and not critical then
      flogic_fire(FLOGIC_EV_CRITICAL_CLEAR)
    end
    if advance and not st.last_advance then
      flogic_fire(FLOGIC_EV_ADVANCE)
    end
    if mode ~= st.last_mode then
      flogic_fire(FLOGIC_EV_MODE_CHANGED)
    end
  end
  st.last_mode, st.last_flowing = mode, flowing
  st.last_water_off, st.last_warning = water_off, warning
  st.last_critical, st.last_advance = critical, advance
end

local function flogic_sync_tick_timer()
  local st = flogic_state
  local snap = st.last_snapshot
  local flowing = snap ~= nil and FloModel.is_water_flowing(snap.valve)
  if flowing and st.tick_timer == nil then
    st.tick_timer = flogic_set_timer(FLOGIC_LOCAL_TICK_MS, function()
      local current = flogic_state.last_snapshot
      if current == nil or not FloModel.is_water_flowing(current.valve) then
        if flogic_state.tick_timer ~= nil then
          flogic_state.tick_timer:Cancel()
          flogic_state.tick_timer = nil
        end
        return
      end
      local now = os.time()
      flogic_set_prop("Shutoff Countdown", flogic_num(FloModel.shutoff_countdown_seconds(current.valve, now)))
      flogic_set_prop("Flow Elapsed", flogic_num(FloModel.flow_elapsed_seconds(current.valve, now)))
      if FloModel.advance_shutoff_warning(current.valve, current.access, now) and not flogic_state.last_advance then
        flogic_state.last_advance = true
        flogic_fire(FLOGIC_EV_ADVANCE)
      end
    end, true)
  elseif not flowing and st.tick_timer ~= nil then
    st.tick_timer:Cancel()
    st.tick_timer = nil
  end
end

--- Status-only relay providers. Initial/bind sync must not fire transition programming.
local function flogic_relay_notify(binding, closed, initial)
  local command = closed and "CLOSED" or "OPENED"
  if initial then
    command = "STATE_" .. command
  end
  C4:SendToProxy(binding, command, {}, "NOTIFY")
end

local function flogic_update_relays(valve)
  local st = flogic_state
  local mode = valve and tonumber(valve.mode)
  if
    not valve
    or valve.online ~= true
    or not mode
    or mode ~= mode
    or mode < 0
    or mode == math.huge
    or mode % 1 ~= 0
  then
    st.relay_states = nil
    return
  end
  local flags = FloModel.VALVE_MODE_FLAGS
  local current = {
    [FLOGIC_RELAY_VALVE_CLOSED] = FloModel.has_any_flag(mode, FloModel.WATER_OFF_MODE_FLAGS),
    [FLOGIC_RELAY_AWAY] = FloModel.has_any_flag(mode, { flags.away, flags.auto_away, flags.external_away }),
  }
  local previous = st.relay_states or {}
  st.relay_states = current
  for _, binding in ipairs({ FLOGIC_RELAY_VALVE_CLOSED, FLOGIC_RELAY_AWAY }) do
    if previous[binding] == nil or previous[binding] ~= current[binding] then
      flogic_relay_notify(binding, current[binding], previous[binding] == nil)
    end
  end
end

local function flogic_sync_relay(binding)
  local st = flogic_state
  if not st.initialized or not st.relay_states then
    return
  end
  local value = st.relay_states[binding]
  if value ~= nil then
    flogic_relay_notify(binding, value, true)
  end
end

function OnBindingChanged(idBinding, strClass, bIsBound)
  if strClass == "RELAY" and bIsBound then
    flogic_sync_relay(idBinding)
  end
end

function ReceivedFromProxy(idBinding, strCommand, _tParams)
  if idBinding ~= FLOGIC_RELAY_VALVE_CLOSED and idBinding ~= FLOGIC_RELAY_AWAY then
    return
  end
  -- These outputs report status, never accept commands to move the physical valve.
  if strCommand == "GET_STATE" then
    flogic_sync_relay(idBinding)
  end
end

local function flogic_on_snapshot(snap, session)
  local st = flogic_state
  st.last_snapshot = snap
  if session.relog_token ~= nil and session.relog_token ~= "" and session.relog_token ~= st.relog_token then
    st.relog_token = session.relog_token
    C4:PersistSetValue("flologic_relog", session.relog_token, true)
  end
  flogic_set_connection(snap.valve == nil or snap.valve.online == true, "selected valve offline")
  flogic_update_picker(snap.devices)
  if snap.valve == nil then
    st.last_snapshot, st.relay_states = nil, nil
    flogic_set_prop(FLOGIC_PROP_CONNECTION, "Select a valve")
    return
  end
  flogic_update_properties(snap)
  flogic_update_relays(snap.valve)
  flogic_process_edges(snap)
  flogic_sync_tick_timer()
end

local function flogic_clear_snapshot()
  local st = flogic_state
  st.last_snapshot, st.last_mode, st.relay_states = nil, nil, nil
  if st.tick_timer then
    st.tick_timer:Cancel()
    st.tick_timer = nil
  end
  flogic_set_prop("Shutoff Countdown", "")
  flogic_set_prop("Flow Elapsed", "")
end

local function flogic_on_session_error(where, err)
  flogic_clear_snapshot()
  flogic_log_warn(where .. " failed: " .. tostring(err))
  flogic_set_connection(false, flogic_describe_error(err))
end

-- --- Poll and command engines (one session at a time) ----------------------

local function flogic_run_next()
  local st = flogic_state
  if st.busy or not st.initialized then
    return
  end
  local job = table.remove(st.command_queue, 1)
  if job == nil then
    return
  end
  st.busy = true
  local session = flogic_new_session()
  st.session = session
  session.send_command(flogic_hub_url(), job.selected, job.fields, function(err)
    if st.session ~= session then
      return
    end
    st.session = nil
    st.busy = false
    if err ~= nil then
      flogic_set_prop("Last Command", job.name .. ": failed (" .. flogic_describe_error(err) .. ")")
      flogic_on_session_error("command " .. job.name, err)
    else
      flogic_log("command " .. job.name .. " ok; refreshing")
      flogic_set_prop("Last Command", job.name .. ": acknowledged; awaiting refresh")
      flogic_poll_soon(5000)
    end
    flogic_run_next()
  end)
end

function flogic_poll_soon(delay_ms)
  local st = flogic_state
  if not st.initialized then
    return
  end
  if st.soon_timer then
    st.soon_timer:Cancel()
  end
  st.soon_timer = flogic_set_timer(delay_ms or 1000, function(t)
    t:Cancel()
    st.soon_timer = nil
    flogic_poll_now()
  end, false)
end

function flogic_poll_now()
  local st = flogic_state
  if st.busy or not st.initialized then
    flogic_log("poll skipped: session busy")
    return
  end
  if flogic_prop(FLOGIC_PROP_EMAIL) == "" or flogic_prop(FLOGIC_PROP_PASSWORD) == "" then
    flogic_set_prop(FLOGIC_PROP_CONNECTION, "Not configured")
    return
  end
  if st.sha1_digest == nil then
    flogic_set_connection(false, "no SHA1 digest available")
    return
  end
  st.busy = true
  local session = flogic_new_session()
  st.session = session
  session.fetch_snapshot(flogic_hub_url(), flogic_selection(), function(err, snap)
    if st.session ~= session then
      return
    end
    st.session = nil
    st.busy = false
    if err ~= nil then
      flogic_on_session_error("poll", err)
    else
      flogic_on_snapshot(snap, session)
    end
    flogic_run_next()
  end)
end

local function flogic_poll_interval_ms()
  local seconds = tonumber(flogic_prop(FLOGIC_PROP_POLL)) or 60
  if seconds ~= seconds then
    seconds = 60
  end
  if seconds < FLOGIC_MIN_POLL_SECONDS then
    seconds = FLOGIC_MIN_POLL_SECONDS
  elseif seconds > FLOGIC_MAX_POLL_SECONDS then
    seconds = FLOGIC_MAX_POLL_SECONDS
  end
  return seconds * 1000
end

local function flogic_restart_poll_timer()
  local st = flogic_state
  if st.poll_timer ~= nil then
    st.poll_timer:Cancel()
    st.poll_timer = nil
  end
  st.poll_timer = flogic_set_timer(flogic_poll_interval_ms(), function()
    flogic_poll_now()
  end, true)
end

-- --- Commands (programming) -------------------------------------------------

local function flogic_queue_command(name, fields)
  local st = flogic_state
  local selected = flogic_selection()
  if
    not st.initialized
    or selected == ""
    or #st.command_queue >= 8
    or flogic_prop(FLOGIC_PROP_EMAIL) == ""
    or flogic_prop(FLOGIC_PROP_PASSWORD) == ""
  then
    flogic_set_prop("Last Command", name .. ": rejected; check configuration or queue capacity")
    return
  end
  st.command_queue[#st.command_queue + 1] = { name = name, fields = fields, selected = selected }
  flogic_set_prop("Last Command", name .. ": queued")
  flogic_run_next()
end

local function flogic_param_number(params, name, minimum, maximum, fractional)
  local raw = params ~= nil and params[name] or nil
  local value = tonumber(raw)
  if value == nil or value ~= value or (not fractional and value % 1 ~= 0) or value < minimum or value > maximum then
    return nil
  end
  return value
end

function ExecuteCommand(strCommand, tParams)
  if strCommand == "LUA_ACTION" then
    strCommand = tParams and tParams.ACTION
  end
  if strCommand == "Refresh GitHub Updates" then
    strCommand = "Check for Update"
  end
  flogic_log("command: " .. tostring(strCommand))
  if strCommand == "Check for Update" then
    flogic_check_update()
    return
  elseif strCommand == "Refresh" then
    flogic_poll_now()
    return
  elseif strCommand == "Refresh Valve List" then
    flogic_poll_now() -- picker refreshes from every snapshot
    return
  end
  local mode_commands = {
    ["Set Mode Home"] = "home",
    ["Set Mode Away"] = "away",
    ["Set Mode Bypass"] = "bypass",
    ["Set Mode Shutoff"] = "shutoff",
    ["Set Mode Disabled"] = "disabled",
  }
  local mode = mode_commands[strCommand]
  if mode ~= nil then
    flogic_queue_command(strCommand, { mode = FloModel.VALVE_MODES[mode] })
    return
  end
  local value_commands = {
    ["Set Home Limit"] = { param = "Minutes", field = "homeIntervalTime", min = 1, max = 10080 },
    ["Set Away Limit"] = { param = "Minutes", field = "awayIntervalTime", min = 0, max = 10080, fractional = true },
    ["Set Bypass Time"] = { param = "Minutes", field = "bypassTime", min = 1, max = 10080 },
    ["Set Auto Away"] = { param = "Hours", field = "autoAwayTime", min = 1, max = 8760 },
    ["Set Temp Alert"] = { param = "Temperature", field = "lowTemperatureAlert", min = -50, max = 150 },
    ["Set Temp Shutoff"] = { param = "Temperature", field = "lowTemperatureLimit", min = -50, max = 150 },
    ["Set Pre-Alert"] = { param = "Minutes", field = "preAlertNoticeInterval", min = 1, max = 10080 },
    ["Set No-Flow Notice"] = { param = "Seconds", field = "noFlowNoticeInterval", min = 1, max = 604800 },
    ["Set Flow Sensitivity"] = { param = "Value", field = "dripRate", min = 0, max = 1000, fractional = true },
  }
  local spec = value_commands[strCommand]
  if spec == nil then
    flogic_log_warn("unknown command: " .. tostring(strCommand))
    return
  end
  local value = flogic_param_number(tParams, spec.param, spec.min, spec.max, spec.fractional)
  if value == nil then
    flogic_log_warn("command " .. strCommand .. " rejected: bad " .. spec.param)
    return
  end
  flogic_queue_command(strCommand, { [spec.field] = value })
end

-- --- Lifecycle --------------------------------------------------------------

local function flogic_restore_relog()
  local saved = C4:PersistGetValue("flologic_relog")
  if type(saved) == "string" then
    flogic_state.relog_token = saved
  end
end

function OnDriverInit(driver_init_type)
  -- Publish the running version even if Composer already shows the XML default.
  C4:UpdateProperty("Driver Version", FLOGIC_DRIVER_VERSION)
  print("[flologic] OnDriverInit: " .. FLOGIC_DRIVER_VERSION .. " (" .. tostring(driver_init_type) .. ")")
  flogic_restore_relog()
end

function OnDriverLateInit(driver_init_type)
  print("[flologic] OnDriverLateInit: " .. FLOGIC_DRIVER_VERSION .. " (" .. tostring(driver_init_type) .. ")")
  flogic_retire_runtime()
  flogic_state = flogic_fresh_state()
  flogic_restore_relog()
  C4:UpdateProperty("Driver Version", FLOGIC_DRIVER_VERSION)
  flogic_set_prop(FLOGIC_PROP_CONNECTION, "Initializing")
  for _, key in ipairs({ "device_code", "device_token" }) do
    local saved = C4:PersistGetValue("flologic_" .. key)
    if type(saved) ~= "string" or saved == "" then
      saved = assert(C4:UUID("RANDOM"))
      C4:PersistSetValue("flologic_" .. key, saved, true)
    end
    flogic_state[key] = saved
  end
  flogic_state.sha1_digest = flogic_probe_sha1()
  if flogic_state.sha1_digest == nil then
    flogic_set_prop(FLOGIC_PROP_CONNECTION, "Offline: no SHA1 digest available")
    flogic_log_warn("no working SHA1 digest; websocket handshake impossible")
    return
  end
  flogic_state.initialized = true
  OnPropertyChanged(FLOGIC_PROP_DEBUG)
  flogic_restart_poll_timer()
  flogic_poll_soon(2000)
  flogic_schedule_update_checks()
  flogic_state.update_start_timer = flogic_set_timer(10000, function()
    flogic_state.update_start_timer = nil
    flogic_check_update()
  end, false)
  print("[flologic] Runtime ready: " .. FLOGIC_DRIVER_VERSION)
end

local function flogic_cancel_work()
  local st = flogic_state
  local session = st.session
  st.session, st.busy = nil, false
  if session then
    session.cancel()
  end
  if st.soon_timer then
    st.soon_timer:Cancel()
    st.soon_timer = nil
  end
  if #st.command_queue > 0 then
    flogic_set_prop("Last Command", "Queued commands cancelled")
  end
  st.command_queue = {}
  flogic_clear_snapshot()
end

function OnDriverDestroyed(driver_init_type)
  print("[flologic] OnDriverDestroyed: " .. FLOGIC_DRIVER_VERSION .. " (" .. tostring(driver_init_type) .. ")")
  flogic_retire_runtime()
end

function OnDriverUpdated()
  OnDriverLateInit("OnDriverUpdated")
end

function OnDriverRemovedFromProject()
  OnDriverDestroyed()
end

function OnPropertyChanged(strProperty)
  if not flogic_state.initialized then
    return
  end
  flogic_log("property changed: " .. tostring(strProperty))
  if strProperty == FLOGIC_PROP_DEBUG then
    if flogic_state.debug_timer then
      flogic_state.debug_timer:Cancel()
    end
    if flogic_prop(FLOGIC_PROP_DEBUG) == "On" then
      flogic_state.debug_timer = flogic_set_timer(10800000, function()
        flogic_set_prop(FLOGIC_PROP_DEBUG, "Off")
        flogic_state.debug_timer = nil
      end, false)
    end
  elseif strProperty == "Update Check Interval" then
    flogic_schedule_update_checks()
  elseif strProperty == FLOGIC_PROP_POLL then
    flogic_restart_poll_timer()
  elseif
    strProperty == FLOGIC_PROP_EMAIL
    or strProperty == FLOGIC_PROP_PASSWORD
    or strProperty == FLOGIC_PROP_HUB
    or strProperty == FLOGIC_PROP_PICKER
    or strProperty == FLOGIC_PROP_OVERRIDE
  then
    flogic_cancel_work()
    if strProperty == FLOGIC_PROP_EMAIL or strProperty == FLOGIC_PROP_PASSWORD or strProperty == FLOGIC_PROP_HUB then
      flogic_state.relog_token = ""
      C4:PersistSetValue("flologic_relog", "", true)
      flogic_state.last_picker_labels = nil
    end
    if strProperty == FLOGIC_PROP_EMAIL or strProperty == FLOGIC_PROP_HUB then
      flogic_set_prop(FLOGIC_PROP_OVERRIDE, "")
      C4:UpdatePropertyList(FLOGIC_PROP_PICKER, "Select a valve", "Select a valve")
      flogic_set_prop("Available Valves", "")
    end
    flogic_set_prop(FLOGIC_PROP_CONNECTION, "Refreshing configuration")
    flogic_poll_soon(1000)
  end
end
