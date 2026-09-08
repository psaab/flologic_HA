# Control4 adversarial review — second pass

Reviewed on 2026-09-08 at `7ee712c7216e2230f86a87af4a592cb40c68d429`, shipping version `2026090810`.

**Verdict: the release improves the implementation substantially, but the claim that all fourteen previous findings are fixed is unsupported.** Physical identity still does not reach the actual write boundary, freshness still measures cached-message receipt, and several recovery paths bypass the new protections.

## Scope and validation

This continues the whole-tree code review recorded in `ADVERSARIAL_REVIEW.md`. The Home Assistant implementation, legacy monolith, shared Lua stack, spike drivers, scripts, and original tests were read in that pass. This pass reviewed all implementation changes since that baseline, new tests, packaging/release changes, and their surrounding lifecycle, persistence, transport, and command paths. Generated bundles are duplicate source assemblies; packaging tests checked their agreement with the editable sources.

The full existing suite passed: **110 tests in 4.30 seconds**. Lua subtests run inside those Python tests, so the unchanged Python count does not mean no tests were added. Both committed shipping archives passed CRC checks and matched rebuilt archive member contents. Incidental ZIP metadata changes from running tests were restored. No driver implementation was changed.

Director API claims were checked against Control4's published reference. Public GitHub release metadata was read on the review date. No live controller, Composer project, cloud login, or physical valve was exercised. The findings below are source-level defects; controller-specific outcomes are qualified. P1 denotes a release-blocking control/identity/state issue; P2 denotes a substantive correctness or recovery issue.

## Findings

### R1. P1 — UUID verification ends before the actual physical write

**References:** `c4/cloud/cloud.lua:1553`, `c4/cloud/cloud.lua:1574`, `c4/cloud/cloud.lua:1868`, `c4/cloud/cloud.lua:1892`; `c4/src/flologic.lua:511`, `c4/src/flologic.lua:631`.

Admission verifies a slot against cached inventory, but the queued job carries only numeric `valve_id`, without expected UUID or identity generation. Queue draining does not revalidate the slot. The new overdue-poll path can quarantine a slot for a changed UUID and then run a command already queued for that slot.

More generally, the command session fetches its own inventory and selects a valve by numeric ID. That newly fetched row is never compared with the UUID that authorized the command. A replaced identity can therefore receive an old command even though the new quarantine logic correctly rejects subsequent admissions.

**Required correction:** Carry the expected immutable identity and configuration generation with the job. Revalidate slot membership before starting it and compare the actual command-session valve immediately before `RequestStateChange`. Invalidate unsent work on quarantine. Identity validation solely at queue admission is insufficient.

**Coverage gap:** The new quarantine test submits its command after quarantine. It does not establish safety for work already admitted or for differences between poll inventory and command-session inventory.

### R2. P1 — The transmit deadline is actually a session-start deadline

**References:** `c4/cloud/cloud.lua:1924`, `c4/cloud/cloud.lua:1868`; `c4/src/flologic.lua:402`, `c4/src/flologic.lua:424`, `c4/src/flologic.lua:438`, `c4/src/flologic.lua:732`; `c4/valve/valve.lua:592`.

The 90-second check happens before starting negotiation, WebSocket upgrade, login, and inventory retrieval. Those asynchronous steps can consume additional time before the physical request is sent. The session has its own 180-second budget; no absolute job deadline reaches it.

Thus a job can pass the queue-age check, exceed the companion's 120-second response window while preparing the session, and still transmit afterward. The companion has already reported no response and reconciled its tile, but an old Open or Close can subsequently execute. The comments claiming margin for execution do not create that bound.

**Required correction:** Pass an absolute deadline into the session and enforce it before the irreversible request. Session preparation must consume the same budget. Once transmission occurs, distinguish an uncertain outcome from a request that expired without being transmitted.

**Coverage gap:** Existing deadline coverage ages the queued job before dequeue. It does not cover expiration during session preparation.

### R3. P1 — Replayed cache still restores freshness and clears unavailability

