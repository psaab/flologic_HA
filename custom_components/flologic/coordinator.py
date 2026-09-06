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


def select_monitored_accounts(
    accounts: dict[str, FloLogicAccount],
    monitored_valves: set[str] | None,
) -> dict[str, FloLogicAccount]:
    """Return only the accounts this install monitors.

    A ``None`` selection means "all valves" and is only used before a
    config entry has recorded an explicit selection; nothing new is ever
    auto-added once a selection exists.
    """
    if monitored_valves is None:
        return dict(accounts)
    return {key: acct for key, acct in accounts.items() if key in monitored_valves}


class FloLogicCoordinator(DataUpdateCoordinator[dict[str, FloLogicAccount]]):
    """Coordinate FloLogic polling for the monitored valves."""

    def __init__(
        self,
        hass: HomeAssistant,
        client: FloLogicClient,
        poll_interval: int,
        monitored_valves: set[str] | None = None,
    ) -> None:
        """Initialize the coordinator."""
        super().__init__(
            hass,
            _LOGGER,
            name=DOMAIN,
            update_interval=timedelta(seconds=poll_interval),
        )
        self.client = client
        self.monitored_valves = monitored_valves
        self.client.set_push_accounts_callback(self._handle_pushed_accounts)

    async def _async_update_data(self) -> dict[str, FloLogicAccount]:
        """Fetch data from FloLogic."""
        try:
            accounts = await self.client.async_fetch_accounts()
        except FloLogicError as err:
            raise UpdateFailed(str(err)) from err
        selected = select_monitored_accounts(accounts, self.monitored_valves)
        if self.monitored_valves is not None:
            missing = self.monitored_valves - accounts.keys()
            if missing:
                _LOGGER.warning(
                    "FloLogic is configured to monitor valves %s, but the "
                    "cloud did not return them; their entities are unavailable "
                    "until the selection is fixed in the integration options",
                    sorted(missing),
                )
        return selected

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
        lingering as stale ghosts. Empty pushes are ignored. Only monitored
        valves are kept; pushes for other valves are dropped.
        """
        selected = select_monitored_accounts(accounts, self.monitored_valves)
        if not selected:
            return
        self.async_set_updated_data(selected)
