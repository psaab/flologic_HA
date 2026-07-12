"""FloLogic client-device identity helpers."""

from __future__ import annotations

import secrets
from uuid import uuid4

from homeassistant.core import HomeAssistant

from .const import (
    CONF_DEVICE_CODE,
    CONF_DEVICE_IDENTITY_VERSION,
    CONF_DEVICE_NAME,
    CONF_DEVICE_TOKEN,
    DEVICE_IDENTITY_VERSION,
)


def build_device_identity(hass: HomeAssistant) -> dict[str, str | int]:
    """Return a new app-like client-device identity for FloLogic."""
    return {
        CONF_DEVICE_NAME: _device_name(hass),
        CONF_DEVICE_CODE: f"AND-{uuid4()}",
        CONF_DEVICE_TOKEN: secrets.token_urlsafe(32),
        CONF_DEVICE_IDENTITY_VERSION: DEVICE_IDENTITY_VERSION,
    }


def _device_name(hass: HomeAssistant) -> str:
    """Return the mobile-device display name sent to FloLogic."""
    location_name = getattr(hass.config, "location_name", None)
    if isinstance(location_name, str) and location_name.strip():
        return f"Home Assistant {location_name.strip()}"
    return "Home Assistant"
