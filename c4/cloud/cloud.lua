-- ============================================================================
-- c4/cloud/cloud.lua — FloLogic Cloud (account coordinator) Director glue.
--
-- Owns credentials, one poll loop, discovery, dynamic valve bindings, and
-- per-valve fan-out. Valve drivers are display + control surfaces only.
-- Transport/session/engine structure is adapted from c4/src/main.lua
-- (one-shot FloLogic sessions, TLS TCP bindings, FIFO command queue with
-- polls draining first, report-only GitHub updater); per-valve display,
-- contacts, and picker selection were removed (CLOUD-U6, see README.md) in
-- favor of the slot->valve identity map below. Lua 5.1 safe.
-- ============================================================================

FLOCLOUD_DRIVER_VERSION = "2026090831"
print("[flologic-cloud] Lua loaded: " .. FLOCLOUD_DRIVER_VERSION)

FLOCLOUD_DEFAULT_HUB = "https://hub-cloudapps-prod.azurewebsites.net"
FLOCLOUD_BINDING_FIRST = 6100
FLOCLOUD_BINDING_LAST = 6199
FLOCLOUD_MIN_POLL_SECONDS = 30
FLOCLOUD_MAX_POLL_SECONDS = 3600
FLOCLOUD_LOCAL_TICK_MS = 5000
FLOCLOUD_RECONCILE_MS = 600000
FLOCLOUD_CB_FAILURES = 5
FLOCLOUD_CB_COOLDOWN_S = 300
FLOCLOUD_QUEUE_MAX = 8
-- Refresh (GET_STATE) doubles as a freshness request: at most one
-- refresh-triggered cloud poll per window, coalesced across all slots.
FLOCLOUD_REFRESH_POLL_MIN_S = 30
-- A queued command must start transmitting within this window or it is
-- NACKed "expired" and never sent. The companion settles its own request
-- at 120s, so the transmit deadline stays inside that window with margin
-- for execution and ack transit. The deadline is absolute from enqueue:
-- the command session enforces it immediately before the irreversible
-- request, so preparation (negotiate, upgrade, login, inventory) can
-- never spend the companion's window and still transmit.
FLOCLOUD_COMMAND_DEADLINE_S = 90
-- Watchdog: a session (poll or command) holding busy longer than this
-- never settled — force-clear it and poll fresh instead of wedging the
-- driver forever. Above the 180s session deadline (not equal to it), so
-- a healthy session's own deadline always settles first and only a hung
-- transport — one whose callbacks never run at all — trips the
-- watchdog. Detection happens on the next poll tick past the bound.
FLOCLOUD_BUSY_WATCHDOG_S = 240
-- Freshness budget advertised on every snapshot: the configured poll
-- cadence times the multiple, plus one worst-case session, clamped to
-- the floor. The companion must not infer cadence from traffic (a
-- duplicate reply or a recovery gap would teach it a lie), so the
-- cloud — the only side that knows the poll interval — states the
-- budget outright. SESSION_SLOP_S covers one slow poll session; the max
-- poll interval (3600s) bounds the top end implicitly.
FLOCLOUD_FRESH_MULTIPLE = 3
FLOCLOUD_FRESH_SESSION_SLOP_S = 180
FLOCLOUD_FRESH_FLOOR_S = 300

-- Dynamic CONTROL provider slots (plan D2): one per valve, lowest free id
-- reused, 16-valve cap. Never declared in driver.xml: Composer indexes
-- the cloud via combo + composer_categories, so every link is dynamic and
-- carries its valve name.
FLOCLOUD_SLOT_FIRST = 2001
FLOCLOUD_SLOT_LAST = 2016
FLOCLOUD_LINK_CLASS = "FLOGIC_VALVE"

-- Additive hint a valve attaches to SendToDevice fallback sends so the
-- cloud can attribute a sender ExecuteCommand cannot name. Extra keys are
-- ignored by FloLogicLink.parse, so this never alters the wire contract.
FLOCLOUD_K_FROM = "FLOGIC_FROM"

-- Property names (must match c4/cloud/driver.xml). Deliberately no
-- per-valve selection: no "Select Valve" picker, no "Valve ID Override"
-- (CLOUD-U6). Valve targeting comes only from discovery plus the
-- handshake-verified slot map.
FLOCLOUD_PROP_DEBUG = "Debug Mode"
FLOCLOUD_PROP_EMAIL = "Email"
FLOCLOUD_PROP_PASSWORD = "Password"
FLOCLOUD_PROP_HUB = "Hub URL"
FLOCLOUD_PROP_POLL = "Poll Interval"
FLOCLOUD_PROP_UPDATE_INTERVAL = "Update Check Interval"
FLOCLOUD_PROP_CONNECTION = "Connection"

-- Event names (must match c4/cloud/driver.xml). Account-level only; all
-- per-valve events live on the valve driver.
FLOCLOUD_EV_CONN_LOST = "Connection Lost"
FLOCLOUD_EV_CONN_RESTORED = "Connection Restored"

FLOCLOUD_PERSIST_SLOTS = "flocloud_slots"
FLOCLOUD_PERSIST_RELOG = "flocloud_relog"
FLOCLOUD_PERSIST_VERSION = "flocloud_last_version"
FLOCLOUD_PERSIST_EPOCH = "flocloud_link_epoch"

-- Test seams (globals so the suite can inject scripted peers). Production
-- leaves both nil, which selects the real FloLogic transports below.
flocloud_account_fetch = nil
flocloud_command_send = nil

-- The shared updater defaults to the monolith asset (c4/src/update.lua is
-- read-only); each driver repoints it at its own package (plan D7) and
-- names the whole lockstep family a release must carry to be selectable.
if FloUpdate ~= nil then
  FloUpdate.ASSET = "flologic_cloud.c4z"
  FloUpdate.FAMILY_ASSETS = { "flologic_cloud.c4z", "flologic_water_valve.c4z" }
end

-- Runs FIRST, before replacing module tables or Director callbacks on hot
-- reload. Adapted from c4/src/bootstrap.lua for cloud-owned timers and the
-- slot/queue/link state (attribution: same retire-old-runtime pattern).
function flocloud_retire_runtime()
  local previous = flocloud_state
  if not previous then
    return
  end
  previous.initialized = false
  local session = previous.session
  local binding, port = previous.binding, previous.hub_port
  previous.session, previous.busy, previous.tcp_callbacks = nil, false, nil
  previous.busy_since, previous.busy_what, previous.busy_job = nil, nil, nil
  previous.command_queue = {}
  previous.pending_commands = {}
  for _, name in ipairs({
    "poll_timer",
    "soon_timer",
    "reconcile_timer",
    "debug_timer",
    "update_timer",
    "update_start_timer",
  }) do
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
  if session then
    pcall(session.cancel or session.close)
  end
  -- Never hand a new connection the old binding's pending OFFLINE callback.
  previous.retired_bindings = previous.retired_bindings or {}
  if binding and port then
    previous.retired_bindings[binding] = port
    pcall(function()
      C4:NetDisconnect(binding, port)
    end)
  end
  previous.binding = nil
  if previous.soap_binding and previous.soap_port then
    previous.retired_bindings[previous.soap_binding] = previous.soap_port
    pcall(function()
      C4:NetDisconnect(previous.soap_binding, previous.soap_port)
    end)
  end
  previous.soap_binding, previous.soap_port, previous.soap_callbacks = nil, nil, nil
end

flocloud_retire_runtime()

-- Driver state. One session at a time; commands queue behind a running poll.
local function flocloud_fresh_state()
  return {
    initialized = false,
    busy = false,
    command_queue = {},
    pending_commands = {}, -- [slot][cmd_id] liveness, namespaced per slot
    slots = {},
    valve_slots = {},
    identity = {},
    last_slices = {},
    slice_seq = {}, -- [slot] last ordering sequence pushed (cache replays reuse it)
    link_epoch = flocloud_state and flocloud_state.link_epoch or 0,
    last_devices = nil,
    refresh_poll_at = nil,
    poll_overdue = false,
    relog_token = "",
    cb_failures = 0,
    cb_open_until = 0,
    retired_bindings = flocloud_state and flocloud_state.retired_bindings or {},
  }
end

flocloud_state = flocloud_fresh_state()

--- Timer closures belong to this load, even if Director delivers a cancelled tick.
local function flocloud_set_timer(ms, callback, repeating)
  local owner = flocloud_state
  -- Director rejects a nil repeat flag ("repeat should be a boolean"),
  -- so default it: every existing caller already passes one explicitly.
  return C4:SetTimer(ms, function(timer)
    if flocloud_state == owner and owner.initialized then
      callback(timer)
    end
  end, repeating or false)
end

local function flocloud_log(message)
  if Properties ~= nil and Properties[FLOCLOUD_PROP_DEBUG] == "On" then
    print("[flologic-cloud] " .. tostring(message))
  end
end

local function flocloud_log_warn(message)
  print("[flologic-cloud] WARN: " .. tostring(message))
end

local function flocloud_prop(name)
  if Properties == nil then
    return ""
  end
  return Properties[name] or ""
end

local function flocloud_set_prop(name, value)
  if value == nil then
    value = ""
  end
  value = tostring(value)
  if flocloud_prop(name) ~= value then
    C4:UpdateProperty(name, value)
  end
end

-- --- Transport: Director-managed TLS TCP connection -----------------------
-- Adapted from c4/src/main.lua (attribution): sessions run serially and a
-- closing binding stays reserved until OFFLINE so a new session never
-- inherits its disconnect callbacks.

local function flocloud_find_free_binding()
  local st = flocloud_state
  for id = FLOCLOUD_BINDING_FIRST, FLOCLOUD_BINDING_LAST do
    local ok, address = pcall(function()
      return C4:GetBindingAddress(id)
    end)
    -- Never reissue a live binding even if Director reports no address for
    -- it (for example an idle SOAP binding after disconnect): the hub and
    -- SOAP users would overwrite each other's connection configuration.
    if
      ok
      and (address == nil or address == "")
      and not st.retired_bindings[id]
      and st.binding ~= id
      and st.soap_binding ~= id
    then
      return id
    end
  end
  return nil
end

-- Force-free one retired binding whose OFFLINE never drained. Only used
-- at pool exhaustion: a lost OFFLINE would otherwise wedge every future
-- session permanently. A late OFFLINE for the old use may close one
-- future session; that beats a permanently dead driver, and it is logged.
function flocloud_reclaim_retired_binding()
  local st = flocloud_state
  for id in pairs(st.retired_bindings) do
    st.retired_bindings[id] = nil
    pcall(function()
      C4:SetBindingAddress(id, "")
    end)
    flocloud_log_warn("network binding " .. tostring(id) .. " reclaimed without OFFLINE drain")
    return id
  end
  return nil
end

