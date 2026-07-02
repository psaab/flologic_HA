"""Constants for the FloLogic integration."""

from __future__ import annotations

DOMAIN = "flologic"

CONF_DEVICE_NAME = "device_name"
CONF_DEVICE_CODE = "device_code"
CONF_DEVICE_TOKEN = "device_token"
CONF_HUB_URL = "hub_url"
CONF_POLL_INTERVAL = "poll_interval"
CONF_KEEP_SESSION_ALIVE = "keep_session_alive"

DEFAULT_DEVICE_NAME = "Home Assistant"
DEFAULT_DEVICE_CODE = "AND-ha-custom-001"
DEFAULT_DEVICE_TOKEN = "ha-custom-token"
DEFAULT_HUB_URL = "https://hub-cloudapps-prod.azurewebsites.net"
DEFAULT_POLL_INTERVAL = 60
MIN_POLL_INTERVAL = 1
DEFAULT_KEEP_SESSION_ALIVE = False

PLATFORMS = ["sensor", "binary_sensor", "select"]

VALVE_MODES = {
    "home": 1,
    "away": 2,
    "bypass": 4,
    "shutoff": 8,
    "disabled": 16,
}

MODE_NAMES = {value: key for key, value in VALVE_MODES.items()}

FLOW_STATE_NAMES = {
    1: "no_flow",
    2: "new_flow",
    4: "flow",
    8: "valve_closed",
}

NOTIFICATION_FLAGS = {
    "always": 1,
    "never": 2,
    "mode_change": 4,
    "auto_shutoff": 8,
    "auto_away": 16,
    "delay_away": 32,
    "advance_shutoff": 64,
    "guest_mode": 128,
    "connection_change": 256,
    "general_alert": 512,
    "critical_error": 1024,
    "no_flow": 2048,
}
