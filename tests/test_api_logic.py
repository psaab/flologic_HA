"""Pure-logic tests for the FloLogic cloud client.

These tests deliberately avoid importing Home Assistant: api.py, const.py and
exceptions.py only need aiohttp, so valve selection, account decoding and the
push-cache state machine can be covered without a HA test harness.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import pytest

from custom_components.flologic.api import (
    FloLogicAccount,
    FloLogicClient,
    _mode_value,
    choose_valve,
    controllable_valves,
)
from custom_components.flologic.const import VALVE_MODES


def make_valve(**overrides: Any) -> dict[str, Any]:
    """Build a valve dict with controllable defaults."""
    valve: dict[str, Any] = {
        "id": 11,
        "uuid": "uuid-1",
        "isZConnect": True,
        "isZGateway": False,
        "mode": 1,
        "online": True,
        "flowState": 1,
        "deviceTypeName": "Connect",
    }
    valve.update(overrides)
    return valve


def make_account(valve: dict[str, Any], **overrides: Any) -> FloLogicAccount:
    """Build an account snapshot for a valve."""
    kwargs: dict[str, Any] = {"user": {"id": 7}, "valve": valve}
    kwargs.update(overrides)
    return FloLogicAccount(**kwargs)


def make_client(**overrides: Any) -> FloLogicClient:
    """Build a client without any network resources."""
    kwargs: dict[str, Any] = {
        "email": "user@example.com",
        "password": "secret",
        "hub_url": "https://example.test",
        "device_name": "test",
        "device_code": "code",
        "device_token": "token",
        "keep_session_alive": True,
    }
    kwargs.update(overrides)
    return FloLogicClient(**kwargs)


# --- controllable_valves / choose_valve ---


def test_controllable_prefers_all_zconnect_valves() -> None:
    """A two-valve Z-Connect account must expose both valves."""
    first = make_valve(id=11, uuid="uuid-1")
    second = make_valve(id=22, uuid="uuid-2")
    gateway = make_valve(id=99, uuid="gw", isZConnect=False, isZGateway=True)
    assert controllable_valves([first, gateway, second]) == [first, second]
    assert choose_valve([first, gateway, second]) == first


def test_controllable_falls_back_to_anyconnect_without_gateway() -> None:
    valve = make_valve(isZConnect=False, isAnyConnect=True)
    gateway = make_valve(
        id=99, uuid="gw", isZConnect=False, isZGateway=True, isAnyConnect=True
    )
    assert controllable_valves([valve, gateway]) == [valve]


def test_controllable_falls_back_to_connect_name() -> None:
    valve = make_valve(
        isZConnect=False, deviceTypeName="G-Connect Valve", isZGateway=False
    )
    other = make_valve(id=99, uuid="other", isZConnect=False, deviceTypeName="Hub")
    assert controllable_valves([valve, other]) == [valve]


def test_controllable_falls_back_to_not_gateway() -> None:
    valve = make_valve(isZConnect=False, deviceTypeName="Thing")
    gateway = make_valve(
        id=99, uuid="gw", isZConnect=False, isZGateway=True, deviceTypeName="Hub"
    )
    assert controllable_valves([valve, gateway]) == [valve]


def test_controllable_empty_and_gateway_only() -> None:
    assert controllable_valves([]) == []
    assert choose_valve([]) is None
    gateway = make_valve(isZConnect=False, isZGateway=True, deviceTypeName="Hub")
    assert controllable_valves([gateway]) == [gateway]


# --- FloLogicAccount decoding ---


def test_unique_id_prefix_pins_uuid_over_id() -> None:
    assert make_account(make_valve()).unique_id_prefix == "uuid-1"
    assert make_account(make_valve(uuid=None, id=42)).unique_id_prefix == "42"


def test_mode_name_exact_and_flag_fallbacks() -> None:
    assert make_account(make_valve(mode=1)).mode_name == "home"
    assert make_account(make_valve(mode=2)).mode_name == "away"
    assert make_account(make_valve(mode=4)).mode_name == "bypass"
    assert make_account(make_valve(mode=8)).mode_name == "shutoff"
    # Combined flags resolve to the most relevant controllable mode.
    assert make_account(make_valve(mode=1 | 32)).mode_name == "shutoff"
    assert make_account(make_valve(mode=2 | 4)).mode_name == "bypass"
    assert make_account(make_valve(mode=2 | 128)).mode_name == "away"
    assert make_account(make_valve(mode=1 | 128)).mode_name == "home"
    assert make_account(make_valve(mode=16 | 128)).mode_name == "disabled"
    assert make_account(make_valve(mode=64)).mode_name == "shutoff"  # external_leak
    assert make_account(make_valve(mode=128)).mode_name is None  # auto_away alone
    assert make_account(make_valve(mode=None)).mode_name is None
    assert make_account(make_valve(mode="bogus")).mode_name is None


def test_mode_status_name_priority_and_unknown() -> None:
    assert make_account(make_valve(mode=1)).mode_status_name == "home"
    # flow_time_exceeded outranks the base mode in the status sensor.
    assert make_account(make_valve(mode=1 | 32)).mode_status_name == (
        "flow_time_exceeded"
    )
    assert make_account(make_valve(mode=None)).mode_status_name == "unknown"
    assert make_account(make_valve(mode=1 << 30)).mode_status_name == (
        f"unknown_{1 << 30}"
    )


def test_mode_flag_names() -> None:
    account = make_account(make_valve(mode=1 | 32))
    assert set(account.mode_flag_names) == {"home", "flow_time_exceeded"}
    assert make_account(make_valve(mode=None)).mode_flag_names == []


def test_notification_flags_decode() -> None:
    account = make_account(make_valve(), access={"notificationsList": 1 | 64})
    flags = account.notification_flags
    assert flags["always"] is True
    assert flags["advance_shutoff"] is True
    assert flags["never"] is False


def test_is_water_flowing_matrix() -> None:
    assert make_account(make_valve(online=True, flowState=2)).is_water_flowing is True
    assert make_account(make_valve(online=True, flowState=4)).is_water_flowing is True
    assert make_account(make_valve(online=True, flowState=1)).is_water_flowing is False
    assert make_account(make_valve(online=True, flowState=8)).is_water_flowing is False
    assert (
        make_account(make_valve(online=True, flowState=None)).is_water_flowing is False
    )
    assert make_account(make_valve(online=False, flowState=2)).is_water_flowing is False
    assert make_account(make_valve(online=None, flowState=2)).is_water_flowing is False


def test_flow_timing_and_countdown() -> None:
    started = datetime.now(UTC) - timedelta(seconds=60)
    account = make_account(
        make_valve(
            online=True,
            flowState=4,
            mode=1,
            homeIntervalTime=10,
            lastNewFlow=started.isoformat(),
        )
    )
    assert account.flow_started_at is not None
    assert 55 <= (account.flow_elapsed_seconds or 0) <= 65
    # 10-minute limit, 1 minute elapsed -> ~540 seconds left.
    assert 530 <= (account.shutoff_countdown_seconds or 0) <= 550


def test_countdown_none_when_idle_or_unlimited() -> None:
    idle = make_account(
        make_valve(online=True, flowState=1, mode=1, homeIntervalTime=10)
    )
    assert idle.shutoff_countdown_seconds is None
    assert idle.flow_started_at is None
    assert idle.flow_elapsed_seconds is None
    unlimited = make_account(
        make_valve(
            online=True,
            flowState=4,
            mode=16,  # disabled has no flow limit
            lastNewFlow=datetime.now(UTC).isoformat(),
        )
    )
    assert unlimited.shutoff_countdown_seconds is None


def test_advance_shutoff_warning_window() -> None:
    started = datetime.now(UTC) - timedelta(seconds=60)

    def warned(pre_alert: float, flag: bool) -> bool:
        return make_account(
            make_valve(
                online=True,
                flowState=4,
                mode=1,
                homeIntervalTime=10,
                preAlertNoticeInterval=pre_alert,
                lastNewFlow=started.isoformat(),
            ),
            access={"notificationsList": 64 if flag else 0},
        ).advance_shutoff_warning

    assert warned(10, True) is True  # 540s left inside the 600s window
    assert warned(1, True) is False  # 540s left outside the 60s window
    assert warned(10, False) is False  # cloud notification flag disabled


def test_active_scheduler_events_filters_empty() -> None:
    account = make_account(
        make_valve(),
        scheduler=[
            {"action": "mode", "actionPayload": {"mode": 1}},
            {"action": None, "actionPayload": None},
            {"action": "mode", "actionPayload": None},
        ],
    )
    assert account.active_scheduler_events == [
        {"action": "mode", "actionPayload": {"mode": 1}}
    ]


# --- valve lookup / mode validation ---


def test_find_valve_by_id_uuid_and_case() -> None:
    client = make_client()
    first = make_valve(id=11, uuid="AbC-123")
    second = make_valve(id=22, uuid="uuid-2")
    devices = [first, second]
    assert client._find_valve(devices, "11") == first
    assert client._find_valve(devices, "uuid-2") == second
    assert client._find_valve(devices, "abc-123") == first
    assert client._find_valve(devices, "nope") is None


def test_mode_value_rejects_unknown() -> None:
    assert _mode_value("home") == VALVE_MODES["home"]
    with pytest.raises(ValueError, match="bogus"):
        _mode_value("bogus")


# --- push-cache state machine ---


def seed_push_cache(
    client: FloLogicClient, *valves: dict[str, Any]
) -> dict[str, FloLogicAccount]:
    """Seed the persistent/push caches as if a poll just completed."""
    user = {"id": 7}
    client._persistent_user = user
    client._persistent_devices = list(valves)
    client._persistent_valves = {
        str(v.get("uuid") or v.get("id")): v for v in controllable_valves(list(valves))
    }
    client._persistent_valve = choose_valve(list(valves))
    accounts = {
        str(v.get("uuid") or v.get("id")): make_account(v, user=user) for v in valves
    }
    client._last_accounts = dict(accounts)
    client._last_account = next(iter(accounts.values()))
    return accounts


def test_lone_gateway_push_is_ignored() -> None:
    client = make_client()
    valve = make_valve()
    seed_push_cache(client, valve)
    received: list[dict[str, FloLogicAccount]] = []
    client.set_push_accounts_callback(received.append)

    gateway = make_valve(id=99, uuid="gw", isZConnect=False, isZGateway=True)
    client._handle_pushed_valves([gateway])

    assert received == []
    assert client._persistent_valve == valve
    assert client._persistent_devices == [valve]


def test_single_valve_push_merges_and_reuses_cached_rows() -> None:
    client = make_client()
    valve = make_valve()
    access = {"valveId": 11, "notificationsList": 64}
    scheduler = [{"action": "mode", "actionPayload": {"mode": 1}}]
    notifications = [{"id": 1}]
    seed_push_cache(client, valve)
    assert client._last_accounts is not None
    client._last_accounts["uuid-1"] = make_account(
        valve, access=access, scheduler=scheduler, notifications=notifications
    )
    received: list[dict[str, FloLogicAccount]] = []
    client.set_push_accounts_callback(received.append)

    updated = make_valve(mode=2, flowState=4)
    client._handle_pushed_valves([updated])

    assert len(received) == 1
    pushed = received[0]["uuid-1"]
    assert pushed.valve["mode"] == 2
    assert pushed.update_source == "push"
    # Cached poll-only rows survive the push; they are not refetched.
    assert pushed.access == access
    assert pushed.scheduler == scheduler
    assert pushed.notifications == notifications


def test_incremental_push_discovers_new_valve() -> None:
    client = make_client()
    valve = make_valve()
    seed_push_cache(client, valve)
    received: list[dict[str, FloLogicAccount]] = []
    client.set_push_accounts_callback(received.append)

    second = make_valve(id=22, uuid="uuid-2")
    client._handle_pushed_valves([second])

    assert len(received) == 1
    assert set(received[0]) == {"uuid-1", "uuid-2"}
    assert set(client._last_accounts or {}) == {"uuid-1", "uuid-2"}


def test_full_array_push_prunes_removed_valve() -> None:
    client = make_client()
    first = make_valve()
    second = make_valve(id=22, uuid="uuid-2")
    seed_push_cache(client, first, second)
    received: list[dict[str, FloLogicAccount]] = []
    client.set_push_accounts_callback(received.append)

    updated = make_valve(mode=2)
    gateway = make_valve(id=99, uuid="gw", isZConnect=False, isZGateway=True)
    client._handle_pushed_valves([updated, gateway], full_replace=True)

    assert len(received) == 1
    assert set(received[0]) == {"uuid-1"}
    assert set(client._last_accounts or {}) == {"uuid-1"}
    # Full array is authoritative: raw devices replaced, gateway kept as a
    # device but excluded from controllable accounts.
    assert client._persistent_devices == [updated, gateway]


def test_full_array_push_empty_is_ignored() -> None:
    client = make_client()
    seed_push_cache(client, make_valve())
    received: list[dict[str, FloLogicAccount]] = []
    client.set_push_accounts_callback(received.append)
    client._handle_pushed_valves([], full_replace=True)
    assert received == []
    assert set(client._last_accounts or {}) == {"uuid-1"}


def test_push_ignored_without_session_or_user() -> None:
    client = make_client(keep_session_alive=False)
    seed_push_cache(client, make_valve())
    received: list[dict[str, FloLogicAccount]] = []
    client.set_push_accounts_callback(received.append)
    client._handle_pushed_valves([make_valve(mode=2)])
    assert received == []

    client._keep_session_alive = True
    client._persistent_user = None
    client._handle_pushed_valves([make_valve(mode=2)])
    assert received == []


def test_persistent_event_routes_single_vs_array() -> None:
    client = make_client()
    first = make_valve()
    second = make_valve(id=22, uuid="uuid-2")
    seed_push_cache(client, first, second)
    received: list[dict[str, FloLogicAccount]] = []
    client.set_push_accounts_callback(received.append)

    # ValveSent merges: both valves still reported.
    client._handle_persistent_event("ValveSent", [make_valve(mode=2)])
    assert set(received[-1]) == {"uuid-1", "uuid-2"}

    # ValveArraySent replaces: the missing valve is pruned.
    updated = make_valve(mode=2)
    client._handle_persistent_event("ValveArraySent", [[updated]])
    assert set(received[-1]) == {"uuid-1"}