local function flocloud_ensure_binding(host, port)
  local st = flocloud_state
  local id = flocloud_find_free_binding()
  if id == nil then
    flocloud_reclaim_retired_binding()
    id = flocloud_find_free_binding()
  end
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
  local st = flocloud_state
  if st.binding == idBinding and st.hub_port == nPort and st.tcp_callbacks ~= nil then
    st.tcp_callbacks.on_data(strData)
  elseif st.soap_binding == idBinding and st.soap_callbacks ~= nil then
    st.soap_callbacks.on_data(strData)
  end
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
  local st = flocloud_state
  if strStatus == "OFFLINE" and st.retired_bindings[idBinding] == nPort then
    st.retired_bindings[idBinding] = nil
    pcall(function()
      C4:SetBindingAddress(idBinding, "")
    end)
    return
  end
  if st.soap_binding == idBinding and st.soap_callbacks ~= nil then
    if strStatus == "ONLINE" then
      st.soap_callbacks.on_open()
    elseif strStatus == "OFFLINE" then
      st.soap_callbacks.on_close()
    end
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

local function flocloud_tcp_open(host, port, callbacks)
  local binding, err = flocloud_ensure_binding(host, port)
  if binding == nil then
    return nil, err
  end
  -- Only a binding that actually connected can have an OFFLINE in flight.
  -- Retiring a never-connected binding would strand the id forever when
  -- Director sends no OFFLINE for it, leaking the pool one id per aborted
  -- connect; instead release it for immediate reuse.
  local connected = false
  local tracked = {
    on_open = function()
      connected = true
      callbacks.on_open()
    end,
    on_data = callbacks.on_data,
    on_close = callbacks.on_close,
    on_error = callbacks.on_error,
  }
  flocloud_state.tcp_callbacks = tracked
  C4:NetConnect(binding, port)
  local handle = {}
  function handle.send(bytes)
    C4:SendToNetwork(binding, port, bytes)
  end
  function handle.close()
    if flocloud_state.tcp_callbacks == tracked then
      flocloud_state.tcp_callbacks = nil
      flocloud_state.binding = nil
      if connected then
        flocloud_state.retired_bindings[binding] = port
      else
        C4:SetBindingAddress(binding, "")
      end
      C4:NetDisconnect(binding, port)
    end
  end
  return handle
end

-- --- Transport: platform HTTPS for the negotiate step ----------------------
-- Adapted from c4/src/main.lua (attribution).

local function flocloud_http_post(url, body, headers, cb)
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

local function flocloud_http_get(url, headers, cb)
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

local function flocloud_check_update()
  local st = flocloud_state
  if not st.initialized or st.updater then
    return
  end
  flocloud_set_prop("Update Status", "Checking GitHub")
  flocloud_set_prop("Update Download URL", "")
  flocloud_set_prop("Latest Driver Version", "")
  local check
  check = FloUpdate.new_check({
    http_get = flocloud_http_get,
    set_timeout = function(ms, callback)
      local timer = flocloud_set_timer(ms, callback, false)
      return function()
        timer:Cancel()
      end
    end,
    on_result = function(err, release)
      if flocloud_state ~= st or not st.initialized or st.updater ~= check then
        return
      end
      st.updater = nil
      if err then
        flocloud_set_prop("Update Status", err)
      elseif not release then
        flocloud_set_prop("Update Status", "No published C4 package found in recent releases")
      else
        flocloud_set_prop("Latest Driver Version", release.version)
        flocloud_set_prop("Update Download URL", release.url)
        local status = "Up to date"
        if release.version > FLOCLOUD_DRIVER_VERSION then
          status = "Update available: " .. release.version .. "; run Install Latest Release"
        elseif release.version < FLOCLOUD_DRIVER_VERSION then
          status = "Running build is newer than the published release"
        end
        flocloud_set_prop("Update Status", status)
      end
    end,
  })
  st.updater = check
  check.start()
end

local function flocloud_schedule_update_checks()
  local st = flocloud_state
  if st.update_timer then
    st.update_timer:Cancel()
    st.update_timer = nil
  end
  local hours = tonumber(flocloud_prop("Update Check Interval")) or 24
  if hours ~= hours or hours <= 0 then
    return
  end
  hours = math.min(hours, 168)
  st.update_timer = flocloud_set_timer(hours * 3600000, function()
    flocloud_check_update()
  end, true)
end

-- --- Self-update install transports (file store + local Composer SOAP) -----
-- Adapted from c4/src/main.lua (attribution); the asset and lookup keys are
-- the cloud package, not the monolith one.

-- The store file_set_dir selected: file_move stays within it.
local flocloud_file_store = "C4Z"

