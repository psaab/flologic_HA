-- Runs FIRST, before replacing module tables or Director callbacks on hot reload.
-- Director may evaluate the bundle again without calling OnDriverDestroyed.
function flogic_retire_runtime()
  local previous = flogic_state
  if not previous then
    return
  end
  previous.initialized = false
  local session = previous.session
  local binding, port = previous.binding, previous.hub_port
  previous.session, previous.busy, previous.tcp_callbacks = nil, false, nil
  previous.command_queue = {}
  for _, name in ipairs({
    "poll_timer",
    "tick_timer",
    "soon_timer",
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
end

flogic_retire_runtime()
