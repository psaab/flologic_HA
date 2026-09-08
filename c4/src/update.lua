-- GitHub release discovery. Installation remains a Composer operation.
FloUpdate = {}
FloUpdate.REPOSITORY = "psaab/flologic_HA"
FloUpdate.ASSET = "flologic_valve.c4z"
FloUpdate.API_URL = "https://api.github.com/repos/" .. FloUpdate.REPOSITORY .. "/releases?per_page=100"

--- Ignore HA releases, drafts, prereleases, and releases without the C4 asset.
function FloUpdate.select_release(releases)
  if type(releases) ~= "table" or releases.message ~= nil then
    return nil, "Invalid GitHub release response"
  end
  local best
  for _, release in ipairs(releases) do
    if type(release) == "table" and not release.draft and not release.prerelease then
      local tag = release.tag_name
      local version = type(tag) == "string" and tag:match("^c4%-v(%d%d%d%d%d%d%d%d%d%d)$")
      if version and type(release.assets) == "table" then
        local expected = "https://github.com/"
          .. FloUpdate.REPOSITORY
          .. "/releases/download/"
          .. tag
          .. "/"
          .. FloUpdate.ASSET
        for _, asset in ipairs(release.assets) do
          if type(asset) == "table" and asset.name == FloUpdate.ASSET and asset.browser_download_url == expected then
            if not best or version > best.version then
              best = { version = version, url = expected }
            end
          end
        end
      end
    end
  end
  return best
end

--- A cancellable, report-only check; callbacks never run after cancel/reload.
function FloUpdate.new_check(opts)
  local self = { done = false }
  function self.cancel()
    self.done = true
    if self.cancel_timer then
      pcall(self.cancel_timer)
      self.cancel_timer = nil
    end
    if self.cancel_http then
      pcall(self.cancel_http)
      self.cancel_http = nil
    end
  end
  local function finish(err, release)
    if self.done then
      return
    end
    self.cancel()
    opts.on_result(err, release)
  end
  function self.start()
    if self.done or self.started then
      return
    end
    self.started = true
    self.cancel_timer = opts.set_timeout(35000, function()
      finish("GitHub request timed out")
    end)
    local ok, cancel = pcall(opts.http_get, FloUpdate.API_URL, {
      Accept = "application/vnd.github+json",
      ["User-Agent"] = "FloLogic-Control4",
      ["X-GitHub-Api-Version"] = "2022-11-28",
    }, function(err, body, code)
      if self.done then
        return
      end
      if err then
        finish("GitHub request failed")
        return
      end
      if code == 403 or code == 429 then
        finish("GitHub rate limited or denied the request; try later")
        return
      end
      if code ~= 200 then
        finish("GitHub HTTP " .. tostring(code))
        return
      end
      if type(body) ~= "string" or #body > 1048576 then
        finish("Invalid GitHub response size")
        return
      end
      local decoded, releases = pcall(JSON.decode, body)
      if not decoded then
        finish("Invalid GitHub JSON")
        return
      end
      local release, reason = FloUpdate.select_release(releases)
      finish(reason, release)
    end)
    if not ok then
      finish("GitHub transport unavailable")
      return
    end
    if self.done then
      if cancel then
        pcall(cancel)
      end
    else
      self.cancel_http = cancel
    end
  end
  return self
end

FloUpdate.C4Z_ROOT = "C4Z_ROOT"
FloUpdate.SOAP_HOST = "127.0.0.1"
FloUpdate.SOAP_PORT = 5020
FloUpdate.MAX_REDIRECTS = 5
FloUpdate.MAX_PACKAGE_BYTES = 8 * 1024 * 1024

--- Compare driver versions ("YYYYMMDDNN" date-numbers): -1, 0, or 1.
--- Falls back to lexicographic order for anything else.
function FloUpdate.compare_versions(a, b)
  local sa, sb = tostring(a or ""), tostring(b or "")
  if sa == sb then
    return 0
  end
  if sa:match("^%d+$") and sb:match("^%d+$") then
    if #sa ~= #sb then
      return #sa < #sb and -1 or 1
    end
    return sa < sb and -1 or 1
  end
  return sa < sb and -1 or 1
