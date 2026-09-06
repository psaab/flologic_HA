"""Run the Control4 driver's Lua suite under lupa.

The suite itself lives in c4/tests/run.lua with support files under c4/src
and c4/tests. Everything is concatenation-safe by design, so this wrapper
concatenates the same files bundle.sh uses (plus the test helpers) and
executes them in one lupa runtime with a stub C4 global. A failure inside
Lua raises through lupa and fails the test.
"""

from __future__ import annotations

from pathlib import Path

import lupa
import pytest

C4_DIR = Path(__file__).resolve().parent.parent / "c4"

LOAD_ORDER = [
    "src/json.lua",
    "src/model.lua",
    "src/signalr.lua",
    "src/websocket.lua",
    "src/flologic.lua",
    "src/main.lua",
    "tests/helpers.lua",
    "tests/run.lua",
]


def _read(name: str) -> str:
    return (C4_DIR / name).read_text(encoding="utf-8")


def test_lua_suite_passes() -> None:
    pytest.importorskip("lupa")
    runtime = lupa.LuaRuntime()
    runtime.execute("C4 = {}")  # main.lua must not call C4 at load time
    # run_all() calls os.exit(1) on failure, which would kill pytest itself.
    runtime.execute(
        "os.exit = function(code) error('suite exit: ' .. tostring(code)) end"
    )
    printed: list[str] = []
    runtime.globals().print = lambda *args: printed.append(" ".join(map(str, args)))
    chunk = "\n".join(_read(name) for name in LOAD_ORDER)
    runtime.execute(chunk)  # raises on any Lua error
    assert any(line.startswith("passed=") for line in printed), printed
    summary = next(line for line in printed if line.startswith("passed="))
    assert summary.endswith("failed=0"), summary


def test_bundled_driver_matches_sources() -> None:
    """driver.lua must be a fresh bundle.sh concatenation of src/*.lua."""
    bundled = (C4_DIR / "driver.lua").read_text(encoding="utf-8")
    assert "THIS FILE IS GENERATED" in bundled.splitlines()[1]
    for name in LOAD_ORDER[:6]:
        source = _read(name).strip()
        assert source in bundled, f"{name} not reflected in driver.lua"
