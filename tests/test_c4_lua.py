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
