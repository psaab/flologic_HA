-- ============================================================================
-- spike/valve_stub/driver.lua — Unit-0 spike: static link consumer + app switch.
--
-- Static CONTROL consumer link (binding 6000, class FLOGIC_VALVE) toward the
-- cloud stub plus a light_v2 proxy (binding 5001) with switch capabilities.
-- Answers SPIKE_PING with SPIKE_PONG (multi-KB both directions), sends
-- SPIKE_HELLO on bind, and applies DYNAMIC_ON / DYNAMIC_OFF / TOGGLE /
-- SET_BRIGHTNESS_TARGET while reporting LIGHT_LEVEL 100/0. A SendToDevice
-- fallback path (ExecuteCommand + provider discovery) mirrors the cloud stub.
--
-- Director entry points only; no top-level C4 calls. Lua 5.1 safe.
-- ============================================================================

SPIKE_VALVE_VERSION = "2026090701"
print("[spike-valve] Lua loaded: " .. SPIKE_VALVE_VERSION)

SPIKE_LINK_ID = 6000
SPIKE_LIGHT_ID = 5001
SPIKE_MAX_PAYLOAD = 16384
SPIKE_PERSIST_LEVEL = "spike_valve_level"

-- Property names (must match driver.xml).
SPIKE_PROP_STATUS = "Link Status"
SPIKE_PROP_LEVEL = "Light Level"
SPIKE_PROP_LAST_PING = "Last Ping"
SPIKE_PROP_LAST_PONG = "Last Pong"

spike_valve_state = {
  link_bound = false,
  level = 100,
  seq = 0,
}

local function spike_log(message)
  print("[spike-valve] " .. tostring(message))
end

local function spike_set_status()
  if spike_valve_state.link_bound then
    C4:UpdateProperty(SPIKE_PROP_STATUS, "Bound")
  else
    C4:UpdateProperty(SPIKE_PROP_STATUS, "Not linked")
  end
end

local function spike_payload(num_bytes)
  if num_bytes ~= num_bytes or num_bytes == math.huge or num_bytes < 0 then
    num_bytes = 0
  end
  if num_bytes > SPIKE_MAX_PAYLOAD then
    num_bytes = SPIKE_MAX_PAYLOAD
  end
  return string.rep("V", math.floor(num_bytes))
end

-- Single place that applies a level change: persist, report LIGHT_LEVEL on
-- the proxy, and tell the cloud stub so its log shows the round trip.
local function spike_apply_level(level, source)
  local st = spike_valve_state
  if level > 0 then
    level = 100
  else
    level = 0
  end
  st.level = level
  C4:PersistSetValue(SPIKE_PERSIST_LEVEL, tostring(level))
  C4:UpdateProperty(SPIKE_PROP_LEVEL, tostring(level))
  C4:SendToProxy(SPIKE_LIGHT_ID, "LIGHT_LEVEL", { LEVEL = level }, "NOTIFY")
  spike_log("level -> " .. level .. " (" .. tostring(source) .. "); reported LIGHT_LEVEL")
  if st.link_bound then
    local ok, err = pcall(function()
      C4:SendToProxy(SPIKE_LINK_ID, "SPIKE_LEVEL", { SENDER = "valve", LEVEL = level }, "COMMAND")
    end)
    if not ok then
      spike_log("WARN: SPIKE_LEVEL notify failed: " .. tostring(err))
    end
  end
end

