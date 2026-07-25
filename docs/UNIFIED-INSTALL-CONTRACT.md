# Unified install contract — draft spec (responds to issue #6 §1)

Status: **first draft, not agreed**. Written to make issue #6's proposal
concrete enough to react to, not to settle it. Corrects one oversimplification
in the RFC text along the way (see "What wootc actually does" below).

## What wootc actually does

The RFC describes wootc's contract as a single `vault.json` matching
`install-config.json`'s shape. In the real code
(`app/vault_windows.go`, `app/installer_windows.go`) it's split across
**three channels**, not one file:

1. **`vault.json`** (`0o600`, ACL-restricted to SYSTEM/Administrators) —
   only `username`, `hostname`, `image`, `password_hash`. The password is
   hashed with `sha512_crypt` (`$6$...`) **before** the file ever touches
   disk; plaintext never lands anywhere.
2. **Bootloader-entry kernel cmdline args** — `wootc.image=`,
   `wootc.hostname=` (duplicated from vault.json — readable before NTFS is
   even mounted), `wootc.bootloader=`, `wootc.luks=<encryption-type>`.
3. **fisherman's `recipe.json`**, assembled by the deployer script from (1)
   and (2) at runtime, not written by the Windows app directly.

This split exists because of a real Windows constraint: the deployer
initramfs needs some config (image ref, LUKS type) available from
`/proc/cmdline` *before* it has mounted anything, while richer config
(username, password hash) can wait until the NTFS volume holding
`vault.json` is mounted.

## Why Asahi doesn't need the split

`install-config.json` already lives on the ESP (per `DESIGN.md`), and the
bootsahi bootstrap mounts the ESP as one of its first actions regardless
(it needs `<ESP>/m1n1/boot.bin` and the bootstrap root itself lives there
too) — there's no "before any mount" phase analogous to wootc's Windows
cmdline trick where a single JSON file doesn't already work. **Recommend
keeping Asahi's contract as the single-file `install-config.json`** already
specified in `components/bootsahi-agent/install-config.schema.json` —
simpler, and wootc's split is solving a problem Asahi doesn't have, not a
pattern worth importing for its own sake.

## What to actually converge on

Not the file split — the **field shapes and security conventions**, since
fisherman's `recipe.json` is the true shared contract underneath both:

| Concern | wootc | Asahi (current) | Converge? |
|---|---|---|---|
| Password | `$6$` hash, hashed client-side, `password_hash` field | plaintext `password` field | **Yes** — see below |
| Image ref | `image` | `targetImgref` | No — Asahi's name is clearer (wootc's `image` is also the *current* value in other structs); not worth a rename fight |
| LUKS type | `Encryption` string (`none`/`tpm2-luks`/...) on `InstallConfig`, forwarded as `wootc.luks=` cmdline | `encryption.type` object | Already aligned in spirit; Asahi's object form is finer-grained (carries `passphrase` alongside `type`) and should stay |
| Hostname | `hostname` | `hostname` | Already aligned |

**Concrete action taken in this PR:** `install-config.schema.json`'s
`user.password` field now documents the `$6$`-hash convention explicitly
(fisherman's `chpasswd` step — `projectbluefin/fisherman` only, see below —
already auto-detects a `$`-prefixed value and passes `chpasswd -e`; a plain
string is also accepted but means the password sat in the file in the clear
until install completed). The macOS app should hash client-side the same
way `vault_windows.go` does, before `install-config.json` is ever written to
the ESP.

## A real, non-hypothetical blocker found while writing this

`components/bootsahi-agent` was built against `github.com/tuna-os/fisherman`.
wootc actually vendors `github.com/projectbluefin/fisherman`, which is **six
days ahead** (as of this writing) and has two fixes `tuna-os/fisherman`
lacks entirely:

- **`MountType`** — an explicit `mount -t <fstype>` for the freshly-formatted
  root. Without it, the deployer initramfs (no libblkid probe path) can
  attempt an xfs root as ext4 and fail outright. The Asahi dracut/initramfs
  likely has the same no-probe property (unverified — needs an aarch64
  re-check, tracked in the hardware testing checklist).
