"""Pin the Lua↔manifest name contracts for the split drivers (T1).

Every property/command/event table in Lua carries a "must match
driver.xml" comment, but manifest literals and Lua constants were
asserted separately — so drift (a typo'd property name, a renamed
command) went undetected until live use. These tests extract the names
each driver actually uses from its Lua source and compare them against
its manifest.
"""

from __future__ import annotations

import re
from pathlib import Path
from xml.etree import ElementTree

REPO = Path(__file__).resolve().parent.parent
C4_DIR = REPO / "c4"

TRANSPORT_COMMAND = "LUA_ACTION"  # Composer action transport, not a command


def _manifest(driver: str) -> ElementTree.Element:
    return ElementTree.parse(C4_DIR / driver / "driver.xml").getroot()


def _source(driver: str, name: str) -> str:
    return (C4_DIR / driver / name).read_text(encoding="utf-8")


_SECTION_TAG = {"properties": "property", "commands": "command", "actions": "action"}


def _manifest_names(manifest: ElementTree.Element, section: str) -> set[str]:
    return {
        entry.findtext("name")
        for entry in manifest.findall(f"config/{section}/{_SECTION_TAG[section]}")
    }


def _assert_commands_covered(
    handled: set[str], manifest: ElementTree.Element, driver: str
) -> None:
    """Every declared command is handled; every handled name is a declared
    command or a declared action name (action buttons arrive under their
    action name on some paths, e.g. Refresh GitHub Updates)."""
    declared = _manifest_names(manifest, "commands")
    aliases = _manifest_names(manifest, "actions")
    assert declared <= handled, (
        f"{driver}: unhandled manifest commands: {sorted(declared - handled)}"
    )
    assert handled <= declared | aliases, (
        f"{driver}: handled but undeclared: {sorted(handled - declared - aliases)}"
    )


def _lua_prop_names(source: str, prefix: str) -> set[str]:
    """PROP consts plus every literal passed to the prop helpers."""
    names = set(re.findall(rf"^{prefix}_PROP_[A-Z_]+ = \"([^\"]+)\"", source, re.M))
    names.update(re.findall(r'_prop\("([^"]+)"', source))
    names.update(re.findall(r'UpdateProperty\("([^"]+)"', source))
    return names


def _lua_event_names(source: str, prefix: str) -> set[str]:
    return set(re.findall(rf"^{prefix}_EV_[A-Z_]+ = \"([^\"]+)\"", source, re.M))


def _execute_command_body(source: str) -> str:
    """Slice out top-level ExecuteCommand (no nested functions inside)."""
    lines = source.splitlines(keepends=True)
    start = next(
        i for i, line in enumerate(lines) if line.startswith("function ExecuteCommand")
    )
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == "end\n")
    return "".join(lines[start : end + 1])


def _lua_handled_commands(source: str) -> set[str]:
    """strCommand literals in ExecuteCommand, minus the transport."""
    body = _execute_command_body(source)
    return set(re.findall(r'strCommand == "([^"]+)"', body)) - {TRANSPORT_COMMAND}


def _lua_program_keys(source: str) -> set[str]:
    """Valve FLOVALVE_PROGRAM_COMMANDS keys (Title Case; lowercase keys
    belong to FLOVALVE_VALUE_ACTIONS and are link actions, not commands)."""
    return set(re.findall(r'\["([A-Z][^"]*)"\] = \{', source))


def test_valve_props_exist_in_manifest() -> None:
    """Every property the valve Lua touches is declared."""
    source = _source("valve", "valve.lua")
    manifest = _manifest("valve")
    declared = _manifest_names(manifest, "properties")
    used = _lua_prop_names(source, "FLOVALVE")
    assert used, "extraction found no property names"
    assert used <= declared, f"undeclared properties used: {sorted(used - declared)}"


def test_valve_commands_match_manifest_exactly() -> None:
    """Handled programming commands cover the manifest set (no dead or
    missing entries in either direction, modulo action-name aliases)."""
    source = _source("valve", "valve.lua")
    manifest = _manifest("valve")
    handled = _lua_handled_commands(source) | _lua_program_keys(source)
    _assert_commands_covered(handled, manifest, "valve")


def test_valve_events_match_manifest_exactly() -> None:
    """Every fired event is declared and every declared event is firable."""
    source = _source("valve", "valve.lua")
    manifest = _manifest("valve")
    declared = {e.findtext("name") for e in manifest.findall("events/event")}
    fired = _lua_event_names(source, "FLOVALVE")
    assert fired == declared, (
        f"declared but never fired: {sorted(declared - fired)}; "
        f"fired but undeclared: {sorted(fired - declared)}"
    )


def test_valve_actions_reference_real_commands() -> None:
    """Manifest-internal: every action maps to a declared command."""
    manifest = _manifest("valve")
    declared = _manifest_names(manifest, "commands")
    actions = {
        action.findtext("name"): action.findtext("command")
        for action in manifest.findall("config/actions/action")
    }
    assert actions, "no actions in manifest"
    for name, command in actions.items():
        assert command in declared, f"action {name!r} maps to unknown {command!r}"


def test_cloud_props_exist_in_manifest() -> None:
    """Every property the cloud Lua touches is declared."""
    source = _source("cloud", "cloud.lua")
    manifest = _manifest("cloud")
    declared = _manifest_names(manifest, "properties")
    used = _lua_prop_names(source, "FLOCLOUD")
    assert used, "extraction found no property names"
    assert used <= declared, f"undeclared properties used: {sorted(used - declared)}"


def test_cloud_commands_match_manifest_exactly() -> None:
    """Handled programming commands cover the manifest set."""
    source = _source("cloud", "cloud.lua")
    manifest = _manifest("cloud")
    handled = _lua_handled_commands(source)
    _assert_commands_covered(handled, manifest, "cloud")


def test_cloud_events_match_manifest_exactly() -> None:
    """Every fired event is declared and every declared event is firable."""
    source = _source("cloud", "cloud.lua")
    manifest = _manifest("cloud")
    declared = {e.findtext("name") for e in manifest.findall("events/event")}
    fired = _lua_event_names(source, "FLOCLOUD")
    assert fired == declared, (
        f"declared but never fired: {sorted(declared - fired)}; "
        f"fired but undeclared: {sorted(fired - declared)}"
    )


def test_cloud_actions_reference_real_commands() -> None:
    """Manifest-internal: every action maps to a declared command."""
    manifest = _manifest("cloud")
    declared = _manifest_names(manifest, "commands")
    actions = {
        action.findtext("name"): action.findtext("command")
        for action in manifest.findall("config/actions/action")
    }
    assert actions, "no actions in manifest"
    for name, command in actions.items():
        assert command in declared, f"action {name!r} maps to unknown {command!r}"
