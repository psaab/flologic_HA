"""Minimal FloLogic SignalR cloud client."""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections.abc import Awaitable, Callable
from contextlib import suppress
from dataclasses import dataclass, field, replace
from datetime import UTC, datetime
from typing import Any
from urllib.parse import quote

import aiohttp

from .const import (
    MODE_FLAG_NAMES,
    MODE_NAMES,
    MODE_STATUS_PRIORITY,
    NOTIFICATION_FLAGS,
    VALVE_MODES,
    WATER_OFF_MODE_FLAGS,
)
from .exceptions import FloLogicAuthError, FloLogicError, FloLogicTimeoutError

_LOGGER = logging.getLogger(__name__)

_RECORD_SEPARATOR = "\x1e"
_ARRAY_PROBE_INTERVAL_SECONDS = 3600


@dataclass(slots=True)
class FloLogicAccount:
    """FloLogic account/device snapshot."""

    user: dict[str, Any]
    valve: dict[str, Any]
    devices: list[dict[str, Any]] = field(default_factory=list)
    access: dict[str, Any] | None = None
    scheduler: list[dict[str, Any]] = field(default_factory=list)
    notifications: list[dict[str, Any]] = field(default_factory=list)
    update_source: str = "poll"

    @property
    def valve_name(self) -> str:
        """Return a friendly valve name."""
        return (
            self.valve.get("valveFriendlyName")
            or self.valve.get("combinedName")
            or self.valve.get("name")
            or self.valve.get("uuid")
            or "FloLogic"
        )

    @property
    def unique_id_prefix(self) -> str:
        """Return a stable unique ID prefix.

        Pinned to uuid-or-id: existing installs already use this key for
        entity unique_ids, so changing the preference would churn every
        entity id and lose history/automations. Do not reorder.
        """
        return str(self.valve.get("uuid") or self.valve.get("id"))

    @property
    def mode_name(self) -> str | None:
        """Return the current controllable mode name."""
        mode = self.valve.get("mode")
        mode_value = self._int_or_none(mode)
        if mode_value is None:
            return None
        exact = MODE_NAMES.get(mode_value)
        if exact is not None:
            return exact
        if self._has_any_mode_flag(mode_value, WATER_OFF_MODE_FLAGS):
            return "shutoff"
        if mode_value & VALVE_MODES["bypass"]:
            return "bypass"
        if mode_value & VALVE_MODES["away"]:
            return "away"
        if mode_value & VALVE_MODES["home"]:
            return "home"
        if mode_value & VALVE_MODES["disabled"]:
            return "disabled"
        return None

    @property
    def mode_status_name(self) -> str:
        """Return the most specific current mode/status name."""
        mode_value = self._int_or_none(self.valve.get("mode"))
        if mode_value is None:
            return "unknown"
        exact = MODE_NAMES.get(mode_value)
        if exact is not None:
            return exact
        for flag in MODE_STATUS_PRIORITY:
            if mode_value & flag:
                return MODE_FLAG_NAMES[flag]
        return f"unknown_{mode_value}"

    @property
    def mode_flag_names(self) -> list[str]:
        """Return every known mode flag currently set."""
        mode_value = self._int_or_none(self.valve.get("mode"))
        if mode_value is None:
            return []
        return [name for flag, name in MODE_FLAG_NAMES.items() if mode_value & flag]

    @property
    def notification_flags(self) -> dict[str, bool]:
        """Return decoded notification settings."""
        raw = 0
        if self.access:
            raw = int(self.access.get("notificationsList") or 0)
        return {name: bool(raw & bit) for name, bit in NOTIFICATION_FLAGS.items()}

    @property
    def shutoff_countdown_seconds(self) -> int | None:
        """Return estimated seconds until automatic shutoff from continuous flow."""
        if not self.is_water_flowing:
            return None

        limit_minutes = self._current_flow_limit_minutes
        if limit_minutes is None or limit_minutes <= 0:
            return None

        last_new_flow = self._parse_datetime(self.valve.get("lastNewFlow"))
        if last_new_flow is None:
            return None

        shutoff_at = last_new_flow.timestamp() + (limit_minutes * 60)
        return max(0, int(shutoff_at - datetime.now(UTC).timestamp()))

    @property
    def advance_shutoff_warning(self) -> bool:
        """Return whether the valve is in the advance-shutoff warning window."""
        if not self.notification_flags.get("advance_shutoff", False):
            return False
        countdown = self.shutoff_countdown_seconds
        if countdown is None:
            return False
        pre_alert_minutes = self.valve.get("preAlertNoticeInterval") or 0
        return 0 <= countdown <= int(pre_alert_minutes * 60)

    @property
    def flow_started_at(self) -> datetime | None:
        """Return when the current flow event started."""
        if not self.is_water_flowing:
            return None
        return self._parse_datetime(self.valve.get("lastNewFlow"))

    @property
    def flow_elapsed_seconds(self) -> int | None:
        """Return locally calculated seconds since flow started."""
        started_at = self.flow_started_at
        if started_at is None:
            return None
        return max(0, int(datetime.now(UTC).timestamp() - started_at.timestamp()))

    @property
    def is_water_flowing(self) -> bool:
        """Return whether the valve reports active flow."""
        flow_state = self.valve.get("flowState")
        return bool(self.valve.get("online")) and flow_state not in (None, 1, 8)

    @property
    def _current_flow_limit_minutes(self) -> float | None:
        """Return the active mode's flow limit in minutes."""
        mode = self.mode_name
        if mode == "home":
            return self._float_or_none(self.valve.get("homeIntervalTime"))
        if mode == "away":
            return self._float_or_none(self.valve.get("awayIntervalTime"))
        if mode == "bypass":
            return self._float_or_none(self.valve.get("bypassTime"))
        return None

    @property
    def active_scheduler_events(self) -> list[dict[str, Any]]:
        """Return scheduler entries that have an action."""
        return [
            event
            for event in self.scheduler
            if event.get("action") is not None
            and event.get("actionPayload") is not None
        ]

    @staticmethod
    def _float_or_none(value: Any) -> float | None:
        """Return a float or None."""
        if value is None:
            return None
        try:
            return float(value)
        except (TypeError, ValueError):
            return None

    @staticmethod
    def _int_or_none(value: Any) -> int | None:
        """Return an int or None."""
        if value is None:
            return None
        try:
            return int(value)
        except (TypeError, ValueError):
            return None

    @staticmethod
    def _has_any_mode_flag(mode_value: int, flags: tuple[int, ...]) -> bool:
        """Return whether any mode flag is set."""
        return any(mode_value & flag for flag in flags)

    @staticmethod
    def _parse_datetime(value: Any) -> datetime | None:
        """Parse a FloLogic timestamp as UTC."""
        if not isinstance(value, str) or not value:
            return None
        text = value
        if text.endswith("Z"):
            text = f"{text[:-1]}+00:00"
        try:
            parsed = datetime.fromisoformat(text)
        except ValueError:
            return None
        if parsed.tzinfo is None:
            return parsed.replace(tzinfo=UTC)
        return parsed.astimezone(UTC)


