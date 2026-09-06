"""FloLogic binary sensors."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from homeassistant.components.binary_sensor import (
    BinarySensorDeviceClass,
    BinarySensorEntity,
    BinarySensorEntityDescription,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.event import async_call_later

from .const import (
    CRITICAL_MODE_FLAGS,
    DOMAIN,
    MODE_FLAG_NAMES,
    NOTIFICATION_FLAGS,
    WARNING_ALERT_MODE_FLAGS,
    WATER_OFF_MODE_FLAGS,
)
from .coordinator import FloLogicCoordinator
from .entity import FloLogicEntity

HIDDEN_BY_DEFAULT_NOTIFICATION_FLAGS = {
    "always",
    "auto_away",
    "auto_shutoff",
    "critical_error",
    "delay_away",
    "general_alert",
    "guest_mode",
    "never",
    "no_flow",
}


@dataclass(frozen=True, kw_only=True)
class FloLogicBinarySensorDescription(BinarySensorEntityDescription):
    """FloLogic binary sensor description."""

    source: str


BINARY_SENSORS: tuple[FloLogicBinarySensorDescription, ...] = (
    FloLogicBinarySensorDescription(
        key="online",
        translation_key="online",
        device_class=BinarySensorDeviceClass.CONNECTIVITY,
        source="online",
    ),
    FloLogicBinarySensorDescription(
        key="advance_shutoff_warning",
        translation_key="advance_shutoff_warning",
        device_class=BinarySensorDeviceClass.PROBLEM,
        source="advance_shutoff_warning",
    ),
    FloLogicBinarySensorDescription(
        key="water_off_event",
        translation_key="water_off_event",
        device_class=BinarySensorDeviceClass.PROBLEM,
        source="water_off_event",
    ),
    FloLogicBinarySensorDescription(
        key="warning_alert_event",
        translation_key="warning_alert_event",
        device_class=BinarySensorDeviceClass.PROBLEM,
        source="warning_alert_event",
    ),
    FloLogicBinarySensorDescription(
        key="critical_fault_event",
        translation_key="critical_fault_event",
        device_class=BinarySensorDeviceClass.PROBLEM,
        source="critical_fault_event",
    ),
    *(
        FloLogicBinarySensorDescription(
            key=f"notification_{name}",
            translation_key=f"notification_{name}",
            entity_registry_enabled_default=(
                name not in HIDDEN_BY_DEFAULT_NOTIFICATION_FLAGS
            ),
            source=name,
        )
        for name in NOTIFICATION_FLAGS
    ),
)


def _entities_for_valve(
    coordinator: FloLogicCoordinator, valve_id: str
) -> list[FloLogicBinarySensor]:
    """Build every binary sensor for one valve."""
    entities: list[FloLogicBinarySensor] = []
    for description in BINARY_SENSORS:
        if description.key == "advance_shutoff_warning":
            entities.append(
                FloLogicLocallyTickingBinarySensor(coordinator, description, valve_id)
            )
        else:
            entities.append(FloLogicBinarySensor(coordinator, description, valve_id))
    return entities


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    """Set up FloLogic binary sensors."""
    coordinator: FloLogicCoordinator = hass.data[DOMAIN][entry.entry_id]
    known_valves: set[str] = set()

    def _async_add_new_valves() -> None:
        """Add entities for valves discovered after setup."""
        new_valve_ids = [
            valve_id
            for valve_id in coordinator.accounts
            if valve_id not in known_valves
        ]
        if not new_valve_ids:
            return
        entities: list[FloLogicBinarySensor] = []
        for valve_id in new_valve_ids:
            entities.extend(_entities_for_valve(coordinator, valve_id))
        known_valves.update(new_valve_ids)
        async_add_entities(entities)

    _async_add_new_valves()
    entry.async_on_unload(coordinator.async_add_listener(_async_add_new_valves))


class FloLogicBinarySensor(FloLogicEntity, BinarySensorEntity):
    """FloLogic binary sensor."""

    entity_description: FloLogicBinarySensorDescription

    def __init__(
        self,
        coordinator: FloLogicCoordinator,
        description: FloLogicBinarySensorDescription,
        valve_id: str | None = None,
    ) -> None:
        """Initialize the binary sensor."""
        super().__init__(coordinator, description.key, valve_id)
        self.entity_description = description

    @property
    def is_on(self) -> bool | None:
        """Return the binary sensor state."""
        account = self._account
        if account is None:
            return None
        if self.entity_description.source == "online":
            return account.valve.get("online")
        if self.entity_description.source == "advance_shutoff_warning":
            return account.advance_shutoff_warning
        if self.entity_description.source == "water_off_event":
            return self._has_any_mode_flag(WATER_OFF_MODE_FLAGS)
        if self.entity_description.source == "warning_alert_event":
            return self._has_any_mode_flag(WARNING_ALERT_MODE_FLAGS)
        if self.entity_description.source == "critical_fault_event":
            return self._has_any_mode_flag(CRITICAL_MODE_FLAGS)
        return account.notification_flags.get(self.entity_description.source)

    @property
    def extra_state_attributes(self) -> dict[str, Any] | None:
        """Return diagnostic details for grouped trouble sensors."""
        if self.entity_description.source == "water_off_event":
            return self._trouble_attributes(WATER_OFF_MODE_FLAGS)
        if self.entity_description.source == "warning_alert_event":
            return self._trouble_attributes(WARNING_ALERT_MODE_FLAGS)
        if self.entity_description.source == "critical_fault_event":
            return self._trouble_attributes(CRITICAL_MODE_FLAGS)
        return None

    def _has_any_mode_flag(self, flags: tuple[int, ...]) -> bool:
        """Return whether the current valve mode contains any provided flag."""
        mode = self._mode_value
        if mode is None:
            return False
        return any(mode & flag for flag in flags)

    def _trouble_attributes(self, flags: tuple[int, ...]) -> dict[str, Any]:
        """Return active mode flags for a grouped trouble sensor."""
        mode = self._mode_value
        active_flags = [
            MODE_FLAG_NAMES[flag] for flag in flags if mode is not None and mode & flag
        ]
        return {
            "raw_mode": mode,
            "active_mode_flags": active_flags,
        }

    @property
    def _mode_value(self) -> int | None:
        """Return the current raw valve mode as an integer."""
        account = self._account
        if account is None:
            return None
        mode = account.valve.get("mode")
        try:
            return int(mode)
        except (TypeError, ValueError):
            return None


class FloLogicLocallyTickingBinarySensor(FloLogicBinarySensor):
    """FloLogic binary sensor that updates locally while water is flowing."""

    _unsub_tick: Callable[[], None] | None = None
    _last_tick_value: bool | None = None

    async def async_added_to_hass(self) -> None:
        """Start local ticking when added to Home Assistant."""
        await super().async_added_to_hass()
        self._sync_tick_timer()

    async def async_will_remove_from_hass(self) -> None:
        """Stop local ticking when removed."""
        self._stop_tick_timer()
        await super().async_will_remove_from_hass()

    def _handle_coordinator_update(self) -> None:
        """Handle updated data from the coordinator."""
        super()._handle_coordinator_update()
        self._sync_tick_timer()

    def _sync_tick_timer(self) -> None:
        """Start or stop the local one-second tick."""
        self._last_tick_value = self.is_on
        account = self._account
        if account is not None and account.is_water_flowing:
            if self._unsub_tick is None:
                self._schedule_next_tick()
        else:
            self._stop_tick_timer()

    def _schedule_next_tick(self) -> None:
        """Schedule the next local state write."""
        self._unsub_tick = async_call_later(self.hass, 1, self._handle_tick)

    def _stop_tick_timer(self) -> None:
        """Stop the local tick timer."""
        if self._unsub_tick is not None:
            self._unsub_tick()
            self._unsub_tick = None

    def _handle_tick(self, _now: Any) -> None:
        """Refresh the local warning value."""
        self._unsub_tick = None
        account = self._account
        if account is None or not account.is_water_flowing:
            self._stop_tick_timer()
            self.schedule_update_ha_state()
            return
        # A boolean rarely flips: only write state on an actual change to
        # avoid a pointless state write every second while flowing.
        current = self.is_on
        if current != self._last_tick_value:
            self._last_tick_value = current
            self.schedule_update_ha_state()
        self._schedule_next_tick()
