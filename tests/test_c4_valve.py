"""Run the FloLogic Water Valve driver's Lua suite under lupa.

The suite itself lives in c4/tests/valve.lua with the shared pure-logic
modules under c4/src, c4/shared, and c4/valve. It runs in its own Lua
state, mirroring c4/tests/loader_valve.lua: bundles must never share one
runtime (plan D8). A failure inside Lua raises through lupa and fails the
test.
"""

from __future__ import annotations

from pathlib import Path
from xml.etree import ElementTree

from lupa.lua51 import LuaRuntime

C4_DIR = Path(__file__).resolve().parent.parent / "c4"
VALVE_DIR = C4_DIR / "valve"

VALVE_LOAD_ORDER = [
    "src/json.lua",
    "src/model.lua",
    "src/update.lua",
    "shared/flologic_link.lua",
    "valve/valve.lua",
    "tests/helpers.lua",
    "tests/valve.lua",
]

VALVE_SOURCES = [
    ("src/json.lua", C4_DIR),
    ("src/model.lua", C4_DIR),
    ("src/update.lua", C4_DIR),
    ("shared/flologic_link.lua", C4_DIR),
    ("valve.lua", VALVE_DIR),
]


def _read(name: str) -> str:
    return (C4_DIR / name).read_text(encoding="utf-8")


def _valve_runtime() -> tuple[LuaRuntime, list[str]]:
    runtime = LuaRuntime()
    runtime.execute("C4 = {}")  # valve.lua must not call C4 at load time
    # run_all() calls os.exit(1) on failure, which would kill pytest itself.
    runtime.execute(
        "os.exit = function(code) error('suite exit: ' .. tostring(code)) end"
    )
    printed: list[str] = []
    runtime.globals().print = lambda *args: printed.append(" ".join(map(str, args)))
    chunk = "\n".join(_read(name) for name in VALVE_LOAD_ORDER)
    runtime.execute(chunk)
    return runtime, printed


def test_valve_lua_suite_passes() -> None:
    runtime, printed = _valve_runtime()
    runtime.execute("TestHelp.run_all()")  # raises on any Lua error
    assert any(line.startswith("passed=") for line in printed), printed
    summary = next(line for line in printed if line.startswith("passed="))
    assert summary.endswith("failed=0"), summary


def test_valve_bundled_driver_matches_sources() -> None:
    """valve/driver.lua must be a fresh bundle.sh concatenation."""
    bundled = (VALVE_DIR / "driver.lua").read_text(encoding="utf-8")
    assert "THIS FILE IS GENERATED" in bundled.splitlines()[1]
    assert bundled.index("-- bundled: ../src/json.lua") < bundled.index(
        "-- bundled: valve.lua"
    )
    for name, root in VALVE_SOURCES:
        source = (root / name).read_text(encoding="utf-8").strip()
        assert source in bundled, f"{name} not reflected in driver.lua"


def test_valve_manifest_links_switch_contacts_and_identity() -> None:
    """The valve owns the link, the switch, contacts, and identity display."""
    text = (VALVE_DIR / "driver.xml").read_text(encoding="utf-8")
    manifest = ElementTree.fromstring(text)
    assert manifest.findtext("name") == "FloLogic Water Valve"
    version = manifest.findtext("version")
    assert f'FLOVALVE_DRIVER_VERSION = "{version}"' in _read("valve/valve.lua")
    assert version == "2026090811"
    # Switch-only light proxy on 5001.
    assert len(manifest.findall("proxies/proxy")) == 1
    proxy = manifest.find("proxies/proxy")
    assert proxy.text == "light_v2"
    assert proxy.get("proxybindingid") == "5001"
    assert "<dimmer>false</dimmer>" in text
    assert "<set_level>false</set_level>" in text
    assert "<on_off>True</on_off>" in text
    # Tile clicks need DYNAMIC_ON/DYNAMIC_OFF (OS 3.3.2+).
    assert manifest.findtext("minimum_os_version") == "3.3.2"
    # Composer discovery: category declared; no combo element (the UI goes
    # through the light proxy, mirroring the reference proxy drivers).
    assert manifest.findtext("composer_categories/category") == "Utility"
    assert manifest.find("combo") is None
    # Instance naming: the proxy carries primary + name, or Composer
    # names new instances after the raw proxy ("Light v2").
    (proxy,) = manifest.findall("proxies/proxy")
    assert proxy.attrib.get("primary") == "True"
    assert proxy.attrib.get("name") == "FloLogic Water Valve"
    assert (proxy.text or "").strip() == "light_v2"
    connections = {
        int(entry.findtext("id")): entry
        for entry in manifest.findall("connections/connection")
    }
    assert connections[600].findtext("consumer") == "True"
    assert connections[600].findtext("classes/class/classname") == "FLOGIC_VALVE"
    # Light form must match the spike-validated declaration exactly, or a
    # passing spike run proves nothing about the shipped tile (H2).
    assert connections[5001].findtext("classes/class/classname") == "LIGHT_V2"
    assert connections[5001].findtext("type") == "1"
    assert connections[5001].findtext("consumer") == "False"
    capabilities = connections[5001].find("capabilities")
    assert capabilities is not None, "switch capabilities live on 5001"
    assert capabilities.findtext("dimmer") == "false"
    assert capabilities.findtext("set_level") == "false"
    assert capabilities.findtext("on_off") == "True"
    assert manifest.find("capabilities") is None, "no top-level capabilities"
    expected_contacts = {
        101: "Valve Closed",
        102: "Away Mode",
        103: "Flowing",
        104: "Leak Detected",
        105: "Warning Active",
        106: "Critical Fault",
        107: "Valve Online",
    }
    for binding, name in expected_contacts.items():
        entry = connections[binding]
        assert entry.findtext("connectionname") == name, f"contact {binding}"
        assert entry.findtext("consumer") == "False"
        assert entry.findtext("classes/class/classname") == "CONTACT_SENSOR"
    # Identity is display-only: no credentials, picker, or override.
    assert "FLOGIC_VALVE" in text  # link class comment + connection
    for banned in ("Password", "Select Valve", "Valve ID Override", "Hub URL"):
        assert banned not in text, f"banned property {banned}"
    properties = {
        prop.findtext("name"): prop
        for prop in manifest.findall("config/properties/property")
    }
    for required in (
        "Valve ID",
        "Valve Name",
        "Connection",
        "Mode",
        "Last Link Update",
        "Driver Version",
    ):
        assert required in properties, f"missing property {required}"
    assert properties["Driver Version"].findtext("default") == version
    commands = {
        entry.findtext("name") for entry in manifest.findall("config/commands/command")
    }
    assert {
        "Open Valve",
        "Close Valve",
        "Toggle",
        "Refresh",
        "Check for Update",
    } <= commands
    assert "Install Latest Release" in commands
    assert "Force Reinstall Latest Release" in commands
    actions = {
        action.findtext("name"): action.findtext("command")
        for action in manifest.findall("config/actions/action")
    }
    assert actions["Open Valve"] == "Open Valve"
    assert actions["Close Valve"] == "Close Valve"
    assert actions["Toggle"] == "Toggle"
    events = {entry.findtext("name") for entry in manifest.findall("events/event")}
    assert {
        "Flow Started",
        "Water Off Detected",
        "Critical Fault",
        "Mode Changed",
        "Connection Lost",
        "Connection Restored",
    } <= events
    # Preserve Proflame's working Composer script-tag serialization: an XML
    # parser normalizes the two forms, so parsed-tree checks cannot catch drift.
    assert '<script file="driver.lua" encryption="0" jit="1"></script>' in text
