# Control4 adversarial review

Reviewed 2026-09-08 at commit `fb54f468069327552c48b7d71959f7a6d311dd91`.

**Disposition: changes required before treating the split driver as dependable valve control.** The most serious defects affect physical-valve identity and the truthfulness of the displayed shutoff state. Passing the current suite does not establish those properties.

## Scope and evidence

Read the repository's implementation and test code, including the Home Assistant integration, shared Lua JSON/model/SignalR/WebSocket/session/update code, legacy Control4 monolith, shipping cloud and valve companions, link protocol, spike drivers, manifests, build scripts, and CI/release workflows. The shipping split manifests are version `2026090809`; the retained monolith is `2026090709`.

Validation: `.venv/bin/python -m pytest -q` completed with **110 passed in 4.07s**. The committed cloud and valve C4Z archives passed ZIP CRC checks and had identical member contents to the packages rebuilt by the tests. Rebuilding changed ZIP container metadata; those incidental changes were restored. No implementation changes were made during this review.

Findings below follow source control flow and, where relevant, the published Director API contract. No live Director, Composer, FloLogic account, or physical valve was exercised. Controller-dependent conclusions are identified separately. References are to editable source files, rather than duplicate generated bundles. P1 means fix before relying on the affected control behavior; P2 means a substantive correctness or recovery defect; P3 means a lower-impact defect.

## Findings

### 1. P1 — Bound-device discovery reads names as device IDs

**Locations:** `c4/cloud/cloud.lua:981`, `c4/cloud/cloud.lua:1006`, `c4/cloud/cloud.lua:1586`; `c4/valve/valve.lua:351`, `c4/valve/valve.lua:706`.

Both discovery helpers iterate `for _, id in pairs(found)` and retain values convertible to numbers. Director documents bound-device tables as device-ID keys and device-name values, with an example iterating `for id,name in pairs(devs)`. Ordinary names therefore produce an empty result. The singular provider API's scalar result needs its own compatibility handling. [Control4 DriverWorks reference](https://control4.github.io/docs-driverworks-api/#getboundconsumerdevices)

The cloud's ten-minute reconciliation consequently marks connected slots unbound. Subsequent polls omit their state slices because `entry.bound == false`. The fallback delivery path also loses its recipients. On the valve, startup provider detection can suppress the handshake despite an existing Composer connection. Numeric device names could instead be mistaken for unrelated IDs.

**Fix:** Decode the documented map by keys, distinguish lookup failure from an empty binding, and preserve explicit handling for a scalar provider result. Check which protocol/proxy device owns the custom binding on the supported Director versions.

**Test gap:** The cloud and valve fakes supply arrays such as `{55}` and `{77}`. They model a different API contract and conceal this defect. Binding lifecycle coverage must use Director-shaped results.

### 2. P1 — Slot reuse proceeds even when the live check finds a consumer

**Locations:** `c4/cloud/cloud.lua:1097`, `c4/cloud/cloud.lua:1118`; `c4/tests/cloud.lua:673`.

For a previously unavailable slot cached as unbound, reconciliation performs a live consumer check. When the check finds a consumer, it only logs that the old binding name will remain. It then replaces the slot's valve mapping anyway. The fallback condition permits this even when `AddDynamicBinding` fails because the existing binding remains present. An unavailable live lookup also allows reassignment.

Existing Composer connections and programming now refer to a slot whose physical target has changed. The companion's state-ID mismatch handler deliberately re-handshakes, so it can eventually adopt the replacement identity instead of preserving the original association.

**Fix:** A live consumer or indeterminate lookup must veto reuse. Preserve the old slot identity, refresh its bound status, and seek another safely available slot or report capacity exhaustion. Binding allocation and identity replacement must succeed as one operation.

**Test gap:** The existing test explicitly expects valve `200` to take slot `2001` despite a live consumer. Its final assertion encodes the unsafe behavior. This defect remains after fixing finding 1.

### 3. P1 — Companions can present indefinitely stale state as online

**Locations:** `c4/cloud/cloud.lua:1059`, `c4/cloud/cloud.lua:1332`, `c4/cloud/cloud.lua:1604`; `c4/valve/valve.lua:488`, `c4/valve/valve.lua:546`, `c4/valve/valve.lua:680`.

A failed cloud session updates only the cloud driver's connection property/events. Removing a valve from inventory marks its slot unavailable without publishing that transition to the companion. A companion with an intact Composer binding has no independent freshness watchdog. Its last online contact, valve state, and connection indication can therefore survive indefinitely through cloud failure or disappearance from the account.

