# FloLogic split drivers for Control4 (cloud + valve)

Two drivers replace the single monolith `FloLogic Valve` driver for new
installs. This guide covers what each driver is, how to install and bind
them, how the app tile behaves, and how to migrate. Per-driver details
live in [c4/cloud/README.md](cloud/README.md) (account coordinator) and
[c4/valve/README.md](valve/README.md) (per-valve companion); the wire
contract is [c4/shared/flologic_link.md](shared/flologic_link.md)
(normative code:
[`c4/shared/flologic_link.lua`](shared/flologic_link.lua)).

Both drivers share lockstep version **2026090808** (link protocol
version **1**). Releases ship both packages under one `c4-v*` tag (e.g.
`c4-v2026090808`); see [c4/RELEASE_NOTES.md](RELEASE_NOTES.md).
The valve tile click needs Director OS 3.3.2+ (`DYNAMIC_ON`/`DYNAMIC_OFF`);
the cloud driver runs on 3.3.0+.

| Driver | Name / model | Package | Proxy | Role |
| --- | --- | --- | --- | --- |
| Cloud | `FloLogic Cloud` | `c4/flologic_cloud.c4z` | none (no app tile, no contacts) | Account credentials, single poll loop, discovery, one dynamic `FLOGIC_VALVE` provider slot (ids 2001–2016) per valve |
| Valve | `FloLogic Water Valve` | `c4/flologic_valve.c4z` | `light_v2` (switch tile, binding 5001) | One instance per physical valve: state display, seven contact outputs, app on/off, programming commands |

Composer identities (name, model, proxy) are fully distinct from the
monolith (`FloLogic Valve` / `FloLogic Connect` / `flologic_valve`), but
the valve package intentionally reuses the legacy monolith asset filename
`flologic_valve.c4z`. Installed monoliths will therefore offer the valve
driver as an update: never install it over a monolith instance — migrate
manually (delete the monolith, add cloud + valves) instead.

## Install order

1. Build the packages with `sh c4/scripts/package.sh` (builds both
   split assets; the monolith is legacy and is no longer packaged), or
   take them from a GitHub `c4-v*` release.
2. In Composer, add **one** `FloLogic Cloud` driver (from
   `flologic_cloud.c4z`).
3. Set `Email` and `Password` on the cloud driver. Touch `Hub URL`
   (default `https://hub-cloudapps-prod.azurewebsites.net`) only if
   FloLogic moves it.
4. Wait one poll (`Poll Interval`, 30–3600 s, default 60) or run the
   cloud `Refresh` command. `Valve Count` / `Available Valves` (id: name
   pairs) confirm the account inventory.
5. Add **one `FloLogic Water Valve` driver per physical valve** (from
   `flologic_valve.c4z`).
6. In Connections view, bind each valve instance's **FloLogic Link**
   (consumer, id 600, class `FLOGIC_VALVE`) to that valve's named slot
   on the cloud driver (provider, ids 2001–2016, class `FLOGIC_VALVE`, each carrying its valve name).
   See [c4/cloud/README.md](cloud/README.md) for the handshake sequence
   (`FLOGIC_HELLO` → `FLOGIC_IDENTITY`).
7. Confirm on each valve: `Valve ID` / `Valve Name` fill in,
   `Connection` reads `Online`, and the app tile follows the valve.
8. Program against the **valve** drivers (contacts, events, commands).
   The cloud driver exposes no contacts and no app tile.

## Identity setup

There is nothing to type: the Composer binding plus the handshake
selects the valve.

- On bind the valve sends `FLOGIC_HELLO`; the cloud replies with that
  slot's valve id and starts pushing state. Unmapped slots stay silent.
- `Valve ID` / `Valve Name` are read-only displays. The persisted id is
  display continuity only and is never trusted across binds — every
  bind re-handshakes from scratch.
- To move a valve instance to a different physical valve, rebind its
  FloLogic Link to the other slot; the next handshake re-learns the
  identity. There is no `Select Valve` picker and no ID override on
  either new driver (deliberate; see `CLOUD-U6` in
  [c4/cloud/README.md](cloud/README.md) and `VALVE-U4` in
  [c4/valve/README.md](valve/README.md)).
- Removed valves mark their cloud slot unavailable without deleting the
  bound slot; the slot→valve map persists across restarts and bindings
  are re-created on init, so connections survive Director restarts. A
  10-minute reconcile timer re-discovers bound state because
  restart-restored connections may not re-fire bind events.

