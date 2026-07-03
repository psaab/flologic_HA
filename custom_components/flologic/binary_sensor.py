"""FloLogic binary sensors."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from homeassistant.components.binary_sensor import BinarySensorDeviceClass, BinarySensorEntity, BinarySensorEntityDescription
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.event import async_call_later
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import DOMAIN, NOTIFICATION_FLAGS
from .coordinator import FloLogicCoordinator
from .entity import FloLogicEntity


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
    *(
        FloLogicBinarySensorDescription(
            key=f"notification_{name}",
            translation_key=f"notification_{name}",
            source=name,
        )
        for name in NOTIFICATION_FLAGS
    ),
)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    """Set up FloLogic binary sensors."""
    coordinator: FloLogicCoordinator = hass.data[DOMAIN][entry.entry_id]
    async_add_entities(
        FloLogicLocallyTickingBinarySensor(coordinator, description)
        if description.key == "advance_shutoff_warning"
        else FloLogicBinarySensor(coordinator, description)
        for description in BINARY_SENSORS
    )


class FloLogicBinarySensor(FloLogicEntity, BinarySensorEntity):
    """FloLogic binary sensor."""

    entity_description: FloLogicBinarySensorDescription

    def __init__(
        self,
        coordinator: FloLogicCoordinator,
        description: FloLogicBinarySensorDescription,
    ) -> None:
        """Initialize the binary sensor."""
        super().__init__(coordinator, description.key)
        self.entity_description = description

    @property
    def is_on(self) -> bool | None:
        """Return the binary sensor state."""
        if self.entity_description.source == "online":
            return self.coordinator.data.valve.get("online")
        if self.entity_description.source == "advance_shutoff_warning":
            return self.coordinator.data.advance_shutoff_warning
        return self.coordinator.data.notification_flags.get(self.entity_description.source)


class FloLogicLocallyTickingBinarySensor(FloLogicBinarySensor):
    """FloLogic binary sensor that updates locally while water is flowing."""

    _unsub_tick: Callable[[], None] | None = None

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
        if self.coordinator.data.is_water_flowing:
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
        if not self.coordinator.data.is_water_flowing:
            self._stop_tick_timer()
            self.schedule_update_ha_state()
            return
        self.schedule_update_ha_state()
        self._schedule_next_tick()
