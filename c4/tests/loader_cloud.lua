-- c4/tests/loader_cloud.lua — cloud-driver suite in its own Lua state.
-- Usage from the repo root:  lua5.1 c4/tests/loader_cloud.lua
-- Plan D8: the monolith and cloud bundles must never share one Lua state,
-- so this loader mirrors loader_standalone.lua for c4/cloud only.
local base = arg[0]:match("^(.*/)") or "./"
dofile(base .. "../src/json.lua")
dofile(base .. "../src/model.lua")
dofile(base .. "../src/signalr.lua")
dofile(base .. "../src/websocket.lua")
dofile(base .. "../src/flologic.lua")
dofile(base .. "../src/update.lua")
dofile(base .. "../shared/flologic_link.lua")
dofile(base .. "../cloud/cloud.lua")
dofile(base .. "helpers.lua")
dofile(base .. "cloud.lua")

TestHelp.run_all()
