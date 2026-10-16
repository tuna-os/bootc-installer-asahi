# Bootsahi Legacy — Intel Mac macOS-to-Linux design

Bootsahi Legacy is the Intel-Mac companion to Bootsahi's Apple-Silicon path.
It has a different host boundary: an Intel Mac can be stranded on macOS High
Sierra, Mojave, Catalina, or a later release, while the Apple-Silicon app
requires macOS 13. Legacy therefore supports **macOS 10.13 High Sierra and
newer** and uses only Bash 3.2 and POSIX facilities available on that floor.

## Status

Only the preflight (`legacy/bootsahi-legacy`) is implemented. The firmware
extraction, USB writer, and legacy installer UI described below are design
and do not exist yet.

## Scope

All Intel Macs on macOS 10.13 or newer are accepted. Recognized T2 Macs
select the dedicated `t2` image profile. All other Intel Macs select the
`generic-intel` profile, which uses the normal x86_64 TunaOS images.

The recognized T2 set is:

- iMac (2020): `iMac20,1`, `iMac20,2`
- iMac Pro (2017): `iMacPro1,1`
- MacBook Air (2018–2020): `MacBookAir8,1`, `MacBookAir8,2`, `MacBookAir9,1`
- MacBook Pro (2018–2020): `MacBookPro15,1` through `MacBookPro16,4`
- Mac mini (2018): `Macmini8,1`
- Mac Pro (2019): `MacPro7,1`

The installer must never apply the T2 kernel profile to a Mac outside this
set.

## Migration flow

```
macOS 10.13+ preflight
  -> select the generic-intel or t2 profile and confirm a backup/recovery plan
  -> t2 only: extract Apple Broadcom firmware locally from the installed macOS volume
  -> write an x86_64 TunaOS installer USB (the T2 installer for the t2 profile)
  -> t2 only: boot it after the user enables external boot in Startup Security Utility
  -> bootc install the selected image and verify the post-install hardware contract
```

This is USB based rather than an Asahi-style APFS-resize backend. The T2 boot
policy requires the user to change Startup Security Utility settings, and the
legacy frontend must never change partitions or security policy merely by
running a preflight.

## Image contract

Generic Intel images keep their normal hardware gate. Every offered `*-t2`
bootc image must also pass the T2 hardware gate before it appears in the
legacy catalog. The T2 gate verifies:

1. x86_64 UEFI boot and the T2 kernel/driver stack (keyboard, trackpad,
   internal SSD, audio, camera, Touch Bar where present, and fan control);
2. `brcmfmac` is used for internal wireless — **never** `broadcom-wl`;
3. a locally extracted firmware payload is installed at the standard
   `/usr/lib/firmware/brcm` location before NetworkManager is started;
4. iwd is selected as the NetworkManager Wi-Fi backend where required; and
5. the chosen image can complete an unattended `bootc install` to a T2
   target disk.

The kernel and supporting packages are versioned in the image recipe, not
downloaded ad hoc by the installed system. This gives users an atomic,
bootc-managed hardware stack while allowing the project to update package
sources without changing the macOS application.

## Firmware is an on-device hand-off

Apple's Broadcom firmware may not be redistributed. Therefore it is not part
of a public TunaOS image, release asset, or registry layer. On macOS the
legacy flow extracts the firmware from that Mac and places a local,
per-install hand-off on the installer media/EFI partition. The T2 bootstrap
consumes it once, installs it into the target deployment, then removes the
hand-off. The user may choose Ethernet or USB tethering instead; in that case
the bootstrap can use the documented recovery-image extraction path.

Some iMac/iMac Pro configurations require an existing macOS installation for
firmware extraction, so the legacy UI must strongly recommend preserving the
macOS/recovery partition until the T2 image has completed its hardware check.

## Included preflight

`legacy/bootsahi-legacy` is the non-destructive preflight entry point. It
runs on the macOS 10.13 Bash 3.2. `--json` is the stable UI interface: it
reports `supported` for Intel Macs on macOS 10.13 or newer, otherwise
`unsupported` with a reason, and a `profile` of `generic-intel` or `t2`.
Without `--json` it prints a human-readable result and exits 1 when the Mac
is unsupported.
