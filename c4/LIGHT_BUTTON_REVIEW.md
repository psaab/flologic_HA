# Control4 valve light-button review

Reviewed: 2026-09-09  
Baseline: `8ad0160`, driver build `2026090829`  
Scope: light-proxy configuration, button handling, relevant commit history,
and offline verification. This document proposes no dimmer functionality.

## Required behavior

The valve is a binary switch:

- **On:** the valve is open, or in any state that is not closed.
- **Off:** the valve is closed.

The current state mapping uses the reported water-off flags or flow state
8 to identify closure. The tile should agree with the Valve Closed contact.
An unavailable or stale observation is an availability problem, not a new
physical valve position.

Control4's light proxy represents the binary display as `100` for on and
`0` for off. These are proxy values, not percentages of valve opening.
There is no intermediate valve position, dimming, or physical ramp.

Likewise, a command named `SET_LEVEL` or `SET_BRIGHTNESS_TARGET` can be a
Control4 mechanism for requesting binary on/off. Its name does not imply
that the valve should become a dimmer. Whether the failing controls send
either command must be established from Director output.

The existing Identify Tile action sends an artificial `50` to mark a tile.
That is display-only diagnostic behavior; it is neither a valid valve
state nor evidence that a button command reaches the driver.

## Assessment

There are confirmed defects in the current button handler, but the exact
cause of the reported installation failure remains unconfirmed without a
trace of a failing press.

The strongest regression introduced in build 0829 is its CPU-time-based
debounce. Missing legacy command coverage and missing button acknowledgment
are separate gaps that predate that regression. Display feedback and
button input have repeatedly been conflated in the release explanations.

## Findings

### 1. CPU-time debounce can discard distinct button presses

In `c4/valve/valve.lua`, `flovalve_on_light` uses `os.clock()` to enforce
`FLOVALVE_BUTTON_DEBOUNCE_S = 0.75`.

