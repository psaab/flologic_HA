# Control4 conventions and review notes

Reviewed against the public FiniteLabs repository inventory on 2026-09-07.
All 19 repositories were cloned and their file trees inventoried. The source
review focused on the shared driver template, its Director handlers, timers,
HTTP/WebSocket code, build/test tooling, and relevant connection/lifecycle
paths in the driver suites. This is not a line-by-line audit of every vendored
cryptographic library, protocol implementation, or unrelated website.

## Patterns applied here

| Reference | Lesson | FloLogic change |
| --- | --- | --- |
| [Driver template](https://github.com/finitelabs/control4-driver-template) example driver, shared handlers, Makefile and test shim | Keep Director callbacks small, initialize deliberately, format consistently, and test host contracts | Startup guard, Composer `LUA_ACTION` dispatch, timed debug, Lua 5.1 adapter tests, checked-in StyLua configuration |
| [Schluter](https://github.com/finitelabs/control4-schluter) account driver | Retire old asynchronous work before changing credentials; stale responses must not overwrite current state | Session identity checks, cancellation before reconfiguration, cleared relog token and event baseline |
| [MQTT](https://github.com/finitelabs/control4-mqtt) broker connection callbacks | Compare callback owner with the active client, including disconnect paths | Ignore retired session results and unrelated network callbacks; hold closing bindings until OFFLINE |
| [Hatch](https://github.com/finitelabs/control4-hatch) connection module | Arm a connection deadline before opening a socket and explicitly tear down owned timers | Whole-session and upgrade deadlines; full cancellation on destruction |
| [InfluxDB](https://github.com/finitelabs/control4-influxdb) lifecycle and buffering | Bound background work and define shutdown ownership | Bounded command queue with visible overflow rejection; no silent removal of an earlier shutoff |
| Template HTTP/logging modules | Logs must remain useful without exposing credentials | No account email in login traces or raw undecodable SignalR payloads; masked password property |
| Template packaging tools | Build output must match reviewed source and metadata | Exact package-content checks, version consistency, packaged CA license |

These are independently implemented design patterns. No FiniteLabs source
files were imported. Its drivers commonly carry AGPL-3.0 licensing; adopting
an entire library would require a separate licensing and dependency decision.

The raw WebSocket code is a reference, not an authority for every TLS choice.
Hatch explicitly disables peer verification for its deployment. FloLogic sends
account credentials over this connection, so it uses a packaged CA bundle and
peer verification instead. See the [network validation limits](README.md#networking-and-validation-limits)
and the [official API](https://control4.github.io/docs-driverworks-api/).

## Style for this driver

- Use Lua 5.1 syntax, two spaces, Unix newlines, double-quoted strings, and
  120-column formatting. Run StyLua with `c4/stylua.toml` before bundling.
- Use local helpers and state owned by the relevant session. Reserve global
  names for the existing module tables and Director entry points. Retain this
  repository's snake_case naming rather than mixing it with another template's
  camelCase names.
- Document public module contracts, units, callback signatures, and ownership.
  Comments should explain ordering constraints and protocol decisions.
- Register response handlers before transmitting requests. Settle each request
  once, cancel its work on completion, and reject results from old sessions.
- Never block Director with sleeps or synchronous HTTP. Bound socket, message,
  and queue growth. Keep retries separate from physical-control writes.
- Treat discovery inventory as authoritative. Use stable IDs for routing;
  names and list positions are presentation only. Preserve unavailable targets.
- Keep requested state separate from observed state. Cloud acknowledgement
  does not justify a physical state change or a restored-connection event.
- Keep protocol tests independent of Director, then test the Director adapter
  itself with realistic callback signatures and cancellation behavior.
- Rebuild generated artifacts together. Verify XML version, visible version,
  bundled Lua, trust material, and ZIP entries before committing.

## Larger improvements to consider next

1. **An account coordinator with valve companions.** Schluter, Hatch, MQTT,
   and ESPHome show this separation. A single FloLogic account connection
   could feed multiple valve drivers, avoiding repeated logins and duplicated
   polling. It requires persistent SignalR reconnection, binding migration,
   and per-valve routing tests; it is an architectural change, not a style edit.
2. **Native proxies and programming variables.** Use appropriate supported
   relay/contact/sensor proxies and explicit availability feedback instead of
   inventing Navigator commands. Validate each proxy contract against Control4
   documentation and actual Composer behavior before adding it.
3. **Persistent push plus reconciliation.** Once an account coordinator owns
   the connection, retain push updates, reconnect with bounded backoff, and
   periodically reconcile the full inventory. Do not retry uncertain writes.
4. **Controller acceptance tests.** Exercise certificate handling, repeated
   connect/disconnect, reload and removal, credential edits, unavailable valves,
   physical command confirmation, and multiple instances on OS 3.3+.

## Reference snapshots

The following commits pin the inventory used for this review. Driver-specific
source paths above were reviewed selectively; support-library and website
entries establish scope and provenance, not a claim of a full source audit.

| Repository | Commit |
| --- | --- |
| [control4-driver-template](https://github.com/finitelabs/control4-driver-template) | [2a26353a78a5](https://github.com/finitelabs/control4-driver-template/tree/2a26353a78a51a03506ddb5e905a4b7a4e5cc4a9) |
| [control4-esphome](https://github.com/finitelabs/control4-esphome) | [662dc887e7f8](https://github.com/finitelabs/control4-esphome/tree/662dc887e7f864eb11343b0c9a385f35d6056dde) |
| [control4-finite-labs-essentials](https://github.com/finitelabs/control4-finite-labs-essentials) | [3587b7b49a0c](https://github.com/finitelabs/control4-finite-labs-essentials/tree/3587b7b49a0ca3f517531401589ffd9f8cbe0ab5) |
| [control4-hatch](https://github.com/finitelabs/control4-hatch) | [2011dca463fc](https://github.com/finitelabs/control4-hatch/tree/2011dca463fc0f7b2e1446a1db514f212f211faa) |
| [control4-influxdb](https://github.com/finitelabs/control4-influxdb) | [7dc256273704](https://github.com/finitelabs/control4-influxdb/tree/7dc25627370455bf9626e64d77e1a7f108129324) |
| [control4-mqtt](https://github.com/finitelabs/control4-mqtt) | [d3c2cea4a125](https://github.com/finitelabs/control4-mqtt/tree/d3c2cea4a125caa0fd2ac4474cff68db4acdfda6) |
| [control4-schluter](https://github.com/finitelabs/control4-schluter) | [227068f0fb78](https://github.com/finitelabs/control4-schluter/tree/227068f0fb783cbc0d17884aa05aab0af08d27f8) |
| [control4-tplink](https://github.com/finitelabs/control4-tplink) | [938971192dea](https://github.com/finitelabs/control4-tplink/tree/938971192dea165859c34f0d6b7451dedd964eac) |
| [control4-zigbee3-kwikset](https://github.com/finitelabs/control4-zigbee3-kwikset) | [f791300f5fd8](https://github.com/finitelabs/control4-zigbee3-kwikset/tree/f791300f5fd8c2e258e673eceee64d1202aa247d) |
| [control4-zigbee3-smlight](https://github.com/finitelabs/control4-zigbee3-smlight) | [d5b5431037df](https://github.com/finitelabs/control4-zigbee3-smlight/tree/d5b5431037df04b984864e7f621316760974324f) |
| [drivers-driverpackager](https://github.com/finitelabs/drivers-driverpackager) | [465ecc1cf73a](https://github.com/finitelabs/drivers-driverpackager/tree/465ecc1cf73a85a4fdaf62fb688e9aed83e6d530) |
| [homebridge-control4-home-connect](https://github.com/finitelabs/homebridge-control4-home-connect) | [66e307a9cca8](https://github.com/finitelabs/homebridge-control4-home-connect/tree/66e307a9cca8addb3c7a6c2015426409c0306af1) |
| [lua-bitn](https://github.com/finitelabs/lua-bitn) | [a20cafe97d62](https://github.com/finitelabs/lua-bitn/tree/a20cafe97d62a0a13e54b63807efbddfa8d7d7c2) |
| [lua-bthome-ble](https://github.com/finitelabs/lua-bthome-ble) | [7b04f8cdb928](https://github.com/finitelabs/lua-bthome-ble/tree/7b04f8cdb928a0f106bb4cdb2b8398bc7d5e344e) |
| [lua-crypto](https://github.com/finitelabs/lua-crypto) | [4f780b68a48f](https://github.com/finitelabs/lua-crypto/tree/4f780b68a48f6c0ef088dd0d1b73e656266b35ca) |
| [lua-noiseprotocol](https://github.com/finitelabs/lua-noiseprotocol) | [589de081185f](https://github.com/finitelabs/lua-noiseprotocol/tree/589de081185f18562bb8091966db9dc9f5df066b) |
| [lua-protobuf](https://github.com/finitelabs/lua-protobuf) | [f2b3b9306f8e](https://github.com/finitelabs/lua-protobuf/tree/f2b3b9306f8ef98c6a285a7ba12c64e5cd1f99ef) |
| [noiseprotocol.github.io](https://github.com/finitelabs/noiseprotocol.github.io) | [97a603a07338](https://github.com/finitelabs/noiseprotocol.github.io/tree/97a603a07338435a05e9e78d717facfffe7c6f19) |
| [website](https://github.com/finitelabs/website) | [fc81d06b9475](https://github.com/finitelabs/website/tree/fc81d06b9475d2fd42227fb398f1d776985ad6e5) |

## Proflame reload reference (2026-09-07)

The follow-up review used [psaab/proflame_c4](https://github.com/psaab/proflame_c4),
particularly `src/driver.lua` load cleanup and `OnDriverUpdated`, and specification
section 3.3. FloLogic now cleans up at the start of bundle evaluation, replaces
module/state tables, and explicitly restarts on updates. Tests reload the source
in the same Lua runtime without a preceding destroy callback and deliver old
HTTP/timer/disconnect callbacks after replacement.

Proflame's report-only startup/periodic release checks also inform the GitHub
release workflow here. FloLogic uses C4-specific tags because it shares a
repository with Home Assistant. Version 2026090707 removes the filesystem
restriction override introduced by the direct installer. Retain Director's
filesystem restrictions and use Composer where installation access is denied.
Transport completion must not be reported as a verified driver installation.
The running version and lifecycle output are the available confirmation.
