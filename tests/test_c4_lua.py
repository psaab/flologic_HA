"""Run the Control4 driver's Lua suite under lupa.

The suite itself lives in c4/tests/run.lua with support files under c4/src
and c4/tests. Everything is concatenation-safe by design, so this wrapper
concatenates the same files bundle.sh uses (plus the test helpers) and
executes them in one lupa runtime with a stub C4 global. A failure inside
Lua raises through lupa and fails the test.
"""

from __future__ import annotations

import zipfile
from pathlib import Path
from xml.etree import ElementTree

from lupa.lua51 import LuaRuntime

C4_DIR = Path(__file__).resolve().parent.parent / "c4"

LOAD_ORDER = [
    "src/bootstrap.lua",
    "src/json.lua",
    "src/model.lua",
    "src/signalr.lua",
    "src/websocket.lua",
    "src/flologic.lua",
    "src/update.lua",
    "src/main.lua",
    "tests/helpers.lua",
    "tests/run.lua",
    "tests/driver.lua",
]


def _read(name: str) -> str:
    return (C4_DIR / name).read_text(encoding="utf-8")


def test_lua_suite_passes() -> None:
    runtime = LuaRuntime()
    runtime.execute("C4 = {}")  # main.lua must not call C4 at load time
    # run_all() calls os.exit(1) on failure, which would kill pytest itself.
    runtime.execute(
        "os.exit = function(code) error('suite exit: ' .. tostring(code)) end"
    )
    printed: list[str] = []
    runtime.globals().print = lambda *args: printed.append(" ".join(map(str, args)))
    runtime.globals().flogic_test_source = _read("driver.lua")
    runtime.execute(
        "function flogic_test_reload() assert(loadstring(flogic_test_source))() end"
    )
    chunk = "\n".join(_read(name) for name in LOAD_ORDER)
    runtime.execute(chunk + "\nTestHelp.run_all()")  # raises on any Lua error
    assert any(line.startswith("passed=") for line in printed), printed
    summary = next(line for line in printed if line.startswith("passed="))
    assert summary.endswith("failed=0"), summary


def test_bundled_driver_matches_sources() -> None:
    """driver.lua must be a fresh bundle.sh concatenation of src/*.lua."""
    bundled = (C4_DIR / "driver.lua").read_text(encoding="utf-8")
    assert "THIS FILE IS GENERATED" in bundled.splitlines()[1]
    assert bundled.index("-- bundled: src/bootstrap.lua") < bundled.index(
        "-- bundled: src/json.lua"
    )
    for name in LOAD_ORDER[:8]:
        source = _read(name).strip()
        assert source in bundled, f"{name} not reflected in driver.lua"


def test_file_handles_close_on_errors() -> None:
    """Exercise cleanup with fake handles, without installing or changing paths."""
    runtime = LuaRuntime()
    runtime.globals().print = lambda *args: None
    runtime.execute(_read("src/main.lua"))
    runtime.execute(
        """
        local function upvalue(fn, wanted)
          for i = 1, 100 do
            local name, value = debug.getupvalue(fn, i)
            if name == wanted then return value end
            if name == nil then break end
          end
          error("missing upvalue: " .. wanted)
        end
        local install = upvalue(ExecuteCommand, "flogic_install_update")
        local write = upvalue(install, "flogic_file_write")
        local size = upvalue(install, "flogic_file_size")
        local handle = {}
        local closed = 0
        C4 = {
          FileExists = function() return true end,
          FileOpen = function() return handle end,
          FileWrite = function() error("simulated write failure") end,
          FileGetSize = function() error("simulated size query failure") end,
          FileClose = function(_, actual)
            assert(actual == handle)
            closed = closed + 1
          end,
        }
        write("test-package", "test-data")
        assert(closed == 1, "write failure leaked handle")
        assert(size("test-package") == nil)
        assert(closed == 2, "size failure leaked handle")
        C4.FileOpen = function() return -1 end
        write("test-package", "test-data")
        assert(size("test-package") == nil)
        assert(closed == 2, "invalid handle must not be closed")
        """
    )


def test_package_matches_reviewed_files() -> None:
    """The installable artifact must contain the reviewed code and trust store."""
    files = {"driver.xml", "driver.lua", "ca-bundle.pem", "CA-LICENSE"}
    with zipfile.ZipFile(C4_DIR / "flologic_valve.c4z") as package:
        assert set(package.namelist()) == files
        for name in files:
            assert package.read(name) == (C4_DIR / name).read_bytes()
    manifest = ElementTree.parse(C4_DIR / "driver.xml").getroot()
    version = manifest.findtext("version")
    assert f'FLOGIC_DRIVER_VERSION = "{version}"' in _read("src/main.lua")
    properties = {
        prop.findtext("name"): prop
        for prop in manifest.findall("config/properties/property")
    }
    assert properties["Driver Version"].findtext("default") == version
    assert properties["Password"].findtext("password") == "true"
    # Preserve Proflame's working Composer script-tag serialization: an XML
    # parser normalizes the two forms, so parsed-tree checks cannot catch drift.
    assert '<script file="driver.lua" encryption="0" jit="1"></script>' in _read(
        "driver.xml"
    )


def test_status_contact_bindings_and_github_refresh_action() -> None:
    """Composer needs actual XML connection/action definitions, not only Lua."""
    manifest = ElementTree.parse(C4_DIR / "driver.xml").getroot()
    bindings = {
        entry.findtext("id"): entry
        for entry in manifest.findall("connections/connection")
    }
    assert set(bindings) == {"101", "102"}
    for binding, name in (("101", "Valve Closed"), ("102", "Away Mode")):
        entry = bindings[binding]
        assert entry.findtext("connectionname") == name
        assert entry.findtext("type") == "1"
        assert entry.findtext("consumer") == "False"
        assert entry.findtext("classes/class/classname") == "CONTACT_SENSOR"
    actions = {
        action.findtext("name"): action.findtext("command")
        for action in manifest.findall("config/actions/action")
    }
    assert actions["Refresh GitHub Updates"] == "Check for Update"


def test_updater_commands_and_actions() -> None:
    """Composer needs the install/force commands and buttons, not only Lua."""
    manifest = ElementTree.parse(C4_DIR / "driver.xml").getroot()
    commands = {
        entry.findtext("name") for entry in manifest.findall("config/commands/command")
    }
    assert "Install Latest Release" in commands
    assert "Force Reinstall Latest Release" in commands
    actions = {
        action.findtext("name"): action.findtext("command")
        for action in manifest.findall("config/actions/action")
    }
    assert actions["Install Latest Release"] == "Install Latest Release"
    assert (
        actions["Force Reinstall Latest Release (Recovery)"]
        == "Force Reinstall Latest Release"
    )
