# Unit-0 spike procedure: cloud/valve link + light-proxy round trip

Goal: settle D1 (BindMessages peer-to-peer, else SendToDevice fallback) and D4
(light_v2 switch tile) on a real Director before the split is built. A human
runs this in Composer Pro (or Composer Express for install) and Navigator.
Estimated time: under an hour.

Artifacts:

- `spike/cloud_stub/` — CONTROL provider stub: static manifest link 2001
  (Composer-indexing shim, class `FLOGIC_VALVE`) plus the dynamic test
  link 2002 of the same class, persisted and restored on init. Bind and
  ping over the dynamic `Spike Valve 1` (2002), never the static shim.
- `spike/valve_stub/` — static link consumer (6000) + `light_v2` proxy (5001,
  switch capabilities: dimmer/set_level false, on_off true).
- `spike/cloud_stub.c4z`, `spike/valve_stub.c4z` — packaged drivers.

Lua logs are prefixed `[spike-cloud]` / `[spike-valve]` (Director Lua output
window). Properties referenced below are on each driver's Properties tab.

## 0. Install

1. In Composer, add the `FloLogic Cloud Spike` driver (from
   `spike/cloud_stub.c4z`) and the `FloLogic Valve Spike` driver (from
   `spike/valve_stub.c4z`) to the project room.
2. Confirm both show Driver Version `2026090701` on their Properties tabs.

Expected: both drivers load with no script errors; cloud Link Status reads
`No link (run Add Valve Link)`; valve Link Status reads `Not linked`.

## 1. Create the dynamic binding

1. On the cloud driver, run the `Add Valve Link` programming command
   (or its Composer action button).
2. Check the cloud Lua log for
   `dynamic binding added: id=2002 class=FLOGIC_VALVE`.
3. Open Connections view: a new provider connection named `Spike Valve 1`
   with class `FLOGIC_VALVE` is listed on the cloud driver (alongside the
   static `Valve Link 1 (static)` shim, which you ignore).

Expected: binding id 2002 appears; Binding ID property reads `2002`;
Link Status reads `Waiting for bind`.

## 2. Bind the custom class

1. In Connections view, drag the cloud driver's `Spike Valve 1` output to the
   valve driver's `Cloud Link` input (both class `FLOGIC_VALVE`).
2. Watch both Lua logs.

Expected: both logs print an `OnBindingChanged ... bound=true` line; cloud
Link Status flips to `Bound`; valve Link Status flips to `Bound`; the valve
log prints `sent SPIKE_HELLO on bind` and the cloud log prints
`SPIKE_HELLO from peer; replying SPIKE_IDENTITY`, followed by the valve log
`SPIKE_IDENTITY from cloud valve=spike-valve-1`.

## 3. Ping/pong both directions (multi-KB)

1. Set cloud Ping Bytes to `4096` (default). Run cloud `Ping Peer`.
2. Check the valve log for `SPIKE_PING from cloud seq=1 bytes=4096` and the
   cloud log for `SPIKE_PONG from peer seq=1 bytes=4096`.
3. Confirm the valve Last Ping property and the cloud Last Pong property.
4. On the valve driver, run `Ping Cloud`. Confirm the mirror image: cloud
   log `SPIKE_PING from peer`, valve log `SPIKE_PONG from cloud`.
5. Repeat with Ping Bytes `16384` to prove a larger payload.

Expected: both directions carry the full byte count with matching sequence
numbers; no truncation or script errors. Record the byte counts observed.

## 4. Navigator click (light proxy)

1. In Navigator (or the app), find the valve's light tile. It must render as
   a switch (on/off), not a dimmer slider.
2. Tap it off. Check the valve log for `level -> 0 (DYNAMIC_OFF)` and that
   Light Level reads `0`. The cloud log shows `SPIKE_LEVEL from peer level=0`.
3. Tap it on. Confirm `level -> 100 (DYNAMIC_ON)`, Light Level `100`, cloud
   `SPIKE_LEVEL ... level=100`.
4. In Composer programming, run valve `Turn Off` / `Turn On` (these call
   the level path directly; only a real scene sends TOGGLE /
   SET_BRIGHTNESS_TARGET — test those from a scene if available).

Expected: every tap changes the tile state and the reported
`LIGHT_BRIGHTNESS_CHANGED` tracks it (0 when off, 100 when on). Note
which proxy commands arrived (`DYNAMIC_ON`/`DYNAMIC_OFF` from taps;
test TOGGLE and SET_BRIGHTNESS_TARGET from a scene if available).