class FloLogicConnection:
    """Short-lived SignalR connection."""

    def __init__(
        self,
        *,
        session: aiohttp.ClientSession,
        hub_url: str,
        headers: dict[str, str],
        event_callback: Callable[[str, list[Any]], None] | None = None,
        closed_callback: Callable[[], None] | None = None,
    ) -> None:
        """Initialize the connection."""
        self._session = session
        self._hub_url = hub_url.rstrip("/")
        self._headers = headers
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._reader_task: asyncio.Task | None = None
        self._events: dict[str, list[asyncio.Future[list[Any]]]] = {}
        self._closed = asyncio.Event()
        self._event_callback = event_callback
        self._closed_callback = closed_callback

    async def __aenter__(self) -> FloLogicConnection:
        """Open the SignalR connection."""
        negotiate = await self._session.post(
            f"{self._hub_url}/negotiate",
            headers=self._headers,
        )
        if negotiate.status in (401, 403):
            raise FloLogicAuthError("FloLogic rejected the request")
        if negotiate.status >= 400:
            raise FloLogicError(f"SignalR negotiate failed: {negotiate.status}")
        payload = await negotiate.json()
        token = payload.get("connectionToken") or payload.get("connectionId")
        if not token:
            raise FloLogicError("SignalR negotiate did not return a connection token")

        websocket_hub_url = self._hub_url.replace("https://", "wss://").replace(
            "http://", "ws://"
        )
        ws_url = f"{websocket_hub_url}?id={quote(token, safe='')}"
        self._ws = await self._session.ws_connect(ws_url, headers=self._headers)
        await self._ws.send_str(
            json.dumps({"protocol": "json", "version": 1}) + _RECORD_SEPARATOR
        )
        self._reader_task = asyncio.create_task(self._reader())
        return self

    async def __aexit__(self, *_exc: object) -> None:
        """Close the SignalR connection."""
        await self.close()

    async def close(self) -> None:
        """Close the websocket."""
        if self._ws is not None and not self._ws.closed:
            await self._ws.close()
        if self._reader_task is not None:
            self._reader_task.cancel()
            with suppress(asyncio.CancelledError):
                await self._reader_task
        for waiters in self._events.values():
            for waiter in waiters:
                if not waiter.done():
                    waiter.cancel()
        self._events.clear()

    @property
    def closed(self) -> bool:
        """Return whether the websocket is closed."""
        return self._ws is None or self._ws.closed or self._closed.is_set()

    async def invoke(self, target: str, *arguments: Any) -> None:
        """Invoke a hub method."""
        if self._ws is None:
            raise FloLogicError("SignalR connection is not open")
        if self.closed:
            raise FloLogicError("SignalR connection is closed")
        frame = {
            "type": 1,
            "target": target,
            "arguments": list(arguments),
        }
        await self._ws.send_str(
            json.dumps(frame, separators=(",", ":")) + _RECORD_SEPARATOR
        )

    async def invoke_and_wait(
        self,
        target: str,
        event_name: str,
        *arguments: Any,
        timeout: float = 30,
    ) -> list[Any]:
        """Invoke a hub method and wait for an event."""
        waiter = self.wait_for(event_name)
        try:
            await self.invoke(target, *arguments)
        except Exception:
            # Don't leak a waiter that can never complete.
            waiter.cancel()
            raise
        return await asyncio.wait_for(waiter, timeout)

    def wait_for(self, event_name: str) -> asyncio.Future[list[Any]]:
        """Wait for a hub event."""
        future: asyncio.Future[list[Any]] = asyncio.get_running_loop().create_future()
        self._events.setdefault(event_name, []).append(future)
        future.add_done_callback(
            lambda done_future: self._remove_waiter(event_name, done_future)
        )
        return future

    def _remove_waiter(
        self, event_name: str, future: asyncio.Future[list[Any]]
    ) -> None:
        """Remove a completed event waiter."""
        waiters = self._events.get(event_name, [])
        if future in waiters:
            waiters.remove(future)

    async def _reader(self) -> None:
        """Read SignalR frames."""
        assert self._ws is not None
        async for message in self._ws:
            if message.type == aiohttp.WSMsgType.TEXT:
                for raw_frame in message.data.split(_RECORD_SEPARATOR):
                    if not raw_frame:
                        continue
                    try:
                        frame = json.loads(raw_frame)
                    except json.JSONDecodeError:
                        _LOGGER.debug("Ignoring non-JSON FloLogic frame: %s", raw_frame)
                        continue
                    self._handle_frame(frame)
            elif message.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                break
        self._closed.set()
        if self._closed_callback is not None:
            self._closed_callback()

    def _handle_frame(self, frame: dict[str, Any]) -> None:
        """Dispatch a SignalR frame."""
        if frame.get("type") != 1:
            return
        target = frame.get("target")
        if not target:
            return
        if target == "ErrorOccured":
            _LOGGER.warning("FloLogic error event: %s", frame.get("arguments"))
        arguments = frame.get("arguments") or []
        waiters = self._events.get(target, [])
        if waiters:
            waiter = waiters.pop(0)
            if not waiter.done():
                waiter.set_result(arguments)
        if self._event_callback is not None:
            self._event_callback(target, arguments)


