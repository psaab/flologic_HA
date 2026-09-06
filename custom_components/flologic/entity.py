"""Base FloLogic entities."""

from __future__ import annotations

from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .api import FloLogicAccount
from .const import DOMAIN
from .coordinator import FloLogicCoordinator


class FloLogicEntity(CoordinatorEntity[FloLogicCoordinator]):
    """Base FloLogic entity."""

    _attr_has_entity_name = True

    def __init__(
        self, coordinator: FloLogicCoordinator, key: str, valve_id: str | None = None
    ) -> None:
        """Initialize the entity."""
        super().__init__(coordinator)
        self._key = key
        # Resolve the valve identifier: explicit valve_id or primary account fallback.
        if valve_id is None:
            primary = coordinator.primary_account
            if primary is None:
                raise ValueError(
                    "valve_id is required when no FloLogic valve is loaded"
                )
            valve_id = primary.unique_id_prefix
        self._valve_id = valve_id
        self._attr_unique_id = f"{valve_id}_{key}"

    @property
    def _account(self) -> FloLogicAccount | None:
        """Return the FloLogicAccount for this entity's valve, if loaded.

        Never falls back to another valve: showing valve A's leak/shutoff
        state under valve B's entity would corrupt safety automations.
        """
        data = self.coordinator.data
        if isinstance(data, dict):
            return data.get(self._valve_id)
        return None

    @property
    def available(self) -> bool:
        """Return whether the entity's valve data is available."""
        return super().available and self._account is not None

    @property
    def device_info(self) -> DeviceInfo:
        """Return device information."""
        account = self._account
        if account is None:
            # Valve data not loaded (yet): keep the device linkable by id only.
            return DeviceInfo(identifiers={(DOMAIN, self._valve_id)})
        valve = account.valve
        return DeviceInfo(
            identifiers={(DOMAIN, self._valve_id)},
            name=account.valve_name,
            manufacturer="FloLogic",
            model=valve.get("deviceTypeName"),
            sw_version=valve.get("softwareVersion")
            or valve.get("valveAndCpFirmwareVersionString"),
        )
