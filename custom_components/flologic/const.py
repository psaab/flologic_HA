"""Constants for the FloLogic integration."""

from __future__ import annotations

DOMAIN = "flologic"

CONF_DEVICE_NAME = "device_name"
CONF_DEVICE_CODE = "device_code"
CONF_DEVICE_TOKEN = "device_token"
CONF_DEVICE_IDENTITY_VERSION = "device_identity_version"
CONF_HIDDEN_ENTITY_DEFAULTS_VERSION = "hidden_entity_defaults_version"
CONF_OPTIONS_DEFAULTS_VERSION = "options_defaults_version"
CONF_HUB_URL = "hub_url"
CONF_POLL_INTERVAL = "poll_interval"
CONF_KEEP_SESSION_ALIVE = "keep_session_alive"
CONF_MONITORED_VALVES = "monitored_valves"

DEFAULT_DEVICE_NAME = "Home Assistant"
DEFAULT_DEVICE_CODE = "AND-ha-custom-001"
DEFAULT_DEVICE_TOKEN = "ha-custom-token"
DEVICE_IDENTITY_VERSION = 1
HIDDEN_ENTITY_DEFAULTS_VERSION = 1
OPTIONS_DEFAULTS_VERSION = 1
DEFAULT_HUB_URL = "https://hub-cloudapps-prod.azurewebsites.net"
DEFAULT_POLL_INTERVAL = 60
MIN_POLL_INTERVAL = 1
DEFAULT_KEEP_SESSION_ALIVE = True

PLATFORMS = ["sensor", "binary_sensor", "select"]

VALVE_MODES = {
    "home": 1,
    "away": 2,
    "bypass": 4,
    "shutoff": 8,
    "disabled": 16,
}

MODE_NAMES = {value: key for key, value in VALVE_MODES.items()}

VALVE_MODE_FLAGS = {
    "home": 1,
    "away": 2,
    "bypass": 4,
    "shutoff": 8,
    "disabled": 16,
    "flow_time_exceeded": 32,
    "external_leak": 64,
    "auto_away": 128,
    "external_bypass": 256,
    "delay_away": 512,
    "external_away": 1024,
    "override": 2048,
    "ac_lost": 4096,
    "change_battery": 8192,
    "error": 16384,
    "sensor_leak": 32768,
    "system_down": 65536,
    "valve_failure": 131072,
    "communication_error": 262144,
    "external_home": 524288,
    "external_emergency_shutdown": 1048576,
    "updating": 2097152,
    "external_override": 4194304,
    "low_temp_alert": 8388608,
    "low_temp_shutoff": 16777216,
    "humidity_sensor_shutoff": 33554432,
    "low_temp_sensor_shutoff": 67108864,
    "unknown": 268435456,
}

MODE_FLAG_NAMES = {value: key for key, value in VALVE_MODE_FLAGS.items()}

WATER_OFF_MODE_FLAGS = (
    VALVE_MODE_FLAGS["flow_time_exceeded"],
    VALVE_MODE_FLAGS["external_leak"],
    VALVE_MODE_FLAGS["sensor_leak"],
    VALVE_MODE_FLAGS["shutoff"],
    VALVE_MODE_FLAGS["external_emergency_shutdown"],
    VALVE_MODE_FLAGS["low_temp_shutoff"],
    VALVE_MODE_FLAGS["humidity_sensor_shutoff"],
    VALVE_MODE_FLAGS["low_temp_sensor_shutoff"],
)

WARNING_ALERT_MODE_FLAGS = (
    VALVE_MODE_FLAGS["low_temp_alert"],
    VALVE_MODE_FLAGS["change_battery"],
    VALVE_MODE_FLAGS["ac_lost"],
    VALVE_MODE_FLAGS["communication_error"],
    VALVE_MODE_FLAGS["updating"],
)

CRITICAL_MODE_FLAGS = (
    VALVE_MODE_FLAGS["error"],
    VALVE_MODE_FLAGS["system_down"],
    VALVE_MODE_FLAGS["valve_failure"],
    VALVE_MODE_FLAGS["unknown"],
)

MODE_STATUS_PRIORITY = (
    VALVE_MODE_FLAGS["flow_time_exceeded"],
    VALVE_MODE_FLAGS["sensor_leak"],
    VALVE_MODE_FLAGS["external_leak"],
    VALVE_MODE_FLAGS["external_emergency_shutdown"],
    VALVE_MODE_FLAGS["low_temp_shutoff"],
    VALVE_MODE_FLAGS["humidity_sensor_shutoff"],
    VALVE_MODE_FLAGS["low_temp_sensor_shutoff"],
    VALVE_MODE_FLAGS["shutoff"],
    VALVE_MODE_FLAGS["delay_away"],
    VALVE_MODE_FLAGS["auto_away"],
    VALVE_MODE_FLAGS["external_away"],
    VALVE_MODE_FLAGS["away"],
    VALVE_MODE_FLAGS["external_bypass"],
    VALVE_MODE_FLAGS["bypass"],
    VALVE_MODE_FLAGS["external_home"],
    VALVE_MODE_FLAGS["home"],
    VALVE_MODE_FLAGS["disabled"],
    VALVE_MODE_FLAGS["updating"],
    VALVE_MODE_FLAGS["communication_error"],
    VALVE_MODE_FLAGS["valve_failure"],
    VALVE_MODE_FLAGS["system_down"],
    VALVE_MODE_FLAGS["error"],
    VALVE_MODE_FLAGS["unknown"],
)

FLOW_STATE_NAMES = {
    1: "No flow",
    2: "New flow",
    4: "Flow",
    8: "Valve closed",
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
