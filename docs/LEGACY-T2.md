# Bootsahi Legacy — Intel/T2 macOS-to-Linux design

Bootsahi Legacy is the Intel/T2 companion to Bootsahi's Apple-Silicon path.
It deliberately has a different host boundary: a T2 Mac can be stranded on
macOS Catalina, Big Sur, Monterey, Ventura, or later, while the Apple-Silicon
app requires macOS 13. Legacy therefore supports **macOS 10.15 Catalina and
newer** and uses only Foundation/POSIX facilities available on that floor.

## Scope

Supported hardware is the complete T2 Mac set:

- iMac Pro (2017): `iMacPro1,1`
- MacBook Air (2018–2020): `MacBookAir8,1`, `MacBookAir8,2`
- MacBook Pro (2018–2020): `MacBookPro15,1` through `MacBookPro16,4`
- Mac mini (2018): `Macmini8,1`
- Mac Pro (2019): `MacPro7,1`

The installer must reject non-T2 Intel Macs instead of applying a T2 kernel
profile to unsupported hardware.

## Migration flow

```
macOS 10.15+ preflight
  -> verify supported T2 model and a backup/recovery plan
  -> extract Apple Broadcom firmware locally from the installed macOS volume
  -> write a signed x86_64 TunaOS T2 installer USB
  -> boot it after the user enables external boot in Startup Security Utility
  -> bootc install a :t2 image and verify the post-install hardware contract
```

This is USB based rather than an Asahi-style APFS-resize backend. The T2 boot
policy requires the user to change Startup Security Utility settings, and the
legacy frontend must never change partitions or security policy merely by
running a preflight.

## Image contract

Every offered `*-t2` bootc image must pass the T2 hardware gate before it
appears in the legacy catalog. The gate verifies:

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
legacy flow extracts the firmware from that Mac and places the encrypted,
per-install hand-off on the installer media/EFI partition. The T2 bootstrap
consumes it once, installs it into the target deployment, then removes the
handoff. The user may choose Ethernet or USB tethering instead; in that case
the bootstrap can use the documented recovery-image extraction path.

Some iMac/iMac Pro configurations require an existing macOS installation for
firmware extraction, so the legacy UI must strongly recommend preserving the
macOS/recovery partition until the T2 image has completed its hardware check.

## Included preflight

`legacy/bootsahi-legacy` is the Catalina-compatible, non-destructive
preflight entry point. `--json` is stable UI input; its result is
`supported` only for the model identifiers above and macOS >= 10.15.
