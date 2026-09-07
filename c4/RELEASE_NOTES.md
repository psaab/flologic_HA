Control4 DriverWorks package for FloLogic Connect valves (OS 3.3.0+).

Download `flologic_valve.c4z` and use Composer Pro **Driver → Add or Update
Driver…** to update the existing project driver. Confirm **Driver Version**
2026090704 on each installed FloLogic instance. Keep existing instances and
programming references.

- **Actions → Refresh GitHub Updates** checks published C4 releases and updates
  the version/status/download URL. Installation remains through Composer.
- **Connections → Control → Valve Closed** (RELAY binding 101) closes when
  FloLogic reports a shutoff condition, including flow-limit trips.
- **Connections → Control → Away Mode** (RELAY binding 102) closes when an
  away, automatic-away, or external-away flag is active.
- Relays report observed status only. Initial/rebind/recovery sync is quiet;
  later changes send relay transitions. Offline status retains the consumer's
  last indication without manufacturing an open/normal state.

This release adds static connections and updates an action label. Composer
must re-read `driver.xml`; a Lua-only reload cannot register these changes.
Refresh Composer's driver/project metadata after installing if the new
connections or button are missing. Bind the new outputs in Connections.
