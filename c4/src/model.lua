-- ============================================================================
-- c4/src/model.lua — FloLogic constants and valve/account decoding.
--
-- Pure logic ported from custom_components/flologic/{const,api}.py. Defines
-- the global FloModel table only. No require, no return, no top-level
-- execution, Lua 5.1 safe (no bitwise operators: flag tests use arithmetic).
-- ============================================================================

FloModel = FloModel or {}

-- Controllable valve modes: name -> cloud bit value.
FloModel.VALVE_MODES = { home = 1, away = 2, bypass = 4, shutoff = 8, disabled = 16 }
FloModel.MODE_NAMES = { [1] = "home", [2] = "away", [4] = "bypass", [8] = "shutoff", [16] = "disabled" }

FloModel.VALVE_MODE_FLAGS = {
  home = 1, away = 2, bypass = 4, shutoff = 8, disabled = 16,
  flow_time_exceeded = 32, external_leak = 64, auto_away = 128,
  external_bypass = 256, delay_away = 512, external_away = 1024,
  override = 2048, ac_lost = 4096, change_battery = 8192, error = 16384,
  sensor_leak = 32768, system_down = 65536, valve_failure = 131072,
  communication_error = 262144, external_home = 524288,
  external_emergency_shutdown = 1048576, updating = 2097152,
  external_override = 4194304, low_temp_alert = 8388608,
  low_temp_shutoff = 16777216, humidity_sensor_shutoff = 33554432,
  low_temp_sensor_shutoff = 67108864, unknown = 268435456,
}

local F = FloModel.VALVE_MODE_FLAGS
FloModel.MODE_FLAG_NAMES = {}
for name, bit in pairs(F) do
  FloModel.MODE_FLAG_NAMES[bit] = name
end

FloModel.WATER_OFF_MODE_FLAGS = {
  F.flow_time_exceeded, F.external_leak, F.sensor_leak, F.shutoff,
  F.external_emergency_shutdown, F.low_temp_shutoff,
  F.humidity_sensor_shutoff, F.low_temp_sensor_shutoff,
}
FloModel.WARNING_ALERT_MODE_FLAGS = {
  F.low_temp_alert, F.change_battery, F.ac_lost, F.communication_error, F.updating,
}
FloModel.CRITICAL_MODE_FLAGS = { F.error, F.system_down, F.valve_failure, F.unknown }

FloModel.MODE_STATUS_PRIORITY = {
  F.flow_time_exceeded, F.sensor_leak, F.external_leak,
  F.external_emergency_shutdown, F.low_temp_shutoff,
  F.humidity_sensor_shutoff, F.low_temp_sensor_shutoff, F.shutoff,
  F.delay_away, F.auto_away, F.external_away, F.away, F.external_bypass,
  F.bypass, F.external_home, F.home, F.disabled, F.updating,
  F.communication_error, F.valve_failure, F.system_down, F.error, F.unknown,
}

FloModel.FLOW_STATE_NAMES = { [1] = "No flow", [2] = "New flow", [4] = "Flow", [8] = "Valve closed" }

FloModel.NOTIFICATION_FLAGS = {
  always = 1, never = 2, mode_change = 4, auto_shutoff = 8, auto_away = 16,
  delay_away = 32, advance_shutoff = 64, guest_mode = 128,
  connection_change = 256, general_alert = 512, critical_error = 1024,
  no_flow = 2048,
}

-- Lua 5.1 has no bitwise operators: test a single power-of-two flag
-- arithmetically. All flag values used here are exact in doubles.
function FloModel.has_flag(value, flag)
  if value == nil or flag == nil or flag <= 0 then
    return false
  end
  return math.floor(value / flag) % 2 == 1
end

function FloModel.has_any_flag(value, flags)
  for _, flag in ipairs(flags) do
    if FloModel.has_flag(value, flag) then
      return true
    end
  end
  return false
end

local function to_number(value)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    return tonumber(value)
  end
  return nil
end

function FloModel.unique_id_prefix(valve)
  local uuid = valve.uuid
  if uuid ~= nil and uuid ~= "" then
    return tostring(uuid)
  end
  return tostring(valve.id)
end

function FloModel.valve_name(valve)
  return valve.valveFriendlyName
    or valve.combinedName
    or valve.name
    or valve.uuid
    or "FloLogic"
end

function FloModel.mode_name(valve)
  local mode = to_number(valve.mode)
  if mode == nil then
    return nil
  end
  local exact = FloModel.MODE_NAMES[mode]
  if exact ~= nil then
    return exact
  end
  local modes = FloModel.VALVE_MODES
  if FloModel.has_any_flag(mode, FloModel.WATER_OFF_MODE_FLAGS) then
    return "shutoff"
  end
  if FloModel.has_flag(mode, modes.bypass) then
    return "bypass"
  end
  if FloModel.has_flag(mode, modes.away) then
    return "away"
  end
  if FloModel.has_flag(mode, modes.home) then
    return "home"
  end
  if FloModel.has_flag(mode, modes.disabled) then
    return "disabled"
  end
  return nil
end

function FloModel.mode_status_name(valve)
  local mode = to_number(valve.mode)
  if mode == nil then
    return "unknown"
  end
  local exact = FloModel.MODE_NAMES[mode]
  if exact ~= nil then
    return exact
  end
  for _, flag in ipairs(FloModel.MODE_STATUS_PRIORITY) do
    if FloModel.has_flag(mode, flag) then
      return FloModel.MODE_FLAG_NAMES[flag]
    end
  end
  return "unknown_" .. tostring(mode)
end

