"""FloLogic select entities."""

from __future__ import annotations

from typing import ClassVar

from homeassistant.components.select import SelectEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import DOMAIN, VALVE_MODES
from .coordinator import FloLogicCoordinator
from .entity import FloLogicEntity


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    """Set up FloLogic selects."""
    coordinator: FloLogicCoordinator = hass.data[DOMAIN][entry.entry_id]
    async_add_entities([FloLogicModeSelect(coordinator)])


class FloLogicModeSelect(FloLogicEntity, SelectEntity):
    """FloLogic valve mode selector."""

    _attr_translation_key = "valve_mode"
    _attr_options: ClassVar[list[str]] = list(VALVE_MODES)

    def __init__(self, coordinator: FloLogicCoordinator) -> None:
        """Initialize the select."""
        super().__init__(coordinator, "valve_mode")

    @property
    def current_option(self) -> str | None:
        """Return the current option."""
        return self.coordinator.data.mode_name

    async def async_select_option(self, option: str) -> None:
        """Set the valve mode."""
        await self.coordinator.client.async_set_mode(option)
        await self.coordinator.async_request_refresh()
