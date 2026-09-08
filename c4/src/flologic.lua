-- ============================================================================
-- c4/src/flologic.lua — FloLogic SignalR cloud session (transport-injected).
--
-- Mirrors custom_components/flologic/api.py one-shot (non-persistent) flows:
-- negotiate -> websocket -> login -> fetch metadata | send command -> close.
-- No Control4 globals are referenced here; the caller injects http_post, a
-- raw tcp byte transport, timers, randomness, and crypto. Defines the global
-- FloLogic table only. Lua 5.1 safe.
-- ============================================================================

FloLogic = {}

FloLogic.OS_PLATFORM = "Android"
FloLogic.APP_VERSION = "control4"

local function pct_encode(text)
  return tostring(text):gsub("[^A-Za-z0-9_%.%-%~]", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end)
end

-- Describe a hub frame for logs by shape only (the byte length the
-- dispatcher reports), never by content: redacting control bytes stops
-- log injection but a payload excerpt can still leak whatever the
-- frame carried.
local function describe_frame_bytes(byte_count)
  return "frame-bytes=" .. tostring(tonumber(byte_count) or 0)
end

-- Split an https:// hub URL into host, port, and signalr base path.
function FloLogic.parse_hub_url(hub_url)
  if type(hub_url) ~= "string" or hub_url:find("[%s?#@]") then
    return nil, "bad hub URL"
  end
  local host, port, path = hub_url:match("^https://([%w%.%-]+):?(%d*)(/?.*)$")
  if host == nil then
    return nil, "bad hub URL"
  end
  port = tonumber(port) or 443
  if port < 1 or port > 65535 or (path ~= "" and path:sub(1, 1) ~= "/") then
    return nil, "bad hub URL"
  end
  path = path or ""
  path = path:gsub("/+$", "")
  if not path:lower():find("/signalr$") then
    path = path .. "/signalr"
  end
  return { host = host, port = port, path = path }
end

--- Validate a dense, unambiguous cloud inventory before replacing cached devices.
local function validate_inventory(devices)
  if type(devices) ~= "table" then
    return nil
  end
  local clean, ids, count = {}, {}, 0
  for index, device in pairs(devices) do
    count = count + 1
    if
      type(index) ~= "number"
      or index < 1
      or index % 1 ~= 0
      or type(device) ~= "table"
      or (type(device.id) ~= "number" and type(device.id) ~= "string")
      or tostring(device.id) == ""
      or ids[tostring(device.id)]
    then
      return nil
    end
    ids[tostring(device.id)] = true
    clean[index] = device
  end
  if count ~= #clean then
    return nil
  end
  return clean
end

