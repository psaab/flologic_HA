-- ============================================================================
-- c4/valve/valve.lua — FloLogic Water Valve (per-valve companion) Director glue.
--
-- One driver instance per physical valve. Holds no credentials and runs no
-- poll loop: it binds to one cloud-driver slot over the static link
-- connection, shows that valve's state, exports seven CONTACT_SENSOR
-- outputs for programming, and appears in the app as a light_v2 switch
-- that shuts water off or turns it on when clicked.
--
-- Identity (VALVE-U4, see README.md): the Composer binding selects the
-- valve. The slot's cloud handshake (FLOGIC_IDENTITY) is authoritative;
-- the persisted id is display continuity only and is never trusted across
-- binds — every bind re-handshakes from scratch (plan D3). There is no
-- valve picker and no Valve ID Override, mirroring CLOUD-U6 on the cloud
-- driver. An unbound valve displays "Not linked" and issues nothing.
--
-- Transport (plan D1): peer-driver BindMessages primary
-- (SendToProxy/ReceivedFromProxy on the link id), SendToDevice fallback
-- with provider discovery plus the FLOGIC_FROM hint when the proxy send
-- raises. The cloud ignores the hint key when parsing, so the wire
-- contract never changes.
--
-- Bundled AFTER json/model/update plus the shared link protocol (see
-- bundle.sh). Defines Director entry points (OnDriverInit,
-- OnDriverLateInit, ExecuteCommand, ...) plus module state. No top-level
-- C4 calls (safe to load in tests with a stub C4). Lua 5.1 safe.
-- ============================================================================

FLOVALVE_DRIVER_VERSION = "2026090802"
print("[flologic-valve] Lua loaded: " .. FLOVALVE_DRIVER_VERSION)

-- Static link consumer (binds to one cloud-driver FLOGIC_VALVE slot) and
-- the switch-only light proxy (see driver.xml; ids must match).
FLOVALVE_LINK_ID = 600
FLOVALVE_LIGHT_ID = 5001
FLOVALVE_LINK_CLASS = "FLOGIC_VALVE"

-- Minimum seconds between GET_STATE retries while digests keep arriving.
FLOVALVE_DIGEST_RETRY_S = 60

-- Seconds a command may await its ack/nack before the valve settles it
-- locally as lost (cloud restarted mid-command, reply dropped).
FLOVALVE_ACK_TIMEOUT_S = 120

-- Seven contact outputs (plan D5). 101/102 semantics are ported from
-- c4/src/main.lua (attribution); 103-107 derive from the same mode flags
-- plus the link slice's online/flow_state fields.
FLOVALVE_CONTACT_CLOSED = 101
FLOVALVE_CONTACT_AWAY = 102
FLOVALVE_CONTACT_FLOWING = 103
FLOVALVE_CONTACT_LEAK = 104
FLOVALVE_CONTACT_WARNING = 105
FLOVALVE_CONTACT_CRITICAL = 106
FLOVALVE_CONTACT_ONLINE = 107

FLOVALVE_CONTACTS = {
  FLOVALVE_CONTACT_CLOSED,
  FLOVALVE_CONTACT_AWAY,
  FLOVALVE_CONTACT_FLOWING,
  FLOVALVE_CONTACT_LEAK,
  FLOVALVE_CONTACT_WARNING,
  FLOVALVE_CONTACT_CRITICAL,
  FLOVALVE_CONTACT_ONLINE,
}

-- Additive hint attached to SendToDevice fallback sends so the cloud can
-- attribute a sender ExecuteCommand cannot name. Extra keys are ignored
-- by FloLogicLink.parse, so this never alters the wire contract.
FLOVALVE_K_FROM = "FLOGIC_FROM"

-- Property names (must match c4/valve/driver.xml). Deliberately no
-- credentials, no picker, no override (VALVE-U4): binding + handshake is
-- the only selection mechanism.
FLOVALVE_PROP_DEBUG = "Debug Mode"
FLOVALVE_PROP_UPDATE_INTERVAL = "Update Check Interval"
FLOVALVE_PROP_VALVE_ID = "Valve ID"
FLOVALVE_PROP_VALVE_NAME = "Valve Name"
FLOVALVE_PROP_CONNECTION = "Connection"
FLOVALVE_PROP_LAST_UPDATE = "Last Link Update"

-- Event names (must match c4/valve/driver.xml). Advance Shutoff Warning
-- is intentionally absent: the link slice carries no lastNewFlow or
-- pre-alert window, so the valve cannot compute it (see README.md).
FLOVALVE_EV_FLOW_STARTED = "Flow Started"
FLOVALVE_EV_FLOW_STOPPED = "Flow Stopped"
FLOVALVE_EV_WATER_OFF = "Water Off Detected"
FLOVALVE_EV_WATER_OFF_CLEAR = "Water Off Cleared"
FLOVALVE_EV_WARNING = "Warning Alert"
FLOVALVE_EV_WARNING_CLEAR = "Warning Cleared"
FLOVALVE_EV_CRITICAL = "Critical Fault"
FLOVALVE_EV_CRITICAL_CLEAR = "Critical Cleared"
FLOVALVE_EV_MODE_CHANGED = "Mode Changed"
FLOVALVE_EV_CONN_LOST = "Connection Lost"
FLOVALVE_EV_CONN_RESTORED = "Connection Restored"

FLOVALVE_PERSIST_ID = "flovalve_valve_id"
FLOVALVE_PERSIST_STATE = "flovalve_last_state"
FLOVALVE_PERSIST_VERSION = "flovalve_last_version"

-- Link action vocabulary. Names and value ranges are the cloud driver's
-- contract (c4/cloud/cloud.lua FLOCLOUD_*_ACTIONS, read-only): the valve
-- forwards, the cloud validates again and NACKs anything unknown.
FLOVALVE_RESTORE_DEFAULT = "mode_home"
FLOVALVE_VALUE_ACTIONS = {
  home_limit = { param = "Minutes", min = 1, max = 10080 },
  away_limit = { param = "Minutes", min = 0, max = 10080, fractional = true },
  bypass_time = { param = "Minutes", min = 1, max = 10080 },
  auto_away = { param = "Hours", min = 1, max = 8760 },
  temp_alert = { param = "Temperature", min = -50, max = 150 },
  temp_shutoff = { param = "Temperature", min = -50, max = 150 },
  pre_alert = { param = "Minutes", min = 1, max = 10080 },
  noflow_notice = { param = "Seconds", min = 1, max = 604800 },
  flow_sensitivity = { param = "Value", min = 0, max = 1000, fractional = true },
}

