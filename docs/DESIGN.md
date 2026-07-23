# TunaOS Asahi Installer — design

*Draft 1, 2026-07-23. The "ultimate challenge": a good macOS-based installer for
bootc Asahi images (all TunaOS variants + Dakota + Bluefin).*

## The core idea: install a bootstrap, not an OS

Every existing asahi-installer distro (Fedora Asahi, Ubuntu Asahi, NixOS) ships
**one zip payload per OS variant** — extracted raw onto the partitions from
macOS. For a family with 10+ variants × desktops × streams, that's a
combinatorial artifact explosion, always stale relative to the registries.

Instead: **one bootstrap payload per architecture, ever.**

```
macOS app ──▶ asahi-installer backend ──▶ writes:
   • stub macOS + per-install ESP (m1n1 boot.bin, U-Boot, systemd-boot/GRUB)
   • "tuna-dive" bootstrap root (~1.5 GB): 16K asahi kernel, dracut-asahi,
     NetworkManager, podman/bootc, fisherman + minimal UI
   • install-config.json (chosen image ref, user, locale, LUKS choice, Wi-Fi)
        ↓ reboot (after the one unavoidable recoveryOS blessing step)
bootstrap boots ──▶ first-boot agent reads install-config.json
   ──▶ bootc install to-filesystem / bootc switch --apply ghcr.io/tuna-os/<variant>:<tag>-arm64
   ──▶ reboots into the real OS; bootstrap root is reclaimed
```

Why this wins:
- **Catalog = the registries.** The macOS app lists variants from a small
  `catalog.json` (generated in CI from registry-map.yaml); new variants/tags
  appear without touching the installer or payloads.
- **The heavy download happens in Linux**, with bootc's resumable, layered,
  signed pulls — not as a giant zip over asahi-installer's plain HTTP.
- **One artifact to maintain, test, and sign.** The bootstrap is small enough
  to boot-test in QEMU on every build (it's just an aarch64 UEFI image).
- Serves TunaOS, Dakota, Bluefin, Bazzite — anyone with a bootc aarch64 image
  ref. This is the shared piece the whole ecosystem lacks.

## Components

### 1. macOS app ("Tuna Dive")
- **Wraps, never reimplements, the asahi-installer Python backend** — APFS
  live-resize, stub macOS creation, per-install ESP, machine-signed m1n1
  stage-1 install, and Apple-firmware extraction to `<ESP>/vendorfw` are
  battle-tested and Apple-fragile. Fork it only to add a `--json` machine
  interface (progress events + answers over stdio) for the GUI to drive.
- SwiftUI shell (native disk pickers, notarization, no runtime deps; the
  audience is by definition on a Mac). Tauri acceptable fallback if team
  prefers web-stack.
- Flow: welcome → catalog (variant/desktop/stream picker, rendered from
  catalog.json) → disk-space slider (APFS resize) → user + Wi-Fi + LUKS
  options (written to install-config.json) → run backend with progress →
  **guided recoveryOS walkthrough** (the one step no software can do: shut
  down, hold power, select the new OS, `bputil`-bless via the terminal
  dialog — illustrated, with a phone-scannable QR to continue instructions
  off-device while the Mac is rebooting).
- Distribution: notarized DMG + `curl | sh` fallback that runs the TUI
  backend directly (keeps CLI parity for servers/CI).

### 2. Bootstrap image ("tuna-dive-boot")
- Built in CI from the leanest asahi-capable base we have — bonito-asahi
  minimal (near-term) or Dakota-asahi minimal (long-term, from-source pride).
- Contents: 16K asahi kernel + Apple DTBs, dracut-asahi (ESP firmware flow),
  NetworkManager + iwd, bootc + podman, greetd + a fisherman-driven
  first-boot UI (tuna-installer-* frontends already exist for the ISO path —
  reuse the contract in INSTALLER-FRONTENDS.md), speakersafetyd (safety even
  in bootstrap), sshd togglable for headless installs.
- First-boot agent: reads install-config.json from the ESP; if Wi-Fi creds
  present, connects; `bootc install to-filesystem` the chosen ref into the
  prepared root partition (or switch-in-place); on failure drops to the
  fisherman UI instead of a black screen. Verifies cosign signatures before
  deploying.
- The asahi-installer payload zip wraps: ESP tree (m1n1 boot.bin + U-Boot +
  bootloader) + the bootstrap root filesystem image + installer metadata.
  Produced by CI (adapt `make-asahi-installer-package.sh`), uploaded to R2
  (download.tunaos.org), referenced by our `installer_data.json`.

### 3. Boot.bin lifecycle (shared engineering, already scoped)
- The installed OS needs the update-m1n1-on-change systemd unit (the piece
  travier/Bazzite also need). Ship it in every asahi image; upstream to
  fedora-asahi-remix-atomic-desktops#2 / bootupd.

## Constraints to design around
- **M1/M2 only** until Asahi supports M3+; the app must detect the SoC
  generation from macOS (`sysctl hw.model` / IORegistry) and refuse politely
  with a link, not fail late.
- macOS ≥ 13.5 host requirement (asahi-installer backend requirement).
- No external boot, no live ISO — this flow is the *only* path onto the
  hardware; polish is not optional.
- The recoveryOS blessing step cannot be automated — invest UX effort there;
  it's where every first-time Asahi user gets lost.
- Never redistribute Apple firmware: extraction happens on-device (backend
  handles it; the bootstrap's dracut module consumes it).

## Milestones
1. **D0** — CI job builds `tuna-dive-boot` (bonito-asahi minimal) + payload
   zip + installer_data.json to R2; manual install with stock asahi-installer
   TUI pointed at our URL; QEMU boot-gate the bootstrap on every build.
2. **D1** — first-boot agent: install-config.json → unattended
   `bootc install` of a chosen ref; headless/ssh path proven (this is also
   how the M1 Air test loop gets provisioned).
3. **D2** — `--json` machine mode upstreamable PR to asahi-installer.
4. **D3** — SwiftUI app driving the backend; notarized DMG; catalog.json
   generation in CI.
5. **D4** — polish: recoveryOS walkthrough UX, LUKS via systemd-repart
   options, Wi-Fi handoff from macOS (SystemConfiguration read of current
   SSID; never the password — user re-enters).

## Open questions for James
- Naming: "Tuna Dive" is a placeholder; fisherman-adjacent naming preferred?
- Repo home: tuna-os/tuna-dive (app + payload CI together, or split)?
- Does the bootstrap adopt fisherman as the first-boot agent directly, or a
  thin dedicated agent that calls bootc? (fisherman reuse keeps one installer
  brain across ISO and Asahi paths — my recommendation.)
