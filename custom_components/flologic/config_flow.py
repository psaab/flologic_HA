"""Config flow for FloLogic."""

from __future__ import annotations

from typing import Any

import voluptuous as vol
from homeassistant import config_entries
from homeassistant.const import CONF_EMAIL, CONF_PASSWORD
from homeassistant.data_entry_flow import FlowResult
from homeassistant.helpers import selector

from .api import FloLogicAccount, FloLogicClient
from .const import (
    CONF_DEVICE_CODE,
    CONF_DEVICE_NAME,
    CONF_DEVICE_TOKEN,
    CONF_HUB_URL,
    CONF_KEEP_SESSION_ALIVE,
    CONF_MONITORED_VALVES,
    CONF_POLL_INTERVAL,
    DEFAULT_HUB_URL,
    DEFAULT_KEEP_SESSION_ALIVE,
    DEFAULT_POLL_INTERVAL,
    DOMAIN,
    MIN_POLL_INTERVAL,
)
from .device_identity import build_device_identity
from .exceptions import FloLogicAuthError, FloLogicError


def valve_option_label(account: FloLogicAccount) -> str:
    """Return a human-readable label for a valve selection option."""
    valve_id = account.valve.get("id")
    if valve_id is not None and str(valve_id) not in account.valve_name:
        return f"{account.valve_name} ({valve_id})"
    return account.valve_name


class FloLogicConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Handle a FloLogic config flow."""

    VERSION = 1

    def __init__(self) -> None:
        """Initialize the config flow."""
        self._entry_data: dict[str, Any] | None = None
        self._discovered: dict[str, FloLogicAccount] | None = None

    @staticmethod
    def async_get_options_flow(
        config_entry: config_entries.ConfigEntry,
    ) -> FloLogicOptionsFlow:
        """Create the options flow."""
        return FloLogicOptionsFlow(config_entry)

    async def async_step_user(self, user_input: dict | None = None) -> FlowResult:
        """Handle the initial step."""
        errors: dict[str, str] = {}

        if user_input is not None:
            data = {
                **user_input,
                **build_device_identity(self.hass),
            }
            client = FloLogicClient(
                email=data[CONF_EMAIL],
                password=data[CONF_PASSWORD],
                hub_url=data[CONF_HUB_URL],
                device_name=data[CONF_DEVICE_NAME],
                device_code=data[CONF_DEVICE_CODE],
                device_token=data[CONF_DEVICE_TOKEN],
            )
            try:
                accounts = await client.async_fetch_accounts()
            except FloLogicAuthError:
                errors["base"] = "invalid_auth"
            except FloLogicError:
                errors["base"] = "cannot_connect"
            else:
                first = next(iter(accounts.values()))
                await self.async_set_unique_id(str(first.valve["id"]))
                self._abort_if_unique_id_configured()
                self._entry_data = data
                self._discovered = accounts
                if len(accounts) == 1:
                    # No choice to make: monitor the only valve.
                    return self._async_create_entry([next(iter(accounts))])
                return await self.async_step_select_valves()

        schema = vol.Schema(
            {
                vol.Required(CONF_EMAIL): str,
                vol.Required(CONF_PASSWORD): str,
                vol.Optional(CONF_HUB_URL, default=DEFAULT_HUB_URL): str,
            }
        )
        return self.async_show_form(
            step_id="user",
            data_schema=schema,
            errors=errors,
        )

    async def async_step_select_valves(
        self, user_input: dict | None = None
    ) -> FlowResult:
        """Let the user choose which valves this install monitors."""
        assert self._entry_data is not None
        assert self._discovered is not None
        errors: dict[str, str] = {}

        if user_input is not None:
            monitored = list(user_input.get(CONF_MONITORED_VALVES) or [])
            unknown = [key for key in monitored if key not in self._discovered]
            if not monitored:
                errors["base"] = "no_valve_selected"
            elif unknown:
                errors["base"] = "unknown_valve_selected"
            else:
                return self._async_create_entry(monitored)

        options = [
            selector.SelectOptionDict(value=key, label=valve_option_label(acct))
            for key, acct in self._discovered.items()
        ]
        # Default to the first valve only: this install may be one of several
        # homes on the account, so never assume every valve belongs here.
        schema = vol.Schema(
            {
                vol.Required(
                    CONF_MONITORED_VALVES,
                    default=[next(iter(self._discovered))],
                ): selector.SelectSelector(
                    selector.SelectSelectorConfig(
                        options=options,
                        multiple=True,
                        mode=selector.SelectSelectorMode.LIST,
                    )
                ),
            }
        )
        return self.async_show_form(
            step_id="select_valves",
            data_schema=schema,
            errors=errors,
        )

    def _async_create_entry(self, monitored: list[str]) -> FlowResult:
        """Create the config entry with an explicit valve selection."""
        assert self._entry_data is not None
        assert self._discovered is not None
        primary = self._discovered[monitored[0]]
        return self.async_create_entry(
            title=primary.valve_name,
            data=self._entry_data,
            options={
                CONF_POLL_INTERVAL: DEFAULT_POLL_INTERVAL,
                CONF_KEEP_SESSION_ALIVE: DEFAULT_KEEP_SESSION_ALIVE,
                CONF_MONITORED_VALVES: monitored,
            },
        )


class FloLogicOptionsFlow(config_entries.OptionsFlow):
    """Handle FloLogic options."""

    def __init__(self, config_entry: config_entries.ConfigEntry) -> None:
        """Initialize the options flow."""
        self._config_entry = config_entry

    async def async_step_init(self, user_input: dict | None = None) -> FlowResult:
        """Manage FloLogic options."""
        errors: dict[str, str] = {}
        options = self._config_entry.options
        discovered = await self._async_discover_valves()

        if user_input is not None:
            poll_interval = user_input[CONF_POLL_INTERVAL]
            monitored = list(user_input.get(CONF_MONITORED_VALVES) or [])
            if poll_interval < MIN_POLL_INTERVAL:
                errors[CONF_POLL_INTERVAL] = "interval_too_low"
            elif not monitored:
                errors["base"] = "no_valve_selected"
            elif discovered is not None and any(
                key not in discovered for key in monitored
            ):
                errors["base"] = "unknown_valve_selected"
            else:
                return self.async_create_entry(title="", data=user_input)

        currently_monitored = list(options.get(CONF_MONITORED_VALVES) or [])
        if discovered is not None:
            valve_options = [
                selector.SelectOptionDict(value=key, label=valve_option_label(acct))
                for key, acct in discovered.items()
            ]
            # Keep a vanished selection visible so the user decides what
            # happens to it instead of silently deselecting it.
            valve_options.extend(
                selector.SelectOptionDict(
                    value=key, label=f"{key} (not found on account)"
                )
                for key in currently_monitored
                if key not in discovered
            )
            default_monitored = [
                key
                for key in currently_monitored
                if any(opt["value"] == key for opt in valve_options)
            ] or [next(iter(discovered))]
        else:
            # Cloud unreachable: only offer the current selection so other
            # options stay editable without destroying it.
            errors["base"] = "cannot_connect"
            valve_options = [
                selector.SelectOptionDict(value=key, label=key)
                for key in currently_monitored
            ]
            default_monitored = currently_monitored

        schema = vol.Schema(
            {
                vol.Required(
                    CONF_POLL_INTERVAL,
                    default=options.get(CONF_POLL_INTERVAL, DEFAULT_POLL_INTERVAL),
                ): vol.All(vol.Coerce(int), vol.Range(min=MIN_POLL_INTERVAL)),
                vol.Required(
                    CONF_KEEP_SESSION_ALIVE,
                    default=options.get(
                        CONF_KEEP_SESSION_ALIVE, DEFAULT_KEEP_SESSION_ALIVE
                    ),
                ): bool,
                vol.Required(
                    CONF_MONITORED_VALVES,
                    default=default_monitored,
                ): selector.SelectSelector(
                    selector.SelectSelectorConfig(
                        options=valve_options,
                        multiple=True,
                        mode=selector.SelectSelectorMode.LIST,
                    )
                ),
            }
        )
        return self.async_show_form(
            step_id="init",
            data_schema=schema,
            errors=errors,
        )

    async def _async_discover_valves(self) -> dict[str, FloLogicAccount] | None:
        """Return every valve on the account, or None if unreachable."""
        data = self._config_entry.data
        client = FloLogicClient(
            email=data[CONF_EMAIL],
            password=data[CONF_PASSWORD],
            hub_url=data.get(CONF_HUB_URL, DEFAULT_HUB_URL),
            device_name=data.get(CONF_DEVICE_NAME, ""),
            device_code=data.get(CONF_DEVICE_CODE, ""),
            device_token=data.get(CONF_DEVICE_TOKEN, ""),
        )
        try:
            return await client.async_fetch_accounts()
        except FloLogicError:
            return None
