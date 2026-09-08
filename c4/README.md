# FloLogic Control4 Driver

> New installs use the split drivers — one `FloLogic Cloud` coordinator
> plus one `FloLogic Water Valve` per valve — documented in
> [SPLIT_README.md](SPLIT_README.md) (version 2026090802). Below
> documents the legacy single-driver monolith (`FloLogic Valve`,
> version **2026090709**), which still works but is no longer packaged
> or published; see the split guide for manual migration. Do NOT install
> any post-split `flologic_valve.c4z` on a monolith instance — that
> filename is now the split valve driver, not a monolith upgrade.

Control4 DriverWorks driver for FloLogic Connect valves, based on the
[Home Assistant integration](../README.md). Version **2026090709**, targeting
Control4 OS **3.3.0 or newer**. One instance monitors one explicitly selected
valve. This is a poll-based programming driver; it has no Navigator interface
or sensor proxy bindings. Two contact sensor connections report valve-closed
and away status for programming and state detection.

## Install

Install the last monolith build from the `c4-v2026090709` release tag
(`sh c4/scripts/package.sh` no longer builds the monolith), then add
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
`flologic_valve.c4z`, keeping the existing project instances — but only
with monolith-era builds (`c4-v2026090709` and older). Post-split
`flologic_valve.c4z` files are the split valve driver and must never be
installed over a monolith instance. Confirm **Driver Version** on each
instance. The package filename, self-proxy name,
and existing command/event identities remain stable so programming references
can remain attached to those instances.

The bundle retires the previous runtime before redefining any modules. It
cancels old HTTP transfers, sessions, timers, and update checks, then replaces
module tables and runtime state. Composer upgrades use `OnDriverDestroyed`,
then load the bundle and call `OnDriverInit` and `OnDriverLateInit` with
`DIT_UPDATING`. The additional `OnDriverUpdated` callback also restarts the driver;
repeated late-init/update callbacks leave one timer set. Persistent device identity,
credentials, and valve selection survive. Retired network bindings remain
reserved until Director acknowledges their disconnection.

