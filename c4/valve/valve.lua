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

FLOVALVE_DRIVER_VERSION = "2026090823"
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

-- Freshness watchdog: the companion must stop presenting state as
-- current when snapshots stop arriving, even with the Composer link
-- intact. The budget comes from the cloud's advertised FLOGIC_FRESH
-- (three configured poll intervals plus one slow session); STALE_MIN_S
-- is only the floor for clouds too old to advertise. Cadence is never
-- inferred from traffic: duplicates and recovery gaps would corrupt it.
-- Only NOVEL snapshots renew the watchdog — replays of an already
-- applied snapshot prove the link is alive, not that the data is fresh.
FLOVALVE_STALE_MIN_S = 300
FLOVALVE_STALE_CHECK_S = 60
-- Sanity bounds for an advertised budget: below the floor is a cloud
-- bug, above twice the worst case (hourly polls) is absurd — both fall
-- back to the floor rather than wedging the watchdog either way.
FLOVALVE_FRESH_MIN_S = 300
FLOVALVE_FRESH_MAX_S = 22000

-- Handshake recovery: a hello that earns no identity is retried on this
-- cadence up to HELLO_ATTEMPTS times, then the link is marked failed
-- instead of hanging in "Linking..." forever. The slow freshness tick
-- restarts a burst after failure, so a late cloud still links without
-- rebind; unbound links (no burst ever started) stay silent.
FLOVALVE_HELLO_RETRY_S = 10
FLOVALVE_HELLO_ATTEMPTS = 6

-- Pending-observation deadline: an ACK proves the cloud accepted the
-- command, not that the valve moved. The cloud hurries a poll after
-- every ack, so a novel snapshot should confirm the request promptly;
-- without one the tile reconciles instead of displaying the unconfirmed
-- request forever.
FLOVALVE_OBSERVATION_TIMEOUT_S = 120

-- First-state wait: identity alone does not establish a usable link.
-- After the handshake a usable snapshot must arrive within the timeout
-- (re-requested, bounded attempts); then the link is marked failed
-- explicitly instead of hanging in "Linking..." forever. Like the hello
-- burst, the slow freshness tick restarts a failed wait.
FLOVALVE_FIRST_STATE_TIMEOUT_S = 90
FLOVALVE_FIRST_STATE_ATTEMPTS = 3

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
FLOVALVE_PERSIST_UUID = "flovalve_valve_uuid"
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
-- read-only); each driver repoints it at its own package (plan D7) and
-- names the whole lockstep family a release must carry to be selectable.
-- The split valve ships under its own asset name: it must never appear
-- as flologic_valve.c4z again, or installed monoliths would offer the
-- incompatible companion as an update.
if FloUpdate ~= nil then
  FloUpdate.ASSET = "flologic_water_valve.c4z"
  FloUpdate.FAMILY_ASSETS = { "flologic_cloud.c4z", "flologic_water_valve.c4z" }
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
  for _, name in ipairs({
    "debug_timer",
    "update_timer",
    "update_start_timer",
    "stale_timer",
    "hello_timer",
    "state_wait_timer",
    "soap_grace",
  }) do
    local timer = previous[name]
    previous[name] = nil
    if timer then
      pcall(function()
        timer:Cancel()
      end)
    end
  end
  -- Pending command timers are per-entry, not named: cancel them
  -- explicitly so retirement owns the whole timer lifetime instead of
  -- relying on orphaned ticks to no-op.
  if previous.pending_commands ~= nil then
    for cmd_id, pending in pairs(previous.pending_commands) do
      previous.pending_commands[cmd_id] = nil
      local timer = pending.timer
      pending.timer = nil
      if timer ~= nil then
        pcall(function()
          timer:Cancel()
        end)
      end
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
    valve_uuid = nil,
    valve_id_persisted = flovalve_state and flovalve_state.valve_id_persisted or nil,
    valve_uuid_persisted = flovalve_state and flovalve_state.valve_uuid_persisted or nil,
    hint_valve_id = nil,
    hello_attempts = 0,
    hello_failed = false,
    state_wait_attempts = 0,
    state_failed = false,
    last_state = nil,
    unavailable = nil,
    stale = false,
    last_slice_at = nil, -- receipt time of the last NOVEL snapshot (replays never renew)
    last_slice_updated = nil, -- cloud observation time of the applied snapshot
    link_epoch = nil, -- ordering baseline: (epoch, seq) of the newest applied message
    link_seq = nil,
    fresh_budget = nil, -- advertised FLOGIC_FRESH seconds, else the floor
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
    [FLOVALVE_CONTACT_CLOSED] = FloModel.has_any_flag(mode, FloModel.WATER_OFF_MODE_FLAGS) or flow_state == 8,
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

-- Valve-closed for the on/off switch: a water-off mode flag OR flow_state 8
-- ("Valve closed"). The tile is OFF exactly when this holds and ON for
-- everything else — the inverse of the Valve Closed contact. Link
-- validation guarantees flow_state is an integer on this path; the
-- defensive contact helper above re-checks it for unvalidated input.
local function flovalve_is_valve_closed(fields)
  return flovalve_is_water_off(fields) or (fields ~= nil and fields.flow_state == 8)
end

-- Snapshot readers below use link-validated fields directly: the link
-- validator is the single numeric conversion path (types and domains
-- checked atomically at parse), so re-converting here would only add a
-- second, weaker interpretation. Only flovalve_contact_values keeps its
-- own checks — it doubles as a defensive helper for unvalidated input.
local function flovalve_is_flowing(fields)
  if fields == nil or fields.online ~= true then
    return false
  end
  local flow_state = fields.flow_state
  return flow_state ~= nil and flow_state ~= 1 and flow_state ~= 8
end

local function flovalve_level_for(fields)
  if flovalve_is_valve_closed(fields) then
    return 0
  end
  return 100
end

