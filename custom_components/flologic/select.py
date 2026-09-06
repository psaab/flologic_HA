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
        known_valves.update(new_valve_ids)
        async_add_entities(
            [FloLogicModeSelect(coordinator, valve_id) for valve_id in new_valve_ids]
        )

    _async_add_new_valves()
    entry.async_on_unload(coordinator.async_add_listener(_async_add_new_valves))


class FloLogicModeSelect(FloLogicEntity, SelectEntity):
    """FloLogic valve mode selector."""

    _attr_translation_key = "valve_mode"
    _attr_options: ClassVar[list[str]] = list(VALVE_MODES)

    def __init__(
        self, coordinator: FloLogicCoordinator, valve_id: str | None = None
    ) -> None:
        """Initialize the select."""
        super().__init__(coordinator, "valve_mode", valve_id)

    @property
    def current_option(self) -> str | None:
        """Return the current option."""
        account = self._account
        if account is None:
            return None
        return account.mode_name

    async def async_select_option(self, option: str) -> None:
        """Set the valve mode."""
        if option not in VALVE_MODES:
            raise ValueError(
                f"Unknown FloLogic mode {option!r}; valid modes: {sorted(VALVE_MODES)}"
            )
        await self.coordinator.client.async_request_state_change_for_valve(
            self._valve_id, {"mode": VALVE_MODES[option]}
        )
        await self.coordinator.async_request_refresh()