## Navigator app toggle behavior

Each valve appears in the app as an on/off switch (light proxy, no
dimmer slider).

- Tapping **off** shuts the water off (Shutoff mode). Tapping **on**
  restores the valve's last non-shutoff mode tracked from state pushes
  (default Home).
- Navigator taps arrive as `DYNAMIC_OFF` / `DYNAMIC_ON`; scenes and
  programming use `TOGGLE` and `SET_BRIGHTNESS_TARGET` (level > 0 on,
  0 off). The tile reports `LIGHT_LEVEL` 100/0 optimistically for
  responsiveness; contacts, properties, and events always follow the
  cloud's next `FLOGIC_STATE` push, never the tile tap alone.
- Reported level is 0 exactly when a water-off flag is active, else
  100 — the inverse of the Valve Closed contact.

## Contacts list

All seven live on each valve driver (all `CONTACT_SENSOR`;
`CLOSED` = named state true). The first push reports steady
`STATE_CLOSED`/`STATE_OPENED` so bindings never fire transition
programming on startup; later changes use `CLOSED`/`OPENED`.

| ID | Name | Closed means |
| --- | --- | --- |
| 101 | Valve Closed | Any shutoff flag (flow-limit trip, manual shutoff, leak, emergency, temperature shutoff) |
| 102 | Away Mode | Away, automatic-away, or external-away flag active |
| 103 | Flowing | Water is flowing |
| 104 | Leak Detected | External or sensor leak flag |
| 105 | Warning Active | A warning mode flag is active |
| 106 | Critical Fault | A critical fault flag is active |
| 107 | Valve Online | The valve reports online |

Per-valve events: Flow Started/Stopped, Water Off Detected/Cleared,
Warning Alert/Cleared, Critical Fault/Cleared, Mode Changed, Connection
Lost/Restored. The first state push sets the baseline and fires
nothing. There is no Advance Shutoff Warning event: the link slice
carries no flow-start timestamp, so the valve cannot compute it.

Valve programming commands: Open Valve, Close Valve, Toggle, Set Mode
Home/Away/Bypass/Shutoff/Disabled, the limit commands (Set Home Limit,
Set Away Limit, Set Bypass Time, Set Auto Away, Set Temp
Alert/Shutoff, Set Pre-Alert, Set No-Flow Notice, Set Flow
Sensitivity), Refresh (ask the cloud for state now), plus report-only
Check for Update and the Composer install commands tracking the
`flologic_valve.c4z` asset. Ranges mirror the monolith
(home/bypass/pre-alert 1–10080, away 0–10080 fractional, auto-away
1–8760 h, temperatures −50–150, no-flow notice 1–604800 s, flow
sensitivity 0–1000 fractional); the cloud revalidates and NACKs
anything unknown. The cloud driver's own commands are Check for
Update, Install Latest Release, Force Reinstall Latest Release,
Refresh, and Refresh Valve List; its events are Connection
Lost/Restored.

## Migrating from the monolith

Migration is manual; there is no auto-migration (identities, bindings,
and programming all differ). Installed monoliths keep working, but their
updater matches the valve package by filename and will offer it as an
update: do NOT install it over a monolith instance — it is a different
driver, not an upgrade. Migrate during a maintenance window and leave the
monolith alone until then. Old release tags still carry the monolith
`.c4z` for rollback.

1. On a maintenance window, note the monolith's account, selected
   valve, and programming (events, contacts 101/102, commands).
2. Delete the monolith driver instance from the project. Keep the old
   `.c4z` file for rollback.
3. Add `FloLogic Cloud`, configure the account, and confirm `Valve
   Count`.
4. Add one `FloLogic Water Valve` per valve and bind each to its slot.
5. Rebuild programming on the valve drivers: contacts 101–107,
   per-valve events, and mode/limit commands. Review every line:
   contact ids 101/102 keep their monolith meanings but 103–107 are
   new, event names differ, and there is no Advance Shutoff Warning
   event and no valve picker to configure.
6. Delete the monolith `.c4z` from the controller file store only after
   the new drivers report `Online` and the app tile toggles correctly.