local function flovalve_report_level(level)
  flovalve_state.last_level = level
  -- Level Target API (light_v2): the tile follows BRIGHTNESS_CHANGED.
  -- The pre-3.3 LIGHT_LEVEL notify is silently discarded by v2 proxies,
  -- so reporting it leaves the switch state blank in Navigator. Switch
  -- drivers need only CHANGED (no CHANGING ramp prelude); the param is
  -- the raw 0-100 brightness, 0 = off.
  C4:SendToProxy(FLOVALVE_LIGHT_ID, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level }, "NOTIFY")
end

-- Track the last non-shutoff mode so Open/Toggle restores it (plan:
-- default Home). Water-off pushes never overwrite the restore target.
-- Deliberately mode-flags-only, NOT the valve-closed predicate: a closed
-- valve still has a mode, and ON must restore the actual current mode —
-- freezing on flow_state 8 would restore a stale mode instead.
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
-- driver device ids: EMPTY when observed unbound, or nil when Director
-- cannot answer. Director documents null as the SUCCESSFUL no-bindings
-- result ("null if no bindings..."), so a nil answer is observed-unbound
-- — only a missing API or a raised error is indeterminate. The plural
-- API answers a map of device-ID keys to device-NAME values (decode by
-- key); the singular API answers one scalar id, where nil AND 0 both
-- mean unbound (0 is the "current device" query alias, never a peer id)
-- and anything non-numeric is indeterminate.
local function flovalve_bound_providers()
  local name = nil
  local singular = false
  if C4.GetBoundProviderDevices ~= nil then
    name = "GetBoundProviderDevices"
  elseif C4.GetBoundProviderDevice ~= nil then
    name = "GetBoundProviderDevice"
    singular = true
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
  if found == nil or (singular and found == 0) then
    return {}
  end
  local ids = {}
  if type(found) == "table" then
    for id in pairs(found) do
      local num = tonumber(id)
      if num ~= nil then
        ids[#ids + 1] = num
      end
    end
    return ids
  end
  if singular and tonumber(found) ~= nil and tonumber(found) ~= 0 then
    ids[#ids + 1] = tonumber(found)
    return ids
  end
  return nil
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
  -- The fallback hint is learned from a LIVE handshake on the current
  -- binding only: the persisted id survives rebinds, so attaching it
  -- would route the new binding's traffic to the old valve's slot. A
  -- hintless message attributes by elimination only when exactly one
  -- consumer is bound; otherwise the cloud drops it (ExecuteCommand
  -- names no sender), so multi-valve fallback needs one proxy
  -- handshake first.
  if flovalve_state.hint_valve_id ~= nil and flovalve_state.hint_valve_id ~= "" then
    hinted[FLOVALVE_K_FROM] = flovalve_state.hint_valve_id
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

-- Hello with a bounded retry burst: a non-throwing SendToProxy is not
-- proof of delivery, so an unanswered hello is retried until the burst
-- is spent, then the link is marked failed explicitly. Any identity
-- cancels the burst. Sending never touches the display: callers own the
-- Linking/failed text, so slow retries never flap it.
local flovalve_send_hello -- forward: the timeout recurses into the send
local function flovalve_hello_timeout()
  local st = flovalve_state
  st.hello_timer = nil
  if st.valve_id ~= nil then
    return
  end
  if st.hello_attempts >= FLOVALVE_HELLO_ATTEMPTS then
    if not st.hello_failed then
      st.hello_failed = true
      flovalve_log_warn("link handshake failed: no cloud identity after " .. st.hello_attempts .. " hellos")
      flovalve_set_prop(FLOVALVE_PROP_CONNECTION, "Link failed: no response from cloud")
    end
    return
  end
  flovalve_send_hello()
end

flovalve_send_hello = function()
  local st = flovalve_state
  flovalve_log("link FLOGIC_HELLO")
  flovalve_send_to_cloud(FloLogicLink.build_hello())
  if st.valve_id ~= nil then
    return
  end
  st.hello_attempts = st.hello_attempts + 1
  if st.hello_timer ~= nil then
    st.hello_timer:Cancel()
    st.hello_timer = nil
  end
  st.hello_timer = flovalve_set_timer(FLOVALVE_HELLO_RETRY_S * 1000, flovalve_hello_timeout, false)
end

local function flovalve_cancel_hello()
  local st = flovalve_state
  st.hello_attempts = 0
  st.hello_failed = false
  if st.hello_timer ~= nil then
    st.hello_timer:Cancel()
    st.hello_timer = nil
  end
end

local function flovalve_send_get_state()
  local envelope = FloLogicLink.build_get_state()
  if envelope ~= nil then
    flovalve_send_to_cloud(envelope)
  end
end

-- First-state wait: identity without a usable snapshot owns its own
-- deadline. Expiry re-requests state up to FIRST_STATE_ATTEMPTS times,
-- then marks the link failed explicitly instead of hanging in
-- "Linking..." forever; the slow freshness tick restarts a failed wait.
-- Only a NOVEL full snapshot disarms the wait — digests prove the peer
-- is alive (so they extend the wait without consuming an attempt) but
-- are not usable state.
local flovalve_arm_state_wait -- forward: the timeout re-arms into the send
local function flovalve_state_wait_timeout()
  local st = flovalve_state
  st.state_wait_timer = nil
  if st.valve_id == nil or st.last_state ~= nil then
    return
  end
  if st.state_wait_attempts >= FLOVALVE_FIRST_STATE_ATTEMPTS then
    if not st.state_failed then
      st.state_failed = true
      -- The identity itself is suspect now (a misattributed handshake
      -- answers nothing): drop the hint it authorized so recovery
      -- re-handshakes hintless instead of perpetuating a wrong route.
      st.hint_valve_id = nil
      flovalve_log_warn("link has identity but no usable state after " .. st.state_wait_attempts .. " requests")
      flovalve_set_prop(FLOVALVE_PROP_CONNECTION, "Link failed: no state from cloud")
    end
    return
  end
  flovalve_send_get_state()
  flovalve_arm_state_wait()
end

flovalve_arm_state_wait = function()
  local st = flovalve_state
  if st.state_wait_timer ~= nil then
    st.state_wait_timer:Cancel()
    st.state_wait_timer = nil
  end
  st.state_wait_attempts = st.state_wait_attempts + 1
  st.state_wait_timer = flovalve_set_timer(FLOVALVE_FIRST_STATE_TIMEOUT_S * 1000, flovalve_state_wait_timeout, false)
end

local function flovalve_cancel_state_wait()
  local st = flovalve_state
  st.state_wait_attempts = 0
  st.state_failed = false
  if st.state_wait_timer ~= nil then
    st.state_wait_timer:Cancel()
    st.state_wait_timer = nil
  end
end

local function flovalve_extend_state_wait()
  local st = flovalve_state
  if st.valve_id == nil or st.last_state ~= nil or st.state_wait_timer == nil then
    return
  end
  st.state_wait_timer:Cancel()
  st.state_wait_timer = flovalve_set_timer(FLOVALVE_FIRST_STATE_TIMEOUT_S * 1000, flovalve_state_wait_timeout, false)
end

local function flovalve_next_cmd_id()
  local st = flovalve_state
  st.cmd_seq = st.cmd_seq + 1
  return "v" .. tostring(st.cmd_seq) .. "-" .. tostring(os.time())
end

-- Forward one validated link action. Returns true when sent; commands
-- with no handshake identity are dropped locally (the cloud would drop
-- them unattributed anyway) with a display note, never a crash.
-- Reconcile the tile after settling a request without confirmation:
-- the last OBSERVED level wins; with no observation at all the
-- pre-command level is restored so the unconfirmed request is withdrawn
-- from the tile (callers label the state unknown in that case).
local function flovalve_reconcile_tile(pre_level)
  local st = flovalve_state
  if st.last_state ~= nil then
    flovalve_report_level(flovalve_level_for(st.last_state))
    return true
  end
  if pre_level ~= nil then
    flovalve_report_level(pre_level)
  end
  return false
end

-- Settle one command whose reply never arrived: drop the pending entry,
-- say so on the display, and reconcile the tile. Physical state
-- (last_state) and requested state (pending plus the optimistic
-- last_level) stay separate; with no reply there is no evidence either
-- way, so the tile must not keep showing the request.
local function flovalve_timeout_pending(cmd_id, pending)
  local st = flovalve_state
  st.pending_commands[cmd_id] = nil
  if pending.timer ~= nil then
    pending.timer:Cancel()
    pending.timer = nil
  end
  flovalve_log_warn("command " .. pending.label .. " no response from cloud; reconciling tile")
  if flovalve_prop("Last Command") == pending.label .. ": sent (awaiting cloud refresh)" then
    flovalve_set_prop("Last Command", pending.label .. ": no response from cloud")
  end
  if not flovalve_reconcile_tile(pending.pre_level) then
    flovalve_set_prop("Last Command", pending.label .. ": no response from cloud (state unknown)")
  end
end

-- Settle one ACKED command the following snapshot never confirmed: the
-- ack proved acceptance, not movement, so the optimistic level cannot
-- stand past the observation deadline.
local function flovalve_timeout_observation(cmd_id, pending)
  local st = flovalve_state
  st.pending_commands[cmd_id] = nil
  if pending.timer ~= nil then
    pending.timer:Cancel()
    pending.timer = nil
  end
  flovalve_log_warn("command " .. pending.label .. " acknowledged but never confirmed by a snapshot; reconciling tile")
  flovalve_set_prop("Last Command", pending.label .. ": acknowledged but unconfirmed (no refresh)")
  flovalve_reconcile_tile(pending.pre_level)
end

-- Settle every in-flight request at once (unbind, unavailable): cancel
-- their timers, drop the entries, reconcile the tile once, and say so.
-- Returns the drop count.
local function flovalve_settle_all_pending(label)
  local st = flovalve_state
  local dropped = 0
  local pre_level = nil
  for cmd_id, pending in pairs(st.pending_commands) do
    st.pending_commands[cmd_id] = nil
    if pending.timer ~= nil then
      pending.timer:Cancel()
      pending.timer = nil
    end
    if pre_level == nil then
      pre_level = pending.pre_level
    end
    dropped = dropped + 1
  end
  if dropped > 0 then
    flovalve_reconcile_tile(pre_level)
    flovalve_set_prop("Last Command", label .. ": " .. dropped .. " command(s) dropped")
  end
  return dropped
end

-- Pending entries with no ack/nack (lost reply, cloud restarted
-- mid-command) settle on their own deadline timer; acked entries settle
-- on the observation deadline instead. The lazy sweep below is only a
-- backstop for activity that arrives after a missed tick.
local function flovalve_expire_pending(now)
  local st = flovalve_state
  for cmd_id, pending in pairs(st.pending_commands) do
    if pending.awaiting_obs then
      if now - (pending.obs_at or now) >= FLOVALVE_OBSERVATION_TIMEOUT_S then
        flovalve_timeout_observation(cmd_id, pending)
      end
    elseif now - (pending.sent_at or now) >= FLOVALVE_ACK_TIMEOUT_S then
      flovalve_timeout_pending(cmd_id, pending)
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
  if st.unavailable ~= nil then
    flovalve_log_warn("command " .. label .. " dropped: valve unavailable (" .. st.unavailable .. ")")
    flovalve_set_prop("Last Command", label .. ": not available")
    return false
  end
  if st.last_state == nil then
    -- No observation yet (first-state wait): a blind write cannot be
    -- shown truthfully — the tile has no confirmed level to reconcile
    -- to, so any optimistic level would stand as an unproven physical
    -- claim. Refuse with an explicit unknown-state note instead.
    flovalve_log_warn("command " .. label .. " dropped: no state yet (state unknown)")
    flovalve_set_prop("Last Command", label .. ": no state yet")
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
  local pending = { action = action, label = label, sent_at = os.time(), pre_level = st.last_level }
  st.pending_commands[cmd_id] = pending
  local route, route_err = flovalve_send_to_cloud(envelope)
  if route == nil then
    st.pending_commands[cmd_id] = nil
    flovalve_log_warn("command " .. label .. " has no link route: " .. tostring(route_err))
    flovalve_set_prop("Last Command", label .. ": no link route")
    return false
  end
  flovalve_log("command " .. label .. " sent (" .. cmd_id .. " via " .. route .. ")")
  flovalve_set_prop("Last Command", label .. ": sent (awaiting cloud refresh)")
  -- Real deadline: a lost reply settles on this timer even when the
  -- driver is otherwise quiet. Ack/nack cancel it; unbind and identity
  -- resets drop the entry, and the orphaned tick then no-ops.
  pending.timer = flovalve_set_timer(FLOVALVE_ACK_TIMEOUT_S * 1000, function()
    local still = st.pending_commands[cmd_id]
    if still ~= nil then
      flovalve_timeout_pending(cmd_id, still)
    end
  end, false)
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
  local flow_state = fields.flow_state
  flovalve_set_prop("Flow State", FloModel.FLOW_STATE_NAMES[flow_state] or flovalve_num(fields.flow_state))
  if flovalve_is_flowing(fields) then
    flovalve_set_prop("Water Flowing", "Yes")
  else
    flovalve_set_prop("Water Flowing", "No")
  end
  flovalve_set_prop("Home Limit", flovalve_num(fields.home_interval))
  flovalve_set_prop("Away Limit", flovalve_num(fields.away_interval))
  flovalve_set_prop("Bypass Time", flovalve_num(fields.bypass_time))
  -- Last Link Update shows when the cloud observed this snapshot, not
  -- when it arrived: receipt time cannot establish data freshness.
  flovalve_set_prop(FLOVALVE_PROP_LAST_UPDATE, os.date("%Y-%m-%d %H:%M:%S", fields.updated or os.time()))
end

-- Per-valve edge events ported from c4/src/main.lua flogic_process_edges
-- (attribution), evaluated against link slices. The first full push sets
-- the baseline and fires nothing, so a restart never replays history.
local function flovalve_process_edges(fields)
  local st = flovalve_state
  local mode = FloModel.mode_status_name({ mode = fields.mode })
  local flowing = flovalve_is_flowing(fields)
  local raw_mode = fields.mode
  local water_off = flovalve_is_valve_closed(fields)
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

-- Forward: a replacement snapshot resets history mid-apply, but the
-- reset itself is defined below beside the other identity handling.
local flovalve_reset_valve_history

-- Ordering gate for stamped cloud->valve messages: a message is novel
-- only when its (epoch, seq) advances the baseline. Older epochs
-- (delayed pre-restart traffic) and older-or-equal sequences within the
-- epoch (duplicates, reordered redeliveries) are dropped WITHOUT
-- renewing freshness or disturbing availability markings — a replay
-- proves the link is alive, not that the data is fresh. Unstamped
-- messages (older clouds) are always novel: legacy semantics.
-- Returns true when the message is novel (baseline advanced).
local function flovalve_note_ordered(env)
  local st = flovalve_state
  if env.seq == nil or env.epoch == nil then
    return true
  end
  if st.link_epoch ~= nil then
    if env.epoch < st.link_epoch then
      return false
    end
    if env.epoch == st.link_epoch and st.link_seq ~= nil and env.seq <= st.link_seq then
      return false
    end
  end
  st.link_epoch, st.link_seq = env.epoch, env.seq
  return true
end

local function flovalve_apply_state(env)
  local st = flovalve_state
  local fields, body = env.fields, env.body
  local now = os.time()
  -- Replacement check BEFORE the ordering gate: a new physical valve
  -- (same numeric id, different immutable uuid) resets history —
  -- including the ordering baseline — so its first snapshot always
  -- applies as novel and never inherits the old valve's restore mode,
  -- event baselines, or availability markings. The persisted
  -- association counts as known identity across a restart.
  local uuid = type(fields.uuid) == "string" and fields.uuid or nil
  if uuid ~= nil then
    local known = st.valve_uuid
    if known == nil then
      known = st.valve_uuid_persisted
    end
    if known ~= nil and known ~= uuid then
      flovalve_log_warn("link state uuid changed for valve " .. tostring(st.valve_id) .. "; resetting control history")
      flovalve_reset_valve_history()
    end
  end
  if not flovalve_note_ordered(env) then
    flovalve_log("link state duplicate or out of order; dropped without renewing freshness")
    return
  end
  -- Ordering also runs on the cloud's observation time, not receipt
  -- time: a delayed older snapshot must never roll back a newer one.
  local observed = fields.updated or now
  if st.last_slice_updated ~= nil and observed < st.last_slice_updated then
    flovalve_log("link state older than the applied snapshot; dropped")
    return
  end
  if uuid ~= nil and st.valve_uuid ~= uuid then
    st.valve_uuid = uuid
    st.valve_uuid_persisted = uuid
    C4:PersistSetValue(FLOVALVE_PERSIST_UUID, uuid, true)
  end
  -- Past every gate: this snapshot is novel. Renew the watchdog from
  -- its receipt, adopt the advertised freshness budget when sane, and
  -- clear any unavailability/staleness marking: the valve is back and
  -- the data is current again.
  st.last_slice_at = now
  st.last_slice_updated = observed
  if env.fresh_s ~= nil and env.fresh_s >= FLOVALVE_FRESH_MIN_S and env.fresh_s <= FLOVALVE_FRESH_MAX_S then
    st.fresh_budget = env.fresh_s
  end
  st.unavailable, st.stale = nil, false
  st.last_state = fields
  st.digest_retry_at = nil
  flovalve_cancel_state_wait()
  -- A novel snapshot confirms every ack-awaiting request: the cloud
  -- hurries a poll after each ack, so the next novel observation IS the
  -- confirmation of the outstanding request.
  for cmd_id, pending in pairs(st.pending_commands) do
    if pending.awaiting_obs then
      st.pending_commands[cmd_id] = nil
      if pending.timer ~= nil then
        pending.timer:Cancel()
        pending.timer = nil
      end
      flovalve_log("command " .. pending.label .. " confirmed by refresh")
      flovalve_set_prop("Last Command", pending.label .. ": confirmed")
    end
  end
  flovalve_expire_pending(now)
  C4:PersistSetValue(FLOVALVE_PERSIST_STATE, body, true)
  flovalve_track_restore(fields)
  flovalve_update_display(fields)
  flovalve_update_contacts(fields)
  -- Reported level is 0 iff the valve is closed (a water-off flag or
  -- flow_state 8, "Valve closed"), else 100: the inverse of the Valve
  -- Closed contact (plan).
  flovalve_report_level(flovalve_level_for(fields))
  flovalve_process_edges(fields)
  flovalve_set_connection(true)
end

-- Drop everything learned from the previous valve: its restore target,
-- contact baselines, edge-event baselines, live state, and in-flight
-- commands. The next push from the new valve then establishes a fresh
-- quiet baseline (STATE_* sync, no transitions) instead of comparing new
-- observations against old history or restoring another valve's mode.
-- The persisted identity/state association dies with the runtime one: a
-- restart before the first new snapshot restores NO state for the new
-- identity, never the old valve's. Pending timers cancel explicitly.
flovalve_reset_valve_history = function()
  local st = flovalve_state
  st.restore_action = FLOVALVE_RESTORE_DEFAULT
  st.contact_states = nil
  st.last_state = nil
  st.hint_valve_id = nil
  st.valve_uuid = nil
  st.valve_uuid_persisted = nil
  C4:PersistSetValue(FLOVALVE_PERSIST_STATE, "", true)
  C4:PersistSetValue(FLOVALVE_PERSIST_UUID, "", true)
  st.unavailable = nil
  st.stale = false
  st.last_slice_at = nil
  st.last_slice_updated = nil
  st.link_epoch = nil
  st.link_seq = nil
  st.fresh_budget = nil
  st.last_mode, st.last_flowing = nil, nil
  st.last_water_off, st.last_warning = nil, nil
  st.last_critical = nil
  st.digest_retry_at = nil
  flovalve_cancel_state_wait()
  local dropped = 0
  for cmd_id, pending in pairs(st.pending_commands) do
    st.pending_commands[cmd_id] = nil
    local timer = pending.timer
    pending.timer = nil
    if timer ~= nil then
      timer:Cancel()
    end
    dropped = dropped + 1
  end
  if dropped > 0 then
    flovalve_set_prop("Last Command", "Link changed: " .. dropped .. " command(s) dropped")
  end
end

local function flovalve_on_identity(valve_id)
  local st = flovalve_state
  -- Unbind clears the authoritative id but keeps the persisted one, so
  -- compare against whichever names the previous valve: a genuinely new
  -- identity resets control history, while a same-valve re-link keeps
  -- its baselines (a flap must not swallow real transitions either).
  local previous = st.valve_id
  if previous == nil then
    previous = st.valve_id_persisted
  end
  if previous ~= nil and tostring(previous) ~= tostring(valve_id) then
    flovalve_log_warn(
      "link identity changed from valve "
        .. tostring(previous)
        .. " to "
        .. tostring(valve_id)
        .. "; resetting control history"
    )
    flovalve_reset_valve_history()
  end
  st.valve_id = valve_id
  st.valve_id_persisted = valve_id
  -- The live handshake authorizes the fallback hint for this binding;
  -- any identity (same or new) also cancels the hello burst.
  st.hint_valve_id = valve_id
  flovalve_cancel_hello()
  C4:PersistSetValue(FLOVALVE_PERSIST_ID, valve_id, true)
  flovalve_set_prop(FLOVALVE_PROP_VALVE_ID, valve_id)
  flovalve_log("link bound to valve " .. valve_id)
  -- The cloud already pushes its latest slice on hello, but a GET_STATE
  -- covers the race where it had nothing cached yet.
  flovalve_send_get_state()
  -- Identity alone is not a usable link: wait for the first snapshot
  -- unless an observation already stands (same-valve re-link).
  flovalve_cancel_state_wait()
  if st.last_state == nil then
    flovalve_arm_state_wait()
  end
end

local function flovalve_on_unavailable(env)
  local st = flovalve_state
  local valve_id, reason = env.valve_id, env.error_reason
  -- Attribute strictly once an identity is known: another valve's
  -- notice (fallback cross-talk) must never mark this link.
  if st.valve_id ~= nil and tostring(st.valve_id) ~= tostring(valve_id) then
    flovalve_log_warn(
      "unavailable notice for valve "
        .. tostring(valve_id)
        .. " does not match "
        .. tostring(st.valve_id)
        .. "; ignored"
    )
    return false
  end
  if not flovalve_note_ordered(env) then
    flovalve_log("unavailable notice duplicate or out of order; dropped")
    return false
  end
  reason = reason or "unavailable"
  -- Settle in-flight requests: the valve is gone, so no reply and no
  -- confirming snapshot can arrive — reconcile the tile now instead of
  -- letting the optimistic level linger until a deadline.
  flovalve_settle_all_pending("Not available (" .. reason .. ")")
  if st.unavailable == reason then
    return true
  end
  st.unavailable = reason
  st.stale = false
  -- Historical contacts and display stay put (deliberate retention
  -- policy); only the freshness claim changes, once per reason.
  flovalve_set_connection(false, "not available (" .. reason .. ")")
  local last = flovalve_prop(FLOVALVE_PROP_LAST_UPDATE)
  if last ~= "" then
    last = " (last update " .. last .. ")"
  end
  flovalve_set_prop(FLOVALVE_PROP_CONNECTION, "Not available: " .. reason .. last)
  flovalve_log_warn("valve " .. tostring(valve_id) .. " unavailable: " .. reason)
  return true
end

-- Freshness watchdog: with a known identity and at least one novel
-- snapshot, silence longer than the cloud's advertised budget (or the
-- floor for older clouds) means the data is no longer current — even
-- with the Composer link itself intact. Unavailable links are already
-- marked and skip the check.
function flovalve_check_freshness()
  local st = flovalve_state
  if not st.initialized then
    return
  end
  if st.valve_id == nil then
    -- Slow handshake recovery: a burst that already failed restarts here
    -- so a late cloud still links without rebind. Links that never
    -- started a burst (truly unbound) stay silent.
    if st.hello_failed and st.hello_timer == nil then
      st.hello_attempts = 0
      st.hello_failed = false
      flovalve_send_hello()
    end
    return
  end
  if st.state_failed and st.state_wait_timer == nil and st.last_state == nil then
    -- Slow first-state recovery: a wait that already failed restarts
    -- here so a late cloud still delivers state without rebind. This
    -- re-handshakes (single hello — valve_id is set, so no burst)
    -- rather than just re-requesting: the failed identity may itself
    -- be wrong, and only a new handshake can replace it.
    flovalve_cancel_state_wait()
    flovalve_send_hello()
    flovalve_arm_state_wait()
    return
  end
  if st.unavailable ~= nil or st.stale or st.last_slice_at == nil then
    return
  end
  local limit = st.fresh_budget or FLOVALVE_STALE_MIN_S
  local silent_for = os.time() - st.last_slice_at
  if silent_for > limit then
    st.stale = true
    flovalve_set_connection(false, "no cloud data for " .. silent_for .. "s")
    flovalve_set_prop(FLOVALVE_PROP_CONNECTION, "Stale: no cloud data for " .. silent_for .. "s")
    flovalve_log_warn("link stale: no cloud snapshot for " .. silent_for .. "s")
  end
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
    -- A digest proves the cloud is alive: extend the first-state wait
    -- (when one runs) without consuming an attempt.
    flovalve_extend_state_wait()
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
    st.hint_valve_id = nil
    flovalve_send_hello()
    return false
  end
  flovalve_apply_state(env)
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
  if pending.timer ~= nil then
    pending.timer:Cancel()
    pending.timer = nil
  end
  if acked then
    -- The cloud accepted the command — but acceptance is not movement.
    -- The tile keeps showing the request ONLY until the observation
    -- deadline: a novel snapshot confirms it (apply settles the entry),
    -- silence reconciles it. An ack without a following refresh must
    -- never linger as an optimistic level.
    flovalve_log("command " .. pending.label .. " acknowledged")
    flovalve_set_prop("Last Command", pending.label .. ": acknowledged; awaiting refresh")
    st.pending_commands[cmd_id] = pending
    pending.awaiting_obs = true
    pending.obs_at = os.time()
    pending.timer = flovalve_set_timer(FLOVALVE_OBSERVATION_TIMEOUT_S * 1000, function()
      local still = st.pending_commands[cmd_id]
      if still ~= nil and still.awaiting_obs then
        flovalve_timeout_observation(cmd_id, still)
      end
    end, false)
  else
    flovalve_log_warn("command " .. pending.label .. " rejected: " .. tostring(reason))
    flovalve_set_prop("Last Command", pending.label .. ": rejected (" .. tostring(reason) .. ")")
    -- The tile level was set optimistically when the command went out;
    -- roll it back to the last cloud-confirmed state so a failed shutoff
    -- (or open) never displays the action that did not happen.
    flovalve_reconcile_tile(pending.pre_level)
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
  elseif env.msg == FloLogicLink.MSG_UNAVAILABLE then
    return flovalve_on_unavailable(env)
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
  -- The binding that produced the handshake is gone: its hint must not
  -- route the next binding's traffic, and the burst stops with the link.
  st.hint_valve_id = nil
  flovalve_cancel_hello()
  flovalve_cancel_state_wait()
  flovalve_settle_all_pending("Link lost")
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
-- on, 0 off); remotes/keypads use BUTTON_ACTION; older senders and
-- Composer actions use plain ON/OFF. OFF issues the shutoff mode; ON
-- restores the last non-shutoff mode tracked from state pushes (default
-- Home). The tile level reports optimistically for responsiveness;
-- contacts, properties, and events still change only on FLOGIC_STATE
-- pushes.

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

