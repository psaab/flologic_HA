"""Build and verify the two split-driver Control4 packages.

Unit 4 release-infra self-test: both c4z files must build reproducibly from
c4/cloud/ and c4/valve/ (+ shared), carry the same lockstep version, and
contain the reviewed sources. Composer identities (name/model/proxy) stay
distinct from the monolith driver, and the split valve ships under its own
asset name flologic_water_valve.c4z: it must never reuse the legacy
monolith filename flologic_valve.c4z, or installed monoliths would offer
the incompatible companion as an update. Monolith owners migrate manually
(delete monolith, add cloud + valves). CI runs this file via the full
pytest suite (check.yml) and the release workflow (release-c4.yml).
"""

from __future__ import annotations

import re
import subprocess
import zipfile
from pathlib import Path
from xml.etree import ElementTree

import pytest

REPO = Path(__file__).resolve().parent.parent
C4_DIR = REPO / "c4"
CLOUD_DIR = C4_DIR / "cloud"
VALVE_DIR = C4_DIR / "valve"

CLOUD_C4Z = C4_DIR / "flologic_cloud.c4z"
VALVE_C4Z = C4_DIR / "flologic_water_valve.c4z"
LEGACY_C4Z = C4_DIR / "flologic_valve.c4z"
CLOUD_FILES = ("driver.xml", "driver.lua", "ca-bundle.pem", "CA-LICENSE")
VALVE_FILES = ("driver.xml", "driver.lua")


@pytest.fixture(scope="module")
def built_packages() -> dict[str, Path]:
    """Build both c4z files with the packaging scripts (bundle + zip)."""
    for script in ("c4/scripts/package-cloud.sh", "c4/scripts/package-valve.sh"):
        completed = subprocess.run(
            ["sh", str(REPO / script)],
            capture_output=True,
            text=True,
            cwd=REPO,
            timeout=120,
            check=False,
        )
        assert completed.returncode == 0, (
            f"{script} failed:\n{completed.stdout}\n{completed.stderr}"
        )
    assert CLOUD_C4Z.is_file(), "package-cloud.sh did not write flologic_cloud.c4z"
    assert VALVE_C4Z.is_file(), (
        "package-valve.sh did not write flologic_water_valve.c4z"
    )
    assert CLOUD_C4Z.stat().st_size > 0
    assert VALVE_C4Z.stat().st_size > 0
    return {"cloud": CLOUD_C4Z, "valve": VALVE_C4Z}


def _manifest(path: Path) -> ElementTree.Element:
    return ElementTree.parse(path).getroot()


def test_package_contents_match_sources(
    built_packages: dict[str, Path],
) -> None:
    """Each c4z holds exactly the reviewed files, byte for byte."""
    with zipfile.ZipFile(built_packages["cloud"]) as package:
        assert set(package.namelist()) == set(CLOUD_FILES)
        assert package.read("driver.xml") == (CLOUD_DIR / "driver.xml").read_bytes()
        assert package.read("driver.lua") == (CLOUD_DIR / "driver.lua").read_bytes()
        assert package.read("ca-bundle.pem") == (C4_DIR / "ca-bundle.pem").read_bytes()
        assert package.read("CA-LICENSE") == (C4_DIR / "CA-LICENSE").read_bytes()
        assert "THIS FILE IS GENERATED" in package.read("driver.lua").decode()
    with zipfile.ZipFile(built_packages["valve"]) as package:
        assert set(package.namelist()) == set(VALVE_FILES)
        assert package.read("driver.xml") == (VALVE_DIR / "driver.xml").read_bytes()
        assert package.read("driver.lua") == (VALVE_DIR / "driver.lua").read_bytes()
        assert "THIS FILE IS GENERATED" in package.read("driver.lua").decode()


def test_version_lockstep(built_packages: dict[str, Path]) -> None:
    """Both manifests share one version; Lua and properties agree with it."""
    cloud_version = _manifest(CLOUD_DIR / "driver.xml").findtext("version")
    valve_version = _manifest(VALVE_DIR / "driver.xml").findtext("version")
    assert re.fullmatch(r"[0-9]{10}", cloud_version or ""), cloud_version
    assert cloud_version == valve_version, (
        f"lockstep versions differ: cloud={cloud_version} valve={valve_version}"
    )
    assert f'FLOCLOUD_DRIVER_VERSION = "{cloud_version}"' in (
        CLOUD_DIR / "cloud.lua"
    ).read_text(encoding="utf-8")
    assert f'FLOVALVE_DRIVER_VERSION = "{valve_version}"' in (
        VALVE_DIR / "valve.lua"
    ).read_text(encoding="utf-8")
    for directory, version in ((CLOUD_DIR, cloud_version), (VALVE_DIR, valve_version)):
        manifest = _manifest(directory / "driver.xml")
        properties = {
            prop.findtext("name"): prop
            for prop in manifest.findall("config/properties/property")
        }
        assert properties["Driver Version"].findtext("default") == version
        with zipfile.ZipFile(built_packages[directory.name]) as package:
            assert version.encode() in package.read("driver.xml")