**References:** `c4/cloud/cloud.lua:1515`; `c4/valve/valve.lua:674`, `c4/valve/valve.lua:800`.

State application rejects only observation timestamps strictly older than the previous timestamp. Replaying the identical snapshot passes. Every accepted replay resets `last_slice_at` to the current receipt time, clears `stale` and `unavailable`, and reports Online. The watchdog measures receipt time, not observation age.

Refresh still immediately replays cached state before attempting a new poll. During cloud failure, repeated Refresh requests can therefore keep an old observation online indefinitely. A delayed equal-timestamp snapshot can also clear a newer unavailable notice because those notices have no ordering generation. The displayed observation timestamp is more honest now, but the live-state decision remains wrong.

**Required correction:** Separate receipt liveness from observation freshness. Duplicate snapshots must not renew observation age or revoke newer availability information. Add a generation/sequence and explicit observation-age rules, including recovery after clock changes or cloud-driver restart.

**Coverage gap:** The stale-recovery test treats another copy of its baseline state as recovery. That tests the existing behavior rather than proving that recovery requires a fresh observation.

### R4. P1 — Companion history remains scoped to numeric ID, and persistence can mix identities

**References:** `c4/valve/valve.lua:708`, `c4/valve/valve.lua:729`, `c4/valve/valve.lua:755`, `c4/valve/valve.lua:1601`; `c4/cloud/cloud.lua:1259`.

Cloud quarantine specifically handles a replacement with the same numeric ID and a different UUID. It places that replacement on another slot and asks the installer to re-link. However, the companion resets history only when the numeric ID changes. Following the prescribed re-link procedure with the same ID retains the original valve's restore mode, last state, and event baselines. A replacement that is initially closed can inherit Disabled or Bypass as its Open action.

There is also a persistence gap for different numeric IDs: reset clears runtime history, but leaves the old persisted state body. Identity acceptance persists the new ID immediately. A restart before the first new snapshot then restores the new ID alongside the old valve's state. `flovalve_restore_display` does not verify that those records belong together, so it relearns the old restore action.

**Required correction:** Make companion identity include immutable valve identity and account/provider scope. Persist identity and its state as one validated association, or clear incompatible persisted state before accepting the new identity. Establish a fresh baseline for a replacement even when its numeric ID matches.

**Coverage gap:** The new reassociation test changes ID `11` to `22` without a restart. Neither same-ID replacement nor the identity/state persistence gap is covered.

### R5. P1 — ACK and unbind still leave optimistic physical state without settlement

**References:** `c4/valve/valve.lua:528`, `c4/valve/valve.lua:875`, `c4/valve/valve.lua:945`, `c4/valve/valve.lua:991`.

The new timer repairs the unanswered-command path only while its pending entry survives. ACK deletes that entry and cancels its timer, although the displayed status explicitly says it is still awaiting refresh. If the following state refresh never arrives, the optimistic level is retained indefinitely. The freshness watchdog changes a property/event, but does not settle that level.

Unbind likewise deletes pending entries without reconciling the optimistic tile; their later timer callbacks find no entry and do nothing. Timeout reconciliation also does nothing when there is no previous `last_state`.

These paths still allow an off tile without a confirmed closure represented in companion state. Acknowledgement, binding loss, and first-observation absence require explicit outcome handling.

**Required correction:** Keep a separate pending-observation state after ACK and give it a deadline. Settle requested-state presentation on unbind and unavailability as well as timeout. If no observation exists, expose unknown state rather than leaving the requested level as the physical claim.

**Coverage gap:** The new ACK test explicitly asserts that the optimistic level survives beyond the deadline without supplying a confirming state.

### R6. P1 — Published historical assets still expose the legacy updater to the incompatible package

**References:** `c4/src/update.lua:5`, `c4/src/update.lua:12`; `c4/RELEASE_NOTES.md:6`; `.github/workflows/release-c4.yml`.

