"""Exercise actions and entity lifecycles with real Home Assistant registries."""

import logging
from unittest.mock import MagicMock, patch

import pytest
import voluptuous as vol
from homeassistant.const import STATE_UNAVAILABLE
from homeassistant.exceptions import HomeAssistantError, ServiceValidationError
from homeassistant.helpers import device_registry as dr
from homeassistant.helpers import entity_registry as er
from homeassistant.helpers import issue_registry as ir
from homeassistant.setup import async_setup_component
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.flologic.api import FloLogicClient
from custom_components.flologic.const import DOMAIN
from custom_components.flologic.exceptions import FloLogicError

from .test_api_logic import make_account, make_valve


@pytest.fixture
async def loaded_entries(hass):
    """Load two accounts with one valve each through normal integration setup."""
    entries = []
    clients = []
    for number in (1, 2):
        entry = MockConfigEntry(
            domain=DOMAIN,
            data={"email": f"user{number}@example.com", "password": "secret"},
            options={"monitored_valves": [f"uuid-{number}"]},
            unique_id=f"account-{number}",
        )
        entry.add_to_hass(hass)
        account = make_account(make_valve(id=number * 11, uuid=f"uuid-{number}"))
        client = MagicMock(spec=FloLogicClient)
        client.async_fetch_accounts.return_value = {account.unique_id_prefix: account}
        with patch("custom_components.flologic.FloLogicClient", return_value=client):
            assert await hass.config_entries.async_setup(entry.entry_id)
            await hass.async_block_till_done()
        entries.append(entry)
        clients.append(client)
    return entries, clients


async def call_action(hass, **targets):
    """Call an action through HA's schema validation and service registry."""
    await hass.services.async_call(
        DOMAIN, "set_home_limit", {"minutes": 10, **targets}, blocking=True
    )


async def test_services_registered_without_loaded_entries(hass):
    assert await async_setup_component(hass, DOMAIN, {})
    assert hass.services.has_service(DOMAIN, "set_home_limit")
    with pytest.raises(ServiceValidationError, match="No FloLogic valves"):
        await call_action(hass)


@pytest.mark.parametrize(
    "targets",
    [
        {},
        {"valve_id": "uuid-1", "device_id": "unknown"},
        {"valve_id": "uuid-1", "valve_uuid": "uuid-2"},
        {"valve_id": "uuid-1", "entity_id": []},
        {"valve_id": ""},
        {"valve_uuid": " "},
        {"device_id": ""},
        {"entity_id": []},
        {"valve_id": "unknown"},
        {"device_id": "uuid-1"},
        {"entity_id": ["sensor.unknown"]},
    ],
)
async def test_invalid_targets_never_send_commands(hass, loaded_entries, targets):
    _, clients = loaded_entries
    with pytest.raises((ServiceValidationError, vol.Invalid)):
        await call_action(hass, **targets)
    for client in clients:
        client.async_request_state_change_for_valve.assert_not_awaited()


@pytest.mark.parametrize(
    "target_field", ["valve_id", "valve_uuid", "device_id", "entity_id"]
)
async def test_target_second_account(hass, loaded_entries, target_field):
    entries, clients = loaded_entries
    device = dr.async_get(hass).async_get_device_by_identifier(
        (DOMAIN, "uuid-2"), entries[1].entry_id
    )
    entity_id = er.async_get(hass).async_get_entity_id(
        "select", DOMAIN, "uuid-2_valve_mode"
    )
    value = {"device_id": device.id, "entity_id": [entity_id]}.get(
        target_field, "uuid-2"
    )
    await call_action(hass, **{target_field: value})
    clients[0].async_request_state_change_for_valve.assert_not_awaited()
    clients[1].async_request_state_change_for_valve.assert_awaited_once_with(
        "uuid-2", {"homeIntervalTime": 10}
    )


async def test_entity_targets_deduplicate_across_accounts(hass, loaded_entries):
    _, clients = loaded_entries
    registry = er.async_get(hass)
    entity_ids = [
        registry.async_get_entity_id(domain, DOMAIN, f"uuid-{number}_{key}")
        for number in (1, 2)
        for domain, key in (("select", "valve_mode"), ("binary_sensor", "online"))
    ]
    await call_action(hass, entity_id=entity_ids)
    for number, client in enumerate(clients, start=1):
        client.async_request_state_change_for_valve.assert_awaited_once_with(
            f"uuid-{number}", {"homeIntervalTime": 10}
        )


