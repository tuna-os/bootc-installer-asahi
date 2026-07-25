# ADR 0001 — Bootstrap runs from its own partition, not from the target root

Date: 2026-07-25
Status: **Accepted** (decision delegated by James: "do what you think is best")
Resolves the blocking decision in [issue #19](https://github.com/tuna-os/bootc-installer-asahi/issues/19)
and the layout question in [`UNIFIED-INSTALL-CONTRACT.md`](../UNIFIED-INSTALL-CONTRACT.md).

## Context

Three things this project believed simultaneously could not all be true:

1. `DESIGN.md` — a small bootstrap root boots and runs the first-boot agent.
2. `scripts/make-payload.sh` — the payload declares exactly **two** partitions,
   `EFI` and `Root` (`expand: true`). One Linux partition.
3. fisherman — `disk.ApplyCustomLayout()` runs `mkfs` on the partition it
   installs `/` onto (`internal/disk/custom.go:61`).

The agent therefore asked fisherman to format the filesystem containing PID 1
and the agent itself. It should fail as busy; if anything ever let it proceed,
it destroys the environment running the install.

This is the architectural difference from wootc, which runs its deployer from
an initramfs *outside* the target root.

## Options considered

- **A — three partitions.** ESP + a fixed-size bootstrap root + an expanding
  target root. The agent installs into the target; the bootstrap partition is
  reclaimed afterward or kept as a rescue system.
- **B — bootstrap runs from RAM.** Boot the bootstrap as a squashfs/initramfs
  live root, freeing the single Linux partition to be formatted.
- **C — `bootc install to-existing-root`** (in-place, no reformat).

## Decision: A

### Why not C

It bypasses fisherman's formatting entirely, giving up the shared-installer-brain
premise that [RFC #6 §1](https://github.com/tuna-os/bootc-installer-asahi/issues/6)
exists to serve — one schema, one installer, one set of tests across
Windows/macOS/ISO. It also still cannot do LUKS. Rejected.

### Why not B — this is the decisive constraint

A RAM root cannot hold the image pull. fisherman's own code carries the scar
tissue (`internal/install/bootc.go:352-356`):

> the default VFS storage driver copies every image layer byte-for-byte when
> preparing the bootc container, which OOM-kills VMs on large images (>4 GB).
> Probe whether the target scratch filesystem supports overlay and redirect
> podman storage there via `--root`.

fisherman deliberately redirects podman storage **onto disk** to escape exactly
the memory pressure a RAM root would guarantee. On an 8 GB M1 Air, pulling a
multi-GB bootc image into a tmpfs root is the failure mode fisherman was
already fixed once to avoid. B would mean re-fighting a battle upstream has
won, and building a live-root dracut path we don't have.

### Why A

- **The direct wootc analog.** Bootstrap root = wootc's Phase 2 (temporary home
  next to the existing OS); target root = Phase 3 native-disk graduation. RFC
  §1's framing carries over intact rather than by analogy.
- **Real disk for the pull**, which is what fisherman wants.
- **Zero backend changes.** `osinstall.py:79-95` iterates the template's
  partition list generically: a partition with no `format` and no `image` is
  created `%noformat%` and left untouched, and `expand: true` absorbs the
  remaining space. A three-entry template Just Works against upstream
  asahi-installer.
- **Ownership is positively verifiable.** `osinstall.py:82` names each partition
  `"<template name> - <os name>"`, an installer-created GPT label. Combined with
  GPT type and parent-disk identity, that gives the agent a way to prove a
  partition belongs to *this* install before formatting it — which is what
  [#22](https://github.com/tuna-os/bootc-installer-asahi/issues/22) asks for,
  and strictly better than inferring from a partition ordinal.
- **LUKS becomes possible at all.** You cannot reformat the filesystem you are
  running from, so encryption was unreachable under the two-partition layout no
  matter what else changed. (Being *possible* is not being *implemented* — see
  [#20](https://github.com/tuna-os/bootc-installer-asahi/issues/20); the agent
  currently fails closed on any `encryption.type != "none"`.)

## Consequences

Work this decision creates, none of it done yet:

- `make-payload.sh` must emit three partitions, and the bootstrap image must
  stop being a 24 GB desktop image installed into the expanding partition
  (entangled with [#27](https://github.com/tuna-os/bootc-installer-asahi/issues/27):
  the payload today contains no agent at all).
- The agent must **resolve** the target root at runtime and refuse anything it
  cannot prove is the installer-created target — never its own root, never an
  Apple/APFS/recovery partition (#22).
- `build_recipe`'s root mount stays as-is until the above lands. Under the
  current payload it still names the partition the agent runs from.
- The bootstrap partition is dead space after install. Reclaiming it is a
  follow-up; leaving it as a rescue system is a defensible alternative and
  costs a fixed, small amount of disk.

## Not a licence to test on hardware

Per James, no destructive hardware install until **#19–#24 and #26–#27** are
resolved. This ADR resolves #19's *decision*; #19's acceptance criteria
(canaries on the active root, ESP, and neighbours; the real pinned fisherman on
a disposable disk) remain open.
