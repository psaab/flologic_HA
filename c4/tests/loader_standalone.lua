-- c4/tests/loader_standalone.lua — load src modules + helpers + tests.
-- Usage from the repo root:  lua5.1 c4/tests/loader_standalone.lua
local base = arg[0]:match("^(.*/)") or "./"
dofile(base .. "../src/bootstrap.lua")
dofile(base .. "../src/json.lua")
dofile(base .. "../src/model.lua")
dofile(base .. "../src/signalr.lua")
dofile(base .. "../src/websocket.lua")
dofile(base .. "../src/flologic.lua")
dofile(base .. "../src/update.lua")
dofile(base .. "../src/main.lua")
dofile(base .. "helpers.lua")
dofile(base .. "run.lua")
dofile(base .. "driver.lua")
function flogic_test_reload()
  dofile(base .. "../driver.lua")
end

TestHelp.run_all()
