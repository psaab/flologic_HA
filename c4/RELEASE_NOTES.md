Control4 DriverWorks package for FloLogic Connect valves (OS 3.3.0+).

Version **2026090801** is the split-driver release: one `FloLogic Cloud`
account coordinator (`flologic_cloud.c4z`) plus one `FloLogic Water
Valve` companion per valve (`flologic_valve.c4z`), both under this
tag at one lockstep version. New installs start with the split drivers;
see [SPLIT_README.md](SPLIT_README.md) for the install/bind guide and
manual migration from the monolith. The valve driver requires OS 3.3.2+
for the app-tile click; the cloud driver runs on 3.3.0+. The valve package
intentionally reuses the legacy monolith filename, so installed monoliths
will offer it as an update: do NOT install it over a monolith instance —
migrate manually instead (delete the monolith, add cloud + valves, rebind
programming). Both new drivers self-update from GitHub releases, each
tracking only its own asset.

Monolith owners: the legacy single-driver line ended at Driver Version
2026090709; its notes stay on the older release tags. This tag carries
only the split drivers.
