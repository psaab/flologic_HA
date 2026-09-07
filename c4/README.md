# FloLogic Control4 Driver

Control4 DriverWorks driver for FloLogic Connect valves, based on the
[Home Assistant integration](../README.md). Version **2026090702**, targeting
Control4 OS **3.3.0 or newer**. One instance monitors one explicitly selected
valve. This is a poll-based programming driver; it has no Navigator interface
or sensor/relay proxy bindings.

## Install

Build the package with `sh c4/scripts/package.sh`, then add
`flologic_valve.c4z` through Composer Pro. Set **Email** and **Password**.
The first poll discovers the account's valves. Choose **Select Valve** before
monitoring or sending commands. **Valve ID Override** accepts an ID or UUID
and takes precedence over the picker.

A missing selection stays unavailable. The driver never selects another valve
because the original disappears or the inventory order changes. Editing the
account, endpoint, or selection cancels outstanding work and queued commands.
A command already transmitted to the cloud cannot be recalled.

## Operation

Every poll and command uses a short-lived SignalR session:
HTTPS negotiate → TLS WebSocket upgrade → SignalR acknowledgement → login →
full inventory → selected-valve metadata or command → cleanup.

Both negotiation and WebSocket upgrade send the same device identity,
application/platform, device name, and relog headers, matching the HA client.
Version 2026090702 fixes their omission from the WebSocket upgrade, which
could leave login waiting for `LoggedIn` until timeout.

- Poll interval: 30–3600 seconds, default 60. Only one session runs at a time.
- Commands queue behind an active session, with a maximum of eight waiting
  commands. Overflow rejects the new command and preserves existing commands.
- **Last Command** distinguishes queued, failed, and acknowledged requests.
  Acknowledgement is followed by a status refresh; it does not confirm that
  the physical valve has moved. Writes are never automatically replayed.
- Every session has a 180-second deadline; upgrade and hub operations also
  have individual timeouts. Destruction and configuration changes cancel the
  HTTP transfer, socket, pending refresh, and session timers.
- Countdown and elapsed-flow properties update locally every five seconds
  while the last valid snapshot reports flow. A failed poll stops those
  timers. Other telemetry and **Last Update** retain the last received values;
  check **Connection** before using them.
- The first snapshot after startup, selection changes, or a connection error
  establishes an event baseline. It does not emit valve transition events.
- Debug Mode automatically returns to Off after three hours. Credentials,
  relog tokens, and raw protocol bodies are not logged.

Composer properties expose connection, mode, flow, temperature, battery,
signal strength, limits, countdown, elapsed flow, scheduler/notification
counts, available valves, and the last update time. Programming commands
cover mode changes and the same settings/ranges as the HA integration,
including fractional away limits and flow sensitivity. Events cover flow,
water-off, warning, critical fault, mode, advance warning, and connection
transitions. Refresh actions work from both programming and Composer Actions.

## Networking and validation limits

Negotiate uses `C4:url()` with explicit peer and hostname verification,
connection/request timeouts, and cancellation. Raw WebSocket TLS uses
`NetPortOptions` with `VERIFY_MODE = "peer"` and the packaged
`./ca-bundle.pem`, as documented by the
[DriverWorks API](https://control4.github.io/docs-driverworks-api/).
There is no fallback to unverified TLS.

The trust bundle is unmodified **certifi 2026.07.22** Mozilla CA data.
Its license is included as `CA-LICENSE`. Update both files from an official
certifi release when maintaining trust roots, then rebuild the package.
See [certifi](https://github.com/certifi/python-certifi).

**Real Director validation remains required.** The offline tests cannot prove
Director's certificate bundle loading, SNI behavior, or raw-socket hostname
verification. `VERIFY_MODE = "peer"` establishes chain verification; the
published raw-socket API does not document a hostname verification switch.
Do not treat the mocked tests as proof of full TLS endpoint authentication.
Test the cloud connection, bad-certificate behavior, Composer import, actions,
repeated reconnects, and multiple driver instances on the target OS before
production use.

A retired binding is held until Director reports OFFLINE, then released.
Callbacks for other bindings or ports are ignored. A controller that never
reports disconnect completion can exhaust the bounded dynamic binding pool;
the driver reports an allocation failure rather than reusing a live binding.

Polling is not an alarm delivery guarantee. WAN outages and cloud latency can
delay events, and transitions between polls may be missed. FloLogic's own
protection remains independent of this driver.

## Development

Edit `src/*.lua`; `driver.lua` and `flologic_valve.c4z` are generated artifacts.
The protocol/model modules are transport-independent. `src/main.lua` owns
Director callbacks, properties, transports, and lifecycle. Tests use injected
transports plus a Director shim; production never loads test helpers.

```sh
stylua --config-path c4/stylua.toml c4/src c4/tests
lua5.1 c4/tests/loader_standalone.lua
sh c4/scripts/package.sh
python -m pytest tests/test_c4_lua.py
```

The Python runner explicitly selects Lua 5.1 through `lupa.lua51`. Tests cover
protocol vectors, full sessions, discovery, negative command results,
handshake/session timeouts, cancellation, stale callbacks, queue limits,
Composer actions, and exact package contents/version consistency.

[Control4 conventions and review notes](CONVENTIONS.md) records the
FiniteLabs references, adopted patterns, and larger architectural improvements.
