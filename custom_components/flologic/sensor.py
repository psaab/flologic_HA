"""FloLogic sensors."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from homeassistant.components.sensor import SensorDeviceClass, SensorEntity, SensorEntityDescription, SensorStateClass
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import EntityCategory, PERCENTAGE, UnitOfTemperature, UnitOfTime
from homeassistant.core import HomeAssistant
from homeassistant.helpers.event import async_call_later
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import DOMAIN, FLOW_STATE_NAMES, MODE_NAMES
from .coordinator import FloLogicCoordinator
from .entity import FloLogicEntity


@dataclass(frozen=True, kw_only=True)
class FloLogicSensorDescription(SensorEntityDescription):
    """FloLogic sensor description."""

    value_fn: Callable[[FloLogicCoordinator], Any]


def valve_value(field: str) -> Callable[[FloLogicCoordinator], Any]:
    """Return a valve field getter."""
    return lambda coordinator: coordinator.data.valve.get(field)


SENSORS: tuple[FloLogicSensorDescription, ...] = (
    FloLogicSensorDescription(
        key="mode",
        translation_key="mode",
        value_fn=lambda coordinator: MODE_NAMES.get(coordinator.data.valve.get("mode"), "other"),
    ),
    FloLogicSensorDescription(
        key="flow_state",
        translation_key="flow_state",
        value_fn=lambda coordinator: FLOW_STATE_NAMES.get(coordinator.data.valve.get("flowState"), coordinator.data.valve.get("flowState")),
    ),
    FloLogicSensorDescription(
        key="current_flow",
        translation_key="current_flow",
        native_unit_of_measurement="oz/min",
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=valve_value("currentFlow"),
    ),
    FloLogicSensorDescription(
        key="temperature",
        translation_key="temperature",
        device_class=SensorDeviceClass.TEMPERATURE,
        native_unit_of_measurement=UnitOfTemperature.FAHRENHEIT,
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=valve_value("temperature"),
    ),
    FloLogicSensorDescription(
        key="battery",
        translation_key="battery",
        device_class=SensorDeviceClass.BATTERY,
        native_unit_of_measurement=PERCENTAGE,
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=valve_value("batteryLevel"),
    ),
    FloLogicSensorDescription(
        key="signal_strength",
        translation_key="signal_strength",
        device_class=SensorDeviceClass.SIGNAL_STRENGTH,
        native_unit_of_measurement="dBm",
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=valve_value("signalStrength"),
    ),
    FloLogicSensorDescription(
        key="flow_sensitivity",
        translation_key="flow_sensitivity",
        native_unit_of_measurement="oz/min",
        value_fn=valve_value("dripRate"),
    ),
    FloLogicSensorDescription(
        key="home_flow_limit",
        translation_key="home_flow_limit",
        native_unit_of_measurement="min",
        value_fn=valve_value("homeIntervalTime"),
    ),
    FloLogicSensorDescription(
        key="away_flow_limit",
        translation_key="away_flow_limit",
        native_unit_of_measurement="min",
        value_fn=valve_value("awayIntervalTime"),
    ),
    FloLogicSensorDescription(
        key="bypass_time",
        translation_key="bypass_time",
        native_unit_of_measurement="min",
        value_fn=valve_value("bypassTime"),
    ),
    FloLogicSensorDescription(
        key="auto_away",
        translation_key="auto_away",
        native_unit_of_measurement="h",
        value_fn=valve_value("autoAwayTime"),
    ),
    FloLogicSensorDescription(
        key="low_temperature_alert",
        translation_key="low_temperature_alert",
        device_class=SensorDeviceClass.TEMPERATURE,
        native_unit_of_measurement=UnitOfTemperature.FAHRENHEIT,
        value_fn=valve_value("lowTemperatureAlert"),
    ),
    FloLogicSensorDescription(
        key="low_temperature_shutoff",
        translation_key="low_temperature_shutoff",
        device_class=SensorDeviceClass.TEMPERATURE,
        native_unit_of_measurement=UnitOfTemperature.FAHRENHEIT,
        value_fn=valve_value("lowTemperatureLimit"),
    ),
    FloLogicSensorDescription(
        key="pre_alert_notice",
        translation_key="pre_alert_notice",
        native_unit_of_measurement="min",
        value_fn=valve_value("preAlertNoticeInterval"),
    ),
    FloLogicSensorDescription(
        key="no_flow_notice",
        translation_key="no_flow_notice",
        native_unit_of_measurement="s",
        value_fn=valve_value("noFlowNoticeInterval"),
    ),
    FloLogicSensorDescription(
        key="shutoff_countdown",
        translation_key="shutoff_countdown",
        device_class=SensorDeviceClass.DURATION,
        native_unit_of_measurement=UnitOfTime.SECONDS,
        value_fn=lambda coordinator: coordinator.data.shutoff_countdown_seconds,
    ),
    FloLogicSensorDescription(
        key="flow_started_at",
        translation_key="flow_started_at",
        device_class=SensorDeviceClass.TIMESTAMP,
        value_fn=lambda coordinator: coordinator.data.flow_started_at,
    ),
    FloLogicSensorDescription(
        key="flow_elapsed",
        translation_key="flow_elapsed",
        device_class=SensorDeviceClass.DURATION,
        native_unit_of_measurement=UnitOfTime.SECONDS,
        value_fn=lambda coordinator: coordinator.data.flow_elapsed_seconds,
    ),
    FloLogicSensorDescription(
        key="active_scheduler_events",
        translation_key="active_scheduler_events",
        value_fn=lambda coordinator: len(coordinator.data.active_scheduler_events),
    ),
    FloLogicSensorDescription(
        key="notification_history_count",
        translation_key="notification_history_count",
        value_fn=lambda coordinator: len(coordinator.data.notifications),
    ),
    FloLogicSensorDescription(
        key="last_update_source",
        translation_key="last_update_source",
        entity_category=EntityCategory.DIAGNOSTIC,
        value_fn=lambda coordinator: coordinator.data.update_source,
    ),
)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    """Set up FloLogic sensors."""
    coordinator: FloLogicCoordinator = hass.data[DOMAIN][entry.entry_id]
    async_add_entities(
        FloLogicLocallyTickingFlowSensor(coordinator, description)
        if description.key in {"flow_elapsed", "shutoff_countdown"}
        else FloLogicSensor(coordinator, description)
        for description in SENSORS
    )


class FloLogicSensor(FloLogicEntity, SensorEntity):
    """FloLogic sensor."""

    entity_description: FloLogicSensorDescription

    def __init__(self, coordinator: FloLogicCoordinator, description: FloLogicSensorDescription) -> None:
        """Initialize the sensor."""
        super().__init__(coordinator, description.key)
        self.entity_description = description

    @property
    def native_value(self) -> Any:
        """Return the sensor value."""
        return self.entity_description.value_fn(self.coordinator)

    @property
    def extra_state_attributes(self) -> dict[str, Any] | None:
        """Return useful attributes for grouped values."""
        if self.entity_description.key == "active_scheduler_events":
            return {"events": self.coordinator.data.active_scheduler_events}
        if self.entity_description.key == "notification_history_count":
            return {"notifications": self.coordinator.data.notifications}
        return None


class FloLogicLocallyTickingFlowSensor(FloLogicSensor):
    """FloLogic flow sensor that ticks locally while water is flowing."""

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
        """Refresh the local elapsed-flow value."""
        self._unsub_tick = None
        if not self.coordinator.data.is_water_flowing:
            self._stop_tick_timer()
            self.schedule_update_ha_state()
            return
        self.schedule_update_ha_state()
        self._schedule_next_tick()
