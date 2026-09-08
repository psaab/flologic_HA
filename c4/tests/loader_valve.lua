-- c4/tests/loader_valve.lua — valve-driver suite in its own Lua state.
-- Usage from the repo root:  lua5.1 c4/tests/loader_valve.lua
-- Plan D8: bundles must never share one Lua state, so this loader mirrors
-- loader_cloud.lua for c4/valve only.
local base = arg[0]:match("^(.*/)") or "./"
dofile(base .. "../src/json.lua")
dofile(base .. "../src/model.lua")
dofile(base .. "../src/update.lua")
dofile(base .. "../shared/flologic_link.lua")
dofile(base .. "../valve/valve.lua")
dofile(base .. "helpers.lua")
dofile(base .. "valve.lua")

TestHelp.run_all()