-- Param shape follows the supports_target capability, which this switch
-- leaves unset: targets-enabled proxies send LIGHT_BRIGHTNESS_TARGET,
-- legacy ones send LEVEL (or LIGHT on the oldest API). Accept all
-- three, preferring the Level Target name. Shared by
-- SET_BRIGHTNESS_TARGET and RAMP_TO_LEVEL (a switch has no ramp: any
-- target level routes to open/close).
local function flovalve_target_level(tParams)
  local level = tParams ~= nil and tParams.LIGHT_BRIGHTNESS_TARGET or nil
  if level == nil then
    level = tParams ~= nil and tParams.LEVEL or nil
  end
  if level == nil then
    level = tParams ~= nil and tParams.LIGHT or nil
  end
  return tonumber(level)
end

function flovalve_on_light(strCommand, tParams)
  if strCommand == "DYNAMIC_ON" or strCommand == "ON" then
    flovalve_open_valve("Open Valve")
  elseif strCommand == "DYNAMIC_OFF" or strCommand == "OFF" then
    flovalve_close_valve("Close Valve")
  elseif strCommand == "TOGGLE" then
    flovalve_toggle_valve("Toggle")
  elseif strCommand == "BUTTON_ACTION" then
    -- Neeo/Halo remotes and keypads drive light_v2 via BUTTON_ACTION,
    -- not ON/OFF/TOGGLE: BUTTON_ID 0 on, 1 off, 2 toggle. Act on
    -- release (ACTION 2) like the stock proxy so the press+release
    -- pair fires once.
    local button = tostring(tParams ~= nil and tParams.BUTTON_ID or "")
    local action = tostring(tParams ~= nil and tParams.ACTION or "")
    if action == "2" then
      if button == "0" then
        flovalve_open_valve("Open Valve")
      elseif button == "1" then
        flovalve_close_valve("Close Valve")
      elseif button == "2" then
        flovalve_toggle_valve("Toggle")
      end
    end
  elseif strCommand == "SET_BRIGHTNESS_TARGET" or strCommand == "RAMP_TO_LEVEL" then
    local level = flovalve_target_level(tParams)
    if level == nil then
      flovalve_log_warn(strCommand .. " without a level; ignored")
      return false
    end
    if level > 0 then
      flovalve_open_valve("Open Valve")
    else
      flovalve_close_valve("Close Valve")
    end
  elseif strCommand == "GET_LIGHT_LEVEL" or strCommand == "GET_STATE" or strCommand == "GET_BRIGHTNESS_TARGET" then
    -- Navigator queries current state on load: reply with the best-known
    -- level or the query times out and the tile resets to 0. Never
    -- commands the valve; a pure state serve.
    flovalve_report_level(flovalve_state.last_level)
  else
    flovalve_log("light proxy command ignored: " .. tostring(strCommand))
    return false
  end
  return true
