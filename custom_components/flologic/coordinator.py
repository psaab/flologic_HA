"""FloLogic coordinator."""

from __future__ import annotations

import logging
from datetime import timedelta

from homeassistant.core import HomeAssistant
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed

from .api import FloLogicAccount, FloLogicClient
from .const import DOMAIN
from .exceptions import FloLogicError

_LOGGER = logging.getLogger(__name__)


class FloLogicCoordinator(DataUpdateCoordinator[dict[str, FloLogicAccount]]):
    """Coordinate FloLogic polling for one or more valves."""

    def __init__(
        self, hass: HomeAssistant, client: FloLogicClient, poll_interval: int
    ) -> None:
        """Initialize the coordinator."""
        super().__init__(
            hass,
            _LOGGER,
            name=DOMAIN,
            update_interval=timedelta(seconds=poll_interval),
        )
        self.client = client
        self.client.set_push_accounts_callback(self._handle_pushed_accounts)

    async def _async_update_data(self) -> dict[str, FloLogicAccount]:
        """Fetch data from FloLogic."""
        try:
            return await self.client.async_fetch_accounts()
        except FloLogicError as err:
            raise UpdateFailed(str(err)) from err

    @property
    def accounts(self) -> dict[str, FloLogicAccount]:
        """Return current accounts keyed by unique_id_prefix."""
        if isinstance(self.data, dict):
            return self.data
        return {}

    @property
    def primary_account(self) -> FloLogicAccount | None:
        """Return the first/primary account."""
        if isinstance(self.data, dict) and self.data:
            return next(iter(self.data.values()))
        return None

    def _handle_pushed_accounts(self, accounts: dict[str, FloLogicAccount]) -> None:
        """Update entities from a pushed multi-valve event.

        The client always pushes its full known valve set, so the push
        replaces the data: valves removed cloud-side disappear instead of
        lingering as stale ghosts. Empty pushes are ignored.
        """
        if not accounts:
            return
        self.async_set_updated_data(dict(accounts))