Version 2026090705 introduced an explicit closing `script` tag, matching Proflame's
[working reload manifest](https://github.com/psaab/proflame_c4/commit/c295ce0678b3).
This is a compatibility change; its effect still needs verification on Director.
Lua Output now reports `Lua loaded`, each initialization callback with its reason,
and `Runtime ready`, including the running version even with Debug Mode off.
Capture those lines during an upgrade to distinguish failure to load the new
package from failure during initialization or subsequent cloud polling.

**Actions → Refresh GitHub Updates** reads releases from
[psaab/flologic_HA](https://github.com/psaab/flologic_HA/releases). It checks once
10 seconds after startup and every **Update Check Interval** hours (default
24; 0 disables periodic checks). **Update Status**, **Latest Driver Version**,
and **Update Download URL** identify a published C4 package. Checks are
report-only.

**Actions → Install Latest Release** attempts to download and install the newest
C4 release. **Force Reinstall Latest Release (Recovery)** targets the latest
published release even when it matches or is older than the running build;
it does not restore a bundled or guaranteed known-good copy. Both actions
are always present; periodic checks update properties, not button availability.

Version 2026090707 removes the initialization-time filesystem restriction
override. Direct installation can fail when Director denies access to its
package store; use Composer to install the downloaded package instead.
An `Installation unconfirmed` result does not prove an update occurred.
Verify the running **Driver Version** and lifecycle messages in Lua Output.

The direct installer still lacks package-content validation and safe replacement
of the previous stored package. A write failure can leave that file incomplete
or missing. Use Composer installation until those remaining issues are addressed.

C4 releases use `c4-vYYYYMMDDNN` tags. Monolith-era tags carried the
monolith as the exactly named `flologic_valve.c4z` asset; current tags
carry the split valve driver under that same filename instead, so a
monolith will report it as an available update — do not install it.
Drafts, prereleases, and Home Assistant releases are
ignored. A build newer than GitHub is reported explicitly. A repository with
no eligible C4 asset is reported as such, rather than as up to date.

To publish after committing and pushing a tested build, create and push a tag
matching the XML/Lua version (for this build, `c4-v2026090709`). The
`release-c4.yml` workflow verifies the tag, tests/rebuilds the driver, and uploads
its asset. C4 releases are not marked as GitHub's latest release, preserving
that designation for Home Assistant. No tag or release is published merely by
running the local packaging script.

Version 2026090703 adds static update properties/actions. Composer must re-read
`driver.xml` to register them; a Lua-only reload is insufficient. Refresh the
Composer project/driver metadata if those fields are missing after installation.

## Contact sensor status connections

Under Composer **Connections → Control**, bind these CONTACT_SENSOR provider
outputs to contact-consuming drivers, or use them directly in programming to
detect the reported state:

| Connection | Binding ID | Closed means | Open means |
| --- | --- | --- | --- |
| Valve Closed | 101 | FloLogic reports a shutoff condition | No shutoff condition reported |
| Away Mode | 102 | Away, automatic-away, or external-away flag is active | None of those away flags is active |

Valve Closed includes flow-time-limit trips, manual shutoff, leak, emergency,
and temperature/humidity shutoff flags. It reflects the reported cloud state;
it is not a separate physical valve-position measurement. Away remains active
if its flag is still present during a shutoff. Delayed-away is not active-away.

These are status outputs: they report state and never accept commands to move
the valve or change its mode. Use the driver's explicit mode commands for
control. Initial status, reconnects, and new bindings use
STATE_OPENED/STATE_CLOSED; subsequent observed transitions use OPENED/CLOSED.
Unchanged polls send no additional notifications. During an outage the
connected consumer retains its last indication, because a contact has no
unknown state. Check **Connection** and **Last Update** before treating it as
current; stale state is not replayed to a new binding. Recovery establishes a
fresh baseline without false transitions.

Version 2026090704 adds static relay connections and renames the update action
to **Refresh GitHub Updates**. Install the complete `.c4z` through Composer's
**Add or Update Driver…** and refresh its driver metadata to expose the new
connections/button. Loading Lua alone does not install these XML changes.

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

A binding that connected is retired until Director reports OFFLINE, then
released; a binding closed before connecting is released immediately so a
missing OFFLINE cannot strand it. The allocator never reissues a live hub or
Composer binding id even when Director reports no address for it. Callbacks
for other bindings or ports are ignored. If the bounded pool ever exhausts,
the driver reports an allocation failure rather than reusing a live binding.

## Director acceptance checklist

The offline suite plus the published
[DriverWorks API](https://control4.github.io/docs-driverworks-api/) verify the
timer, hash, transfer, file, TLS, UUID, and contact-notify contracts, but
these behaviors need a real controller:

- Which `GetDevicesByC4iName` key matches (`flologic_valve.c4i`,
  `flologic_valve`, or the package filename). The driver tries all three.
- Which `FileSetDir` alias stages where the Composer trigger finds the
  package (`C4Z_ROOT` first, documented `C4Z` on denial).
- End-to-end Install Latest Release and Force Reinstall: the
  `UpdateProjectC4i` SOAP trigger on port 5020 is undocumented folk
  knowledge, so confirm Director actually loads the staged build.
- `STATE_OPENED`/`STATE_CLOSED` initial sync versus `OPENED`/`CLOSED`
  transitions on real CONTACT_SENSOR bindings (the base vocabulary matches
  the documented `SendToProxy` example; the `STATE_` distinction is ours).
- A live cloud poll and a mode command round trip, repeated reconnects,
  credential/selection changes, and two driver instances polling together.

Polling is not an alarm delivery guarantee. WAN outages and cloud latency can
delay events, and transitions between polls may be missed. FloLogic's own
protection remains independent of this driver.

## Development

Edit `src/*.lua` (legacy; `package.sh` no longer builds the monolith —
`driver.lua` and the old `flologic_valve.c4z` were its generated artifacts).
The bootstrap runs before module replacement; the protocol/model and release
selection modules are transport-independent. `src/main.lua` owns
Director callbacks, properties, transports, and lifecycle. Tests use injected
transports plus a Director shim; production never loads test helpers.

```sh
stylua --config-path c4/stylua.toml c4/src c4/tests
sh c4/scripts/bundle.sh
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