local function spike_provider_ids()
  local ids = {}
  if C4.GetBoundProviderDevices ~= nil then
    local ok, found = pcall(function()
      return C4:GetBoundProviderDevices(0, SPIKE_LINK_ID)
    end)
    if not ok then
      spike_log("WARN: GetBoundProviderDevices raised: " .. tostring(found))
      return ids
    end
    if type(found) == "table" then
      for _, id in pairs(found) do
        if tonumber(id) ~= nil then
          ids[#ids + 1] = id
        end
      end
    elseif tonumber(found) ~= nil then
      ids[#ids + 1] = found
    end
  elseif C4.GetBoundProviderDevice ~= nil then
    local ok, found = pcall(function()
      return C4:GetBoundProviderDevice(0, SPIKE_LINK_ID)
    end)
    if not ok then
      spike_log("WARN: GetBoundProviderDevice raised: " .. tostring(found))
      return ids
    end
    if tonumber(found) ~= nil then
      ids[#ids + 1] = found
    end
  end
  return ids
end

local function spike_send_ping(via_device)
  local st = spike_valve_state
  st.seq = st.seq + 1
  local payload = spike_payload(4096)
  local params = { SENDER = "valve", SEQ = tostring(st.seq), PAYLOAD = payload }
  if via_device then
    local ids = spike_provider_ids()
    spike_log("sending Device Ping seq=" .. st.seq .. " bytes=" .. #payload .. " to " .. #ids .. " provider(s)")
    for _, id in ipairs(ids) do
      C4:SendToDevice(id, "Device Ping", params)
    end
  else
    C4:SendToProxy(SPIKE_LINK_ID, "SPIKE_PING", params, "COMMAND")
    spike_log("sent SPIKE_PING seq=" .. st.seq .. " bytes=" .. #payload)
  end
  C4:UpdateProperty(SPIKE_PROP_LAST_PING, "seq " .. st.seq .. " (" .. #payload .. " bytes)")
end

local function spike_on_link_message(strCommand, tParams)
  local st = spike_valve_state
  tParams = tParams or {}
  if strCommand == "SPIKE_PING" then
    local size = #(tostring(tParams.PAYLOAD or ""))
    spike_log("SPIKE_PING from cloud seq=" .. tostring(tParams.SEQ) .. " bytes=" .. size .. "; replying SPIKE_PONG")
    C4:SendToProxy(
      SPIKE_LINK_ID,
      "SPIKE_PONG",
      { SENDER = "valve", SEQ = tostring(tParams.SEQ or ""), PAYLOAD = spike_payload(size) },
      "COMMAND"
    )
    C4:UpdateProperty(SPIKE_PROP_LAST_PING, "cloud seq " .. tostring(tParams.SEQ) .. " (" .. size .. " bytes)")
  elseif strCommand == "SPIKE_PONG" then
    local size = #(tostring(tParams.PAYLOAD or ""))
    spike_log("SPIKE_PONG from cloud seq=" .. tostring(tParams.SEQ) .. " bytes=" .. size)
    C4:UpdateProperty(SPIKE_PROP_LAST_PONG, "seq " .. tostring(tParams.SEQ) .. " (" .. size .. " bytes)")
  elseif strCommand == "SPIKE_IDENTITY" then
    spike_log("SPIKE_IDENTITY from cloud valve=" .. tostring(tParams.VALVE))
    C4:UpdateProperty(SPIKE_PROP_LAST_PONG, "identity " .. tostring(tParams.VALVE))
  end
end

local function spike_on_light_message(strCommand, tParams)
  local st = spike_valve_state
  tParams = tParams or {}
  if strCommand == "DYNAMIC_ON" then
    spike_apply_level(100, "DYNAMIC_ON")
  elseif strCommand == "DYNAMIC_OFF" then
    spike_apply_level(0, "DYNAMIC_OFF")
  elseif strCommand == "TOGGLE" then
    if st.level > 0 then
      spike_apply_level(0, "TOGGLE")
    else
      spike_apply_level(100, "TOGGLE")
    end
  elseif strCommand == "SET_BRIGHTNESS_TARGET" then
    local target = tonumber(tParams.LEVEL) or tonumber(tParams.level) or 0
    if target > 0 then
      spike_apply_level(100, "SET_BRIGHTNESS_TARGET " .. target)
    else
      spike_apply_level(0, "SET_BRIGHTNESS_TARGET 0")
    end
  end
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  if idBinding == SPIKE_LINK_ID then
    spike_on_link_message(strCommand, tParams)
  elseif idBinding == SPIKE_LIGHT_ID then
    spike_on_light_message(strCommand, tParams)
  end
end

function OnBindingChanged(idBinding, strClass, bIsBound)
  spike_log(
    "OnBindingChanged id=" .. tostring(idBinding) .. " class=" .. tostring(strClass) .. " bound=" .. tostring(bIsBound)
  )
  if idBinding ~= SPIKE_LINK_ID then
    return
  end
  spike_valve_state.link_bound = bIsBound and true or false
  spike_set_status()
  if bIsBound then
    local ok, err = pcall(function()
      C4:SendToProxy(SPIKE_LINK_ID, "SPIKE_HELLO", { SENDER = "valve" }, "COMMAND")
    end)
    if ok then
      spike_log("sent SPIKE_HELLO on bind")
    else
      spike_log("WARN: SPIKE_HELLO failed: " .. tostring(err))
    end
  end
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "Ping Cloud" then
    spike_send_ping(false)
  elseif strCommand == "Ping Cloud via Device" then
    spike_send_ping(true)
  elseif strCommand == "Turn On" then
    spike_apply_level(100, "programming")
  elseif strCommand == "Turn Off" then
    spike_apply_level(0, "programming")
  elseif strCommand == "Device Ping" then
    -- SendToDevice fallback arrival: reply to every bound provider.
    local size = #(tostring(tParams.PAYLOAD or ""))
    spike_log("Device Ping seq=" .. tostring(tParams.SEQ) .. " bytes=" .. size .. "; replying Device Pong")
    for _, id in ipairs(spike_provider_ids()) do
      C4:SendToDevice(
        id,
        "Device Pong",
        { SENDER = "valve", SEQ = tostring(tParams.SEQ or ""), PAYLOAD = spike_payload(size) }
      )
    end
    C4:UpdateProperty(SPIKE_PROP_LAST_PING, "cloud seq " .. tostring(tParams.SEQ) .. " (" .. size .. " bytes, device)")
  elseif strCommand == "Device Pong" then
    local size = #(tostring(tParams.PAYLOAD or ""))
    spike_log("Device Pong seq=" .. tostring(tParams.SEQ) .. " bytes=" .. size)
    C4:UpdateProperty(SPIKE_PROP_LAST_PONG, "seq " .. tostring(tParams.SEQ) .. " (" .. size .. " bytes, device)")
  else
    spike_log("WARN: unknown command: " .. tostring(strCommand))
  end
end

function OnDriverInit(driver_init_type)
  C4:UpdateProperty("Driver Version", SPIKE_VALVE_VERSION)
  spike_log("OnDriverInit: " .. SPIKE_VALVE_VERSION .. " (" .. tostring(driver_init_type) .. ")")
  local saved = C4:PersistGetValue(SPIKE_PERSIST_LEVEL)
  if tonumber(saved) == 0 then
    spike_valve_state.level = 0
  else
    spike_valve_state.level = 100
  end
  C4:UpdateProperty(SPIKE_PROP_LEVEL, tostring(spike_valve_state.level))
  spike_set_status()
end

function OnDriverLateInit(driver_init_type)
  spike_log("OnDriverLateInit: " .. SPIKE_VALVE_VERSION .. " (" .. tostring(driver_init_type) .. ")")
  C4:UpdateProperty("Driver Version", SPIKE_VALVE_VERSION)
  C4:UpdateProperty(SPIKE_PROP_LEVEL, tostring(spike_valve_state.level))
  spike_set_status()
  spike_log("runtime ready")
end

function OnDriverDestroyed()
  spike_log("OnDriverDestroyed")
end
