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
> | [#24](https://github.com/tuna-os/bootc-installer-asahi/issues/24) | Signature verification optional | **fails closed now** — a missing or half policy is refused, and the install deploys the digest cosign verified rather than the tag. Catalog-side trust policy still to come |
> | [#26](https://github.com/tuna-os/bootc-installer-asahi/issues/26) | Exercise the recipe with real fisherman | **resolved** — real install runs in CI via test-agent-install.sh; real fisherman validates the generated recipe in test-agent.sh; the pinned fisherman revision is enforced across all scripts |
> | [#27](https://github.com/tuna-os/bootc-installer-asahi/issues/27) | Build and boot the actual bootstrap image | **resolved** — bootstrap contents statically verified (test-bootstrap-contents.sh); E2E boot tested opt-in (test-bootstrap-boot.sh, needs qemu + u-boot-qemu); CI install-selftest uses a stand-in for cost but the bootstrap's own selftest path is documented |
>
> **What "ready to test for real" still means, concretely.** The bootstrap image
> exists and its contents are verified statically by `test-bootstrap-contents.sh`
> (all required tools, enabled unit, fisherman version, cosign version). The
> generated D1 recipe is validated by the REAL pinned fisherman at the end of
> `test-agent.sh` and exercised through a full `bootc install` in
> `test-agent-install.sh`. The actual bootstrap image can be built, packaged,
> and booted under qemu with U-Boot via the opt-in `test-bootstrap-boot.sh`
> (needs aarch64 + qemu + u-boot-qemu). What still has *not* happened is an
> install driven from the bootstrap image itself, and nothing has been run on a
> Mac.
>
> **The first real installs failed, and that is the point.** Two separate
> defects, found in sequence, each of which would have bricked an install:
>
> 1. `bootupd is required for ostree-based installs` — the recipe asked for
>    `bootloader: systemd` without `composeFsBackend`, and bootc only honours
>    systemd-boot on the composefs path. Fixed here; the two flags are now
>    asserted as a pair so they cannot drift apart.
> 2. `Filesystem does not support fs-verity` — with composefs enabled, bootc
>    calls `FS_IOC_ENABLE_VERITY` on deployed files, which ext4 refuses unless
>    the feature was set at mkfs time. fisherman's automatic layout passes
>    `-O verity` for exactly this reason; its manual (`customMounts`) layout,
>    the one we must use to install beside macOS, did not. Fixed upstream in
>    [fisherman#70](https://github.com/tuna-os/fisherman/pull/70); the pin here
>    points at that PR until it merges.
>
> Both failed *late* — after the target was formatted and the image deployed
> (65 layers, 909 MB). On a Mac that is a wiped partition next to the user's
> macOS with nothing bootable in it. Every producer-side test passed on that
> recipe and `fisherman validate` accepted it, because it *is* a valid recipe.
> Only executing the install surfaced either one. That is the entire argument
> for #26 existing, demonstrated twice on its first two runs.
>
> **A third failure was the test's fault, not the product's, and it is worth
> recording as a trap.** With the two above fixed, the install got all the way
> to the bootloader step and died with `Failed to open boot loader directory
> /usr/lib/systemd/boot/efi`. `bootctl install` copies systemd-boot's EFI
> binaries out of the *deployed image*, so `bootloader: systemd` is only
> installable if that image ships systemd-boot. `bonito:gnome-asahi` does, and
> installs cleanly. The small PR-time stand-in
> (`quay.io/fedora/fedora-bootc:42`) ships grub2 + bootupd and does not, so the
> PR-time job was structurally unable to pass. The stand-in now gets
> `systemd-boot-unsigned` layered on so it can satisfy the recipe under test.
>
> The trap: this PR originally reasoned that the deployed image does not matter,
> because the code paths under test are fisherman's and are "identical whichever
> bootc image is deployed". That is true of partitioning, `unformatted`
> handling, and staying in-partition, and false of the bootloader step, which
> reads files out of the image. A stand-in has to satisfy the parts of the
> recipe the test intends to execute.
>
> **A fourth failure was also the test's fault: it asserted `/ostree` exists.**
> With the stand-in fixed, the install completed — agent exit 0, all four
> canaries intact, boot entries on the ESP, **2.1 GB deployed to the target** —
> and the test still failed, because it required an `/ostree` directory. The
> target root it actually produced was `boot/ composefs/ lost+found/ state/
> usr/ var/`, with 2.0 GB under `composefs/` and 43 MB under `state/`, and no
> `ostree/` entry at all. Across installs that all worked, `/ostree` has been
> absent (fedora-bootc + systemd-boot), an empty 4 KB stub
> (`bonito:gnome-asahi`), and populated (classic ostree) — so its presence
> carries no information about whether an install succeeded. The deployment
> check is now made on bytes plus a recognized deployment root
> (`state/deploy`, `ostree/deploy`, or `composefs/`), which is what
> fisherman's own `isComposeFsNative` keys on.
>
> The trap, and it is the same shape as the third one: a test that pins itself
> to one backend's on-disk layout reports a healthy install as broken. That is
> not a harmless false alarm here — it trains people to disregard the one test
> standing between them and a wiped macOS partition.
>
> What these runs prove positively, per partition: the ESP keeps its Apple
> `vendorfw/` and m1n1 payload (so `fstype: "unformatted"` really does skip the
> mkfs), the neighbouring macOS stand-in is untouched, the bootstrap partition
> the agent runs from is untouched, the target is formatted, and the ESP gains
> boot entries.
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
binary from **`tuna-os/fisherman`**, which is now synced with
projectbluefin (tuna-os/fisherman#59) and additionally carries the
customMounts validation (#58). It previously had to be built from
projectbluefin/fisherman because our fork lacked the explicit `mount -t` fix;
that workaround is no longer needed.

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