class FloLogicClient:
    """FloLogic cloud API client."""

    def __init__(
        self,
        *,
        email: str,
        password: str,
        hub_url: str,
        device_name: str,
        device_code: str,
        device_token: str,
        session_factory: Callable[[], aiohttp.ClientSession] | None = None,
        keep_session_alive: bool = False,
    ) -> None:
        """Initialize the client."""
        self._email = email
        self._password = password
        self._hub_url = hub_url.rstrip("/")
        self._device_name = device_name
        self._device_code = device_code
        self._device_token = device_token
        self._session_factory = session_factory
        self._keep_session_alive = keep_session_alive
        self._relog_token = ""
        self._persistent_lock = asyncio.Lock()
        self._persistent_session: aiohttp.ClientSession | None = None
        self._persistent_session_owned = False
        self._persistent_connection: FloLogicConnection | None = None
        self._persistent_user: dict[str, Any] | None = None
        self._persistent_valve: dict[str, Any] | None = None
        self._persistent_devices: list[dict[str, Any]] = []
        self._persistent_valves: dict[str, dict[str, Any]] = {}
        self._push_accounts_callback: (
            Callable[[dict[str, FloLogicAccount]], None] | None
        ) = None
        self._last_account: FloLogicAccount | None = None
        self._last_accounts: dict[str, FloLogicAccount] | None = None
        self._last_array_probe: float = 0.0
        self._push_revision = 0
        self._reconnect_task: asyncio.Task | None = None
        self._closing = False

    def set_push_accounts_callback(
        self, callback: Callable[[dict[str, FloLogicAccount]], None] | None
    ) -> None:
        """Set a callback for pushed multi-valve updates."""
        self._push_accounts_callback = callback

    async def async_fetch_account(self) -> FloLogicAccount:
        """Fetch the current account/device snapshot (first valve)."""
        accounts = await self.async_fetch_accounts()
        if not accounts:
            raise FloLogicError("FloLogic account has no controllable valves")
        # Keep the legacy primary preference when additional types are discovered.
        valve = choose_valve([account.valve for account in accounts.values()])
        assert valve is not None
        account = accounts[str(valve.get("uuid") or valve.get("id"))]
        self._last_account = account
        return account

    async def async_fetch_accounts(self) -> dict[str, FloLogicAccount]:
        """Fetch snapshots for every controllable valve on the account."""
        if self._keep_session_alive:
            accounts = await self._with_persistent_retry(
                self._async_fetch_accounts_persistent
            )
        else:
            accounts = await self._with_session(self._async_fetch_accounts)
        self._last_accounts = accounts
        if accounts:
            self._last_account = next(iter(accounts.values()))
        return accounts

    async def async_set_mode(self, mode: str) -> None:
        """Set the valve mode (first valve, backward compatible)."""
        await self.async_request_state_change({"mode": _mode_value(mode)})

    async def async_set_mode_for_valve(self, valve_id: str, mode: str) -> None:
        """Set mode for a specific valve."""
        await self.async_request_state_change_for_valve(
            valve_id, {"mode": _mode_value(mode)}
        )

    async def async_request_state_change(self, fields: dict[str, Any]) -> None:
        """Send a FloLogic state-change command (first valve)."""
        if self._keep_session_alive:
            await self._with_persistent_retry(
                lambda connection: self._async_send_state_change(connection, fields)
            )
            return

        async def _send(session: aiohttp.ClientSession) -> None:
            async with self._connection(session) as connection:
                user, valve, _devices = await self._login(connection)
                await self._send_state_change(connection, user, valve, fields)

        await self._with_session(_send)

    async def async_request_state_change_for_valve(
        self, valve_id: str, fields: dict[str, Any]
    ) -> None:
        """Send a state-change command for a specific valve by id or uuid."""
        if self._keep_session_alive:

            async def _persistent_send(connection: FloLogicConnection) -> None:
                valve = await self._resolve_valve_for_command(connection, valve_id)
                await self._send_state_change_for_valve(connection, valve, fields)

            await self._with_persistent_retry(_persistent_send)
            return

        async def _send(session: aiohttp.ClientSession) -> None:
            async with self._connection(session) as connection:
                user, _primary, devices = await self._login(connection)
                # Try to get full device list for id resolution
                full_devices = await self._ensure_full_devices(
                    connection, user, devices
                )
                valve = self._find_valve(full_devices, valve_id)
                if valve is None:
                    raise FloLogicError(f"Valve {valve_id} not found")
                await self._send_state_change(connection, user, valve, fields)

        await self._with_session(_send)

    async def async_close(self) -> None:
        """Close any persistent connection."""
        self._closing = True
        if self._reconnect_task is not None:
            self._reconnect_task.cancel()
            with suppress(asyncio.CancelledError):
                await self._reconnect_task
        await self._close_persistent()

    async def _async_fetch_account(
        self, session: aiohttp.ClientSession
    ) -> FloLogicAccount:
        """Fetch a snapshot using an existing session (backward compatible)."""
        accounts = await self._async_fetch_accounts(session)
        if not accounts:
            raise FloLogicTimeoutError("FloLogic login did not return a valve")
        return next(iter(accounts.values()))

    async def _async_fetch_accounts(
        self, session: aiohttp.ClientSession
    ) -> dict[str, FloLogicAccount]:
        """Fetch snapshots for every controllable valve."""
        async with self._connection(session) as connection:
            user, _primary, devices = await self._login(connection)
            full_devices = await self._ensure_full_devices(connection, user, devices)
            valves = controllable_valves(full_devices)
            if not valves:
                raise FloLogicTimeoutError("FloLogic login did not return a valve")
            # Fetch user accesses once for all valves.
            try:
                access_args = await connection.invoke_and_wait(
                    "RequestUserAccesses",
                    "UserAccessesSent",
                    user,
                    timeout=30,
                )
            except TimeoutError:
                access_args = []
            accesses = access_args[0] if access_args else []
            access_map: dict[Any, dict[str, Any]] = {
                acc.get("valveId"): acc
                for acc in accesses
                if isinstance(acc, dict) and acc.get("valveId") is not None
            }
            # Fetch per-valve scheduler/notifications. The two calls for one
            # valve wait on different hub events, so they can run together;
            # valves stay sequential because concurrent waits on the SAME
            # event cannot be correlated back to a valve.
            accounts: dict[str, FloLogicAccount] = {}
            for valve in valves:
                access = access_map.get(valve.get("id"))
                scheduler, notifications = await asyncio.gather(
                    self._fetch_scheduler(connection, user, valve),
                    self._fetch_notifications(connection, user, valve),
                )
                account = FloLogicAccount(
                    user=user,
                    valve=valve,
                    devices=full_devices,
                    access=access,
                    scheduler=scheduler,
                    notifications=notifications,
                    update_source="poll",
                )
                accounts[account.unique_id_prefix] = account
            return accounts

    async def _async_fetch_account_persistent(
        self,
        connection: FloLogicConnection,
    ) -> FloLogicAccount:
        """Fetch a snapshot using the persistent SignalR connection (compat)."""
        accounts = await self._async_fetch_accounts_persistent(connection)
        if not accounts:
            raise FloLogicTimeoutError("FloLogic refresh did not return a valve")
        return next(iter(accounts.values()))

    async def _async_fetch_accounts_persistent(
        self,
        connection: FloLogicConnection,
    ) -> dict[str, FloLogicAccount]:
        """Fetch snapshots for every valve using the persistent connection."""
        user, devices = await self._refresh_persistent_valves(connection)
        push_revision = self._push_revision
        valves = controllable_valves(devices)
        if not valves:
            raise FloLogicTimeoutError("FloLogic refresh did not return a valve")
        try:
            access_args = await connection.invoke_and_wait(
                "RequestUserAccesses",
                "UserAccessesSent",
                user,
                timeout=30,
            )
        except TimeoutError:
            access_args = []
        accesses = access_args[0] if access_args else []
        access_map: dict[Any, dict[str, Any]] = {
            acc.get("valveId"): acc
            for acc in accesses
            if isinstance(acc, dict) and acc.get("valveId") is not None
        }
        accounts: dict[str, FloLogicAccount] = {}
        for valve in valves:
            access = access_map.get(valve.get("id"))
            scheduler, notifications = await asyncio.gather(
                self._fetch_scheduler(connection, user, valve),
                self._fetch_notifications(connection, user, valve),
            )
            account = FloLogicAccount(
                user=user,
                valve=valve,
                devices=devices,
                access=access,
                scheduler=scheduler,
                notifications=notifications,
                update_source="poll",
            )
            accounts[account.unique_id_prefix] = account
        if self._push_revision != push_revision:
            # Requests above may yield while pushes change state or membership.
            # Keep fetched metadata, but publish the latest valve snapshot.
            current_accounts: dict[str, FloLogicAccount] = {}
            for valve in controllable_valves(self._persistent_devices):
                prefix = str(valve.get("uuid") or valve.get("id"))
                account = accounts.get(prefix) or (self._last_accounts or {}).get(
                    prefix
                )
                if account is None:
                    account = FloLogicAccount(user=user, valve=valve)
                current_accounts[prefix] = replace(
                    account,
                    valve=valve,
                    devices=list(self._persistent_devices),
                    update_source="push",
                )
            return current_accounts
        return accounts

    async def _async_send_state_change(
        self,
        connection: FloLogicConnection,
        fields: dict[str, Any],
    ) -> None:
        """Send a state-change command on the persistent connection."""
        user, valve, _devices = await self._refresh_persistent_valve(connection)
        await self._send_state_change(connection, user, valve, fields)

    async def _send_state_change(
        self,
        connection: FloLogicConnection,
        user: dict[str, Any],
        valve: dict[str, Any],
        fields: dict[str, Any],
    ) -> None:
        """Send a FloLogic state-change command on an open connection."""
        command = {
            "active": True,
            "created": datetime.now(UTC).isoformat(),
            "userId": user["id"],
            "valveId": valve["id"],
            **fields,
        }
        await connection.invoke_and_wait(
            "RequestStateChange",
            "StateChangeResult",
            user,
            valve,
            command,
            timeout=45,
        )

    async def _login(
        self,
        connection: FloLogicConnection,
    ) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, Any]]]:
        """Log in and return user, selected valve, and device list."""
        login_waiter = connection.wait_for("LoggedIn")
        valve_waiter = connection.wait_for("ValveSent")
        try:
            await connection.invoke(
                "Login", self._email, self._password, self._device_name, None
            )
            try:
                user_args = await asyncio.wait_for(login_waiter, 30)
            except TimeoutError as err:
                raise FloLogicAuthError("FloLogic login did not return a user") from err
            user = user_args[0]
            self._relog_token = user.get("relogToken") or self._relog_token

            devices: list[dict[str, Any]] = []
            valve: dict[str, Any] | None = None
            try:
                valve_args = await asyncio.wait_for(valve_waiter, 3)
                valve = valve_args[0]
                devices = [valve]
            except TimeoutError:
                array_args = await connection.invoke_and_wait(
                    "RefreshValveArray",
                    "ValveArraySent",
                    user,
                    timeout=30,
                )
                devices = array_args[0] if array_args else []
                # A ValveSent that arrived just after the 3s cutoff is still
                # useful: merge it so the device list is complete.
                if valve_waiter.done() and not valve_waiter.cancelled():
                    with suppress(Exception):
                        late_args = valve_waiter.result()
                        late_valve = late_args[0] if late_args else None
                        if isinstance(late_valve, dict) and all(
                            device.get("id") != late_valve.get("id")
                            for device in devices
                        ):
                            devices = [*devices, late_valve]
                valve = choose_valve(devices)

            if not valve:
                raise FloLogicTimeoutError("FloLogic login did not return a valve")
            return user, valve, devices
        finally:
            for waiter in (login_waiter, valve_waiter):
                if not waiter.done():
                    waiter.cancel()

    async def _fetch_access(
        self,
        connection: FloLogicConnection,
        user: dict[str, Any],
        valve: dict[str, Any],
    ) -> dict[str, Any] | None:
        """Fetch the current user's access record."""
        try:
            args = await connection.invoke_and_wait(
                "RequestUserAccesses",
                "UserAccessesSent",
                user,
                timeout=30,
            )
        except TimeoutError:
            return None
        accesses = args[0] if args else []
        return next(
            (access for access in accesses if access.get("valveId") == valve.get("id")),
            None,
        )

    async def _fetch_scheduler(
        self,
        connection: FloLogicConnection,
        user: dict[str, Any],
        valve: dict[str, Any],
    ) -> list[dict[str, Any]]:
        """Fetch scheduler entries."""
        try:
            args = await connection.invoke_and_wait(
                "RequestSchedulerEvents",
                "SchedulerEventsSent",
                user["id"],
                valve["id"],
                timeout=30,
            )
        except TimeoutError:
            return []
        return args[0] if args else []

    async def _fetch_notifications(
        self,
        connection: FloLogicConnection,
        user: dict[str, Any],
        valve: dict[str, Any],
    ) -> list[dict[str, Any]]:
        """Fetch notification history, if the cloud has any rows."""
        try:
            args = await connection.invoke_and_wait(
                "RefreshValvesNotificationsHistory",
                "NotificationsHistorySent",
                user["id"],
                [valve["id"]],
                timeout=30,
            )
        except TimeoutError:
            return []
        notifications = args[0] if args else []
        if notifications:
            return notifications
        try:
            all_args = await connection.invoke_and_wait(
                "RefreshValvesNotificationsHistory",
                "NotificationsHistorySent",
                user["id"],
                [],
                timeout=30,
            )
        except TimeoutError:
            return []
        return all_args[0] if all_args else []

    def _find_valve(
        self, devices: list[dict[str, Any]], valve_id: str
    ) -> dict[str, Any] | None:
        """Find a valve by id/uuid/string."""
        needle = str(valve_id)
        for device in devices:
            if str(device.get("id")) == needle or str(device.get("uuid")) == needle:
                return device
        # Accept UUIDs with different casing.
        needle_lower = needle.lower()
        for device in devices:
            if (
                needle_lower == str(device.get("id")).lower()
                or needle_lower == str(device.get("uuid")).lower()
            ):
                return device
        return None

    async def _ensure_full_devices(
        self,
        connection: FloLogicConnection,
        user: dict[str, Any],
        devices: list[dict[str, Any]],
    ) -> list[dict[str, Any]]:
        """Ensure we have the full device array for a multi-valve account.

        The cloud's ``Login`` may only send a single ``ValveSent`` (primary)
        even when ``ValveArraySent`` lists two valves. If the initial list has
        one entry we probe ``RefreshValveArray`` to discover the second device.

        Single-valve accounts would otherwise pay for this probe on every
        poll, so a confirmed single-valve result is trusted for an hour
        (a valve added later is discovered on the next hourly probe at the
        latest). A login that disagrees with a known multi-valve set always
        re-probes immediately.
        """
        if len(devices) != 1:
            return devices
        known_count = (
            len(self._last_accounts) if self._last_accounts is not None else None
        )
        if (
            known_count == 1
            and time.monotonic() - self._last_array_probe
            < _ARRAY_PROBE_INTERVAL_SECONDS
        ):
            return devices
        self._last_array_probe = time.monotonic()
        try:
            array_args = await connection.invoke_and_wait(
                "RefreshValveArray",
                "ValveArraySent",
                user,
                timeout=30,
            )
            full = array_args[0] if array_args else []
            if isinstance(full, list) and len(full) > len(devices):
                return [v for v in full if isinstance(v, dict)]
        except TimeoutError:
            pass
        return devices

    async def _resolve_valve_for_command(
        self, connection: FloLogicConnection, valve_id: str
    ) -> dict[str, Any]:
        """Resolve a target valve for a state-change command."""
        if self._persistent_user is None:
            raise FloLogicError("FloLogic persistent connection is not logged in")
        # Prefer cached valves
        if self._persistent_valves:
            candidate = self._find_valve(
                list(self._persistent_valves.values()), valve_id
            )
            if candidate is not None:
                return candidate
            candidate = self._find_valve(self._persistent_devices, valve_id)
            if candidate is not None:
                return candidate
        # Refresh to discover the valve
        _, devices = await self._refresh_persistent_valves(connection)
        valve = self._find_valve(devices, valve_id)
        if valve is None:
            # Also search within controllable tier using id string matching
            valve = self._find_valve(controllable_valves(devices), valve_id)
        if valve is None:
            raise FloLogicError(f"Valve {valve_id} not found")
        return valve

    async def _send_state_change_for_valve(
        self,
        connection: FloLogicConnection,
        valve: dict[str, Any],
        fields: dict[str, Any],
    ) -> None:
        """Send a state-change for an explicit valve."""
        if self._persistent_user is None:
            raise FloLogicError("FloLogic persistent connection is not logged in")
        await self._send_state_change(connection, self._persistent_user, valve, fields)

    async def _with_session(
        self, func: Callable[[aiohttp.ClientSession], Awaitable[Any]]
    ) -> Any:
        """Run a function with a client session."""
        if self._session_factory is not None:
            session = self._session_factory()
            return await func(session)
        async with aiohttp.ClientSession() as session:
            return await func(session)

    async def _with_persistent_retry(
        self,
        func: Callable[[FloLogicConnection], Awaitable[Any]],
    ) -> Any:
        """Run a function on the persistent connection, reconnecting once if needed."""
        last_error: Exception | None = None
        for attempt in range(2):
            try:
                connection = await self._ensure_persistent_connection()
                return await func(connection)
            except (TimeoutError, FloLogicError, aiohttp.ClientError) as err:
                last_error = err
                _LOGGER.debug(
                    "FloLogic persistent connection failed on attempt %s",
                    attempt + 1,
                    exc_info=err,
                )
                await self._close_persistent()
        if last_error is not None:
            raise FloLogicError(str(last_error)) from last_error
        raise FloLogicError("FloLogic persistent connection failed")

    async def _ensure_persistent_connection(self) -> FloLogicConnection:
        """Open or return the persistent SignalR connection."""
        async with self._persistent_lock:
            if (
                self._persistent_connection is not None
                and not self._persistent_connection.closed
            ):
                return self._persistent_connection

            await self._close_persistent()
            if self._session_factory is not None:
                session = self._session_factory()
                self._persistent_session_owned = False
            else:
                session = aiohttp.ClientSession()
                self._persistent_session_owned = True
            connection = self._connection(session)
            await connection.__aenter__()
            user, valve, devices = await self._login(connection)
            full_devices = await self._ensure_full_devices(connection, user, devices)
            valves = controllable_valves(full_devices)
            self._persistent_session = session
            self._persistent_connection = connection
            self._persistent_user = user
            self._persistent_valve = valve
            self._persistent_devices = full_devices
            self._persistent_valves = {
                str(v.get("uuid") or v.get("id")): v for v in valves
            }
            return connection

    async def _close_persistent(self) -> None:
        """Close the persistent connection and owned session."""
        connection = self._persistent_connection
        session = self._persistent_session
        owned = self._persistent_session_owned
        self._persistent_connection = None
        self._persistent_session = None
        self._persistent_session_owned = False
        self._persistent_user = None
        self._persistent_valve = None
        self._persistent_devices = []
        self._persistent_valves = {}
        if connection is not None:
            await connection.close()
        if owned and session is not None and not session.closed:
            await session.close()

    def _handle_persistent_closed(self) -> None:
        """Schedule persistent reconnection after an unexpected close."""
        if self._closing or not self._keep_session_alive:
            return
        if self._reconnect_task is not None and not self._reconnect_task.done():
            return
        self._reconnect_task = asyncio.create_task(self._reconnect_with_backoff())

    async def _reconnect_with_backoff(self) -> None:
        """Reconnect the persistent websocket with conservative backoff."""
        for delay in (5, 15, 30, 60):
            if self._closing or not self._keep_session_alive:
                return
            await asyncio.sleep(delay)
            try:
                await self._close_persistent()
                await self._ensure_persistent_connection()
            except (TimeoutError, FloLogicError, aiohttp.ClientError):
                _LOGGER.debug(
                    "FloLogic persistent reconnect failed after %s seconds",
                    delay,
                    exc_info=True,
                )
                continue
            return
        _LOGGER.warning(
            "FloLogic persistent reconnect gave up after repeated failures; "
            "the next poll will retry the connection"
        )

    async def _refresh_persistent_valve(
        self,
        connection: FloLogicConnection,
    ) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, Any]]]:
        """Refresh the persistent connection's selected valve (compat)."""
        user, devices = await self._refresh_persistent_valves(connection)
        valve = choose_valve(devices)
        if not valve:
            raise FloLogicTimeoutError("FloLogic refresh did not return a valve")
        return user, valve, devices

    async def _refresh_persistent_valves(
        self,
        connection: FloLogicConnection,
    ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        """Refresh the full valve array for the persistent connection."""
        if self._persistent_user is None:
            raise FloLogicError("FloLogic persistent connection is not logged in")
        args = await connection.invoke_and_wait(
            "RefreshValveArray",
            "ValveArraySent",
            self._persistent_user,
            timeout=30,
        )
        devices = args[0] if args else []
        if not isinstance(devices, list):
            devices = []
        valves = controllable_valves(devices)
        valve = valves[0] if valves else None
        if not valve:
            raise FloLogicTimeoutError("FloLogic refresh did not return a valve")
        self._persistent_valve = valve
        self._persistent_devices = devices
        self._persistent_valves = {str(v.get("uuid") or v.get("id")): v for v in valves}
        return self._persistent_user, devices

    def _handle_persistent_event(self, target: str, arguments: list[Any]) -> None:
        """Handle unsolicited hub events on the persistent connection."""
        if target == "ValveSent" and arguments:
            valve = arguments[0]
            if isinstance(valve, dict):
                self._handle_pushed_valves([valve], full_replace=False)
        elif target == "ValveArraySent" and arguments:
            valves = arguments[0]
            if isinstance(valves, list):
                self._handle_pushed_valves(
                    [valve for valve in valves if isinstance(valve, dict)],
                    full_replace=True,
                )

    def _handle_pushed_valves(
        self, valves: list[dict[str, Any]], *, full_replace: bool = False
    ) -> None:
        """Update the cached account(s) from pushed valve data.

        Single ``ValveSent`` pushes merge into the cache; full
        ``ValveArraySent`` pushes replace it so cloud-side removals prune
        stale valves instead of lingering as ghosts.
        """
        if not self._keep_session_alive or self._persistent_user is None:
            return
        if full_replace:
            if not valves:
                return
            self._persistent_devices = list(valves)
            self._persistent_valves = {
                str(v.get("uuid") or v.get("id")): v
                for v in controllable_valves(valves)
            }
        else:
            # Update persistent cache with whatever valves the cloud pushed.
            merged = False
            for incoming in valves:
                if not isinstance(incoming, dict):
                    continue
                incoming_id = incoming.get("id")
                # A lone gateway push must not overwrite a real valve cache.
                if (
                    len(valves) == 1
                    and incoming.get("isZGateway") is True
                    and self._persistent_valve is not None
                    and self._persistent_valve.get("isZGateway") is not True
                    and incoming.get("id") != self._persistent_valve.get("id")
                ):
                    continue
                # Replace or add to persistent_devices.
                for index, device in enumerate(self._persistent_devices):
                    if device.get("id") == incoming_id:
                        self._persistent_devices[index] = incoming
                        break
                else:
                    self._persistent_devices.append(incoming)
                if incoming.get("isZGateway") is not True:
                    prefix = str(incoming.get("uuid") or incoming_id)
                    self._persistent_valves[prefix] = incoming
                    if choose_valve([incoming]) is not None and (
                        self._persistent_valve is None
                        or self._persistent_valve.get("id") == incoming_id
                    ):
                        self._persistent_valve = incoming
                    merged = True
            if not merged:
                # Pure gateway noise: nothing valve-related changed.
                return

        # Build accounts dict for all known controllable valves
        valves_list = controllable_valves(self._persistent_devices)
        if not valves_list:
            return

        self._push_revision += 1

        # Build new push accounts reusing cached access/scheduler
        new_accounts: dict[str, FloLogicAccount] = {}
        for valve in valves_list:
            prefix = str(valve.get("uuid") or valve.get("id"))
            if self._last_accounts and prefix in self._last_accounts:
                previous_account = self._last_accounts[prefix]
                account = FloLogicAccount(
                    user=previous_account.user,
                    valve=valve,
                    devices=self._persistent_devices,
                    access=previous_account.access,
                    scheduler=previous_account.scheduler,
                    notifications=previous_account.notifications,
                    update_source="push",
                )
            elif (
                self._last_account is not None
                and prefix == self._last_account.unique_id_prefix
            ):
                account = FloLogicAccount(
                    user=self._last_account.user,
                    valve=valve,
                    devices=self._persistent_devices,
                    access=self._last_account.access,
                    scheduler=self._last_account.scheduler,
                    notifications=self._last_account.notifications,
                    update_source="push",
                )
            else:
                account = FloLogicAccount(
                    user=self._persistent_user,
                    valve=valve,
                    devices=self._persistent_devices,
                    update_source="push",
                )
            new_accounts[prefix] = account

        # Update caches and dispatch. A full array push is authoritative, so
        # it replaces the cache (pruning removals); incremental pushes merge.
        if full_replace or self._last_accounts is None:
            self._last_accounts = dict(new_accounts)
        else:
            self._last_accounts.update(new_accounts)
        primary = choose_valve(valves_list)
        if primary is not None:
            primary_prefix = str(primary.get("uuid") or primary.get("id"))
            self._last_account = new_accounts.get(primary_prefix)
            self._persistent_valve = primary
        if self._push_accounts_callback is not None:
            self._push_accounts_callback(dict(new_accounts))

    def _connection(self, session: aiohttp.ClientSession) -> FloLogicConnection:
        """Create a connection object."""
        hub_url = self._hub_url
        if not hub_url.lower().endswith("/signalr"):
            hub_url = f"{hub_url}/signalr"
        return FloLogicConnection(
            session=session,
            hub_url=hub_url,
            headers={
                "userDeviceCode": self._device_code,
                "userDeviceToken": self._device_token,
                "relogToken": self._relog_token,
                "OsPlatform": "Android",
                "AppVer": "homeassistant",
                "DeviceName": self._device_name,
            },
            event_callback=self._handle_persistent_event
            if self._keep_session_alive
            else None,
            closed_callback=self._handle_persistent_closed
            if self._keep_session_alive
            else None,
        )


def controllable_valves(devices: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Return Connect valves of every type, excluding explicit gateways.

    Prefer positively identified valves. Older payloads without type metadata
    retain the non-gateway fallback used by existing installations.
    """
    candidates = [device for device in devices if device.get("isZGateway") is not True]
    valves = [
        device
        for device in candidates
        if device.get("isZConnect") is True
        or device.get("isAnyConnect") is True
        or "connect" in str(device.get("deviceTypeName") or "").lower()
    ]
    return valves or candidates


def choose_valve(devices: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Choose the controllable Connect valve from a device list."""
    valves = controllable_valves(devices)
    return next(
        (valve for valve in valves if valve.get("isZConnect") is True),
        next(
            (valve for valve in valves if valve.get("isAnyConnect") is True),
            valves[0] if valves else None,
        ),
    )


def _mode_value(mode: str) -> int:
    """Return the cloud value for a mode name, rejecting unknown modes."""
    try:
        return VALVE_MODES[mode]
    except KeyError as err:
        raise ValueError(
            f"Unknown FloLogic mode {mode!r}; valid modes: {sorted(VALVE_MODES)}"
        ) from err
