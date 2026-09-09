# FloLogic cloud/valve link protocol (unit 1)

Normative wire contract for the cloud-driver/valve-driver split. The
implementation is [`flologic_link.lua`](flologic_link.lua); where this
document and the code disagree, the code wins and this document must be
fixed. Both drivers bundle the same file as their single source of truth
(plan D7). All behavior below is covered by `c4/tests/link.lua`, which both
driver suites run: if `FLOGIC_LINK_VERSION` drifts, every suite fails (D8).

Protocol version: `1` (`FLOGIC_LINK_VERSION`). There is no negotiation:
either side rejects an envelope whose version differs.

## 1. Transport mapping

Primary transport is peer-driver BindMessages (plan D1): the cloud calls
`C4:SendToProxy(slot_binding, name, params, "COMMAND")` and the valve calls
`C4:SendToProxy(LINK_ID, name, params, "COMMAND")`; arrivals enter through
`ReceivedFromProxy`. Each message is one flat params table whose values are
all strings. The `SendToDevice` + `ExecuteCommand` fallback carries the
identical params table, so transport changes never alter this contract.

`NOTIFY` is never used on the link leg. The `LIGHT_BRIGHTNESS_CHANGED`
notify vocabulary belongs to the valve's light proxy, not to this protocol.

## 2. Envelope

Keys (constants `FloLogicLink.K_*`):

| Key | Present on | Meaning |
| --- | --- | --- |
| `FLOGIC_V` | all | Version, wire form `"1"` |
| `FLOGIC_MSG` | all | One of the seven names in section 3 |
| `FLOGIC_BODY` | `IDENTITY`, `STATE`, `COMMAND` | Payload string; `""` elsewhere |
| `FLOGIC_HASH` | `STATE` (always) | Hex digest of the full body (section 6) |
| `FLOGIC_CMD` | `COMMAND`, `CMD_ACK`, `CMD_NACK` | Command correlation id |
| `FLOGIC_TRUNC` | digest-only `STATE` | `"1"` when the body is withheld |
| `FLOGIC_ERROR` | `CMD_NACK` | Human-readable nack reason |

Validation order in `parse`: envelope is a table, else
`envelope-not-table`; numeric `FLOGIC_V` equals `1`, else
`version-mismatch`; `FLOGIC_MSG` is a known name, else
`unknown-message`; `FLOGIC_BODY` (default `""`) is a string, else
`body-not-string`, and fits `MAX_BODY_BYTES` (4096), else
`oversize-body`; then the per-message checks in section 3. Unknown extra
keys are ignored so a newer sender's additive keys never break an older
receiver; every known field is validated strictly.

## 3. Messages

Valve to cloud (leg predicates: `is_valve_to_cloud`):

- `FLOGIC_HELLO` — handshake opener. No body, no identity claim: the
  persisted valve id is never trusted across binds, so hello only announces
  "a valve just bound; tell me who I am".
- `FLOGIC_GET_STATE` — poll for the latest state outside the fan-out.
- `FLOGIC_COMMAND` — one programming action. Requires `FLOGIC_CMD`
  (`bad-cmd-id` when missing/empty/over 64 chars/non-clean) and a body
  field block (section 5) containing `action` (non-empty, at most 64 chars,
  no control characters; `bad-action` otherwise) plus optional flat scalar
  params. A `params` entry named `action` is rejected
  (`param-clash:action`). Builder refuses bodies over budget
  (`command-body-oversize`): commands are small by construction, so
  oversize is a caller bug and is never sent.

Cloud to valve (leg predicates: `is_cloud_to_valve`):

- `FLOGIC_IDENTITY` — handshake answer. Body is the raw valve id string
  for this slot (`bad-valve-id` when empty, over 128 chars, or carrying
  control characters). Numbers are coerced with `tostring`.
- `FLOGIC_STATE` — per-valve snapshot slice (section 4). Full sends carry
  the body plus `FLOGIC_HASH`; digest-only sends carry `TRUNC="1"`, an
  empty body, and the hash of the unseen body (`digest-missing` when the
  hash is absent). A full send whose hash is present but wrong fails with
  `hash-mismatch`; a missing hash on a full send is accepted for forward
  compatibility. The two legs are disjoint: no name appears in both
  directions, so misrouted traffic fails closed.
- `FLOGIC_CMD_ACK` — requires `FLOGIC_CMD`; echoes the command id.
- `FLOGIC_CMD_NACK` — requires `FLOGIC_CMD` and a non-empty
  `FLOGIC_ERROR` of at most 256 chars (`bad-reason` otherwise).

## 4. Handshake and steady-state flows

Bind handshake (prose sequence; plan D3):

1. Director binds the valve link; both sides observe `OnBindingChanged`.
2. The valve sends `FLOGIC_HELLO` on its link id immediately, before any
   other link traffic.
3. The cloud looks up the slot's valve id in its slot-to-valve map. If the
   slot is unmapped it stays silent; otherwise it replies `FLOGIC_IDENTITY`
   with that slot's id on the same slot binding.
4. The valve persists the received id (for display continuity only) and
   waits for state. The cloud starts fan-out pushes for that slot.
