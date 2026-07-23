#!/usr/bin/env bash
# asahi-bootbin-sync — keep <ESP>/m1n1/boot.bin current on bootc/ostree systems.
#
# On dnf systems RPM %posttrans triggers run update-m1n1 when m1n1/U-Boot/DTBs
# change. bootc deploys never run package scriptlets on the machine, so nothing
# regenerates boot.bin after `bootc upgrade` — new kernels' DTBs and m1n1 fixes
# silently never reach the boot chain. This unit closes that gap:
# compare a content stamp of the deployed boot components against the one
# recorded on the ESP; when stale, back up boot.bin and run update-m1n1.
#
# Safe-by-design: never touches m1n1 stage 1 (Apple-signed, installer-owned);
# always keeps boot.bin.bak; no-ops on non-Apple hardware and when up to date.
set -euo pipefail

# Only Apple Silicon (Asahi) machines have this DT compatible.
grep -q "apple," /proc/device-tree/compatible 2>/dev/null || exit 0

ESP=""
for c in /boot/efi /efi /boot; do
    [ -d "$c/m1n1" ] && ESP="$c" && break
done
[ -n "$ESP" ] || { echo "asahi-bootbin-sync: no ESP with m1n1/ found; skipping"; exit 0; }

# Content stamp over everything update-m1n1 would concatenate.
m1n1_bin=""
for c in /usr/lib64/m1n1/m1n1.bin /usr/lib/m1n1/m1n1.bin /usr/lib/asahi-boot/m1n1.bin; do
    [ -f "$c" ] && m1n1_bin="$c" && break
done
uboot_bin=""
for c in /usr/share/uboot/apple_m1/u-boot-nodtb.bin /usr/lib/u-boot-asahi/u-boot-nodtb.bin /usr/lib/u-boot/apple_m1/u-boot-nodtb.bin /usr/lib/asahi-boot/u-boot-nodtb.bin /usr/lib/asahi-boot/u-boot.bin; do
    [ -f "$c" ] && uboot_bin="$c" && break
done
kver=$(ls /usr/lib/modules | sort -V | tail -1)
[ -n "$m1n1_bin" ] && [ -n "$uboot_bin" ] || { echo "asahi-bootbin-sync: m1n1/u-boot payloads not in image; skipping"; exit 0; }

stamp=$( { cat "$m1n1_bin" "$uboot_bin"; cat /usr/lib/modules/"$kver"/dtb/apple/*.dtb 2>/dev/null; } | sha256sum | cut -d' ' -f1)
stamp_file="$ESP/m1n1/.bootbin.sha256"

if [ -f "$stamp_file" ] && [ "$(cat "$stamp_file")" = "$stamp" ]; then
    exit 0
fi

echo "asahi-bootbin-sync: boot components changed; regenerating boot.bin"
[ -f "$ESP/m1n1/boot.bin" ] && cp -f "$ESP/m1n1/boot.bin" "$ESP/m1n1/boot.bin.bak"
if update-m1n1 "$ESP/m1n1"; then
    echo "$stamp" > "$stamp_file"
    sync -f "$ESP"
    echo "asahi-bootbin-sync: boot.bin updated (backup at m1n1/boot.bin.bak)"
else
    echo "asahi-bootbin-sync: update-m1n1 FAILED — restoring backup" >&2
    [ -f "$ESP/m1n1/boot.bin.bak" ] && cp -f "$ESP/m1n1/boot.bin.bak" "$ESP/m1n1/boot.bin"
    exit 1
fi