end

-- Director asks for current proxy state when a navigator connects (and at
-- other sync points): serve the best-known level. The v2 tile protocol
-- has no "unknown" state — missing data renders as 0 — so always answer.
function OnRequestData(idBinding, strGet, strSet)
  if idBinding == FLOVALVE_LIGHT_ID then
    flovalve_report_level(flovalve_state.last_level)
  end
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
    -- dark until the next cloud push: always serve the best-known level
    -- (0 default). The v2 protocol has no "unknown" — missing data
    -- renders as 0 — so quiet and default-zero are UI-identical, and
    -- serving keeps the proxy established.
    if bIsBound then
      flovalve_report_level(flovalve_state.last_level)
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

-- The store file_set_dir selected: file_move stays within it.
local flovalve_file_store = "C4Z"

-- FileSetDir documents neither a return value nor an error convention,
-- so every refusal shape with any precedent denies: a raise, an explicit
-- false, -1 (Director's sentinel style, cf. FileOpen/FileWrite), or a
-- (nil, err) pair (Lua C style). No success convention produces any of
-- those shapes, so this only ever refuses. (A denial that silently
-- succeeds is unverifiable — no getter exists — and is caught a cycle
-- later by the version check, as the 0815 no-op was.)
local function flovalve_dir_accepted(ok, ret, err)
  return ok and ret ~= false and ret ~= -1 and (ret ~= nil or err == nil)
end

local function flovalve_file_set_dir(alias)
  -- Pass the C4Z_ROOT unlock key first (undocumented; pcall'd since not
  -- every OS accepts it), then select exactly the requested alias. There
  -- is no fallback store: Director's UpdateProjectC4i hot-reload
  -- resolves the staged package in C4Z_ROOT only, so staging into the
  -- running driver's own directory verifies and triggers yet reloads
  -- the previously installed build. Denial refuses the install.
  local unlock_ok, unlock_ret, unlock_err = pcall(function()
    return C4:FileSetDir(FloUpdate.C4Z_ROOT_UNLOCK_KEY)
  end)
  flovalve_log_warn(
    "update file store unlock key: "
      .. (flovalve_dir_accepted(unlock_ok, unlock_ret, unlock_err) and "accepted" or "rejected")
  )
  local ok, ret, err = pcall(function()
    return C4:FileSetDir(alias)
  end)
  if flovalve_dir_accepted(ok, ret, err) then
    flovalve_file_store = alias
    flovalve_log_warn("update file store: " .. alias)
    return true
  end
  return false
end

local function flovalve_file_move(from_name, to_name)
  -- C4:FileMove(alias, from, alias, to) is documented from OS 3.3.0 with
  -- C4Z among the allowed aliases; the valve driver requires 3.3.2+.
  -- The documented example uses leading-slash paths, but a bare
  -- filename is also a valid relative path — and FileMove's own return
  -- convention is undocumented. So try both forms and believe the
  -- filesystem, not the call: our flows never move onto an existing
  -- destination, so the destination's existence proves the move. The
  -- updater re-verifies every step by state regardless.
  if C4.FileMove == nil then
    return false
  end
  local forms = { { from_name, to_name }, { "/" .. from_name, "/" .. to_name } }
  for _, form in ipairs(forms) do
    pcall(function()
      C4:FileMove(flovalve_file_store, form[1], flovalve_file_store, form[2])
    end)
    local ok, exists = pcall(function()
      return C4:FileExists(to_name)
    end)
    if ok and exists then
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

local function flovalve_file_read(name, count)
  local handle
  local ok, data = pcall(function()
    if not C4:FileExists(name) then
      return nil
    end
    handle = C4:FileOpen(name)
    if handle == nil or handle == -1 then
      return nil
    end
    -- FileOpen positions at END-of-file: without the seek every read
    -- returns "" and no magic gate can ever pass (field failure on
    -- 2026090812). FileSetPos is available since 1.6.0.
    C4:FileSetPos(handle, 0)
    return C4:FileRead(handle, count)
  end)
  if handle ~= nil and handle ~= -1 then
    pcall(function()
      C4:FileClose(handle)
    end)
  end
  if ok then
    return data
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

-- Global so the lifecycle tests can drive the real adapter (bind +
-- entry-point dispatch) instead of only the shared updater's injected
-- soap_send fake.
function flovalve_soap_send(packet, cb)
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
  -- can establish its running version. Transmission itself IS tracked:
  -- grace expiry (or a close, or stray bytes) before the packet was
  -- handed to the transport reports a connection failure, never a sent
  -- trigger.
  local opened = false
  local sent = false
  local grace = flovalve_set_timer(3000, function()
    if sent then
      finish(nil)
    else
      finish("cannot reach Composer endpoint")
    end
  end, false)
  owner.soap_grace = grace
  owner.soap_callbacks = {
    on_data = function()
      if sent then
        finish(nil)
      else
        finish("cannot reach Composer endpoint")
      end
    end,
    on_open = function()
      opened = true
      -- Handover starts at the call (the transport queues/copies the
      -- packet then), so mark sent BEFORE it: a transport that answers
      -- synchronously must still observe a transmitted trigger.
      sent = true
      local ok = pcall(function()
        C4:SendToNetwork(binding, FloUpdate.SOAP_PORT, packet)
      end)
      if not ok then
        sent = false
        finish("cannot reach Composer endpoint")
      end
    end,
    on_close = function()
      if opened and sent then
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

-- Network dispatch for the transient SOAP binding above: without these
-- entry points Director has no way to invoke the stored install-packet
-- callbacks, and the grace timer would report success with nothing ever
-- transmitted. Binding, port, and live-callback checks fence every event
-- to the current load's in-flight send; anything else is ignored.
function ReceivedFromNetwork(idBinding, nPort, strData)
  local st = flovalve_state
  if st.soap_binding == idBinding and st.soap_port == nPort and st.soap_callbacks ~= nil then
    st.soap_callbacks.on_data(strData)
  end
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
  local st = flovalve_state
  if st.soap_binding == idBinding and st.soap_port == nPort and st.soap_callbacks ~= nil then
    if strStatus == "ONLINE" then
      st.soap_callbacks.on_open()
    elseif strStatus == "OFFLINE" then
      st.soap_callbacks.on_close()
    end
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
    -- The pre-rename flologic_valve.* keys stay so instances updated
    -- across the asset rename still match; new installs match the new
    -- keys first. Confirm which key matches on a live Director.
    get_installed = function()
      for _, key in ipairs({
        "flologic_water_valve.c4i",
        "flologic_water_valve",
        "flologic_valve.c4i",
        "flologic_valve",
        FloUpdate.ASSET,
      }) do
        if flovalve_get_installed(key) then
          flovalve_log_warn("update installed lookup matched: " .. key)
          return true
        end
      end
      return false
    end,
    file_set_dir = flovalve_file_set_dir,
    file_exists = flovalve_file_exists,
    file_delete = flovalve_file_delete,
    file_write = flovalve_file_write,
    file_size = flovalve_file_size,
    file_read = flovalve_file_read,
    file_move = flovalve_file_move,
    log_warn = flovalve_log_warn,
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

-- Prefill display continuity from persistence. Contacts and events move
-- only on a full FLOGIC_STATE push; props restore from validated persist;
-- the tile level always reports (last-known, 0 default) so the proxy
-- binding carries a value before the first push.
local function flovalve_restore_display()
  local st = flovalve_state
  local saved_id = C4:PersistGetValue(FLOVALVE_PERSIST_ID)
  if type(saved_id) == "string" and saved_id ~= "" then
    st.valve_id_persisted = saved_id
    flovalve_set_prop(FLOVALVE_PROP_VALVE_ID, saved_id)
  end
  local saved_uuid = C4:PersistGetValue(FLOVALVE_PERSIST_UUID)
  if type(saved_uuid) == "string" and saved_uuid ~= "" then
    st.valve_uuid_persisted = saved_uuid
  end
  local saved_body = C4:PersistGetValue(FLOVALVE_PERSIST_STATE)
  local boot_level = nil
  if type(saved_body) == "string" and saved_body ~= "" then
    local fields = FloLogicLink.parse_state_body(saved_body)
    -- Identity and state restore as ONE validated association: the body
    -- must name the persisted id, and when both sides carry a uuid those
    -- must match too. Otherwise the body belongs to a valve this link no
    -- longer serves (identity changed, restart before the first new
    -- snapshot) and is discarded — never relearned as restore action.
    local body_uuid = fields ~= nil and type(fields.uuid) == "string" and fields.uuid or nil
    local uuid_ok = body_uuid == nil or st.valve_uuid_persisted == nil or body_uuid == st.valve_uuid_persisted
    if fields ~= nil and tostring(fields.id) == tostring(st.valve_id_persisted or "") and uuid_ok then
      flovalve_set_prop(FLOVALVE_PROP_VALVE_NAME, fields.name or ("Valve " .. tostring(fields.id)))
      flovalve_set_prop("Mode", FloModel.mode_status_name({ mode = fields.mode }))
      flovalve_track_restore(fields)
      boot_level = flovalve_level_for(fields)
    end
  end
  -- Always establish the tile: persisted level when a validated body
  -- exists, else the best-known default. Boot must speak first — a
  -- binding with no value leaves every tile dark until a push lands.
  flovalve_report_level(boot_level or st.last_level)
end

function OnDriverInit(driver_init_type)
  -- Publish the running version even if Composer already shows the XML default.
  C4:UpdateProperty("Driver Version", FLOVALVE_DRIVER_VERSION)
  print("[flologic-valve] OnDriverInit: " .. FLOVALVE_DRIVER_VERSION .. " (" .. tostring(driver_init_type) .. ")")
  -- Display restore lives in OnDriverLateInit only: it calls SendToProxy
  -- and Persist APIs, which Director's Safe Usage table forbids during
  -- OnDriverInit, and LateInit re-runs it on the fresh state anyway.
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
  flovalve_state.stale_timer = flovalve_set_timer(FLOVALVE_STALE_CHECK_S * 1000, flovalve_check_freshness, true)
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
