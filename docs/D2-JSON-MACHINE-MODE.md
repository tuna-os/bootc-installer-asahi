# D2 machine-mode contract

The macOS driver starts the forked `asahi-installer` with `--json`. The two
sides then send newline-delimited JSON. This repository owns this contract.
The implementation and its unit tests are in the backend revision that
`scripts/test-backend-contract.sh` pins.

## Framing and routing

- Installer output is one JSON object per line on stdout. Blank lines are
  harmless. Stderr is for diagnostics only.
- The driver sends exactly one JSON answer for the most recent `ask` event:
  `{ "id": "...", "value": ... }`.
- Only one ask is outstanding. The driver must match the answer by `id`, not
  by the order of arrival. It must not answer an old request after a retry.
- The backend validates each answer. The driver must show the messages from
  the backend. It must not have a second parser for APFS or size values.

## Events

Progress and output for the user:

```json
{"event":"message","level":"progress","text":"..."}
```

Questions use these `kind` values: `input`, `password`, `continue`, `yesno`,
`choice`, and `size`. Each question has an `id` and a `prompt`. A `choice`
question also has `options` and an optional `default`. A `size` question has
the `min`, `max`, and `total` bounds in bytes. A size answer uses the backend
grammar (for example `50%`, `20GB`, or `max`). Thus the bounds have one owner.

The last protocol event is exactly one `result`. The backend sends no JSON
event after it:

```json
{"event":"result","status":"success","efiPartUuid":"..."}
{"event":"result","status":"failure","kind":"process","reason":"..."}
{"event":"result","status":"aborted","reason":"..."}
```

The driver reports success only when the last status is `success` and the
subprocess exits zero. A missing result, a non-zero exit, or a different last
status is a failed install. `aborted` means that the user stopped the install.
It is never a success. The EFI PARTUUID is the stable handoff to the
first-boot agent. A macOS device name must not cross this boundary.

A CI check at the process boundary causes a failure in the constructor. Then
it makes sure that the backend sends one failure result and no stdout that is
not JSON. The result must be the last event, and the exit code must not be
zero. This check finds a driver race or a backend exception handler that
can make a partial run look complete.

## Compatibility and safety

The default TTY mode does not change. The backend does these steps: APFS
resize, partition creation, firmware extraction, m1n1 preparation, and bless.
The driver only shows events, collects answers, and reads the last result.
CI pins and checks the contract. If an event field or result rule changes and
the driver does not, the UI can show "installed" for an install that failed.

The full diskutil/bless/bputil path still needs a real Mac with Apple
Silicon. Linux CI proves the protocol layer and the behavior of the last
result after an injected failure. It does not prove a hardware install.
