Control4 DriverWorks package for FloLogic Connect valves (OS 3.3.0+).

Version **2026090813** adds a busy watchdog to the cloud driver: a
poll or command session that never settles (a hung transport calls
back never) used to hold `busy` forever, so every later poll skipped
with "session busy or driver not ready" and the driver looked dead
with no error. Past 180s the watchdog now force-clears the orphan
(its late reply is fenced by session identity and poll generation),
nacks an orphaned command job `stuck` so the companion learns the
outcome, and starts a fresh poll in the same tick. The skip message
is also split — "session busy (<owner> <age>s)" versus "driver not
ready" — so the next field report diagnoses itself. Valve package
is a lockstep version bump only.

Version **2026090812** fixes the self-update read-back the 0811 field
run caught: `C4:FileOpen` positions at end-of-file, so the staged
candidate's magic gate read `""` and failed every install. All three
file adapters now `FileSetPos(handle, 0)` before reading (pinned by a
packaging test), the updater distinguishes read-back failure from a
non-archive download, and the Director mock models true position
semantics (open-at-EOF, seek, append writes) so the regression suite
fails without the seek. The move adapter also tries both bare and
leading-slash paths (the documented `FileMove` example uses slashes)
and believes filesystem existence, not the call's undocumented return.

Version **2026090811** implements the second adversarial-review
remediation (12 findings, all fixed and covered; see
`c4/ADVERSARIAL_REVIEW_2026090810.md`).

- Command identity end to end: jobs carry the expected uuid, scope, and
  absolute deadline; dequeue revalidates the slot, quarantine purges
  admitted-but-unsent work, and the command session compares its own
  freshly fetched row plus the transmit deadline immediately before the
  irreversible request (pre-transmit expiry reports `expired`, never
  transmitted). A replaced valve can never receive another valve's
  queued write.
- Ordering and freshness: every snapshot/notice carries a per-slot
  sequence under a persisted cloud epoch, and every snapshot advertises
  its freshness budget from the configured poll interval. Duplicates
  and reordered redeliveries drop without renewing the watchdog or
  revoking newer availability info; cadence is never inferred from
  traffic. The keys are additive envelope fields, so mixed versions
  still link (older peers keep legacy semantics).