Do not install the monolith `.c4z` and the new `.c4z` files as if they
were upgrades of each other. Note the repository still ships the
monolith sources alongside the split drivers (kept deliberately against
the plan's deletion step, so the legacy driver stays reviewable and its
last build stays reproducible); the release workflow publishes the valve
driver under the legacy `flologic_valve.c4z` filename, which is why
monolith instances must migrate manually instead of updating.

## Troubleshooting

- **Link loss.** `Connection` on the valve shows `Not linked` (with
  the last update time) when the binding drops, `Linking...` during
  the handshake, and `Degraded` when the cloud sends a digest-only
  snapshot. Last-known contacts and display stay put — programming
  never flaps on a link outage — and commands issued while unlinked
  are dropped with a `Last Command` note. Fix: check the Connections
  view binding (valve FloLogic Link 600 → cloud named slot), confirm
  `Valve Count` on the cloud, then run cloud `Refresh Valve List`.
- **Version mismatch.** Both drivers must run the same lockstep
  version (currently 2026090808; the release tag must equal both
  manifests, enforced by the release workflow). Each driver's updater
  tracks only its own asset (`flologic_cloud.c4z` /
  `flologic_valve.c4z`); a valve talking to a cloud on a
  different link version is rejected with `version-mismatch` (link
  protocol has no negotiation — either side rejects a foreign
  version). Fix: install the same release on both drivers via
  Composer; `Driver Version` on each instance confirms it.
- **Stale state.** Contacts and properties retain their last values on
  poll failure, outage, or digest-only state — check `Connection` and
  `Last Update` (cloud) / `Last Link Update` (valve) before treating
  readings as current. Recovery establishes a fresh baseline without
  false transitions or replayed events. Fix: run valve `Refresh` (asks
  the cloud for state now) or cloud `Refresh`; if the cloud itself is
  stale, check its `Connection` property — five consecutive session
  failures open a 5-minute circuit-breaker cooldown, and logical
  rejections (unknown valve, rejected write) never feed it.
- **Debugging.** Lua output is prefixed per driver
  (`[flologic-cloud]` / `[flologic-valve]`). `Debug Mode` returns to
  Off automatically; credentials and raw protocol bodies are never
  logged.

## Spike procedure (live Director check)

Before trusting the split on a real controller, run the unit-0 spike
in [spike/PROCEDURE.md](../spike/PROCEDURE.md) (read-only). It uses two
minimal stub drivers (`spike/cloud_stub.c4z`,
`spike/valve_stub.c4z`, version 2026090701, distinct spike-only
identities that never touch production drivers) to prove the
architecture's two risky assumptions:

1. Create the cloud stub's dynamic binding (`Add Valve Link` → id
   2002, class `FLOGIC_VALVE`; static 2001 is a Composer-indexing shim).
2. Bind it to the valve stub's link input; confirm the hello/identity
   exchange in both Lua logs.
3. Ping/pong both directions at 4096 then 16384 bytes; confirm full
   byte counts and matching sequence numbers.
4. Tap the Navigator tile off/on; confirm level 0/100 with matching
   `LIGHT_LEVEL`, and exercise `Turn Off` / `Turn On` (the
   `TOGGLE` / `SET_BRIGHTNESS_TARGET` path).
5. Restart Director: the connection must restore with no manual
   rebind; record whether bind events re-fire (decides whether the
   slow reconcile timer is belt-and-braces or load-bearing).
6. Only if BindMessages fail, run the `via Device`
   (`SendToDevice`/`ExecuteCommand`) fallback variant.

Fill in the results template at the bottom of
[spike/PROCEDURE.md](../spike/PROCEDURE.md) and take the verdict
(`GO` / `GO WITH FALLBACK` / `NO-GO`). Delete both stub instances
when done.

## Building and testing

- `sh c4/scripts/package.sh` builds all three assets; `sh
  c4/scripts/package-cloud.sh` / `sh c4/scripts/package-valve.sh`
  build one split driver each (each re-runs its `bundle.sh`, which
  regenerates the checked-in `driver.lua` — never edit it by hand).
- `lua5.1 c4/tests/loader_cloud.lua` and `lua5.1
  c4/tests/loader_valve.lua` run the per-driver suites in separate Lua
  states (the two bundles must never share one).
- `python -m pytest -q tests/test_c4_lua.py
  tests/test_c4_packaging.py` runs the offline build/packaging gates;
  `stylua --check --config-path c4/stylua.toml` covers style.