-- The shared updater defaults to the monolith asset (c4/src/update.lua is
-- read-only); each driver repoints it at its own package (plan D7).
if FloUpdate ~= nil then
  FloUpdate.ASSET = "flologic_valve.c4z"
end

-- Runs FIRST, before replacing module tables or Director callbacks on hot
-- reload. Retires this load's timers, updater, and SOAP binding so a new
-- load never inherits their callbacks.
function flovalve_retire_runtime()
  local previous = flovalve_state
  if not previous then
    return
  end
  previous.initialized = false
  for _, name in ipairs({ "debug_timer", "update_timer", "update_start_timer", "soap_grace" }) do
    local timer = previous[name]
    previous[name] = nil
    if timer then
      pcall(function()
        timer:Cancel()
      end)
    end
  end
  if previous.updater then
    pcall(previous.updater.cancel)
    previous.updater = nil
  end
  if previous.soap_binding and previous.soap_port then
    pcall(function()
      C4:NetDisconnect(previous.soap_binding, previous.soap_port)
    end)
  end
  previous.soap_binding, previous.soap_port, previous.soap_callbacks = nil, nil, nil
end

flovalve_retire_runtime()

-- Driver state. No sessions, no queue: commands forward to the cloud
-- immediately and correlate by cmd_id; displayed state changes only on
-- FLOGIC_STATE pushes, never on ack alone.
local function flovalve_fresh_state()
  return {
    initialized = false,
    link_bound = false,
    valve_id = nil,
    valve_id_persisted = flovalve_state and flovalve_state.valve_id_persisted or nil,
    last_state = nil,
    contact_states = nil,
    last_mode = nil,
    last_flowing = nil,
    last_water_off = nil,
    last_warning = nil,
    last_critical = nil,
    last_connection_ok = nil,
    restore_action = (flovalve_state and flovalve_state.restore_action) or FLOVALVE_RESTORE_DEFAULT,
    last_level = (flovalve_state and flovalve_state.last_level) or 0,
    pending_commands = {},
    cmd_seq = (flovalve_state and flovalve_state.cmd_seq) or 0,
  }
end

flovalve_state = flovalve_fresh_state()

--- Timer closures belong to this load, even if Director delivers a cancelled tick.
local function flovalve_set_timer(ms, callback, repeating)
  local owner = flovalve_state
  return C4:SetTimer(ms, function(timer)
    if flovalve_state == owner and owner.initialized then
      callback(timer)
    end
  end, repeating)
end

local function flovalve_log(message)
  if Properties ~= nil and Properties[FLOVALVE_PROP_DEBUG] == "On" then
    print("[flologic-valve] " .. tostring(message))
  end
end

local function flovalve_log_warn(message)
  print("[flologic-valve] WARN: " .. tostring(message))
end

local function flovalve_prop(name)
  if Properties == nil then
    return ""
  end
  return Properties[name] or ""
end

local function flovalve_set_prop(name, value)
  if value == nil then
    value = ""
  end
  value = tostring(value)
  if flovalve_prop(name) ~= value then
    C4:UpdateProperty(name, value)
  end
end

local function flovalve_fire(name)
  flovalve_log("event: " .. name)
  C4:FireEvent(name)
end

local function flovalve_set_connection(ok, detail)
  local st = flovalve_state
  if ok then
    flovalve_set_prop(FLOVALVE_PROP_CONNECTION, "Online")
  else
    flovalve_set_prop(FLOVALVE_PROP_CONNECTION, "Offline: " .. tostring(detail or "error"))
  end
  if st.last_connection_ok ~= nil and st.last_connection_ok ~= ok then
    if ok then
      flovalve_fire(FLOVALVE_EV_CONN_RESTORED)
    else
      flovalve_fire(FLOVALVE_EV_CONN_LOST)
    end
  end
  st.last_connection_ok = ok
end

-- --- Contact outputs --------------------------------------------------------
-- Status-only providers ported from c4/src/main.lua (attribution):
-- initial/bind sync reports steady state (STATE_*) and must not fire
-- transition programming; only genuine changes emit CLOSED/OPENED.

local function flovalve_contact_notify(binding, closed, initial)
  local command = closed and "CLOSED" or "OPENED"
  if initial then
    command = "STATE_" .. command
  end
  C4:SendToProxy(binding, command, {}, "NOTIFY")
end

-- Derive all seven contact values from one validated link state slice.
-- Returns a binding->boolean table, or nil when the slice is unusable
-- (callers then leave programming untouched, never flap it).
function flovalve_contact_values(fields)
  if type(fields) ~= "table" then
    return nil
  end
  local mode = fields.mode
  -- Monolith parity (c4/src/main.lua): only non-negative integers carry
  -- flag semantics. Floats would floor silently and negatives test every
  -- flag set under modulo arithmetic, so both leave programming untouched.
  if type(mode) ~= "number" or mode ~= mode or mode == math.huge or mode == -math.huge or mode % 1 ~= 0 or mode < 0 then
    return nil
  end
  local online = fields.online == true
  local flow_state = tonumber(fields.flow_state)
  local flags = FloModel.VALVE_MODE_FLAGS
  return {
    [FLOVALVE_CONTACT_CLOSED] = FloModel.has_any_flag(mode, FloModel.WATER_OFF_MODE_FLAGS),
    [FLOVALVE_CONTACT_AWAY] = FloModel.has_any_flag(mode, { flags.away, flags.auto_away, flags.external_away }),
    [FLOVALVE_CONTACT_FLOWING] = online and flow_state ~= nil and flow_state ~= 1 and flow_state ~= 8,
    [FLOVALVE_CONTACT_LEAK] = FloModel.has_any_flag(mode, { flags.external_leak, flags.sensor_leak }),
    [FLOVALVE_CONTACT_WARNING] = FloModel.has_any_flag(mode, FloModel.WARNING_ALERT_MODE_FLAGS),
    [FLOVALVE_CONTACT_CRITICAL] = FloModel.has_any_flag(mode, FloModel.CRITICAL_MODE_FLAGS),
    [FLOVALVE_CONTACT_ONLINE] = online,
  }
end

local function flovalve_update_contacts(fields)
  local st = flovalve_state
  local current = flovalve_contact_values(fields)
  if current == nil then
    return false
  end
  local previous = st.contact_states or {}
  st.contact_states = current
  for _, binding in ipairs(FLOVALVE_CONTACTS) do
    if previous[binding] == nil or previous[binding] ~= current[binding] then
      flovalve_contact_notify(binding, current[binding], previous[binding] == nil)
    end
  end
  return true
