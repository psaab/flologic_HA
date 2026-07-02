"""FloLogic Home Assistant integration."""

from __future__ import annotations

from typing import Any

import voluptuous as vol

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import CONF_EMAIL, CONF_PASSWORD
from homeassistant.core import HomeAssistant, ServiceCall
import homeassistant.helpers.config_validation as cv
from homeassistant.helpers.aiohttp_client import async_get_clientsession

from .api import FloLogicClient
from .const import (
    CONF_DEVICE_CODE,
    CONF_DEVICE_NAME,
    CONF_DEVICE_TOKEN,
    CONF_HUB_URL,
    CONF_KEEP_SESSION_ALIVE,
    CONF_POLL_INTERVAL,
    DEFAULT_DEVICE_CODE,
    DEFAULT_DEVICE_NAME,
    DEFAULT_DEVICE_TOKEN,
    DEFAULT_HUB_URL,
    DEFAULT_KEEP_SESSION_ALIVE,
    DEFAULT_POLL_INTERVAL,
    DOMAIN,
    PLATFORMS,
)
from .coordinator import FloLogicCoordinator

SERVICE_SET_FLOW_SENSITIVITY = "set_flow_sensitivity"
SERVICE_SET_HOME_LIMIT = "set_home_limit"
SERVICE_SET_AWAY_LIMIT = "set_away_limit"
SERVICE_SET_BYPASS_TIME = "set_bypass_time"
SERVICE_SET_AUTO_AWAY = "set_auto_away"
SERVICE_SET_TEMP_ALERT = "set_temp_alert"
SERVICE_SET_TEMP_SHUTOFF = "set_temp_shutoff"
SERVICE_SET_PRE_ALERT = "set_pre_alert_notice"
SERVICE_SET_NO_FLOW_NOTICE = "set_no_flow_notice"

ATTR_VALUE = "value"
ATTR_MINUTES = "minutes"
ATTR_HOURS = "hours"
ATTR_SECONDS = "seconds"
ATTR_TEMPERATURE = "temperature"

WRITE_SERVICE_SCHEMAS = {
    SERVICE_SET_FLOW_SENSITIVITY: vol.Schema({vol.Required(ATTR_VALUE): vol.Coerce(float)}),
    SERVICE_SET_HOME_LIMIT: vol.Schema({vol.Required(ATTR_MINUTES): cv.positive_int}),
    SERVICE_SET_AWAY_LIMIT: vol.Schema({vol.Required(ATTR_MINUTES): vol.Coerce(float)}),
    SERVICE_SET_BYPASS_TIME: vol.Schema({vol.Required(ATTR_MINUTES): cv.positive_int}),
    SERVICE_SET_AUTO_AWAY: vol.Schema({vol.Required(ATTR_HOURS): cv.positive_int}),
    SERVICE_SET_TEMP_ALERT: vol.Schema({vol.Required(ATTR_TEMPERATURE): vol.Coerce(int)}),
    SERVICE_SET_TEMP_SHUTOFF: vol.Schema({vol.Required(ATTR_TEMPERATURE): vol.Coerce(int)}),
    SERVICE_SET_PRE_ALERT: vol.Schema({vol.Required(ATTR_MINUTES): cv.positive_int}),
    SERVICE_SET_NO_FLOW_NOTICE: vol.Schema({vol.Required(ATTR_SECONDS): cv.positive_int}),
}


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Set up FloLogic from a config entry."""
    session = async_get_clientsession(hass)
    client = FloLogicClient(
        email=entry.data[CONF_EMAIL],
        password=entry.data[CONF_PASSWORD],
        hub_url=entry.data.get(CONF_HUB_URL, DEFAULT_HUB_URL),
        device_name=entry.data.get(CONF_DEVICE_NAME, DEFAULT_DEVICE_NAME),
        device_code=entry.data.get(CONF_DEVICE_CODE, DEFAULT_DEVICE_CODE),
        device_token=entry.data.get(CONF_DEVICE_TOKEN, DEFAULT_DEVICE_TOKEN),
        session_factory=lambda: session,
        keep_session_alive=entry.options.get(CONF_KEEP_SESSION_ALIVE, DEFAULT_KEEP_SESSION_ALIVE),
    )
    coordinator = FloLogicCoordinator(
        hass,
        client,
        entry.options.get(CONF_POLL_INTERVAL, DEFAULT_POLL_INTERVAL),
    )
    await coordinator.async_config_entry_first_refresh()

    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = coordinator
    entry.async_on_unload(entry.add_update_listener(_async_update_listener))
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)

    _async_register_services(hass)
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Unload a FloLogic config entry."""
    unload_ok = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if unload_ok:
        coordinator = hass.data[DOMAIN].pop(entry.entry_id)
        await coordinator.client.async_close()
    return unload_ok


async def _async_update_listener(hass: HomeAssistant, entry: ConfigEntry) -> None:
    """Reload the integration when options change."""
    await hass.config_entries.async_reload(entry.entry_id)


def _async_register_services(hass: HomeAssistant) -> None:
    """Register FloLogic services once."""
    if hass.data.setdefault(DOMAIN, {}).get("_services_registered"):
        return

    async def handle_service(call: ServiceCall) -> None:
        coordinator = _get_first_coordinator(hass)
        fields = _service_call_to_command(call)
        await coordinator.client.async_request_state_change(fields)
        await coordinator.async_request_refresh()

    for service, schema in WRITE_SERVICE_SCHEMAS.items():
        hass.services.async_register(DOMAIN, service, handle_service, schema=schema)

    hass.data[DOMAIN]["_services_registered"] = True


def _get_first_coordinator(hass: HomeAssistant) -> FloLogicCoordinator:
    """Return the first configured FloLogic coordinator."""
    for key, value in hass.data.get(DOMAIN, {}).items():
        if key != "_services_registered":
            return value
    raise RuntimeError("No FloLogic config entry is loaded")


def _service_call_to_command(call: ServiceCall) -> dict[str, Any]:
    """Translate a Home Assistant service call to a FloLogic command."""
    data = call.data
    if call.service == SERVICE_SET_FLOW_SENSITIVITY:
        return {"dripRate": data[ATTR_VALUE]}
    if call.service == SERVICE_SET_HOME_LIMIT:
        return {"homeIntervalTime": data[ATTR_MINUTES]}
    if call.service == SERVICE_SET_AWAY_LIMIT:
        return {"awayIntervalTime": data[ATTR_MINUTES]}
    if call.service == SERVICE_SET_BYPASS_TIME:
        return {"bypassTime": data[ATTR_MINUTES]}
    if call.service == SERVICE_SET_AUTO_AWAY:
        return {"autoAwayTime": data[ATTR_HOURS]}
    if call.service == SERVICE_SET_TEMP_ALERT:
        return {"lowTemperatureAlert": data[ATTR_TEMPERATURE]}
    if call.service == SERVICE_SET_TEMP_SHUTOFF:
        return {"lowTemperatureLimit": data[ATTR_TEMPERATURE]}
    if call.service == SERVICE_SET_PRE_ALERT:
        return {"preAlertNoticeInterval": data[ATTR_MINUTES]}
    if call.service == SERVICE_SET_NO_FLOW_NOTICE:
        return {"noFlowNoticeInterval": data[ATTR_SECONDS]}
    raise RuntimeError(f"Unsupported FloLogic service: {call.service}")