- **`chroot <target> useradd`** instead of **`useradd --root <target>`** —
  `--root` also initializes the *host's* PAM/SELinux stack and fails against
  a target whose `/etc` is otherwise perfectly writable (proven on
  bluefin:lts per wootc's fisherman fork commit history).

`bootsahi-agent`'s README and the hardware testing checklist have been
updated to point at `projectbluefin/fisherman` accordingly. This should be
fixed before any real-disk testing, not after — these are exactly the kind
of failures that only show up once you're not on a mocked stdin.

## The handoff: how install-config.json reaches the ESP

*(Added after reading fisherman and asahi-installer source. This is
testing-checklist step 4, the item blocking every real-disk step. It also
corrects the section above — see "Correcting my own §1 recommendation".)*

### The question

`install-config.json` carries `rootPartition` and `espPartition`. The macOS
app cannot know those until the backend has partitioned the disk, and the
backend partitions the disk during the install run. So: who writes the file,
where, when, and what identifies the partitions?

### Option "backend hands device nodes back" is not merely awkward — it is impossible

The app runs on macOS, where the partitions it just created are named
`disk0s5`. The agent runs on Linux, where the same partition is
`nvme0n1p5`. **A device node learned on macOS is meaningless to the agent**,
so no amount of plumbing device nodes back to the app produces a usable
value. This isn't a preference between two workable designs; it eliminates
one of them.

### Both channels this needs already exist upstream

1. **A post-partition write hook.** `installer_data.json`'s EFI partition
   entry already sets `copy_installer_data: true`, which makes
   `osinstall.py:169` register `<ESP>/asahi/` as a target, and
   `main.py:596` calls `collect_installer_data()` over those targets —
   **after** `osins.install()` has created and mounted the partitions. Files
   are copied from `stub.py`'s `copy_idata` list, and `stub_info.json` and
   `installer.log` are written there too. Adding `install-config.json` is an
   append to that list, not a new mechanism.
2. **A partition identifier that crosses OS boundaries.** Every
   `diskutil.py` partition object carries its GPT UUID
   (`uuid=partinfo["DiskUUID"]`, `diskutil.py:134`), and asahi-installer
   *already* threads the ESP's into the boot chain:
   `chosen.asahi,efi-system-partition=<uuid>` and
   `chainload=<uuid>;<next_object>` (`osinstall.py:189-192`). It even prints
   it to the user as "EFI PARTUUID" (`main.py:731`). **PARTUUID is already
   this stack's identity currency** — stable across macOS/Linux and immune
   to partition renumbering.

### Proposed contract

Split by *who knows what, and when*:

| Channel | Written by | When | Contents |
|---|---|---|---|
| `<ESP>/asahi/install-config.json` | macOS app → backend's `copy_idata` | after partitioning, by the existing `collect_installer_data()` hook | **intent only**: `targetImgref`, `user` (with `$6$` hash), `hostname`, `filesystem`, `encryption`, `wifi`, `cosign*`, `sshEnabled` |
| `<ESP>/asahi/stub_info.json` (existing file, extra keys) | backend | same hook | **facts only the backend knows**: ESP and target-root **PARTUUIDs** |

### Credential lifetime on the ESP (the channel is not a safe resting place)

The channel table above says *where the file goes*; it also has to say *how
long it lives*, because the ESP is a bad place to keep secrets:

- It is **vfat** — no permission bits. Nothing can be `0o600` there, unlike
  wootc's `vault.json`, which is `0o600` and ACL-restricted to
  SYSTEM/Administrators on NTFS.
- It is **not** tmpfs (unlike the agent's `RUN_DIR`), and it stays mounted
  at `/boot/efi` on the installed system indefinitely.
- The password travels as a `$6$` hash, which is the point of that
  convention — but the **LUKS passphrase and Wi-Fi PSK cannot be hashed**,
  because they have to be usable. They are necessarily plaintext-equivalent.

Leaving the file in place would publish the disk-encryption passphrase, in
the clear and world-readable, on the machine we just encrypted. So the
contract is: **the agent removes `install-config.json` on a successful
install**, in the same place it already shreds `recipe.json` — and
deliberately *preserves* it on failure, since the interactive fisherman UI
it falls back to has nothing to retry from otherwise. Both directions are
asserted by `test-agent.sh`.

(`shred` is best-effort and largely theatre on vfat over wear-levelled
flash; removal is the part that carries the weight. Worth noting rather than
pretending otherwise.)

### The app writes no device fields at all

So: **the app writes no device fields at all.** `rootPartition` and
`espPartition` stop being app-supplied inputs and become values the agent
resolves at runtime from `/dev/disk/by-partuuid/<uuid>`. They should leave
`required` in the schema and be retained only as an explicit dev/test
override (which is exactly how `test-agent.sh` uses them today).

### Correcting my own §1 recommendation

The section above concluded "Asahi doesn't need wootc's split" because
Asahi has no pre-mount phase forcing config onto the kernel cmdline. That
reasoning was right about the **file** and wrong about the **boundary**.

wootc's split is not primarily an early-mount hack — it is a *separation of
knowledge*: the host app writes what it knows before touching the disk, and
the runtime resolves what only the runtime can know. Asahi needs that same
boundary for exactly the reason wootc needed it, even though Asahi can keep
one file on one channel. Recommendation stands (single JSON file, converge
on field shapes and the `$6$` convention); the correction is that the
device-identity fields belong on the runtime side of the line, not in the
app's file.

### The blocking constraint: fisherman formats `/`

Reading `tuna-os/fisherman` turned up something that has to be settled
before any of the above can be implemented. `disk.ApplyCustomLayout()`
(`internal/disk/custom.go:61`) runs `mkfs` on every custom mount whose
fstype isn't `unformatted`/`""` — including `/`. Three things currently
believed simultaneously cannot all be true:

- `DESIGN.md`: a ~1.5 GB bootstrap root boots and runs the agent.
- `scripts/make-payload.sh`: the payload declares exactly **two**
  partitions — `EFI` and `Root` (`expand: true`). One Linux partition.
- fisherman: formats the partition it installs `/` onto.

**You cannot mkfs the filesystem you are running from.** And this is not
just a layout tidiness question — **LUKS forces it**. Encrypting the root
means reformatting it as a LUKS container, which is impossible in place, so
encryption cannot work at all under the current single-partition layout,
whatever else changes.

Options, for James to pick:

- **A — three partitions.** ESP + a small fixed-size bootstrap root + the
  target root (`expand: true`). The agent installs into the target root and
  the bootstrap partition is reclaimed afterward (or kept deliberately as a
  rescue system). This is the direct wootc analog: bootstrap root = Phase 2,
  target root = Phase 3 native-disk graduation. Needs only a
  `make-payload.sh` change, and the agent resolves "the Linux partition that
  isn't the one I'm running from" — or better, reads the target's PARTUUID
  from the backend per the table above.
- **B — bootstrap runs from RAM.** Boot the bootstrap as a
  squashfs/initramfs live root, leaving the single Linux partition free to
  be formatted. Cleaner on disk and keeps the two-partition layout, but
  needs a live-root dracut path built new on this side.
- **~~C — `bootc install to-existing-root`~~** (install in place, no
  reformat). Discarded: it bypasses fisherman's formatting entirely, and so
  gives up the shared-installer-brain premise that RFC §1 exists to serve —
  and still cannot do LUKS.

A vs B is a real trade (one payload script change vs. a cleaner disk
layout), and everything downstream of testing-checklist step 4 waits on it.

**Decided: option A** — see [ADR 0001](adr/0001-bootstrap-partition-layout.md).
The payload now emits three partitions.

The generated recipe is still not *correct* — `build_recipe` emits
`rootPartition` verbatim, and nothing resolves it to the installer-created
target yet (that is #22). But since ADR 0001 the disk carries two Linux
partitions, which made a wrong value *plausible* rather than obviously bogus,
so the agent now positively refuses the catastrophic ones: a `rootPartition`
or `espPartition` that resolves to the device backing `/`, or the two being
the same device. Compared by `major:minor` via `/proc/self/mountinfo`, so
`/dev/nvme0n1p5` and `/dev/disk/by-partuuid/...` aren't mistaken for different
devices.

The original hazard, for the record: `build_recipe`
emits the root mount as `{ partition: $c.rootPartition, target: "/", fstype:
$c.filesystem }`, and under the current two-partition payload the only Linux
partition *is* the one the agent is running from. fisherman would `mkfs` it
mid-install. That is not deferred cleanup; it is a live hazard, and it is why
the root mount is left untouched here rather than "fixed" to something
plausible. The correct value is a function of which layout wins.

### Two live bugs found while writing this

Both in the recipe `bootsahi-agent` generates, both invisible to the
selftest as it stood, both fixed in the same PR as this document:

1. **The ESP mount specified `fstype: "vfat"`, which fisherman does not
   accept.** `recipe.Validate()` doesn't check `customMounts` fstypes
   (`internal/recipe/recipe.go:148-166`), so it passes validation and then
   fatals inside `formatPartition()` — whose switch knows `fat32`, not
   `vfat`. **This recipe has never been valid**; it would have died at
   fisherman step 1 on the first real run.
2. **The obvious fix is the dangerous one.** Changing it to `fat32` makes
   `ApplyCustomLayout` run `mkfs.fat -F32` on an ESP that by then holds
   `m1n1/boot.bin`, the bootloader, `stub_info.json`, and `vendorfw/` — the
   Apple firmware extracted on-device, which is not redistributable and
   therefore cannot be restored from anywhere. That is a DFU-restore-grade
   mistake. The correct value is **`unformatted`**, which skips only the
   `mkfs`; the mount and the `efiPart` bookkeeping fisherman needs for the
   boot entry both still happen (`custom.go:68-86`).

The selftest now asserts every `customMounts` fstype is in
`formatPartition`'s accepted set, and separately that the ESP's is a
skip-format token. Both assertions were verified to fire against the old
`vfat` value. The gap that let this through is worth naming: the previous
shape checks grepped that a `/boot/efi` mount *existed*, never what it
would *do*.

### Also confirms RFC §5's `MountType` landmine, with a line number

`custom.go:85` is `runner.Run("mount", s.Partition, hostTarget)` — no
`-t`. That is precisely the missing-explicit-type bug §5 describes, live in
`tuna-os/fisherman` today, and already fixed in
`projectbluefin/fisherman`. It strengthens the existing recommendation to
build from the projectbluefin fork.

## One correction to issue #6 §5

The RFC lists the clevis/dracut-omit landmine under "already fixed for you"
in the shared fisherman. It isn't — it lives in **wootc's own deployer
script** (`payload/deployer/deploy.sh`'s `DRACUT_OMIT` handling), a
post-install dracut regen step wootc runs that `bootsahi-agent` doesn't
currently have an equivalent of. Not urgent today (D1 has no dracut-regen
step yet), but worth a comment marker if/when Asahi's agent ever grows one.
