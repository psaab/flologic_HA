"""Config flow for FloLogic."""

from __future__ import annotations

import voluptuous as vol

from homeassistant import config_entries
from homeassistant.const import CONF_EMAIL, CONF_PASSWORD
from homeassistant.data_entry_flow import FlowResult

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
    MIN_POLL_INTERVAL,
)
from .exceptions import FloLogicAuthError, FloLogicError


class FloLogicConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Handle a FloLogic config flow."""

    VERSION = 1

    @staticmethod
    def async_get_options_flow(config_entry: config_entries.ConfigEntry) -> FloLogicOptionsFlow:
        """Create the options flow."""
        return FloLogicOptionsFlow(config_entry)

    async def async_step_user(self, user_input: dict | None = None) -> FlowResult:
        """Handle the initial step."""
        errors: dict[str, str] = {}

        if user_input is not None:
            client = FloLogicClient(
                email=user_input[CONF_EMAIL],
                password=user_input[CONF_PASSWORD],
                hub_url=user_input[CONF_HUB_URL],
                device_name=user_input[CONF_DEVICE_NAME],
                device_code=user_input[CONF_DEVICE_CODE],
                device_token=user_input[CONF_DEVICE_TOKEN],
            )
            try:
                account = await client.async_fetch_account()
            except FloLogicAuthError:
                errors["base"] = "invalid_auth"
            except FloLogicError:
                errors["base"] = "cannot_connect"
            else:
                await self.async_set_unique_id(str(account.valve["id"]))
                self._abort_if_unique_id_configured()
                return self.async_create_entry(
                    title=account.valve_name,
                    data=user_input,
                    options={
                        CONF_POLL_INTERVAL: DEFAULT_POLL_INTERVAL,
                        CONF_KEEP_SESSION_ALIVE: DEFAULT_KEEP_SESSION_ALIVE,
                    },
                )

        schema = vol.Schema(
            {
                vol.Required(CONF_EMAIL): str,
                vol.Required(CONF_PASSWORD): str,
                vol.Optional(CONF_HUB_URL, default=DEFAULT_HUB_URL): str,
                vol.Optional(CONF_DEVICE_NAME, default=DEFAULT_DEVICE_NAME): str,
                vol.Optional(CONF_DEVICE_CODE, default=DEFAULT_DEVICE_CODE): str,
                vol.Optional(CONF_DEVICE_TOKEN, default=DEFAULT_DEVICE_TOKEN): str,
            }
        )
        return self.async_show_form(
            step_id="user",
            data_schema=schema,
            errors=errors,
        )


class FloLogicOptionsFlow(config_entries.OptionsFlow):
    """Handle FloLogic options."""

    def __init__(self, config_entry: config_entries.ConfigEntry) -> None:
        """Initialize the options flow."""
        self._config_entry = config_entry

    async def async_step_init(self, user_input: dict | None = None) -> FlowResult:
        """Manage FloLogic options."""
        errors: dict[str, str] = {}

        if user_input is not None:
            poll_interval = user_input[CONF_POLL_INTERVAL]
            if poll_interval < MIN_POLL_INTERVAL:
                errors[CONF_POLL_INTERVAL] = "interval_too_low"
            else:
                return self.async_create_entry(title="", data=user_input)

        options = self._config_entry.options
        schema = vol.Schema(
            {
                vol.Required(
                    CONF_POLL_INTERVAL,
                    default=options.get(CONF_POLL_INTERVAL, DEFAULT_POLL_INTERVAL),
                ): vol.All(vol.Coerce(int), vol.Range(min=MIN_POLL_INTERVAL)),
                vol.Required(
                    CONF_KEEP_SESSION_ALIVE,
                    default=options.get(CONF_KEEP_SESSION_ALIVE, DEFAULT_KEEP_SESSION_ALIVE),
                ): bool,
            }
        )
        return self.async_show_form(
            step_id="init",
            data_schema=schema,
            errors=errors,
        )
