Control4 DriverWorks package for FloLogic Connect valves (OS 3.3.0+).

Download `flologic_valve.c4z` and use Composer Pro **Driver → Add or Update
Driver…** to update the existing project driver. Confirm **Driver Version**
on each installed FloLogic instance. Keep the existing instance, credentials,
valve selection, and programming references.

This build fixes hot reload by retiring old timers, HTTP requests, sessions,
and module references before initializing the replacement runtime. It adds
report-only GitHub release checks under **Actions → Check for Update**,
with **Update Status**, **Latest Driver Version**, and **Update Download URL**.
Scheduled checks default to every 24 hours; interval 0 disables periodic checks.

The updater reports and links available releases; installation is performed
with Composer. This build does not include Proflame's restricted-storage
bypass or an in-driver installer.

This release adds static Composer properties/actions. Refresh Composer's
driver metadata after installation if the new fields are missing. A Lua-only
reload cannot register XML additions. Confirm the version before testing login.
