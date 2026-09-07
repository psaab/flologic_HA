Control4 DriverWorks package for FloLogic Connect valves (OS 3.3.0+).

Download `flologic_valve.c4z` and update the existing project driver in Composer
Pro. Confirm **Driver Version 2026090705** on each installed FloLogic instance.
Keep existing instances and programming references.

- Match the explicit XML script closing tag in Proflame's working reload
  manifest. This compatibility change still needs verification on Director.
- Publish the running Lua version during both initialization callbacks and log
  load, initialization reason, and runtime readiness even with Debug Mode off.
- Exercise Composer's documented `DIT_UPDATING` destroy/load/init/late-init
  sequence in the Lua regression suite, including automatic polling, preserved
  identity/selection, and rejection of callbacks from the old runtime.

In Lua Output, look for `Lua loaded: 2026090705`, `OnDriverInit`,
`OnDriverLateInit`, and `Runtime ready: 2026090705`. Missing lines identify which
stage needs further investigation; offline tests cannot confirm Composer behavior.

Includes the GitHub refresh action and Valve Closed/Away Mode relay outputs from
2026090704. Install the complete package so Composer reads the XML connections.
GitHub checks provide a download URL; installation remains through Composer.
