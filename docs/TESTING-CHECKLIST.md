# Hardware/Mac testing checklist

> ## 🛑 No destructive hardware install until #19–#24 and #26–#27 are resolved
>
> James's call, 2026-07-25. Non-destructive steps (0–3: build, launch, protocol
> round trips) are fine and several are already green. Anything that writes a
> partition table or runs fisherman against a real disk waits on that set.
>
> Current state of the gate:
>
> | Issue | Subject | State |
> |---|---|---|
> | [#19](https://github.com/tuna-os/bootc-installer-asahi/issues/19) | D1 cannot format the root it runs from | **decided + implemented** ([ADR 0001](adr/0001-bootstrap-partition-layout.md)); real-fisherman run still open (#26) |
> | [#20](https://github.com/tuna-os/bootc-installer-asahi/issues/20) | LUKS silently skipped in manual path | **fails closed** (#29); real support open |
> | [#21](https://github.com/tuna-os/bootc-installer-asahi/issues/21) | Secrets persist on ESP; cleanup not failure-safe | **partly fixed** (#18, #29); one-shot secret channel open |
> | [#22](https://github.com/tuna-os/bootc-installer-asahi/issues/22) | Stable partition identity + ownership checks | **mostly** — see the caveat below |
> | [#23](https://github.com/tuna-os/bootc-installer-asahi/issues/23) | Both units never started | **fixed** (#29) |
> | [#24](https://github.com/tuna-os/bootc-installer-asahi/issues/24) | Signature verification optional | open — cosign is now IN the image (pinned + checksummed), but the policy is still optional |
> | [#26](https://github.com/tuna-os/bootc-installer-asahi/issues/26) | Exercise the recipe with real fisherman | open |
> | [#27](https://github.com/tuna-os/bootc-installer-asahi/issues/27) | Payload contains no agent | **built + verified in CI**; base is still a GNOME image, not minimal |
>
> **What "ready to test for real" still means, concretely.** The bootstrap image
> now exists and the agent has been observed running inside it (20 assertions
> against `/usr/libexec/bootsahi-agent` as shipped, in CI). What has *not*
> happened: the real fisherman has never been run against a real disk from that
> image (#26), so no `bootc install` has ever been performed by this stack. The
> QEMU boot harness (`scripts/test-boot-payload.sh`) is wired into the payload
> job and now finally has a bootstrap worth booting — that is the next thing to
> observe, and it needs no Mac.
>
> **#22 caveat, so the table isn't read as more than it is.** Resolution by
> PARTUUID + role is implemented and covered by a real-GPT-disk test (13
> assertions, four refusal paths against real devices). But the issue also asks
> to refuse "Apple/APFS/recovery partitions" and "unexpected GPT types", and
> the agent does **not** check GPT types at all. It refuses by *provenance*
> instead — the target must be one this install recorded a PARTUUID for, and
> must sit on the same parent disk as our ESP. That is arguably stronger than a
> type check (a type check would happily accept a Linux partition belonging to
> someone else's install), but it is not what was asked, and the two are not
> equivalent for a disk whose recorded identities are stale. Also: the
> attached-second-disk case is covered by the parent-disk check but has **no
> fixture** exercising it.
>
> Also open but outside the gate: [#25](https://github.com/tuna-os/bootc-installer-asahi/issues/25)
> (backend exits 0 on failure, so the app can tell you to bless a failed
> install) and [#28](https://github.com/tuna-os/bootc-installer-asahi/issues/28)
> (kernel selected by version sort can pick a non-Asahi kernel).

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
**Delivery mechanism designed; partition layout still undecided — and the
recipe is NOT yet safe to run against a real disk.** Under the current
two-partition payload, the only Linux partition is the one the agent runs
from, and fisherman would `mkfs` it mid-install. Do not attempt steps 5-6
until the A/B decision below is made and `build_recipe`'s root mount is
updated to match.

See the "handoff" section of
[`docs/UNIFIED-INSTALL-CONTRACT.md`](UNIFIED-INSTALL-CONTRACT.md), written
against the RFC in [issue #6](https://github.com/tuna-os/bootc-installer-asahi/issues/6).
Summary of the answers:
- **Where/when:** `<ESP>/asahi/install-config.json`, delivered through
  asahi-installer's existing `copy_installer_data` →
  `collect_installer_data()` hook, which already runs after partitioning.
  No new mechanism needed.
- **What identifies the partitions:** PARTUUIDs, resolved by the agent at
  runtime. The app supplies **no device fields at all** — it knows the
  partition as `disk0s5` while the agent sees `nvme0n1p5`, so an
  app-supplied device node cannot be correct even in principle.

**One decision still blocks this step (and 5-6 behind it):** fisherman
formats the partition it installs `/` onto, so the bootstrap cannot run
from the target root — but `make-payload.sh` declares only two partitions
(ESP + Root). LUKS makes this unavoidable rather than cosmetic: you cannot
reformat the filesystem you are running from, so encryption is impossible
under the current layout. Pick **A** (three partitions: ESP + small
bootstrap root + expanding target root, the direct wootc Phase-2/Phase-3
analog) or **B** (bootstrap runs from RAM as a live squashfs root). Details
and the discarded option C are in that doc.

## 5. D1 agent — dry run only, not on real hardware yet
`components/bootsahi-agent/bootsahi-agent.sh` is CI-tested
(`test-agent.sh`, 8 assertions, all green) against generated shell stubs
standing in for fisherman — never against a real `fisherman` binary or a
real disk. The stubs are generated rather than borrowed from the host
because the suite originally used `/bin/true` and `/bin/false`, which do
not exist on macOS (it has `/usr/bin/true`); that made both success-path
assertions fail on a Mac for reasons unrelated to the agent, and made the
"fisherman itself fails" assertion pass for the wrong reason. If `$TMPDIR`
is mounted `noexec` the suite now says so and tells you to re-run with
`TMPDIR=$PWD/.tmp`. Before trusting it on the M1 Air:
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
