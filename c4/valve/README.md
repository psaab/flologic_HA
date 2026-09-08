# FloLogic Water Valve (per-valve companion driver)

One driver instance per physical valve. This driver holds no credentials
and runs no poll loop: it binds to one `FloLogic Cloud` slot, shows that
valve's state, exports seven contact outputs for programming, and appears
in the app as a switch that shuts water off or turns it on when tapped.

## Install (one copy per valve)

1. Install and configure `FloLogic Cloud` first (account email/password,
   confirm `Valve Count`). The cloud driver exposes one named
   `FLOGIC_VALVE` connection per valve it discovers.
2. Add one `FloLogic Water Valve` driver instance per physical valve.
3. In Composer Connections, bind each valve instance's **FloLogic Link**
   (600) to its valve's slot on the cloud driver.
4. On bind the valve sends `FLOGIC_HELLO`; the cloud replies with that
   slot's valve id and starts pushing state. `Valve ID` / `Valve Name`
   fill in, `Connection` goes `Online`, and the app tile follows the
   valve (on = water may flow, off = shut off). The tile click needs
   Director OS 3.3.2+ (`DYNAMIC_ON`/`DYNAMIC_OFF`).

No per-instance configuration is needed or available: the binding selects
the valve (VALVE-U4 below). To move a valve instance to a different
physical valve, rebind its FloLogic Link to the other slot; the next
handshake re-learns the identity.

## What you see

- **App tile.** A switch (light proxy, on/off only — no dimmer). Tapping
  it sends Close (off) or Open (on, restoring the last non-shutoff mode,
  default Home) to the cloud. The tile reports optimistically; contacts,
  properties, and events always follow the cloud's next state push.
- **Contacts 101–107** (all `CONTACT_SENSOR`, `CLOSED` = named state
  true; first push reports steady `STATE_*` so binding never fires
  transition programming):
  101 Valve Closed (any shutoff flag), 102 Away Mode (away flags),
  103 Flowing, 104 Leak Detected, 105 Warning Active, 106 Critical Fault,
  107 Valve Online.
- **Events.** Flow Started/Stopped, Water Off Detected/Cleared, Warning
  Alert/Cleared, Critical Fault/Cleared, Mode Changed, Connection
  Lost/Restored. The first state push sets the baseline and fires
  nothing. There is no Advance Shutoff Warning event: the link slice
  carries no flow-start timestamp, so the valve cannot compute it.
- **Commands.** Open Valve, Close Valve, Toggle, Set Mode
  Home/Away/Bypass/Shutoff/Disabled, the limit commands (home/away
  limits, bypass time, auto away, temp alert/shutoff, pre-alert,
  no-flow notice, flow sensitivity), Refresh (ask the cloud for state
  now), plus the report-only Check for Update and the Composer install
  commands tracking the `flologic_water_valve.c4z` asset.
- **Link problems.** `Connection` shows `Not linked` (with the last
  update time) when the binding drops and `Degraded` when the cloud sends
  a digest-only snapshot. Last-known contacts and display stay put —
  programming never flaps on a link outage — and commands issued while
  unlinked are dropped with a `Last Command` note instead of crashing.

## VALVE-U4: no valve selector on the valve driver

The monolith picked one valve via the `Select Valve` picker with a `Valve
ID Override`. The valve driver deliberately has neither:

- Considered: (a) keep an editable Valve ID property for manual pinning,
  (b) keep a picker fed by the cloud, (c) drop both and let the binding
  plus the handshake decide.
- Decided: (c). An editable id would bypass handshake authorization (the
  cloud drops commands it cannot attribute to its slot map); a picker
  would duplicate the cloud's discovery and could disagree with it. Valve
  targeting comes exclusively from the Composer binding plus the
  handshake-verified identity. `Valve ID` / `Valve Name` are read-only
  displays; the persisted id is continuity only — it travels solely as
  a `FLOGIC_FROM` sender hint on the fallback path, which the cloud
  re-validates — and every bind re-handshakes from scratch (plan D3).

## Link action set (valve → cloud `FLOGIC_COMMAND` bodies)

Mode actions (no params): `mode_home`, `mode_away`, `mode_bypass`,
`mode_shutoff`, `mode_disabled`. Value actions (numeric `value` param):
`home_limit`, `away_limit`, `bypass_time`, `auto_away`, `temp_alert` /
`temp_shutoff`, `pre_alert`, `noflow_notice`, `flow_sensitivity`. The
cloud revalidates ranges and NACKs anything unknown; the valve surfaces
acks/nacks in `Last Command` and never applies state on ack alone — only
a `FLOGIC_STATE` push moves display, contacts, or events.

## Building and testing

- `sh c4/valve/bundle.sh` regenerates the committed `driver.lua`
  concatenation (`json` + `model` + `update` + `flologic_link` +
  `valve.lua`). Never edit `driver.lua` by hand.
- `lua5.1 c4/tests/loader_valve.lua` runs this driver's suite in its own
  Lua state (plan D8: bundles never share a state).
- `stylua --config-path c4/stylua.toml c4/valve/valve.lua c4/tests/valve.lua`
