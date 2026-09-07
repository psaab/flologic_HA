-- ============================================================================
-- c4/src/json.lua — minimal JSON encoder/decoder for Control4 (Lua 5.1 safe).
--
-- Bundling rule: this file defines the global JSON table only. No require,
-- no return, no top-level execution, no Lua 5.2+ features (no \x escapes,
-- no bitwise operators, no string.pack, no table.pack).
-- ============================================================================

JSON = {}

-- Sentinel for explicit JSON null in encoded output (Lua nil cannot occupy
-- an array slot). Decoded nulls still arrive as nil (absent key). Sessions
-- are always cancelled across a reload, so no live value can carry a stale
-- sentinel from a previous bundle evaluation.
JSON.null = {}

local function is_array(t)
  local count = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
      return false
    end
    count = count + 1
  end
  if count == 0 then
    return true -- empty table encodes as []; our protocol never needs {}.
  end
  for i = 1, count do
    if t[i] == nil then
      return false
    end
  end
  return true
end

local escapes = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\008"] = "\\b",
  ["\012"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

function JSON.encode(value)
  if value == JSON.null then
    return "null"
  end
  local vtype = type(value)
  if vtype == "nil" then
    return "null"
  elseif vtype == "boolean" then
    return value and "true" or "false"
  elseif vtype == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      error("JSON cannot encode NaN or infinity")
    end
    return string.format("%.14g", value)
  elseif vtype == "string" then
    return '"'
      .. value:gsub('[%z\001-\031\\"]', function(ch)
        return escapes[ch] or string.format("\\u%04x", string.byte(ch))
      end)
      .. '"'
  elseif vtype == "table" then
    local parts = {}
    if is_array(value) then
      for i = 1, #value do
        parts[#parts + 1] = JSON.encode(value[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, v in pairs(value) do
      if type(k) ~= "string" then
        error("JSON object keys must be strings")
      end
      parts[#parts + 1] = JSON.encode(k) .. ":" .. JSON.encode(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("JSON cannot encode type " .. vtype)
end

local function utf8_encode(code)
  if code < 128 then
    return string.char(code)
  elseif code < 2048 then
    return string.char(192 + math.floor(code / 64), 128 + (code % 64))
  elseif code < 65536 then
    return string.char(224 + math.floor(code / 4096), 128 + (math.floor(code / 64) % 64), 128 + (code % 64))
  end
  return string.char(
    240 + math.floor(code / 262144),
    128 + (math.floor(code / 4096) % 64),
    128 + (math.floor(code / 64) % 64),
    128 + (code % 64)
  )
end

local function new_decoder(text)
  local pos = 1
  local len = #text
  local decode_value -- forward declaration for recursion

  local function fail(msg)
    error("JSON decode error at byte " .. pos .. ": " .. msg)
  end

  local function skip_ws()
    while pos <= len do
      local ch = text:sub(pos, pos)
      if ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then
        pos = pos + 1
      else
        break
      end
    end
  end

  local function decode_string()
    -- pos is on the opening quote.
    pos = pos + 1
    local parts = {}
    while true do
      if pos > len then
        fail("unterminated string")
      end
      local ch = text:sub(pos, pos)
      if ch == '"' then
        pos = pos + 1
        return table.concat(parts)
      elseif ch == "\\" then
        local esc = text:sub(pos + 1, pos + 1)
        if esc == '"' or esc == "\\" or esc == "/" then
          parts[#parts + 1] = esc
          pos = pos + 2
        elseif esc == "b" then
          parts[#parts + 1] = "\008"
          pos = pos + 2
        elseif esc == "f" then
          parts[#parts + 1] = "\012"
          pos = pos + 2
        elseif esc == "n" then
          parts[#parts + 1] = "\n"
          pos = pos + 2
        elseif esc == "r" then
          parts[#parts + 1] = "\r"
          pos = pos + 2
        elseif esc == "t" then
          parts[#parts + 1] = "\t"
          pos = pos + 2
        elseif esc == "u" then
          local hex = text:sub(pos + 2, pos + 5)
          local code = tonumber(hex, 16)
          if code == nil then
            fail("bad \\u escape")
          end
          pos = pos + 6
          if code >= 55296 and code <= 56319 then
            -- High surrogate: expect a low surrogate next.
            if text:sub(pos, pos + 1) ~= "\\u" then
              fail("lone high surrogate")
            end
            local low = tonumber(text:sub(pos + 2, pos + 5), 16)
            if low == nil or low < 56320 or low > 57343 then
              fail("bad low surrogate")
            end
            pos = pos + 6
            code = 65536 + (code - 55296) * 1024 + (low - 56320)
          end
          parts[#parts + 1] = utf8_encode(code)
        else
          fail("bad escape \\" .. esc)
        end
      else
        parts[#parts + 1] = ch
        pos = pos + 1
      end
    end
  end

  local function decode_number()
    local numtext = text:match("^%-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if numtext == nil or numtext == "" or numtext == "-" then
      fail("bad number")
    end
    -- Reject malformed tails like "1e" or "1." that the pattern may accept.
    if numtext:match("[eE][+-]?$") or numtext:match("%.$") then
      fail("bad number")
    end
    pos = pos + #numtext
    local num = tonumber(numtext)
    if num == nil then
      fail("bad number")
    end
    return num
  end

  local function decode_array()
    -- pos is on '['.
    pos = pos + 1
    local arr = {}
    skip_ws()
    if text:sub(pos, pos) == "]" then
      pos = pos + 1
      return arr
    end
    while true do
      arr[#arr + 1] = decode_value()
      skip_ws()
      local ch = text:sub(pos, pos)
      if ch == "]" then
        pos = pos + 1
        return arr
      elseif ch ~= "," then
        fail("expected ',' or ']' in array")
      end
      pos = pos + 1
    end
  end

  local function decode_object()
    -- pos is on '{'.
    pos = pos + 1
    local obj = {}
    skip_ws()
    if text:sub(pos, pos) == "}" then
      pos = pos + 1
      return obj
    end
    while true do
      skip_ws()
      if text:sub(pos, pos) ~= '"' then
        fail("expected string key in object")
      end
      local key = decode_string()
      skip_ws()
      if text:sub(pos, pos) ~= ":" then
        fail("expected ':' in object")
      end
      pos = pos + 1
      obj[key] = decode_value()
      skip_ws()
      local ch = text:sub(pos, pos)
      if ch == "}" then
        pos = pos + 1
        return obj
      elseif ch ~= "," then
        fail("expected ',' or '}' in object")
      end
      pos = pos + 1
    end
  end

  decode_value = function()
    skip_ws()
    if pos > len then
      fail("unexpected end of input")
    end
    local ch = text:sub(pos, pos)
    if ch == "{" then
      return decode_object()
    elseif ch == "[" then
      return decode_array()
    elseif ch == '"' then
      return decode_string()
    elseif ch == "t" and text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif ch == "f" and text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif ch == "n" and text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    elseif ch == "-" or (ch >= "0" and ch <= "9") then
      return decode_number()
    end
    fail("unexpected character '" .. ch .. "'")
  end

  return {
    run = function()
      local value = decode_value()
      skip_ws()
      if pos <= len then
        fail("trailing data")
      end
      return value
    end,
  }
end

function JSON.decode(text)
  if type(text) ~= "string" then
    error("JSON.decode expects a string")
  end
  return new_decoder(text).run()
end