## 5. Director restart: persistence + event re-fire

1. Note the current bind state (both `Bound`).
2. Restart Director (or reboot the controller).
3. Immediately check: is the Connections-view link still drawn?
4. Check the cloud log for `restored dynamic binding id=2002` during init,
   before any human action.
5. Record whether either driver logged a fresh `OnBindingChanged ...
   bound=true` line after the restart without touching anything.
6. Without rebinding, run cloud `Ping Peer` again.

Expected: the connection restores automatically (go); the ping works with no
manual rebind (go). The re-fire observation decides D3 reconciliation design:

- Events re-fire: note it; the slow reconcile timer stays as belt-and-braces.
- Events do NOT re-fire: the reconcile timer from `GetBoundConsumerDevices`
  is load-bearing — do not rely on bind events alone.

## 6. Lua reload (update in place)

The self-updater delivers new builds as a Lua reload (`DIT_UPDATING`),
not a Director restart. Runtime bindings likely survive the reload while
both drivers re-run init — verify the cloud re-registers without
orphaning the link.

1. With the link `Bound` from step 2, update the cloud stub driver in
   place (Composer: update/reload the driver without rebooting).
2. Check the cloud log during init for `restored dynamic binding
   id=2002` (fresh re-add) or a single `WARN: restore re-add failed
   (binding may already exist)` (binding survived the reload). Either is
   fine; a loop of re-add failures is not.
3. Without rebinding, run cloud `Ping Peer` again.

Expected: the ping works with no manual rebind (go). If the link goes
dark or the log loops re-add failures, the production restore path must
tolerate already-existing bindings before release (H4).

## 7. SendToDevice-fallback variant

Run this variant only if step 3 or 4 fails (BindMessages never arrive as
`ReceivedFromProxy`), or as a regression pass after the primary path works.

1. Run cloud `Ping Peer via Device`.
2. Confirm the valve log `Device Ping ...` and the cloud log `Device Pong`.
3. Run valve `Ping Cloud via Device` and confirm the mirror image.

Expected: same byte counts and sequence correlation as step 3, arriving via
`ExecuteCommand`. If the primary path failed but this works, D1 switches to
the fallback and units 1-3 use `SendToDevice` + `ExecuteCommand` with
`GetBound*` discovery.

## Verdict

- GO: bind incl. custom class works, multi-KB ping/pong works both
  directions over BindMessages, Navigator tap toggles with correct
  `LIGHT_BRIGHTNESS_CHANGED`, restart restores the binding (re-fire
  noted either way), and Lua reload keeps the link without rebind.
- GO WITH FALLBACK: primary BindMessages fail but the SendToDevice variant
  passes in both directions; restart still restores the connection.
- NO-GO: neither transport delivers peer messages, or the binding does not
  survive restart or reload. Stop and redesign before unit 1.

## Results template

Copy, fill in, and hand back with the logs.

```text
Tester:
Date:
Director version / controller model:
Composer version:

1. Dynamic binding created (id/class as expected): PASS / FAIL
   Notes:
2. Custom-class bind (FLOGIC_VALVE both ends): PASS / FAIL
   Notes:
3a. Cloud -> valve ping bytes observed:        (expected 4096, then 16384)
3b. Valve -> cloud ping bytes observed:
3c. Sequence numbers matched both ways: YES / NO
4a. Tile renders as switch (not slider): YES / NO
4b. DYNAMIC_OFF -> level 0 + LIGHT_BRIGHTNESS_CHANGED 0: PASS / FAIL
4c. DYNAMIC_ON -> level 100 + LIGHT_BRIGHTNESS_CHANGED 100: PASS / FAIL
4d. Proxy commands seen (list):
5a. Connection restored after restart without rebind: YES / NO
5b. Cloud log showed restore line: YES / NO
5c. Bind events re-fired after restart (which driver): CLOUD / VALVE / BOTH / NEITHER
5d. Post-restart ping without rebind: PASS / FAIL
6a. Link survives Lua reload without rebind: YES / NO
6b. Restore/re-add log lines (paste):
7. Fallback variant run: NOT NEEDED / PASS / FAIL
   Device ping bytes observed:

Verdict: GO / GO WITH FALLBACK / NO-GO
Log excerpts (paste the [spike-cloud] / [spike-valve] lines for steps 2-7):
```

## Cleanup

Delete both spike driver instances from the project when done. The stubs use
distinct name/model identities (`FloLogic Cloud Spike`, `FloLogic Valve
Spike`) and never touch the production `FloLogic Valve` driver or its
`flologic_valve.c4z` asset.
