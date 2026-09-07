Control4 DriverWorks package for FloLogic Connect valves (OS 3.3.0+).

Update the existing driver through Composer Pro and confirm **Driver Version
2026090709**. Keep existing instances and programming references.

- Harden the self-updater's install gate: the store lookup now tries the
  documented `.c4i` proxy-name form first, then the bare proxy name, then the
  package filename, so no single wrong guess can report "not installed".
- Stage through the documented `C4Z` file alias when the proflame-style
  `C4Z_ROOT` alias is denied.
- Probe every plausible `C4:Hash` call shape (documented 3-argument raw form
  plus 2-argument raw/hex), so handshake digests survive API differences.
- Never hand the live hub or Composer network binding to a second user, and
  release bindings closed before connecting instead of retiring them into a
  slow pool leak.
- Match Home Assistant fetch tolerance: cloud error notices, undecodable or
  malformed frames, and binary frames no longer abort a poll, and an access
  timeout degrades instead of blanking the snapshot. Pushed valves merge
  into a live inventory.
- Verified against the published DriverWorks API reference: timer, hash,
  transfer, file, TLS, UUID, and contact-notify contracts. The README's
  Director acceptance checklist lists the behaviors that still need a real
  controller (install trigger end to end, `STATE_*` sync semantics).

This build includes the 2026090708 contact-sensor outputs and the 2026090707
updater corrections. The direct installer's package validation and safe
replacement issues remain unresolved; prefer Composer installation. Neither
a Navigator refresh nor adding a second instance verifies an upgrade.
Confirm the running version and `Lua loaded` / `Runtime ready` messages instead.

Offline checks do not establish installation or reload behavior on Director.