end

local function flovalve_sync_contact(binding)
  local st = flovalve_state
  if not st.initialized or not st.contact_states then
    return
  end
  local value = st.contact_states[binding]
  if value ~= nil then
    flovalve_contact_notify(binding, value, true)
  end
end

-- --- Blended state helpers --------------------------------------------------

local function flovalve_is_water_off(fields)
  return fields ~= nil and FloModel.has_any_flag(fields.mode, FloModel.WATER_OFF_MODE_FLAGS)
end

local function flovalve_is_flowing(fields)
  if fields == nil or fields.online ~= true then
    return false
  end
  local flow_state = tonumber(fields.flow_state)
  return flow_state ~= nil and flow_state ~= 1 and flow_state ~= 8
end

local function flovalve_level_for(fields)
  if flovalve_is_water_off(fields) then
    return 0
  end
  return 100
end

local function flovalve_report_level(level)
  flovalve_state.last_level = level
  C4:SendToProxy(FLOVALVE_LIGHT_ID, "LIGHT_LEVEL", { LEVEL = level }, "NOTIFY")
end

-- Track the last non-shutoff mode so Open/Toggle restores it (plan:
-- default Home). Water-off pushes never overwrite the restore target.
local function flovalve_track_restore(fields)
  local st = flovalve_state
  if fields == nil or flovalve_is_water_off(fields) then
    return
  end
  local name = FloModel.mode_name({ mode = fields.mode })
  if name == "home" or name == "away" or name == "bypass" or name == "disabled" then
    st.restore_action = "mode_" .. name
  end
end

-- --- Link send: BindMessages primary, SendToDevice fallback -----------------

