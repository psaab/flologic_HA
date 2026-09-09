# FloLogic tile taps: current DriverWorks SDK and OSS comparison

Reviewed 2026-09-09. Committed FloLogic baseline: `7310b4f`, build
`2026090901`. During this review, concurrent working-tree changes for
`2026090902` appeared. Those changes were inspected separately, not authored
or tested on Director by this review.

This supersedes the diagnostic priorities in [the 0829 review](LIGHT_BUTTON_REVIEW.md).
It does not change the valve's binary behavior: **on means not closed;
off means closed**. The proxy's 100/0 representation is not valve dimming.
Only documentation was changed in this pass.

## Principal finding: inspect proxy availability before button dispatch

The current SDK explicitly says that an offline light has its UI
functionality disabled. It also says the proxy defaults to online for
backward compatibility. Thus, an actually offline proxy explains disabled
controls; simply omitting an online notification does not prove that the
proxy became offline. [SDK online-state contract][sdk-online].

This is a much better fit for **the display receives updates but touching
the tile produces no incoming Lua command** than changing press/release
handling. A handler cannot repair a command the UI never sends.

At committed baseline 0901, FloLogic neither sends `ONLINE_CHANGED` nor
answers `GET_CONNECTED_STATE`. Its Composer `Connection` property and
`Proxy Bound` property describe different facts. Neither establishes the
light proxy's own availability.

The concurrent 0902 patch adds an online notification at late initialization
and in response to `GET_CONNECTED_STATE`. Its source comment reports that a
field `GET_SETUP` result contained `ONLINE_CHANGED=False` and that sending
online restored operation. **That is reported field evidence in the patch,
not a Director observation independently obtained during this review.**

If the reported before/after observation is accurate, it strongly supports
proxy availability as the immediate cause of the dead tile. Preserve that
raw observation and a successful incoming tap trace with the release record.

Two qualifications remain:

- Why was this particular proxy offline, given the documented online
  default? The reviewed sources do not establish the originating event.
- The draft reports online unconditionally. That may re-enable controls,
  but it does not express whether the selected valve is linked, observed,
  available, or stale. The intended availability policy needs to be explicit.

## Sources actually inspected

The old `control4/docs-driverworks` default branch is a relocation notice.
The current SDK README directs Light V2 developers to a dedicated
`snap-one/docs-driverworks-proxyprotocol-lightv2` reference. Earlier research
relied too heavily on the older combined Control4 documentation page.
[SDK entry point][sdk-readme].

Source repositories were cloned into `/tmp/flologic-light-references` for
inspection. No external driver code was copied into FloLogic.

| Source | Revision inspected | Relevant files | License / role |
| --- | --- | --- | --- |
| Snap One DriverWorks SDK | `36076bbd4c86066aed4c3887dc9a8fdbc0e2e799` | README, current training light example, older `light_sample.c4i` | Official SDK reference; not classified here as OSS |
| Snap One dedicated Light V2 reference | `9a439bc0a73c849e627386016ba7c76270517e46` | Online notification, setup query, dynamic on/off, target command and capability documentation | Official protocol specification |
| Finite Labs ESPHome | `634680ba428685b23f13205793372039704f39d3` | `drivers/esphome_light/driver.lua`, `driver.xml` | AGPL-3.0; real light integration with binary and dimmable branches |
| Black Ops Drivers HyperHDR | `1ce3839a6cc0015d559b98fe0eac56ff6f1b78ac` | `driver.lua`, `driver.xml`, constants | MIT; lighting integration with connection lifecycle and button echo |
| Jagdeep Matharu Kasa Cloud | `e30eb8fae3b244df0da99b21ded3cf70bc44b6ea` | `driver.lua`, `driver.xml` | MIT; switch/dimmer implementation previously cited by FloLogic |

Repository availability and implementation detail are evidence of design
patterns, not proof that every path works on the user's Director. No OSS
driver was installed or operated during this review.

## Comparison of the actual input and feedback paths

| Behavior | FloLogic 0901 | Official examples | ESPHome | HyperHDR | Kasa |
| --- | --- | --- | --- | --- | --- |
| Explicit proxy online notification | Absent | Training example has a SetOnline action | On connection/state lifecycle | On connect/disconnect | Not found in inspected driver |
| `GET_CONNECTED_STATE` response | Absent | Older light sample answers it | Implemented | Implemented | Not found |
| `SYNCHRONIZE` state response | Absent | Current training example implements it | Not relied on in this comparison | Not relied on in this comparison | Uses other query handlers |
| `DYNAMIC_ON` / `DYNAMIC_OFF` | Implemented | Documented in current SDK | Implemented | No explicit handlers found | No explicit handlers found |
| `SET_BRIGHTNESS_TARGET` | Accepts target, `LEVEL`, or `LIGHT` | Current training example handles target | Implemented | Implemented | Implemented |
| `SET_LEVEL` | Added in 0831 | Older sample implements it | Implemented | Not used as evidence here | No explicit handler found |
| Button acknowledgment | Echo plus immediate synthetic hold-release after press | Required echo in SDK | Echoes the received action | Echoes the received action | No echo found |
| Binary operation | Closed/not-closed | Sample is a light demonstration | Explicit non-dimming branch | Primarily brightness-oriented | `Is Dimmer` distinguishes behavior |

