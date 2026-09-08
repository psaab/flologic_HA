-- Director contract tests. No cloud credentials or network access required.
local D = TestHelp
local original_factory = FloLogic.new_session

local function director()
  local timers = D.new_fake_timers()
  local env = {
    timers = timers,
    sessions = {},
    transfers = {},
    events = {},
    contact_notifications = {},
    addresses = {},
    saved = {},
    files = {},
    file_dirs = {},
    file_moves = {},
    dir_attempts = {},
    files_denied = false,
    installed = {},
    soap_packets = {},
  }
  Properties = { Email = "test@example.invalid", Password = "test", ["Select Valve"] = "Kitchen (11)" }
  flogic_state = { command_queue = {}, retired_bindings = {}, relog_token = "" }
  C4 = {}
  function C4:UpdateProperty(name, value)
    Properties[name] = value
  end
  function C4:UpdatePropertyList(name, list, value)
    env.list = list
    Properties[name] = value
  end
  function C4:SendToProxy(binding, command, params, kind)
    env.contact_notifications[#env.contact_notifications + 1] = { binding = binding, command = command, kind = kind }
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
    return D.sha1(value)
  end
  function C4:Base64Encode(value)
    return D.b64encode(value)
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
  function C4:GetBindingAddress(id)
    return env.addresses[id]
  end
  function C4:SetBindingAddress(id, value)
    env.addresses[id] = value
  end
  function C4:CreateNetworkConnection(id, host, protocol)
    env.addresses[id], env.protocol = host, protocol
  end
  function C4:NetPortOptions(_, _, protocol, options)
    env.tls, env.tls_protocol = options, protocol
  end
  function C4:NetConnect(id, port)
    env.binding, env.port = id, port
    if env.addresses[id] == "127.0.0.1" then
      OnConnectionStatusChanged(id, port, "ONLINE")
    elseif env.server then
      env.socket = env.server.tcp_open(env.addresses[id], port, {
        on_open = function()
          OnConnectionStatusChanged(id, port, "ONLINE")
        end,
        on_data = function(bytes)
          ReceivedFromNetwork(id, port, bytes)
        end,
        on_close = function()
          OnConnectionStatusChanged(id, port, "OFFLINE")
        end,
      })
    end
  end
  function C4:SendToNetwork(id, _, bytes)
    if env.addresses[id] == "127.0.0.1" then
      env.soap_packets[#env.soap_packets + 1] = bytes
      ReceivedFromNetwork(id, env.port, "<c4soap></c4soap>")
      return
    end
    env.socket.send(bytes)
  end
  function C4:NetDisconnect(id, port)
    if env.socket and env.addresses[id] ~= "127.0.0.1" then
      env.socket.close()
    end
    OnConnectionStatusChanged(id, port, "OFFLINE")
  end
  function C4:FileSetDir(alias)
    env.dir_attempts[#env.dir_attempts + 1] = alias
    if env.files_denied or (env.denied_dirs ~= nil and env.denied_dirs[alias]) then
      error("Restricted path specified")
    end
    env.file_dirs[#env.file_dirs + 1] = alias
  end
  function C4:FileExists(name)
    return env.files[name] ~= nil
  end
  -- Faithful position semantics per the DriverWorks docs: FileOpen
  -- positions at END-of-file (rba mode), reads without a FileSetPos(0)
  -- return "", and writes always append. This fidelity is load-bearing:
  -- the 2026090811 field failure (magic gate reading "") passed the
  -- old position-agnostic mock.
  function C4:FileOpen(name)
    if env.files[name] == nil then
      env.files[name] = ""
    end
    return { name = name, pos = #(env.files[name] or "") }
  end
  function C4:FileSetPos(handle, pos)
    handle.pos = pos
  end
  function C4:FileWrite(handle, length, data)
    env.files[handle.name] = (env.files[handle.name] or "") .. data:sub(1, length)
    handle.pos = #env.files[handle.name]
    return length
  end
  function C4:FileGetSize(handle)
    return #(env.files[handle.name] or "")
  end
  function C4:FileRead(handle, count)
    local data = env.files[handle.name] or ""
    local from = (handle.pos or 0) + 1
    local chunk = data:sub(from, from + count - 1)
    handle.pos = (handle.pos or 0) + #chunk
    return chunk
  end
  function C4:FileClose(_) end
  function C4:FileDelete(name)
    env.files[name] = nil
  end
  function C4:FileMove(_, from_name, _, to_name)
    if env.move_fail then
      error("move denied")
    end
    -- The adapter tries bare then leading-slash paths; the store holds
    -- bare names either way.
    local from = from_name:gsub("^/", "")
    local to = to_name:gsub("^/", "")
    env.file_moves[#env.file_moves + 1] = { from = from_name, to = to_name }
    env.files[to] = env.files[from]
    env.files[from] = nil
  end
  function C4:GetDevicesByC4iName(name)
    return env.installed[name] or {}
  end
  function C4:url()
    local transfer = {}
    function transfer:SetOptions(options)
      self.options = options
    end
    function transfer:OnDone(callback)
      self.done = callback
    end
    function transfer:Cancel()
      self.cancelled = true
    end
    function transfer:Get(url, headers)
      self.url, self.headers = url, headers
    end
    function transfer:Post(url, body, headers)
      self.url, self.headers = url, headers
      if env.server then
        env.server.http_post(url, body, headers, function(err, data, code)
          self.done(self, { { code = code, body = data } }, err and 1 or 0, err)
        end)
      end
    end
    env.transfers[#env.transfers + 1] = transfer
    return transfer
  end
  FloLogic.new_session = original_factory
  OnDriverInit()
  OnDriverLateInit()
  return env
end

local function stub_sessions(env)
  FloLogic.new_session = function()
    local session = {}
    env.sessions[#env.sessions + 1] = session
    function session.cancel()
      session.cancelled = true
    end
    function session.fetch_snapshot(_, selected, cb)
      session.selected, session.callback = selected, cb
    end
    function session.send_command(_, selected, fields, cb)
      session.selected, session.fields, session.callback = selected, fields, cb
    end
    return session
  end
end

D.test("director: configuration cancels work and ignores late callbacks", function()
  local env = director()
  stub_sessions(env)
  flogic_poll_now()
  local first = env.sessions[1]
  ExecuteCommand("Set Mode Shutoff", {})
  D.check_equal(flogic_state.command_queue[1].selected, "11", "queue pins valve")
  Properties["Select Valve"] = "Garden (22)"
  OnPropertyChanged("Select Valve")
  D.check(first.cancelled, "active session cancelled")
  D.check_equal(#flogic_state.command_queue, 0, "queue cancelled")
  flogic_poll_now()
  first.callback("old failure")
  D.check(flogic_state.busy, "old callback cannot release new session")
  D.check_equal(env.sessions[2].selected, "22", "new session uses new valve")
  OnDriverDestroyed()
  D.check_equal(env.timers.pending_count(), 0, "destroy cancels every timer")
  env.sessions[2].callback("late failure")
  D.check_equal(#env.events, 0, "destroyed driver emits no events")
end)

D.test("director: picker preserves identity and never selects another site", function()
  local env = director()
  stub_sessions(env)
  Properties["Select Valve"] = ""
  flogic_poll_now()
  env.sessions[1].callback(nil, { devices = { { id = 11, name = "Kitchen, downstairs", deviceType = "valve" } } })
  D.check_equal(Properties["Select Valve"], "Select a valve", "discovery requires selection")
  ExecuteCommand("Set Mode Shutoff", {})
  D.check_equal(#env.sessions, 1, "unselected command never starts")
  Properties["Select Valve"] = "Kitchen (11)"
  flogic_poll_now()
  env.sessions[2].callback(nil, { devices = { { id = 22, name = "Garden" } } })
  D.check_equal(Properties["Select Valve"], "Unavailable (11)", "missing valve retained")
  OnDriverDestroyed()
end)

D.test("director: queue overflow preserves earlier commands and validates integers", function()
  local env = director()
  stub_sessions(env)
  flogic_poll_now()
  ExecuteCommand("Set Mode Shutoff", {})
  for _ = 1, 8 do
    ExecuteCommand("Set Mode Home", {})
  end
  D.check_equal(#flogic_state.command_queue, 8, "queue bounded")
  D.check_equal(flogic_state.command_queue[1].name, "Set Mode Shutoff", "oldest write preserved")
  flogic_state.command_queue = {}
  ExecuteCommand("Set Home Limit", { Minutes = 0 / 0 })
  ExecuteCommand("Set Home Limit", { Minutes = 1.5 })
  D.check_equal(#flogic_state.command_queue, 0, "nonfinite/fractional commands rejected")
  ExecuteCommand("Set Away Limit", { Minutes = 0.5 })
  ExecuteCommand("Set Flow Sensitivity", { Value = 0.25 })
  D.check_equal(#flogic_state.command_queue, 2, "fractional settings preserved")
  OnDriverDestroyed()
end)

D.test("director: native HTTP errors, cancellation, and startup guard", function()
  local env = director()
  flogic_poll_now()
  local request = env.transfers[1]
  D.check(request.options.ssl_verify_peer and request.options.ssl_verify_host, "HTTP verifies TLS")
  request.done(request, {}, 28, "timeout")
  D.check(not flogic_state.busy, "HTTP error completes session")
  D.check(Properties.Connection:find("transport%-28") ~= nil, "transport error surfaced")
  flogic_poll_now()
  local pending = env.transfers[2]
  OnDriverDestroyed()
  D.check(pending.cancelled, "HTTP cancelled on destroy")
  pending.done(pending, { { code = 200, body = '{"connectionToken":"late"}' } }, 0)
  D.check(env.binding == nil, "late HTTP completion opens no socket")
  OnPropertyChanged("Email")
  D.check_equal(env.timers.pending_count(), 0, "property callback cannot restart destroyed driver")
end)

D.test("director: full adapter discovery and verified TLS options", function()
  local env = director()
  Properties["Select Valve"] = ""
  env.server = D.new_fake_server({
    { expect_target = "Login", reply_target = "LoggedIn", reply_args = { { id = 7 } } },
    {
      expect_target = "RefreshValveArray",
      reply_target = "ValveArraySent",
      reply_args = { { { id = 11, name = "Kitchen" } } },
    },
  })
  flogic_poll_now()
  D.check_equal(Properties.Connection, "Select a valve", "adapter completes discovery")
  D.check_equal(env.tls.VERIFY_MODE, "peer", "raw TLS peer verification")
  D.check_equal(env.tls.CACERTFILE, "./ca-bundle.pem", "packaged trust store")
  D.check_equal(env.tls_protocol, "SSL", "documented socket protocol")
  D.check(not flogic_state.busy, "completion releases busy flag")
  D.check(env.server._tcp_closed, "socket closed")
  OnDriverDestroyed()
  D.check_equal(env.timers.pending_count(), 0, "no timer leaks")
end)

D.test("director: port mismatch and obsolete binding cannot affect active session", function()
  local env = director()
  flogic_poll_now()
  env.transfers[1].done(nil, { { code = 200, body = '{"connectionToken":"token"}' } }, 0)
  OnConnectionStatusChanged(env.binding, env.port + 1, "OFFLINE")
  ReceivedFromNetwork(env.binding + 1, env.port, "irrelevant")
  D.check(flogic_state.busy, "unrelated network callbacks ignored")
  OnDriverDestroyed()
end)

FloLogic.new_session = original_factory

D.test("director: Composer actions dispatch and offline snapshots stop local ticks", function()
  local env = director()
  stub_sessions(env)
  ExecuteCommand("LUA_ACTION", { ACTION = "Refresh" })
  D.check_equal(#env.sessions, 1, "Composer action starts refresh")
  local valve = {
    id = 11,
    online = true,
    flowState = 2,
    mode = 1,
    lastNewFlow = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    homeIntervalTime = 30,
  }
  env.sessions[1].callback(nil, { valve = valve, devices = { valve }, scheduler = {}, notifications = {} })
  D.check(flogic_state.tick_timer ~= nil, "flow starts local timer")
  flogic_poll_now()
  env.sessions[2].callback("offline")
  D.check(flogic_state.tick_timer == nil and flogic_state.last_snapshot == nil, "offline clears ticking snapshot")
  local event_count = #env.events
  env.timers.advance(5000)
  D.check_equal(#env.events, event_count, "stale sample generates no valve events")
  OnDriverDestroyed()
end)

D.test("director: changing accounts discards old target and relog credentials", function()
  local env = director()
  flogic_state.relog_token = "old-account-token"
  Properties["Valve ID Override"] = "old-valve"
  Properties.Email = "new@example.invalid"
  OnPropertyChanged("Email")
  D.check_equal(flogic_state.relog_token, "", "account token cleared")
  D.check_equal(env.saved.flologic_relog, "", "persisted token cleared")
  D.check_equal(Properties["Valve ID Override"], "", "override cleared")
  D.check_equal(Properties["Select Valve"], "Select a valve", "new account requires explicit selection")
  OnDriverDestroyed()
end)

D.test("director: repeated update callbacks retire work and preserve configuration", function()
  local env = director()
  local code = flogic_state.device_code
  local old_state = flogic_state
  local old_tick = env.timers._pending[1].fn
  flogic_poll_now()
  local request = env.transfers[1]
  OnDriverUpdated()
  D.check(request.cancelled, "update cancels old transfer")
  D.check(flogic_state ~= old_state and not old_state.initialized, "fresh runtime")
  D.check_equal(flogic_state.device_code, code, "persistent identity kept")
  D.check_equal(Properties["Select Valve"], "Kitchen (11)", "selection kept")
  old_tick()
  request.done(request, { { code = 200, body = '{"connectionToken":"old"}' } }, 0)
  D.check_equal(#env.transfers, 1, "retired callbacks cannot restart networking")
  OnDriverUpdated()
  OnDriverLateInit()
  D.check_equal(env.timers.pending_count(), 4, "one set of poll/update timers")
  OnDriverDestroyed()
  D.check_equal(env.timers.pending_count(), 0, "all timers retired")
end)

D.test("director: Composer DIT_UPDATING reload starts polling without OnDriverUpdated", function()
  local env = director()
  local old_state = flogic_state
  local identity = old_state.device_code
  Properties["Debug Mode"] = "Off"
  flogic_poll_now()
  local old_request = env.transfers[1]
  OnDriverDestroyed("DIT_UPDATING")
  D.check(old_request.cancelled, "Composer destroy cancels outstanding request")
  flogic_test_reload()
  original_factory = FloLogic.new_session
  Properties["Driver Version"] = "old version"
  OnDriverInit("DIT_UPDATING")
  D.check_equal(Properties["Driver Version"], FLOGIC_DRIVER_VERSION, "init stamps running version")
  D.check_equal(env.timers.pending_count(), 0, "init waits for bindings")
  OnDriverLateInit("DIT_UPDATING")
  D.check(flogic_state.initialized and flogic_state ~= old_state, "new runtime initialized")
  D.check_equal(flogic_state.device_code, identity, "device identity survives Composer upgrade")
  D.check_equal(Properties["Select Valve"], "Kitchen (11)", "valve selection preserved")
  D.check_equal(env.timers.pending_count(), 4, "one timer set after Composer upgrade")
  old_request.done(old_request, { { code = 200, body = '{"connectionToken":"stale"}' } }, 0)
  D.check_equal(#env.transfers, 1, "old callback cannot connect")
  env.timers.advance(2000)
  D.check_equal(#env.transfers, 2, "new runtime polls automatically")
  OnDriverDestroyed()
  D.check_equal(env.timers.pending_count(), 0, "new timers cleaned up")
end)

D.test("director: reload replaces modules and fences old binding callbacks", function()
  local env = director()
  local old_modules = { JSON, FloModel, SignalR, WS, FloLogic, FloUpdate }
  local old_callback = OnPropertyChanged
  local old_state = flogic_state
  C4.NetDisconnect = function() end -- Director acknowledges OFFLINE later.
  flogic_poll_now()
  env.transfers[1].done(nil, { { code = 200, body = '{"connectionToken":"first"}' } }, 0)
  local old_binding = env.binding
  flogic_test_reload()
  original_factory = FloLogic.new_session
  local new_modules = { JSON, FloModel, SignalR, WS, FloLogic, FloUpdate }
  for i, module in ipairs(old_modules) do
    D.check(module ~= new_modules[i], "module reference replaced")
  end
  D.check(OnPropertyChanged ~= old_callback, "Director entry point replaced")
  D.check(flogic_state ~= old_state and old_state.session == nil, "old session retired")
  D.check_equal(env.timers.pending_count(), 0, "load cleans before lifecycle callbacks")
  OnDriverUpdated()
  flogic_poll_now()
  env.transfers[2].done(nil, { { code = 200, body = '{"connectionToken":"second"}' } }, 0)
  D.check(env.binding ~= old_binding, "closing binding cannot be reused")
  OnConnectionStatusChanged(old_binding, 443, "OFFLINE")
  D.check(flogic_state.busy, "old disconnect cannot close new connection")
  D.check_equal(env.addresses[old_binding], "", "old binding released on acknowledgement")
  OnDriverDestroyed()
end)

D.test("director: GitHub checks survive busy valve polling and cancel on reload", function()
  local env = director()
  flogic_poll_now()
  ExecuteCommand("LUA_ACTION", { ACTION = "Check for Update" })
  local request = env.transfers[2]
  D.check_equal(request.url, FloUpdate.API_URL, "GitHub repository endpoint")
  D.check(flogic_state.busy, "release check does not release valve session")
  request.done(request, { { code = 200, body = "[]" } }, 0)
  D.check(Properties["Update Status"]:find("No published C4", 1, true) ~= nil, "no release is explicit")
  ExecuteCommand("Check for Update")
  local obsolete = env.transfers[3]
  flogic_test_reload()
  original_factory = FloLogic.new_session
  D.check(obsolete.cancelled, "reload cancels GitHub transfer")
  local before = Properties["Update Status"]
  obsolete.done(obsolete, {}, 28)
  D.check_equal(Properties["Update Status"], before, "retired updater cannot write properties")
  OnDriverUpdated()
  OnDriverDestroyed()
end)

D.test("director: status contacts initialize, transition, and synchronize bindings", function()
  local env = director()
  stub_sessions(env)
  local function snapshot(mode, online)
    flogic_poll_now()
    local valve = { id = 11, online = online ~= false, mode = mode, flowState = 1 }
    env.sessions[#env.sessions].callback(nil, { valve = valve, devices = { valve } })
  end
  snapshot(1)
  local notices = env.contact_notifications
  D.check_equal(#notices, 2, "initialize both connections")
  D.check_equal(notices[1].binding, 101, "stable closed binding")
  D.check_equal(notices[1].command, "STATE_OPENED", "home is open initial state")
  D.check_equal(notices[2].binding, 102, "stable away binding")
  snapshot(1)
  D.check_equal(#notices, 2, "unchanged polls do not fire programming")
  snapshot(2)
  D.check_equal(notices[3].binding, 102, "away changes independently")
  D.check_equal(notices[3].command, "CLOSED", "away is closed")
  snapshot(2 + 32)
  D.check_equal(notices[4].binding, 101, "flow timeout closes water status")
  D.check_equal(notices[4].command, "CLOSED", "flow shutoff asserted")
  D.check_equal(#notices, 4, "away stays asserted during shutoff")
  OnBindingChanged(101, "CONTACT_SENSOR", true)
  D.check_equal(notices[5].command, "STATE_CLOSED", "late binding initializes without edge")
  ReceivedFromProxy(102, "GET_STATE", {})
  D.check_equal(notices[6].command, "STATE_CLOSED", "state query answered")
  ReceivedFromProxy(101, "OPEN", {})
  ReceivedFromProxy(102, "TOGGLE", {})
  D.check_equal(#env.sessions, 4, "status connections never issue cloud commands")
  snapshot(1)
  D.check_equal(notices[7].command, "OPENED", "water restored")
  D.check_equal(notices[8].command, "OPENED", "away cleared")
  OnDriverDestroyed()
end)

D.test("director: offline and selection changes cannot fabricate contact edges", function()
  local env = director()
  stub_sessions(env)
  local function snapshot(mode, online)
    flogic_poll_now()
    local valve = { id = 11, online = online, mode = mode, flowState = 1 }
    env.sessions[#env.sessions].callback(nil, { valve = valve, devices = { valve } })
  end
  snapshot(8, true)
  D.check_equal(env.contact_notifications[1].command, "STATE_CLOSED", "manual shutoff initialized")
  snapshot(1, false)
  ReceivedFromProxy(101, "GET_STATE")
  D.check_equal(#env.contact_notifications, 2, "offline does not claim water restored")
  snapshot(128, true)
  D.check_equal(env.contact_notifications[3].command, "STATE_OPENED", "recovery resynchronizes")
  D.check_equal(env.contact_notifications[4].command, "STATE_CLOSED", "automatic away supported")
  Properties["Valve ID Override"] = "22"
  OnPropertyChanged("Valve ID Override")
  OnBindingChanged(101, "CONTACT_SENSOR", true)
  D.check_equal(#env.contact_notifications, 4, "old selection cannot be replayed")
  OnDriverDestroyed()
end)

D.test("director: GitHub refresh button accepts Composer command and label", function()
  local env = director()
  ExecuteCommand("LUA_ACTION", { ACTION = "Check for Update" })
  env.transfers[1].done(nil, { { code = 200, body = "[]" } }, 0)
  ExecuteCommand("LUA_ACTION", { ACTION = "Refresh GitHub Updates" })
  D.check_equal(#env.transfers, 2, "button label and command refresh GitHub")
  D.check_equal(env.transfers[2].url, FloUpdate.API_URL, "refresh uses GitHub, not cloud poll")
  OnDriverDestroyed()
end)

local function director_release(version)
  local tag = "c4-v" .. version
  return JSON.encode({
    {
      tag_name = tag,
      draft = false,
      prerelease = false,
      assets = {
        {
          name = "flologic_valve.c4z",
          browser_download_url = "https://github.com/psaab/flologic_HA/releases/download/"
            .. tag
            .. "/flologic_valve.c4z",
        },
      },
    },
  })
end

D.test("director: install command stages the package and triggers Composer", function()
  local env = director()
  env.installed["flologic_valve.c4i"] = { [1] = true }
  env.files["flologic_valve.c4z"] = "OLD-DRIVER-BYTES"
  ExecuteCommand("Install Latest Release", {})
  D.check_equal(env.transfers[1].url, FloUpdate.API_URL, "install queries releases first")
  env.transfers[1].done(nil, { { code = 200, body = director_release("2026090808") } }, 0)
  D.check_equal(#env.transfers, 2, "newer release downloads its asset")
  env.transfers[2].done(nil, { { code = 200, body = "PK\003\004NEW-C4Z-BYTES" } }, 0)
  D.check_equal(env.files["flologic_valve.c4z"], "PK\003\004NEW-C4Z-BYTES", "download staged to the file store")
  D.check_equal(#env.soap_packets, 1, "one Composer install trigger")
  D.check_equal(env.soap_packets[1], FloUpdate.build_install_packet("flologic_valve.c4z"), "trigger names the asset")
  D.check(
    Properties["Update Status"]:find("Installation unconfirmed: 2026090808", 1, true) ~= nil,
    "result does not claim a verified installation, got " .. tostring(Properties["Update Status"])
  )
  OnDriverDestroyed()
end)

D.test("director: force reinstall bypasses the version compare", function()
  local env = director()
  -- The package filename is the fallback lookup key when the proxy name misses.
  env.installed["flologic_valve.c4z"] = { [1] = true }
  ExecuteCommand("Force Reinstall Latest Release", {})
  env.transfers[1].done(nil, { { code = 200, body = director_release(FLOGIC_DRIVER_VERSION) } }, 0)
  D.check_equal(#env.transfers, 2, "force downloads the same build")
  env.transfers[2].done(nil, { { code = 200, body = "PK\003\004SAME-C4Z-BYTES" } }, 0)
  D.check_equal(env.files["flologic_valve.c4z"], "PK\003\004SAME-C4Z-BYTES", "same build restaged")
  D.check_equal(#env.soap_packets, 1, "force still triggers Composer")
  OnDriverDestroyed()
end)

D.test("director: denied file store fails loudly and keeps the old driver", function()
  local env = director()
  env.installed["flologic_valve"] = { [1] = true }
  env.files["flologic_valve.c4z"] = "OLD-DRIVER-BYTES"
  env.files_denied = true
  ExecuteCommand("Install Latest Release", {})
  env.transfers[1].done(nil, { { code = 200, body = director_release("2026090808") } }, 0)
  env.transfers[2].done(nil, { { code = 200, body = "PK\003\004NEW-C4Z-BYTES" } }, 0)
  D.check_equal(env.files["flologic_valve.c4z"], "OLD-DRIVER-BYTES", "denial keeps the old build")
  D.check_equal(#env.soap_packets, 0, "denial triggers no install")
  D.check(
    Properties["Update Status"]:find("Install failed", 1, true) ~= nil
      and Properties["Update Status"]:find("Composer", 1, true) ~= nil,
    "denial points at the manual path, got " .. tostring(Properties["Update Status"])
  )
  OnDriverDestroyed()
end)

D.test("director: staging falls back to the documented C4Z alias", function()
  local env = director()
  env.installed["flologic_valve.c4i"] = { [1] = true }
  env.denied_dirs = { C4Z_ROOT = true }
  ExecuteCommand("Install Latest Release", {})
  env.transfers[1].done(nil, { { code = 200, body = director_release("2026090808") } }, 0)
  env.transfers[2].done(nil, { { code = 200, body = "PK\003\004NEW-C4Z-BYTES" } }, 0)
  D.check_equal(env.dir_attempts[1], "C4Z_ROOT", "proflame alias tried first")
  D.check_equal(env.dir_attempts[2], "C4Z", "documented alias tried on denial")
  D.check_equal(env.files["flologic_valve.c4z"], "PK\003\004NEW-C4Z-BYTES", "staging completes via fallback")
  D.check_equal(#env.soap_packets, 1, "install triggers after fallback staging")
  OnDriverDestroyed()
end)

D.test("director: install without a store entry reports not-installed", function()
  local env = director()
  ExecuteCommand("Install Latest Release", {})
  D.check_equal(#env.transfers, 0, "no GitHub query without a store entry")
  D.check(
    Properties["Update Status"]:find("not found on controller", 1, true) ~= nil,
    "skip names the missing package, got " .. tostring(Properties["Update Status"])
  )
  OnDriverDestroyed()
end)

D.test("director: websocket handshake survives a hex-only C4:Hash", function()
  local env = director()
  -- Colon definition: the probe's C4:Hash(...) calls pass C4 as self.
  function C4:Hash(_, data, opts)
    if opts ~= nil then
      error("options unsupported")
    end
    return D.sha1_hex(data)
  end
  OnDriverLateInit("test")
  D.check_equal(flogic_state.sha1_probe.encoding, "hex", "hex fallback probed")
  D.check_equal(flogic_state.sha1_probe.arity, 2, "two-argument call shape")
  Properties["Select Valve"] = ""
  env.server = D.new_fake_server({
    { expect_target = "Login", reply_target = "LoggedIn", reply_args = { { id = 7 } } },
    {
      expect_target = "RefreshValveArray",
      reply_target = "ValveArraySent",
      reply_args = { { { id = 11, name = "Kitchen" } } },
    },
  })
  flogic_poll_now()
  D.check_equal(Properties.Connection, "Select a valve", "discovery completes on hex digests")
  D.check(not flogic_state.busy, "completion releases busy flag")
  OnDriverDestroyed()
end)

D.test("director: unusable C4:Hash parks the driver with a clear status", function()
  local env = director()
  C4.Hash = function()
    error("no hash")
  end
  OnDriverLateInit("test")
  D.check(flogic_state.sha1_probe == nil, "no probe result")
  D.check(not flogic_state.initialized, "driver stays uninitialized")
  flogic_poll_now()
  D.check_equal(#env.transfers, 0, "no poll without a digest")
  D.check(
    Properties.Connection:find("no SHA1", 1, true) ~= nil,
    "status names the missing digest, got " .. tostring(Properties.Connection)
  )
  OnDriverDestroyed()
end)

D.test("director: polls never steal the idle Composer binding", function()
  local env = director()
  env.installed["flologic_valve"] = { [1] = true }
  ExecuteCommand("Install Latest Release", {})
  env.transfers[1].done(nil, { { code = 200, body = director_release("2026090808") } }, 0)
  env.transfers[2].done(nil, { { code = 200, body = "PK\003\004NEW-C4Z-BYTES" } }, 0)
  local soap_id = env.binding
  D.check(soap_id ~= nil, "install used a binding")
  -- Director clears the address when the SOAP connection drops; the id must
  -- still be reserved for the Composer endpoint.
  C4:SetBindingAddress(soap_id, "")
  Properties["Select Valve"] = ""
  env.server = D.new_fake_server({
    { expect_target = "Login", reply_target = "LoggedIn", reply_args = { { id = 7 } } },
    {
      expect_target = "RefreshValveArray",
      reply_target = "ValveArraySent",
      reply_args = { { { id = 11, name = "Kitchen" } } },
    },
  })
  flogic_poll_now()
  D.check(env.binding ~= soap_id, "poll takes a fresh binding")
  D.check_equal(Properties.Connection, "Select a valve", "poll completes")
  OnDriverDestroyed()
end)

D.test("director: cancelling before connect releases the binding for reuse", function()
  local env = director()
  flogic_poll_now()
  env.transfers[1].done(nil, { { code = 200, body = '{"connectionToken":"token"}' } }, 0)
  local first_id = env.binding
  -- Simulate a Director that never reports OFFLINE for the aborted connect.
  local disconnects = 0
  C4.NetDisconnect = function()
    disconnects = disconnects + 1
  end
  Properties["Select Valve"] = "Garden (22)"
  OnPropertyChanged("Select Valve")
  D.check(flogic_state.retired_bindings[first_id] == nil, "unconnected binding not retired")
  D.check_equal(disconnects, 1, "aborted connect still disconnects")
  flogic_poll_now()
  env.transfers[2].done(nil, { { code = 200, body = '{"connectionToken":"token"}' } }, 0)
  D.check_equal(env.binding, first_id, "binding reused immediately")
  OnDriverDestroyed()
end)
