Control4 DriverWorks package for FloLogic Connect valves (OS 3.3.0+).

Update the existing driver through Composer Pro and confirm **Driver Version
2026090707**. Keep existing instances and programming references.

- Remove the unconditional filesystem restriction override from initialization.
  Direct installation may now be denied by Director; use Composer in that case.
- Report an unverified installation attempt as `Installation unconfirmed`,
  rather than claiming that the requested version was installed.
- Close file handles after write or size-query errors.
- Correct the write-failure message: the stored package may be missing or
  incomplete. The previous package is not guaranteed to have been preserved.
- Correct recovery documentation: Force Reinstall targets GitHub's latest
  eligible release, potentially downgrading. It is not a bundled backup.
  Update polling changes properties; the buttons are always present.

The direct installer's package validation and destructive replacement issues
remain unresolved. Use Composer installation until those issues are addressed.
Neither a Navigator refresh nor adding a second instance verifies an upgrade.
Confirm the running version and `Lua loaded` / `Runtime ready` messages instead.

Offline checks do not establish installation or reload behavior on Director.
