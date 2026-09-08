# FloLogic Cloud driver (account coordinator)

One `FloLogic Cloud` instance owns the FloLogic account: credentials, a
single poll loop, discovery, and one dynamic CONTROL provider binding per
valve (dynamic 2002–2016 first, static 2001 `Valve Link 16` overflow-last, class `FLOGIC_VALVE`). Each `FloLogic Water Valve`
driver binds to one of those slots and shows/controls that valve. Valve
drivers hold no credentials and never talk to the cloud directly.

Protocol contract: [`../shared/flologic_link.md`](../shared/flologic_link.md)
(normative code: [`../shared/flologic_link.lua`](../shared/flologic_link.lua)).

## Install

1. In Composer, add one `FloLogic Cloud` driver (from
   `flologic_cloud.c4z`) to the project.
2. Set `Email`, `Password` (and `Hub URL` only if FloLogic moves it).
3. Wait one poll (`Poll Interval`, default 60 s) or run the `Refresh`
   command. `Valve Count` / `Available Valves` list the account inventory.
4. Add one `FloLogic Water Valve` driver per valve (from
   `flologic_valve.c4z`).
5. In Connections view, bind each valve driver's link input to the named
   cloud slot for that valve. The valve handshakes (`FLOGIC_HELLO` →
   `FLOGIC_IDENTITY`) and starts receiving state.
6. Program against the valve drivers (contacts, events, commands), not the
   cloud driver. The cloud driver exposes no contacts and no app tile.

## How it works

- **One poll serves N valves.** Each poll opens a single cloud session,
  takes the authoritative inventory, reconciles slot bindings (slot 2001
  is the static manifest link, 2002-2016 dynamic; new
  valves take the lowest free dynamic slot (static 2001 only overflows at 16 valves), reusing a departed slot only once
  its binding is explicitly observed unbound; removed valves mark their
  slot unavailable without deleting the bound slot), then fans one
  `FLOGIC_STATE` slice out per bound slot.
- **Slots persist across restarts.** The slot→valve map is persisted on
  every change and the bindings are re-created on init, so Composer
  connections survive Director restarts. A slow reconcile timer
  (`GetBoundConsumerDevices`, 10 min) re-discovers bound state because
  restart-restored connections may not re-fire bind events.
- **Every bind re-handshakes.** The valve sends `FLOGIC_HELLO`, the
  cloud replies with that slot's valve id, and unmapped slots stay
  silent. The persisted valve id is continuity only: it travels solely
  as a `FLOGIC_FROM` sender hint on the fallback path, where the cloud
  re-validates it against the slot map before acting on anything.
- **Commands are authorized per slot.** A valve's `FLOGIC_COMMAND` runs
  only when its slot maps to an available valve; the cloud answers
  `FLOGIC_CMD_ACK` / `FLOGIC_CMD_NACK` echoing the same `cmd_id`,
  followed by a post-command refresh (on failure too, so the tile
  converges to the true state). Success races the hub's confirmation
  event against inventory verification, so applied commands ack even
  when the event never arrives. Valve-tagged jobs share
  one FIFO queue (cap 8); polls drain first, as in the monolith.
- **Circuit breaker.** Five consecutive session failures open the breaker
  for a 5-minute cooldown (`Connection` shows the backoff countdown) so a
  dead cloud or bad credentials never hot-loop logins. One success closes
  it. Logical rejections (unknown valve, rejected write) never feed it.
- **Transport fallback.** Link sends use `SendToProxy` BindMessages; when
  the proxy send raises, the cloud falls back to `SendToDevice` at each
  bound consumer (plan D1). Fallback receives arrive via
  `ExecuteCommand`, which names no sender, so the valve attaches its
  persisted valve id as an additive `FLOGIC_FROM` hint (ignored by the
  link parser); unattributable traffic is dropped.
- **Self-update.** Report-only GitHub checks plus Composer install, same
  as the monolith, but tracking the `flologic_cloud.c4z` asset. Both new
  drivers share one lockstep version number.

## CLOUD-U6: no per-valve selection on the cloud driver

The monolith picked one valve via the `Select Valve` picker with a `Valve
ID Override`. The cloud driver deliberately has neither:

- Considered: (a) keep the picker as a "primary" valve, (b) keep the
  override for manual pinning, (c) drop both.
- Decided: (c). A picker would reintroduce single-valve semantics and
  contradict fan-out; an override would bypass handshake authorization.
  Valve targeting comes exclusively from discovery plus the
  handshake-verified slot map. Changing `Email` therefore only clears the
  relog token (no picker/override to reset); the next poll rebuilds the
  map from the new account.

## Migrating from the monolith (`FloLogic Valve`)

Installed monoliths keep working, but their updater matches the valve
package by filename and will offer it as an update: do NOT install it
over a monolith instance — it is a different driver, not an upgrade.
Migration is manual; there is no auto-migration (identities, bindings,
and programming all differ):

1. On a maintenance window, note the monolith's account, selected valve,
   and programming (events, contacts 101/102, commands).
2. Delete the monolith driver instance from the project. (Keep the old
   `.c4z` file: old release tags still carry it for rollback.)
3. Add `FloLogic Cloud`, configure the account, and confirm `Valve
   Count`.
4. Add one `FloLogic Water Valve` per valve and bind each to its slot.
5. Rebuild programming on the valve drivers: seven contacts
   (101–107), per-valve events, and mode/limit commands. Contact ids
   101/102 and the event names match the monolith (except the dropped
   Advance Shutoff Warning), but bindings, parameters, and contexts
   differ — review every programming line.
6. Delete the monolith `.c4z` from the controller file store only after
   the new drivers report `Online` and the app tile toggles correctly.

Do not install the monolith `.c4z` and the new `.c4z` files as if they
were upgrades of each other. Composer identities (names, models,
proxies) are fully distinct, but the valve package intentionally reuses
the legacy `flologic_valve.c4z` asset filename — so monolith updaters
will offer it, and installing it over a monolith instance is
unsupported. Migrate manually instead.

## Link action set (valve → cloud `FLOGIC_COMMAND` bodies)

Mode actions (no params): `mode_home`, `mode_away`, `mode_bypass`,
`mode_shutoff`, `mode_disabled`. Value actions (numeric `value` param,
ranges mirror the monolith): `home_limit` (1–10080),
`away_limit` (0–10080, fractional), `bypass_time` (1–10080),
`auto_away` (1–8760), `temp_alert` / `temp_shutoff` (−50–150),
`pre_alert` (1–10080), `noflow_notice` (1–604800),
`flow_sensitivity` (0–1000, fractional). Anything else is NACKed with
`unknown-action` / `bad-param:value`.

## Building and testing

- `sh c4/cloud/bundle.sh` regenerates `c4/cloud/driver.lua` (checked in;
  never edit by hand).
- `lua5.1 c4/tests/loader_cloud.lua` runs the cloud suite in its own Lua
  state (two bundles must never share a state).
- `stylua` with `c4/stylua.toml` before bundling.
