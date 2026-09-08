-- ============================================================================
-- c4/shared/flologic_link.lua — versioned cloud<->valve link protocol.
--
-- Single source of truth for the cloud/valve BindMessage contract, bundled
-- into both drivers (plan D7). Pure logic only: defines the global
-- FloLogicLink table plus the FLOGIC_LINK_VERSION global. No require, no
-- return, no top-level execution, no C4 globals. Lua 5.1 safe (no bitwise
-- operators: the digest uses arithmetic 32-bit helpers).
--
-- Wire form: every link message travels as a flat BindMessage params table
-- whose values are all strings:
--   FLOGIC_V     protocol version, currently "1"
--   FLOGIC_MSG   one of the MSG_* names below
--   FLOGIC_BODY  payload string (state/command field block, or the raw
--                valve id for FLOGIC_IDENTITY); "" when the message
--                carries no body
--   FLOGIC_HASH  hex digest of FLOGIC_BODY for FLOGIC_STATE (integrity
--                check on full sends; identity of the unseen body on
--                digest-only sends)
--   FLOGIC_CMD   command correlation id for COMMAND / CMD_ACK / CMD_NACK
--   FLOGIC_TRUNC "1" when a FLOGIC_STATE envelope carries a digest instead
--                of the full body (see the digest-fallback note below)
--   FLOGIC_ERROR human-readable nack reason for FLOGIC_CMD_NACK
--
-- Digest fallback: a full valve_state body always fits the budget in
-- practice (see flologic_link.md for the measured worst case), but a
-- pathological state (oversized name/uuid passthrough) must never wedge
-- the link. build_state therefore degrades: when the encoded body exceeds
-- MAX_BODY_BYTES it emits a digest-only envelope (empty body, TRUNC set,
-- HASH of the full body) instead of failing. The valve keeps its last
-- full state, marks the link degraded, and may retry with FLOGIC_GET_STATE.
-- ============================================================================

FloLogicLink = {}

-- Protocol version. Both drivers reject envelopes whose FLOGIC_V differs.
FLOGIC_LINK_VERSION = 1
FloLogicLink.VERSION = FLOGIC_LINK_VERSION

-- Message names. Valve->cloud and cloud->valve sets are disjoint by design
-- so a misrouted message fails closed in parse.
FloLogicLink.MSG_HELLO = "FLOGIC_HELLO"
FloLogicLink.MSG_GET_STATE = "FLOGIC_GET_STATE"
FloLogicLink.MSG_COMMAND = "FLOGIC_COMMAND"
FloLogicLink.MSG_IDENTITY = "FLOGIC_IDENTITY"
FloLogicLink.MSG_STATE = "FLOGIC_STATE"
FloLogicLink.MSG_CMD_ACK = "FLOGIC_CMD_ACK"
FloLogicLink.MSG_CMD_NACK = "FLOGIC_CMD_NACK"

FloLogicLink.VALVE_TO_CLOUD = {
  FloLogicLink.MSG_HELLO,
  FloLogicLink.MSG_GET_STATE,
  FloLogicLink.MSG_COMMAND,
}
FloLogicLink.CLOUD_TO_VALVE = {
  FloLogicLink.MSG_IDENTITY,
  FloLogicLink.MSG_STATE,
  FloLogicLink.MSG_CMD_ACK,
  FloLogicLink.MSG_CMD_NACK,
}

-- Wire keys (BindMessage params are flat string tables).
FloLogicLink.K_VERSION = "FLOGIC_V"
FloLogicLink.K_MSG = "FLOGIC_MSG"
FloLogicLink.K_BODY = "FLOGIC_BODY"
FloLogicLink.K_HASH = "FLOGIC_HASH"
FloLogicLink.K_CMD = "FLOGIC_CMD"
FloLogicLink.K_TRUNC = "FLOGIC_TRUNC"
FloLogicLink.K_ERROR = "FLOGIC_ERROR"

-- Budgets and field caps. MAX_BODY_BYTES is the BindMessage-safe budget a
-- full valve_state body must fit; anything larger degrades to a digest.
FloLogicLink.MAX_BODY_BYTES = 4096
FloLogicLink.MAX_VALVE_ID_LEN = 128
FloLogicLink.MAX_CMD_ID_LEN = 64
FloLogicLink.MAX_ACTION_LEN = 64
FloLogicLink.MAX_ERROR_LEN = 256