async def test_validate_all_entities_before_sending(hass, loaded_entries):
    _, clients = loaded_entries
    entity_id = er.async_get(hass).async_get_entity_id(
        "select", DOMAIN, "uuid-1_valve_mode"
    )
    with pytest.raises(ServiceValidationError):
        await call_action(hass, entity_id=[entity_id, "sensor.unknown"])
    for client in clients:
        client.async_request_state_change_for_valve.assert_not_awaited()


@pytest.mark.parametrize("wrong_platform", [True, False])
async def test_entity_must_belong_to_device_account(
    hass, loaded_entries, wrong_platform
):
    entries, clients = loaded_entries
    device = dr.async_get(hass).async_get_device_by_identifier(
        (DOMAIN, "uuid-1"), entries[0].entry_id
    )
    entity = er.async_get(hass).async_get_or_create(
        "sensor",
        "other_integration" if wrong_platform else DOMAIN,
        "uuid-1_unrelated",
        config_entry=entries[0] if wrong_platform else entries[1],
        device_id=device.id,
    )
    with pytest.raises(ServiceValidationError):
        await call_action(hass, entity_id=[entity.entity_id])
    for client in clients:
        client.async_request_state_change_for_valve.assert_not_awaited()


async def test_ambiguous_cloud_id_requires_registry_target(hass, loaded_entries):
    entries, clients = loaded_entries
    coordinator = hass.data[DOMAIN][entries[1].entry_id]
    account = make_account(make_valve(id=11, uuid="uuid-2"))
    coordinator.async_set_updated_data({"uuid-2": account})
    with pytest.raises(ServiceValidationError, match="ambiguous"):
        await call_action(hass, valve_id="11")
    for client in clients:
        client.async_request_state_change_for_valve.assert_not_awaited()


@pytest.mark.parametrize("all_fail", [True, False])
async def test_command_failures(hass, loaded_entries, all_fail, caplog):
    _, clients = loaded_entries
    clients[0].async_request_state_change_for_valve.side_effect = FloLogicError(
        "offline"
    )
    if all_fail:
        clients[1].async_request_state_change_for_valve.side_effect = FloLogicError(
            "offline"
        )
    entity_ids = [
        er.async_get(hass).async_get_entity_id(
            "select", DOMAIN, f"uuid-{number}_valve_mode"
        )
        for number in (1, 2)
    ]
    if all_fail:
        with pytest.raises(HomeAssistantError, match="offline"):
            await call_action(hass, entity_id=entity_ids)
    else:
        await call_action(hass, entity_id=entity_ids)
        assert "uuid-1: offline" in caplog.text
    for client in clients:
        client.async_request_state_change_for_valve.assert_awaited_once()


async def test_dynamic_entities_removal_return_and_unload(hass, loaded_entries):
    entries, clients = loaded_entries
    coordinator = hass.data[DOMAIN][entries[0].entry_id]
    push = clients[0].set_push_accounts_callback.call_args.args[0]
    initial = dict(coordinator.accounts)
    # Dynamic discovery only applies to monitored valves (see the options-flow
    # test for widening the selection); declare uuid-3 monitored first.
    coordinator.monitored_valves.add("uuid-3")
    added = make_account(make_valve(id=33, uuid="uuid-3", mode=2))
    push({**initial, "uuid-3": added})
    await hass.async_block_till_done()
    registry = er.async_get(hass)
    entity_ids = [
        registry.async_get_entity_id(domain, DOMAIN, f"uuid-3_{key}")
        for domain, key in (
            ("sensor", "mode"),
            ("binary_sensor", "online"),
            ("select", "valve_mode"),
        )
    ]
    assert all(entity_ids)
    assert hass.states.get(entity_ids[-1]).state == "away"
    push(initial)
    await hass.async_block_till_done()
    assert all(
        hass.states.get(entity_id).state == STATE_UNAVAILABLE
        for entity_id in entity_ids
    )
    entity_count = len(registry.entities)
    push({**initial, "uuid-3": added})
    await hass.async_block_till_done()
    assert len(registry.entities) == entity_count
    assert hass.states.get(entity_ids[-1]).state == "away"

    assert await hass.config_entries.async_unload(entries[0].entry_id)
    await hass.async_block_till_done()
    assert not coordinator._listeners
    clients[0].async_close.assert_awaited_once()
    # The remaining account is now the only implicit target.
    await call_action(hass)
    clients[1].async_request_state_change_for_valve.assert_awaited_once_with(
        "uuid-2", {"homeIntervalTime": 10}
    )
    assert await hass.config_entries.async_unload(entries[1].entry_id)
    await hass.async_block_till_done()
    assert hass.services.has_service(DOMAIN, "set_home_limit")
    with pytest.raises(ServiceValidationError, match="No FloLogic valves"):
        await call_action(hass)