### Official training example: availability and synchronization are separate

The SDK's `3 - handle navigator.lua` demonstrates three distinct pieces:
an action to report online/offline, a `SYNCHRONIZE` response returning current
brightness, and a `SET_BRIGHTNESS_TARGET` handler. This supports treating
availability, displayed state, and requested operation as separate contracts.
[Training source][sdk-training].

FloLogic's current query list omits `SYNCHRONIZE`. That is a concrete
compatibility gap relative to this example, but not independently proven to
cause the reported dead taps. Its existing proactive state reports can
still update a tile without this query handler.

The sample includes dimmer ramp demonstrations. Those are irrelevant to
FloLogic's required binary behavior and should not be copied into the valve.

### ESPHome: useful lifecycle reference, including binary lights

ESPHome answers `GET_CONNECTED_STATE` from whether it has current state.
It sends online on the first valid update and does so before dynamic
capabilities. Its disconnect handling reports offline. It implements both
dynamic on/off and legacy level dispatch. Its button handler echoes the
received action without FloLogic's immediate extra release.
[ESPHome implementation][esp-lua].

Its XML starts with dimming capabilities enabled, then discovery changes
capabilities; the code sets `supports_target` according to dimming support.
This is not a manifest to copy wholesale for a binary valve.
[ESPHome manifest][esp-xml].

### HyperHDR: explicit availability and one matching button echo

HyperHDR's connection callbacks publish both online and offline. Its
`GET_CONNECTED_STATE` response uses `hyperhdr:isConnected()`. After handling
a supported button action, it sends one notification with that button and
action. It does not manufacture an immediate release after every press.
[HyperHDR implementation][hyper-lua].

Its ramp and color functions serve its own hardware. The transferable
lessons are connection-state reporting and the command/notification boundary,
not dimming the valve.

### Kasa: useful evidence, but not a complete proxy contract

Kasa's dispatcher comment distinguishes phone-app target commands from
remote/keypad button actions. It acts on button action 2. Its manifest
enables `supports_target`; its code has no explicit online notification or
button echo. [Kasa dispatcher][kasa-lua], [Kasa manifest][kasa-xml].

This matters because previous FloLogic commits cited Kasa as proof of a
complete working switch configuration. Kasa cannot simultaneously establish
that every omission is correct and that every other driver must add it.
Its missing availability handling may coexist with the SDK's online default.
Its lack of button echo does not override the documented requirement.
[SDK button-action contract][sdk-button].

## Corrections to earlier conclusions

### Disabling `supports_target` does not imply taps must send `SET_LEVEL`

The current SDK defines **two payload forms of `SET_BRIGHTNESS_TARGET`**:
the target form when the capability is enabled and `LEVEL` when disabled.
The command can remain the same. The previous review overstated the
connection between the unset capability and the missing legacy handler.
[SDK target-command definition][sdk-target].

Adding `SET_LEVEL` broadens compatibility and is already present in 0901.
It is not established as the cause of the original failure. FloLogic's
current parser accepts both documented brightness forms, mapping requests
to binary actions.

### Navigator commands and protocol-driver callbacks are different layers

The current dynamic-on documentation describes Navigator interaction and
fallback to the On preset for drivers without dynamic-on support. A UI's
operation name is therefore not enough to infer what reaches Lua.
[SDK dynamic-on definition][sdk-dynamic].

The SDK training dispatcher also distinguishes `ExecuteCommand`, targeting
the protocol driver, from `ReceivedFromProxy`, used for UI/proxy commands.
Testing a Composer device-specific Open Valve action does not test the
Navigator-to-proxy path. [Training dispatcher][sdk-training].

### An arbitrary immediate release is not established by the references

Build 0831 added an echo, but `flovalve_ack_button` also sends action 0
immediately after acknowledging action 1. ESPHome and HyperHDR echo the
received action. Their code does not support the claim that all press-only
senders require this extra notification.

The protocol's reason for acknowledging a press is to let the proxy track
that pressed state. An immediate extra release may undermine that state
when a real click follows. This is a review concern requiring a real
gesture trace, not a claimed reproduction of Director's internal behavior.

### Local gesture state still remains latched after release

In committed 0901, a paired action 2 is ignored without clearing the stored
action 1. A later click-only action 2 on that button remains suppressed
until another press changes the path. An isolated offline dispatch check
against `git show 7310b4f:c4/valve/valve.lua` confirmed:

| Input sequence | Command attempts | Stored button state |
| --- | --- | --- |
| Press, paired click-release, later click-only release | 1 | Still `1` |

The command sender and proxy sender were stubbed, so no valve operation
occurred. This demonstrates a mixed-sender gesture defect. It cannot explain
a tile that never sends any command into Lua.

## Read-only Director evidence that resolves the primary question

