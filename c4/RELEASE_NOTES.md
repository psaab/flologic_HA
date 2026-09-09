Control4 DriverWorks package for FloLogic Connect valves (OS 3.3.0+).

Version **2026090825** answers the orphan-tile trap: after a delete +
re-add the old proxy can linger next to the live one, and the two tiles
look identical while only the bound one works. New "Identify Tile"
action flashes the bound tile 0/100 twice (pure display: no valve
commands, true level restored after), so the field can tell the live
tile apart without Composer archaeology — a tile that stays static
during Identify is not bound to this driver. New read-only "Proxy
Bound" property (Bound/Unbound/Unknown) exposes the 5001 bind state for
the same diagnosis. Lua-only (no manifest structural change): plain
update, no re-add needed — except installs coming from 0822 or older
still need the remove + re-add + re-pair from the 0823 notes.

Version **2026090824** is a Lua-only diagnostic follow-up to 0823 (no
manifest change, so no re-add is needed for 0823 installs — but installs
coming from 0822 or older still need the remove + re-add + re-pair from
the 0823 notes). An adversarial review found the tile path could still
fail silently: unknown light-proxy commands were debug-gated, so a
sender using unexpected vocabulary left no trace with Debug Mode off.
Unknown light commands now always warn, and every light-proxy arrival is
traced with Debug Mode on (kasa parity). The spike stub logs ignored
light commands the same way. Open/close logic is unchanged.

Version **2026090823** fixes the valve tile still dead (blank state, dead
taps) after a fresh add on 0822. Root cause: the valve manifest declared
no top-level `<capabilities>` block, so the light_v2 proxy instantiated
with no `on_off` combo and rendered no on/off buttons at all. The 0821
review had removed `on_off` as "fictional" by trusting the proxy-protocol
reference, which documents no such capability — but two field-working
switch drivers (kasa-cloud, Hue Scenes) both declare `on_off` true, with
the comment "without this, the light wouldn't show on/off buttons." This
release restores the explicit switch combo (mirroring Hue Scenes), adds
`qty="1"` to `<proxies>`, and extends the light handler with the
remaining kasa-proven commands: plain `ON`/`OFF`, `BUTTON_ACTION`
(remotes/keypads, acting on release), and `RAMP_TO_LEVEL` (routed to
open/close like `SET_BRIGHTNESS_TARGET`). After updating, remove and
re-add the valve driver instance so the new proxy combo takes effect,
then re-pair the cloud link.

Version **2026090822** fixes the valve tile state still not showing
after the 0821 vocabulary fix, with three further proxy-leg repairs
(all cross-checked against the official proxy protocol docs and a
field-working light_v2 switch driver): the 5001 light connection was
declared as type 1 (Control) instead of type 2 (Proxy), so proxy
state never routed — now type 2 with the capabilities block removed
(the switch combo is the documented default set; the previous
`on_off` element is not a real light_v2 capability); the driver now
answers `OnRequestData` and the `GET_LIGHT_LEVEL` / `GET_STATE` /
`GET_BRIGHTNESS_TARGET` queries with the best-known level, since a
connecting navigator that gets no reply times out and resets the
tile to 0; and boot plus light-bind always serve the best-known
level (0 default) so the binding carries a value before the first
push. `SET_BRIGHTNESS_TARGET` also accepts the oldest-API `LIGHT`
param shape. The spike stub carries the same proxy-leg fixes. Cloud
package is a lockstep version bump only.

Version **2026090821** fixes the valve tile state never showing in
Navigator: the driver reported the pre-3.3 `LIGHT_LEVEL` notify, which
light_v2 proxies silently discard. The tile now reports the Level
Target API `LIGHT_BRIGHTNESS_CHANGED` notify (`LIGHT_BRIGHTNESS_CURRENT`
0/100), which the v2 proxy documents as the switch vocabulary, and
`SET_BRIGHTNESS_TARGET` accepts the v2 `LIGHT_BRIGHTNESS_TARGET` param
(with the legacy `LEVEL` fallback kept for targets-unset proxies).
Display restore also moved out of `OnDriverInit` (SendToProxy/Persist
calls violate Director's Safe Usage table there; `OnDriverLateInit`
already re-ran it on the fresh state, so nothing is lost). The spike
stub carries the same protocol fix. Cloud package is a lockstep version
bump only.