Valve Refresh asks for state, but the cloud returns its cached slice whenever one exists; it does not request a fresh observation in that branch. Applying the replay sets the companion's connection true and stamps Last Link Update with the current wall clock. The slice's `updated` field does not constrain acceptance. Receipt time therefore cannot establish cloud-data freshness.

**Fix:** Represent cloud reachability, valve availability, and snapshot age explicitly. Publish unavailable transitions and expire freshness independently on the companion. Preserve the original observation time when replaying a snapshot. Refresh should request a bounded, coalesced cloud poll. Retaining historical contacts can be a deliberate policy, but they need an unambiguous stale/unknown indication for programming and users.

**Validation needed:** Recovery coverage must establish that a companion stops claiming current knowledge when snapshots stop, including when the Composer link itself stays bound.

### 4. P1 — An unconfirmed shutoff can leave the app tile off without a deadline

**Locations:** `c4/valve/valve.lua:436`, `c4/valve/valve.lua:616`, `c4/valve/valve.lua:722`.

Open and Close report light levels immediately after dispatch. NACK handling restores the last observed level, but a lost reply has no equivalent settlement. The nominal 120-second expiry runs only on later command/state activity and merely edits Last Command. It neither schedules a timeout nor reconciles the optimistic level. A quiet outage can leave the switch off indefinitely while closure was never established.

Toggle also uses this optimistic level, so a subsequent interaction can select the opposite physical command based on an unconfirmed assumption. Contacts remaining observation-based does not make the contradictory primary app tile reliable.

**Fix:** Keep physical state and requested state separate. If optimistic feedback is retained, give it a real deadline and an explicit pending/unknown representation. On uncertainty, reconcile the observed level and freshness; do not declare either successful closure or definite failure without evidence.

### 5. P1 — Stored identity hashes never protect a slot from identity changes

**Locations:** `c4/cloud/cloud.lua:838`, `c4/cloud/cloud.lua:891`, `c4/cloud/cloud.lua:1019`, `c4/cloud/cloud.lua:1069`, `c4/cloud/cloud.lua:1958`.

The implementation calculates a valve-ID/UUID hash and stores it in `st.identity`, but never compares that value when accepting inventory or authorizing commands. Reconciliation matches numeric ID and overwrites UUID/hash. Verification accepts restored mappings before the first inventory and otherwise checks numeric ID only. Account/endpoint property changes retain slot mappings, cached inventory, and cached slices.

If an ID identifies a different UUID after replacement, account changes, or endpoint changes, the established Composer association silently follows it. The code comments claim an identity protection that is not enforced. Actual cross-account ID reuse is not established by this review; the missing guard is established by the source.

**Fix:** Bind identity to the endpoint/account and immutable valve identity, compare before updating the mapping, and require explicit reassociation on mismatch. Configuration changes must invalidate cached authorization and freshness. Avoid authorizing physical writes from an unverified restored map.

### 6. P1 — Rebinding carries another valve's restore mode and event history

**Locations:** `c4/valve/valve.lua:335`, `c4/valve/valve.lua:507`, `c4/valve/valve.lua:562`, `c4/valve/valve.lua:672`.

Unbinding clears the current identity and pending commands but retains `restore_action`, previous state, contact baselines, and edge-event baselines. Binding a different valve and accepting its identity does not reset them. If that new valve is already shut off, `flovalve_track_restore` deliberately leaves the remembered action unchanged. Opening it can therefore select the previous valve's Disabled or Bypass mode.

The first snapshot from the new valve is also compared with the old valve's history. Differences can emit flow, warning, critical, and water-off transitions even though no corresponding transition occurred on the new device. Those events are available to Composer programming.

**Fix:** Scope remembered restore behavior and event baselines to immutable valve identity. A new identity needs a safe configured default, a fresh quiet baseline, and invalidation of prior live state. Historical display preservation during a temporary outage must not transfer control policy to a different valve.

### 7. P1 — Legacy self-update selects an incompatible split companion

**Locations:** `c4/src/update.lua:4`, `c4/src/update.lua:25`, `c4/src/update.lua:369`; `.github/workflows/release-c4.yml:43`; `c4/driver.xml:11`, `c4/valve/driver.xml`.

The legacy updater selects `flologic_valve.c4z` from a newer `c4-v...` release. The split release publishes its companion-only valve using that same filename. Selection checks release/version/asset URL but not driver family or migration compatibility. The old driver can therefore offer, stage, and request installation of a package that requires a separate cloud driver and has a different proxy/connection architecture.

