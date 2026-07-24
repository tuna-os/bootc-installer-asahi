# Tuna Dive (macOS app) — SKELETON, partially CI-verified

D3 from [`docs/DESIGN.md`](../../docs/DESIGN.md): a SwiftUI app driving the
forked asahi-installer backend
([`hanthor/asahi-installer@json-machine-mode`](https://github.com/hanthor/asahi-installer/tree/json-machine-mode),
D2) over its `--json` stdio protocol
([`docs/json-mode.md`](https://github.com/hanthor/asahi-installer/blob/json-machine-mode/docs/json-mode.md)).

**Written with no local Swift toolchain** — no macOS host in the environment
that produced it. It was, however, subsequently built and tested for real on
a GitHub-hosted `macos-14` runner (Xcode 15.4, Swift 5.10) via
[`tuna-dive-app-build.yml`](../../.github/workflows/tuna-dive-app-build.yml)
(dispatch manually with `gh workflow run tuna-dive-app-build.yml --ref
feat/d3-tuna-dive-app-skeleton`, or check the Actions tab): **`swift build`
succeeds and all 8 tests in `BackendEventDecodingTests` pass**, with zero
compiler warnings. That proves the Codable models, the protocol round-trip,
and the SwiftUI view graph all type-check and link. It does **not** prove:
the app actually launches and shows a window, `InstallerProcess` correctly
drives a real `python3 main.py --json` subprocess, or any of the recoveryOS/
disk/Wi-Fi flows behave right on real hardware — none of that is exercised
by `swift build`/`swift test` in CI.

## First things to do on the real Mac

1. `cd macos-app/TunaDive && swift run` — confirm the app actually launches
   and the welcome screen renders (CI proves it compiles, not that it runs).
2. Point `InstallerProcess` at a real `python3` + the fork's `src/main.py`
   and confirm one real `ask`/`answer` round-trip before building out the
   rest of the flow.

## What exists

- `Models/` — `BackendEvent`/`BackendAsk`/`BackendMessage`/`JSONValue`
  mirror `docs/json-mode.md` exactly (by hand — no shared schema/codegen
  with the Python side yet). `InstallConfig` mirrors
  `components/tuna-dive-agent/install-config.schema.json` in this same repo
  (also by hand, also needs to be kept in sync manually).
- `Backend/InstallerProcess.swift` — spawns `python3 main.py --json`,
  streams stdout line-by-line into decoded `BackendEvent`s, writes
  `BackendAnswer` lines back to stdin.
- `ViewModel/InstallFlowViewModel.swift` — the wizard state machine.
- `Views/` — one view per step (welcome, catalog, options, disk-slider/
  progress, recoveryOS walkthrough).

## What's deliberately left as a TODO, not invented

- **Where `python3` comes from at runtime.** asahi-installer's own
  `install.sh` already solves this for the curl-|-sh path (provisions a
  venv); TunaDive should probably reuse that rather than bundling a Python
  runtime. Not decided — see the comment in `InstallerProcess.swift`.
- **catalog.json generation in CI.** `Resources/catalog.json` is a single
  hand-written placeholder entry. The real thing (generated from
  registry-map.yaml, per DESIGN.md) doesn't exist yet.
- **The install-config.json handoff.** The forked backend creates the
  target partitions (stub macOS, ESP, root) but has no reason to know about
  `install-config.json` — it only ever installs the single "tuna-dive-boot"
  bootstrap OS. Something (this app, or a small addition to the fork) needs
  to write `install-config.json` onto the newly-created ESP once the
  backend's `do_install()` completes, using whatever partition devices it
  reports back. That reporting contract doesn't exist yet — `docs/DESIGN.md`
  and `docs/json-mode.md` don't specify it, and this skeleton doesn't
  either. This is probably the single biggest remaining design gap between
  D2 and D3/D1 actually working end to end.
- **SoC-generation gate** (M1/M2 only, refuse M3+ politely) —
  `WelcomeView.swift` has a TODO comment; not implemented.
- **Wi-Fi SSID prefill from the current macOS network** (DESIGN.md D4,
  `SystemConfiguration`) — `OptionsView.swift` has a plain manual field.
- **Real disk-space slider bytes**, notarization, and the recoveryOS
  walkthrough's actual illustrations/QR code — all D4 polish, not attempted
  here beyond a labeled placeholder.