Use the **actual light proxy device ID**, not the protocol driver ID and
not binding ID 5001, to inspect the proxy's setup:

```lua
-- Replace LIGHT_PROXY_DEVICE_ID with the verified project device ID.
print(C4:SendUIRequest(LIGHT_PROXY_DEVICE_ID, "GET_SETUP", {}))
```

`GET_SETUP` returns the proxy configuration consumed by UIs, including an
online field in the documented example. `SendUIRequest` addresses a device
ID and requires an empty parameter table when no parameters are needed.
[SDK setup query][sdk-setup], [DriverWorks API][sdk-ui].

Capture that response alongside the running version and the existing debug
output from an intended normal tap. Reading setup does not move the valve.
Do not change proxy availability or send valve commands as part of this
read-only evidence collection.

| Evidence | Interpretation |
| --- | --- |
| Proxy setup is offline; tap produces no ingress | Matches the SDK's disabled-UI behavior; examine availability lifecycle first. |
| Proxy setup is online; tap produces no ingress | Examine the selected proxy instance and UI routing; button-handler edits are still downstream. |
| Target command arrives with `LEVEL` | Valid compatibility form, not proof of a dimmer or a malformed command. |
| Button action arrives | Evaluate press/click/release pairing and acknowledgment using the actual sequence. |
| Driver logs sent, then cloud rejection or no confirmation | UI delivery worked; inspect cloud command/state handling. |

For a subsequent availability fix, record before/after setup responses and
the first successfully received tap. Also verify initialization with no
valve state, disconnect/reconnect, reload, and Navigator reopen. These checks
test the lifecycle rather than a single successful display notification.

## Status of the concurrent 0902 patch

The patch observed during this review adds `ONLINE_CHANGED` and a
`GET_CONNECTED_STATE` handler, which address the principal missing lifecycle
behavior found by the comparison. It uses the string `"True"`; the SDK
declares a boolean and the inspected examples use Lua booleans. The exact
capitalization of XML returned by `GET_SETUP` is not proof that the outgoing
Lua value must be a capitalized string.

The patch's unconditional online report should be described as its actual
policy, rather than as measured device availability. The reference drivers
demonstrate reporting connection/state transitions. A valve implementation
must decide how freshness and link state affect availability while preserving
the user's closed/not-closed display semantics.

This review did not author, revert, install, or certify that concurrent
patch. It documents why its direction is relevant and which assertions
remain unverified.

[sdk-readme]: https://github.com/snap-one/docs-driverworks/blob/36076bbd4c86066aed4c3887dc9a8fdbc0e2e799/README.md
[sdk-button]: https://github.com/snap-one/docs-driverworks-proxyprotocol-lightv2/blob/9a439bc0a73c849e627386016ba7c76270517e46/source/includes/10_light_v2_commands/_1-BUTTONACTION.md
[sdk-online]: https://github.com/snap-one/docs-driverworks-proxyprotocol-lightv2/blob/9a439bc0a73c849e627386016ba7c76270517e46/source/includes/35_Light_v2_protocol_notifications.5_Light_v2_protocol_notifications/_15-ONLINECHANGED.md
[sdk-target]: https://github.com/snap-one/docs-driverworks-proxyprotocol-lightv2/blob/9a439bc0a73c849e627386016ba7c76270517e46/source/includes/10_light_v2_commands/_1.5-SETBRIGHTNESSTARGET.md
[sdk-dynamic]: https://github.com/snap-one/docs-driverworks-proxyprotocol-lightv2/blob/9a439bc0a73c849e627386016ba7c76270517e46/source/includes/10_light_v2_commands/_1.3-DYNAMICON.md
[sdk-setup]: https://github.com/snap-one/docs-driverworks-proxyprotocol-lightv2/blob/9a439bc0a73c849e627386016ba7c76270517e46/source/includes/10_light_v2_commands/_16.5-GETSETUP.md
[sdk-training]: https://github.com/snap-one/docs-driverworks/blob/36076bbd4c86066aed4c3887dc9a8fdbc0e2e799/driver_development_training/sample_light_driver/sample_light_driver/3%20-%20handle%20navigator.lua
[sdk-ui]: https://snap-one.github.io/docs-driverworks-api/#senduirequest
[esp-lua]: https://github.com/finitelabs/control4-esphome/blob/634680ba428685b23f13205793372039704f39d3/drivers/esphome_light/driver.lua
[esp-xml]: https://github.com/finitelabs/control4-esphome/blob/634680ba428685b23f13205793372039704f39d3/drivers/esphome_light/driver.xml
[hyper-lua]: https://github.com/black-ops-drivers/control4-hyperhdr/blob/1ce3839a6cc0015d559b98fe0eac56ff6f1b78ac/driver.lua
[kasa-lua]: https://github.com/jagdeep85/control4-kasa-cloud-driver/blob/e30eb8fae3b244df0da99b21ded3cf70bc44b6ea/driver.lua
[kasa-xml]: https://github.com/jagdeep85/control4-kasa-cloud-driver/blob/e30eb8fae3b244df0da99b21ded3cf70bc44b6ea/driver.xml