-- valve_state string fields with per-field caps; number fields are capped
-- by the body budget instead.
FloLogicLink.STATE_STRING_FIELDS = { uuid = 128, name = 128, device_type = 64 }
FloLogicLink.STATE_NUMBER_FIELDS = {
  flow_state = true,
  home_interval = true,
  away_interval = true,
  bypass_time = true,
  access = true,
  updated = true,
}

local KNOWN_MESSAGES = {
  [FloLogicLink.MSG_HELLO] = true,
  [FloLogicLink.MSG_GET_STATE] = true,
  [FloLogicLink.MSG_COMMAND] = true,
  [FloLogicLink.MSG_IDENTITY] = true,
  [FloLogicLink.MSG_STATE] = true,
  [FloLogicLink.MSG_CMD_ACK] = true,
  [FloLogicLink.MSG_CMD_NACK] = true,
}

local VALVE_TO_CLOUD = {
  [FloLogicLink.MSG_HELLO] = true,
  [FloLogicLink.MSG_GET_STATE] = true,
  [FloLogicLink.MSG_COMMAND] = true,
}

local CLOUD_TO_VALVE = {
  [FloLogicLink.MSG_IDENTITY] = true,
  [FloLogicLink.MSG_STATE] = true,
  [FloLogicLink.MSG_CMD_ACK] = true,
  [FloLogicLink.MSG_CMD_NACK] = true,
}

-- --- Small validators (all return true/false, never raise). ---

