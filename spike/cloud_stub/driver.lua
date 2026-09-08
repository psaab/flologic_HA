-- ============================================================================
-- spike/cloud_stub/driver.lua — Unit-0 spike: dynamic CONTROL provider stub.
--
-- Creates ONE dynamic provider binding (class FLOGIC_VALVE) at runtime via
-- C4:AddDynamicBinding, persists it, and restores it on init. Speaks a
-- minimal BindMessage ping/pong in both directions (ReceivedFromProxy /
-- SendToProxy) with a multi-KB payload, plus a SendToDevice fallback path
-- (ExecuteCommand + GetBound* discovery) if peer BindMessages do not arrive.
--
-- Director entry points only; no top-level C4 calls. Lua 5.1 safe.
-- ============================================================================

SPIKE_CLOUD_VERSION = "2026090701"
print("[spike-cloud] Lua loaded: " .. SPIKE_CLOUD_VERSION)

SPIKE_BINDING_ID = 2001
SPIKE_BINDING_CLASS = "FLOGIC_VALVE"
SPIKE_BINDING_NAME = "Spike Valve 1"
SPIKE_PERSIST_KEY = "spike_cloud_binding"
SPIKE_MAX_PAYLOAD = 16384

-- Property names (must match driver.xml).
SPIKE_PROP_STATUS = "Link Status"
SPIKE_PROP_BINDING = "Binding ID"
SPIKE_PROP_PING_BYTES = "Ping Bytes"
SPIKE_PROP_LAST_PING = "Last Ping"
SPIKE_PROP_LAST_PONG = "Last Pong"

spike_cloud_state = {
  binding_id = nil,
  bound = false,
  seq = 0,
}

local function spike_log(message)
  print("[spike-cloud] " .. tostring(message))
end

local function spike_set_status()
  local st = spike_cloud_state
  if st.binding_id == nil then
    C4:UpdateProperty(SPIKE_PROP_STATUS, "No link (run Add Valve Link)")
    C4:UpdateProperty(SPIKE_PROP_BINDING, "")
  elseif st.bound then
    C4:UpdateProperty(SPIKE_PROP_STATUS, "Bound")
    C4:UpdateProperty(SPIKE_PROP_BINDING, tostring(st.binding_id))
  else
    C4:UpdateProperty(SPIKE_PROP_STATUS, "Waiting for bind")
    C4:UpdateProperty(SPIKE_PROP_BINDING, tostring(st.binding_id))
  end
end

local function spike_add_binding(binding_id)
  C4:AddDynamicBinding(binding_id, "CONTROL", true, SPIKE_BINDING_NAME, SPIKE_BINDING_CLASS, false, false)
  spike_cloud_state.binding_id = binding_id
  C4:PersistSetValue(SPIKE_PERSIST_KEY, tostring(binding_id))
  spike_log("dynamic binding added: id=" .. tostring(binding_id) .. " class=" .. SPIKE_BINDING_CLASS)
  spike_set_status()
end

local function spike_restore_binding()
  if spike_cloud_state.binding_id ~= nil then
    return
  end
  local saved = C4:PersistGetValue(SPIKE_PERSIST_KEY)
  if type(saved) ~= "string" or saved == "" then
    spike_log("no persisted binding; run the Add Valve Link command")
    spike_set_status()
    return
  end
  local id = tonumber(saved) or SPIKE_BINDING_ID
  -- Re-create the runtime binding; a stale entry self-heals because the
  -- persisted value is rewritten by spike_add_binding on the next command.
  local ok, err = pcall(function()
    C4:AddDynamicBinding(id, "CONTROL", true, SPIKE_BINDING_NAME, SPIKE_BINDING_CLASS, false, false)
  end)
  -- A Lua reload keeps Director-side runtime bindings, so re-add may fail
  -- on the id that already exists. The persisted map is authoritative
  -- either way (mirrors the production H4 fix): keep the id regardless
  -- and let traffic prove the binding.
  if not ok then
    spike_log("WARN: restore re-add failed (binding may already exist): " .. tostring(err))
  else
    spike_log("restored dynamic binding id=" .. tostring(id))
  end
  spike_cloud_state.binding_id = id
  spike_set_status()
end

local function spike_ping_bytes()
  local raw = nil
  if Properties ~= nil then
    raw = Properties[SPIKE_PROP_PING_BYTES]
  end
  local n = tonumber(raw) or 4096
  if n ~= n or n == math.huge or n < 0 then
    n = 0
  end
  if n > SPIKE_MAX_PAYLOAD then
    n = SPIKE_MAX_PAYLOAD
  end
  return math.floor(n)
end

local function spike_payload(num_bytes)
  if num_bytes ~= num_bytes or num_bytes == math.huge or num_bytes < 0 then
    num_bytes = 0
  end
  if num_bytes > SPIKE_MAX_PAYLOAD then
    num_bytes = SPIKE_MAX_PAYLOAD
  end
  return string.rep("C", math.floor(num_bytes))
end

local function spike_consumer_ids()
  local st = spike_cloud_state
  local ids = {}
  if st.binding_id == nil or C4.GetBoundConsumerDevices == nil then
    return ids
  end
  local ok, found = pcall(function()
    return C4:GetBoundConsumerDevices(0, st.binding_id)
  end)
  if not ok then
    spike_log("WARN: GetBoundConsumerDevices raised: " .. tostring(found))
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
  return ids
end