- Replacement safety: companions key identity on id + immutable uuid
  (reset before applying a replacement's first snapshot), persist
  identity and state as one validated association, and clear both on
  identity change — a restart before the first new snapshot restores
  nothing stale.
- Pending-observation: an ack holds the tile only until the observation
  deadline; a novel snapshot confirms the request, silence reconciles
  it. Unbind and unavailability settle in-flight requests at once, and
  commands block before the first observation (`no state yet`) instead
  of claiming blindly.
- Discovery truth: a nil bound-device lookup is observed-unbound (per
  the published API contract), so genuinely unbound slots recycle and
  unbound companions stay silent; only a missing API or raised error is
  indeterminate. Hintless fallback attributes by elimination when
  exactly one consumer exists (single-valve bootstrap with a broken
  proxy leg); multi-valve fallback still needs one proxy handshake.
- Safe replacement: installs move installed → backup → candidate with
  filesystem verification at each step and rollback on failure, refuse
  before touching anything without a file move, and report grace
  expiry before transmission as a connection failure. Legacy-named
  split assets (`flologic_valve.c4z`) were retired from releases
  `c4-v2026090801`–`c4-v2026090809` with migration notes, so installed
  monoliths only ever see monolith releases again.
- Identity without state owns its own bounded wait (re-requested, then
  an explicit `Link failed: no state from cloud` with slow recovery);
  slot identity is scoped to account + endpoint (ID-only records never
  equate across namespaces); hub-frame logs are shape-only; pending
  timers cancel explicitly on reset/unbind/retire.

Version **2026090810** implements the adversarial-review remediation (14
findings, all fixed and covered; see `c4/ADVERSARIAL_REVIEW.md`).

- Valve package renamed `flologic_valve.c4z` →
  `flologic_water_valve.c4z`: installed monoliths no longer see split
  releases as updates, and split updaters require the whole lockstep
  family before staging. Split installs on tags
  `c4-v2026090801`–`c4-v2026090809` need ONE manual Composer update to
  this release; self-updates resume after that hop. Monolith owners
  still migrate manually.
- Updater stages to a validated separate candidate (never deletes the
  installed package first), screens downloads by published size plus
  archive prefix, and the valve install socket is now actually
  dispatched through lifecycle entry points.
- Slot safety: Director bound-device maps decoded by ID key; slot reuse
  vetoed on any live consumer or failed lookup; exact valve identity
  (id + uuid) verified before any write, with quarantine + explicit
  re-link on conflict; account changes invalidate cached authorization.
- Truthful state: companions publish unavailable transitions, expire
  stale snapshots on a cadence-aware watchdog, display observation
  time, drop out-of-order snapshots, and settle unanswered commands on
  a real deadline that reconciles the tile. Commands carry a transmit
  deadline, never replay, and share the breaker policy with polls;
  overdue polls run before further commands.
- Fallback: hints follow the live handshake only (never a stale
  binding); proxy hellos retry in a bounded burst with an explicit
  failed state plus slow recovery. Snapshots validate atomically
  (domains + clean text); relog tokens harvest from any settled
  session and drop on auth failure; hub frame logs are scrubbed and
  retired bindings drain safely.

Version **2026090808** removes the phantom `Valve Link 16` connection and
fixes valve instances installing as `Light v2`. The static slot is gone:
Composer indexes the proxy-less cloud via combo + category (the proven
reference form), so all 16 links are dynamic and named — existing binds
migrate untouched since restore re-creates the persisted ids. The valve
proxy now carries `primary` + `name` like the reference proxy drivers,
so new instances take the driver name.

Version **2026090807** diagnoses the failing GitHub self-update: the
updater now traces every milestone to the Lua log (downloaded bytes,
which file-store alias won, which installed-lookup key matched, stage
verification, trigger outcome) and refuses to trigger an install when
the staged file is not a driver archive (zip-magic read-back). Run one
update on this build and the log pinpoints the breaking step.

Version **2026090806** fixes commands timing out despite being applied
plus link naming in Connections view. (0805 never published — its release
run failed on a formatting check; identical content ships here.) The hub applies `RequestStateChange`
immediately but the `StateChangeResult` event is unreliable (slow/offline
valves may never produce it), and the driver treated the event as the
only success signal. Commands now race the event against inventory
verification — any post-command state showing the requested fields
counts as success — and the hub event stream is traced to the Lua log
during commands so the exchange stays diagnosable. Failed commands also
trigger a refresh so the tile converges to the true state. The fix lives
in the shared protocol stack the split drivers build from (the frozen
monolith line stays on its last published build). Naming: Director has
no binding-rename API and the static link's name is manifest-fixed, so
the static slot now fills LAST as honestly-named overflow (`Valve Link
16`) while dynamic slots 2002–2016 fill first carrying their valve
names; reused slots are removed + re-added so the new valve's name
shows. (0804 was superseded before release; its command fix ships here.)

Version **2026090803** completes the Composer-discovery fix: the cloud
manifest now declares `combo` plus a `Utility` composer category,
mirroring the proven proxy-less coordinator form (and restoring the
`combo` element the working monolith shipped). The valve declares the
same category. If `FloLogic Cloud` still did not appear in driver
search on 2026090802, this build resolves it.

Version **2026090802** fixes Composer discovery of the cloud driver:
Composer refuses to index a driver with neither proxies nor connections,
so the cloud now declares its primary valve link as a static manifest
connection (`Valve Link 1`, slot 2001, class `FLOGIC_VALVE`); slots
2002–2016 stay dynamic. If `FloLogic Cloud` never appeared in driver
search on 2026090801, this build resolves it — update both drivers to
this lockstep version.

Version **2026090801** was the split-driver release: one `FloLogic Cloud`
account coordinator (`flologic_cloud.c4z`) plus one `FloLogic Water
Valve` companion per valve (`flologic_valve.c4z` on tags
`c4-v2026090801`–`c4-v2026090809`, renamed to
`flologic_water_valve.c4z` from `c4-v2026090810`), both under one tag
at one lockstep version. New installs start with the split drivers;
see [SPLIT_README.md](SPLIT_README.md) for the install/bind guide and
manual migration from the monolith. The valve driver requires OS 3.3.2+
for the app-tile click; the cloud driver runs on 3.3.0+. Tags
`c4-v2026090801`–`c4-v2026090809` reuse the legacy monolith filename, so
installed monoliths will offer those as an update: do NOT install them
over a monolith instance — migrate manually instead (delete the
monolith, add cloud + valves, rebind programming). Both new drivers
self-update from GitHub releases, each tracking only its own asset.

Monolith owners: the legacy single-driver line ended at Driver Version
2026090709; its notes stay on the older release tags.