The release workflow acknowledges this collision in a comment and instructs monolith owners not to install it. That instruction is not an executable safeguard in already installed drivers. The incompatible candidate and attempted install path are confirmed; the exact resulting project damage depends on Director and was not tested.

**Fix:** Stop exposing an incompatible package under the legacy updater's asset name. Give the split family a distinct asset identity, and validate family compatibility before staging. Preserve a deliberate manual migration path for legacy projects.

### 8. P2 — Valve self-update never dispatches its install socket callbacks

**Locations:** `c4/valve/valve.lua:1106`, `c4/valve/valve.lua:1135`; compare `c4/cloud/cloud.lua:234`.

The valve updater stores `soap_callbacks.on_open`, with the only install-packet `SendToNetwork` call inside it. The valve source and generated bundle define neither `OnConnectionStatusChanged` nor `ReceivedFromNetwork` to dispatch those callbacks. Creating the network connection does not invoke a function merely because it is stored in a state table.

Consequently the packet-send branch is unreachable through the supplied driver entry points. The three-second grace timer nevertheless completes with no error, allowing an unconfirmed-install result despite no packet transmission.

**Fix:** Implement the network dispatch entry points with binding, port, and runtime ownership checks; distinguish connection failure, packet transmission, and confirmed running version. Exercise the actual valve adapter through lifecycle entry points, not only the shared updater with injected callbacks.

### 9. P2 — Commands can outlive the companion's response window

**Locations:** `c4/cloud/cloud.lua:1366`, `c4/cloud/cloud.lua:1638`, `c4/cloud/cloud.lua:1704`; `c4/src/flologic.lua:428`; `c4/valve/valve.lua:436`.

The cloud queue is count-bounded but jobs have no enqueue timestamp or deadline. Each session can consume up to 180 seconds, already longer than the companion's nominal 120-second response window. Waiting commands can execute much later after their local pending entries have expired. Their eventual acknowledgements are then ignored as unknown.

An old Open request executing minutes later is materially different from a prompt command. Immediate queue draining also takes priority over scheduled refreshes: a poll firing while busy is simply skipped, and the next queued command starts immediately after settlement. A continued command backlog delays authoritative state convergence.

**Fix:** Establish accepted/queued/sent/outcome semantics and an end-to-end deadline. Expire work that has not been transmitted; treat uncertain transmitted writes separately. Guarantee reconciliation opportunities between bounded command batches. Do not automatically replay a physical write whose outcome is uncertain.

### 10. P2 — The circuit breaker does not gate commands

**Locations:** `c4/cloud/cloud.lua:1347`, `c4/cloud/cloud.lua:1510`, `c4/cloud/cloud.lua:1638`, `c4/cloud/cloud.lua:1709`.

Polling honors `cb_open_until`; command acceptance and queue draining do not. After repeated authentication or transport failures open the breaker, further commands can continue opening sessions and draining the queue throughout the cooldown. The protection therefore does not bound the same cloud traffic generated by user actions or programming.

**Fix:** Define and enforce one breaker policy at session admission. Reject or defer unsent commands with explicit status during cooldown, preserving their deadline. If a deliberate recovery probe is allowed, bound it separately. Successful credential correction should have an explicit recovery policy rather than inheriting an unrelated cooldown accidentally.

### 11. P2 — Device fallback cannot establish a first identity and can use a stale route

**Locations:** `c4/valve/valve.lua:382`, `c4/valve/valve.lua:562`, `c4/cloud/cloud.lua:1812`.

This remains after correcting bound-device lookup. A valve with no prior handshake cannot attach the persisted-ID hint to a fallback hello. Cloud fallback ingress requires that hint to choose a slot, so it drops the initial hello. A previously linked valve retains its old persisted ID during rebinding; fallback selects the slot associated with that old ID rather than establishing the current connection's identity.

The alternative transport therefore lacks an independent bootstrap and safe reassociation mechanism. Also, transport selection treats a non-throwing `SendToProxy` call as delivery, with no handshake deadline to detect silent failure.

**Fix:** Correlate fallback routing with the current Composer peer and binding relationship. Do not use an old valve ID as the authority for choosing a new binding. Add bounded handshake recovery and an explicit failure state. Validate the complete fallback conversation from an empty persisted identity through rebind, not just isolated message handlers.

### 12. P2 — Staging destroys the previous package before validating the replacement

**Locations:** `c4/src/update.lua:316`.

The installer deletes the existing C4Z and writes the download directly into its place. Only afterward does it check disk size against the received body and inspect a two-character ZIP prefix. A failed write or invalid download leaves the prior package unavailable. Matching the received body's length does not detect a body that was already incomplete; a ZIP-looking prefix does not establish archive integrity, driver identity, or compatibility.

