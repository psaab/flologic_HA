"""Validate the unit-0 spike artifacts (stub manifests + procedure).

The spike retires the highest-risk Director unknowns (custom-class bind,
peer BindMessages, the light_v2 tile, restart restore), so a malformed
stub manifest would waste a human procedure run. This pins the stub
structure the procedure describes. It deliberately asserts nothing about
the packaged spike .c4z files (developer-built, may be absent).
"""

from __future__ import annotations

from pathlib import Path
from xml.etree import ElementTree

REPO = Path(__file__).resolve().parent.parent
SPIKE = REPO / "spike"


def _manifest(name: str) -> ElementTree.Element:
    return ElementTree.parse(SPIKE / name / "driver.xml").getroot()


def test_spike_manifests_are_well_formed_at_spike_version() -> None:
    """Both stubs parse and carry the version the procedure expects."""
    for name in ("cloud_stub", "valve_stub"):
        manifest = _manifest(name)
        assert manifest.findtext("version") == "2026090701", name


def test_spike_light_form_matches_production() -> None:
    """The spike tile must declare exactly what production ships (H2).

    A passing spike run only retires the production risk when both
    manifests use the same light-proxy form.
    """
    stubs = _manifest("valve_stub")
    production = ElementTree.parse(REPO / "c4" / "valve" / "driver.xml").getroot()
    for manifest in (stubs, production):
        proxy = manifest.find("proxies/proxy")
        assert proxy is not None and proxy.text == "light_v2"
        assert proxy.get("proxybindingid") == "5001"
        connections = {
            entry.findtext("id"): entry
            for entry in manifest.findall("connections/connection")
        }
        light = connections["5001"]
        assert light.findtext("type") == "1"
        assert light.findtext("consumer") == "False"
        assert light.findtext("classes/class/classname") == "LIGHT_V2"
        capabilities = light.find("capabilities")
        assert capabilities is not None, "switch capabilities live on 5001"
        assert capabilities.findtext("dimmer") == "false"
        assert capabilities.findtext("set_level") == "false"
        assert capabilities.findtext("on_off") == "True"
        assert manifest.find("capabilities") is None, "no top-level capabilities"


def test_spike_link_ids_match_procedure() -> None:
    """Stub link ids match the procedure text (2001 static / 2002 / 6000 / 5001)."""
    valve = _manifest("valve_stub")
    link_ids = {
        entry.findtext("classes/class/classname"): entry.findtext("id")
        for entry in valve.findall("connections/connection")
    }
    assert link_ids["FLOGIC_VALVE"] == "6000"
    # The cloud stub needs a static connection or Composer never indexes
    # it (same rule as production); the test link stays dynamic 2002.
    cloud = _manifest("cloud_stub")
    statics = cloud.findall("connections/connection")
    assert len(statics) == 1
    assert statics[0].findtext("id") == "2001"
    assert statics[0].findtext("classes/class/classname") == "FLOGIC_VALVE"
    stub_lua = (SPIKE / "cloud_stub" / "driver.lua").read_text(encoding="utf-8")
    assert "SPIKE_BINDING_ID = 2002" in stub_lua
    procedure = (SPIKE / "PROCEDURE.md").read_text(encoding="utf-8")
    for token in ("2001", "2002", "6000", "5001", "FLOGIC_VALVE", "2026090701"):
        assert token in procedure, token
    # H4: the Lua-reload case must exist, not just the restart case.
    assert "Lua reload" in procedure
