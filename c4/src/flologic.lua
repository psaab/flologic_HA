-- ============================================================================
-- c4/src/flologic.lua — FloLogic SignalR cloud session (transport-injected).
--
-- Mirrors custom_components/flologic/api.py one-shot (non-persistent) flows:
-- negotiate -> websocket -> login -> fetch metadata | send command -> close.
-- No Control4 globals are referenced here; the caller injects http_post, a
-- raw tcp byte transport, timers, randomness, and crypto. Defines the global
-- FloLogic table only. Lua 5.1 safe.
-- ============================================================================

FloLogic = FloLogic or {}

FloLogic.OS_PLATFORM = "Android"
FloLogic.APP_VERSION = "control4"

local function pct_encode(text)
  return tostring(text):gsub("[^A-Za-z0-9_%.%-%~]", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end)
end

-- Split an https:// hub URL into host, port, and signalr base path.
function FloLogic.parse_hub_url(hub_url)
  local host, port, path = hub_url:match("^https?://([^:/%s]+):?(%d*)([^%s]*)")
  if host == nil then
    return nil, "bad hub URL: " .. tostring(hub_url)
  end
  port = tonumber(port) or 443
  path = path or ""
  path = path:gsub("/+$", "")
  if not path:lower():find("/signalr$") then
    path = path .. "/signalr"
  end
  if path == "" then
    path = "/signalr"
  end
  return { host = host, port = port, path = path }
end