5. Every re-bind repeats steps 2-4 from scratch. An unbound valve displays
   "Not linked" and issues nothing.

Steady state: each cloud poll fans one `FLOGIC_STATE` per bound slot out
to that slot only. Between polls the valve may send `FLOGIC_GET_STATE`;
the cloud answers with the latest slice for the requesting slot.

Control flow: the valve builds `FLOGIC_COMMAND` with a fresh `cmd_id`,
forwards one programming action, and waits. The cloud authorizes the
command against its slot-to-valve map, runs it through the valve-tagged
queue, and answers `FLOGIC_CMD_ACK` or `FLOGIC_CMD_NACK` echoing the same
`cmd_id`, followed by a post-command `FLOGIC_STATE` refresh. The valve
correlates the ack/nack by `cmd_id` and never applies state on ack alone:
only a `FLOGIC_STATE` push changes displayed state.

## 5. Field-block codec

`STATE` and `COMMAND` bodies use one canonical encoding
(`encode_fields`/`decode_fields`): a JSON-object subset holding a single
flat object of string keys to string/number/boolean values. Keys match
`^[A-Za-z_][A-Za-z0-9_]*$`, are sorted alphabetically so digests are stable
across drivers, and string escapes cover `"`, `\`, `/`, `b`, `f`, `n`,
`r`, `t`, and `uXXXX` (decoded to UTF-8). The decoder rejects nesting,
arrays, nulls, leading-zero numbers, duplicate keys, raw control
characters, bad escapes, and any trailing data. `{}` decodes to an empty
table; a missing body is not the same as `{}` and fails the shape checks
that need it.

## 6. Digest

`digest` is FNV-1a 32-bit over the body bytes, hex-encoded to 8 lowercase
characters, implemented in dependency-free arithmetic so both drivers and
the lua5.1 suite agree without `C4:Hash`. Vectors: `""` -> `811c9dc5`,
`"foobar"` -> `bf9cf968`, `"hello"` -> `4f9f2cab`.

## 7. valve_state body and byte budget

Required: `id` (string or number, canonicalized to string; non-empty, at
most 128 chars), `mode` (finite number), `online` (boolean). Optional
strings (length-capped): `uuid` (128), `name` (128), `device_type` (64).
Optional finite numbers: `flow_state`, `home_interval`, `away_interval`,
`bypass_time`, `access` (account notification bitmask slice),
`updated` (snapshot unix time). Any other key fails the build and the
parse (`unknown-state-field:*`) so a renamed cloud field fails loudly
instead of dropping silently. Production cloud builds currently omit
`access` (no downstream consumer reads it); the key stays reserved so a
future valve feature can adopt it without a protocol bump.

Budget: `MAX_BODY_BYTES` is 4096. Worst case measured by the suite
(`link: worst-case full state fits the byte budget`, lua5.1, 2026-09-08):
a state with every field present at maximum length/value encodes to
**530 bytes**, about 13% of budget, leaving 3566 bytes of headroom. A
representative live slice (id, uuid, short name, mode, online, flow,
intervals, access) is 194 bytes. The digest fallback therefore only
triggers for pathological inputs that cannot arise from capped cloud data;
it exists so such an input degrades the link instead of wedging it.

Digest-fallback behavior: `build_state` emits `TRUNC="1"` with an empty
body and the full body's hash. A valve receiving digest-only state keeps
its last full state, marks the link degraded (stale-link display in unit
3), and may retry with `FLOGIC_GET_STATE` under its own backoff; the cloud
re-attempts the full send each time. Retries are valve-paced so a
persistently oversized state cannot create a hot loop.

## 8. Error catalog

Builder errors (returned as `nil, err`, never raised): `fields-not-table`,
`bad-field-key`, `bad-field-value:*`, `state-not-table`, `bad-state-id`,
`bad-state-mode`, `bad-state-online`, `bad-state-field:*`,
`unknown-state-field:*`, `bad-valve-id`, `bad-cmd-id`, `bad-action`,
`params-not-table`, `param-clash:action`, `bad-param-key`,
`bad-param-value:*`, `command-body-oversize`, `bad-reason`,
`digest-needs-string`. Parse errors: `envelope-not-table`,
`version-mismatch`, `unknown-message`, `body-not-string`,
`oversize-body`, `bad-hash`, plus the per-message errors above and
`digest-missing`, `hash-mismatch`, and the codec/state errors
(`not-an-object`, `unsupported-value`, `bad-number`, `trailing-data`,
`duplicate-key`, `expected-string/colon/separator`, `bad-escape`,
`bad-unicode-escape`, `raw-control-char`, `unterminated-string`).

## 9. Conformance

`c4/tests/link.lua` pins every behavior above: version and disjoint
direction sets, digest vectors, per-message round trips, `cmd_id`
correlation through a scripted hello/identity/state/command/ack exchange,
rejection of each malformed shape, version mismatches (`"2"`, `"0"`,
`"x"`, `""`, missing), the oversize rejection and digest-only branches,
and the worst-case sizing assertion that prints the measured body size on
every run. Units 2-3 import this module and must fail if
`FLOGIC_LINK_VERSION` drifts.

