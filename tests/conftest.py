"""Shared test fixtures.

The pure-logic tests in this directory exercise api.py/const.py/exceptions.py,
which only need aiohttp at runtime. Importing them through the
``custom_components.flologic`` package executes the package ``__init__`` and
its Home Assistant imports, so stub those HA/voluptuous modules before any
test module is collected. Tests that need real HA behavior belong in a
separate harness-based suite, not here.
"""

from __future__ import annotations

import sys
from unittest.mock import MagicMock

_STUB_MODULES = (
    "homeassistant",
    "homeassistant.components",
    "homeassistant.components.binary_sensor",
    "homeassistant.components.select",
    "homeassistant.components.sensor",
    "homeassistant.config_entries",
    "homeassistant.const",
    "homeassistant.core",
    "homeassistant.data_entry_flow",
    "homeassistant.exceptions",
    "homeassistant.helpers",
    "homeassistant.helpers.aiohttp_client",
    "homeassistant.helpers.config_validation",
    "homeassistant.helpers.device_registry",
    "homeassistant.helpers.entity_platform",
    "homeassistant.helpers.entity_registry",
    "homeassistant.helpers.event",
    "homeassistant.helpers.update_coordinator",
    "voluptuous",
)

for _name in _STUB_MODULES:
    if _name not in sys.modules:
        sys.modules[_name] = MagicMock(name=f"stub-{_name}")
