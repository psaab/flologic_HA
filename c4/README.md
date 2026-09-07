# FloLogic Control4 Driver

Control4 DriverWorks driver for FloLogic Connect valves, based on the
[Home Assistant integration](../README.md). Version **2026090703**, targeting
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

## Updates and reloads

In Composer Pro, use **Driver → Add or Update Driver…** with the new
`flologic_valve.c4z`, keeping the existing project instances. Confirm
**Driver Version** on each instance. The package filename, self-proxy name,
and existing command/event identities remain stable so programming references
can remain attached to those instances.

The bundle retires the previous runtime before redefining any modules. It
cancels old HTTP transfers, sessions, timers, and update checks, then replaces
module tables and runtime state. `OnDriverUpdated` restarts the driver; repeated
late-init/update callbacks leave one timer set. Persistent device identity,
credentials, and valve selection survive. Retired network bindings remain
reserved until Director acknowledges their disconnection.

**Actions → Check for Update** reads releases from
[psaab/flologic_HA](https://github.com/psaab/flologic_HA/releases). It checks once
10 seconds after startup and every **Update Check Interval** hours (default
24; 0 disables periodic checks). **Update Status**, **Latest Driver Version**,
and **Update Download URL** identify a published C4 package. Checks are
report-only; install the downloaded package using Composer.

The automatic installer in the Proflame reference relies on an undocumented
bypass of restricted driver-storage access. This driver does not include that
bypass or claim that discovering a release installs it. Its supported workflow
is GitHub discovery followed by Composer installation.

C4 releases use `c4-vYYYYMMDDNN` tags and must contain exactly named
`flologic_valve.c4z` assets. Drafts, prereleases, and Home Assistant releases are
ignored. A build newer than GitHub is reported explicitly. A repository with
no eligible C4 asset is reported as such, rather than as up to date.

To publish after committing and pushing a tested build, create and push a tag
matching the XML/Lua version (for this build, `c4-v2026090703`). The
`release-c4.yml` workflow verifies the tag, tests/rebuilds the driver, and uploads
its asset. C4 releases are not marked as GitHub's latest release, preserving
that designation for Home Assistant. No tag or release is published merely by
running the local packaging script.

Version 2026090703 adds static update properties/actions. Composer must re-read
`driver.xml` to register them; a Lua-only reload is insufficient. Refresh the
Composer project/driver metadata if those fields are missing after installation.

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
The bootstrap runs before module replacement; the protocol/model and release
selection modules are transport-independent. `src/main.lua` owns
Director callbacks, properties, transports, and lifecycle. Tests use injected
transports plus a Director shim; production never loads test helpers.

```sh
stylua --config-path c4/stylua.toml c4/src c4/tests
sh c4/scripts/package.sh
lua5.1 c4/tests/loader_standalone.lua
python -m pytest tests/test_c4_lua.py
```

The Python runner explicitly selects Lua 5.1 through `lupa.lua51`. Tests cover
protocol vectors, full sessions, discovery, negative command results,
handshake/session timeouts, cancellation, stale callbacks, queue limits,
Composer actions, repeated loads in the same Lua runtime, GitHub release
selection/cancellation, and exact package contents/version consistency.

[Control4 conventions and review notes](CONVENTIONS.md) records the
FiniteLabs references, adopted patterns, and larger architectural improvements.