function FloLogic.new_session(opts)
  local self = {
    _email = opts.email,
    _password = opts.password,
    _device_name = opts.device_name or "Control4",
    _device_code = opts.device_code or "AND-c4-custom-001",
    _device_token = opts.device_token or "c4-custom-token",
    _relog_token = opts.relog_token or "",
    _http_post = opts.http_post,
    _tcp_open = opts.tcp_open,
    _set_timeout = opts.set_timeout,
    _client_key = opts.client_key,
    _sha1 = opts.sha1,
    _b64encode = opts.b64encode,
    _random_mask = opts.random_mask,
    _log = opts.log or function() end,
    _tcp = nil,
    _dispatcher = nil,
    _ws_parser = nil,
    _done = false,
    _timers = {},
    _user = nil,
    _devices = nil,
    _late_valve = nil,
    relog_token = opts.relog_token or "",
  }

  function self._log_debug(msg)
    self._log("DEBUG: " .. msg)
  end

  function self._after(ms, fn)
    local cancel = self._set_timeout(ms, function()
      if not self._done then
        fn()
      end
    end)
    self._timers[#self._timers + 1] = cancel
    return cancel
  end

  function self._cancel_timers()
    for _, cancel in ipairs(self._timers) do
      pcall(cancel)
    end
    self._timers = {}
  end

  function self._finish(err, result, callback)
    if self._done then
      return
    end
    self._done = true
    self._cancel_timers()
    if self._dispatcher ~= nil then
      self._dispatcher.fail_all(err or "closed")
    end
    self.close()
    callback(err, result)
  end

  function self.close()
    if self._tcp ~= nil then
      local tcp = self._tcp
      self._tcp = nil
      pcall(function()
        tcp.close()
      end)
    end
  end

  function self._send_text(text)
    if self._tcp == nil then
      return false
    end
    local mask = self._random_mask()
    local frame = WS.build_client_frame(text, mask, WS.OP_TEXT)
    self._tcp.send(frame)
    return true
  end

  function self._invoke(target, args)
    self._log_debug("invoke " .. target)
    return self._send_text(SignalR.build_invoke(target, args))
  end

  -- Wait for one hub event with a timeout (ms). cb(args) on success,
  -- fail_cb(err) on timeout. Returns immediately if the session finished.
  function self._wait_for(event_name, timeout_ms, cb, fail_cb)
    local cancel_waiter = nil
    local cancel_timer = nil
    local settled = false
    local function settle(args, err)
      if settled or self._done then
        return
      end
      settled = true
      if cancel_timer ~= nil then
        pcall(cancel_timer)
      end
      if err ~= nil then
        fail_cb(err)
      else
        cb(args)
      end
    end
    cancel_waiter = self._dispatcher.wait_for(event_name, function(args, err)
      settle(args, err)
    end)
    cancel_timer = self._after(timeout_ms, function()
      if cancel_waiter ~= nil then
        cancel_waiter()
      end
      settle(nil, "timeout:" .. event_name)
    end)
  end

  function self._negotiate(hub, on_ok, on_fail)
    local url = "https://" .. hub.host .. ":" .. tostring(hub.port) .. hub.path .. "/negotiate"
    -- Omit the default port for cosmetics; harmless either way.
    if hub.port == 443 then
      url = "https://" .. hub.host .. hub.path .. "/negotiate"
    end
    local headers = {
      userDeviceCode = self._device_code,
      userDeviceToken = self._device_token,
      relogToken = self._relog_token,
      OsPlatform = FloLogic.OS_PLATFORM,
      AppVer = FloLogic.APP_VERSION,
      DeviceName = self._device_name,
    }
    self._log_debug("negotiate " .. url)
    self._http_post(url, "", headers, function(err, data, code)
      if self._done then
        return
      end
      if err ~= nil then
        on_fail("http:" .. tostring(err))
        return
      end
      if code == 401 or code == 403 then
        on_fail("auth")
        return
      end
      if code == nil or code < 200 or code >= 300 then
        on_fail("http:" .. tostring(code))
        return
      end
      local ok, payload = pcall(JSON.decode, data or "")
      if not ok or type(payload) ~= "table" then
        on_fail("http:bad-negotiate-body")
        return
      end
      local token = payload.connectionToken or payload.connectionId
      if token == nil or token == "" then
        on_fail("http:no-connection-token")
        return
      end
      on_ok(token)
    end)
  end

  function self._open_websocket(hub, token, on_ok, on_fail)
    local ws_path = hub.path .. "?id=" .. pct_encode(token)
    local key = self._client_key()
    local expected = WS.expected_accept(key, self._sha1, self._b64encode)
    local handshake_done = false
    local handshake_buffer = ""
    local parser = WS.new_parser({
      on_message = function(payload, is_binary)
        if is_binary then
          if not self._done then
            on_fail("ws:binary-frame")
          end
          return
        end
        self._dispatcher.feed(payload)
      end,
      send_frame = function(payload, opcode)
        if self._tcp ~= nil then
          self._tcp.send(WS.build_client_frame(payload, self._random_mask(), opcode))
        end
      end,
      on_close = function(code, _reason)
        if not self._done then
          on_fail("ws:closed-" .. tostring(code))
        end
      end,
      on_error = function(msg)
        if not self._done then
          on_fail("ws:" .. tostring(msg))
        end
      end,
    })
    self._ws_parser = parser
    -- The transport may report on_open synchronously (before tcp_open
    -- returns), so the handshake send is deferred until self._tcp exists.
    local opened, handshake_sent = false, false
    local function send_handshake()
      if handshake_sent or self._done or self._tcp == nil then
        return
      end
      handshake_sent = true
      local request = WS.build_handshake_request(
        hub.host .. ":" .. tostring(hub.port), ws_path, key
      )
      self._tcp.send(request)
    end
    local tcp, tcp_err = self._tcp_open(hub.host, hub.port, {
      on_open = function()
        opened = true
        send_handshake()
      end,
      on_data = function(bytes)
        if self._done then
          return
        end
        if not handshake_done then
          handshake_buffer = handshake_buffer .. bytes
          local accept, consumed_or_err = WS.parse_handshake_response(handshake_buffer)
          if accept == nil and consumed_or_err == "need_more" then
            return
          end
          if accept == nil then
            on_fail("ws:" .. tostring(consumed_or_err))
            return
          end
          if accept ~= expected then
            on_fail("ws:bad-accept-key")
            return
          end
          handshake_done = true
          local rest = handshake_buffer:sub(consumed_or_err + 1)
          handshake_buffer = ""
          if not self._send_text(SignalR.handshake_message()) then
            on_fail("ws:send-failed")
            return
          end
          on_ok()
          if rest ~= "" then
            parser.feed(rest)
          end
        else
          parser.feed(bytes)
        end
      end,
      on_close = function()
        if not self._done then
          on_fail("ws:tcp-closed")
        end
      end,
      on_error = function(msg)
        if not self._done then
          on_fail("ws:" .. tostring(msg))
        end
      end,
    })
    if tcp == nil then
      on_fail("ws:" .. tostring(tcp_err or "tcp-open-failed"))
      return
    end
    self._tcp = tcp
    if opened then
      send_handshake()
    end
  end

  function self._login(on_ok, on_fail)
    self._log_debug("login as " .. self._email)
    self._wait_for("LoggedIn", 30000, function(args)
      local user = args[1]
      if type(user) ~= "table" then
        on_fail("auth")
        return
      end
      self._user = user
      if user.relogToken ~= nil and user.relogToken ~= "" then
        self._relog_token = user.relogToken
        self.relog_token = user.relogToken
      end
      -- Fast path: a ValveSent usually follows immediately. Fall back to
      -- RefreshValveArray after 3s, merging a late ValveSent if one lands.
      self._late_valve = nil
      local got_valve = false
      local function use_devices(devices)
        if got_valve then
          return
        end
        got_valve = true
        self._devices = devices
        on_ok(user, devices)
      end
      self._wait_for("ValveSent", 3000, function(valve_args)
        local valve = valve_args[1]
        if type(valve) == "table" then
          use_devices({ valve })
        else
          self._refresh_valve_array(user, use_devices, on_fail)
        end
      end, function(_timeout_err)
        self._refresh_valve_array(user, use_devices, on_fail)
      end)
    end, on_fail)
    if not self._invoke("Login", { self._email, self._password, self._device_name, JSON.null }) then
      on_fail("ws:send-failed")
    end
  end

  function self._refresh_valve_array(user, on_ok, on_fail)
    self._wait_for("ValveArraySent", 30000, function(args)
      local devices = args[1]
      if type(devices) ~= "table" then
        devices = {}
      end
      local clean = {}
      for _, device in ipairs(devices) do
        if type(device) == "table" then
          clean[#clean + 1] = device
        end
      end
      if self._late_valve ~= nil then
        local seen = false
        for _, device in ipairs(clean) do
          if device.id == self._late_valve.id then
            seen = true
            break
          end
        end
        if not seen then
          clean[#clean + 1] = self._late_valve
        end
      end
      on_ok(clean)
    end, on_fail)
    if not self._invoke("RefreshValveArray", { user }) then
      on_fail("ws:send-failed")
    end
  end

  local function observe_valve_sent(self_ref, target, args)
    if target == "ValveSent" and args[1] ~= nil and type(args[1]) == "table" then
      self_ref._late_valve = args[1]
    elseif target == "ErrorOccured" then
      self_ref._log_debug("cloud error event")
    end
  end

  function self._connect(hub_url, on_ready, on_fail)
    local hub, hub_err = FloLogic.parse_hub_url(hub_url)
    if hub == nil then
      on_fail(hub_err)
      return
    end
    self._dispatcher = SignalR.new_dispatcher({
      on_event = function(target, args)
        observe_valve_sent(self, target, args)
      end,
      on_error = function(msg)
        self._log_debug(msg)
      end,
    })
    self._negotiate(hub, function(token)
      self._open_websocket(hub, token, function()
        self._login(function(user, devices)
          on_ready(user, devices)
        end, on_fail)
      end, on_fail)
    end, on_fail)
  end

  -- Resolve the effective valve. A nil/blank selection means the primary
  -- valve. When a selection is not among the login devices, the login fast
  -- path may have sent only the primary valve, so the full array is fetched
  -- before reporting valve-not-found.
  function self._ensure_valve(user, devices, selected, on_ok, on_fail)
    local valves = FloModel.controllable_valves(devices)
    local valve = nil
    if selected == nil or selected == "" then
      valve = FloModel.choose_valve(devices)
    else
      valve = FloModel.find_valve(valves, selected)
        or FloModel.find_valve(devices, selected)
    end
    if valve ~= nil then
      on_ok(valve, devices, valves)
      return
    end
    if selected == nil or selected == "" then
      on_fail("no-valve")
      return
    end
    self._refresh_valve_array(user, function(full)
      local full_valves = FloModel.controllable_valves(full)
      local found = FloModel.find_valve(full_valves, selected)
        or FloModel.find_valve(full, selected)
      if found == nil then
        on_fail("valve-not-found")
        return
      end
      on_ok(found, full, full_valves)
    end, on_fail)
  end

  function self._fetch_access(user, valve, on_ok, on_fail)
    self._wait_for("UserAccessesSent", 30000, function(args)
      local accesses = args[1]
      local access = nil
      if type(accesses) == "table" then
        for _, row in ipairs(accesses) do
          if type(row) == "table" and row.valveId == valve.id then
            access = row
            break
          end
        end
      end
      on_ok(access)
    end, on_fail)
    if not self._invoke("RequestUserAccesses", { user }) then
      on_fail("ws:send-failed")
    end
  end

  function self._fetch_scheduler(user, valve, on_ok, on_fail)
    self._wait_for("SchedulerEventsSent", 30000, function(args)
      local rows = args[1]
      if type(rows) ~= "table" then
        rows = {}
      end
      on_ok(rows)
    end, function(_timeout_err)
      on_ok({}) -- scheduler is optional; timeouts degrade to empty
    end)
    if not self._invoke("RequestSchedulerEvents", { user.id, valve.id }) then
      on_fail("ws:send-failed")
    end
  end

  function self._fetch_notifications(user, valve, on_ok, on_fail)
    -- Per-valve history only. There is deliberately no account-wide retry:
    -- an empty history must never pull in another site's notifications.
    self._wait_for("NotificationsHistorySent", 30000, function(args)
      local rows = args[1]
      if type(rows) == "table" then
        on_ok(rows)
      else
        on_ok({})
      end
    end, function(_timeout_err)
      on_ok({})
    end)
    if not self._invoke("RefreshValvesNotificationsHistory", { user.id, { valve.id } }) then
      on_fail("ws:send-failed")
    end
  end

  -- Fetch one poll snapshot for the selected valve. selected may be a valve
  -- id, uuid, or unique-id prefix, or nil for the primary valve.
  -- cb(err, snapshot) with snapshot = { user, devices, valves, valve,
  -- access, scheduler, notifications }.
  function self.fetch_snapshot(hub_url, selected, cb)
    local function fail(err)
      self._finish(err, nil, cb)
    end
    self._connect(hub_url, function(user, devices)
      self._ensure_valve(user, devices, selected, function(valve, all_devices, valves)
        self._fetch_access(user, valve, function(access)
          self._fetch_scheduler(user, valve, function(scheduler)
            self._fetch_notifications(user, valve, function(notifications)
              self._finish(nil, {
                user = user,
                devices = all_devices,
                valves = valves,
                valve = valve,
                access = access,
                scheduler = scheduler,
                notifications = notifications,
              }, cb)
            end, fail)
          end, fail)
        end, fail)
      end, fail)
    end, fail)
  end

  -- Send one state-change command. fields is a flat table of cloud values.
  function self.send_command(hub_url, selected, fields, cb)
    local function fail(err)
      self._finish(err, nil, cb)
    end
    self._connect(hub_url, function(user, devices)
      self._ensure_valve(user, devices, selected, function(valve)
        local command = {
          active = true,
          created = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          userId = user.id,
          valveId = valve.id,
        }
        for k, v in pairs(fields) do
          command[k] = v
        end
        self._wait_for("StateChangeResult", 45000, function(_args)
          self._finish(nil, { valve = valve }, cb)
        end, function(err)
          self._finish(err, nil, cb)
        end)
        if not self._invoke("RequestStateChange", { user, valve, command }) then
          self._finish("ws:send-failed", nil, cb)
        end
      end, fail)
    end, fail)
  end

  return self
end