The current code honestly warns that Composer recovery may be required, but warning after deletion does not preserve recoverability.

**Fix:** Validate a separate candidate before replacing the installed package. Check archive integrity, manifest identity/version, and download metadata where available. Use a supported atomic replacement mechanism or preserve and restore a backup. Keep a known-good package on every failure path.

### 13. P2 — Invalid mode semantics are rejected by contacts but accepted elsewhere

**Locations:** `c4/shared/flologic_link.lua:411`, `c4/valve/valve.lua:255`, `c4/valve/valve.lua:507`, `c4/valve/valve.lua:546`.

The link parser requires mode to be finite but permits values without valid flag semantics. The contact helper correctly requires a nonnegative integer and returns without changing contacts otherwise. State application nevertheless persists the same snapshot, computes the tile level and edge events, and marks the connection online. That produces inconsistent outputs from one accepted snapshot.

**Fix:** Validate the complete semantic state once before any persistence, display, contact, level, or event mutation. Invalid snapshots should leave the previous observation intact and affect freshness/diagnostics appropriately. Helper-only validation coverage is insufficient to establish atomic state acceptance.

### 14. P3 — The real poll path discards the session before saving its relog token

**Locations:** `c4/cloud/cloud.lua:1443`, `c4/cloud/cloud.lua:1569`, `c4/cloud/cloud.lua:1740`.

`flocloud_real_fetch_account.done` clears `st.session`, cancels the session, and calls its callback. That callback passes `st.session` to `flocloud_on_account`, so the real flow supplies nil. The token-saving block requires a non-nil session and is unreachable on that flow. Command completion also discards the session without saving an updated token.

Full login remains a working fallback, so this is not evidence that all authentication fails. It defeats the intended token reuse and causes unnecessary full authentication.

**Fix:** Capture the token from the completed session before clearing it, and pass completion metadata explicitly. Keep session ownership fencing while testing the actual adapter's completion order.

## Additional hardening and controller acceptance gaps

- **Raw frame logging:** `c4/src/flologic.lua:619` enables event tracing for command sessions regardless of Debug Mode. At line 482 an undecodable frame's detail is sent to the warning logger. `c4/src/signalr.lua` supplies a raw frame excerpt. This contradicts an unconditional claim that raw bodies are never logged. No actual secret disclosure was observed. Emit bounded diagnostic metadata rather than raw payload text, including on error paths.
- **Retired network bindings:** Inspect `c4/cloud/cloud.lua:243` and the TCP close/retirement path under a spontaneous OFFLINE callback and hot reload. Retirement can wait for another OFFLINE after one has already been consumed. The current fake eagerly emits disconnect callbacks; whether Director always supplies the additional callback needs verification. A stranded binding would reduce the finite pool. This is a controller-dependent resource-lifecycle concern, not a proven production exhaustion claim.
- **TLS endpoint identity:** Raw SSL uses `VERIFY_MODE = "peer"` and a CA bundle. Confirm hostname verification and SNI behavior for this exact Director API on every supported OS. CA-chain verification alone does not establish that endpoint-name checking happens. This review does not claim a demonstrated TLS bypass.
- **Live transport contract:** Establish actual custom-binding direction, protocol/proxy ownership, restored binding visibility, message-size behavior, and Navigator command notifications on supported Director versions. The spike and isolated Lua fakes are useful, but cannot certify the split driver's complete lifecycle and transport adapters.

## Remediation order

1. Correct Director bound-device decoding and make occupied/unknown slots impossible to reuse. Enforce account/UUID identity and reset per-valve control history on reassociation.
2. Establish truthful freshness and command-outcome behavior across the cloud, companion, contacts, and app tile. Give unsent commands deadlines and prevent unconfirmed state from becoming permanent UI state.
3. Separate legacy and split update artifacts, repair the valve network adapter, and preserve a known-good package during staging.
4. Repair fallback bootstrap, unify breaker admission, tighten atomic snapshot validation, and capture relog completion metadata.
5. Replace inaccurate API fakes and contradictory assertions. Then complete Director acceptance against the invariants above before calling the driver production-ready.

The code contains worthwhile defensive work: bounded link envelopes, action whitelists, serialized cloud sessions, callback ownership checks, and substantial offline coverage. The failures are concentrated where those individually reasonable pieces meet Director's API, persistent physical identity, and asynchronous state. Those boundaries need to become explicit, enforced contracts.
