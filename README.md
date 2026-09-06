# FloLogic Home Assistant Integration

Custom Home Assistant integration for FloLogic Connect and G-Connect devices.

The integration connects to the FloLogic cloud service used by the mobile app and exposes valve status, flow telemetry, alert states, selected settings, and valve mode control in Home Assistant.

## Features

- UI-based setup with FloLogic email and password
- Cloud polling with configurable polling interval
- Optional persistent SignalR session for pushed valve updates
- Automatic reconnect when the persistent session is interrupted
- Valve mode control: `home`, `away`, `bypass`, `shutoff`, `disabled`
- Flow elapsed time and estimated shutoff countdown
- Advance shutoff warning
- Grouped trouble sensors for water-off, warning/alert, and critical fault states
- Read-only notification setting sensors
- Service actions for supported FloLogic settings
- Multi-valve accounts: every controllable valve gets its own device and entities

## Installation

### HACS custom repository

1. Open HACS in Home Assistant.
2. Add `https://github.com/technorat2/flologic_HA` as a custom repository.
3. Select repository type `Integration`.
4. Install the FloLogic integration.
5. Restart Home Assistant.
6. Go to **Settings** -> **Devices & services** -> **Add integration**.
7. Search for **FloLogic** and complete setup.

### Manual installation

1. Copy `custom_components/flologic` into your Home Assistant `custom_components` directory.
2. Restart Home Assistant.
3. Add the integration from **Settings** -> **Devices & services**.

## Configuration

During setup, enter your FloLogic account email and password.

Advanced fields are available for non-standard deployments:

- Hub URL
- Device name
- Device code
- Device token

Most users should leave the advanced fields unchanged.

If the account has more than one valve, setup asks which valves this Home
Assistant install monitors. Pick only the valves installed at this site;
each home should run its own install with its own selection. The choice
defaults to the first valve and can select several when one install is
genuinely responsible for more than one.

## Options

After setup, open the integration options to configure cloud behavior:

- **Polling interval in seconds**: Defaults to `60`; minimum is `1`.
- **Keep cloud session alive**: Keeps one SignalR websocket open, listens for pushed valve updates, and reconnects automatically if the connection closes.
- **Monitored valves**: Which valves this install tracks. New valves on the account are never added automatically; widen the selection here when a valve is added to this site. Changing the selection reloads the integration.

Polling remains active when persistent mode is enabled. It acts as a fallback in case pushed updates are delayed or missed.

## Entities

### Sensors

- Mode
- Flow state
- Current flow
- Temperature
- Battery
- Signal strength
- Flow sensitivity
- Home flow limit
- Away flow limit
- Bypass time
- Auto Away
- Low temperature alert
- Low temperature shutoff
- Pre-alert notice
- No-flow notice
- Shutoff countdown
- Flow started at
- Flow elapsed
- Active scheduled mode changes
- Notification history count
- Last update source

### Binary sensors

- Online
- Advance shutoff warning
- Water-off event
- Warning or alert event
- Critical fault event
- Notification setting flags

The grouped trouble sensors expose the raw FloLogic mode and active decoded mode flags as attributes.

### Selects

- Valve mode

## Service Actions

The integration registers these service actions under the `flologic` domain:

- `flologic.set_flow_sensitivity`
- `flologic.set_home_limit`
- `flologic.set_away_limit`
- `flologic.set_bypass_time`
- `flologic.set_auto_away`
- `flologic.set_temp_alert`
- `flologic.set_temp_shutoff`
- `flologic.set_pre_alert_notice`
- `flologic.set_no_flow_notice`

### Multi-valve targeting

Every action accepts the same optional targeting fields: `valve_id`
(FloLogic valve id or uuid), `device_id` (Home Assistant device id), or
`entity_id` (one or more FloLogic entities, whose valves are controlled).
Give at most one of them. `valve_uuid` is also accepted as an alias for
`valve_id`. Empty or conflicting targets are rejected.

- With exactly one loaded valve across all configured accounts, the target
  may be omitted.
- With multiple valves, an explicit target is required. Actions never fan
  out to valves the caller did not name: an unknown or missing target is a
  validation error, not a broadcast.
- Targets resolve across all loaded accounts. If a cloud valve ID matches
  more than one account, use `device_id` or `entity_id` to identify its owner.
- If several valves are targeted via `entity_id` and some fail, the failure
  is logged with the affected valves; if all fail, the action raises.

## Advance Shutoff Warning

FloLogic can notify users before continuous flow reaches the automatic shutoff limit. This integration exposes that behavior with:

- `Shutoff countdown`: estimated seconds until automatic shutoff while water is flowing.
- `Advance shutoff warning`: turns on when the countdown is inside the configured pre-alert window and the FloLogic notification setting is enabled.

The estimate uses FloLogic valve state, flow state, `lastNewFlow`, mode-specific flow limits, and `preAlertNoticeInterval`. Once Home Assistant learns that water is flowing, elapsed time and countdown entities tick locally each second without creating additional FloLogic cloud requests.

## Known Limitations

- This integration uses FloLogic cloud services and requires internet access.
- Notification history may be empty if the FloLogic service returns no history for the account.
- Notification setting toggles are exposed read-only.
- Scheduler entries are exposed for visibility, but schedule editing is not implemented.

## Removal

1. Delete the FloLogic integration from **Settings** -> **Devices & services**.
2. Restart Home Assistant.
3. If manually installed, remove `custom_components/flologic`.

## Support

Open issues at:

https://github.com/technorat2/flologic_HA/issues

## Development

Tests use the real Home Assistant harness with mocked cloud clients. With Python
3.14, install `requirements_test.txt` into a virtual environment and run
`python -m pytest -q`. CI runs the same suite, Ruff, and Python/JSON checks.
