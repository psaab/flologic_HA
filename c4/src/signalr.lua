-- ============================================================================
-- c4/src/signalr.lua — SignalR JSON-protocol codec and event dispatcher.
--
-- Pure logic (uses the global JSON table at call time). Defines the global
-- SignalR table only. No require, no return, no top-level execution.
-- Lua 5.1 safe: the record separator uses a decimal escape (\030 = \x1e).
-- ============================================================================

SignalR = SignalR or {}

SignalR.RECORD_SEPARATOR = "\030"

function SignalR.handshake_message()
  return '{"protocol":"json","version":1}' .. SignalR.RECORD_SEPARATOR
end

function SignalR.build_invoke(target, args)
  return JSON.encode({ type = 1, target = target, arguments = args or {} }) .. SignalR.RECORD_SEPARATOR
end

-- Dispatcher matches hub events to one-shot waiters, like the Home Assistant
-- client's _events table. opts.on_event(target, arguments) observes every
-- event; opts.on_error(message) reports undecodable frames.
function SignalR.new_dispatcher(opts)
  opts = opts or {}
  local self = {
    _buffer = "",
    _waiters = {},
    _on_event = opts.on_event,
    _on_error = opts.on_error,
  }

  function self.wait_for(event_name, callback)
    local list = self._waiters[event_name]
    if list == nil then
      list = {}
      self._waiters[event_name] = list
    end
    list[#list + 1] = callback
    -- Returns a cancel function for timeouts.
    return function()
      local current = self._waiters[event_name]
      if current == nil then
        return
      end
      for i, fn in ipairs(current) do
        if fn == callback then
          table.remove(current, i)
          return
        end
      end
    end
  end

  function self.pending(event_name)
    local list = self._waiters[event_name]
    return list ~= nil and #list or 0
  end

  function self.stop()
    self._stopped = true
    self._buffer, self._waiters = "", {}
  end

  function self.fail_all(err)
    local waiters = self._waiters
    self._waiters = {}
    for _, list in pairs(waiters) do
      for _, fn in ipairs(list) do
        fn(nil, err)
      end
    end
  end

  local function handle_frame(frame)
    if type(frame) == "table" and (frame.error ~= nil or frame.type == 7) then
      if self._on_error then
        self._on_error("server-closed")
      end
      return
    end
    if type(frame) == "table" and frame.type == nil and self.on_handshake then
      local callback = self.on_handshake
      self.on_handshake = nil
      callback()
      return
    end
    if type(frame) ~= "table" or frame.type ~= 1 then
      return
    end
    local target = frame.target
    if target == nil or target == "" then
      return
    end
    local args = frame.arguments or {}
    if type(target) ~= "string" or type(args) ~= "table" then
      if self._on_error then
        self._on_error("bad-event")
      end
      return
    end
    if self._on_event ~= nil then
      self._on_event(target, args)
    end
    if self._stopped then
      return
    end
    local list = self._waiters[target]
    if list ~= nil and #list > 0 then
      local fn = table.remove(list, 1)
      fn(args, nil)
    end
  end

  function self.feed(text)
    if self._stopped then
      return
    end
    self._buffer = self._buffer .. text
    if #self._buffer > 1048576 then
      self.stop()
      if self._on_error then
        self._on_error("record-too-large")
      end
      return
    end
    while not self._stopped do
      local cut = self._buffer:find(SignalR.RECORD_SEPARATOR, 1, true)
      if cut == nil then
        return
      end
      local raw = self._buffer:sub(1, cut - 1)
      self._buffer = self._buffer:sub(cut + 1)
      if raw ~= "" then
        local ok, frame = pcall(JSON.decode, raw)
        if ok then
          handle_frame(frame)
        elseif self._on_error ~= nil then
          self._on_error("undecodable SignalR frame")
        end
      end
    end
  end

  return self
end
