# FloLogic Control4 Driver

Control4 DriverWorks driver for FloLogic Connect valves, ported from the
[Home Assistant integration](../README.md). One driver instance monitors one
valve; add one instance per valve.

Status: **v1, poll-based.** Every poll and every command runs one short-lived
SignalR session (negotiate → websocket → login → fetch/command → close).
There is no persistent connection yet, so updates arrive at the poll interval.

## Layout

```
c4/
  driver.xml          Driver manifest (properties, commands, actions, events).
  driver.lua          GENERATED bundle of src/*.lua — what ships in the .c4z.
  src/
    json.lua          Minimal JSON codec (Lua 5.1 safe).
    model.lua         Valve/account decoding + discovery (port of const/api.py).
    signalr.lua       SignalR JSON-protocol codec + event dispatcher.
    websocket.lua     RFC 6455 client codec + handshake helpers.
    flologic.lua      Cloud session state machine (transport-injected).
    main.lua          Director glue: lifecycle, properties, commands, events.
  scripts/
    bundle.sh         Concatenates src/*.lua into driver.lua.
    package.sh        Builds flologic_valve.c4z for Composer Pro.
  tests/
    run.lua           Standalone suite (mocked transports, scripted server).
    helpers.lua       Test-only SHA1/Base64/fakes/runner (not shipped).
    loader_standalone.lua  Loads everything under a real interpreter.
```

Every `src/*.lua` file is concatenation-safe: it defines globals only, with no
`require`/`return`/top-level execution, and stays within Lua 5.1 (no `\x`
escapes, no bitwise operators, no `string.pack`).

## Packaging and install

```sh
sh c4/scripts/package.sh        # produces c4/flologic_valve.c4z
```

In Composer Pro: add the `.c4z` via the driver search (local file), add one
*FloLogic Valve* device per valve, then set **Email** and **Password**. The
first poll populates **Select Valve**; pick the valve for this site, or leave
it blank for the primary valve. **Valve ID Override** accepts an id/uuid and
wins over the picker when non-blank.

## Properties

Config: Email, Password, Hub URL, Poll Interval (30–3600 s, default 60),
Select Valve (dynamic list), Valve ID Override, Debug Mode.

Read-only telemetry mirrors the Home Assistant sensors: Connection,
Valve Name, Mode, Flow State, Water Flowing, Temperature, Battery Level,
Signal Strength, Current Flow, Home/Away Limit, Bypass Time, Auto Away,
Temp Alert/Shutoff, Pre-Alert, No-Flow Notice, Flow Sensitivity, Shutoff
Countdown, Flow Elapsed, Scheduler Events, Notifications, Available Valves,
Last Update.

Countdown/Elapsed tick locally every 5 s while flowing (no cloud traffic).

## Programming

Commands: Refresh, Refresh Valve List, Set Mode Home/Away/Bypass/Shutoff/
Disabled, Set Home/Away Limit, Set Bypass Time, Set Auto Away, Set Temp
Alert/Shutoff, Set Pre-Alert, Set No-Flow Notice, Set Flow Sensitivity.
Value ranges match the Home Assistant service validation.

Events: Flow Started/Stopped, Water Off Detected/Cleared, Warning
Alert/Cleared, Critical Fault/Cleared, Mode Changed, Advance Shutoff
Warning, Connection Lost/Restored. The first poll only sets the baseline;
nothing fires until a real transition is observed.

## How the cloud session works

`flologic.lua` owns the protocol; `main.lua` injects the transports:

- Negotiate runs over `C4:urlPost` (platform HTTPS with system CA
  verification).
- The websocket runs over a Director-managed TLS TCP connection allocated
  at runtime (`CreateNetworkConnection` + `NetPortOptions` TCP/SSL +
  `NetConnect` on the first free binding in 6100–6199). One binding is
  reused for every session; sessions run serially (a poll never overlaps a
  command — polls skip, commands queue).
- Handshake accept keys use `C4:Hash("SHA1", …)` (probed from SHA1/sha1/
  SHA-1 spellings at startup) and `C4:Base64Encode`; the accept key is
  verified, never assumed.
- The relog token persists encrypted via `PersistSetValue`.

## Tests

```sh
lua5.1 c4/tests/loader_standalone.lua   # real Lua 5.1 (17 tests)
python -m pytest tests/test_c4_lua.py    # same suite via lupa + bundle check
```

The suite covers JSON round-trips and malformed input, mode/flag/countdown
decoding, valve discovery tiers, SignalR framing/dispatch, RFC 6455 vectors
(handshake accept, frame sizes, masking, fragmentation, ping/pong, close),
and full login→fetch and login→command sessions against a scripted fake
SignalR server, including the ValveSent→array fallback, notification-history
retry, auth/timeout/missing-valve failures, and timer/connection cleanup.

## Assumptions and limits

These need a real Director to confirm and are the first suspects if the
driver misbehaves in the field:

- **TLS verification on raw sockets.** Director documents no system CA
  bundle for `NetPortOptions` SSL connections, so the websocket uses
  `VERIFY_MODE none` (the documented default). The negotiate POST still
  verifies. Revisit if Director documents CA handling for sockets.
- **Dynamic TLS connection to a cloud hostname.** `CreateNetworkConnection`
  accepts hostnames per the API docs; the driver relies on that plus
  `GetBindingAddress` reporting unallocated bindings as empty/error (wrapped
  in `pcall`, scanned 6100–6199).
- **urlPost header/argument shape** follows the field-proven
  `urlPost(url, body, headers-table, false, callback)` calling convention
  with the numeric-ticket callback quirk handled.
- **Combo self-proxy searchability** (`<combo>` + self `<proxy>`, no static
  connections) follows the generic_http pattern for connection-less cloud
  drivers.
- **No proxies or Navigator UI.** The driver exposes properties, programming
  commands, and events only — no relay/contact/temperature proxy bindings
  yet.
- **One valve per driver instance**, one session at a time, no push channel
  (poll interval is the freshness bound).

## Porting notes (vs Home Assistant)

- Async/await became an explicit callback state machine; every cloud wait
  has a timeout, and every path closes the connection exactly once.
- Bit flags use arithmetic (`floor(v / flag) % 2`) since Lua 5.1 has no
  bit operations.
- `datetime` parsing converts ISO-8601 to epoch via `os.time` plus the
  controller's measured UTC offset.
- Per-valve scheduler/notification fetches run for the selected valve only
  (the C4 driver never needs the others), and the array probe runs only
  when the selection is missing from the login devices.
