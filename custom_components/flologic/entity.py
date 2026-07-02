"""Base FloLogic entities."""

from __future__ import annotations

from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import FloLogicCoordinator


class FloLogicEntity(CoordinatorEntity[FloLogicCoordinator]):
    """Base FloLogic entity."""

    _attr_has_entity_name = True

    def __init__(self, coordinator: FloLogicCoordinator, key: str) -> None:
        """Initialize the entity."""
        super().__init__(coordinator)
        self._key = key
        self._attr_unique_id = f"{coordinator.data.unique_id_prefix}_{key}"

    @property
    def device_info(self) -> DeviceInfo:
        """Return device information."""
        valve = self.coordinator.data.valve
        return DeviceInfo(
            identifiers={(DOMAIN, self.coordinator.data.unique_id_prefix)},
            name=self.coordinator.data.valve_name,
            manufacturer="FloLogic",
            model=valve.get("deviceTypeName"),
            sw_version=valve.get("softwareVersion") or valve.get("valveAndCpFirmwareVersionString"),
        )
