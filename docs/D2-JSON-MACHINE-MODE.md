# D2 machine-mode contract

The macOS driver invokes the forked `asahi-installer` with `--json` and
communicates over newline-delimited JSON. This file is the contract owned by
this repository; the implementation and its unit tests live in the pinned
backend revision configured by `scripts/test-backend-contract.sh`.

## Framing and routing

- Installer output is one JSON object per line on stdout. Blank lines are
  harmless and stderr is diagnostic only.
- The driver sends exactly one JSON answer for the most recent `ask` event:
  `{ "id": "...", "value": ... }`.
- Only one ask is outstanding. The driver must match the answer by `id`, not
  by arrival order, and must not answer an old request after a retry.
- An answer is validated by the backend. The driver must display backend
  validation messages rather than implementing a second APFS or size parser.

## Events

Progress and user-facing output:

```json
{"event":"message","level":"progress","text":"..."}
```

Questions use `kind` values `input`, `password`, `continue`, `yesno`,
`choice`, and `size`. All include an `id` and `prompt`; `choice` additionally
includes `options` and an optional `default`, while `size` includes byte-valued
`min`, `max`, and `total` bounds. A size answer uses the backend grammar (for
example `50%`, `20GB`, or `max`) so bounds remain authoritative in one place.

The final event is exactly one `result`:

```json
{"event":"result","status":"success","efiPartUuid":"..."}
{"event":"result","status":"failure","kind":"process","reason":"..."}
{"event":"result","status":"aborted","reason":"..."}
```

The driver reports success only when both the final status is `success` and
the subprocess exits zero. Missing results, a non-zero exit, or any final
status other than `success` is a failed install. `aborted` is an intentional
user exit and is never success. The EFI PARTUUID is the stable handoff to the
first-boot agent; a macOS device name must not cross this boundary.

## Compatibility and safety

Default TTY mode remains unchanged. The backend owns APFS resize, partition
creation, firmware extraction, m1n1 preparation, and blessing; the driver
only renders events, collects answers, and observes the terminal result. The
contract is pinned and checked in CI because changing an event field or result
rule without updating the driver can lead to a misleading “installed” UI.

The full diskutil/bless/bputil path still requires a real Apple Silicon host.
Linux CI proves the protocol layer and injected-failure terminal behavior,
not hardware installation.
