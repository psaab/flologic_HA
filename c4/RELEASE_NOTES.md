Control4 DriverWorks package for FloLogic Connect valves (OS 3.3.0+).

Download `flologic_valve.c4z` and update the existing project driver in Composer
Pro. Confirm **Driver Version 2026090706** on each installed FloLogic instance.
Keep existing instances and programming references.

- **Install Latest Release** action: downloads the newest GitHub release to
  controller staging storage, verifies its size, then applies it and refreshes
  the project item so the new Lua loads without deleting the instance.
- **Force Reinstall** action: reinstalls the driver's bundled build even when
  no newer release exists, restoring a known-good copy.
- Both actions are cancellable and report progress through the Update Status
  property; automatic release polling continues to enable the install action
  when a newer build appears.
- If Director does not pick up the refreshed file automatically, run Refresh
  Navigators or re-add the driver instance without deleting programming.

In Lua Output, look for `Lua loaded: 2026090706`, `OnDriverInit`,
`OnDriverLateInit`, and `Runtime ready: 2026090706`. Missing lines identify which
stage needs further investigation; offline tests cannot confirm Composer behavior.

Install the complete package so Composer reads the XML connections and actions.