def test_composer_identities_distinct_valve_asset_never_collides() -> None:
    """Names, models, proxies, and asset filenames stay off the monolith.

    Composer matches drivers by name/model/proxy identity, and those stay
    fully distinct. The split valve asset must never reuse the legacy
    monolith filename: this test pins the distinct name, the family both
    split updaters require, and the absence of any stale legacy-named
    package that a release could upload by mistake.
    """
    monolith = _manifest(C4_DIR / "driver.xml")
    cloud = _manifest(CLOUD_DIR / "driver.xml")
    valve = _manifest(VALVE_DIR / "driver.xml")
    assert (monolith.findtext("name"), monolith.findtext("model")) == (
        "FloLogic Valve",
        "FloLogic Connect",
    )
    assert [proxy.text for proxy in monolith.findall("proxies/proxy")] == [
        "flologic_valve"
    ]
    assert (cloud.findtext("name"), cloud.findtext("model")) == (
        "FloLogic Cloud",
        "FloLogic Cloud",
    )
    assert (valve.findtext("name"), valve.findtext("model")) == (
        "FloLogic Water Valve",
        "FloLogic Water Valve",
    )
    for new in (cloud, valve):
        assert new.findtext("name") != monolith.findtext("name")
        assert new.findtext("model") != monolith.findtext("model")
        assert "flologic_valve" not in ElementTree.tostring(new, encoding="unicode")
    cloud_lua = (CLOUD_DIR / "cloud.lua").read_text(encoding="utf-8")
    valve_lua = (VALVE_DIR / "valve.lua").read_text(encoding="utf-8")
    assert 'FloUpdate.ASSET = "flologic_cloud.c4z"' in cloud_lua
    assert 'FloUpdate.ASSET = "flologic_water_valve.c4z"' in valve_lua
    family = (
        'FloUpdate.FAMILY_ASSETS = { "flologic_cloud.c4z", "flologic_water_valve.c4z" }'
    )
    assert family in cloud_lua
    assert family in valve_lua
    # The installed-lookup keys may keep pre-rename flologic_valve.c4i /
    # flologic_valve fallbacks, and comments may name the legacy file, but
    # no code value may reference the legacy .c4z filename as an asset.
    assert '"flologic_valve.c4z"' not in valve_lua
    assert not LEGACY_C4Z.is_file(), "stale legacy-named package must not exist"


def test_file_read_seeks_before_reading_in_all_adapters() -> None:
    """Every file_read adapter must FileSetPos(0) before FileRead.

    C4:FileOpen positions at end-of-file, so a read without the seek
    returns "" and the updater's magic gate fails every install (field
    failure on 2026090811). The three adapters are copy-pasted per
    driver by bundle design; this pins the invariant in all of them.
    """
    sources = {
        "cloud": (CLOUD_DIR / "cloud.lua").read_text(encoding="utf-8"),
        "valve": (VALVE_DIR / "valve.lua").read_text(encoding="utf-8"),
        "monolith": (C4_DIR / "src" / "main.lua").read_text(encoding="utf-8"),
    }
    fns = {
        "cloud": "flocloud_file_read",
        "valve": "flovalve_file_read",
        "monolith": "flogic_file_read",
    }
    for driver, text in sources.items():
        fn = fns[driver]
        start = text.index(f"local function {fn}(")
        body = text[start : text.index("\nend", start)]
        seek = body.index("C4:FileSetPos(handle, 0)")
        read = body.index("C4:FileRead(handle, count)")
        assert seek < read, f"{driver} {fn} must seek before reading"


def test_file_set_dir_unlocks_c4z_root_without_fallback_in_all_adapters() -> None:
    """Every file_set_dir adapter must unlock C4Z_ROOT first and try no fallback.

    Director rejects the C4Z_ROOT alias until the unlock key passes, and
    UpdateProjectC4i hot-reload resolves staged packages in C4Z_ROOT
    only: staging into the running driver's own directory verifies and
    triggers yet reloads the previously installed build (field no-op on
    2026090815). The three adapters are copy-pasted per driver by bundle
    design; this pins the invariant in all of them.
    """
    sources = {
        "cloud": (CLOUD_DIR / "cloud.lua").read_text(encoding="utf-8"),
        "valve": (VALVE_DIR / "valve.lua").read_text(encoding="utf-8"),
        "monolith": (C4_DIR / "src" / "main.lua").read_text(encoding="utf-8"),
    }
    fns = {
        "cloud": "flocloud_file_set_dir",
        "valve": "flovalve_file_set_dir",
        "monolith": "flogic_file_set_dir",
    }
    for driver, text in sources.items():
        fn = fns[driver]
        start = text.index(f"local function {fn}(")
        body = text[start : text.index("\nend", start)]
        unlock = body.index("C4:FileSetDir(FloUpdate.C4Z_ROOT_UNLOCK_KEY)")
        select = body.index("C4:FileSetDir(alias)")
        assert unlock < select, f"{driver} {fn} must pass the unlock key first"
        assert "candidates" not in body, f"{driver} {fn} must not try a fallback store"
    helpers = {
        "cloud": "flocloud_dir_accepted",
        "valve": "flovalve_dir_accepted",
        "monolith": "flogic_dir_accepted",
    }
    seen: set[str] = set()
    for driver, text in sources.items():
        helper = helpers[driver]
        start = text.index(f"local function {helper}(ok, ret, err)")
        body = text[start : text.index("\nend", start)]
        # Every refusal shape with any precedent denies: a raise (the pcall
        # status), an explicit false, -1 (Director sentinel style), or a
        # (nil, err) pair. The three copies stay in sync by bundle design.
        for fragment in ("ret ~= false", "ret ~= -1", "ret ~= nil or err == nil"):
            assert fragment in body, f"{driver} {helper} must deny that shape"
        seen.add(body.replace(helper, "dir_accepted"))
    assert len(seen) == 1, "dir_accepted copies must stay in sync"
