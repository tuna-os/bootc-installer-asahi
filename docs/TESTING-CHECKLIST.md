# Hardware/Mac testing checklist

For the first real-hardware pass once James is on the MacBook. Ordered
cheapest/lowest-risk first — each step should pass before moving to the next.

## 0. Prerequisites
- Xcode Command Line Tools (`xcode-select --install`) for `swift`/`python3`.
- Clone this repo and `hanthor/asahi-installer` (branch `json-machine-mode`)
  side by side.

**CLT is enough to build, but not to test.** `XCTest.framework` ships inside
`Xcode.app`, not the Command Line Tools, so on a CLT-only Mac `swift build`
succeeds while `swift test` fails with `error: no such module 'XCTest'`. That
is a host toolchain limitation, not a defect in the app — `mac-hardware-smoketest.sh`
now detects it and reports SKIP rather than FAIL. Compile/link correctness is
still covered by `swift build` locally and by the full-Xcode CI runner, which
runs the tests green. To run them locally, install Xcode.app and:
```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## 1. D3 app — does it even launch?
Already CI-verified to compile/link/test on a GitHub macos-14 runner
([`bootsahi-app-build.yml`](../.github/workflows/bootsahi-app-build.yml),
run [30102272271](https://github.com/tuna-os/bootc-installer-asahi/actions/runs/30102272271):
`swift build` clean, 8/8 tests pass, zero warnings). Not yet proven to
actually run.

```sh
cd macos-app/Bootsahi
swift run
```
Expect: a window titled "Bootsahi" showing the welcome screen. This is the
very first real-hardware milestone — if it doesn't get this far, nothing
downstream matters yet.

## 2. D2 backend — one real ask/answer round trip
```sh
cd path/to/asahi-installer/src
python3 main.py --json
```
Expect: one JSON `message` line, then an `ask` line (the "press enter to
continue" `continue` kind at the welcome banner). Answer it manually:
```sh
echo '{"id": "<the id from the ask line>", "value": null}' 
```
piped to its stdin, and confirm it proceeds to the next ask (system
info / disk detection). This proves the protocol layer for real, not just
against the mocked stdin in `src/test_json_mode.py`.

## 3. D3 driving D2 for real
Point `InstallerProcess` (currently hardcoded call sites expect
`pythonPath`/`mainPyPath` to be passed in — there's no settings UI yet) at
the real `python3` + `main.py` from step 2, and confirm the app's own log
view shows the same messages/asks step 2 produced manually, and that
clicking through actually sends working answers back.

## 4. The real gap: install-config.json handoff
Per `macos-app/Bootsahi/README.md`'s biggest open TODO — there is no
defined contract yet for how `install-config.json` gets written onto the
ESP after the backend's `do_install()` finishes creating partitions. Before
attempting a real disk-touching install:
- Decide where in `do_install()` (or a subsequent step) this should happen.
- Decide what partition device info the app needs back from the backend to
  fill in `rootPartition`/`espPartition` in `install-config.json`.
This is a design conversation, not just a bug fix — flag it explicitly
rather than guessing at it under time pressure with a real disk on the line.

## 5. D1 agent — dry run only, not on real hardware yet
`components/bootsahi-agent/bootsahi-agent.sh` is CI-tested
(`test-agent.sh`, 8 assertions, all green) against `/bin/true`/`/bin/false`
stand-ins for fisherman — never against a real `fisherman` binary or a real
disk. Before trusting it on the M1 Air:
```sh
BOOTSAHI_CONFIG_PATH=/path/to/a/real/install-config.json \
BOOTSAHI_NO_REBOOT=1 \
./components/bootsahi-agent/bootsahi-agent.sh
```
with a real `fisherman` binary on `$PATH` pointed at a scratch loop device
or VM disk — **not** the machine's real disk — to prove the `customMounts`
+ `bootloader: "systemd"` recipe it generates actually installs. Build that
binary from **`projectbluefin/fisherman`**, not `tuna-os/fisherman` — the
former is what wootc actually vendors and has real fixes (explicit
`mount -t`, `chroot`-based `useradd`) the latter lacks as of this writing;
see [issue #6](https://github.com/tuna-os/bootc-installer-asahi/issues/6)
for the full comparison.

## 6. Only after 1-5 pass: an actual bootc-Asahi install attempt
This is the M1 Air test loop DESIGN.md refers to. Don't attempt it until
every step above has a real (not mocked, not CI-simulated) pass — a bad
partition table write is not reversible the way a failed `swift build` is.

## Known-broken things to check are fixed by tomorrow (in flight now)
Three arm64 Asahi image builds had real (non-flaky) CI failures, all one
root cause (asahi kernel installed alongside a leftover base-distro kernel,
picked wrong by version-sort) — fixed in
[tuna-os/tunaOS#810](https://github.com/tuna-os/tunaOS/pull/810):
marlin (arch/pacman conflict), flounder (debian/apt leftover kernel),
sailfin (opensuse/zypper leftover module directory). Re-verification builds
were dispatched against the fix branch before this checklist was written —
check that PR's state before relying on any of these three variants'
gnome-asahi images being freshly built and boot-testable.