The renamed `0810` package prevents a new collision, but discovery searches the latest 100 releases and selects the highest eligible asset across them. It does not stop at the latest tag. The public release API still lists stable `c4-v2026090809` with `flologic_valve.c4z` (30,417 bytes), and earlier split releases also retain that name. [Published 0809 release](https://github.com/psaab/flologic_HA/releases/tag/c4-v2026090809)

An installed monolith at `2026090709` therefore still selects the incompatible `0809` companion. The statement that monoliths no longer see split releases is false for the currently published release set. This conclusion follows from selection code plus read-only release metadata; no install was attempted.

**Required correction:** Plan release remediation for already-installed updaters, including the historical eligible assets. A local code fix cannot change their selection behavior. Options require a deliberate compatibility release or retiring unsafe legacy-named split assets with appropriate migration communication. This review did not modify releases.

### R7. P2 — No-binding results are treated as discovery failures

**References:** `c4/cloud/cloud.lua:1022`, `c4/cloud/cloud.lua:1186`; `c4/valve/valve.lua:396`, `c4/valve/valve.lua:980`; `c4/tests/cloud.lua:396`.

The ID/name map decoding is fixed. However, both helpers now return the indeterminate result when a successful API call returns nil. Director documents null as the no-bindings result. [Control4 bound-device API](https://control4.github.io/docs-driverworks-api/#getboundconsumerdevices)

On the cloud, live rechecking therefore vetoes reuse of a truly unbound departed slot. Once all sixteen slots have historical occupants, replacement discovery can fail despite free physical connections. Slow reconciliation also retains stale bound flags. On a companion, a genuinely unbound startup is treated as unknown, causing hello bursts and a misleading Link failed state.

**Required correction:** Distinguish API absence/exception from the documented successful no-bindings result. Validate the scalar provider no-binding convention separately. Model Director's actual return values in tests.

**Coverage gap:** New tests use an empty table to represent no bindings, while nil remains classified as failure.

### R8. P2 — Freshness cadence is inferred from traffic, causing false outages and excessive grace

**References:** `c4/valve/valve.lua:685`, `c4/valve/valve.lua:816`; `c4/cloud/cloud.lua:20`.

The timeout is three times the spacing between the last two received messages, with a five-minute floor. Cloud polling is configurable up to one hour. Before two observations establish that cadence, a healthy slow-poll installation is marked stale after five minutes. A manual Refresh or duplicate reply can later collapse the measured spacing and recreate the false outage.

The reverse happens after a long interruption: a large gap between the last two messages inflates the next outage allowance, without a configured upper bound. Recovery traffic should not teach the watchdog that outages are the normal polling interval.

**Required correction:** Advertise a bounded freshness budget based on configured polling and session timing. Distinguish fresh scheduled observations from cache replies and recovery gaps. Exercise the whole supported poll range, not only the default cadence.

### R9. P2 — Candidate validation does not preserve the installed package on replacement failure

**References:** `c4/src/update.lua:350`, `c4/src/update.lua:398`; `c4/RELEASE_NOTES.md:13`.

After validating `filename.new`, staging deletes the installed file and writes a second copy from memory. A failure or interruption during that second write still leaves the installed filename missing or incomplete, with no rollback. A successful first write cannot establish that a second write will succeed; the candidate also consumes extra storage during replacement. Prefix and byte-count checks are not full archive-integrity checks.

**Required correction:** Preserve a recoverable known-good package through the final replacement. Investigate supported file-move/backup operations for the actual installation store and retain an explicit rollback path; if Director cannot support it reliably, constrain self-install accordingly. Control4 documents `FileMove` from OS 3.3.0, but that alone does not prove it supports this store or atomic replacement. [Control4 file API](https://control4.github.io/docs-driverworks-api/#filemove)

**Coverage gap:** The new failure tests fail the candidate write/read. They do not fail the installed-file rewrite after a successful candidate.

### R10. P2 — A successful identity handshake can wait forever for its first usable state

**References:** `c4/valve/valve.lua:729`, `c4/valve/valve.lua:816`; `c4/cloud/cloud.lua:1837`.

Any identity cancels handshake recovery. The freshness watchdog then returns immediately while `last_slice_at` is nil. If the first snapshot never arrives or repeatedly fails validation, neither recovery mechanism owns the wait. The companion can remain Linking indefinitely despite the newly advertised bounded handshake behavior.

This is distinct from silence after an established snapshot. It also leaves historical display/level without a clear first-observation failure state after restart.

**Required correction:** Give identity-known/state-unconfirmed its own deadline and bounded state request recovery. Completion of identity exchange must not count as completion of usable link establishment.

### R11. P2 — Device fallback still cannot bootstrap when the proxy route stays broken

**References:** `c4/valve/valve.lua:439`, `c4/valve/valve.lua:463`; `c4/cloud/cloud.lua:2115`.

The new live-only hint removes one stale-ID route, but the first fallback hello still has no hint and is still dropped by cloud ingress. Retrying the same unanswerable conversation does not provide an independent fallback transport. A controller where the custom proxy route fails persistently cannot establish the link through `SendToDevice`, even if the latter works.

**Required correction:** Either implement bootstrap attribution based on the actual peer/binding relationship, or explicitly describe fallback as available only after a successful proxy handshake and leave this limitation open. It cannot be counted as a completed fix for fallback bootstrap.

**Coverage gap:** Fallback tests manually inject a successful identity into the companion while simulating a failed proxy leg. That bypasses the missing conversation.

### R12. P2 — Install grace expiry reports a transmitted trigger even without a connection

**References:** `c4/cloud/cloud.lua:608`, `c4/valve/valve.lua:1403`; `c4/src/update.lua:447`.

Both SOAP adapters call `finish(nil)` when their three-second grace timer expires, regardless of whether ONLINE arrived or the packet was sent. The shared installer then logs that the trigger was sent and reports an attempted installation. The newly added valve dispatch entry points fix the previously unreachable send branch, but not this silent-connection case.

**Required correction:** Track successful transmission separately. Expiry before transmission must report connection/send failure. An unconfirmed installation result is appropriate only after the trigger was actually handed to the transport.

**Coverage gap:** The new tests cover ONLINE followed by data, and OFFLINE before ONLINE. They omit a connection attempt producing no callback before grace expiry.

## Other unresolved concerns

- `flocloud_place_valve` treats an existing slot with the same numeric ID as eligible for the fresh-slot branch (`c4/cloud/cloud.lua:1171`). At capacity, a quarantined same-ID/different-UUID slot with a stale unbound flag can therefore bypass the live consumer check entirely. Whether reassignment succeeds depends on Director's response to re-adding that existing binding. Apply the reuse guard to immutable identity changes, not just different numeric IDs.
- Raw hub-frame excerpts remain in warning logs. Replacing control bytes prevents multiline log injection but does not redact payload contents (`c4/src/signalr.lua:143`, `c4/src/flologic.lua:492`). No actual credential disclosure was observed.
- The bound-slot identity hash still excludes account/endpoint scope and permits missing UUIDs. Configuration changes invalidate cache but do not establish a persisted identity namespace. Do not equate two ID-only records across namespaces with verified physical identity.
- Pending command timers are not explicitly cancelled during runtime retirement or history reset. Ownership/entry checks prevent most late mutations, but cancellation would make resource lifetime explicit.
- TLS hostname verification, restored binding ownership, callback ordering, and Navigator behavior still require supported-controller acceptance. This review does not claim a demonstrated TLS vulnerability or confirmed live network-binding exhaustion.

## What improved and what should happen next

The map-key correction, ordinary live-consumer reuse veto, pre-first-poll write rejection, breaker admission, relog harvesting, semantic mode validation, and valve SOAP entry points are meaningful fixes. They should be retained. The outstanding issues largely occur between their individual test cases: admission versus transmission, identity versus state persistence, acknowledgement versus observation, and candidate validation versus replacement.

Prioritize R1–R6. Then repair the Director no-binding contract and recovery states. Validation should establish end-to-end invariants using realistic Director results and asynchronous completion order, with a controller acceptance pass afterward. The release notes should report partial remediation until those invariants hold; passing the current suite does not justify “all fixed and covered.”
