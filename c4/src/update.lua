-- GitHub release discovery. Installation remains a Composer operation.
FloUpdate = {}
FloUpdate.REPOSITORY = "psaab/flologic_HA"
FloUpdate.ASSET = "flologic_valve.c4z"
FloUpdate.API_URL = "https://api.github.com/repos/" .. FloUpdate.REPOSITORY .. "/releases?per_page=100"
-- Split drivers set the whole lockstep family; a release missing a
-- sibling package is not a valid update source. Drivers that set no
-- family match their own asset only (legacy monolith behavior).
FloUpdate.FAMILY_ASSETS = nil

--- Ignore HA releases, drafts, prereleases, and releases without the C4 asset.
function FloUpdate.select_release(releases)
  if type(releases) ~= "table" or releases.message ~= nil then
    return nil, "Invalid GitHub release response"
  end
  local family = FloUpdate.FAMILY_ASSETS
  if type(family) ~= "table" or #family == 0 then
    family = { FloUpdate.ASSET }
  end
  local best
  for _, release in ipairs(releases) do
    if type(release) == "table" and not release.draft and not release.prerelease then
      local tag = release.tag_name
      local version = type(tag) == "string" and tag:match("^c4%-v(%d%d%d%d%d%d%d%d%d%d)$")
      if version and type(release.assets) == "table" then
        local urls, complete, our_size = {}, true, nil
        for _, name in ipairs(family) do
          local expected = "https://github.com/" .. FloUpdate.REPOSITORY .. "/releases/download/" .. tag .. "/" .. name
          local found = false
          for _, asset in ipairs(release.assets) do
            if type(asset) == "table" and asset.name == name and asset.browser_download_url == expected then
              found = true
              if name == FloUpdate.ASSET and type(asset.size) == "number" then
                our_size = asset.size
              end
              break
            end
          end
          if not found then
            complete = false
            break
          end
          urls[name] = expected
        end
        if complete and urls[FloUpdate.ASSET] ~= nil and (not best or version > best.version) then
          best = { version = version, url = urls[FloUpdate.ASSET], size = our_size }
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
-- Undocumented C4Z_ROOT unlock key (finitelabs/control4-mqtt
-- github-updater pattern, validated on live OS 3.4.3): FileSetDir
-- rejects the C4Z_ROOT alias until this key is passed, and
-- Director's UpdateProjectC4i hot-reload resolves staged packages in
-- C4Z_ROOT only — staging anywhere else verifies and triggers yet
-- reloads the previously installed build (0815 field no-op).
FloUpdate.C4Z_ROOT_UNLOCK_KEY = "c29tZXNwZWNpYWxrZXk=++11"
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
--- Downloads the latest C4 asset (screened by exact byte size plus an
--- archive-prefix check before any file is touched), stages it in the C4Z
--- file store via a validated separate candidate, replaces the installed
--- package by move with a backup (a known-good package survives every
--- step; any failure rolls back before reporting), and triggers Composer
--- to install it by name. Without a file move the installed package
--- cannot be preserved through replacement, so installs refuse before
--- touching anything. force skips the version compare, so it can
--- reinstall the same build or even an older one; that is the intended
--- recovery semantic.
--- opts.http_get(url, headers, cb) has cb(err, body, code, headers_or_nil)
--- and returns a cancel function. opts.soap_send(packet, cb(err)) likewise.
--- File callbacks: get_installed() -> bool, file_set_dir(alias) -> ok,
--- file_exists(name) -> bool, file_delete(name), file_write(name, data),
--- file_size(name) -> bytes or nil, file_read(name, count) -> string or nil,
--- file_move(from_name, to_name) -> bool (same store; REQUIRED).
--- File callbacks must not throw; the Director adapter wraps every C4 file
--- call in pcall and converts denials to false/nil. Every replacement
--- step is verified by filesystem state (existence + size), never by the
--- move call's return alone. opts.log_warn(msg) traces
--- download/stage/trigger milestones to the Lua log (default noop).
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
  local function download(url, redirects_left, expected_size, cb)
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
        download(location, redirects_left - 1, expected_size, cb)
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
      -- The transport delivers exact bytes (field-verified byte counts),
      -- so screen the body itself before any file is touched: a
      -- truncated download or an error page must never reach the store.
      if expected_size ~= nil and #body ~= expected_size then
        finish(
          "Downloaded package is incomplete ("
            .. #body
            .. " of "
            .. expected_size
            .. " bytes); installed driver left intact"
        )
        return
      end
      if body:sub(1, 2) ~= "PK" then
        finish("Downloaded package is not a driver archive; installed driver left intact")
        return
      end
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
    -- Without a file move the installed package cannot be preserved
    -- through replacement (delete + rewrite strands the controller when
    -- the rewrite fails). Refuse BEFORE touching anything, with explicit
    -- manual-update guidance: a self-update that can strand the
    -- controller without a driver is worse than no self-update.
    if opts.file_move == nil then
      finish(
        "This controller cannot replace the package safely (no file move); download "
          .. filename
          .. " from the GitHub release and update the driver in Composer"
      )
      return
    end
    -- Switch stores BEFORE touching anything: on denial the installed
    -- file stays intact and no install is triggered.
    progress("Staging " .. filename .. " (" .. #body .. " bytes)")
    local switched = opts.file_set_dir(FloUpdate.C4Z_ROOT)
    if not switched then
      finish("File store " .. FloUpdate.C4Z_ROOT .. " denied; installed driver left intact")
      return
    end
    local candidate = filename .. ".new"
    local backup = filename .. ".bak"
    if not opts.file_exists(filename) and opts.file_exists(backup) then
      -- A previous run died between backup and replacement: the store
      -- holds a known-good backup but no installed file. Restore it
      -- best-effort before doing anything else; the install proceeds
      -- from the candidate either way.
      log_warn("update stage: restoring interrupted backup " .. backup)
      opts.file_move(backup, filename)
    end
    -- Validate a SEPARATE candidate before replacing the installed
    -- package, so a failed write or invalid download can never strand
    -- the controller without a known-good package. (The zip's inner
    -- manifest cannot be checked on-Director: no unzip API, and binary
    -- reads mangle bytes. Identity is established instead by the exact
    -- asset URL + family match at selection, the exact byte size at
    -- download, and the archive prefix + size round-trip here.)
    if opts.file_exists(candidate) then
      opts.file_delete(candidate)
    end
    if opts.file_exists(backup) then
      opts.file_delete(backup)
    end
    opts.file_write(candidate, body)
    -- Never trust the write call: verify by on-disk SIZE (a number), not
    -- by re-reading the full binary that can false-mismatch through
    -- string marshalling. Director strips the zip magic's control bytes
    -- (\003\004 are illegal in XML), so gate on the ASCII "PK" prefix
    -- that survives the read-back: with the exact size match this still
    -- rejects error pages and truncations.
    if opts.file_size(candidate) ~= #body then
      opts.file_delete(candidate)
      finish("Staged package size mismatch; installed driver left intact")
      return
    end
    local head = opts.file_read(candidate, 4)
    if head == nil then
      log_warn("update stage: read-back failed for " .. candidate)
      opts.file_delete(candidate)
      finish("Staged package could not be verified (read-back failed); installed driver left intact")
      return
    end
    if type(head) ~= "string" or head:sub(1, 2) ~= "PK" then
      log_warn("update stage: magic check failed for " .. candidate)
      opts.file_delete(candidate)
      finish("Staged package is not a driver archive; installed driver left intact")
      return
    end
    log_warn("update stage: candidate verified (" .. #body .. " bytes, zip magic ok)")
    -- Candidate verified: replace by move with a backup, verifying each
    -- step by filesystem state. A known-good package survives every
    -- step: installed -> backup, candidate -> installed, verify, then
    -- drop the backup. Any failure rolls back before reporting, and
    -- every report states only what the filesystem proves.
    local had_installed = opts.file_exists(filename)
    local old_size = nil
    local function installed_ok()
      if not opts.file_exists(filename) then
        return false
      end
      return old_size == nil or opts.file_size(filename) == old_size
    end
    -- Roll a failed replacement back to the previous driver when one
    -- existed; without one, remove any torn file so a later run (or
    -- Composer) never mistakes it for a package. Reports only what the
    -- filesystem proves.
    local function roll_back(why)
      if had_installed then
        log_warn("update stage: replacement failed (" .. why .. "); rolling back " .. backup)
        opts.file_move(backup, filename)
        if installed_ok() then
          finish("Installed package replacement failed (" .. why .. "); rolled back to the previous driver")
        else
          finish(
            "Installed package replacement AND rollback failed; stored package may be missing or incomplete; restore using Composer"
          )
        end
      else
        opts.file_delete(filename)
        finish(
          "Installed package replacement failed (" .. why .. ") and no previous driver exists; restore using Composer"
        )
      end
    end
    if had_installed then
      old_size = opts.file_size(filename)
      local backup_made = opts.file_move(filename, backup)
        and opts.file_exists(backup)
        and (old_size == nil or opts.file_size(backup) == old_size)
      if not backup_made then
        opts.file_delete(candidate)
        if installed_ok() then
          -- Clean failure: the move preserved nothing but destroyed
          -- nothing either; the installed file still verifies.
          finish("Installed package backup failed; installed driver left intact")
        else
          -- The move destroyed without preserving: roll back whatever
          -- the backup holds, then report only what verifies.
          log_warn("update stage: backup failed; rolling back " .. backup)
          opts.file_move(backup, filename)
          if installed_ok() then
            finish("Installed package backup failed; rolled back to the previous driver")
          else
            finish("Installed package backup failed and the stored package is unverifiable; restore using Composer")
          end
        end
        return
      end
      log_warn("update stage: backup staged (" .. tostring(old_size) .. " bytes)")
    end
    if not opts.file_move(candidate, filename) or opts.file_size(filename) ~= #body then
      -- The candidate is kept for forensics alongside the failure report.
      roll_back("move failed")
      return
    end
    local installed_head = opts.file_read(filename, 4)
    if installed_head == nil then
      log_warn("update stage: replacement read-back failed for " .. filename)
      roll_back("read-back failed")
      return
    end
    if type(installed_head) ~= "string" or installed_head:sub(1, 2) ~= "PK" then
      roll_back("verification failed")
      return
    end
    opts.file_delete(candidate)
    opts.file_delete(backup)
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
      download(release.url, FloUpdate.MAX_REDIRECTS, release.size, function(body)
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