--- Create a single-use asynchronous session.
--- @param opts table Injected HTTP/TCP, timers, crypto, credentials, and device identity.
--- @return table session fetch_snapshot/send_command complete once; cancel is silent.
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
    _log_warn = opts.log_warn or function() end,
    _now = opts.now or os.time,
    _tcp = nil,
    _dispatcher = nil,
    _ws_parser = nil,
    _done = false,
    _timers = {},
    _user = nil,
    _devices = nil,
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
    self.cancel()
    callback(err, result)
  end

  --- Cancel all owned work without calling the result callback.
  function self.cancel()
    self._done = true
    self._cancel_timers()
    if self._http_cancel then
      pcall(self._http_cancel)
      self._http_cancel = nil
    end
    if self._ws_parser then
      self._ws_parser.stop()
    end
    if self._dispatcher then
      self._dispatcher.stop()
    end
    if self._tcp ~= nil then
      local tcp = self._tcp
      self._tcp = nil
      pcall(function()
        tcp.close()
      end)
    end
  end

  self.close = self.cancel

  function self._send_text(text)
    if self._tcp == nil then
      return false
    end
    local mask = self._random_mask()
    local frame = WS.build_client_frame(text, mask, WS.OP_TEXT)
    return pcall(self._tcp.send, frame)
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
    -- FloLogic reads connection identity on the WebSocket request as well.
    -- Preserve exactly the headers used to create this negotiated connection.
    self._connection_headers = headers
    self._log_debug("negotiate " .. url)
    local ok_post, cancel = pcall(self._http_post, url, "", headers, function(err, data, code)
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
      if type(token) ~= "string" or token == "" then
        on_fail("http:no-connection-token")
        return
      end
      on_ok(token)
    end)
    if not ok_post then
      on_fail("http:adapter-error")
      return
    end
    if self._done then
      if cancel then
        pcall(cancel)
      end
    else
      self._http_cancel = cancel
    end
  end

  function self._open_websocket(hub, token, on_ok, on_fail)
    local ws_path = hub.path .. "?id=" .. pct_encode(token)
    local key = self._client_key()
    local expected = WS.expected_accept(key, self._sha1, self._b64encode)
    local handshake_done = false
    local cancel_upgrade = self._after(30000, function()
      on_fail("timeout:upgrade")
    end)
    self._dispatcher.on_handshake = function()
      cancel_upgrade()
      on_ok()
    end
    local handshake_buffer = ""
    local parser = WS.new_parser({
      on_message = function(payload, is_binary)
        if is_binary then
          -- The Home Assistant reader skips non-text messages; do the same.
          self._log_debug("ignoring binary websocket frame")
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
      local headers = {}
      for name, value in pairs(self._connection_headers) do
        if type(value) ~= "string" or value:find("[\r\n]") then
          on_fail("ws:invalid-connection-header")
          return
        end
        headers[#headers + 1] = name .. ": " .. value
      end
      local request = WS.build_handshake_request(hub.host .. ":" .. tostring(hub.port), ws_path, key, headers)
      if not pcall(self._tcp.send, request) then
        on_fail("ws:send-failed")
      end
    end
    local ok_open, tcp, tcp_err = pcall(self._tcp_open, hub.host, hub.port, {
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
    if not ok_open then
      on_fail("ws:adapter-error")
      return
    end
    if tcp == nil then
      on_fail("ws:" .. tostring(tcp_err or "tcp-open-failed"))
      return
    end
    if self._done then
      tcp.close()
      return
    end
    self._tcp = tcp
    if opened then
      send_handshake()
    end
  end

  function self._login(on_ok, on_fail)
    self._log_debug("login")
    self._wait_for("LoggedIn", 30000, function(args)
      local user = args[1]
      if type(user) ~= "table" or user.id == nil then
        on_fail("auth")
        return
      end
      self._user = user
      if type(user.relogToken) == "string" and user.relogToken ~= "" then
        self._relog_token = user.relogToken
        self.relog_token = user.relogToken
      end
      self._refresh_valve_array(user, function(devices)
        self._devices = devices
        on_ok(user, devices)
      end, on_fail)
    end, on_fail)
    if not self._invoke("Login", { self._email, self._password, self._device_name, JSON.null }) then
      on_fail("ws:send-failed")
    end
  end

  function self._refresh_valve_array(user, on_ok, on_fail)
    self._wait_for("ValveArraySent", 30000, function(args)
      local clean = validate_inventory(args[1])
      if not clean then
        on_fail("bad-valve-array")
        return
      end
      on_ok(clean)
    end, on_fail)
    if not self._invoke("RefreshValveArray", { user }) then
      on_fail("ws:send-failed")
    end
  end

  function self._connect(hub_url, on_ready, on_fail)
    self._after(180000, function()
      on_fail("timeout:session")
    end)
    local hub, hub_err = FloLogic.parse_hub_url(hub_url)
    if hub == nil then
      on_fail(hub_err)
      return
    end
    self._dispatcher = SignalR.new_dispatcher({
      on_event = function(target, args)
        if self._trace_events then
          self._log_warn("hub event: " .. tostring(target))
        end
        if target == "ErrorOccured" then
          -- The Home Assistant client logs this and continues; a cloud
          -- error notice must not abort a fetch that is otherwise healthy.
          self._log("cloud ErrorOccured event ignored")
        elseif target == "ValveArraySent" and self._devices then
          local devices = validate_inventory(args[1])
          if not devices then
            on_fail("bad-valve-array")
            return
          end
          self._devices = devices
          if self._confirm_check ~= nil then
            self._confirm_check()
          end
        elseif target == "ValveSent" and type(args[1]) == "table" and self._devices then
          -- Merge, mirroring the Home Assistant cache: replace the matching
          -- valve, or add a pushed valve the array has not listed yet.
          local incoming = args[1]
          if incoming.id ~= nil then
            local merged = false
            for index, valve in ipairs(self._devices) do
              if tostring(valve.id) == tostring(incoming.id) then
                self._devices[index] = incoming
                merged = true
                break
              end
            end
            if not merged then
              self._devices[#self._devices + 1] = incoming
            end
            if self._confirm_check ~= nil then
              self._confirm_check()
            end
          end
        end
      end,
      on_error = function(msg, detail)
        -- The Home Assistant client ignores undecodable and malformed
        -- frames; only transport-level failures abort the session.
        if msg == "undecodable SignalR frame" or msg == "bad-event" then
          if self._trace_events and detail ~= nil then
            self._log_warn("undecodable hub frame (" .. describe_frame_bytes(detail) .. ")")
          else
            self._log_debug("ignoring " .. msg)
          end
          return
        end
        on_fail("signalr:" .. msg)
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

  --- Resolve an explicit selection against the authoritative controllable inventory.
  function self._ensure_valve(user, devices, selected, on_ok, on_fail)
    local valves = FloModel.controllable_valves(devices)
    local valve = selected and selected ~= "" and FloModel.find_valve(valves, selected)
    if not valve then
      on_fail(selected and selected ~= "" and "valve-not-found" or "select-valve")
      return
    end
    on_ok(valve, devices, valves)
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
    end, function(_timeout_err)
      on_ok(nil) -- access is optional; timeouts degrade like scheduler/notifications
    end)
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
  -- ID or UUID. A blank selection discovers inventory only.
  -- cb(err, snapshot) with snapshot = { user, devices, valves, valve,
  -- access, scheduler, notifications }.
  function self.fetch_snapshot(hub_url, selected, cb)
    local function fail(err)
      self._finish(err, nil, cb)
    end
    self._connect(hub_url, function(user, devices)
      if selected == nil or selected == "" then
        self._finish(nil, { user = user, devices = devices }, cb)
        return
      end
      self._ensure_valve(user, devices, selected, function(valve)
        self._fetch_access(user, valve, function(access)
          self._fetch_scheduler(user, valve, function(scheduler)
            self._fetch_notifications(user, valve, function(notifications)
              local valves = FloModel.controllable_valves(self._devices)
              local latest = FloModel.find_valve(valves, valve.id)
              if not latest then
                fail("valve-not-found")
                return
              end
              self._finish(nil, {
                user = user,
                devices = self._devices,
                valves = valves,
                valve = latest,
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
  -- The hub applies RequestStateChange immediately, but the
  -- StateChangeResult event is unreliable: slow or offline valves may
  -- produce it late or never, while the cloud-side state already changed.
  -- So the event is only the fast path: inventory verification races it,
  -- and any post-invoke row showing the requested fields counts as
  -- success. Failure needs BOTH the event timeout AND no confirmation.
  --
  -- Optional opts (split cloud driver): { expected_uuid, deadline }.
  -- expected_uuid pins the command to the immutable identity that
  -- authorized it: the freshly fetched command-session row must carry it,
  -- or the command fails WITHOUT transmitting — a replaced valve must
  -- never receive another valve's queued write. deadline is an absolute
  -- os.time() budget covering session preparation AND transmission: the
  -- irreversible request is checked against it immediately before it is
  -- sent, so preparation can never spend the companion's response window
  -- and still transmit. Pre-transmit expiry fails "expired" (nothing
  -- sent); post-transmit timeouts keep their uncertain-outcome errors.
  function self.send_command(hub_url, selected, fields, cb, opts)
    local function fail(err)
      self._finish(err, nil, cb)
    end
    if selected == nil or selected == "" then
      fail("select-valve")
      return
    end
    opts = opts or {}
    local expected_uuid = opts.expected_uuid
    if expected_uuid ~= nil then
      expected_uuid = tostring(expected_uuid)
    end
    local deadline = tonumber(opts.deadline)
    self._trace_events = true
    self._connect(hub_url, function(user, devices)
      self._ensure_valve(user, devices, selected, function(valve)
        if expected_uuid ~= nil and tostring(valve.uuid or "") ~= expected_uuid then
          fail("identity-changed")
          return
        end
        local command = {
          active = true,
          created = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          userId = user.id,
          valveId = valve.id,
        }
        for k, v in pairs(fields) do
          if command[k] ~= nil then
            fail("reserved-command-field")
            return
          end
          command[k] = v
        end
        local function row_matches(row)
          if type(row) ~= "table" then
            return false
          end
          for key, want in pairs(fields) do
            if key == "mode" then
              -- Inventory mode is a flag combo; the requested bit set is
              -- what counts (mirrors the mode-name flag fallbacks).
              local have = tonumber(row.mode)
              local want_num = tonumber(want)
              if have == nil or want_num == nil or not FloModel.has_flag(have, want_num) then
                return false
              end
            else
              local have_num, want_num = tonumber(row[key]), tonumber(want)
              if have_num ~= nil and want_num ~= nil then
                if have_num ~= want_num then
                  return false
                end
              elseif row[key] ~= want then
                return false
              end
            end
          end
          return true
        end
        local function find_row()
          if type(self._devices) ~= "table" then
            return nil
          end
          for _, row in ipairs(self._devices) do
            if type(row) == "table" then
              -- A pushed merge may replace this id's row mid-command: a
              -- row carrying a DIFFERENT known uuid is a different
              -- physical valve and must never confirm this command. Rows
              -- without a uuid cannot disprove identity, so they still
              -- match by id (partial pushes carry no uuid).
              local uuid_ok = valve.uuid == nil or row.uuid == nil or tostring(row.uuid) == tostring(valve.uuid)
              if tostring(row.id) == tostring(valve.id) and uuid_ok then
                return row
              end
              if valve.uuid ~= nil and row.uuid == valve.uuid then
                return row
              end
            end
          end
          return nil
        end
        local function try_confirm(source)
          if self._done then
            return
          end
          local row = find_row()
          if row ~= nil and row_matches(row) then
            self._log_warn("command confirmed by " .. source)
            self._finish(nil, { valve = row }, cb)
          end
        end
        -- Push fast path: _connect merges ValveArraySent/ValveSent rows and
        -- runs this hook after every merge.
        self._confirm_check = function()
          try_confirm("push")
        end
        -- Scheduled explicit verifies for the no-push case. Verify errors
        -- never fail the command; the event timeout still owns failure.
        for _, delay_ms in ipairs({ 10000, 22000, 34000 }) do
          self._after(delay_ms, function()
            if self._done then
              return
            end
            try_confirm("cache")
            if self._done then
              return
            end
            self._log_warn("command verify refresh (no confirmation yet)")
            -- The merge hook above confirms from this reply; the waiter
            -- only needs to consume it.
            self._refresh_valve_array(user, function(refreshed)
              self._devices = refreshed
            end, function() end)
          end)
        end
        self._wait_for("StateChangeResult", 45000, function(args)
          local result = args[1]
          if result == false or (type(result) == "table" and (result.ok == false or result.success == false)) then
            fail("command-rejected")
            return
          end
          self._finish(nil, { valve = valve }, cb)
        end, function(err)
          self._finish(err, nil, cb)
        end)
        -- Absolute transmit deadline, checked immediately before the
        -- irreversible request: session preparation (negotiate, upgrade,
        -- login, inventory) consumes the same budget the queue granted.
        if deadline ~= nil and self._now() >= deadline then
          self._log_warn("command expired during session preparation; never transmitted")
          self._finish("expired", nil, cb)
          return
        end
        self._log_warn("invoke RequestStateChange")
        if not self._invoke("RequestStateChange", { user, valve, command }) then
          self._finish("ws:send-failed", nil, cb)
        else
          -- Idempotent fast path: the just-fetched inventory may already
          -- show the requested state (the invoke above still flew, so hub
          -- side effects are preserved).
          try_confirm("cache")
        end
      end, fail)
    end, fail)
  end

  return self
end