function FloModel.mode_flag_names(valve)
  local mode = to_number(valve.mode)
  if mode == nil then
    return {}
  end
  local names = {}
  for flag, name in pairs(FloModel.MODE_FLAG_NAMES) do
    if FloModel.has_flag(mode, flag) then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

function FloModel.notification_flags(access)
  local raw = 0
  if access ~= nil then
    raw = to_number(access.notificationsList) or 0
  end
  local flags = {}
  for name, bit in pairs(FloModel.NOTIFICATION_FLAGS) do
    flags[name] = FloModel.has_flag(raw, bit)
  end
  return flags
end

function FloModel.is_water_flowing(valve)
  if valve.online ~= true then
    return false
  end
  local state = valve.flowState
  return state ~= nil and state ~= 1 and state ~= 8
end

-- Parse a FloLogic ISO-8601 timestamp as a UTC epoch. Returns nil when the
-- value is absent or malformed. os.time interprets tables as local time, so
-- the result is shifted by the controller's UTC offset.
function FloModel.parse_datetime_utc(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  local y, mo, d, h, mi, s = value:match(
    "^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)"
  )
  if y == nil then
    return nil
  end
  local as_local = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  })
  if as_local == nil then
    return nil
  end
  local now = os.time()
  local utc_offset = os.difftime(now, os.time(os.date("!*t", now)))
  return as_local + utc_offset
end

local function current_flow_limit_minutes(valve)
  local mode = FloModel.mode_name(valve)
  if mode == "home" then
    return to_number(valve.homeIntervalTime)
  elseif mode == "away" then
    return to_number(valve.awayIntervalTime)
  elseif mode == "bypass" then
    return to_number(valve.bypassTime)
  end
  return nil
end

function FloModel.flow_started_at(valve)
  if not FloModel.is_water_flowing(valve) then
    return nil
  end
  return FloModel.parse_datetime_utc(valve.lastNewFlow)
end

function FloModel.flow_elapsed_seconds(valve, now_epoch)
  local started = FloModel.flow_started_at(valve)
  if started == nil then
    return nil
  end
  local elapsed = (now_epoch or os.time()) - started
  if elapsed < 0 then
    return 0
  end
  return math.floor(elapsed)
end

function FloModel.shutoff_countdown_seconds(valve, now_epoch)
  if not FloModel.is_water_flowing(valve) then
    return nil
  end
  local limit = current_flow_limit_minutes(valve)
  if limit == nil or limit <= 0 then
    return nil
  end
  local started = FloModel.parse_datetime_utc(valve.lastNewFlow)
  if started == nil then
    return nil
  end
  local remaining = (started + limit * 60) - (now_epoch or os.time())
  if remaining < 0 then
    return 0
  end
  return math.floor(remaining)
end

function FloModel.advance_shutoff_warning(valve, access, now_epoch)
  if not FloModel.notification_flags(access).advance_shutoff then
    return false
  end
  local countdown = FloModel.shutoff_countdown_seconds(valve, now_epoch)
  if countdown == nil then
    return false
  end
  local pre_alert = to_number(valve.preAlertNoticeInterval) or 0
  return countdown >= 0 and countdown <= pre_alert * 60
end

function FloModel.active_scheduler_events(scheduler)
  local active = {}
  if type(scheduler) ~= "table" then
    return active
  end
  for _, event in ipairs(scheduler) do
    if type(event) == "table" and event.action ~= nil and event.actionPayload ~= nil then
      active[#active + 1] = event
    end
  end
  return active
end

-- Valve discovery mirrors the Home Assistant client: exclude explicit
-- gateways, prefer positively identified Connect valves, and otherwise fall
-- back to every non-gateway device (older payloads without type metadata).
function FloModel.controllable_valves(devices)
  if type(devices) ~= "table" or #devices == 0 then
    return {}
  end
  local candidates = {}
  for _, device in ipairs(devices) do
    if type(device) == "table" and device.isZGateway ~= true then
      candidates[#candidates + 1] = device
    end
  end
  local valves = {}
  for _, device in ipairs(candidates) do
    local type_name = string.lower(tostring(device.deviceTypeName or ""))
    if device.isZConnect == true
      or device.isAnyConnect == true
      or type_name:find("connect", 1, true) ~= nil
    then
      valves[#valves + 1] = device
    end
  end
  if #valves > 0 then
    return valves
  end
  return candidates
end

-- Primary-valve preference used when no explicit selection exists.
function FloModel.choose_valve(devices)
  local valves = FloModel.controllable_valves(devices)
  for _, valve in ipairs(valves) do
    if valve.isZConnect == true then
      return valve
    end
  end
  for _, valve in ipairs(valves) do
    if valve.isAnyConnect == true then
      return valve
    end
  end
  return valves[1]
end

function FloModel.find_valve(devices, needle)
  local want = tostring(needle)
  local want_folded = string.lower(want)
  for _, device in ipairs(devices) do
    if type(device) == "table" then
      if tostring(device.id) == want or tostring(device.uuid) == want then
        return device
      end
    end
  end
  for _, device in ipairs(devices) do
    if type(device) == "table" then
      if string.lower(tostring(device.id)) == want_folded
        or string.lower(tostring(device.uuid)) == want_folded
      then
        return device
      end
    end
  end
  return nil
end

function FloModel.mode_value(mode)
  local value = FloModel.VALVE_MODES[mode]
  if value == nil then
    local valid = {}
    for name, _ in pairs(FloModel.VALVE_MODES) do
      valid[#valid + 1] = name
    end
    table.sort(valid)
    error("Unknown FloLogic mode '" .. tostring(mode) .. "'; valid modes: " .. table.concat(valid, ", "))
  end
  return value
end