@pytest.fixture
async def monitored_entry(hass):
    """Load one account with two valves but a single-valve selection."""
    entry = MockConfigEntry(
        domain=DOMAIN,
        data={"email": "user@example.com", "password": "secret"},
        options={"monitored_valves": ["uuid-1"]},
        unique_id="account-1",
    )
    entry.add_to_hass(hass)
    accounts = {
        "uuid-1": make_account(make_valve(id=11, uuid="uuid-1")),
        "uuid-2": make_account(make_valve(id=22, uuid="uuid-2")),
    }
    client = MagicMock(spec=FloLogicClient)
    client.async_fetch_accounts.return_value = accounts
    with patch("custom_components.flologic.FloLogicClient", return_value=client):
        assert await hass.config_entries.async_setup(entry.entry_id)
        await hass.async_block_till_done()
    return entry, client, accounts


async def test_monitored_selection_filters_entities_and_targets(hass, monitored_entry):
    """Unmonitored valves get no entities and reject action targets."""
    entry, client, _accounts = monitored_entry
    coordinator = hass.data[DOMAIN][entry.entry_id]
    assert set(coordinator.accounts) == {"uuid-1"}
    registry = er.async_get(hass)
    assert registry.async_get_entity_id("sensor", DOMAIN, "uuid-1_mode")
    assert registry.async_get_entity_id("sensor", DOMAIN, "uuid-2_mode") is None
    assert registry.async_get_entity_id("select", DOMAIN, "uuid-2_valve_mode") is None
    # The single monitored valve is the implicit target.
    await call_action(hass)
    client.async_request_state_change_for_valve.assert_awaited_once_with(
        "uuid-1", {"homeIntervalTime": 10}
    )
    # The unmonitored valve cannot be reached, even explicitly.
    with pytest.raises(ServiceValidationError, match="uuid-2"):
        await call_action(hass, valve_id="uuid-2")
    client.async_request_state_change_for_valve.assert_awaited_once()


async def test_legacy_entry_freezes_selection_and_ignores_new_valves(hass):
    """Entries without a selection keep all valves but never auto-add more."""
    entry = MockConfigEntry(
        domain=DOMAIN,
        data={"email": "user@example.com", "password": "secret"},
        unique_id="account-legacy",
    )
    entry.add_to_hass(hass)
    for valve_id in ("uuid-1", "uuid-2"):
        dr.async_get(hass).async_get_or_create(
            config_entry_id=entry.entry_id, identifiers={(DOMAIN, valve_id)}
        )
    accounts = {
        "uuid-1": make_account(make_valve(id=11, uuid="uuid-1")),
        "uuid-2": make_account(make_valve(id=22, uuid="uuid-2")),
    }
    client = MagicMock(spec=FloLogicClient)
    client.async_fetch_accounts.return_value = accounts
    with patch("custom_components.flologic.FloLogicClient", return_value=client):
        assert await hass.config_entries.async_setup(entry.entry_id)
        await hass.async_block_till_done()
    assert entry.options["monitored_valves"] == ["uuid-1", "uuid-2"]

    coordinator = hass.data[DOMAIN][entry.entry_id]
    push = client.set_push_accounts_callback.call_args.args[0]
    added = make_account(make_valve(id=33, uuid="uuid-3", mode=2))
    push({**accounts, "uuid-3": added})
    await hass.async_block_till_done()
    assert set(coordinator.accounts) == {"uuid-1", "uuid-2"}
    registry = er.async_get(hass)
    assert registry.async_get_entity_id("sensor", DOMAIN, "uuid-3_mode") is None

    client.async_fetch_accounts.return_value = {**accounts, "uuid-3": added}
    await coordinator.async_refresh()
    await hass.async_block_till_done()
    assert set(coordinator.accounts) == {"uuid-1", "uuid-2"}
    assert registry.async_get_entity_id("sensor", DOMAIN, "uuid-3_mode") is None