-- FileSetDir documents neither a return value nor an error convention,
-- so every refusal shape with any precedent denies: a raise, an explicit
-- false, -1 (Director's sentinel style, cf. FileOpen/FileWrite), or a
-- (nil, err) pair (Lua C style). No success convention produces any of
-- those shapes, so this only ever refuses. (A denial that silently
-- succeeds is unverifiable — no getter exists — and is caught a cycle
-- later by the version check, as the 0815 no-op was.)
local function flocloud_dir_accepted(ok, ret, err)
  return ok and ret ~= false and ret ~= -1 and (ret ~= nil or err == nil)
end

local function flocloud_file_set_dir(alias)
  -- Pass the C4Z_ROOT unlock key first (undocumented; pcall'd since not
  -- every OS accepts it), then select exactly the requested alias. There
  -- is no fallback store: Director's UpdateProjectC4i hot-reload
  -- resolves the staged package in C4Z_ROOT only, so staging into the
  -- running driver's own directory verifies and triggers yet reloads
  -- the previously installed build. Denial refuses the install.
  local unlock_ok, unlock_ret, unlock_err = pcall(function()
    return C4:FileSetDir(FloUpdate.C4Z_ROOT_UNLOCK_KEY)
  end)
  flocloud_log_warn(
    "update file store unlock key: "
      .. (flocloud_dir_accepted(unlock_ok, unlock_ret, unlock_err) and "accepted" or "rejected")
  )
  local ok, ret, err = pcall(function()
    return C4:FileSetDir(alias)
  end)
  if flocloud_dir_accepted(ok, ret, err) then
    flocloud_file_store = alias
    flocloud_log_warn("update file store: " .. alias)
    return true
  end
  return false
end

local function flocloud_file_move(from_name, to_name)
  -- C4:FileMove(alias, from, alias, to) is documented from OS 3.3.0 with
  -- C4Z among the allowed aliases; the cloud driver requires 3.3.0+.
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
      C4:FileMove(flocloud_file_store, form[1], flocloud_file_store, form[2])
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

local function flocloud_file_exists(name)
  local ok, exists = pcall(function()
    return C4:FileExists(name)
  end)
  return ok and exists == true
end

local function flocloud_file_delete(name)
  pcall(function()
    C4:FileDelete(name)
  end)
end

local function flocloud_file_write(name, data)
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

local function flocloud_file_size(name)
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

local function flocloud_file_read(name, count)
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

local function flocloud_get_installed(filename)
  local ok, devices = pcall(function()
    return C4:GetDevicesByC4iName(filename)
  end)
  return ok and type(devices) == "table" and next(devices) ~= nil
end

-- One persistent plain-TCP binding for Composer's local SOAP endpoint,
-- separate from the websocket binding. Installs are rare and serial.
local function flocloud_ensure_soap_binding()
  local st = flocloud_state
  if st.soap_binding ~= nil then
    return st.soap_binding
  end
  local id = flocloud_find_free_binding()
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
function flocloud_soap_send(packet, cb)
  local settled = false
  local owner = flocloud_state
  local binding, err = flocloud_ensure_soap_binding()
  if binding == nil then
    cb(err)
    return function() end
  end
  local function finish(soap_err)
    if settled then
      return
    end
    settled = true
    if flocloud_state == owner then
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
  local grace = flocloud_set_timer(3000, function()
    if sent then
      finish(nil)
    else
      finish("cannot reach Composer endpoint")
    end
  end, false)
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

local function flocloud_install_update(force)
  local st = flocloud_state
  if not st.initialized then
    return
  end
  if st.updater then
    flocloud_set_prop("Update Status", "Update operation already running")
    return
  end
  flocloud_set_prop(
    "Update Status",
    force and "Force-reinstalling the latest release..." or "Checking GitHub for the latest release..."
  )
  local op
  op = FloUpdate.new_install({
    http_get = flocloud_http_get,
    set_timeout = function(ms, callback)
      local timer = flocloud_set_timer(ms, callback, false)
      return function()
        timer:Cancel()
      end
    end,
    -- Try the .c4i proxy name first, then the bare proxy name, then the
    -- package filename, so no single wrong guess can disable installs.
    -- Confirm which key matches on a live Director.
    get_installed = function()
      for _, key in ipairs({ "flologic_cloud.c4i", "flologic_cloud", FloUpdate.ASSET }) do
        if flocloud_get_installed(key) then
          flocloud_log_warn("update installed lookup matched: " .. key)
          return true
        end
      end
      return false
    end,
    file_set_dir = flocloud_file_set_dir,
    file_exists = flocloud_file_exists,
    file_delete = flocloud_file_delete,
    file_write = flocloud_file_write,
    file_size = flocloud_file_size,
    file_read = flocloud_file_read,
    file_move = flocloud_file_move,
    log_warn = flocloud_log_warn,
    soap_send = flocloud_soap_send,
    force = force,
    current_version = FLOCLOUD_DRIVER_VERSION,
    on_progress = function(text)
      if flocloud_state == st and st.updater == op then
        flocloud_set_prop("Update Status", text)
      end
    end,
    on_result = function(install_err, outcome)
      if flocloud_state ~= st or not st.initialized or st.updater ~= op then
        return
      end
      st.updater = nil
      if install_err then
        flocloud_set_prop(
          "Update Status",
          "Install failed: "
            .. install_err
            .. " — download "
            .. FloUpdate.ASSET
            .. " from the GitHub release and update the driver in Composer"
        )
      elseif outcome and outcome.attempted then
        flocloud_set_prop(
          "Update Status",
          "Installation unconfirmed: " .. outcome.attempted .. "; verify Driver Version and Lua Output in Composer"
        )
      elseif outcome and outcome.skipped == "not-installed" then
        flocloud_set_prop("Update Status", "No install applied (driver package not found on controller)")
      else
        local latest = (outcome and outcome.latest) or "?"
        flocloud_set_prop(
          "Update Status",
          "No install applied (current " .. FLOCLOUD_DRIVER_VERSION .. ", latest release " .. latest .. ")"
        )
      end
    end,
  })
  st.updater = op
  op.start()
end

-- --- Crypto / randomness (platform-backed, probed once) --------------------
-- Adapted from c4/src/main.lua (attribution).

local function flocloud_hex_to_raw(hex)
  if type(hex) ~= "string" or #hex ~= 40 or hex:find("[^0-9a-fA-F]") then
    error("C4:Hash returned an unexpected digest shape")
  end
  return (hex:gsub("..", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

--- Probe every plausible C4:Hash shape: the 3-argument raw form first, then
--- the 2-argument form accepting raw bytes or hex. Returns
--- { digest, arity, encoding } or nil when nothing usable answers.
local function flocloud_probe_sha1()
  for _, name in ipairs({ "SHA1", "sha1", "SHA-1" }) do
    local ok, result, err = pcall(function()
      return C4:Hash(name, "test", { return_encoding = "NONE", data_encoding = "NONE" })
    end)
    if ok and result ~= nil and err == nil and #result == 20 then
      return { digest = name, arity = 3, encoding = "raw" }
    end
  end
  for _, name in ipairs({ "SHA1", "sha1", "SHA-1" }) do
    local ok, result, herr = pcall(function()
      return C4:Hash(name, "test")
    end)
    if ok and herr == nil and type(result) == "string" then
      if #result == 20 then
        return { digest = name, arity = 2, encoding = "raw" }
      elseif #result == 40 and not result:find("[^0-9a-fA-F]") then
        return { digest = name, arity = 2, encoding = "hex" }
      end
    end
  end
  return nil
end

local function flocloud_sha1(data)
  local probe = flocloud_state.sha1_probe
  local out, err
  if probe.arity == 3 then
    out, err = C4:Hash(probe.digest, data, { return_encoding = "NONE", data_encoding = "NONE" })
  else
    out, err = C4:Hash(probe.digest, data)
  end
  if out == nil then
    error("C4:Hash failed: " .. tostring(err))
  end
  if probe.encoding == "hex" then
    return flocloud_hex_to_raw(out)
  end
  return out
end

--- Use the random portion of UUIDv4; omit its version/variant bytes.
local function flocloud_random_bytes(count)
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

local function flocloud_random_mask()
  return { flocloud_random_bytes(4):byte(1, 4) }
end

local function flocloud_client_key()
  return C4:Base64Encode(flocloud_random_bytes(16))
end

-- --- Session factory -------------------------------------------------------

local function flocloud_new_session()
  return FloLogic.new_session({
    email = flocloud_prop(FLOCLOUD_PROP_EMAIL),
    password = flocloud_prop(FLOCLOUD_PROP_PASSWORD),
    device_code = flocloud_state.device_code,
    device_token = flocloud_state.device_token,
    http_post = flocloud_http_post,
    tcp_open = flocloud_tcp_open,
    set_timeout = function(ms, fn)
      local timer = flocloud_set_timer(ms, function(t)
        t:Cancel()
        fn()
      end, false)
      return function()
        timer:Cancel()
      end
    end,
    client_key = flocloud_client_key,
    sha1 = flocloud_sha1,
    b64encode = function(data)
      return C4:Base64Encode(data)
    end,
    random_mask = flocloud_random_mask,
    relog_token = flocloud_state.relog_token,
    log = flocloud_log,
    log_warn = flocloud_log_warn,
  })
end

local function flocloud_hub_url()
  local url = flocloud_prop(FLOCLOUD_PROP_HUB)
  if url == nil or url == "" then
    url = FLOCLOUD_DEFAULT_HUB
  end
  return url
end

local function flocloud_poll_interval_s()
  local seconds = tonumber(flocloud_prop(FLOCLOUD_PROP_POLL)) or 60
  if seconds ~= seconds then
    seconds = 60
  end
  if seconds < FLOCLOUD_MIN_POLL_SECONDS then
    seconds = FLOCLOUD_MIN_POLL_SECONDS
  elseif seconds > FLOCLOUD_MAX_POLL_SECONDS then
    seconds = FLOCLOUD_MAX_POLL_SECONDS
  end
  return seconds
end

-- Freshness budget advertised on every snapshot: three configured poll
-- intervals plus one worst-case session, never below the floor. The
-- companion's watchdog runs on this — never on spacing it infers from
-- traffic, which duplicates and recovery gaps would corrupt.
local function flocloud_fresh_budget()
  local budget = flocloud_poll_interval_s() * FLOCLOUD_FRESH_MULTIPLE + FLOCLOUD_FRESH_SESSION_SLOP_S
  if budget < FLOCLOUD_FRESH_FLOOR_S then
    budget = FLOCLOUD_FRESH_FLOOR_S
  end
  return budget
end

-- --- Per-valve identity and slot map ---------------------------------------
-- Each slot binds to one valve id (the "index"). The location hash
-- binds that slot to the valve's stable cloud identity (id + uuid) so a
-- reused numeric id with different cloud metadata is detected instead of
-- silently inheriting the old slot. The persisted map restores Composer
-- connections across restarts; it is never trusted across binds — every
-- bind re-handshakes (plan D3) and re-verifies against fresh inventory.

function flocloud_normalize_id(value)
  if type(value) == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return nil
    end
    value = tostring(value)
  end
  if type(value) ~= "string" then
    return nil
  end
  value = value:match("^%s*(.-)%s*$")
  if value == "" then
    return nil
  end
  return value
end

function flocloud_identity_hash(valve_id, uuid)
  return FloLogicLink.digest(tostring(valve_id) .. "|" .. tostring(uuid or ""))
end

-- Account/endpoint scope of the current configuration. Identity records
-- carry the scope they were verified under; two ID-only records (no
-- uuid on either side) from DIFFERENT scopes are never equated — a
-- numeric id is only stable within one account on one endpoint. The
-- digest is persisted, never the credentials.
function flocloud_config_scope()
  return FloLogicLink.digest(flocloud_prop(FLOCLOUD_PROP_EMAIL) .. "|" .. flocloud_hub_url())
end

local function flocloud_sorted_slots()
  local ids = {}
  for slot in pairs(flocloud_state.slots) do
    ids[#ids + 1] = slot
  end
  table.sort(ids)
  return ids
end

local function flocloud_find_free_slot_except(except)
  for slot = FLOCLOUD_SLOT_FIRST, FLOCLOUD_SLOT_LAST do
    if flocloud_state.slots[slot] == nil and (except == nil or not except[slot]) then
      return slot
    end
  end
  -- Lifetime-cap defense: reuse a slot whose valve left the account, but
  -- only when its binding was explicitly observed unbound. Never steal a
  -- live (bound) link, and never a never-observed one (e.g. post-restart,
  -- where a binding may still exist): the valve there would silently
  -- adopt a stranger's identity on its next hello.
  for slot = FLOCLOUD_SLOT_FIRST, FLOCLOUD_SLOT_LAST do
    local entry = flocloud_state.slots[slot]
    if entry ~= nil and not entry.available and entry.bound == false and (except == nil or not except[slot]) then
      return slot
    end
  end
  return nil
end

function flocloud_find_free_slot()
  return flocloud_find_free_slot_except(nil)
end

local function flocloud_remember_slot(slot, valve_id, name, uuid, available, scope)
  local st = flocloud_state
  local previous = st.slots[slot]
  if previous ~= nil and (previous.valve_id ~= valve_id or previous.uuid ~= uuid) then
    -- Slot reuse (or same-id replacement): drop the previous valve's
    -- reverse mapping, cached slice, and ordering sequence so neither
    -- fallback attribution nor stale pushes can leak across physical
    -- valves. A stale cached slice must never replay for the new valve.
    if st.valve_slots[previous.valve_id] == slot then
      st.valve_slots[previous.valve_id] = nil
    end
    st.last_slices[slot] = nil
    st.slice_seq[slot] = nil
  end
  st.slots[slot] = {
    valve_id = valve_id,
    name = name,
    uuid = uuid,
    available = available,
    bound = st.slots[slot] and st.slots[slot].bound,
  }
  st.valve_slots[valve_id] = slot
  st.identity[slot] =
    { valve_id = valve_id, key_hash = flocloud_identity_hash(valve_id, uuid), scope = scope or flocloud_config_scope() }
end

function flocloud_encode_slots()
  local list = {}
  for _, slot in ipairs(flocloud_sorted_slots()) do
    local entry = flocloud_state.slots[slot]
    local ident = flocloud_state.identity[slot]
    list[#list + 1] = {
      slot = slot,
      valve_id = entry.valve_id,
      name = entry.name,
      uuid = entry.uuid,
      available = entry.available and true or false,
      scope = ident ~= nil and ident.scope or nil,
    }
  end
  return JSON.encode(list)
end

function flocloud_decode_slots(text)
  if type(text) ~= "string" or text == "" then
    return nil, "no persisted map"
  end
  local ok, list = pcall(JSON.decode, text)
  if not ok or type(list) ~= "table" then
    return nil, "bad persisted map"
  end
  local clean = {}
  for _, row in ipairs(list) do
    local slot = tonumber(row.slot)
    local valve_id = flocloud_normalize_id(row.valve_id)
    if
      slot ~= nil
      and slot % 1 == 0
      and slot >= FLOCLOUD_SLOT_FIRST
      and slot <= FLOCLOUD_SLOT_LAST
      and valve_id ~= nil
    then
      clean[#clean + 1] = {
        slot = slot,
        valve_id = valve_id,
        name = tostring(row.name or valve_id),
        uuid = type(row.uuid) == "string" and row.uuid or nil,
        available = row.available ~= false,
        scope = type(row.scope) == "string" and row.scope or nil,
      }
    end
  end
  return clean
end

local function flocloud_persist_slots()
  local ok, encoded = pcall(flocloud_encode_slots)
  if ok then
    C4:PersistSetValue(FLOCLOUD_PERSIST_SLOTS, encoded)
  else
    flocloud_log_warn("slot persist failed: " .. tostring(encoded))
  end
end

local function flocloud_add_binding(slot, name)
  C4:AddDynamicBinding(slot, "CONTROL", true, name, FLOCLOUD_LINK_CLASS, false, false)
  flocloud_log("dynamic binding added: id=" .. tostring(slot) .. " class=" .. FLOCLOUD_LINK_CLASS)
end

-- Re-create every persisted runtime binding so Composer connections survive
-- restarts (plan D2). A stale entry self-heals: the next discovery pass
-- rewrites the persisted map.
local function flocloud_restore_slots()
  local saved = C4:PersistGetValue(FLOCLOUD_PERSIST_SLOTS)
  local list, err = flocloud_decode_slots(saved)
  if list == nil then
    flocloud_log("no slot map to restore: " .. tostring(err))
    return
  end
  for _, row in ipairs(list) do
    -- A Lua reload (driver update) keeps Director-side runtime bindings,
    -- so re-add may fail on an id that already exists. The persisted map
    -- is authoritative either way: remember the slot regardless and let
    -- traffic prove the binding.
    local ok, add_err = pcall(flocloud_add_binding, row.slot, row.name)
    if not ok then
      flocloud_log_warn("slot restore re-add failed for " .. tostring(row.slot) .. ": " .. tostring(add_err))
    end
    flocloud_remember_slot(row.slot, row.valve_id, row.name, row.uuid, row.available, row.scope)
  end
  flocloud_persist_slots()
end

-- Bound-consumer discovery for one slot. Returns an array of device ids:
-- EMPTY when the slot is observed unbound, or nil when Director cannot
-- answer (the caller keeps the previous flag rather than flapping on a
-- transient error). Director documents null as the SUCCESSFUL no-bindings
-- result ("null if no bindings or a table of device id/device name
-- pairs"), so a nil answer is observed-unbound — only a missing API or
-- a raised error is indeterminate. Decode the map by key: ordinary names
-- must never be mistaken for ids, and a numeric name must never become
-- an id.
local function flocloud_bound_consumers(slot)
  if C4.GetBoundConsumerDevices == nil then
    return nil
  end
  local ok, found = pcall(function()
    return C4:GetBoundConsumerDevices(0, slot)
  end)
  if not ok then
    return nil
  end
  if found == nil then
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
  elseif tonumber(found) ~= nil then
    -- Defensive: a scalar answer carries one id, never a name.
    ids[#ids + 1] = tonumber(found)
  end
  return ids
end

-- Slow reconciliation (plan D3): never trust bind events alone, because
-- restart-restored connections may not re-fire them.
function flocloud_reconcile_bindings()
  local st = flocloud_state
  if not st.initialized then
    return
  end
  for _, slot in ipairs(flocloud_sorted_slots()) do
    local consumers = flocloud_bound_consumers(slot)
    if consumers ~= nil then
      st.slots[slot].bound = (#consumers > 0)
    end
  end
end

-- A slot authorizes physical writes only after fresh inventory confirms
-- its exact valve identity: the numeric id must be present AND its
-- immutable uuid must hash to the slot's authorized identity, verified
-- under the CURRENT account/endpoint scope. Before the first poll the
-- restored map is unverified, so this returns false — linking may still
-- proceed (on_hello answers optimistically), but no command executes
-- from an unverified map.
function flocloud_verify_slot(slot)
  local st = flocloud_state
  local entry = st.slots[slot]
  if entry == nil or not entry.available then
    return false
  end
  if st.last_devices == nil then
    return false
  end
  local ident = st.identity[slot]
  if ident == nil or ident.valve_id ~= entry.valve_id then
    return false
  end
  if ident.scope ~= flocloud_config_scope() then
    return false
  end
  local valves = FloModel.controllable_valves(st.last_devices)
  local valve = FloModel.find_valve(valves, entry.valve_id)
  if valve == nil then
    return false
  end
  local uuid = type(valve.uuid) == "string" and valve.uuid or nil
  return flocloud_identity_hash(entry.valve_id, uuid) == ident.key_hash
end

-- --- Slot send primitives ---------------------------------------------------
-- Provider-side send with the plan-D1 fallback: BindMessages first, then
-- SendToDevice at each bound consumer when the proxy send raises. Defined
-- ahead of discovery because reconciliation itself publishes unavailable
-- transitions (Lua locals must precede their callers).
function flocloud_send_to_slot(slot, envelope)
  local name = envelope[FloLogicLink.K_MSG]
  local ok = pcall(function()
    C4:SendToProxy(slot, name, envelope, "COMMAND")
  end)
  if ok then
    return "proxy"
  end
  local consumers = flocloud_bound_consumers(slot) or {}
  for _, device_id in ipairs(consumers) do
    pcall(function()
      C4:SendToDevice(device_id, name, envelope)
    end)
  end
  flocloud_log_warn("slot " .. tostring(slot) .. " fell back to SendToDevice (" .. #consumers .. " consumers)")
  return "device"
end

-- Per-slot ordering: every NEW observation (poll fan-out) and every
-- availability notice consumes the next sequence, so the companion can
-- order snapshots against notices. Cache replays (hello/get_state)
-- reuse the cached slice's sequence BY DESIGN — the companion drops a
-- replay it already applied instead of letting it renew freshness or
-- revoke a newer unavailable marking.
local function flocloud_next_seq(slot)
  local st = flocloud_state
  st.slice_seq[slot] = (st.slice_seq[slot] or 0) + 1
  return st.slice_seq[slot]
end

local function flocloud_push_slice(slot, slice, fresh)
  local st = flocloud_state
  local seq = st.slice_seq[slot]
  if fresh then
    seq = flocloud_next_seq(slot)
  end
  local extra = nil
  if seq ~= nil then
    extra = { seq = seq, epoch = st.link_epoch, fresh_s = flocloud_fresh_budget() }
  end
  local envelope, err = FloLogicLink.build_state(slice, extra)
  if envelope == nil then
    flocloud_log_warn("slot " .. tostring(slot) .. " slice rejected: " .. tostring(err))
    return false
  end
  flocloud_send_to_slot(slot, envelope)
  return true
end

-- Tell a companion its valve is gone (or failed verification) so it stops
-- presenting last-known state as current. Slots observed unbound have no
-- listener and are skipped; force bypasses that for a peer that just
-- spoke (hello on a stale slot).
local function flocloud_push_unavailable(slot, valve_id, reason, force)
  local st = flocloud_state
  local entry = st.slots[slot]
  if entry == nil then
    return false
  end
  if not force and entry.bound == false then
    return false
  end
  local envelope, err =
    FloLogicLink.build_unavailable(valve_id, reason, { seq = flocloud_next_seq(slot), epoch = st.link_epoch })
  if envelope == nil then
    flocloud_log_warn("slot " .. tostring(slot) .. " unavailable build failed: " .. tostring(err))
    return false
  end
  flocloud_send_to_slot(slot, envelope)
  return true
end

-- --- Discovery: inventory reconciles dynamic bindings -----------------------
-- Added valves take the lowest free slot; removed valves mark their slot
-- unavailable without deleting the bound slot (plan D2). Removed slots keep
-- their Composer connection so a returning valve resumes silently.

local function flocloud_display_name(valve)
  return FloModel.valve_name(valve):gsub("[,\r\n]", " ")
end

-- Forward: quarantine (below) purges a slot's unsent work, but the nack
-- primitive lives in the link-receive section further down.
local flocloud_purge_slot_jobs

-- Place one new valve on the first slot that can take it without
-- endangering another valve's identity. Never-used slots take an add;
-- every OTHER candidate — a different valve's departed slot AND a
-- quarantined same-id slot (whose binding still exists under the old
-- identity) — requires a live zero-consumer observation plus a
-- successful remove + re-add as one atomic step. A live consumer or an
-- indeterminate lookup vetoes that slot — the old identity is
-- preserved, the stale bound flag is refreshed, and the search continues
-- on the next candidate instead of retargeting a live Composer link.
local function flocloud_place_valve(id, valve)
  local st = flocloud_state
  local name = flocloud_display_name(valve)
  local uuid = type(valve.uuid) == "string" and valve.uuid or nil
  local skipped = {}
  while true do
    local slot = flocloud_find_free_slot_except(skipped)
    if slot == nil then
      return false
    end
    local previous = st.slots[slot]
    if previous == nil then
      local ok, add_err = pcall(flocloud_add_binding, slot, name)
      if ok then
        flocloud_remember_slot(slot, id, name, uuid, true)
        return true
      end
      -- Fresh slot whose add failed: fail closed on this slot and try
      -- the next rather than mapping a valve onto a missing binding.
      flocloud_log_warn("slot add failed for valve " .. tostring(id) .. ": " .. tostring(add_err))
      skipped[slot] = true
    else
      -- Slot reuse with a new valve: the Director binding still shows
      -- the departed valve's name, and Director has no binding-rename
      -- API. Reuse requires observed-unbound, re-verified live first,
      -- since the flag may be stale.
      local consumers = flocloud_bound_consumers(slot)
      if consumers == nil then
        skipped[slot] = true
        flocloud_log_warn(
          "slot "
            .. tostring(slot)
            .. " reuse vetoed: binding lookup failed; keeping valve "
            .. tostring(previous.valve_id)
        )
      elseif #consumers > 0 then
        -- The flag was stale: a live consumer is bound. Refresh the
        -- flag and keep the old identity — the Composer connection and
        -- its programming still refer to the original valve.
        previous.bound = true
        skipped[slot] = true
        flocloud_log_warn(
          "slot "
            .. tostring(slot)
            .. " reuse vetoed: live consumer bound; keeping valve "
            .. tostring(previous.valve_id)
        )
      else
        local rok = pcall(function()
          C4:RemoveDynamicBinding(slot)
        end)
        if not rok then
          skipped[slot] = true
          flocloud_log_warn(
            "slot "
              .. tostring(slot)
              .. " reuse vetoed: binding remove failed; keeping valve "
              .. tostring(previous.valve_id)
          )
        else
          local ok, add_err = pcall(flocloud_add_binding, slot, name)
          if ok then
            flocloud_log("slot " .. tostring(slot) .. " rebound to valve " .. tostring(id))
            flocloud_remember_slot(slot, id, name, uuid, true)
            return true
          end
          -- The binding is gone and the add failed: the old entry stays
          -- so the next discovery retries the whole remove + add on this
          -- same slot instead of scattering the newcomer elsewhere.
          flocloud_log_warn("slot add failed for valve " .. tostring(id) .. ": " .. tostring(add_err))
          return false
        end
      end
    end
  end
end

function flocloud_reconcile_inventory(devices)
  local st = flocloud_state
  local valves = FloModel.controllable_valves(devices or {})
  local seen = {}
  for _, valve in ipairs(valves) do
    local id = flocloud_normalize_id(valve.id)
    if id ~= nil then
      seen[id] = valve
    end
  end
  local added, kept, missing = 0, 0, 0
  for _, slot in ipairs(flocloud_sorted_slots()) do
    local entry = st.slots[slot]
    local valve = seen[entry.valve_id]
    if valve == nil then
      if entry.available then
        entry.available = false
        missing = missing + 1
        flocloud_log_warn("valve " .. tostring(entry.valve_id) .. " left the account; slot " .. slot .. " unavailable")
        flocloud_purge_slot_jobs(slot, "valve-unavailable")
        flocloud_push_unavailable(slot, entry.valve_id, "left-account")
      end
    else
      local uuid = type(valve.uuid) == "string" and valve.uuid or nil
      local ident = st.identity[slot]
      local want = flocloud_identity_hash(entry.valve_id, uuid)
      local scope = flocloud_config_scope()
      -- A numeric id is only stable within one account on one endpoint:
      -- across a scope change, adoption requires the immutable uuid on
      -- BOTH sides and equal. ID-only records across namespaces
      -- quarantine — they cannot prove they are the same valve.
      local scope_moved = ident ~= nil and ident.scope ~= scope
      local uuid_proven = entry.uuid ~= nil and entry.uuid ~= "" and uuid ~= nil and uuid ~= "" and entry.uuid == uuid
      if
        (ident ~= nil and (ident.valve_id ~= entry.valve_id or ident.key_hash ~= want))
        or (scope_moved and not uuid_proven)
      then
        -- Same numeric id, different immutable identity: a different
        -- physical valve (replacement, account or endpoint change). Never
        -- silently adopt it — quarantine the slot and let the valve
        -- re-place as a newcomer, which forces explicit reassociation at
        -- the Composer layer. Warn once per conflict, not once per poll.
        -- Already-admitted work for the old authorization is purged:
        -- admission-time identity must never outlive a quarantine.
        if not entry.conflict then
          entry.conflict = true
          flocloud_log_warn(
            "slot "
              .. tostring(slot)
              .. " identity conflict for valve "
              .. tostring(entry.valve_id)
              .. ": uuid changed; slot quarantined, re-link the valve on its new slot"
          )
          flocloud_purge_slot_jobs(slot, "identity-changed")
          flocloud_push_unavailable(slot, entry.valve_id, "identity-conflict")
        end
        entry.available = false
        if st.valve_slots[entry.valve_id] == slot then
          st.valve_slots[entry.valve_id] = nil
        end
        st.last_slices[slot] = nil
        missing = missing + 1
      else
        entry.conflict = nil
        entry.available = true
        entry.name = flocloud_display_name(valve)
        entry.uuid = uuid
        st.identity[slot] = { valve_id = entry.valve_id, key_hash = want, scope = scope }
        kept = kept + 1
      end
    end
  end
  -- Sorted so concurrent new valves always take slots in a stable order.
  local new_ids = {}
  for id in pairs(seen) do
    if st.valve_slots[id] == nil then
      new_ids[#new_ids + 1] = id
    end
  end
  table.sort(new_ids)
  for _, id in ipairs(new_ids) do
    local valve = seen[id]
    if flocloud_place_valve(id, valve) then
      added = added + 1
    else
      flocloud_log_warn(
        "valve " .. tostring(id) .. " has no safe slot (cap " .. (FLOCLOUD_SLOT_LAST - FLOCLOUD_SLOT_FIRST + 1) .. ")"
      )
    end
  end
  flocloud_persist_slots()
  flocloud_set_prop("Valve Count", tostring(#valves))
  local lines = {}
  for _, valve in ipairs(valves) do
    lines[#lines + 1] = tostring(valve.id) .. ": " .. flocloud_display_name(valve)
  end
  flocloud_set_prop("Available Valves", table.concat(lines, " | "))
  return { added = added, kept = kept, missing = missing, total = #valves }
end

-- --- Fan-out: one snapshot slice per bound slot -----------------------------

local function flocloud_truncate(text, max_len)
  text = tostring(text or "")
  if #text > max_len then
    return text:sub(1, max_len)
  end
  return text
end

-- Build the link valve_state slice for one cloud valve plus its access row.
-- Returns the slice table or nil plus the link rejection reason.
-- Scrub a cosmetic cloud string for the link: control characters can
-- never survive validation, so strip them (and cap the length) instead
-- of letting one odd name sink the whole snapshot.
local function flocloud_clean_text(value, max_len)
  local text = tostring(value or ""):gsub("[%c\127]", "")
  if #text > max_len then
    text = text:sub(1, max_len)
  end
  return text
end

function flocloud_build_slice(valve, access, now)
  if type(valve) ~= "table" then
    return nil, "bad-valve"
  end
  local id = flocloud_normalize_id(valve.id)
  local mode = tonumber(valve.mode)
  -- Only non-negative integers carry flag semantics; anything else is
  -- corruption the link validator would reject, so fail the slice here
  -- with the valve named.
  if id == nil or mode == nil or mode % 1 ~= 0 or mode < 0 then
    return nil, "bad-valve"
  end
  local slice = { id = id, mode = mode, online = valve.online == true }
  local uuid = flocloud_clean_text(valve.uuid, 128)
  if uuid ~= "" then
    slice.uuid = uuid
  end
  local name = flocloud_clean_text(FloModel.valve_name(valve), 128)
  if name == "" then
    name = "Valve " .. id
  end
  slice.name = name
  local device_type = flocloud_clean_text(valve.deviceTypeName, 64)
  if device_type ~= "" then
    slice.device_type = device_type
  end
  local flow_state = tonumber(valve.flowState)
  if flow_state ~= nil and flow_state % 1 == 0 and flow_state >= 0 then
    slice.flow_state = flow_state
  end
  if tonumber(valve.homeIntervalTime) ~= nil then
    slice.home_interval = tonumber(valve.homeIntervalTime)
  end
  if tonumber(valve.awayIntervalTime) ~= nil then
    slice.away_interval = tonumber(valve.awayIntervalTime)
  end
  if tonumber(valve.bypassTime) ~= nil then
    slice.bypass_time = tonumber(valve.bypassTime)
  end
  if type(access) == "table" and tonumber(access.notificationsList) ~= nil then
    slice.access = tonumber(access.notificationsList)
  end
  slice.updated = now or os.time()
  local ok, err = FloLogicLink.build_state_body(slice)
  if ok == nil then
    return nil, err
  end
  return slice
end

-- Fan one slice out per slot, to that slot only. Slots explicitly observed
-- unbound are skipped; never-observed slots still push so a restart never
-- black-holes state before the slow reconcile runs.
function flocloud_fanout(slices)
  local st = flocloud_state
  for _, slot in ipairs(flocloud_sorted_slots()) do
    local entry = st.slots[slot]
    local slice = slices[slot]
    if entry ~= nil and slice ~= nil and entry.available and entry.bound ~= false then
      st.last_slices[slot] = slice
      flocloud_push_slice(slot, slice, true)
    end
  end
end

-- --- Link action set --------------------------------------------------------
-- The valve forwards one programming action per FLOGIC_COMMAND; the cloud
-- authorizes it against the slot map and translates it to cloud field
-- values. Modes and ranges mirror c4/src/main.lua ExecuteCommand
-- (attribution); the names below are the link vocabulary unit 3 targets.

FLOCLOUD_MODE_ACTIONS = {
  mode_home = "home",
  mode_away = "away",
  mode_bypass = "bypass",
  mode_shutoff = "shutoff",
  mode_disabled = "disabled",
}

FLOCLOUD_VALUE_ACTIONS = {
  home_limit = { field = "homeIntervalTime", min = 1, max = 10080 },
  away_limit = { field = "awayIntervalTime", min = 0, max = 10080, fractional = true },
  bypass_time = { field = "bypassTime", min = 1, max = 10080 },
  auto_away = { field = "autoAwayTime", min = 1, max = 8760 },
  temp_alert = { field = "lowTemperatureAlert", min = -50, max = 150 },
  temp_shutoff = { field = "lowTemperatureLimit", min = -50, max = 150 },
  pre_alert = { field = "preAlertNoticeInterval", min = 1, max = 10080 },
  noflow_notice = { field = "noFlowNoticeInterval", min = 1, max = 604800 },
  flow_sensitivity = { field = "dripRate", min = 0, max = 1000, fractional = true },
}

-- Translate one validated link COMMAND body to cloud field values.
-- Returns the fields table or nil plus a NACK reason.
function flocloud_action_fields(body)
  if type(body) ~= "table" then
    return nil, "bad-action"
  end
  local action = body.action
  local mode = FLOCLOUD_MODE_ACTIONS[action]
  if mode ~= nil then
    return { mode = FloModel.VALVE_MODES[mode] }
  end
  local spec = FLOCLOUD_VALUE_ACTIONS[action]
  if spec == nil then
    return nil, "unknown-action"
  end
  local value = tonumber(body.value)
  if value == nil or value ~= value or value == math.huge or value == -math.huge then
    return nil, "bad-param:value"
  end
  if (not spec.fractional and value % 1 ~= 0) or value < spec.min or value > spec.max then
    return nil, "bad-param:value"
  end
  return { [spec.field] = value }
end

-- --- Link receive: handshake, state poll, authorized commands ---------------
-- Every command is authorized against the slot->valve map (plan D6);
-- mismatches are dropped or NACKed, never executed.

local function flocloud_ack(slot, cmd_id)
  local envelope = FloLogicLink.build_ack(cmd_id)
  if envelope ~= nil then
    flocloud_send_to_slot(slot, envelope)
  end
end

local function flocloud_nack(slot, cmd_id, reason)
  local envelope = FloLogicLink.build_nack(cmd_id, reason)
  if envelope ~= nil then
    flocloud_send_to_slot(slot, envelope)
  else
    flocloud_log_warn("nack build failed for slot " .. tostring(slot) .. ": " .. tostring(reason))
  end
end

-- Drop every unsent job for a slot whose authorization just died
-- (valve left, identity conflicted): each valve still awaits its
-- reply, so every dropped job is nacked — never silently discarded.
-- Queued jobs are the only possible occupants (polls and commands run
-- serially, so nothing executes while a poll quarantines), but the
-- pending entries clear unconditionally so a late completion can never
-- ack for a dead authorization.
flocloud_purge_slot_jobs = function(slot, reason)
  local st = flocloud_state
  local queue = {}
  local dropped = nil
  for _, job in ipairs(st.command_queue) do
    if job.slot == slot then
      dropped = job.name
      flocloud_nack(slot, job.cmd_id, reason)
    else
      queue[#queue + 1] = job
    end
  end
  st.command_queue = queue
  st.pending_commands[slot] = nil
  if dropped ~= nil then
    flocloud_set_prop("Last Command", dropped .. ": dropped (" .. reason .. ")")
  end
end

local function flocloud_on_hello(slot)
  local st = flocloud_state
  local entry = st.slots[slot]
  if entry == nil then
    flocloud_log("hello on unmapped slot " .. tostring(slot) .. "; staying silent")
    return false
  end
  -- Pre-first-poll linking answers from the restored map so valves link
  -- without waiting; the reply below always hurries a verifying poll.
  -- Commands still fail closed until that poll lands (verify_slot).
  if st.last_devices ~= nil and not flocloud_verify_slot(slot) then
    entry.available = false
    flocloud_persist_slots()
    flocloud_log_warn("hello on stale slot " .. tostring(slot) .. "; marked unavailable, notifying the peer")
    flocloud_push_unavailable(slot, entry.valve_id, "valve-unavailable", true)
    return false
  end
  local envelope, err = FloLogicLink.build_identity(entry.valve_id)
  if envelope == nil then
    flocloud_log_warn("identity build failed: " .. tostring(err))
    return false
  end
  flocloud_send_to_slot(slot, envelope)
  flocloud_log("slot " .. tostring(slot) .. " bound to valve " .. tostring(entry.valve_id))
  if st.last_slices[slot] ~= nil then
    flocloud_push_slice(slot, st.last_slices[slot])
  else
    flocloud_poll_soon(1000)
  end
  return true
end

local function flocloud_on_get_state(slot)
  local st = flocloud_state
  local entry = st.slots[slot]
  if entry == nil or not entry.available then
    return false
  end
  if st.last_slices[slot] ~= nil then
    flocloud_push_slice(slot, st.last_slices[slot])
  end
  -- Refresh is an explicit freshness request: serve the cache now, but
  -- also hurry one coalesced cloud poll so the reply converges instead
  -- of replaying the same snapshot forever. Rate-limited across slots;
  -- the poll fans its slices out to every bound slot when it lands.
  local now = os.time()
  if st.refresh_poll_at == nil or now - st.refresh_poll_at >= FLOCLOUD_REFRESH_POLL_MIN_S then
    st.refresh_poll_at = now
    flocloud_poll_soon(1000)
  end
  return true
end

local function flocloud_on_command(slot, env)
  local st = flocloud_state
  local entry = st.slots[slot]
  if entry == nil then
    flocloud_log_warn("command on unmapped slot " .. tostring(slot) .. "; dropped")
    return false
  end
  if not entry.available then
    flocloud_nack(slot, env.cmd_id, "valve-unavailable")
    return false
  end
  if st.last_devices == nil then
    -- Restored map, not yet verified against the account: never execute
    -- a physical write from it. Hurry the verifying poll along.
    flocloud_poll_soon(1000)
    flocloud_nack(slot, env.cmd_id, "verifying")
    return false
  end
  if not flocloud_verify_slot(slot) then
    flocloud_nack(slot, env.cmd_id, "valve-unavailable")
    return false
  end
  local fields, ferr = flocloud_action_fields(env.fields)
  if fields == nil then
    flocloud_nack(slot, env.cmd_id, ferr)
    return false
  end
  -- One breaker policy at session admission: polls and commands share
  -- it. During cooldown commands are rejected with explicit status, not
  -- queued — the cooldown outlasts the transmit deadline, so a held job
  -- could never transmit anyway. Polls are the only recovery probes.
  if flocloud_breaker_open() then
    flocloud_nack(slot, env.cmd_id, "cooling-down")
    return false
  end
  if #st.command_queue >= FLOCLOUD_QUEUE_MAX then
    flocloud_nack(slot, env.cmd_id, "queue-full")
    return false
  end
  -- The job carries the authorization it was admitted under: the exact
  -- immutable identity, the account/endpoint scope, and the absolute
  -- transmit deadline. Admission alone never authorizes the write —
  -- dequeue revalidates the slot, quarantine purges the queue, and the
  -- command session compares its own freshly fetched row before the
  -- irreversible request.
  local now = os.time()
  st.command_queue[#st.command_queue + 1] = {
    cmd_id = env.cmd_id,
    slot = slot,
    valve_id = entry.valve_id,
    expected_uuid = entry.uuid,
    scope = flocloud_config_scope(),
    name = env.fields.action,
    fields = fields,
    enqueued_at = now,
    deadline_at = now + FLOCLOUD_COMMAND_DEADLINE_S,
  }
  -- Pending liveness is namespaced per slot: valve cmd_ids are only
  -- unique per valve ("v<seq>-<time>"), so two valves commanding in the
  -- same second would collide on a bare id and swallow an ack/nack.
  local slot_pending = st.pending_commands[slot]
  if slot_pending == nil then
    slot_pending = {}
    st.pending_commands[slot] = slot_pending
  end
  slot_pending[env.cmd_id] = true
  flocloud_set_prop("Last Command", env.fields.action .. ": queued")
  flocloud_run_next()
  return true
end

-- Shared link ingress for both transports. Returns true when a well-formed
-- valve->cloud message was handled.
function flocloud_handle_link(slot, strCommand, params)
  local env, err = FloLogicLink.parse(params)
  if env == nil then
    flocloud_log_warn("link parse on slot " .. tostring(slot) .. ": " .. tostring(err))
    return false
  end
  if not FloLogicLink.is_valve_to_cloud(env.msg) then
    flocloud_log_warn("misrouted link message on slot " .. tostring(slot) .. ": " .. tostring(env.msg))
    return false
  end
  flocloud_log("link " .. env.msg .. " on slot " .. tostring(slot) .. " (" .. tostring(strCommand) .. ")")
  if env.msg == FloLogicLink.MSG_HELLO then
    return flocloud_on_hello(slot)
  elseif env.msg == FloLogicLink.MSG_GET_STATE then
    return flocloud_on_get_state(slot)
  elseif env.msg == FloLogicLink.MSG_COMMAND then
    return flocloud_on_command(slot, env)
  end
  return false
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  if flocloud_state.slots[idBinding] == nil then
    return
  end
  flocloud_handle_link(idBinding, strCommand, tParams or {})
end

function OnBindingChanged(idBinding, strClass, bIsBound)
  local st = flocloud_state
  local entry = st.slots[idBinding]
  if entry == nil then
    return
  end
  st.slots[idBinding].bound = bIsBound and true or false
  flocloud_log("slot " .. tostring(idBinding) .. " bound=" .. tostring(bIsBound))
  if not bIsBound then
    -- The valve already dropped its side; silently retire ours. Queued
    -- jobs for the slot are dropped (no valve awaits them) and its
    -- pending entries are cleared so late completions skip their acks
    -- instead of paging a dead slot.
    local queue = {}
    for _, job in ipairs(st.command_queue) do
      if job.slot ~= idBinding then
        queue[#queue + 1] = job
      end
    end
    st.command_queue = queue
    st.pending_commands[idBinding] = nil
  end
end

-- --- Account fetch: one login fans out to every valve -----------------------
-- The monolith's public fetch_snapshot is single-valve oriented, which would
-- mean one login per valve per poll. The coordinator instead opens one
-- session and takes the authoritative inventory; it deliberately skips the
-- RequestUserAccesses round-trip (see below), so every poll costs one cloud
-- event.

-- Settle-time token maintenance for real sessions, success or failure:
-- harvest any rotation FIRST (login may have refreshed the token before
-- a later step failed), then drop the persisted token when the hub
-- rejected our credentials — a stale relog token must never wedge every
-- future negotiate. "auth" only fires before any refresh, so the drop
-- can never discard a token this session just earned. The next session
-- (normal update cycle) exercises whatever remains.
function flocloud_harvest_relog(session)
  local st = flocloud_state
  if
    session ~= nil
    and session.relog_token ~= nil
    and session.relog_token ~= ""
    and session.relog_token ~= st.relog_token
  then
    st.relog_token = session.relog_token
    C4:PersistSetValue(FLOCLOUD_PERSIST_RELOG, session.relog_token, true)
    flocloud_log("relog token refreshed")
  end
end

function flocloud_drop_relog()
  local st = flocloud_state
  if st.relog_token ~= "" then
    st.relog_token = ""
    C4:PersistSetValue(FLOCLOUD_PERSIST_RELOG, "", true)
    flocloud_log("relog token dropped after auth failure; next session logs in fully")
  end
end

function flocloud_note_session_end(session, err)
  flocloud_harvest_relog(session)
  if err == "auth" then
    flocloud_drop_relog()
  end
end

local function flocloud_real_fetch_account(hub_url, cb)
  local st = flocloud_state
  local session = flocloud_new_session()
  st.session = session
  local settled = false
  local function done(err, account)
    -- Fenced on session identity like c4/src/main.lua: property changes and
    -- destroy clear st.session first, so a late cloud reply settles nothing.
    if settled or st.session ~= session then
      return
    end
    settled = true
    flocloud_note_session_end(session, err)
    st.session = nil
    st.busy, st.busy_since, st.busy_what, st.busy_job = false, nil, nil, nil
    session.cancel()
    cb(err, account)
  end
  session._connect(hub_url, function(user, devices)
    if st.session ~= session then
      return
    end
    -- No RequestUserAccesses round-trip: nothing downstream reads the
    -- access rows (the valve ignores slice.access, and warning /
    -- critical / water-off all derive from mode flags exactly as the
    -- monolith computed them). Skipping it keeps every poll to one
    -- cloud event instead of stalling on a second 30s waiter for data
    -- nobody consumes. The slice/link `access` field stays reserved.
    done(nil, { user = user, devices = devices, accesses = {} })
  end, function(err)
    done(err)
  end)
end

local function flocloud_fetch_account(hub_url, cb)
  if flocloud_account_fetch ~= nil then
    flocloud_account_fetch(hub_url, cb)
    return
  end
  flocloud_real_fetch_account(hub_url, cb)
end

local function flocloud_access_for(accesses, valve)
  if type(accesses) ~= "table" then
    return nil
  end
  for _, row in ipairs(accesses) do
    if type(row) == "table" and row.valveId == valve.id then
      return row
    end
  end
  return nil
end

-- --- Circuit breaker --------------------------------------------------------
-- Consecutive session failures open the breaker for a cooldown so a dead
-- cloud or bad credentials never hot-loop logins. One success closes it.
-- Logical command rejections (unknown valve, rejected write) are caller
-- bugs, not cloud health, and never feed the breaker.

local function flocloud_is_logical_error(err)
  return err == "valve-not-found"
    or err == "select-valve"
    or err == "command-rejected"
    or err == "reserved-command-field"
    or err == "identity-changed"
end

function flocloud_breaker_open(now)
  return flocloud_state.cb_open_until > (now or os.time())
end

function flocloud_note_result(ok, err, now)
  local st = flocloud_state
  now = now or os.time()
  if ok then
    st.cb_failures = 0
    st.cb_open_until = 0
    return
  end
  if flocloud_is_logical_error(err) then
    return
  end
  st.cb_failures = st.cb_failures + 1
  if st.cb_failures >= FLOCLOUD_CB_FAILURES and st.cb_open_until <= now then
    st.cb_open_until = now + FLOCLOUD_CB_COOLDOWN_S
    flocloud_log_warn(
      "circuit breaker open after " .. st.cb_failures .. " failures; cooling down " .. FLOCLOUD_CB_COOLDOWN_S .. "s"
    )
  end
end

local function flocloud_fire(name)
  flocloud_log("event: " .. name)
  C4:FireEvent(name)
end

local function flocloud_set_connection(ok, detail)
  local st = flocloud_state
  if ok then
    flocloud_set_prop(FLOCLOUD_PROP_CONNECTION, "Online")
  else
    flocloud_set_prop(FLOCLOUD_PROP_CONNECTION, "Offline: " .. tostring(detail or "error"))
  end
  if st.last_connection_ok ~= nil and st.last_connection_ok ~= ok then
    if ok then
      flocloud_fire(FLOCLOUD_EV_CONN_RESTORED)
    else
      flocloud_fire(FLOCLOUD_EV_CONN_LOST)
    end
  end
  st.last_connection_ok = ok
end

local function flocloud_describe_error(err)
  err = tostring(err or "error")
  if err == "auth" then
    return "authentication failed"
  end
  if err == "valve-not-found" then
    return "valve not on account"
  end
  if err == "command-rejected" then
    return "cloud rejected the command"
  end
  return err
end

local function flocloud_on_account(account, session)
  local st = flocloud_state
  st.last_devices = account.devices
  -- Real sessions already harvested at settle (idempotent); this covers
  -- any adapter that hands a live session through the account instead.
  flocloud_harvest_relog(session)
  flocloud_reconcile_inventory(account.devices)
  local valves = FloModel.controllable_valves(account.devices)
  local slices = {}
  for _, slot in ipairs(flocloud_sorted_slots()) do
    local entry = st.slots[slot]
    if entry.available and entry.bound ~= false then
      local valve = FloModel.find_valve(valves, entry.valve_id)
      if valve ~= nil then
        local slice, serr = flocloud_build_slice(valve, flocloud_access_for(account.accesses, valve))
        if slice ~= nil then
          slices[slot] = slice
        else
          flocloud_log_warn("slot " .. tostring(slot) .. " slice skipped: " .. tostring(serr))
        end
      end
    end
  end
  flocloud_fanout(slices)
  flocloud_note_result(true)
  flocloud_set_connection(true)
  flocloud_set_prop("Last Update", os.date("%Y-%m-%d %H:%M:%S"))
end

local function flocloud_on_session_error(where, err)
  flocloud_log_warn(where .. " failed: " .. tostring(err))
  flocloud_note_result(false, err)
  if flocloud_breaker_open() then
    local retry_in = flocloud_state.cb_open_until - os.time()
    if retry_in < 0 then
      retry_in = 0
    end
    flocloud_set_connection(false, "backing off after repeated failures (retry in " .. retry_in .. "s)")
  else
    flocloud_set_connection(false, flocloud_describe_error(err))
  end
end

-- --- Poll and command engines (one session at a time) -----------------------
-- Adapted from c4/src/main.lua (attribution): polls drain first, valve
-- commands queue behind a running poll, and every callback is fenced
-- against retired sessions.

local function flocloud_real_send(job, cb)
  local st = flocloud_state
  local session = flocloud_new_session()
  st.session = session
  -- The session fetches its own inventory and selects by numeric id, so
  -- it re-checks the job's expected identity against that fresh row and
  -- enforces the absolute transmit deadline immediately before the
  -- irreversible request. A replaced valve can therefore never receive
  -- another valve's queued write, however stale the poll inventory is.
  session.send_command(flocloud_hub_url(), job.valve_id, job.fields, function(err)
    if st.session ~= session then
      return
    end
    flocloud_note_session_end(session, err)
    st.session = nil
    st.busy, st.busy_since, st.busy_what, st.busy_job = false, nil, nil, nil
    session.cancel()
    cb(err)
  end, { expected_uuid = job.expected_uuid, deadline = job.deadline_at })
end

-- A queued job is live only while its slot still maps the same valve
-- under the same scope AND fresh inventory still verifies it. Quarantine
-- purges eagerly, but this dequeue check closes every path that admits
-- first and changes second (including the overdue-poll path, which runs
-- between two commands). Returns true, or false plus the nack reason.
local function flocloud_job_live(job)
  local entry = flocloud_state.slots[job.slot]
  if entry == nil or not entry.available or entry.valve_id ~= job.valve_id then
    return false, "valve-unavailable"
  end
  if job.scope ~= nil and job.scope ~= flocloud_config_scope() then
    return false, "identity-changed"
  end
  if not flocloud_verify_slot(job.slot) then
    return false, "identity-changed"
  end
  return true
end

local function flocloud_drop_job(job, reason, detail)
  local st = flocloud_state
  local slot_pending = st.pending_commands[job.slot]
  if slot_pending ~= nil then
    slot_pending[job.cmd_id] = nil
  end
  flocloud_set_prop("Last Command", job.name .. ": " .. detail)
  flocloud_nack(job.slot, job.cmd_id, reason)
end

-- Accepted/queued/sent/outcome: a job is accepted at ingress, queued with
-- an enqueue stamp, transmitted at most once (never replayed), and
-- settled with exactly one ack/nack. Jobs older than the transmit
-- deadline are NACKed "expired" instead of executing: an old Open
-- running minutes later is a different command than the valve asked
-- for. Dequeue revalidates the slot authorization (a poll may have
-- quarantined it while the job waited), and polls that came due while
-- a session ran go first, so command batches can never starve
-- reconciliation.
function flocloud_run_next()
  local st = flocloud_state
  if st.busy or not st.initialized then
    return
  end
  if st.poll_overdue then
    st.poll_overdue = false
    flocloud_poll_now()
    if st.busy then
      return
    end
    -- Poll refused (breaker, unconfigured): fall through so one bad poll
    -- state never wedges the command queue.
  end
  if flocloud_breaker_open() then
    -- Jobs queued before the breaker opened fail fast with explicit
    -- status instead of transmitting into a known-bad cloud. They are
    -- NOT held for recovery: the cooldown outlasts the transmit
    -- deadline, so every held job would expire first anyway.
    for _, job in ipairs(st.command_queue) do
      local slot_pending = st.pending_commands[job.slot]
      if slot_pending ~= nil then
        slot_pending[job.cmd_id] = nil
      end
      flocloud_nack(job.slot, job.cmd_id, "cooling-down")
    end
    if #st.command_queue > 0 then
      flocloud_set_prop("Last Command", "Queued commands dropped: cooling down")
    end
    st.command_queue = {}
    return
  end
  local job = table.remove(st.command_queue, 1)
  while job ~= nil do
    if os.time() - (job.enqueued_at or 0) >= FLOCLOUD_COMMAND_DEADLINE_S then
      flocloud_log_warn(
        "command "
          .. tostring(job.name)
          .. " expired after "
          .. tostring(os.time() - (job.enqueued_at or 0))
          .. "s queued; nacked, never transmitted"
      )
      flocloud_drop_job(job, "expired", "expired before transmit")
    else
      local live, dead_reason = flocloud_job_live(job)
      if live then
        break
      end
      flocloud_log_warn(
        "command " .. tostring(job.name) .. " dropped at dequeue: slot authorization dead (" .. dead_reason .. ")"
      )
      flocloud_drop_job(job, dead_reason, "dropped (" .. dead_reason .. ")")
    end
    job = table.remove(st.command_queue, 1)
  end
  if job == nil then
    return
  end
  st.busy = true
  st.busy_since = os.time()
  st.busy_what = "command:" .. tostring(job.name)
  st.busy_job = job
  local function settled(err)
    local slot_pending = st.pending_commands[job.slot]
    if slot_pending == nil or slot_pending[job.cmd_id] == nil then
      -- Fenced-out late settle (watchdog or cancel already nacked this
      -- job): never release another owner's claim. Reclaim only when we
      -- still own busy or nobody does (watchdog refused its fresh poll,
      -- post-cancel idle), so the queue still drains in those cases.
      if st.busy_job == job or not st.busy then
        st.busy, st.busy_since, st.busy_what, st.busy_job = false, nil, nil, nil
        flocloud_run_next()
      end
      return
    end
    slot_pending[job.cmd_id] = nil
    st.busy, st.busy_since, st.busy_what, st.busy_job = false, nil, nil, nil
    if err ~= nil then
      flocloud_set_prop("Last Command", job.name .. ": failed (" .. flocloud_describe_error(err) .. ")")
      flocloud_nack(job.slot, job.cmd_id, flocloud_describe_error(err))
      flocloud_note_result(false, err)
      -- Converge the tile even when confirmation failed: the hub may have
      -- applied the change without confirming it (slow/offline valve), in
      -- which case the refresh shows the true state within seconds instead
      -- of at the next poll. Poll_now honors the breaker, so a genuinely
      -- dead session does not spin here.
      flocloud_poll_soon(5000)
    else
      flocloud_log("command " .. job.name .. " ok; refreshing")
      flocloud_set_prop("Last Command", job.name .. ": acknowledged; awaiting refresh")
      flocloud_ack(job.slot, job.cmd_id)
      flocloud_note_result(true)
      flocloud_poll_soon(5000)
    end
    flocloud_run_next()
  end
  if flocloud_command_send ~= nil then
    local ok, send_err = pcall(flocloud_command_send, job, settled)
    if not ok then
      settled(send_err or "ws:adapter-error")
    end
    return
  end
  local ok, send_err = pcall(flocloud_real_send, job, settled)
  if not ok then
    settled(send_err or "ws:adapter-error")
  end
end

function flocloud_poll_soon(delay_ms)
  local st = flocloud_state
  if not st.initialized then
    return
  end
  if st.soon_timer then
    st.soon_timer:Cancel()
  end
  st.soon_timer = flocloud_set_timer(delay_ms or 1000, function(t)
    t:Cancel()
    st.soon_timer = nil
    flocloud_poll_now()
  end, false)
end

function flocloud_poll_now()
  local st = flocloud_state
  if not st.initialized then
    flocloud_log("poll skipped: driver not ready")
    return
  end
  if st.busy then
    local age = os.time() - (st.busy_since or os.time())
    if age < 0 then
      age = 0
    end
    if age < FLOCLOUD_BUSY_WATCHDOG_S then
      -- A session is running: remember the due poll so the next run_next
      -- executes it before further commands instead of dropping
      -- reconciliation until the next interval.
      st.poll_overdue = true
      flocloud_log(
        "poll skipped: session busy (" .. tostring(st.busy_what or "session") .. " " .. tostring(age) .. "s)"
      )
      return
    end
    -- Watchdog: the owning session never settled (a hung transport calls
    -- back never). Force-clear and fall through to a fresh poll — every
    -- session callback is fenced on session identity and poll generation,
    -- so the orphan's late reply settles nothing. An orphaned command job
    -- is nacked so the companion learns the outcome instead of timing out.
    flocloud_log_warn(
      "busy watchdog: " .. tostring(st.busy_what or "session") .. " stuck " .. tostring(age) .. "s; forcing clear"
    )
    local orphan = st.session
    st.session = nil
    st.busy = false
    st.busy_since = nil
    st.busy_what = nil
    st.poll_seq = (st.poll_seq or 0) + 1
    if orphan ~= nil then
      pcall(function()
        orphan.cancel()
      end)
    end
    local orphan_job = st.busy_job
    st.busy_job = nil
    if orphan_job ~= nil then
      flocloud_drop_job(orphan_job, "stuck", "stuck session cleared by watchdog")
    end
  end
  if flocloud_breaker_open() then
    local retry_in = st.cb_open_until - os.time()
    if retry_in < 0 then
      retry_in = 0
    end
    flocloud_set_connection(false, "backing off after repeated failures (retry in " .. retry_in .. "s)")
    return
  end
  if flocloud_prop(FLOCLOUD_PROP_EMAIL) == "" or flocloud_prop(FLOCLOUD_PROP_PASSWORD) == "" then
    flocloud_set_prop(FLOCLOUD_PROP_CONNECTION, "Not configured")
    return
  end
  if st.sha1_probe == nil then
    flocloud_set_connection(false, "no SHA1 digest available")
    return
  end
  -- This poll IS any overdue poll: consume the flag at claim time (not in
  -- the watchdog above) so breaker/config/sha1 refusals preserve the debt
  -- exactly as before, while a poll that actually starts never completes
  -- into an immediate duplicate through run_next.
  st.poll_overdue = false
  st.busy = true
  st.busy_since = os.time()
  st.busy_what = "poll"
  st.busy_job = nil
  st.poll_seq = (st.poll_seq or 0) + 1
  local seq = st.poll_seq
  -- Scripted seams call back without clearing session state, so the wrapper
  -- fences on state identity, initialization, and poll generation instead of
  -- on busy/session flags the real transport already settled.
  local function on_fetch(err, account)
    if flocloud_state ~= st or not st.initialized or st.poll_seq ~= seq then
      return
    end
    st.busy, st.busy_since, st.busy_what, st.busy_job = false, nil, nil, nil
    if err ~= nil then
      flocloud_on_session_error("poll", err)
    else
      flocloud_on_account(account, st.session)
    end
    flocloud_run_next()
  end
  local ok, ferr = pcall(flocloud_fetch_account, flocloud_hub_url(), on_fetch)
  if not ok then
    on_fetch(ferr or "ws:adapter-error")
  end
end

local function flocloud_poll_interval_ms()
  return flocloud_poll_interval_s() * 1000
end

local function flocloud_restart_poll_timer()
  local st = flocloud_state
  if st.poll_timer ~= nil then
    st.poll_timer:Cancel()
    st.poll_timer = nil
  end
  st.poll_timer = flocloud_set_timer(flocloud_poll_interval_ms(), function()
    flocloud_poll_now()
  end, true)
end

local function flocloud_restart_reconcile_timer()
  local st = flocloud_state
  if st.reconcile_timer ~= nil then
    st.reconcile_timer:Cancel()
    st.reconcile_timer = nil
  end
  st.reconcile_timer = flocloud_set_timer(FLOCLOUD_RECONCILE_MS, function()
    flocloud_reconcile_bindings()
  end, true)
end

-- Attribute a hintless fallback message by elimination over the live
-- bound-consumer relationship: when exactly one mapped slot has exactly
-- one bound consumer — verified live on every mapped slot, with any
-- indeterminate lookup disqualifying — the sender can only be that
-- consumer. This bootstraps single-valve installations whose proxy leg
-- is broken; anything ambiguous still drops (multi-valve fallback
-- needs one successful proxy handshake first, after which hints flow).
function flocloud_attribute_hintless()
  local found = nil
  local count = 0
  for _, slot in ipairs(flocloud_sorted_slots()) do
    local consumers = flocloud_bound_consumers(slot)
    if consumers == nil then
      return nil
    end
    if #consumers > 0 then
      count = count + #consumers
      found = slot
    end
  end
  if count == 1 then
    return found
  end
  return nil
end

-- --- Commands (Director programming + SendToDevice fallback) -----------------

function ExecuteCommand(strCommand, tParams)
  if strCommand == "LUA_ACTION" then
    strCommand = tParams and tParams.ACTION
  end
  if strCommand == "Refresh GitHub Updates" then
    strCommand = "Check for Update"
  end
  flocloud_log("command: " .. tostring(strCommand))
  if strCommand == "Check for Update" then
    flocloud_check_update()
    return
  elseif strCommand == "Install Latest Release" then
    flocloud_install_update(false)
    return
  elseif strCommand == "Force Reinstall Latest Release" then
    flocloud_install_update(true)
    return
  elseif strCommand == "Refresh" then
    flocloud_poll_now()
    return
  elseif strCommand == "Refresh Valve List" then
    flocloud_reconcile_bindings()
    flocloud_poll_now() -- discovery reconciles bindings from every snapshot
    return
  end
  -- SendToDevice fallback arrival (plan D1): ExecuteCommand names no sender,
  -- so the valve attaches the valve id from its LIVE handshake as an
  -- additive FLOGIC_FROM hint (ignored by FloLogicLink.parse). The valve
  -- never attaches a stale (pre-rebind) id that would misroute to the
  -- old slot — so a first fallback hello arrives hintless, and the
  -- proxy hello burst is the bootstrap when attribution below fails.
  if type(tParams) == "table" and type(tParams[FloLogicLink.K_MSG]) == "string" then
    local from = flocloud_normalize_id(tParams[FLOCLOUD_K_FROM])
    local slot = from ~= nil and flocloud_state.valve_slots[from] or nil
    if slot == nil then
      slot = flocloud_attribute_hintless()
    end
    if slot ~= nil then
      flocloud_handle_link(slot, strCommand, tParams)
    else
      flocloud_log_warn("fallback link message without a known sender; dropped")
    end
    return
  end
  flocloud_log_warn("unknown command: " .. tostring(strCommand))
end

-- --- Lifecycle ---------------------------------------------------------------

local function flocloud_restore_relog()
  local saved = C4:PersistGetValue(FLOCLOUD_PERSIST_RELOG)
  if type(saved) == "string" then
    flocloud_state.relog_token = saved
  end
end

function OnDriverInit(driver_init_type)
  -- Publish the running version even if Composer already shows the XML default.
  C4:UpdateProperty("Driver Version", FLOCLOUD_DRIVER_VERSION)
  print("[flologic-cloud] OnDriverInit: " .. FLOCLOUD_DRIVER_VERSION .. " (" .. tostring(driver_init_type) .. ")")
  flocloud_restore_relog()
end

local function flocloud_log_version_transition()
  local previous = C4:PersistGetValue(FLOCLOUD_PERSIST_VERSION)
  if previous == FLOCLOUD_DRIVER_VERSION then
    return
  end
  if previous == nil or previous == "" then
    print("[flologic-cloud] First run on this controller: " .. FLOCLOUD_DRIVER_VERSION)
  else
    print("[flologic-cloud] Driver version changed: " .. tostring(previous) .. " -> " .. FLOCLOUD_DRIVER_VERSION)
  end
  C4:PersistSetValue(FLOCLOUD_PERSIST_VERSION, FLOCLOUD_DRIVER_VERSION)
end

function OnDriverLateInit(driver_init_type)
  print("[flologic-cloud] OnDriverLateInit: " .. FLOCLOUD_DRIVER_VERSION .. " (" .. tostring(driver_init_type) .. ")")
  flocloud_retire_runtime()
  flocloud_state = flocloud_fresh_state()
  -- Link epoch: strictly increasing across restarts (persisted), so a
  -- companion never compares a new boot's per-slot sequences against
  -- the previous boot's numbering. PersistGetValue answers a missing
  -- key with ZERO values (not nil), and a zero-value call nested in
  -- argument position invokes tonumber() with no arguments, which
  -- raises — so capture into a local (zero values land as nil) before
  -- converting, or first boot crashes before initializing.
  local saved_epoch_raw = C4:PersistGetValue(FLOCLOUD_PERSIST_EPOCH)
  local saved_epoch = tonumber(saved_epoch_raw) or 0
  flocloud_state.link_epoch = saved_epoch + 1
  C4:PersistSetValue(FLOCLOUD_PERSIST_EPOCH, tostring(saved_epoch + 1))
  flocloud_restore_relog()
  C4:UpdateProperty("Driver Version", FLOCLOUD_DRIVER_VERSION)
  pcall(flocloud_log_version_transition)
  flocloud_set_prop(FLOCLOUD_PROP_CONNECTION, "Initializing")
  flocloud_restore_slots()
  for _, key in ipairs({ "device_code", "device_token" }) do
    local saved = C4:PersistGetValue("flocloud_" .. key)
    if type(saved) ~= "string" or saved == "" then
      saved = assert(C4:UUID("RANDOM"))
      C4:PersistSetValue("flocloud_" .. key, saved, true)
    end
    flocloud_state[key] = saved
  end
  flocloud_state.sha1_probe = flocloud_probe_sha1()
  if flocloud_state.sha1_probe == nil then
    flocloud_set_prop(FLOCLOUD_PROP_CONNECTION, "Offline: no SHA1 digest available")
    flocloud_log_warn("no working SHA1 digest; websocket handshake impossible")
    return
  end
  flocloud_state.initialized = true
  OnPropertyChanged(FLOCLOUD_PROP_DEBUG)
  flocloud_restart_poll_timer()
  flocloud_restart_reconcile_timer()
  flocloud_poll_soon(2000)
  flocloud_schedule_update_checks()
  flocloud_state.update_start_timer = flocloud_set_timer(10000, function()
    flocloud_state.update_start_timer = nil
    flocloud_check_update()
  end, false)
  print("[flologic-cloud] Runtime ready: " .. FLOCLOUD_DRIVER_VERSION)
end

local function flocloud_cancel_work()
  local st = flocloud_state
  local session = st.session
  st.session, st.busy = nil, false
  st.busy_since, st.busy_what, st.busy_job = nil, nil, nil
  st.poll_seq = (st.poll_seq or 0) + 1
  if session then
    session.cancel()
  end
  if st.soon_timer then
    st.soon_timer:Cancel()
    st.soon_timer = nil
  end
  -- Nack everything the valves still await: queued jobs plus any
  -- executing job (in pending but already dequeued). Without this the
  -- valves' Last Command labels stick on "sent" forever.
  local nacked = {}
  for _, job in ipairs(st.command_queue) do
    flocloud_nack(job.slot, job.cmd_id, "cancelled")
    nacked[job.slot .. ":" .. job.cmd_id] = true
  end
  for slot, ids in pairs(st.pending_commands) do
    for cmd_id in pairs(ids) do
      if nacked[slot .. ":" .. cmd_id] == nil then
        flocloud_nack(slot, cmd_id, "cancelled")
      end
    end
  end
  if #st.command_queue > 0 then
    flocloud_set_prop("Last Command", "Queued commands cancelled")
  end
  st.command_queue = {}
  st.pending_commands = {}
end

function OnDriverDestroyed(driver_init_type)
  print("[flologic-cloud] OnDriverDestroyed: " .. FLOCLOUD_DRIVER_VERSION .. " (" .. tostring(driver_init_type) .. ")")
  flocloud_retire_runtime()
end

function OnDriverUpdated()
  OnDriverLateInit("OnDriverUpdated")
end

function OnDriverRemovedFromProject()
  OnDriverDestroyed()
end

function OnPropertyChanged(strProperty)
  if not flocloud_state.initialized then
    return
  end
  flocloud_log("property changed: " .. tostring(strProperty))
  if strProperty == FLOCLOUD_PROP_DEBUG then
    if flocloud_state.debug_timer then
      flocloud_state.debug_timer:Cancel()
    end
    if flocloud_prop(FLOCLOUD_PROP_DEBUG) == "On" then
      flocloud_state.debug_timer = flocloud_set_timer(10800000, function()
        flocloud_set_prop(FLOCLOUD_PROP_DEBUG, "Off")
        flocloud_state.debug_timer = nil
      end, false)
    end
  elseif strProperty == FLOCLOUD_PROP_UPDATE_INTERVAL then
    flocloud_schedule_update_checks()
  elseif strProperty == FLOCLOUD_PROP_POLL then
    flocloud_restart_poll_timer()
  elseif
    strProperty == FLOCLOUD_PROP_EMAIL
    or strProperty == FLOCLOUD_PROP_PASSWORD
    or strProperty == FLOCLOUD_PROP_HUB
  then
    -- CLOUD-U6: account-level properties only. There is no picker or
    -- override to reset; discovery rebuilds the slot map on the next poll.
    -- The account or endpoint changed, so every cached authorization and
    -- snapshot is dropped: slots re-verify against the new inventory, and
    -- until then commands fail closed while no stale slice replays.
    flocloud_cancel_work()
    flocloud_state.relog_token = ""
    C4:PersistSetValue(FLOCLOUD_PERSIST_RELOG, "", true)
    -- New credentials or endpoint, new regime: the old failure count is
    -- evidence about the old regime, so the breaker resets explicitly
    -- instead of gating corrected credentials on a stale cooldown.
    flocloud_state.cb_failures = 0
    flocloud_state.cb_open_until = 0
    flocloud_state.last_devices = nil
    flocloud_state.last_slices = {}
    flocloud_set_prop(FLOCLOUD_PROP_CONNECTION, "Refreshing configuration")
    flocloud_poll_soon(1000)
  end
end
