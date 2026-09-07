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