local function spike_send_ping(via_device)
  local st = spike_cloud_state
  if st.binding_id == nil then
    spike_log("WARN: no binding yet; run Add Valve Link first")
    return
  end
  st.seq = st.seq + 1
  local payload = spike_payload(spike_ping_bytes())
  local params = { SENDER = "cloud", SEQ = tostring(st.seq), PAYLOAD = payload }
  if via_device then
    local ids = spike_consumer_ids()
    spike_log("sending Device Ping seq=" .. st.seq .. " bytes=" .. #payload .. " to " .. #ids .. " consumer(s)")
    for _, id in ipairs(ids) do
      C4:SendToDevice(id, "Device Ping", params)
    end
  else
    C4:SendToProxy(st.binding_id, "SPIKE_PING", params, "COMMAND")
    spike_log("sent SPIKE_PING seq=" .. st.seq .. " bytes=" .. #payload)
  end
  C4:UpdateProperty(SPIKE_PROP_LAST_PING, "seq " .. st.seq .. " (" .. #payload .. " bytes)")
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  local st = spike_cloud_state
  if idBinding ~= st.binding_id then
    return
  end
  tParams = tParams or {}
  if strCommand == "SPIKE_PING" then
    local size = #(tostring(tParams.PAYLOAD or ""))
    spike_log("SPIKE_PING from peer seq=" .. tostring(tParams.SEQ) .. " bytes=" .. size .. "; replying SPIKE_PONG")
    local payload = spike_payload(size)
    C4:SendToProxy(
      idBinding,
      "SPIKE_PONG",
      { SENDER = "cloud", SEQ = tostring(tParams.SEQ or ""), PAYLOAD = payload },
      "COMMAND"
    )
    C4:UpdateProperty(SPIKE_PROP_LAST_PING, "peer seq " .. tostring(tParams.SEQ) .. " (" .. size .. " bytes)")
  elseif strCommand == "SPIKE_PONG" then
    local size = #(tostring(tParams.PAYLOAD or ""))
    spike_log("SPIKE_PONG from peer seq=" .. tostring(tParams.SEQ) .. " bytes=" .. size)
    C4:UpdateProperty(SPIKE_PROP_LAST_PONG, "seq " .. tostring(tParams.SEQ) .. " (" .. size .. " bytes)")
  elseif strCommand == "SPIKE_HELLO" then
    spike_log("SPIKE_HELLO from peer; replying SPIKE_IDENTITY")
    C4:SendToProxy(idBinding, "SPIKE_IDENTITY", { SENDER = "cloud", VALVE = "spike-valve-1" }, "COMMAND")
  elseif strCommand == "SPIKE_LEVEL" then
    spike_log("SPIKE_LEVEL from peer level=" .. tostring(tParams.LEVEL))
  end
end

function OnBindingChanged(idBinding, strClass, bIsBound)
  local st = spike_cloud_state
  if idBinding ~= st.binding_id and idBinding ~= SPIKE_BINDING_ID then
    return
  end
  if st.binding_id == nil then
    st.binding_id = idBinding
  end
  st.bound = bIsBound and true or false
  spike_log(
    "OnBindingChanged id=" .. tostring(idBinding) .. " class=" .. tostring(strClass) .. " bound=" .. tostring(bIsBound)
  )
  spike_set_status()
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "Add Valve Link" then
    spike_add_binding(SPIKE_BINDING_ID)
  elseif strCommand == "Ping Peer" then
    spike_send_ping(false)
  elseif strCommand == "Ping Peer via Device" then
    spike_send_ping(true)
  elseif strCommand == "Device Ping" then
    -- SendToDevice fallback arrival: reply to every bound consumer.
    local st = spike_cloud_state
    st.seq = st.seq + 1
    local size = #(tostring(tParams.PAYLOAD or ""))
    local payload = spike_payload(size)
    spike_log("Device Ping seq=" .. tostring(tParams.SEQ) .. " bytes=" .. size .. "; replying Device Pong")
    for _, id in ipairs(spike_consumer_ids()) do
      C4:SendToDevice(id, "Device Pong", { SENDER = "cloud", SEQ = tostring(tParams.SEQ or ""), PAYLOAD = payload })
    end
    C4:UpdateProperty(SPIKE_PROP_LAST_PING, "peer seq " .. tostring(tParams.SEQ) .. " (" .. size .. " bytes, device)")
  elseif strCommand == "Device Pong" then
    local size = #(tostring(tParams.PAYLOAD or ""))
    spike_log("Device Pong seq=" .. tostring(tParams.SEQ) .. " bytes=" .. size)
    C4:UpdateProperty(SPIKE_PROP_LAST_PONG, "seq " .. tostring(tParams.SEQ) .. " (" .. size .. " bytes, device)")
  else
    spike_log("WARN: unknown command: " .. tostring(strCommand))
  end
end

function OnDriverInit(driver_init_type)
  C4:UpdateProperty("Driver Version", SPIKE_CLOUD_VERSION)
  spike_log("OnDriverInit: " .. SPIKE_CLOUD_VERSION .. " (" .. tostring(driver_init_type) .. ")")
  spike_restore_binding()
end

function OnDriverLateInit(driver_init_type)
  spike_log("OnDriverLateInit: " .. SPIKE_CLOUD_VERSION .. " (" .. tostring(driver_init_type) .. ")")
  C4:UpdateProperty("Driver Version", SPIKE_CLOUD_VERSION)
  spike_restore_binding()
  spike_log("runtime ready")
end

function OnDriverDestroyed()
  spike_log("OnDriverDestroyed")
end
