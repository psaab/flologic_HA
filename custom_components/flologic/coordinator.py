"""FloLogic coordinator."""

from __future__ import annotations

from datetime import timedelta
import logging

from homeassistant.core import HomeAssistant
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed

from .api import FloLogicAccount, FloLogicClient
from .const import DOMAIN
from .exceptions import FloLogicError

_LOGGER = logging.getLogger(__name__)


class FloLogicCoordinator(DataUpdateCoordinator[FloLogicAccount]):
    """Coordinate FloLogic polling."""

    def __init__(self, hass: HomeAssistant, client: FloLogicClient, poll_interval: int) -> None:
        """Initialize the coordinator."""
        super().__init__(
            hass,
            _LOGGER,
            name=DOMAIN,
            update_interval=timedelta(seconds=poll_interval),
        )
        self.client = client
        self.client.set_push_callback(self._handle_pushed_account)

    async def _async_update_data(self) -> FloLogicAccount:
        """Fetch data from FloLogic."""
        try:
            return await self.client.async_fetch_account()
        except FloLogicError as err:
            raise UpdateFailed(str(err)) from err

    def _handle_pushed_account(self, account: FloLogicAccount) -> None:
        """Update entities from a pushed SignalR valve event."""
        self.async_set_updated_data(account)
