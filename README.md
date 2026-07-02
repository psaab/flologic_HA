# FloLogic Home Assistant Custom Integration

This is an early custom integration for FloLogic Connect/G-Connect devices. It uses the same FloLogic cloud SignalR hub that the mobile app uses.

## Install

Copy this folder into Home Assistant:

```text
custom_components/flologic
```

Then restart Home Assistant and add the integration from:

```text
Settings -> Devices & services -> Add integration -> FloLogic
```

Use your FloLogic email and password. Leave the hub URL and device fields at their defaults unless you are testing a different endpoint.

## Exposed Entities

The integration creates status sensors for:

- Valve mode
- Flow state
- Current flow
- Temperature
- Battery
- Signal strength
- Flow sensitivity
- Home and Away flow limits
- Bypass time
- Auto Away time
- Low-temperature alert and shutoff thresholds
- Pre-alert notice interval
- No-flow notice interval
- Estimated shutoff countdown
- Flow started at
- Flow elapsed
- Active scheduled mode-change count
- Notification history count
- Last update source: `poll` or `push`

It creates binary sensors for:

- Online/offline
- Advance shutoff warning
- Each app notification setting flag, including mode change, auto shutoff, auto away, delay away, guest mode, connection change, general alert, critical error, and no-flow.

It creates a select entity for:

- Valve mode: `home`, `away`, `bypass`, `shutoff`, `disabled`

## Services

The integration registers these services under the `flologic` domain:

- `flologic.set_flow_sensitivity`
- `flologic.set_home_limit`
- `flologic.set_away_limit`
- `flologic.set_bypass_time`
- `flologic.set_auto_away`
- `flologic.set_temp_alert`
- `flologic.set_temp_shutoff`
- `flologic.set_pre_alert_notice`
- `flologic.set_no_flow_notice`

The mode select also sends mode changes directly.

## Advance Shutoff Warning

The FloLogic app's Advance Shutoff notification is generated when continuous water flow is close to the configured automatic shutoff limit.

This integration captures that as:

- `Shutoff countdown`: estimated seconds until automatic shutoff while water is flowing.
- `Advance shutoff warning`: turns on when countdown is within the `Pre-alert notice` window and the `Notification advance shutoff` setting is enabled.

This is computed from the valve state returned by FloLogic: mode, flow state, `lastNewFlow`, Home/Away/Bypass limits, and `preAlertNoticeInterval`.

Because this is cloud polling, Home Assistant first learns that water is flowing on the next refresh or pushed valve update. After that, the `Flow elapsed`, `Shutoff countdown`, and `Advance shutoff warning` entities use the FloLogic `lastNewFlow` timestamp as their anchor and tick locally every second while water is flowing. Those local counters do not create extra FloLogic cloud requests.

For more app-like timing, enable Keep Session Alive and set the polling interval to a short value such as `1` to `5` seconds. Keep Session Alive lets pushed `ValveSent` / `ValveArraySent` events update Home Assistant between polls when FloLogic sends them.

## Options

After setup, open the integration's Options page to tune cloud behavior:

- Polling interval in seconds: defaults to `60`. The minimum in the UI is `1`.
- Keep cloud session alive: defaults to off. When enabled, the integration keeps one SignalR websocket open, listens for pushed `ValveSent` / `ValveArraySent` updates, and reuses the websocket for refreshes and commands. If FloLogic or the network closes the socket, the integration reconnects with conservative backoff.

Keep Session Alive avoids reconnecting for every update and can update Home Assistant as soon as FloLogic pushes valve events. Polling still remains as a fallback. Use shorter polling only if pushed events are not frequent enough for your automations. Short intervals may increase cloud traffic, Home Assistant state churn, and the chance of FloLogic throttling or closing the connection.

## Current Limits

- Notification history is implemented, but your account currently returns an empty history array from FloLogic.
- Notification setting toggles are exposed read-only for now. They are stored on the FloLogic access record and can be made writable after another test pass.
- The default mode uses a short-lived cloud SignalR connection for each poll/command. Persistent websocket mode is available in Options and listens for pushed valve updates, but should be treated as newer/less-tested than the default until it has had some runtime soak.
- Scheduler is treated as scheduled valve mode changes. The current version exposes active scheduler entries as attributes, but does not edit schedules.

## Local Version Research Plan

For a fully local version, the next phase is to observe the Connect module on the LAN:

1. Capture DNS, TLS, and outbound destination metadata from the device.
2. Determine whether the device speaks directly to Azure IoT Hub, FloLogic app services, or a proprietary gateway.
3. Check whether traffic is TLS-pinned or token-authenticated in a way that prevents local interception.
4. If feasible, build a local proxy/bridge that emulates the cloud-facing service or subscribes to the local gateway stream.

The earlier LAN scan only exposed a W5500 demo web server on port 5000, so the useful protocol is likely outbound from the device rather than an inbound local API.
