"""Exercise config and options flows with a mocked cloud client."""

from unittest.mock import MagicMock, patch

import pytest
from homeassistant import config_entries
from homeassistant.exceptions import ServiceValidationError
from homeassistant.helpers import entity_registry as er
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.flologic.account_identity import account_unique_id
from custom_components.flologic.api import FloLogicClient
from custom_components.flologic.const import (
    CONF_KEEP_SESSION_ALIVE,
    CONF_MONITORED_VALVES,
    CONF_POLL_INTERVAL,
    DEFAULT_HUB_URL,
    DOMAIN,
)
from custom_components.flologic.exceptions import FloLogicError

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
    client.async_discover_accounts.return_value = accounts
    return client, accounts


async def test_config_flow_multi_valve_requires_selection(hass):
    """Setup with several valves stops at the selection step."""
    client, _accounts = make_two_valve_client()
    with (
        patch(
            "custom_components.flologic.config_flow.FloLogicClient", return_value=client
        ),
        patch("custom_components.flologic.async_setup_entry", return_value=True),
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
    client.async_discover_accounts.return_value = {
        "uuid-1": make_account(make_valve(id=11, uuid="uuid-1"))
    }
    with (
        patch(
            "custom_components.flologic.config_flow.FloLogicClient", return_value=client
        ),
        patch("custom_components.flologic.async_setup_entry", return_value=True),
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


async def test_multi_valve_setup_has_no_default_selection(hass):
    client, _ = make_two_valve_client()
    with patch(
        "custom_components.flologic.config_flow.FloLogicClient", return_value=client
    ):
        result = await hass.config_entries.flow.async_init(
            DOMAIN, context={"source": config_entries.SOURCE_USER}
        )
        result = await hass.config_entries.flow.async_configure(
            result["flow_id"], {"email": "u@example.com", "password": "pw"}
        )
    assert result["data_schema"]({})[CONF_MONITORED_VALVES] == []
    client.async_fetch_accounts.assert_not_awaited()


@pytest.mark.parametrize("legacy", [True, False])
async def test_duplicate_account_detection_ignores_valve_order(hass, legacy):
    client, accounts = make_two_valve_client()
    identity = account_unique_id(DEFAULT_HUB_URL, 7)
    entry = MockConfigEntry(
        domain=DOMAIN,
        unique_id="11" if legacy else identity,
        data={"email": "u@example.com", "password": "pw"},
        options={CONF_MONITORED_VALVES: ["uuid-1"]},
    )
    entry.add_to_hass(hass)
    client.async_discover_accounts.return_value = dict(reversed(list(accounts.items())))
    with patch(
        "custom_components.flologic.config_flow.FloLogicClient", return_value=client
    ):
        result = await hass.config_entries.flow.async_init(
            DOMAIN, context={"source": config_entries.SOURCE_USER}
        )
        result = await hass.config_entries.flow.async_configure(
            result["flow_id"], {"email": "u@example.com", "password": "pw"}
        )
    assert result["type"] == "abort"
    assert result["reason"] == "already_configured"
    assert entry.unique_id == identity


@pytest.mark.parametrize("discovery", ["missing", "empty", "offline"])
async def test_options_keep_missing_selection_and_discover_once(hass, discovery):
    client, accounts = make_two_valve_client()
    if discovery == "offline":
        client.async_discover_accounts.side_effect = FloLogicError("unreachable")
    else:
        client.async_discover_accounts.return_value = (
            {"uuid-2": accounts["uuid-2"]} if discovery == "missing" else {}
        )
    entry = MockConfigEntry(
        domain=DOMAIN,
        data={"email": "u@example.com", "password": "pw"},
        options={CONF_MONITORED_VALVES: ["uuid-1"]},
    )
    entry.add_to_hass(hass)
    with patch(
        "custom_components.flologic.config_flow.FloLogicClient", return_value=client
    ):
        result = await hass.config_entries.options.async_init(entry.entry_id)
        result = await hass.config_entries.options.async_configure(
            result["flow_id"],
            {
                CONF_POLL_INTERVAL: 120,
                CONF_KEEP_SESSION_ALIVE: True,
                CONF_MONITORED_VALVES: ["uuid-1"],
            },
        )
    assert result["type"] == "create_entry"
    assert entry.options[CONF_MONITORED_VALVES] == ["uuid-1"]
    assert entry.options[CONF_POLL_INTERVAL] == 120
    client.async_discover_accounts.assert_awaited_once()
    client.async_fetch_accounts.assert_not_awaited()


async def test_narrowing_selection_blocks_all_action_targets(hass):
    client, _ = make_two_valve_client()
    entry = MockConfigEntry(
        domain=DOMAIN,
        data={"email": "u@example.com", "password": "pw"},
        options={CONF_MONITORED_VALVES: ["uuid-1", "uuid-2"]},
    )
    entry.add_to_hass(hass)
    with (
        patch("custom_components.flologic.FloLogicClient", return_value=client),
        patch(
            "custom_components.flologic.config_flow.FloLogicClient", return_value=client
        ),
    ):
        assert await hass.config_entries.async_setup(entry.entry_id)
        await hass.async_block_till_done()
        entity_id = er.async_get(hass).async_get_entity_id(
            "select", DOMAIN, "uuid-2_valve_mode"
        )
        device_id = er.async_get(hass).async_get(entity_id).device_id
        result = await hass.config_entries.options.async_init(entry.entry_id)
        await hass.config_entries.options.async_configure(
            result["flow_id"],
            {
                CONF_POLL_INTERVAL: 60,
                CONF_KEEP_SESSION_ALIVE: True,
                CONF_MONITORED_VALVES: ["uuid-1"],
            },
        )
        await hass.async_block_till_done()
        assert set(hass.data[DOMAIN][entry.entry_id].accounts) == {"uuid-1"}
        for target in (
            {"valve_id": "uuid-2"},
            {"entity_id": [entity_id]},
            {"device_id": device_id},
        ):
            with pytest.raises(ServiceValidationError):
                await hass.services.async_call(
                    DOMAIN, "set_home_limit", {"minutes": 10, **target}, blocking=True
                )
        await hass.services.async_call(
            "select",
            "select_option",
            {"entity_id": entity_id, "option": "shutoff"},
            blocking=True,
        )
        client.async_request_state_change_for_valve.assert_not_awaited()


async def test_shared_valve_does_not_reidentify_another_cloud_account(hass):
    """Shared valve access does not prove that two logins are the same user."""
    client, _ = make_two_valve_client()
    entry = MockConfigEntry(
        domain=DOMAIN,
        unique_id="11",
        data={"email": "other@example.com", "password": "pw"},
    )
    entry.add_to_hass(hass)
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
    assert entry.unique_id == "11"