Version **2026090820** wires the valve on/off switch to the valve's
closed state: the tile reports OFF exactly when the valve is closed
(a water-off mode flag or flow state 8, "Valve closed") and ON for
everything else. Previously flow state 8 without mode flags showed ON
(and left the Valve Closed contact open) while the Flow State property
literally read "Valve closed". The Valve Closed contact and the Water
Off Detected/Cleared events follow the same closed predicate, so the
tile stays the exact inverse of the contact. Restore tracking stays
mode-based on purpose: a closed valve still has a mode, and ON must
restore the actual current mode rather than a stale one frozen by the
closure. Cloud package is a lockstep version bump only.

Version **2026090819** is a third adversarial-review remediation of the
0812–0816 updater/watchdog changes (6 findings, all fixed and covered).

- Watchdog calibration: the 180s bound equaled the session deadline it
  supervises, so a healthy session's final second could be reaped as
  "stuck". The bound is now 240s — past every legitimate session — and
  the comment no longer claims detection is immediate (it fires on the
  next poll tick past the bound).
- Watchdog freshness: a claiming poll consumes the overdue flag at
  claim time (no duplicate poll on completion, including the watchdog's
  forced poll; breaker/config refusals preserve the debt exactly as
  before), the busy age is clamped against clock steps, and a
  fenced-out late settle can no longer release a fresh owner's busy
  claim (ownership guard; busy stamps clear wherever busy clears).
- Updater honesty: FileSetDir has no documented return convention, so
  every refusal shape with any precedent denies — a raise, an explicit
  false, -1 (Director's sentinel style), or a (nil, err) pair (a
  non-raising denial would otherwise fake-select C4Z_ROOT and replay
  the 0815 no-op) — and the unlock outcome is traced as
  accepted/rejected for field diagnosis. Empty read-backs ("", the
  documented FileRead no-bytes answer) with a verified size now report
  read-back failure instead of "not a driver archive" at both the
  candidate and replacement gates.

Version **2026090818** is a version bump only (no functional change
from 0817) as a further self-update target: run Check for Update /
Install Latest Release from 0816+ and confirm the reload lands on
0818 with `update file store: C4Z_ROOT` in the log.

Version **2026090817** is a version bump only (no functional change
from 0816) to prove the fixed updater end to end: install 0816
manually, then run Check for Update / Install Latest Release and
confirm the reload lands on 0817 with `update file store: C4Z_ROOT`
in the log.

Version **2026090816** fixes the self-update no-op the 0815 field
test caught: the updater staged the new package into the running
driver's own directory, verified it, and triggered — yet Director
reloaded the previously installed build. Root cause: Director's
`UpdateProjectC4i` hot-reload resolves staged packages in C4Z_ROOT
(the controller's driver directory) only, and `FileSetDir` rejects
the C4Z_ROOT alias until an undocumented unlock key passes
(finitelabs/control4-mqtt github-updater pattern, validated on live
OS 3.4.3). Without the key the alias silently fell back to the
package directory. All three file adapters now pass the unlock key
and select C4Z_ROOT with no fallback store — denial refuses the
install with a pointer at the manual path instead of fake-succeeding.
The Director mock models the locked alias, the suite pins
unlock-before-select plus both refusal shapes, and a packaging test
pins the invariant in all three adapter copies. Install this build
manually in Composer (the 0815 updater stages to the wrong store, so
self-update cannot reach it), then self-update onward to prove the
trigger delivers.

Version **2026090815** is a version bump only (no functional change
from 0814) to exercise the self-update path in the field: install
0814 manually, then run Check for Update / Install Latest Release
to confirm the updater downloads, magic-gates, moves, and reloads
0815 end to end.

Version **2026090814** fixes the 0811/0812 field wedge: first boot
crashed in `OnDriverLateInit` at the persisted-epoch read, so the
driver loaded but never initialized — every poll skipped, update
checks silently returned, and Connection stayed blank. Root cause:
Director answers a missing persist key with zero values (not nil),
and the nested `tonumber(C4:PersistGetValue(...))` therefore invoked
`tonumber()` with no arguments, which raises; the `or 0` fallback
never ran, and the crash preceded the epoch write, so every boot
crashed identically. The read now captures into a local before
converting. All three Director mocks model zero-value returns for
missing keys, pinned by first-boot and restart regression tests
(without the fix, 53 of 58 cloud tests fail exactly as the field
did). Install this build manually in Composer: the wedged 0811/0812
updater never runs, so self-update cannot reach it.

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