local function is_finite_number(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function is_clean_text(value, max_len)
  if type(value) ~= "string" then
    return false
  end
  if #value == 0 or #value > max_len then
    return false
  end
  for i = 1, #value do
    local byte = value:byte(i)
    if byte < 32 or byte == 127 then
      return false
    end
  end
  return true
end

local function is_field_key(key)
  return type(key) == "string" and key:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function is_scalar(value)
  local kind = type(value)
  if kind == "string" or kind == "boolean" then
    return true
  end
  return is_finite_number(value)
end

-- --- 32-bit arithmetic helpers (Lua 5.1 has no bitwise operators). ---

local function xor32(a, b)
  local result, bit = 0, 1
  for _ = 1, 32 do
    if (a % 2) ~= (b % 2) then
      result = result + bit
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit = bit * 2
  end
  return result
end

local function mul32(a, b)
  -- 16-bit halves keep every intermediate product below 2^53 (double-exact).
  local a0, a1 = a % 65536, math.floor(a / 65536)
  local b0, b1 = b % 65536, math.floor(b / 65536)
  return (((a1 * b0 + a0 * b1) % 65536) * 65536 + a0 * b0) % 4294967296
end

-- FNV-1a 32-bit digest, hex-encoded. Dependency-free so both drivers and
-- the lua5.1 suite compute identical hashes without C4:Hash.
function FloLogicLink.digest(body)
  if type(body) ~= "string" then
    return nil, "digest-needs-string"
  end
  local hash = 2166136261
  for i = 1, #body do
    hash = mul32(xor32(hash, body:byte(i)), 16777619)
  end
  return string.format("%08x", hash)
end

-- --- Flat field-block codec (JSON-object subset, sorted keys). ---
-- Bodies carry only flat string-keyed scalar tables, so the codec rejects
-- nesting, nulls, arrays, and anything trailing the single object. Key
-- order is canonical (sorted) to keep digests stable across drivers.

local function encode_string(value)
  local out = { '"' }
  for i = 1, #value do
    local byte = value:byte(i)
    if byte == 34 then
      out[#out + 1] = '\\"'
    elseif byte == 92 then
      out[#out + 1] = "\\\\"
    elseif byte == 10 then
      out[#out + 1] = "\\n"
    elseif byte == 13 then
      out[#out + 1] = "\\r"
    elseif byte == 9 then
      out[#out + 1] = "\\t"
    elseif byte == 8 then
      out[#out + 1] = "\\b"
    elseif byte == 12 then
      out[#out + 1] = "\\f"
    elseif byte < 32 or byte == 127 then
      out[#out + 1] = string.format("\\u%04x", byte)
    else
      out[#out + 1] = value:sub(i, i)
    end
  end
  out[#out + 1] = '"'
  return table.concat(out)
end

local function encode_value(value)
  local kind = type(value)
  if kind == "string" then
    return encode_string(value)
  elseif kind == "boolean" then
    if value then
      return "true"
    end
    return "false"
  end
  return tostring(value)
end

function FloLogicLink.encode_fields(fields)
  if type(fields) ~= "table" then
    return nil, "fields-not-table"
  end
  local keys = {}
  for key, value in pairs(fields) do
    if not is_field_key(key) then
      return nil, "bad-field-key"
    end
    if not is_scalar(value) then
      return nil, "bad-field-value:" .. tostring(key)
    end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = encode_string(key) .. ":" .. encode_value(fields[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Decodes exactly what encode_fields emits: one flat object of string keys
-- to string/number/boolean values. Returns the table or nil plus an error.
function FloLogicLink.decode_fields(body)
  if type(body) ~= "string" then
    return nil, "body-not-string"
  end
  local pos, len = 1, #body
  local function skip_space()
    while pos <= len and body:sub(pos, pos):match("%s") ~= nil do
      pos = pos + 1
    end
  end
  local function parse_string()
    if body:sub(pos, pos) ~= '"' then
      return nil, "expected-string"
    end
    pos = pos + 1
    local out = {}
    while pos <= len do
      local char = body:sub(pos, pos)
      if char == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif char == "\\" then
        local esc = body:sub(pos + 1, pos + 1)
        if esc == '"' or esc == "\\" or esc == "/" then
          out[#out + 1] = esc
          pos = pos + 2
        elseif esc == "n" then
          out[#out + 1] = "\n"
          pos = pos + 2
        elseif esc == "r" then
          out[#out + 1] = "\r"
          pos = pos + 2
        elseif esc == "t" then
          out[#out + 1] = "\t"
          pos = pos + 2
        elseif esc == "b" then
          out[#out + 1] = "\008"
          pos = pos + 2
        elseif esc == "f" then
          out[#out + 1] = "\012"
          pos = pos + 2
        elseif esc == "u" then
          local hex = body:sub(pos + 2, pos + 5)
          local code = tonumber(hex, 16)
          if hex:match("^%x%x%x%x$") == nil or code == nil then
            return nil, "bad-unicode-escape"
          end
          if code < 128 then
            out[#out + 1] = string.char(code)
          elseif code < 2048 then
            out[#out + 1] = string.char(192 + math.floor(code / 64), 128 + (code % 64))
          else
            out[#out + 1] =
              string.char(224 + math.floor(code / 4096), 128 + (math.floor(code / 64) % 64), 128 + (code % 64))
          end
          pos = pos + 6
        else
          return nil, "bad-escape"
        end
      elseif char:byte() < 32 then
        return nil, "raw-control-char"
      else
        out[#out + 1] = char
        pos = pos + 1
      end
    end
    return nil, "unterminated-string"
  end
  local function parse_value()
    local char = body:sub(pos, pos)
    if char == '"' then
      return parse_string()
    end
    if body:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    end
    if body:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    end
    local digits = body:sub(pos):match("^(-?%d+%.?%d*[eE]?[+-]?%d*)")
    if digits == nil or #digits == 0 then
      return nil, "unsupported-value"
    end
    -- Canonical numbers never carry a leading zero (the encoder uses
    -- tostring), so "01" is malformed rather than 1.
    if digits:match("^%-?0%d") ~= nil then
      return nil, "bad-number"
    end
    -- A bare "-" or a trailing exponent marker is not a number.
    local number = tonumber(digits)
    if number == nil then
      return nil, "bad-number"
    end
    pos = pos + #digits
    return number
  end
  skip_space()
  if body:sub(pos, pos) ~= "{" then
    return nil, "not-an-object"
  end
  pos = pos + 1
  local fields = {}
  skip_space()
  if body:sub(pos, pos) == "}" then
    pos = pos + 1
    skip_space()
    if pos <= len then
      return nil, "trailing-data"
    end
    return fields
  end
  while true do
    skip_space()
    local key, key_err = parse_string()
    if key == nil then
      return nil, key_err
    end
    if not is_field_key(key) then
      return nil, "bad-field-key"
    end
    if fields[key] ~= nil then
      return nil, "duplicate-key"
    end
    skip_space()
    if body:sub(pos, pos) ~= ":" then
      return nil, "expected-colon"
    end
    pos = pos + 1
    skip_space()
    local value, value_err = parse_value()
    if value == nil and value_err ~= nil then
      return nil, value_err
    end
    fields[key] = value
    skip_space()
    local sep = body:sub(pos, pos)
    if sep == "," then
      pos = pos + 1
    elseif sep == "}" then
      pos = pos + 1
      skip_space()
      if pos <= len then
        return nil, "trailing-data"
      end
      return fields
    else
      return nil, "expected-separator"
    end
  end
end

-- --- valve_state body helpers. ---
-- Canonical state shape: id/mode/online required; the documented optional
-- scalars below; anything else rejected so a renamed cloud field fails
-- loudly instead of silently dropping.

local function check_state_fields(fields)
  if type(fields) ~= "table" then
    return nil, "state-not-table"
  end
  local id = fields.id
  if type(id) == "number" then
    if not is_finite_number(id) then
      return nil, "bad-state-id"
    end
    id = tostring(id)
  end
  if not is_clean_text(id, FloLogicLink.MAX_VALVE_ID_LEN) then
    return nil, "bad-state-id"
  end
  if not is_finite_number(fields.mode) then
    return nil, "bad-state-mode"
  end
  if type(fields.online) ~= "boolean" then
    return nil, "bad-state-online"
  end
  for name, cap in pairs(FloLogicLink.STATE_STRING_FIELDS) do
    local value = fields[name]
    if value ~= nil then
      if type(value) ~= "string" or #value > cap then
        return nil, "bad-state-field:" .. name
      end
    end
  end
  for name in pairs(FloLogicLink.STATE_NUMBER_FIELDS) do
    if fields[name] ~= nil and not is_finite_number(fields[name]) then
      return nil, "bad-state-field:" .. name
    end
  end
  for key in pairs(fields) do
    if
      key ~= "id"
      and key ~= "mode"
      and key ~= "online"
      and FloLogicLink.STATE_STRING_FIELDS[key] == nil
      and FloLogicLink.STATE_NUMBER_FIELDS[key] == nil
    then
      return nil, "unknown-state-field:" .. tostring(key)
    end
  end
  return true
end

-- Validates a state table and returns its canonical encoded body.
function FloLogicLink.build_state_body(state)
  local ok, err = check_state_fields(state)
  if not ok then
    return nil, err
  end
  local fields = { id = tostring(state.id), mode = state.mode, online = state.online }
  for name in pairs(FloLogicLink.STATE_STRING_FIELDS) do
    if state[name] ~= nil then
      fields[name] = state[name]
    end
  end
  for name in pairs(FloLogicLink.STATE_NUMBER_FIELDS) do
    if state[name] ~= nil then
      fields[name] = state[name]
    end
  end
  return FloLogicLink.encode_fields(fields)
end

-- Decodes and validates a state body back into a state table.
function FloLogicLink.parse_state_body(body)
  local fields, err = FloLogicLink.decode_fields(body)
  if fields == nil then
    return nil, err
  end
  local ok, check_err = check_state_fields(fields)
  if not ok then
    return nil, check_err
  end
  return fields
end

-- --- Envelope builders. ---
-- Each returns a flat string-valued params table ready for SendToProxy (or
-- SendToDevice fallback), or nil plus an error. Builders never emit a body
-- larger than MAX_BODY_BYTES except through the documented digest path.

local function base_envelope(msg)
  return { [FloLogicLink.K_VERSION] = tostring(FloLogicLink.VERSION), [FloLogicLink.K_MSG] = msg }
end

local function check_cmd_id(cmd_id)
  if type(cmd_id) == "number" then
    if not is_finite_number(cmd_id) then
      return nil, "bad-cmd-id"
    end
    cmd_id = tostring(cmd_id)
  end
  if not is_clean_text(cmd_id, FloLogicLink.MAX_CMD_ID_LEN) then
    return nil, "bad-cmd-id"
  end
  return cmd_id
end

local function check_valve_id(valve_id)
  if type(valve_id) == "number" then
    if not is_finite_number(valve_id) then
      return nil, "bad-valve-id"
    end
    valve_id = tostring(valve_id)
  end
  if not is_clean_text(valve_id, FloLogicLink.MAX_VALVE_ID_LEN) then
    return nil, "bad-valve-id"
  end
  return valve_id
end

-- Valve->cloud: handshake opener sent on every bind (D3). The persisted id
-- is never trusted across binds, so hello carries no identity claim.
function FloLogicLink.build_hello()
  return base_envelope(FloLogicLink.MSG_HELLO)
end

-- Valve->cloud: poll the cloud for the latest state outside the fan-out.
function FloLogicLink.build_get_state()
  return base_envelope(FloLogicLink.MSG_GET_STATE)
end

-- Cloud->valve: answer to hello; binds this link slot to one valve id.
function FloLogicLink.build_identity(valve_id)
  local id, err = check_valve_id(valve_id)
  if id == nil then
    return nil, err
  end
  local env = base_envelope(FloLogicLink.MSG_IDENTITY)
  env[FloLogicLink.K_BODY] = id
  return env
end

-- Valve->cloud: forward one programming action. Action names stay open
-- (units 2-3 own the vocabulary); params is an optional flat scalar
-- table using the same field rules as state bodies.
function FloLogicLink.build_command(cmd_id, action, params)
  local id, id_err = check_cmd_id(cmd_id)
  if id == nil then
    return nil, id_err
  end
  if not is_clean_text(action, FloLogicLink.MAX_ACTION_LEN) then
    return nil, "bad-action"
  end
  local fields = { action = action }
  if params ~= nil then
    if type(params) ~= "table" then
      return nil, "params-not-table"
    end
    for key, value in pairs(params) do
      if key == "action" then
        return nil, "param-clash:action"
      end
      if not is_field_key(key) then
        return nil, "bad-param-key"
      end
      if not is_scalar(value) then
        return nil, "bad-param-value:" .. tostring(key)
      end
      fields[key] = value
    end
  end
  local body, body_err = FloLogicLink.encode_fields(fields)
  if body == nil then
    return nil, body_err
  end
  if #body > FloLogicLink.MAX_BODY_BYTES then
    return nil, "command-body-oversize"
  end
  local env = base_envelope(FloLogicLink.MSG_COMMAND)
  env[FloLogicLink.K_CMD] = id
  env[FloLogicLink.K_BODY] = body
  return env
end

-- Cloud->valve: per-valve snapshot slice plus access flags. Oversized
-- bodies degrade to a digest-only envelope instead of failing: TRUNC is
-- set, BODY is empty, and HASH identifies the unseen full body.
function FloLogicLink.build_state(state)
  local body, err = FloLogicLink.build_state_body(state)
  if body == nil then
    return nil, err
  end
  local env = base_envelope(FloLogicLink.MSG_STATE)
  env[FloLogicLink.K_HASH] = FloLogicLink.digest(body)
  if #body > FloLogicLink.MAX_BODY_BYTES then
    env[FloLogicLink.K_BODY] = ""
    env[FloLogicLink.K_TRUNC] = "1"
    return env
  end
  env[FloLogicLink.K_BODY] = body
  return env
end

-- Cloud->valve: positive acknowledgement echoing the command id.
function FloLogicLink.build_ack(cmd_id)
  local id, err = check_cmd_id(cmd_id)
  if id == nil then
    return nil, err
  end
  local env = base_envelope(FloLogicLink.MSG_CMD_ACK)
  env[FloLogicLink.K_CMD] = id
  return env
end

-- Cloud->valve: negative acknowledgement echoing the command id plus a
-- human-readable reason (authorization, queue, or cloud failure).
function FloLogicLink.build_nack(cmd_id, reason)
  local id, err = check_cmd_id(cmd_id)
  if id == nil then
    return nil, err
  end
  if not is_clean_text(reason, FloLogicLink.MAX_ERROR_LEN) then
    return nil, "bad-reason"
  end
  local env = base_envelope(FloLogicLink.MSG_CMD_NACK)
  env[FloLogicLink.K_CMD] = id
  env[FloLogicLink.K_ERROR] = reason
  return env
end

-- --- Envelope parser. ---
-- Validates a received params table and returns a message table:
--   { version, msg, cmd_id, body, hash, truncated, error_reason,
--     valve_id, fields }
-- absent slots stay nil. Digest-only state parses to truncated=true with
-- fields=nil. Returns nil plus one of: envelope-not-table,
-- version-mismatch, unknown-message, body-not-string, oversize-body,
-- bad-valve-id, bad-cmd-id, bad-reason, bad-action, bad-param-value:<key>,
-- digest-missing, hash-mismatch, or any decode_fields / state-field error.

function FloLogicLink.parse(params)
  if type(params) ~= "table" then
    return nil, "envelope-not-table"
  end
  if tonumber(params[FloLogicLink.K_VERSION]) ~= FloLogicLink.VERSION then
    return nil, "version-mismatch"
  end
  local msg = params[FloLogicLink.K_MSG]
  if type(msg) ~= "string" or KNOWN_MESSAGES[msg] == nil then
    return nil, "unknown-message"
  end
  local body = params[FloLogicLink.K_BODY]
  if body == nil then
    body = ""
  end
  if type(body) ~= "string" then
    return nil, "body-not-string"
  end
  if #body > FloLogicLink.MAX_BODY_BYTES then
    return nil, "oversize-body"
  end
  local out = {
    version = FloLogicLink.VERSION,
    msg = msg,
    cmd_id = nil,
    body = body,
    hash = params[FloLogicLink.K_HASH],
    truncated = false,
    error_reason = nil,
    valve_id = nil,
    fields = nil,
  }
  if out.hash ~= nil and type(out.hash) ~= "string" then
    return nil, "bad-hash"
  end
  if msg == FloLogicLink.MSG_HELLO or msg == FloLogicLink.MSG_GET_STATE then
    return out
  end
  if msg == FloLogicLink.MSG_IDENTITY then
    local id, err = check_valve_id(body)
    if id == nil then
      return nil, err
    end
    out.valve_id = id
    return out
  end
  if msg == FloLogicLink.MSG_CMD_ACK or msg == FloLogicLink.MSG_CMD_NACK then
    local id, err = check_cmd_id(params[FloLogicLink.K_CMD])
    if id == nil then
      return nil, err
    end
    out.cmd_id = id
    if msg == FloLogicLink.MSG_CMD_NACK then
      local reason = params[FloLogicLink.K_ERROR]
      if not is_clean_text(reason, FloLogicLink.MAX_ERROR_LEN) then
        return nil, "bad-reason"
      end
      out.error_reason = reason
    end
    return out
  end
  if msg == FloLogicLink.MSG_COMMAND then
    local id, err = check_cmd_id(params[FloLogicLink.K_CMD])
    if id == nil then
      return nil, err
    end
    out.cmd_id = id
    local fields, fields_err = FloLogicLink.decode_fields(body)
    if fields == nil then
      return nil, fields_err
    end
    -- Overflow spellings ("1e999") decode to inf, which no cloud range
    -- check should ever see: screen non-finite numbers at the gate.
    for key, value in pairs(fields) do
      if type(value) == "number" and (value ~= value or value == math.huge or value == -math.huge) then
        return nil, "bad-param-value:" .. tostring(key)
      end
    end
    if not is_clean_text(fields.action, FloLogicLink.MAX_ACTION_LEN) then
      return nil, "bad-action"
    end
    out.fields = fields
    return out
  end
  -- MSG_STATE: digest-only envelopes carry the hash without the body.
  if params[FloLogicLink.K_TRUNC] == "1" then
    if type(out.hash) ~= "string" or #out.hash == 0 then
      return nil, "digest-missing"
    end
    out.truncated = true
    out.body = ""
    return out
  end
  local fields, fields_err = FloLogicLink.parse_state_body(body)
  if fields == nil then
    return nil, fields_err
  end
  if out.hash ~= nil and out.hash ~= "" and out.hash ~= FloLogicLink.digest(body) then
    return nil, "hash-mismatch"
  end
  out.fields = fields
  return out
end

-- Direction predicates so each driver can fail closed on misrouted traffic.
function FloLogicLink.is_valve_to_cloud(msg)
  return VALVE_TO_CLOUD[msg] == true
end

function FloLogicLink.is_cloud_to_valve(msg)
  return CLOUD_TO_VALVE[msg] == true
end
