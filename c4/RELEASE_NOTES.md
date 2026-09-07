Control4 DriverWorks package for FloLogic Connect valves (OS 3.3.0+).

Update the existing driver through Composer Pro and confirm **Driver Version
2026090708**. Keep existing instances and programming references.

- Report Valve Closed (101) and Away Mode (102) as CONTACT_SENSOR outputs
  instead of RELAY, so programming can detect the reported state directly.
  Binding IDs are unchanged; check existing connections after updating, as
  Director may drop bindings whose class changed.

This build includes the 2026090707 updater corrections (no filesystem
override, unconfirmed-install reporting, closed file handles). The direct
installer's package validation and destructive replacement issues remain
unresolved. Use Composer installation until those issues are addressed.
Neither a Navigator refresh nor adding a second instance verifies an upgrade.
Confirm the running version and `Lua loaded` / `Runtime ready` messages instead.

Offline checks do not establish installation or reload behavior on Director.