end

local function flo_update_xml_escape(value)
  return tostring(value or "")
    :gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub('"', "&quot;")
    :gsub("'", "&apos;")
end

--- Exact c4soap packet Composer's local endpoint installs by name.
--- NUL-terminated per the local protocol.
function FloUpdate.build_install_packet(filename)
  return '<c4soap async="0" category="composer" name="UpdateProjectC4i"'
    .. ' operation="RWX" session="0">'
    .. '<param name="name" type="string">'
    .. flo_update_xml_escape(filename)
    .. "</param></c4soap>\000"
end

--- A cancellable install operation; callbacks never run after cancel/reload.
--- Downloads the latest C4 asset, stages it in the C4Z file store (verified
--- by on-disk size plus a zip-magic read-back), and triggers Composer to
--- install it by name. force skips the version compare, so it can reinstall
--- the same build or even an older one; that is the intended recovery
--- semantic.
--- opts.http_get(url, headers, cb) has cb(err, body, code, headers_or_nil)
--- and returns a cancel function. opts.soap_send(packet, cb(err)) likewise.
--- File callbacks: get_installed() -> bool, file_set_dir(alias) -> ok,
--- file_exists(name) -> bool, file_delete(name), file_write(name, data),
--- file_size(name) -> bytes or nil, file_read(name, count) -> string or nil.
--- File callbacks must not throw; the Director adapter wraps every C4 file
--- call in pcall and converts denials to false/nil. opts.log_warn(msg)
--- traces download/stage/trigger milestones to the Lua log (default noop).
--- on_result(err, outcome) has outcome
--- { attempted = version|nil, latest = version|nil, skipped = reason|nil }.
function FloUpdate.new_install(opts)
  local self = { done = false }
  local log_warn = opts.log_warn or function() end
  function self.cancel()
    self.done = true
    if self.cancel_timer then
      pcall(self.cancel_timer)
      self.cancel_timer = nil
    end
    if self.cancel_http then
      pcall(self.cancel_http)
      self.cancel_http = nil
    end
    if self.cancel_soap then
      pcall(self.cancel_soap)
      self.cancel_soap = nil
    end
  end
  local function finish(err, outcome)
    if self.done then
      return
    end
    self.cancel()
    opts.on_result(err, outcome)
  end
  local function progress(text)
    if not self.done and opts.on_progress then
      opts.on_progress(text)
    end
  end
  local function arm(ms, message)
    if self.cancel_timer then
      pcall(self.cancel_timer)
      self.cancel_timer = nil
    end
    self.cancel_timer = opts.set_timeout(ms, function()
      finish(message)
    end)
  end
  local function track_http(cancel)
    if self.done then
      if cancel then
        pcall(cancel)
      end
    else
      self.cancel_http = cancel
    end
  end
  local function get_releases(cb)
    arm(35000, "GitHub request timed out")
    local ok, cancel = pcall(opts.http_get, FloUpdate.API_URL, {
      Accept = "application/vnd.github+json",
      ["User-Agent"] = "FloLogic-Control4",
      ["X-GitHub-Api-Version"] = "2022-11-28",
    }, function(err, body, code)
      if self.done then
        return
      end
      self.cancel_http = nil
      if err then
        finish("GitHub request failed")
        return
      end
      if code == 403 or code == 429 then
        finish("GitHub rate limited or denied the request; try later")
        return
      end
      if code ~= 200 then
        finish("GitHub HTTP " .. tostring(code))
        return
      end
      if type(body) ~= "string" or #body > 1048576 then
        finish("Invalid GitHub response size")
        return
      end
      local decoded, releases = pcall(JSON.decode, body)
      if not decoded then
        finish("Invalid GitHub JSON")
        return
      end
      local release, reason = FloUpdate.select_release(releases)
      if not release then
        finish(reason or "No published C4 package found in recent releases")
        return
      end
      cb(release)
    end)
    if not ok then
      finish("GitHub transport unavailable")
      return
    end
    track_http(cancel)
  end
  local function download(url, redirects_left, cb)
    arm(120000, "Download timed out")
    local ok, cancel = pcall(opts.http_get, url, {}, function(err, body, code, headers)
      if self.done then
        return
      end
      self.cancel_http = nil
      if err then
        finish("Download failed")
        return
      end
      if code == 301 or code == 302 or code == 307 or code == 308 then
        local location = nil
        if type(headers) == "table" then
          for name, value in pairs(headers) do
            if tostring(name):lower() == "location" and value ~= "" then
              location = value
              break
            end
          end
        end
        if location == nil then
          finish("Asset redirect not followed by transport")
          return
        end
        if redirects_left <= 0 then
          finish("Too many download redirects")
          return
        end
        download(location, redirects_left - 1, cb)
        return
      end
      if code ~= 200 then
        finish("Download HTTP " .. tostring(code))
        return
      end
      if type(body) ~= "string" or #body < 1 then
        finish("Downloaded package is empty")
        return
      end
      if #body > FloUpdate.MAX_PACKAGE_BYTES then
        finish("Downloaded package is too large")
        return
      end
      log_warn("update download: " .. #body .. " bytes, HTTP " .. tostring(code))
      cb(body)
    end)
    if not ok then
      finish("Download transport unavailable")
      return
    end
    track_http(cancel)
  end
  local function stage(filename, body, cb)
    arm(30000, "Install staging timed out")
    -- Switch stores BEFORE deleting anything: on denial the installed file
    -- stays intact and no install is triggered. Falling through would write
    -- and verify against the wrong directory, then reinstall the unchanged
    -- old build as a silent no-op.
    progress("Staging " .. filename .. " (" .. #body .. " bytes)")
    local switched = opts.file_set_dir(FloUpdate.C4Z_ROOT)
    if not switched then
      finish("File store " .. FloUpdate.C4Z_ROOT .. " denied; installed driver left intact")
      return
    end
    if opts.file_exists(filename) then
      opts.file_delete(filename)
    end
    opts.file_write(filename, body)
    -- Never trust the write call: verify by on-disk SIZE (a number), not by
    -- re-reading the full binary that can false-mismatch through string
    -- marshalling. A 4-byte magic read-back additionally proves the staged
    -- file is a driver archive rather than an error page or truncation.
    if opts.file_size(filename) ~= #body then
      finish("Staged package size mismatch; stored package may be missing or incomplete; restore using Composer")
      return
    end
    if opts.file_read(filename, 4) ~= "PK\003\004" then
      log_warn("update stage: magic check failed for " .. filename)
      finish(
        "Staged package is not a driver archive; stored package may be missing or incomplete; restore using Composer"
      )
      return
    end
    log_warn("update stage: " .. filename .. " verified (" .. #body .. " bytes, zip magic ok)")
    cb()
  end
  function self.start()
    if self.done or self.started then
      return
    end
    self.started = true
    if not opts.get_installed() then
      finish(nil, { skipped = "not-installed" })
      return
    end
    get_releases(function(release)
      if not opts.force and FloUpdate.compare_versions(release.version, opts.current_version) <= 0 then
        finish(nil, { attempted = nil, latest = release.version, skipped = "up-to-date" })
        return
      end
      progress("Downloading " .. release.version)
      download(release.url, FloUpdate.MAX_REDIRECTS, function(body)
        stage(FloUpdate.ASSET, body, function()
          progress("Installing " .. release.version)
          arm(30000, "Install trigger timed out")
          log_warn("update trigger: UpdateProjectC4i " .. FloUpdate.ASSET)
          local ok, cancel = pcall(opts.soap_send, FloUpdate.build_install_packet(FloUpdate.ASSET), function(err)
            if self.done then
              return
            end
            self.cancel_soap = nil
            if err then
              log_warn("update trigger failed: " .. tostring(err))
              finish("Install trigger failed: " .. tostring(err))
              return
            end
            log_warn("update trigger sent for " .. release.version)
            finish(nil, { attempted = release.version, latest = release.version })
          end)
          if not ok then
            finish("Install trigger unavailable")
            return
          end
          if self.done then
            if cancel then
              pcall(cancel)
            end
          else
            self.cancel_soap = cancel
          end
        end)
      end)
    end)
  end
  return self
end