async def test_missing_monitored_valve_is_unavailable(hass, monitored_entry, caplog):
    """A monitored valve that vanishes leaves its entities unavailable."""
    entry, client, accounts = monitored_entry
    coordinator = hass.data[DOMAIN][entry.entry_id]
    entity_id = er.async_get(hass).async_get_entity_id("sensor", DOMAIN, "uuid-1_mode")
    assert hass.states.get(entity_id).state != STATE_UNAVAILABLE
    client.async_fetch_accounts.return_value = {"uuid-2": accounts["uuid-2"]}
    await coordinator.async_refresh()
    await hass.async_block_till_done()
    assert hass.states.get(entity_id).state == STATE_UNAVAILABLE
    assert "did not return monitored valves" in caplog.text


async def test_push_removal_and_recovery_log_once(hass, monitored_entry, caplog):
    """An unrelated-only inventory immediately invalidates the selected valve."""
    entry, client, accounts = monitored_entry
    coordinator = hass.data[DOMAIN][entry.entry_id]
    entity_id = er.async_get(hass).async_get_entity_id(
        "select", DOMAIN, "uuid-1_valve_mode"
    )
    push = client.set_push_accounts_callback.call_args.args[0]
    caplog.set_level(logging.INFO)
    for _ in range(2):
        push({"uuid-2": accounts["uuid-2"]})
    client.async_fetch_accounts.return_value = {"uuid-2": accounts["uuid-2"]}
    await coordinator.async_refresh()
    assert hass.states.get(entity_id).state == STATE_UNAVAILABLE
    assert caplog.text.count("did not return monitored valves") == 1
    for _ in range(2):
        push(accounts)
    assert hass.states.get(entity_id).state == "home"
    assert caplog.text.count("available again") == 1


async def test_legacy_migration_preserves_missing_registered_valve(hass):
    """Cloud inventory must neither drop missing devices nor add new ones."""
    entry = MockConfigEntry(
        domain=DOMAIN, unique_id="11", data={"email": "u@example.com", "password": "pw"}
    )
    entry.add_to_hass(hass)
    for key in ("uuid-1", "uuid-2"):
        dr.async_get(hass).async_get_or_create(
            config_entry_id=entry.entry_id, identifiers={(DOMAIN, key)}
        )
    client = MagicMock(spec=FloLogicClient)
    client.account_unique_id = "https://example.test::7"
    first = make_account(make_valve())
    new = make_account(make_valve(id=33, uuid="uuid-3"))
    client.async_fetch_accounts.return_value = {"uuid-1": first, "uuid-3": new}
    with patch("custom_components.flologic.FloLogicClient", return_value=client):
        assert await hass.config_entries.async_setup(entry.entry_id)
        await hass.async_block_till_done()
    assert entry.options["monitored_valves"] == ["uuid-1", "uuid-2"]
    assert entry.unique_id == "https://example.test::7"
    coordinator = hass.data[DOMAIN][entry.entry_id]
    assert (
        coordinator.monitored_valves == client.monitored_valves == {"uuid-1", "uuid-2"}
    )
    second = make_account(make_valve(id=22, uuid="uuid-2"))
    client.set_push_accounts_callback.call_args.args[0](
        {"uuid-1": first, "uuid-2": second, "uuid-3": new}
    )
    await hass.async_block_till_done()
    registry = er.async_get(hass)
    assert registry.async_get_entity_id("select", DOMAIN, "uuid-2_valve_mode")
    assert registry.async_get_entity_id("select", DOMAIN, "uuid-3_valve_mode") is None


async def test_legacy_without_registry_requires_selection(hass):
    """Lack of migration evidence cannot authorize account-wide monitoring."""
    entry = MockConfigEntry(
        domain=DOMAIN, data={"email": "u@example.com", "password": "pw"}
    )
    entry.add_to_hass(hass)
    client = MagicMock(spec=FloLogicClient)
    client.async_fetch_accounts.return_value = {"uuid-1": make_account(make_valve())}
    with patch("custom_components.flologic.FloLogicClient", return_value=client):
        assert await hass.config_entries.async_setup(entry.entry_id)
        await hass.async_block_till_done()
    assert entry.options["monitored_valves"] == []
    assert hass.data[DOMAIN][entry.entry_id].accounts == {}
    assert ir.async_get(hass).async_get_issue(DOMAIN, f"select_valves_{entry.entry_id}")
    assert not er.async_entries_for_config_entry(er.async_get(hass), entry.entry_id)
    with pytest.raises(ServiceValidationError):
        await call_action(hass)
    client.async_request_state_change_for_valve.assert_not_awaited()