Lua 5.1 defines `os.clock()` as CPU time consumed by the program, not
elapsed time. Waiting between presses need not expire this window.
The observed duration on Director will depend on its runtime and process
activity; the code does not implement a reliable 750 ms elapsed interval.
[Lua 5.1 reference](https://www.lua.org/manual/5.1/manual.html#pdf-os.clock).

Evidence:

- An offline check against the unchanged handler sent two toggle clicks
  with two seconds of simulated timer advancement between them. Only one
  valve command was emitted.
- A separate local Lua check waited two actual seconds and measured only
  approximately 0.000049 seconds of CPU time.
- The existing test manually backdates `button_debounce.at`. This proves
  that the comparison can expire, but does not test elapsed-time behavior.

Impact: repeated clicks may appear dead. This can explain failures on
0829, but cannot explain the failures reported before that release.

### 2. The debounce record does not track separate button gestures

The implementation stores one `{ id, at }` record despite describing it
as per-button debounce. A different button replaces that record.

An offline sequence of toggle press, top-button press, and toggle release
emitted three valve commands. The paired toggle release executed again
because the intervening top-button press replaced the debounce record.

Even replacing the clock alone would leave a gesture-pairing problem:
a release arriving outside the window can repeat a toggle already
performed on press. Gesture pairing needs an explicit policy for press,
click release, hold release, and any verified click-only or press-only
senders.

### 3. Required button acknowledgment is absent

The handler receives `BUTTON_ACTION` but does not send a matching
`BUTTON_ACTION` notification back to binding 5001. Brightness updates
are sent separately.

Control4 documents that the driver must echo the button ID and action in
a notification. Without acknowledgment of the pressed state, the proxy
can synthesize another press when it receives a click.
[Control4 button-action contract](https://control4.github.io/docs-driverworks-proxyprotocol/#button-action).

An offline check confirmed that a button press produces no matching
notification. This is a confirmed protocol omission. Its effect on the
reported installation still depends on the actual input sequence.

A button acknowledgment describes gesture handling; it must not be
presented as confirmation that the physical valve moved.

### 4. Legacy `SET_LEVEL` is unhandled

The manifest leaves `supports_target` unset. The handler supports
`SET_BRIGHTNESS_TARGET` and `RAMP_TO_LEVEL`, but not `SET_LEVEL`.

Control4's official light sample implements `SET_LEVEL` with a `LEVEL`
parameter. The newer brightness-target API is enabled through the
`supports_target` capability.
[Official light sample](https://raw.githubusercontent.com/control4/docs-driverworks/master/sample_drivers/light_sample.c4i),
[brightness-target API](https://control4.github.io/docs-driverworks-proxyprotocol/#brightness-target-api).

An offline call with `SET_LEVEL { LEVEL = "0" }` emitted zero cloud
commands. This establishes a compatibility gap, not proof that the
user's particular controls send this command.

If that command appears in a failing press trace, its omission directly
explains the failure. Any eventual handling must remain binary: on/off
only, with malformed or missing values rejected rather than interpreted
as a shutoff request.

### 5. Identify Tile does not test the incoming button path

Commit `8ad0160` states that the 50% mark proved tile taps arrive.
The implementation does not support that inference.

`flovalve_identify_tile` sends `LIGHT_BRIGHTNESS_CHANGED` to the proxy.
It does not exercise `ReceivedFromProxy` or call the light-button handler.

A visible mark proves that this driver can deliver display feedback to
that tile. It does not establish:

- Whether a press reaches the protocol driver.
- Which command the control sends.
- The button ID, action, or level parameters.
- Whether the cloud accepts a resulting valve command.

The mark also cannot, by itself, establish that every other static tile
is an orphan. Other tiles may belong to other valid driver instances.

### 6. Capability explanations in the history are inconsistent

The 0821/0822 release explanations treat `on_off` as fictional or
undocumented; 0823 restores it and attributes the dead tile to its absence.
Control4 documents `on_off` as controlling direct on/off commands in
Composer. This supports declaring it, but does not establish the broader
claims about Navigator rendering in the release notes.
[Control4 on/off capability](https://control4.github.io/docs-driverworks-proxyprotocol/#on_off).

Composer's Control tab, phone Navigator controls, and keypad/remote
gestures should be examined separately. Their incoming commands must not
be assumed identical merely because they all operate a binary switch.

### 7. Current diagnostics cannot establish the claimed action sequence

With Debug Mode enabled, `ReceivedFromProxy` logs the light command name,
but not its parameters. The existing log therefore cannot distinguish a
press from a release when both are named `BUTTON_ACTION`.

Unknown light commands warn, and local command rejection updates
`Last Command`. Those are useful diagnostic boundaries. A future trace
should include only the relevant command parameters, rather than dumping
unrelated cloud payloads or credentials.

## Relevant commit sequence

All 92 commit messages reachable through the local refs were reviewed.
Several older changes appear twice across refs. The most relevant sequence
is summarized below; descriptions are historical claims, not independent
confirmation of Director behavior.

| Build | Commit | Change and review implication |
| --- | --- | --- |
| 0820 | `90cb374` | Makes switch state follow closure. This matches the required binary behavior. |
| 0821 | `2c2171a` | Changes brightness notification vocabulary. Addresses display reporting. |
| 0822 | `547f873` | Repairs proxy connection type and state-query handling. Addresses proxy routing and display initialization. |
| 0823 | `cf5b2c7` | Restores switch capabilities and adds more input commands. Still omits `SET_LEVEL` and button acknowledgment. |
| 0824 | `f763552` | Adds command-name diagnostics. Parameters remain absent. |
| 0825 | `5a7f435` | Adds Identify Tile and Proxy Bound diagnostics. These do not prove button delivery. |
| 0826 | `95f9b41` | Fixes missing timer repeat flags in Identify. |
| 0827 | `2742741` | Fixes zero-delay timer use in Identify. |
| 0828 | `482706d` | Replaces timed Identify flashing with a persistent display mark. |
| 0829 | `8ad0160` | Broadens button action handling and adds the defective CPU-time debounce. Its stated input-path evidence is insufficient. |

Earlier login, update installation, package naming, and cloud-link repairs
matter to installation health, but do not establish which command the
failing light controls send.

## Verification performed

The original 54 valve tests pass. Four additional checks were loaded in
memory against the unchanged source and all four failed:

| Additional check | Expected | Observed |
| --- | --- | --- |
| Two toggle clicks separated by simulated idle time | Two commands | One command |
| Two interleaved presses followed by the first button's paired release | Two commands | Three commands |
| `SET_LEVEL` with `LEVEL = "0"` | One close command | No command |
| Button press acknowledgment | Matching `BUTTON_ACTION` notification | No notification |

These are offline results using the repository's fake Director/cloud
environment. They do not emulate a complete light proxy or prove the
command vocabulary emitted by a particular installed Director version.

Temporary implementation and test edits made during the initial
investigation were reverted. This review does not retain code changes,
change driver versions, rebuild packages, or publish a release. No live
controller installation or physical valve operation was performed.

## Evidence needed from Director

Record the running valve-driver version and identify the failing surface:
Composer Control tab, phone Navigator, or keypad/remote. During an intended
normal operation, capture a failing press and its corresponding release,
including the binding ID, command name, and relevant parameters.

Interpret the result in this order:

| Observation | Meaning / next boundary to inspect |
| --- | --- |
| Display updates but no incoming command | Display feedback works; input routing remains unproven. |
| Incoming `SET_LEVEL`, followed by ignored-command warning | Confirms the missing legacy handler affects this control. |
| Incoming `BUTTON_ACTION`, followed by debounce output | Confirms the debounce path is suppressing that action. |
| Incoming action, then `Last Command` says not linked, no state, or not available | Input arrived; the local command gate refused it. |
| `Last Command` says sent | The driver attempted cloud delivery; inspect acknowledgment and observed valve state next. |
| Acknowledgment without the expected physical state | Acceptance alone is insufficient; inspect subsequent authoritative state. |

Do not use an Identify mark, an optimistic tile change, or a passing
mock-based test as proof of physical valve operation. The acceptance
criterion is reliable binary on/off control with display feedback that
reconciles to the reported closed/not-closed state.
