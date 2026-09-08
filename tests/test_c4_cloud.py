"""Run the FloLogic Cloud driver's Lua suite under lupa.

The suite itself lives in c4/tests/cloud.lua with the shared protocol stack
under c4/src, c4/shared, and c4/cloud. It runs in its own Lua state, mirroring
c4/tests/loader_cloud.lua: the monolith and cloud bundles must never share
one runtime. A failure inside Lua raises through lupa and fails the test.
"""

from __future__ import annotations

from pathlib import Path
from xml.etree import ElementTree

from lupa.lua51 import LuaRuntime

C4_DIR = Path(__file__).resolve().parent.parent / "c4"
CLOUD_DIR = C4_DIR / "cloud"

CLOUD_LOAD_ORDER = [
    "src/json.lua",
    "src/model.lua",
    "src/signalr.lua",
    "src/websocket.lua",
    "src/flologic.lua",
    "src/update.lua",
    "shared/flologic_link.lua",
    "cloud/cloud.lua",
    "tests/helpers.lua",
    "tests/cloud.lua",
]

CLOUD_SOURCES = [
    ("src/json.lua", C4_DIR),
    ("src/model.lua", C4_DIR),
    ("src/signalr.lua", C4_DIR),
    ("src/websocket.lua", C4_DIR),
    ("src/flologic.lua", C4_DIR),
    ("src/update.lua", C4_DIR),
    ("shared/flologic_link.lua", C4_DIR),
    ("cloud.lua", CLOUD_DIR),
]


def _read(name: str) -> str:
    return (C4_DIR / name).read_text(encoding="utf-8")


def _cloud_runtime() -> tuple[LuaRuntime, list[str]]:
    runtime = LuaRuntime()
    runtime.execute("C4 = {}")  # cloud.lua must not call C4 at load time
    # run_all() calls os.exit(1) on failure, which would kill pytest itself.
    runtime.execute(
        "os.exit = function(code) error('suite exit: ' .. tostring(code)) end"
    )
    printed: list[str] = []
    runtime.globals().print = lambda *args: printed.append(" ".join(map(str, args)))
    chunk = "\n".join(_read(name) for name in CLOUD_LOAD_ORDER)
    runtime.execute(chunk)
    return runtime, printed


def test_cloud_lua_suite_passes() -> None:
    runtime, printed = _cloud_runtime()
    runtime.execute("TestHelp.run_all()")  # raises on any Lua error
    assert any(line.startswith("passed=") for line in printed), printed
    summary = next(line for line in printed if line.startswith("passed="))
    assert summary.endswith("failed=0"), summary


def test_cloud_bundled_driver_matches_sources() -> None:
    """cloud/driver.lua must be a fresh bundle.sh concatenation."""
    bundled = (CLOUD_DIR / "driver.lua").read_text(encoding="utf-8")
    assert "THIS FILE IS GENERATED" in bundled.splitlines()[1]
    assert bundled.index("-- bundled: ../src/json.lua") < bundled.index(
        "-- bundled: cloud.lua"
    )
    for name, root in CLOUD_SOURCES:
        source = (root / name).read_text(encoding="utf-8").strip()
        assert source in bundled, f"{name} not reflected in driver.lua"


def test_cloud_manifest_has_no_proxies_or_valve_selection() -> None:
    """The cloud owns the account, not display/contacts/selection (CLOUD-U6)."""
    text = (CLOUD_DIR / "driver.xml").read_text(encoding="utf-8")
    manifest = ElementTree.fromstring(text)
    assert manifest.findtext("name") == "FloLogic Cloud"
    version = manifest.findtext("version")
    assert f'FLOCLOUD_DRIVER_VERSION = "{version}"' in _read("cloud/cloud.lua")
    assert manifest.find("proxies") is not None
    assert len(manifest.findall("proxies/proxy")) == 0
    assert len(manifest.findall("connections/connection")) == 0
    assert "CONTACT_SENSOR" not in text
    assert "light_v2" not in text
    # The dynamic FLOGIC_VALVE provider bindings live in Lua only: no static
    # connection or class element may declare them (the XML comment may name
    # the class to explain why <connections/> is empty).
    assert len(manifest.findall("connections/connection")) == 0
    assert "classname" not in text
    assert "Select Valve" not in text
    assert "Valve ID Override" not in text
    properties = {
        prop.findtext("name"): prop
        for prop in manifest.findall("config/properties/property")
    }
    for required in (
        "Email",
        "Password",
        "Hub URL",
        "Poll Interval",
        "Connection",
        "Valve Count",
        "Available Valves",
        "Driver Version",
    ):
        assert required in properties, f"missing property {required}"
    assert properties["Driver Version"].findtext("default") == version
    assert properties["Password"].findtext("password") == "true"
    commands = {
        entry.findtext("name") for entry in manifest.findall("config/commands/command")
    }
    assert {"Refresh", "Refresh Valve List", "Check for Update"} <= commands
    assert "Install Latest Release" in commands
    assert "Force Reinstall Latest Release" in commands
    actions = {
        action.findtext("name"): action.findtext("command")
        for action in manifest.findall("config/actions/action")
    }
    assert actions["Refresh GitHub Updates"] == "Check for Update"
    assert actions["Refresh"] == "Refresh"
    # Preserve Proflame's working Composer script-tag serialization: an XML
    # parser normalizes the two forms, so parsed-tree checks cannot catch drift.
    assert '<script file="driver.lua" encryption="0" jit="1"></script>' in text
