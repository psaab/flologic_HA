"""Exercise config and options flows with a mocked cloud client."""

from unittest.mock import MagicMock, patch

from homeassistant import config_entries
from homeassistant.helpers import entity_registry as er
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.flologic.api import FloLogicClient
from custom_components.flologic.const import (
    CONF_KEEP_SESSION_ALIVE,
    CONF_MONITORED_VALVES,
    CONF_POLL_INTERVAL,
    DOMAIN,
)

from .test_api_logic import make_account, make_valve


def make_two_valve_client():
    """Return a mocked client pretending the account has two valves."""
    accounts = {
        "uuid-1": make_account(make_valve(id=11, uuid="uuid-1")),
        "uuid-2": make_account(
            make_valve(id=22, uuid="uuid-2", valveFriendlyName="Cabin")
        ),
    }
    client = MagicMock(spec=FloLogicClient)
    client.async_fetch_accounts.return_value = accounts
    return client, accounts


async def test_config_flow_multi_valve_requires_selection(hass):
    """Setup with several valves stops at the selection step."""
    client, _accounts = make_two_valve_client()
    with patch(
        "custom_components.flologic.config_flow.FloLogicClient", return_value=client
    ):
        result = await hass.config_entries.flow.async_init(
            DOMAIN, context={"source": config_entries.SOURCE_USER}
        )
        result = await hass.config_entries.flow.async_configure(
            result["flow_id"], {"email": "u@example.com", "password": "pw"}
        )
        assert result["type"] == "form"
        assert result["step_id"] == "select_valves"
        result = await hass.config_entries.flow.async_configure(
            result["flow_id"], {CONF_MONITORED_VALVES: []}
        )
        assert result["type"] == "form"
        result = await hass.config_entries.flow.async_configure(
            result["flow_id"], {CONF_MONITORED_VALVES: ["uuid-2"]}
        )
        assert result["type"] == "create_entry"
        assert result["options"][CONF_MONITORED_VALVES] == ["uuid-2"]
        assert result["title"] == "Cabin"


async def test_config_flow_single_valve_skips_selection(hass):
    """Setup with one valve records it without an extra step."""
    client = MagicMock(spec=FloLogicClient)
    client.async_fetch_accounts.return_value = {
        "uuid-1": make_account(make_valve(id=11, uuid="uuid-1"))
    }
    with patch(
        "custom_components.flologic.config_flow.FloLogicClient", return_value=client
    ):
        result = await hass.config_entries.flow.async_init(
            DOMAIN, context={"source": config_entries.SOURCE_USER}
        )
        result = await hass.config_entries.flow.async_configure(
            result["flow_id"], {"email": "u@example.com", "password": "pw"}
        )
        assert result["type"] == "create_entry"
        assert result["options"][CONF_MONITORED_VALVES] == ["uuid-1"]


async def test_options_flow_edits_monitored_valves(hass):
    """Widening the selection reloads the entry and adds entities."""
    client, _accounts = make_two_valve_client()
    entry = MockConfigEntry(
        domain=DOMAIN,
        data={"email": "u@example.com", "password": "pw"},
        options={
            CONF_POLL_INTERVAL: 60,
            CONF_KEEP_SESSION_ALIVE: True,
            CONF_MONITORED_VALVES: ["uuid-1"],
        },
        unique_id="account-1",
    )
    entry.add_to_hass(hass)
    with (
        patch("custom_components.flologic.FloLogicClient", return_value=client),
        patch(
            "custom_components.flologic.config_flow.FloLogicClient",
            return_value=client,
        ),
    ):
        assert await hass.config_entries.async_setup(entry.entry_id)
        await hass.async_block_till_done()
        coordinator = hass.data[DOMAIN][entry.entry_id]
        assert set(coordinator.accounts) == {"uuid-1"}

        result = await hass.config_entries.options.async_init(entry.entry_id)
        assert result["type"] == "form"
        result = await hass.config_entries.options.async_configure(
            result["flow_id"],
            {
                CONF_POLL_INTERVAL: 60,
                CONF_KEEP_SESSION_ALIVE: True,
                CONF_MONITORED_VALVES: ["uuid-1", "uuid-2"],
            },
        )
        assert result["type"] == "create_entry"
        await hass.async_block_till_done()

        assert entry.options[CONF_MONITORED_VALVES] == ["uuid-1", "uuid-2"]
        coordinator = hass.data[DOMAIN][entry.entry_id]
        assert set(coordinator.accounts) == {"uuid-1", "uuid-2"}
        registry = er.async_get(hass)
        assert registry.async_get_entity_id("sensor", DOMAIN, "uuid-2_mode")