-- Provider discovery for the fallback leg. Returns an array of cloud
-- driver device ids, or nil when Director cannot answer (the caller then
-- sends to nobody rather than guessing).
local function flovalve_bound_providers()
  local name = nil
  if C4.GetBoundProviderDevices ~= nil then
    name = "GetBoundProviderDevices"
  elseif C4.GetBoundProviderDevice ~= nil then
    name = "GetBoundProviderDevice"
  end
  if name == nil then
    return nil
  end
  local ok, found = pcall(function()
    return C4[name](C4, 0, FLOVALVE_LINK_ID)
  end)
  if not ok then
    return nil
  end
  local ids = {}
  if type(found) == "table" then
    for _, id in pairs(found) do
      if tonumber(id) ~= nil then
        ids[#ids + 1] = id
      end
    end
  elseif tonumber(found) ~= nil then
    ids[#ids + 1] = found
  end
  return ids
end

-- Send one link envelope toward the cloud. Returns "proxy", "device", or
-- nil plus a reason when nothing could be sent.
function flovalve_send_to_cloud(envelope)
  local name = envelope[FloLogicLink.K_MSG]
  local ok = pcall(function()
    C4:SendToProxy(FLOVALVE_LINK_ID, name, envelope, "COMMAND")
  end)
  if ok then
    return "proxy"
  end
  local providers = flovalve_bound_providers() or {}
  local hinted = {}
  for key, value in pairs(envelope) do
    hinted[key] = value
  end
  -- Pre-handshake hellos carry no identity the cloud could attribute, so
  -- the hint is attached only once the handshake has provided one.
  if flovalve_state.valve_id_persisted ~= nil and flovalve_state.valve_id_persisted ~= "" then
    hinted[FLOVALVE_K_FROM] = flovalve_state.valve_id_persisted
  end
  for _, device_id in ipairs(providers) do
    pcall(function()
      C4:SendToDevice(device_id, name, hinted)
    end)
  end
  flovalve_log_warn("link fell back to SendToDevice (" .. #providers .. " providers)")
  if #providers == 0 then
    return nil, "no-link-route"
  end
  return "device"
end

local function flovalve_send_hello()
  flovalve_log("link FLOGIC_HELLO")
  flovalve_send_to_cloud(FloLogicLink.build_hello())
end

local function flovalve_send_get_state()
  local envelope = FloLogicLink.build_get_state()
  if envelope ~= nil then
    flovalve_send_to_cloud(envelope)
  end
end

local function flovalve_next_cmd_id()
  local st = flovalve_state
  st.cmd_seq = st.cmd_seq + 1
  return "v" .. tostring(st.cmd_seq) .. "-" .. tostring(os.time())
end

-- Forward one validated link action. Returns true when sent; commands
-- with no handshake identity are dropped locally (the cloud would drop
-- them unattributed anyway) with a display note, never a crash.
-- Pending entries with no ack/nack (lost reply, cloud restarted
-- mid-command) would stick "sent" on the display forever: expire them
-- lazily on the next activity instead of running a sweeper timer.
local function flovalve_expire_pending(now)
  local st = flovalve_state
  for cmd_id, pending in pairs(st.pending_commands) do
    if now - (pending.sent_at or now) >= FLOVALVE_ACK_TIMEOUT_S then
      st.pending_commands[cmd_id] = nil
      if flovalve_prop("Last Command") == pending.label .. ": sent (awaiting cloud refresh)" then
        flovalve_set_prop("Last Command", pending.label .. ": no response from cloud")
      end
    end
  end
end

function flovalve_send_command(action, params, label)
  local st = flovalve_state
  label = label or action
  if st.valve_id == nil then
    flovalve_log_warn("command " .. label .. " dropped: not linked (no handshake identity)")
    flovalve_set_prop("Last Command", label .. ": not linked")
    return false
  end
  flovalve_expire_pending(os.time())
  local cmd_id = flovalve_next_cmd_id()
  local envelope, err = FloLogicLink.build_command(cmd_id, action, params)
  if envelope == nil then
    flovalve_log_warn("command " .. label .. " rejected locally: " .. tostring(err))
    flovalve_set_prop("Last Command", label .. ": rejected (" .. tostring(err) .. ")")
    return false
  end
  st.pending_commands[cmd_id] = { action = action, label = label, sent_at = os.time() }
  local route, route_err = flovalve_send_to_cloud(envelope)
  if route == nil then
    st.pending_commands[cmd_id] = nil
    flovalve_log_warn("command " .. label .. " has no link route: " .. tostring(route_err))
    flovalve_set_prop("Last Command", label .. ": no link route")
    return false
  end
  flovalve_log("command " .. label .. " sent (" .. cmd_id .. " via " .. route .. ")")
  flovalve_set_prop("Last Command", label .. ": sent (awaiting cloud refresh)")
  return true
end

-- --- Link receive: handshake, full-state apply, ack/nack --------------------
-- Displayed state changes only on FLOGIC_STATE pushes, never on ack alone
-- (link contract). Acks/nacks only settle the Last Command display.

local function flovalve_num(value)
  if value == nil or value == "" then
    return ""
  end
  return tostring(value)
end

local function flovalve_update_display(fields)
  flovalve_set_prop(FLOVALVE_PROP_VALVE_NAME, fields.name or ("Valve " .. tostring(fields.id)))
  flovalve_set_prop("Mode", FloModel.mode_status_name({ mode = fields.mode }))
  local flow_state = tonumber(fields.flow_state)
  flovalve_set_prop("Flow State", FloModel.FLOW_STATE_NAMES[flow_state] or flovalve_num(fields.flow_state))
  if flovalve_is_flowing(fields) then
    flovalve_set_prop("Water Flowing", "Yes")
  else
    flovalve_set_prop("Water Flowing", "No")
  end
  flovalve_set_prop("Home Limit", flovalve_num(fields.home_interval))
  flovalve_set_prop("Away Limit", flovalve_num(fields.away_interval))
  flovalve_set_prop("Bypass Time", flovalve_num(fields.bypass_time))
  flovalve_set_prop(FLOVALVE_PROP_LAST_UPDATE, os.date("%Y-%m-%d %H:%M:%S"))
end

-- Per-valve edge events ported from c4/src/main.lua flogic_process_edges
-- (attribution), evaluated against link slices. The first full push sets
-- the baseline and fires nothing, so a restart never replays history.
local function flovalve_process_edges(fields)
  local st = flovalve_state
  local mode = FloModel.mode_status_name({ mode = fields.mode })
  local flowing = flovalve_is_flowing(fields)
  local raw_mode = tonumber(fields.mode)
  local water_off = raw_mode ~= nil and FloModel.has_any_flag(raw_mode, FloModel.WATER_OFF_MODE_FLAGS)
  local warning = raw_mode ~= nil and FloModel.has_any_flag(raw_mode, FloModel.WARNING_ALERT_MODE_FLAGS)
  local critical = raw_mode ~= nil and FloModel.has_any_flag(raw_mode, FloModel.CRITICAL_MODE_FLAGS)
  local first = st.last_mode == nil
  if not first then
    if flowing and not st.last_flowing then
      flovalve_fire(FLOVALVE_EV_FLOW_STARTED)
    elseif st.last_flowing and not flowing then
      flovalve_fire(FLOVALVE_EV_FLOW_STOPPED)
    end
    if water_off and not st.last_water_off then
      flovalve_fire(FLOVALVE_EV_WATER_OFF)
    elseif st.last_water_off and not water_off then
      flovalve_fire(FLOVALVE_EV_WATER_OFF_CLEAR)
    end
    if warning and not st.last_warning then
      flovalve_fire(FLOVALVE_EV_WARNING)
    elseif st.last_warning and not warning then
      flovalve_fire(FLOVALVE_EV_WARNING_CLEAR)
    end
    if critical and not st.last_critical then
      flovalve_fire(FLOVALVE_EV_CRITICAL)
    elseif st.last_critical and not critical then
      flovalve_fire(FLOVALVE_EV_CRITICAL_CLEAR)
    end
    if mode ~= st.last_mode then
      flovalve_fire(FLOVALVE_EV_MODE_CHANGED)
    end
  end
  st.last_mode, st.last_flowing = mode, flowing
  st.last_water_off, st.last_warning = water_off, warning
  st.last_critical = critical
end

local function flovalve_apply_state(fields, body)
  local st = flovalve_state
  st.last_state = fields
  st.digest_retry_at = nil
  flovalve_expire_pending(os.time())
  C4:PersistSetValue(FLOVALVE_PERSIST_STATE, body, true)
  flovalve_track_restore(fields)
  flovalve_update_display(fields)
  flovalve_update_contacts(fields)
  -- Reported level is 0 iff a water-off flag is active, else 100: the
  -- inverse of the Valve Closed contact (plan).
  flovalve_report_level(flovalve_level_for(fields))
  flovalve_process_edges(fields)
  flovalve_set_connection(true)
end

local function flovalve_on_identity(valve_id)
  local st = flovalve_state
  st.valve_id = valve_id
  st.valve_id_persisted = valve_id
  C4:PersistSetValue(FLOVALVE_PERSIST_ID, valve_id, true)
  flovalve_set_prop(FLOVALVE_PROP_VALVE_ID, valve_id)
  flovalve_log("link bound to valve " .. valve_id)
  -- The cloud already pushes its latest slice on hello, but a GET_STATE
  -- covers the race where it had nothing cached yet.
  flovalve_send_get_state()
end

local function flovalve_on_state(env)
  local st = flovalve_state
  if env.truncated then
    -- Digest-only envelope: keep the last full state and mark the link
    -- degraded. Retries are rate-limited: each GET_STATE re-elicits the
    -- same digest, which would otherwise ping-pong at message speed
    -- until the next poll shrinks the slice.
    flovalve_log_warn("link state digest-only; keeping last full state")
    flovalve_set_prop(FLOVALVE_PROP_CONNECTION, "Degraded: oversized snapshot (retrying)")
    local now = os.time()
    if st.digest_retry_at == nil or now - st.digest_retry_at >= FLOVALVE_DIGEST_RETRY_S then
      st.digest_retry_at = now
      flovalve_send_get_state()
    end
    return true
  end
  if st.valve_id == nil then
    -- State ahead of identity (restart races): never adopt an
    -- unverified id — hello and drop instead. The cloud answers with
    -- this slot's authoritative identity plus its cached slice, so the
    -- link still converges within one round trip.
    flovalve_log("link state before identity; helloing instead of adopting")
    flovalve_send_hello()
    return false
  elseif tostring(env.fields.id) ~= tostring(st.valve_id) then
    -- A slot rebinding mid-life must never paint another valve's state
    -- here: ignore it and re-handshake to learn the new identity.
    flovalve_log_warn(
      "link state for valve "
        .. tostring(env.fields.id)
        .. " does not match "
        .. tostring(st.valve_id)
        .. "; re-handshaking"
    )
    st.valve_id = nil
    flovalve_send_hello()
    return false
  end
  flovalve_apply_state(env.fields, env.body)
  return true
end

local function flovalve_on_ack(cmd_id, acked, reason)
  local st = flovalve_state
  local pending = st.pending_commands[cmd_id]
  if pending == nil then
    flovalve_log_warn("link ack for unknown command " .. tostring(cmd_id) .. "; ignored")
    return false
  end
  st.pending_commands[cmd_id] = nil
  if acked then
    flovalve_log("command " .. pending.label .. " acknowledged")
    flovalve_set_prop("Last Command", pending.label .. ": acknowledged; awaiting refresh")
  else
    flovalve_log_warn("command " .. pending.label .. " rejected: " .. tostring(reason))
    flovalve_set_prop("Last Command", pending.label .. ": rejected (" .. tostring(reason) .. ")")
    -- The tile level was set optimistically when the command went out;
    -- roll it back to the last cloud-confirmed state so a failed shutoff
    -- (or open) never displays the action that did not happen.
    if st.last_state ~= nil then
      flovalve_report_level(flovalve_level_for(st.last_state))
    end
  end
  return true
end

-- Shared link ingress for both transports (proxy Receive + ExecuteCommand
-- fallback). Returns true when a well-formed cloud->valve message was
-- handled; malformed or misrouted traffic warns and is dropped, never a
-- crash.
function flovalve_handle_link(strCommand, params)
  local env, err = FloLogicLink.parse(params)
  if env == nil then
    flovalve_log_warn("link parse (" .. tostring(strCommand) .. "): " .. tostring(err))
    return false
  end
  if not FloLogicLink.is_cloud_to_valve(env.msg) then
    flovalve_log_warn("misrouted link message: " .. tostring(env.msg))
    return false
  end
  flovalve_log("link " .. env.msg .. " (" .. tostring(strCommand) .. ")")
  if env.msg == FloLogicLink.MSG_IDENTITY then
    flovalve_on_identity(env.valve_id)
    return true
  elseif env.msg == FloLogicLink.MSG_STATE then
    return flovalve_on_state(env)
  elseif env.msg == FloLogicLink.MSG_CMD_ACK then
    return flovalve_on_ack(env.cmd_id, true)
  elseif env.msg == FloLogicLink.MSG_CMD_NACK then
    return flovalve_on_ack(env.cmd_id, false, env.error_reason)
  end
  return false
end

-- --- Link membership --------------------------------------------------------
-- Every bind re-handshakes (plan D3): the authoritative id is cleared and
-- re-learned, so a rebound slot can never inherit the previous valve.

local function flovalve_on_link_bound()
  local st = flovalve_state
  st.link_bound = true
  st.valve_id = nil
  flovalve_set_prop(FLOVALVE_PROP_CONNECTION, "Linking...")
  flovalve_send_hello()
end

local function flovalve_on_link_unbound()
  local st = flovalve_state
  st.link_bound = false
  st.valve_id = nil
  local dropped = 0
  for cmd_id in pairs(st.pending_commands) do
    st.pending_commands[cmd_id] = nil
    dropped = dropped + 1
  end
  if dropped > 0 then
    flovalve_set_prop("Last Command", "Link lost: " .. dropped .. " command(s) dropped")
  end
  -- Last-known contacts and display stay put (programming must not flap
  -- on a link outage); only the link marking goes stale. The edge fires
  -- first, then the richer text overwrites its generic "Offline" line.
  flovalve_set_connection(false, "link unbound")
  local last = flovalve_prop(FLOVALVE_PROP_LAST_UPDATE)
  if last ~= "" then
    last = " (last update " .. last .. ")"
  end
  flovalve_set_prop(FLOVALVE_PROP_CONNECTION, "Not linked" .. last)
end

-- Best-effort read of our own bound state for startup display. Nil means
-- Director cannot answer (assume bound and hello anyway); an empty list
-- means unbound (stay silent until the bind event).
local function flovalve_link_has_provider()
  local providers = flovalve_bound_providers()
  if providers == nil then
    return true
  end
  return #providers > 0
end

-- --- Light proxy (app switch) -------------------------------------------------
-- Navigator clicks arrive as DYNAMIC_ON/DYNAMIC_OFF (OS 3.3.2+);
-- programming and scenes use TOGGLE and SET_BRIGHTNESS_TARGET (level > 0
-- on, 0 off). OFF issues the shutoff mode; ON restores the last
-- non-shutoff mode tracked from state pushes (default Home). The tile
-- level reports optimistically for responsiveness; contacts, properties,
-- and events still change only on FLOGIC_STATE pushes.

local function flovalve_open_valve(label)
  if flovalve_send_command(flovalve_state.restore_action, nil, label or "Open Valve") then
    flovalve_report_level(100)
    return true
  end
  return false
end

local function flovalve_close_valve(label)
  if flovalve_send_command("mode_shutoff", nil, label or "Close Valve") then
    flovalve_report_level(0)
    return true
  end
  return false
end

local function flovalve_toggle_valve(label)
  if flovalve_state.last_level >= 50 then
    return flovalve_close_valve(label or "Toggle")
  end
  return flovalve_open_valve(label or "Toggle")
end

function flovalve_on_light(strCommand, tParams)
  if strCommand == "DYNAMIC_ON" then
    flovalve_open_valve("Open Valve")
  elseif strCommand == "DYNAMIC_OFF" then
    flovalve_close_valve("Close Valve")
  elseif strCommand == "TOGGLE" then
    flovalve_toggle_valve("Toggle")
  elseif strCommand == "SET_BRIGHTNESS_TARGET" then
    local level = tonumber(tParams ~= nil and tParams.LEVEL or nil)
    if level == nil then
      flovalve_log_warn("SET_BRIGHTNESS_TARGET without LEVEL; ignored")
      return false
    end
    if level > 0 then
      flovalve_open_valve("Open Valve")
    else
      flovalve_close_valve("Close Valve")
    end
  else
    flovalve_log("light proxy command ignored: " .. tostring(strCommand))
    return false
  end
  return true
end

-- --- Director ingress ---------------------------------------------------------

function ReceivedFromProxy(idBinding, strCommand, tParams)
  if idBinding == FLOVALVE_LIGHT_ID then
    flovalve_on_light(strCommand, tParams or {})
    return
  end
  if idBinding == FLOVALVE_LINK_ID then
    flovalve_handle_link(strCommand, tParams or {})
    return
  end
  -- Status-only contact outputs report state, never accept commands to
  -- move the physical valve (ported from c4/src/main.lua).
  for _, binding in ipairs(FLOVALVE_CONTACTS) do
    if idBinding == binding then
      if strCommand == "GET_STATE" then
        flovalve_sync_contact(idBinding)
      end
      return
    end
  end
end

function OnBindingChanged(idBinding, strClass, bIsBound)
  -- Match on binding id, not the class string: Director may report the
  -- link's custom class or plain CONTROL depending on version.
  if idBinding == FLOVALVE_LINK_ID then
    if bIsBound then
      flovalve_log("link bound; handshaking")
      flovalve_on_link_bound()
    else
      flovalve_log("link unbound")
      flovalve_on_link_unbound()
    end
    return
  end
  if idBinding == FLOVALVE_LIGHT_ID then
    -- A freshly bound tile (new Navigator session) would otherwise sit
    -- dark until the next cloud push: replay the last confirmed level.
    -- With no state yet there is nothing truthful to show, so stay
    -- quiet rather than report the default.
    if bIsBound and flovalve_state.last_state ~= nil then
      flovalve_report_level(flovalve_level_for(flovalve_state.last_state))
    end
    return
  end
  if strClass == "CONTACT_SENSOR" and bIsBound then
    flovalve_sync_contact(idBinding)
  end
end

-- --- Programming commands -----------------------------------------------------
-- Open/Close/Toggle plus the monolith's mode/limit set, forwarded as
-- FLOGIC_COMMAND bodies. Value ranges mirror the cloud driver's link
-- action set (which revalidates and NACKs anything out of range).

FLOVALVE_PROGRAM_COMMANDS = {
  ["Open Valve"] = { kind = "open" },
  ["Close Valve"] = { kind = "close" },
  ["Toggle"] = { kind = "toggle" },
  ["Set Mode Home"] = { kind = "action", action = "mode_home" },
  ["Set Mode Away"] = { kind = "action", action = "mode_away" },
  ["Set Mode Bypass"] = { kind = "action", action = "mode_bypass" },
  ["Set Mode Shutoff"] = { kind = "action", action = "mode_shutoff" },
  ["Set Mode Disabled"] = { kind = "action", action = "mode_disabled" },
  ["Set Home Limit"] = { kind = "value", action = "home_limit" },
  ["Set Away Limit"] = { kind = "value", action = "away_limit" },
  ["Set Bypass Time"] = { kind = "value", action = "bypass_time" },
  ["Set Auto Away"] = { kind = "value", action = "auto_away" },
  ["Set Temp Alert"] = { kind = "value", action = "temp_alert" },
  ["Set Temp Shutoff"] = { kind = "value", action = "temp_shutoff" },
  ["Set Pre-Alert"] = { kind = "value", action = "pre_alert" },
  ["Set No-Flow Notice"] = { kind = "value", action = "noflow_notice" },
  ["Set Flow Sensitivity"] = { kind = "value", action = "flow_sensitivity" },
}

local function flovalve_param_number(params, name, minimum, maximum, fractional)
  local raw = params ~= nil and params[name] or nil
  local value = tonumber(raw)
  if value == nil or value ~= value or (not fractional and value % 1 ~= 0) or value < minimum or value > maximum then
    return nil
  end
  return value
end

local function flovalve_run_program_command(strCommand, tParams)
  local spec = FLOVALVE_PROGRAM_COMMANDS[strCommand]
  if spec == nil then
    return false
  end
  if spec.kind == "open" then
    flovalve_open_valve(strCommand)
  elseif spec.kind == "close" then
    flovalve_close_valve(strCommand)
  elseif spec.kind == "toggle" then
    flovalve_toggle_valve(strCommand)
  elseif spec.kind == "action" then
    flovalve_send_command(spec.action, nil, strCommand)
  else
    local range = FLOVALVE_VALUE_ACTIONS[spec.action]
    local value = flovalve_param_number(tParams, range.param, range.min, range.max, range.fractional)
    if value == nil then
      flovalve_log_warn("command " .. strCommand .. " rejected: bad " .. range.param)
      flovalve_set_prop("Last Command", strCommand .. ": rejected (bad " .. range.param .. ")")
      return true
    end
    flovalve_send_command(spec.action, { value = value }, strCommand)
  end
  return true
end

-- --- Self-update (report-only check + Composer install) -----------------------
-- Ported from c4/cloud/cloud.lua (attribution); the asset and lookup keys
-- are the valve package, not the cloud one. The valve owns no poll loop,
-- so this block is only the GitHub check/install transports.

local function flovalve_http_get(url, headers, cb)
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
    cb(
      code ~= 0 and "transport-error" or nil,
      response and response.body or "",
      response and response.code,
      response and response.headers
    )
  end)
  transfer:Get(url, headers)
  return function()
    transfer:Cancel()
  end
end

local function flovalve_check_update()
  local st = flovalve_state
  if not st.initialized or st.updater then
    return
  end
  flovalve_set_prop("Update Status", "Checking GitHub")
  flovalve_set_prop("Update Download URL", "")
  flovalve_set_prop("Latest Driver Version", "")
  local check
  check = FloUpdate.new_check({
    http_get = flovalve_http_get,
    set_timeout = function(ms, callback)
      local timer = flovalve_set_timer(ms, callback, false)
      return function()
        timer:Cancel()
      end
    end,
    on_result = function(err, release)
      if flovalve_state ~= st or not st.initialized or st.updater ~= check then
        return
      end
      st.updater = nil
      if err then
        flovalve_set_prop("Update Status", err)
      elseif not release then
        flovalve_set_prop("Update Status", "No published C4 package found in recent releases")
      else
        flovalve_set_prop("Latest Driver Version", release.version)
        flovalve_set_prop("Update Download URL", release.url)
        local status = "Up to date"
        if release.version > FLOVALVE_DRIVER_VERSION then
          status = "Update available: " .. release.version .. "; run Install Latest Release"
        elseif release.version < FLOVALVE_DRIVER_VERSION then
          status = "Running build is newer than the published release"
        end
        flovalve_set_prop("Update Status", status)
      end
    end,
  })
  st.updater = check
  check.start()
end

local function flovalve_schedule_update_checks()
  local st = flovalve_state
  if st.update_timer then
    st.update_timer:Cancel()
    st.update_timer = nil
  end
  local hours = tonumber(flovalve_prop("Update Check Interval")) or 24
  if hours ~= hours or hours <= 0 then
    return
  end
  hours = math.min(hours, 168)
  st.update_timer = flovalve_set_timer(hours * 3600000, function()
    flovalve_check_update()
  end, true)
end

local function flovalve_file_set_dir(alias)
  local candidates = { alias }
  if alias ~= "C4Z" then
    candidates[#candidates + 1] = "C4Z"
  end
  for _, candidate in ipairs(candidates) do
    local ok = pcall(function()
      C4:FileSetDir(candidate)
    end)
    if ok then
      return true
    end
  end
  return false
end

local function flovalve_file_exists(name)
  local ok, exists = pcall(function()
    return C4:FileExists(name)
  end)
  return ok and exists == true
end

local function flovalve_file_delete(name)
  pcall(function()
    C4:FileDelete(name)
  end)
end

local function flovalve_file_write(name, data)
  local handle
  pcall(function()
    handle = C4:FileOpen(name)
    if handle ~= nil and handle ~= -1 then
      C4:FileWrite(handle, #data, data)
    end
  end)
  if handle ~= nil and handle ~= -1 then
    pcall(function()
      C4:FileClose(handle)
    end)
  end
end

local function flovalve_file_size(name)
  local handle
  local ok, size = pcall(function()
    if not C4:FileExists(name) then
      return nil
    end
    handle = C4:FileOpen(name)
    if handle == nil or handle == -1 then
      return nil
    end
    return C4:FileGetSize(handle)
  end)
  if handle ~= nil and handle ~= -1 then
    pcall(function()
      C4:FileClose(handle)
    end)
  end
  if ok then
    return size
  end
  return nil
end

local function flovalve_get_installed(filename)
  local ok, devices = pcall(function()
    return C4:GetDevicesByC4iName(filename)
  end)
  return ok and type(devices) == "table" and next(devices) ~= nil
end

-- One transient plain-TCP binding for Composer's local SOAP endpoint.
-- Binding ids are per driver instance, so the 6100 pool never collides
-- with the cloud driver's own pool on the same controller.
local function flovalve_find_free_binding()
  for id = 6100, 6199 do
    local ok, address = pcall(function()
      return C4:GetBindingAddress(id)
    end)
    if ok and (address == nil or address == "") and flovalve_state.soap_binding ~= id then
      return id
    end
  end
  return nil
end

local function flovalve_ensure_soap_binding()
  local st = flovalve_state
  if st.soap_binding ~= nil then
    return st.soap_binding
  end
  local id = flovalve_find_free_binding()
  if id == nil then
    return nil, "no free network binding"
  end
  local ok = pcall(function()
    C4:CreateNetworkConnection(id, FloUpdate.SOAP_HOST, "TCP")
    C4:NetPortOptions(id, FloUpdate.SOAP_PORT, "TCP", {
      AUTO_CONNECT = false,
      MONITOR_CONNECTION = false,
      KEEP_CONNECTION = false,
    })
  end)
  if not ok then
    return nil, "cannot open Composer endpoint"
  end
  st.soap_binding, st.soap_port = id, FloUpdate.SOAP_PORT
  return id
end

local function flovalve_soap_send(packet, cb)
  local settled = false
  local owner = flovalve_state
  local binding, err = flovalve_ensure_soap_binding()
  if binding == nil then
    cb(err)
    return function() end
  end
  local function finish(soap_err)
    if settled then
      return
    end
    settled = true
    if flovalve_state == owner then
      owner.soap_callbacks = nil
      pcall(function()
        C4:NetDisconnect(binding, FloUpdate.SOAP_PORT)
      end)
    end
    cb(soap_err)
  end
  -- Neither receipt of bytes nor connection closure confirms installation.
  -- The caller must report the result as unconfirmed; only the loaded driver
  -- can establish its running version.
  local opened = false
  local grace = flovalve_set_timer(3000, function()
    finish(nil)
  end, false)
  owner.soap_grace = grace
  owner.soap_callbacks = {
    on_data = function()
      finish(nil)
    end,
    on_open = function()
      opened = true
      local sent = pcall(function()
        C4:SendToNetwork(binding, FloUpdate.SOAP_PORT, packet)
      end)
      if not sent then
        finish("cannot reach Composer endpoint")
      end
    end,
    on_close = function()
      if opened then
        finish(nil)
      else
        finish("cannot reach Composer endpoint")
      end
    end,
  }
  local ok = pcall(function()
    C4:NetConnect(binding, FloUpdate.SOAP_PORT)
  end)
  if not ok then
    grace:Cancel()
    finish("cannot reach Composer endpoint")
  end
  return function()
    grace:Cancel()
    finish(nil)
  end
end

local function flovalve_install_update(force)
  local st = flovalve_state
  if not st.initialized then
    return
  end
  if st.updater then
    flovalve_set_prop("Update Status", "Update operation already running")
    return
  end
  flovalve_set_prop(
    "Update Status",
    force and "Force-reinstalling the latest release..." or "Checking GitHub for the latest release..."
  )
  local op
  op = FloUpdate.new_install({
    http_get = flovalve_http_get,
    set_timeout = function(ms, callback)
      local timer = flovalve_set_timer(ms, callback, false)
      return function()
        timer:Cancel()
      end
    end,
    -- Try the .c4i proxy name first, then the bare proxy name, then the
    -- package filename, so no single wrong guess can disable installs.
    -- Confirm which key matches on a live Director.
    get_installed = function()
      return flovalve_get_installed("flologic_valve.c4i")
        or flovalve_get_installed("flologic_valve")
        or flovalve_get_installed(FloUpdate.ASSET)
    end,
    file_set_dir = flovalve_file_set_dir,
    file_exists = flovalve_file_exists,
    file_delete = flovalve_file_delete,
    file_write = flovalve_file_write,
    file_size = flovalve_file_size,
    soap_send = flovalve_soap_send,
    force = force,
    current_version = FLOVALVE_DRIVER_VERSION,
    on_progress = function(text)
      if flovalve_state == st and st.updater == op then
        flovalve_set_prop("Update Status", text)
      end
    end,
    on_result = function(install_err, outcome)
      if flovalve_state ~= st or not st.initialized or st.updater ~= op then
        return
      end
      st.updater = nil
      if install_err then
        flovalve_set_prop(
          "Update Status",
          "Install failed: "
            .. install_err
            .. " — download "
            .. FloUpdate.ASSET
            .. " from the GitHub release and update the driver in Composer"
        )
      elseif outcome and outcome.attempted then
        flovalve_set_prop(
          "Update Status",
          "Installation unconfirmed: " .. outcome.attempted .. "; verify Driver Version and Lua Output in Composer"
        )
      elseif outcome and outcome.skipped == "not-installed" then
        flovalve_set_prop("Update Status", "No install applied (driver package not found on controller)")
      else
        local latest = (outcome and outcome.latest) or "?"
        flovalve_set_prop(
          "Update Status",
          "No install applied (current " .. FLOVALVE_DRIVER_VERSION .. ", latest release " .. latest .. ")"
        )
      end
    end,
  })
  st.updater = op
  op.start()
end

-- --- Commands (Director programming + SendToDevice fallback) ------------------

function ExecuteCommand(strCommand, tParams)
  if strCommand == "LUA_ACTION" then
    strCommand = tParams and tParams.ACTION
  end
  if strCommand == "Refresh GitHub Updates" then
    strCommand = "Check for Update"
  end
  flovalve_log("command: " .. tostring(strCommand))
  if strCommand == "Check for Update" then
    flovalve_check_update()
    return
  elseif strCommand == "Install Latest Release" then
    flovalve_install_update(false)
    return
  elseif strCommand == "Force Reinstall Latest Release" then
    flovalve_install_update(true)
    return
  elseif strCommand == "Refresh" then
    if flovalve_state.valve_id == nil then
      flovalve_log("Refresh dropped: not linked")
      flovalve_set_prop("Last Command", "Refresh: not linked")
      return
    end
    flovalve_send_get_state()
    return
  end
  if flovalve_run_program_command(strCommand, tParams) then
    return
  end
  -- SendToDevice fallback arrival (plan D1): ExecuteCommand names no
  -- sender, so these envelopes arrive under their link message name with
  -- the flat params table. Anything else is unknown programming.
  if type(tParams) == "table" and type(tParams[FloLogicLink.K_MSG]) == "string" then
    flovalve_handle_link(strCommand, tParams)
    return
  end
  flovalve_log_warn("unknown command: " .. tostring(strCommand))
end

-- --- Lifecycle ----------------------------------------------------------------

-- Prefill display continuity from persistence. Contacts, events, and the
-- tile level report nothing derived here except the last-known tile
-- level: only a full FLOGIC_STATE push may move programming or edges.
local function flovalve_restore_display()
  local st = flovalve_state
  local saved_id = C4:PersistGetValue(FLOVALVE_PERSIST_ID)
  if type(saved_id) == "string" and saved_id ~= "" then
    st.valve_id_persisted = saved_id
    flovalve_set_prop(FLOVALVE_PROP_VALVE_ID, saved_id)
  end
  local saved_body = C4:PersistGetValue(FLOVALVE_PERSIST_STATE)
  if type(saved_body) == "string" and saved_body ~= "" then
    local fields = FloLogicLink.parse_state_body(saved_body)
    if fields ~= nil then
      flovalve_set_prop(FLOVALVE_PROP_VALVE_NAME, fields.name or ("Valve " .. tostring(fields.id)))
      flovalve_set_prop("Mode", FloModel.mode_status_name({ mode = fields.mode }))
      flovalve_track_restore(fields)
      flovalve_report_level(flovalve_level_for(fields))
    end
  end
end

function OnDriverInit(driver_init_type)
  -- Publish the running version even if Composer already shows the XML default.
  C4:UpdateProperty("Driver Version", FLOVALVE_DRIVER_VERSION)
  print("[flologic-valve] OnDriverInit: " .. FLOVALVE_DRIVER_VERSION .. " (" .. tostring(driver_init_type) .. ")")
  flovalve_restore_display()
end

local function flovalve_log_version_transition()
  local previous = C4:PersistGetValue(FLOVALVE_PERSIST_VERSION)
  if previous == FLOVALVE_DRIVER_VERSION then
    return
  end
  if previous == nil or previous == "" then
    print("[flologic-valve] First run on this controller: " .. FLOVALVE_DRIVER_VERSION)
  else
    print("[flologic-valve] Driver version changed: " .. tostring(previous) .. " -> " .. FLOVALVE_DRIVER_VERSION)
  end
  C4:PersistSetValue(FLOVALVE_PERSIST_VERSION, FLOVALVE_DRIVER_VERSION)
end

function OnDriverLateInit(driver_init_type)
  print("[flologic-valve] OnDriverLateInit: " .. FLOVALVE_DRIVER_VERSION .. " (" .. tostring(driver_init_type) .. ")")
  flovalve_retire_runtime()
  flovalve_state = flovalve_fresh_state()
  C4:UpdateProperty("Driver Version", FLOVALVE_DRIVER_VERSION)
  pcall(flovalve_log_version_transition)
  flovalve_restore_display()
  flovalve_set_prop(FLOVALVE_PROP_CONNECTION, "Initializing")
  flovalve_state.initialized = true
  OnPropertyChanged(FLOVALVE_PROP_DEBUG)
  flovalve_schedule_update_checks()
  -- Restart-restored Composer connections may not re-fire bind events
  -- (plan D3), so hello once at startup too: an unbound link drops the
  -- send silently inside pcall, a bound one answers with our identity.
  if flovalve_link_has_provider() then
    flovalve_set_prop(FLOVALVE_PROP_CONNECTION, "Linking...")
    flovalve_send_hello()
  else
    flovalve_set_prop(FLOVALVE_PROP_CONNECTION, "Not linked")
  end
  flovalve_state.update_start_timer = flovalve_set_timer(10000, function()
    flovalve_state.update_start_timer = nil
    flovalve_check_update()
  end, false)
  print("[flologic-valve] Runtime ready: " .. FLOVALVE_DRIVER_VERSION)
end

function OnDriverDestroyed(driver_init_type)
  print("[flologic-valve] OnDriverDestroyed: " .. FLOVALVE_DRIVER_VERSION .. " (" .. tostring(driver_init_type) .. ")")
  flovalve_retire_runtime()
end

function OnDriverUpdated()
  OnDriverLateInit("OnDriverUpdated")
end

function OnDriverRemovedFromProject()
  OnDriverDestroyed()
end

function OnPropertyChanged(strProperty)
  if not flovalve_state.initialized then
    return
  end
  flovalve_log("property changed: " .. tostring(strProperty))
  if strProperty == FLOVALVE_PROP_DEBUG then
    if flovalve_state.debug_timer then
      flovalve_state.debug_timer:Cancel()
      flovalve_state.debug_timer = nil
    end
    if flovalve_prop(FLOVALVE_PROP_DEBUG) == "On" then
      flovalve_state.debug_timer = flovalve_set_timer(10800000, function()
        flovalve_set_prop(FLOVALVE_PROP_DEBUG, "Off")
        flovalve_state.debug_timer = nil
      end, false)
    end
  elseif strProperty == FLOVALVE_PROP_UPDATE_INTERVAL then
    flovalve_schedule_update_checks()
  end
  -- All other properties are read-only link displays; the valve owns no
  -- account configuration (VALVE-U4), so nothing else can change behavior.
end
